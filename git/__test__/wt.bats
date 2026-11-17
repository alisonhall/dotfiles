#!/usr/bin/env bats
# Tests for the wt commands (git/wt/), against a local "GitHub" repo and a fake gh.

load wt-fixture

setup() {
	wt_fixture_setup
}

teardown() {
	release_folder
}

# hold_folder <folder>: On Windows, keep a program in the folder, as an editor or a terminal
# would, until release_folder. (It has to be a Windows program: Git Bash's own processes don't
# stop a folder being renamed.)
#
# PowerShell is in the folder from the moment it starts, so it says it's ready by creating a file
# (outside the folder), rather than this checking by renaming the folder away and back: if
# PowerShell started during the rename, it couldn't start in the folder at all, and never held it.
# It then stays until release_folder creates another file, however slow the test is (it used to
# leave after a fixed 2 minutes, which a busy machine could outlast), or for 15 minutes at most.
hold_folder() {
	local ready="$BATS_TEST_TMPDIR/holder-ready" waited=0
	HOLDER_RELEASE="$BATS_TEST_TMPDIR/holder-release"
	rm -f "$ready" "$HOLDER_RELEASE"
	(cd "$1" && WT_HOLDER_READY="$(cygpath -w "$ready")" WT_HOLDER_RELEASE="$(cygpath -w "$HOLDER_RELEASE")" \
		exec powershell.exe -NoProfile -NonInteractive -Command '
			New-Item -ItemType File -Path $env:WT_HOLDER_READY | Out-Null
			$until = (Get-Date).AddMinutes(15)
			while (-not (Test-Path -LiteralPath $env:WT_HOLDER_RELEASE) -and (Get-Date) -lt $until) {
				Start-Sleep -Milliseconds 100
			}') \
		>/dev/null 2>&1 3>&- &
	HOLDER=$!
	# PowerShell can take a while to start on a busy machine (tenths of a second each)
	while [ ! -e "$ready" ] && [ "$waited" -lt 600 ]; do
		sleep 0.1
		waited=$((waited + 1))
	done
	if [ ! -e "$ready" ]; then
		echo "hold_folder: PowerShell didn't start within 60 seconds" >&2
		return 1
	fi
	# (Once, to be sure: a folder that's in use can't be renamed)
	if mv "$1" "$1.check" 2>/dev/null; then
		mv "$1.check" "$1"
		echo "hold_folder: PowerShell started, but $1 still isn't in use" >&2
		return 1
	fi
}

release_folder() {
	[ -n "${HOLDER:-}" ] || return 0
	# Let it leave by itself (it checks every tenth of a second), so it's gone before the next step
	touch "$HOLDER_RELEASE"
	wait "$HOLDER" 2>/dev/null || true
	HOLDER=""
}

#   -------------------------------
#   SHARING FILES WITH MAIN
#   -------------------------------

@test "wt add shares node_modules and WT_SYMLINK_PAIRS with main, by linking rather than copying" {
	echo SECRET=1 > "$MAIN/.env"
	export WT_SYMLINK_PAIRS=.env
	run bash "$WT/wt.sh" add feature/new
	[ "$status" -eq 0 ]
	folder="$WT_WORKTREE_REPO_LOCATION/feature_new"
	# -ef: the same folder or file, not a copy
	[ "$folder/node_modules" -ef "$MAIN/node_modules" ]
	[ "$folder/.env" -ef "$MAIN/.env" ]
	echo SECRET=2 > "$MAIN/.env"
	[ "$(cat "$folder/.env")" = SECRET=2 ]
}

@test "wt add skips a shared file that main doesn't have, rather than linking to nothing" {
	export WT_SYMLINK_PAIRS=.env
	run bash "$WT/wt.sh" add feature/new
	[ "$status" -eq 0 ]
	[[ "$output" == *".env: skipped, because main/.env doesn't exist"* ]] || false
	folder="$WT_WORKTREE_REPO_LOCATION/feature_new"
	[ ! -e "$folder/.env" ] && [ ! -L "$folder/.env" ]
}

@test "wt link --check passes correct links, and wt link repairs a missing one" {
	echo SECRET=1 > "$MAIN/.env"
	export WT_SYMLINK_PAIRS=.env
	bash "$WT/wt.sh" add feature/new >/dev/null 2>&1
	run bash "$WT/wt.sh" link --check --no-workspaces feature/new
	[ "$status" -eq 0 ]
	[[ "$output" == *"node_modules:  ok"* ]] || false
	[[ "$output" == *".env:  ok"* ]] || false

	rm "$WT_WORKTREE_REPO_LOCATION/feature_new/.env"
	run bash "$WT/wt.sh" link --check --no-workspaces feature/new
	[ "$status" -ne 0 ]
	[[ "$output" == *".env:  missing"* ]] || false
	run bash "$WT/wt.sh" link --no-workspaces feature/new
	[ "$status" -eq 0 ]
	[ "$WT_WORKTREE_REPO_LOCATION/feature_new/.env" -ef "$MAIN/.env" ]
}

@test "wt clean counts a shared .env as shared, not as work in the branch folder" {
	echo SECRET=1 > "$MAIN/.env"
	export WT_SYMLINK_PAIRS=.env
	bash "$WT/wt.sh" add feature/done >/dev/null 2>&1
	folder="$WT_WORKTREE_REPO_LOCATION/feature_done"
	git -C "$folder" commit -q --allow-empty -m work
	git -C "$folder" push -q -u origin feature/done 2>/dev/null
	run bash "$WT/wt.sh" clean --apply
	[ "$status" -eq 0 ]
	[[ "$output" == *"GONE"*"feature_done"* ]] || false
	[ "$(cat "$MAIN/.env")" = SECRET=1 ]
}

@test "link-workspaces.mjs points a monorepo's own packages at this branch folder's code" {
	command -v node >/dev/null 2>&1 || skip "Node.js isn't installed"
	folder="$BATS_TEST_TMPDIR/monorepo"
	mkdir -p "$folder/packages/ui" "$folder/packages/app"
	echo '{ "workspaces": ["packages/*"] }' > "$folder/package.json"
	echo '{ "name": "@acme/ui" }' > "$folder/packages/ui/package.json"
	echo '{ "name": "@acme/app" }' > "$folder/packages/app/package.json"
	run node "$WT/link-workspaces.mjs" "$folder" --relative
	[ "$status" -eq 0 ]
	[ "$folder/packages/node_modules/@acme/ui" -ef "$folder/packages/ui" ]
	run node "$WT/link-workspaces.mjs" "$folder" --relative --check
	[ "$status" -eq 0 ]
	[[ "$output" == *"ISSUES=0"* ]] || false
	run node "$WT/link-workspaces.mjs" "$folder" --clean
	[ "$status" -eq 0 ]
	[ ! -e "$folder/packages/node_modules/@acme/ui" ]
	[ -f "$folder/packages/ui/package.json" ]
}

#   -------------------------------
#   REMOVING BRANCH FOLDERS
#   -------------------------------

@test "wt clean --porcelain prints only the folders it would remove, and removes nothing" {
	merged_branch feature/done
	merged_branch feature/dirty
	echo work > "$WT_WORKTREE_REPO_LOCATION/feature_dirty/new-file.txt"
	out="$(bash "$WT/wt.sh" clean --porcelain 2>"$BATS_TEST_TMPDIR/report")"
	# One line, the folder (as git writes it: C:/... on Windows), and nothing else
	[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ]
	[ "$out" -ef "$WT_WORKTREE_REPO_LOCATION/feature_done" ]
	# The report went to stderr
	grep -q "RM.*feature_done" "$BATS_TEST_TMPDIR/report"
	grep -q "KEEP.*feature_dirty" "$BATS_TEST_TMPDIR/report"
	[ -d "$WT_WORKTREE_REPO_LOCATION/feature_done" ]
	# None safe to remove: nothing on stdout, and still exit 0
	rm -rf "$WT_WORKTREE_REPO_LOCATION/feature_done/node_modules"
	echo work > "$WT_WORKTREE_REPO_LOCATION/feature_done/new-file.txt"
	run bash -c 'bash "$1/wt.sh" clean --porcelain 2>/dev/null' _ "$WT"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "wt clean --porcelain's output ends when it does, not when a program it started in the background does" {
	merged_branch feature/done
	# A gh that leaves a program running, as git fetch can leave git's maintenance running: its own
	# stdout and stderr elsewhere (as such a program's are), any other open file inherited
	mv "$BATS_TEST_TMPDIR/bin/gh" "$BATS_TEST_TMPDIR/bin/gh-real"
	printf '#!/usr/bin/env bash\n(sleep 6 </dev/null >/dev/null 2>&1 &)\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR/bin/gh-real" > "$BATS_TEST_TMPDIR/bin/gh"
	chmod +x "$BATS_TEST_TMPDIR/bin/gh"
	SECONDS=0
	out="$(bash "$WT/wt.sh" clean --porcelain 2>/dev/null)"
	took=$SECONDS
	[ "$out" -ef "$WT_WORKTREE_REPO_LOCATION/feature_done" ]
	[ "$took" -lt 5 ]
}

@test "wt clean --porcelain won't go with --apply, and -h works with nothing set" {
	run bash "$WT/wt.sh" clean --porcelain --apply
	[ "$status" -eq 2 ]
	[[ "$output" == *"can't be used with --apply"* ]] || false
	unset WT_WORKTREE_REPO_LOCATION WT_REPO_SLUG
	cd "$BATS_TEST_TMPDIR"
	run bash "$WT/wt.sh" clean -h
	[ "$status" -eq 0 ]
	[[ "$output" == *"--porcelain"* ]] || false
}

@test "wt clean deletes a merged branch's folder, but not the main/node_modules its link points to" {
	merged_branch feature/done
	run bash "$WT/wt.sh" clean --apply
	[ "$status" -eq 0 ]
	[[ "$output" == *"GONE"*"feature_done"* ]] || false
	[ ! -e "$WT_WORKTREE_REPO_LOCATION/feature_done" ]
	[ -f "$MAIN/node_modules/pkg/index.js" ]
}

@test "wt rm deletes a branch's folder, but not the main/node_modules its link points to" {
	merged_branch feature/done
	run bash "$WT/wt.sh" rm feature/done
	[ "$status" -eq 0 ]
	[ ! -e "$WT_WORKTREE_REPO_LOCATION/feature_done" ]
	[ -f "$MAIN/node_modules/pkg/index.js" ]
}

@test "wt rm removes git's record of a branch folder that was already deleted" {
	merged_branch feature/gone
	rm -rf "$WT_WORKTREE_REPO_LOCATION/feature_gone"
	run bash "$WT/wt.sh" rm feature/gone
	[ "$status" -eq 0 ]
	[[ "$output" == *"feature_gone was already deleted"* ]] || false
	[[ "$(git -C "$MAIN" worktree list)" != *feature_gone* ]] || false
}

@test "wt rm without a terminal stops for uncommitted changes, new files and commits not on GitHub, unless --yes" {
	merged_branch feature/a
	merged_branch feature/b
	merged_branch feature/c
	# A gh that knows no pull requests, so feature_c's new commit is in none
	printf '#!/usr/bin/env bash\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/gh"
	echo change >> "$WT_WORKTREE_REPO_LOCATION/feature_a/.gitignore"
	echo new > "$WT_WORKTREE_REPO_LOCATION/feature_b/new-file.txt"
	git -C "$WT_WORKTREE_REPO_LOCATION/feature_c" commit -q --allow-empty -m "not pushed yet"
	for b in a b c; do
		run bash "$WT/wt.sh" rm "feature/$b" </dev/null
		[ "$status" -eq 1 ]
		[[ "$output" == *"feature_$b has work that deleting it would lose"* ]] || false
		[[ "$output" == *"and with no terminal to ask in, nothing was deleted. Add --yes"* ]] || false
		[ -d "$WT_WORKTREE_REPO_LOCATION/feature_$b" ]
	done
	run bash "$WT/wt.sh" rm feature/a </dev/null
	[[ "$output" == *".gitignore"* ]] || false
	run bash "$WT/wt.sh" rm feature/b </dev/null
	[[ "$output" == *"new-file.txt"* ]] || false
	run bash "$WT/wt.sh" rm feature/c </dev/null
	[[ "$output" == *"1 commit(s) not on origin"*"not pushed yet"* ]] || false
	run bash "$WT/wt.sh" rm --yes feature/c </dev/null
	[ "$status" -eq 0 ]
	[ ! -e "$WT_WORKTREE_REPO_LOCATION/feature_c" ]
	# Nothing to lose (its shared node_modules link is no work): no question
	git -C "$MAIN" push -q origin main:refs/heads/feature/d 2>/dev/null
	bash "$WT/wt.sh" add feature/d >/dev/null 2>&1
	run bash "$WT/wt.sh" rm feature/d </dev/null
	[ "$status" -eq 0 ]
	[ ! -e "$WT_WORKTREE_REPO_LOCATION/feature_d" ]
}

@test "wt rm in a terminal asks before losing work, and deletes it only on yes" {
	is_windows && skip "Windows has no terminals for a test to run a command in"
	command -v python3 >/dev/null 2>&1 || skip "python3 isn't installed, to give it a terminal"
	merged_branch feature/a
	echo new > "$WT_WORKTREE_REPO_LOCATION/feature_a/new-file.txt"
	# The command in a terminal, typing the answer once it asks, as a person would
	answer_in_terminal() { python3 "$BATS_TEST_DIRNAME/answer-in-terminal.py" "$@"; }
	run answer_in_terminal n bash "$WT/wt.sh" rm feature/a
	echo "$output"
	[[ "$output" == *"Delete feature_a anyway? [y/N]"* ]] || false
	[[ "$output" == *"has uncommitted changes, so nothing was deleted."* ]] || false
	[ -d "$WT_WORKTREE_REPO_LOCATION/feature_a" ]
	run answer_in_terminal y bash "$WT/wt.sh" rm feature/a
	echo "$output"
	[[ "$output" == *"Worktree folder feature_a removed."* ]] || false
	[ ! -e "$WT_WORKTREE_REPO_LOCATION/feature_a" ]
}

@test "wt rm doesn't count a pr-<number> branch's pull request commits as not on GitHub" {
	fork_pr 13 >/dev/null
	export FAKE_PRS="13:true:main:feature/a"
	bash "$WT/wt.sh" add --pr 13 >/dev/null 2>&1
	run bash "$WT/wt.sh" rm pr-13 </dev/null
	[ "$status" -eq 0 ]
	[ ! -e "$WT_WORKTREE_REPO_LOCATION/pr-13" ]
}

@test "wt rm and wt link take a name as a branch, even when there's a folder of that name where they're run" {
	merged_branch docs
	merged_branch feature/x
	mkdir -p "$WT_WORKTREE_REPO_LOCATION/feature_x/docs"
	echo keep > "$WT_WORKTREE_REPO_LOCATION/feature_x/docs/notes.md"
	git -C "$WT_WORKTREE_REPO_LOCATION/feature_x" add docs
	git -C "$WT_WORKTREE_REPO_LOCATION/feature_x" commit -q -m docs
	git -C "$WT_WORKTREE_REPO_LOCATION/feature_x" push -q 2>/dev/null
	cd "$WT_WORKTREE_REPO_LOCATION/feature_x"
	run bash "$WT/wt.sh" link --check --no-workspaces docs
	[[ "$output" == *"Worktree: docs"* ]] || false
	run bash "$WT/wt.sh" rm docs </dev/null
	[ "$status" -eq 0 ]
	[ ! -e "$WT_WORKTREE_REPO_LOCATION/docs" ]
	[ -f "$WT_WORKTREE_REPO_LOCATION/feature_x/docs/notes.md" ]
	# Written as a path, it's that folder - and one inside a branch folder isn't a branch folder
	run bash "$WT/wt.sh" rm ./docs </dev/null
	[ "$status" -eq 1 ]
	[[ "$output" == *"./docs is inside feature_x, not a branch's folder itself"* ]] || false
	[ -f "$WT_WORKTREE_REPO_LOCATION/feature_x/docs/notes.md" ]
}

@test "wt rm doesn't count shared links as work, even ones git doesn't ignore" {
	mkdir -p "$MAIN/.cache"
	echo data > "$MAIN/.cache/build.json"
	export WT_SYMLINK_PAIRS=.cache
	git -C "$MAIN" push -q origin main:refs/heads/feature/a 2>/dev/null
	bash "$WT/wt.sh" add feature/a >/dev/null 2>&1
	[ "$WT_WORKTREE_REPO_LOCATION/feature_a/.cache" -ef "$MAIN/.cache" ]
	run bash "$WT/wt.sh" rm feature/a </dev/null
	[ "$status" -eq 0 ]
	[ ! -e "$WT_WORKTREE_REPO_LOCATION/feature_a" ]
	[ -f "$MAIN/.cache/build.json" ]
}

@test "wt rm doesn't count a merged pull request's commits as not on GitHub once its branch is deleted" {
	merged_branch feature/done
	# GitHub deletes the branch after the merge, and a fetch drops git's copy of it
	git -C "$MAIN" push -q origin --delete feature/done 2>/dev/null
	git -C "$MAIN" fetch -q --prune
	run bash "$WT/wt.sh" rm feature/done </dev/null
	[ "$status" -eq 0 ]
	[ ! -e "$WT_WORKTREE_REPO_LOCATION/feature_done" ]
	# A commit made after it, though, is
	merged_branch feature/more
	git -C "$MAIN" push -q origin --delete feature/more 2>/dev/null
	git -C "$MAIN" fetch -q --prune
	# (the fake gh says it merged at its commit now, so make one after asking: move the branch on)
	sha="$(git -C "$WT_WORKTREE_REPO_LOCATION/feature_more" rev-parse HEAD)"
	git -C "$WT_WORKTREE_REPO_LOCATION/feature_more" commit -q --allow-empty -m "after the merge"
	cat > "$BATS_TEST_TMPDIR/bin/gh" <<-EOF
		#!/usr/bin/env bash
		[ "\$1 \$2" = "pr list" ] && printf '1\tMERGED\t%s\n' "$sha"
		exit 0
	EOF
	run bash "$WT/wt.sh" rm feature/more </dev/null
	[ "$status" -eq 1 ]
	[[ "$output" == *"1 commit(s) not on origin"*"after the merge"* ]] || false
}

@test "wt rm --branch deletes the branch too, but never a protected one" {
	merged_branch feature/a
	run bash "$WT/wt.sh" rm --branch feature/a </dev/null
	[ "$status" -eq 0 ]
	[[ "$output" == *"Branch feature/a deleted."* ]] || false
	run git -C "$MAIN" show-ref --verify --quiet refs/heads/feature/a
	[ "$status" -ne 0 ]
	[ -z "$(git -C "$MAIN" config --get branch.feature/a.remote)" ]
	# Without --branch it stays
	merged_branch feature/b
	bash "$WT/wt.sh" rm feature/b </dev/null >/dev/null 2>&1
	git -C "$MAIN" show-ref --verify --quiet refs/heads/feature/b
	# A protected one, in a folder of its own
	git -C "$MAIN" branch -q release main
	git -C "$MAIN" worktree add -q "$WT_WORKTREE_REPO_LOCATION/release" release
	git -C "$WT_WORKTREE_REPO_LOCATION/release" push -q -u origin release 2>/dev/null
	export WT_PROTECTED_BRANCHES="main release"
	run bash "$WT/wt.sh" rm --branch release </dev/null
	[ "$status" -eq 0 ]
	[[ "$output" == *"Kept branch release, as it's protected."* ]] || false
	git -C "$MAIN" show-ref --verify --quiet refs/heads/release
}

@test "wt rm given a branch's folder removes it, from anywhere and with nothing set" {
	merged_branch feature/a
	merged_branch feature/b
	export WT_WORKTREE_REPO_LOCATION="$BATS_TEST_TMPDIR/other"
	unset WT_REPO_SLUG
	cd "$BATS_TEST_TMPDIR"
	run bash "$WT/wt.sh" rm --branch "$BATS_TEST_TMPDIR/repo/feature_a" </dev/null
	[ "$status" -eq 0 ]
	[ ! -e "$BATS_TEST_TMPDIR/repo/feature_a" ]
	[[ "$output" == *"Branch feature/a deleted."* ]] || false
	# As ., from inside a subfolder's parent
	cd "$BATS_TEST_TMPDIR/repo/feature_b"
	run bash "$WT/wt.sh" rm . </dev/null
	[ "$status" -eq 0 ]
	[ ! -e "$BATS_TEST_TMPDIR/repo/feature_b" ]
	cd "$BATS_TEST_TMPDIR"
	# The main folder, or a folder that isn't a branch's
	run bash "$WT/wt.sh" rm "$MAIN"
	[ "$status" -eq 1 ]
	[[ "$output" == *"won't delete the main folder"* ]] || false
	mkdir "$BATS_TEST_TMPDIR/elsewhere"
	unset WT_WORKTREE_REPO_LOCATION
	run bash "$WT/wt.sh" rm "$BATS_TEST_TMPDIR/elsewhere"
	[ "$status" -eq 1 ]
	[[ "$output" == *"isn't a worktree of a git repo"* ]] || false
	[ -d "$BATS_TEST_TMPDIR/elsewhere" ]
	run bash "$WT/wt.sh" rm -h
	[ "$status" -eq 0 ]
	[[ "$output" == *"--branch"* ]] || false
}

@test "wt rm won't delete the main folder" {
	run bash "$WT/wt.sh" rm main
	[ "$status" -ne 0 ]
	[[ "$output" == *"won't delete the main folder"* ]] || false
	[ -d "$MAIN/.git" ]
}

@test "wt rm won't take anything git wouldn't accept as a branch name, like . or .." {
	# In the folder that holds main, where . is that folder and .. the one holding it
	cd "$WT_WORKTREE_REPO_LOCATION"
	for name in .git feature/.hidden; do
		run bash "$WT/wt.sh" rm "$name"
		[ "$status" -ne 0 ]
		[[ "$output" == *"isn't a branch name"* ]] || false
	done
	# (. and .. are written as paths, so they're folders - and neither is a worktree)
	for name in . ..; do
		run bash "$WT/wt.sh" rm "$name"
		[ "$status" -ne 0 ]
		[[ "$output" == *"isn't a worktree of a git repo"* ]] || false
	done
	[ -d "$MAIN/.git" ]
}

@test "wt rm won't delete the repo itself in the bare-repo layout (.bare)" {
	export WT_WORKTREE_REPO_LOCATION="$BATS_TEST_TMPDIR/bare-layout"
	git clone -q --bare "$BATS_TEST_TMPDIR/origin.git" "$WT_WORKTREE_REPO_LOCATION/.bare"
	git -C "$WT_WORKTREE_REPO_LOCATION/.bare" worktree add -q ../main main
	run bash "$WT/wt.sh" rm .bare
	[ "$status" -ne 0 ]
	[[ "$output" == *"isn't a branch name"* ]] || false
	[ -f "$WT_WORKTREE_REPO_LOCATION/.bare/HEAD" ]
	git -C "$WT_WORKTREE_REPO_LOCATION/main" status >/dev/null
}

@test "wt rm says so when a branch has no folder and git has no record of one (a typo, say)" {
	run bash "$WT/wt.sh" rm feature/tpyo
	[ "$status" -ne 0 ]
	[[ "$output" == *"there's no worktree for feature/tpyo"* ]] || false
}

@test "remove_links deletes symlinks the repo tracks too, since git might follow them" {
	is_windows && skip "Git for Windows checks out tracked symlinks as plain files by default"
	ln -s .gitignore "$MAIN/ignore-link"
	git -C "$MAIN" add ignore-link
	git -C "$MAIN" commit -q -m "add a symlink"
	merged_branch feature/x
	folder="$WT_WORKTREE_REPO_LOCATION/feature_x"
	run bash -c '. "$1" && remove_links "$2"' _ "$WT/wt-common.sh" "$folder"
	[ "$status" -eq 0 ]
	[ ! -L "$folder/ignore-link" ]
	[ ! -L "$folder/node_modules" ]
}

@test "wt clean deletes a shared link inside a branch folder's own node_modules, not what it points to" {
	mkdir -p "$MAIN/node_modules/.cache"
	echo data > "$MAIN/node_modules/.cache/build.json"
	export WT_SYMLINK_PAIRS=node_modules/.cache
	merged_branch feature/done
	folder="$WT_WORKTREE_REPO_LOCATION/feature_done"
	# This branch folder has its own node_modules, with only the .cache inside it shared
	rm -f "$folder/node_modules"
	mkdir -p "$folder/node_modules/dep"
	link_dir "$MAIN/node_modules/.cache" "$folder/node_modules/.cache"
	run bash "$WT/wt.sh" clean --apply
	[ "$status" -eq 0 ]
	[[ "$output" == *"GONE"*"feature_done"* ]] || false
	[ -f "$MAIN/node_modules/.cache/build.json" ]
}

@test "wt clean puts back symlinks the repo tracks when git refuses to remove the folder" {
	is_windows && skip "Git for Windows checks out tracked symlinks as plain files by default"
	ln -s .gitignore "$MAIN/ignore-link"
	git -C "$MAIN" add ignore-link
	git -C "$MAIN" commit -q -m "add a symlink"
	git -C "$MAIN" push -q origin main
	merged_branch feature/locked
	folder="$WT_WORKTREE_REPO_LOCATION/feature_locked"
	# A locked worktree makes git worktree remove --force refuse
	git -C "$MAIN" worktree lock "$folder"
	run bash "$WT/wt.sh" clean --apply
	[ "$status" -eq 0 ]
	[[ "$output" == *"KEEP"*"feature_locked"*"refused"* ]] || false
	[ -L "$folder/ignore-link" ]
}

@test "wt rm deletes a branch folder that has its own node_modules installed" {
	merged_branch feature/own
	folder="$WT_WORKTREE_REPO_LOCATION/feature_own"
	rm -f "$folder/node_modules"
	mkdir -p "$folder/node_modules/dep"
	echo x > "$folder/node_modules/dep/index.js"
	run bash "$WT/wt.sh" rm feature/own
	[ "$status" -eq 0 ]
	[ ! -e "$folder" ]
	[ -f "$MAIN/node_modules/pkg/index.js" ]
}

# fail_rename_back <times>: An mv that fails to rename a folder back after wt's in-use check,
# the first <times> times, as antivirus or the search indexer holding it for a moment would
fail_rename_back() {
	local real_mv
	real_mv="$(command -v mv)"
	cat > "$BATS_TEST_TMPDIR/bin/mv" <<-EOF
		#!/usr/bin/env bash
		case "\$1" in
			*.wt-in-use-check-*)
				count="\$(cat "$BATS_TEST_TMPDIR/mv-fails" 2>/dev/null || echo 0)"
				if [ "\$count" -lt $1 ]; then
					echo \$((count + 1)) > "$BATS_TEST_TMPDIR/mv-fails"
					echo "mv: Permission denied" >&2
					exit 1
				fi
				;;
		esac
		exec "$real_mv" "\$@"
	EOF
	chmod +x "$BATS_TEST_TMPDIR/bin/mv"
}

@test "on Windows, the in-use check tries again when a folder can't be renamed back straight away" {
	export WT_OS=MINGW64_NT-10.0
	merged_branch feature/done
	fail_rename_back 2
	run bash "$WT/wt.sh" rm feature/done
	[ "$status" -eq 0 ]
	[ ! -e "$WT_WORKTREE_REPO_LOCATION/feature_done" ]
	[ -f "$MAIN/node_modules/pkg/index.js" ]
}

@test "on Windows, wt rm says where a folder is when it can't be renamed back after the in-use check" {
	export WT_OS=MINGW64_NT-10.0
	merged_branch feature/done
	fail_rename_back 99
	run bash "$WT/wt.sh" rm feature/done
	[ "$status" -ne 0 ]
	[[ "$output" == *"Put it back with: mv"* ]] || false
	# (Not also the message for a folder that's in use, which would be wrong)
	[[ "$output" != *"is in use by another program"* ]] || false
	ls -d "$WT_WORKTREE_REPO_LOCATION"/feature_done.wt-in-use-check-*
	[ -f "$MAIN/node_modules/pkg/index.js" ]
}

@test "on Windows, wt clean keeps a folder it can't rename back after the in-use check" {
	export WT_OS=MINGW64_NT-10.0
	merged_branch feature/done
	fail_rename_back 99
	run bash "$WT/wt.sh" clean --apply
	[ "$status" -eq 0 ]
	[[ "$output" == *"KEEP"*"feature_done"*"renamed while checking"* ]] || false
	ls -d "$WT_WORKTREE_REPO_LOCATION"/feature_done.wt-in-use-check-*
}

@test "on Windows, wt rm deletes nothing from a folder that's in use, rather than half of it" {
	is_windows || skip "only Windows refuses to delete a folder that's in use"
	merged_branch feature/busy
	folder="$WT_WORKTREE_REPO_LOCATION/feature_busy"
	echo notes > "$folder/notes.txt"
	hold_folder "$folder"
	# (--yes: notes.txt is work it would otherwise stop for, before looking)
	run bash "$WT/wt.sh" rm --yes feature/busy
	release_folder
	[ "$status" -ne 0 ]
	[[ "$output" == *"in use by another program"* ]] || false
	[ -f "$folder/notes.txt" ]
	[ "$folder/node_modules" -ef "$MAIN/node_modules" ]
}

@test "on Windows, wt clean keeps a folder that's in use" {
	is_windows || skip "only Windows refuses to delete a folder that's in use"
	merged_branch feature/busy
	folder="$WT_WORKTREE_REPO_LOCATION/feature_busy"
	hold_folder "$folder"
	run bash "$WT/wt.sh" clean --apply
	release_folder
	[ "$status" -eq 0 ]
	[[ "$output" == *"KEEP"*"feature_busy"*"in use by another program"* ]] || false
	[ -f "$folder/.gitignore" ]
	[ "$folder/node_modules" -ef "$MAIN/node_modules" ]
}

#   -------------------------------
#   LISTING BRANCH FOLDERS
#   -------------------------------

@test "wt ls shows branch folders next to main as separate folders, not outside the repo" {
	bash "$WT/wt.sh" add feature/new >/dev/null 2>&1
	run bash "$WT/wt.sh" ls --no-fetch
	[ "$status" -eq 0 ]
	[[ "$output" == *"folder:  feature_new  [sibling]"* ]] || false
	[[ "$output" != *"[outside]"* ]] || false
}

@test "wt ls doesn't count files shared with main as untracked" {
	echo debug=1 > "$MAIN/settings.local"
	export WT_SYMLINK_PAIRS=settings.local
	bash "$WT/wt.sh" add feature/new >/dev/null 2>&1
	run bash "$WT/wt.sh" ls --no-fetch
	[ "$status" -eq 0 ]
	[[ "$output" == *"feature/new"*"untracked: none"* ]] || false
}

# pr_commit <number>: A new commit on pull request <number>'s head, as its author pushing more.
# Prints the commit.
pr_commit() {
	local sha
	git -C "$MAIN" switch -q --detach "$(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse "refs/pull/$1/head")" 2>/dev/null ||
		{ git -C "$MAIN" fetch -q origin "refs/pull/$1/head" && git -C "$MAIN" switch -q --detach FETCH_HEAD; }
	git -C "$MAIN" commit -q --allow-empty -m "more work on #$1"
	sha="$(git -C "$MAIN" rev-parse HEAD)"
	git -C "$MAIN" push -q origin "HEAD:refs/pull/$1/head" 2>/dev/null
	git -C "$MAIN" switch -q main
	echo "$sha"
}

# deleted_after_merge <branch> <number>: A branch that was pushed, merged as pull request
# <number>, and then deleted, from GitHub and from the clone. Prints its last commit.
deleted_after_merge() {
	local sha
	git -C "$MAIN" switch -q -c "$1"
	git -C "$MAIN" commit -q --allow-empty -m "work on $1"
	sha="$(git -C "$MAIN" rev-parse HEAD)"
	git -C "$MAIN" push -q origin "$1" 2>/dev/null
	# GitHub keeps every pull request's last commit at refs/pull/<number>/head
	git -C "$BATS_TEST_TMPDIR/origin.git" update-ref "refs/pull/$2/head" "$sha"
	git -C "$MAIN" push -q origin --delete "$1" 2>/dev/null
	git -C "$MAIN" switch -q main
	git -C "$MAIN" branch -q -D "$1"
	git -C "$MAIN" fetch -q --prune
	echo "$sha"
}

@test "on Windows without symlinks, a shared folder's junction works in a folder with & ^ % ; in its name" {
	is_windows || skip "only Windows uses junctions"
	# The folder name from a branch like feature/a&b^c%OS%;d, in a repo location with a space and a !
	local base="$BATS_TEST_TMPDIR/my repo!" folder
	folder="$base/feature_a&b^c%OS%;d"
	mkdir -p "$base/main/node_modules/pkg" "$folder"
	echo 'module.exports = 42' > "$base/main/node_modules/pkg/index.js"
	# As if Developer Mode were off, so make_link can't make a real symlink
	run bash -c '. "$1/wt-common.sh"; ln() { [ "$1" = -s ] && return 1; command ln "$@"; }
		make_link "$2/main/node_modules" "$3/node_modules"' _ "$WT" "$base" "$folder"
	[ "$status" -eq 0 ]
	[ "$(cat "$folder/node_modules/pkg/index.js")" = 'module.exports = 42' ]
	# A junction, not a copy: changes to main's show through
	echo changed > "$base/main/node_modules/pkg/index.js"
	[ "$(cat "$folder/node_modules/pkg/index.js")" = changed ]
}

#   -------------------------------
#   BRANCHES DELETED AFTER MERGING
#   -------------------------------

@test "wt add brings back a branch that was deleted after its pull request was merged" {
	sha="$(deleted_after_merge feature/gone 7)"
	export FAKE_MERGED_PRS="feature/gone=7"
	run bash "$WT/wt.sh" add feature/gone
	[ "$status" -eq 0 ]
	[[ "$output" == *"merged PR #7 had this head"* ]] || false
	[ "$(git -C "$WT_WORKTREE_REPO_LOCATION/feature_gone" rev-parse HEAD)" = "$sha" ]
}

@test "wt add finds the merged pull request without WT_REPO_SLUG, from the main folder's clone" {
	sha="$(deleted_after_merge feature/gone 7)"
	export FAKE_MERGED_PRS="feature/gone=7"
	unset WT_REPO_SLUG
	run bash "$WT/wt.sh" add feature/gone
	[ "$status" -eq 0 ]
	[ "$(git -C "$WT_WORKTREE_REPO_LOCATION/feature_gone" rev-parse HEAD)" = "$sha" ]
}

@test "the merged pull request is found for a branch with \" \\ & or ' in its name" {
	# (Called directly: no Windows folder can be named after a branch with " or \ in it)
	local branch
	for branch in 'say-"hi"' 'back\slash' 'fix-a&b' "it's"; do
		export FAKE_MERGED_PRS="feature/other=3 $branch=7"
		run bash -c '. "$1/wt-common.sh"; MAIN_WT="$2"; REMOTE_BRANCH_NAME="$3"; find_merged_pr' \
			_ "$WT" "$MAIN" "$branch"
		[ "$status" -eq 0 ]
		[ "$output" = 7 ] || { echo "$branch: got '$output'" >&2; false; }
	done
	# And only that branch's: a name that only starts the same finds nothing
	run bash -c '. "$1/wt-common.sh"; MAIN_WT="$2"; REMOTE_BRANCH_NAME="say"; find_merged_pr' _ "$WT" "$MAIN"
	[ "$output" = "" ]
}

#   -------------------------------
#   THE MAIN FOLDER'S BRANCH
#   -------------------------------

@test "wt ls --porcelain prints one tab-separated line per worktree, and nothing else" {
	git -C "$MAIN" push -q origin main:refs/heads/feature/x 2>/dev/null
	bash "$WT/wt.sh" add feature/x >/dev/null 2>&1
	fork_pr 13 >/dev/null
	export FAKE_PRS="13:true:main:feature/a"
	bash "$WT/wt.sh" add --pr 13 >/dev/null 2>&1
	echo work > "$WT_WORKTREE_REPO_LOCATION/feature_x/new-file.txt"
	pr_commit 13 >/dev/null
	out="$(bash "$WT/wt.sh" ls --porcelain 2>/dev/null)"
	[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 3 ]
	# 14 fields on every line
	[ -z "$(printf '%s\n' "$out" | awk -F'\t' 'NF != 14')" ]
	field() { printf '%s\n' "$out" | awk -F'\t' -v b="$1" -v f="$2" '$2 == b { print $f }'; }
	# The main folder
	[ "$(field main 1)" -ef "$MAIN" ]
	[ "$(field main 3)" = "$(git -C "$MAIN" rev-parse HEAD)" ]
	[ "$(field main 5)" = refs/heads/main ]
	[ "$(field main 12)" = 1 ]
	# A branch folder, with a new file in it
	[ "$(field feature/x 1)" -ef "$WT_WORKTREE_REPO_LOCATION/feature_x" ]
	[ "$(field feature/x 4)" = origin ]
	[ "$(field feature/x 5)" = refs/heads/feature/x ]
	[ "$(field feature/x 6)" = exists ]
	[ "$(field feature/x 7) $(field feature/x 8)" = "0 0" ]
	[ "$(field feature/x 9) $(field feature/x 10)" = "no 1" ]
	[ "$(field feature/x 11)" = sibling ]
	[ "$(field feature/x 12) $(field feature/x 13) $(field feature/x 14)" = "0 0 0" ]
	# A pull request's, one behind it
	[ "$(field pr-13 5)" = refs/pull/13/head ]
	[ "$(field pr-13 6)" = exists ]
	[ "$(field pr-13 7) $(field pr-13 8)" = "0 1" ]
}

@test "wt ls --porcelain leaves a detached folder's remote empty, and -h works with nothing set" {
	git -C "$MAIN" push -q origin main:refs/heads/feature/x 2>/dev/null
	bash "$WT/wt.sh" add feature/x >/dev/null 2>&1
	git -C "$MAIN" worktree add -q --detach "$WT_WORKTREE_REPO_LOCATION/zz-detached" main
	out="$(bash "$WT/wt.sh" ls --porcelain --no-fetch 2>/dev/null)"
	row="$(printf '%s\n' "$out" | awk -F'\t' '$1 ~ /zz-detached$/')"
	[ -n "$row" ]
	[ "$(printf '%s' "$row" | cut -f2,4,5,6 | tr '\t' ,)" = ",,,none" ]
	unset WT_WORKTREE_REPO_LOCATION WT_REPO_SLUG
	cd "$BATS_TEST_TMPDIR"
	run bash "$WT/wt.sh" ls -h
	[ "$status" -eq 0 ]
	[[ "$output" == *"--porcelain"* ]] || false
	[[ "$output" == *"14 1 when git can prune it"* ]] || false
}

@test "wt ls doesn't warn about the main folder holding the start branch, even when that isn't main" {
	git -C "$MAIN" switch -q -c develop
	export CURRENT_DEV_BRANCH=develop
	run bash "$WT/wt.sh" ls --no-fetch
	[ "$status" -eq 0 ]
	[[ "$output" != *"⚠"* ]] || false
	[[ "$output" == *"branch ≠ folder: 0"* ]] || false
}

@test "wt ls warns when the main folder holds some other branch" {
	git -C "$MAIN" switch -q -c feature/oops
	run bash "$WT/wt.sh" ls --no-fetch
	[ "$status" -eq 0 ]
	[[ "$output" == *"feature/oops"*"⚠ main folder isn't on main"* ]] || false
	[[ "$output" == *"branch ≠ folder: 1"* ]] || false
	# ...and says how to fix it
	[[ "$output" == *"git config wt.devBranch"* ]] || false
	[[ "$output" == *"switch main"* ]] || false
}

#   -------------------------------
#   WT CLEAN AND THE MAIN FOLDER
#   -------------------------------

@test "wt clean never removes the main folder, whatever branch it holds" {
	git -C "$MAIN" switch -q -c develop
	git -C "$MAIN" push -q -u origin develop 2>/dev/null
	run bash "$WT/wt.sh" clean --apply
	[ "$status" -eq 0 ]
	[[ "$output" == *"KEEP  main"*"(the main folder)"* ]] || false
	[[ "$output" != *"refused"* ]] || false
	[ -d "$MAIN/.git" ]
}

@test "wt clean never removes the main folder in the bare-repo layout either" {
	export WT_WORKTREE_REPO_LOCATION="$BATS_TEST_TMPDIR/bare-layout"
	git clone -q --bare "$BATS_TEST_TMPDIR/origin.git" "$WT_WORKTREE_REPO_LOCATION/.bare"
	git -C "$WT_WORKTREE_REPO_LOCATION/.bare" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
	git -C "$WT_WORKTREE_REPO_LOCATION/.bare" fetch -q
	git -C "$WT_WORKTREE_REPO_LOCATION/.bare" worktree add -q -b develop ../main main
	git -C "$WT_WORKTREE_REPO_LOCATION/main" push -q -u origin develop 2>/dev/null
	run bash "$WT/wt.sh" clean --apply
	[ "$status" -eq 0 ]
	[[ "$output" == *"(the main folder)"* ]] || false
	[ -d "$WT_WORKTREE_REPO_LOCATION/main" ]
	git -C "$WT_WORKTREE_REPO_LOCATION/.bare" rev-parse --verify --quiet refs/heads/develop
}

@test "wt clean protects CURRENT_DEV_BRANCH, as well as WT_PROTECTED_BRANCHES" {
	git -C "$MAIN" worktree add -q -b develop "$WT_WORKTREE_REPO_LOCATION/develop"
	git -C "$WT_WORKTREE_REPO_LOCATION/develop" push -q -u origin develop 2>/dev/null
	export CURRENT_DEV_BRANCH=develop
	run bash "$WT/wt.sh" clean --apply
	[ "$status" -eq 0 ]
	[[ "$output" == *"protected branch: develop"* ]] || false
	[ -d "$WT_WORKTREE_REPO_LOCATION/develop" ]
}

@test "wt clean works when the repo's folder has a space in its path" {
	export WT_WORKTREE_REPO_LOCATION="$BATS_TEST_TMPDIR/my repo"
	MAIN="$WT_WORKTREE_REPO_LOCATION/main"
	git clone -q "$BATS_TEST_TMPDIR/origin.git" "$MAIN" 2>/dev/null
	mkdir -p "$MAIN/node_modules/pkg"
	echo 'module.exports = 42' > "$MAIN/node_modules/pkg/index.js"
	merged_branch feature/done
	run bash "$WT/wt.sh" clean --apply
	[ "$status" -eq 0 ]
	[[ "$output" == *"GONE"*"feature_done"* ]] || false
	[ ! -e "$WT_WORKTREE_REPO_LOCATION/feature_done" ]
	[ -f "$MAIN/node_modules/pkg/index.js" ]
}

#   -------------------------------
#   BRANCH NAMES AND FOLDERS
#   -------------------------------

@test "wt add doesn't mistake a branch on GitHub whose name ends the same, like feature/login for login" {
	git -C "$MAIN" push -q origin main:refs/heads/feature/login 2>/dev/null
	run bash "$WT/wt.sh" add login
	[ "$status" -eq 0 ]
	[[ "$output" == *"Remote branch 'login' not found"* ]] || false
	[ "$(git -C "$WT_WORKTREE_REPO_LOCATION/login" branch --show-current)" = login ]
}

@test "wt add --strict makes nothing for a branch that isn't on GitHub" {
	run bash "$WT/wt.sh" add --strict feature/typo
	# 3: not on the remote, as against 4: couldn't find out
	[ "$status" -eq 3 ]
	[[ "$output" == *"branch 'feature/typo' isn't on origin - with --strict, no new branch is made"* ]] || false
	[ "$(ls "$WT_WORKTREE_REPO_LOCATION")" = main ]
	run git -C "$MAIN" show-ref --verify --quiet refs/heads/feature/typo
	[ "$status" -ne 0 ]
}

@test "wt add --strict still checks out a branch that's on GitHub, the option before or after it" {
	git -C "$MAIN" push -q origin main:refs/heads/feature/a main:refs/heads/feature/b 2>/dev/null
	run bash "$WT/wt.sh" add --strict feature/a
	[ "$status" -eq 0 ]
	run bash "$WT/wt.sh" add feature/b --strict
	[ "$status" -eq 0 ]
	[ "$(git -C "$WT_WORKTREE_REPO_LOCATION/feature_a" rev-parse --abbrev-ref '@{upstream}')" = origin/feature/a ]
	[ "$(git -C "$WT_WORKTREE_REPO_LOCATION/feature_b" rev-parse --abbrev-ref '@{upstream}')" = origin/feature/b ]
}

@test "wt add --strict still brings back a branch deleted after its pull request was merged" {
	sha="$(deleted_after_merge feature/gone 7)"
	export FAKE_MERGED_PRS="feature/gone=7"
	run bash "$WT/wt.sh" add --strict feature/gone
	[ "$status" -eq 0 ]
	[ "$(git -C "$WT_WORKTREE_REPO_LOCATION/feature_gone" rev-parse HEAD)" = "$sha" ]
}

@test "wt add --strict makes nothing when the merged pull request's head can't be fetched" {
	export FAKE_MERGED_PRS="feature/gone=7"
	run bash "$WT/wt.sh" add --strict feature/gone
	[ "$status" -eq 4 ]
	[[ "$output" == *"couldn't fetch refs/pull/7/head"* ]] || false
	[ "$(ls "$WT_WORKTREE_REPO_LOCATION")" = main ]
}

@test "wt add --strict makes nothing when GitHub can't be asked" {
	git -C "$MAIN" remote set-url origin "$BATS_TEST_TMPDIR/nowhere.git"
	run bash "$WT/wt.sh" add --strict feature/a
	[ "$status" -eq 4 ]
	[[ "$output" == *"couldn't ask origin whether it has 'feature/a'"* ]] || false
	[ "$(ls "$WT_WORKTREE_REPO_LOCATION")" = main ]
}

@test "wt add refuses an option it doesn't know, and wt cd refuses any, rather than taking it for a branch" {
	run bash "$WT/wt.sh" add --stirct feature/a
	[ "$status" -eq 2 ]
	[[ "$output" == *"wt-add: unknown option --stirct"* ]] || false
	run bash "$WT/wt.sh" cd --strict
	[ "$status" -eq 2 ]
	[[ "$output" == *"wt-cd: unknown option --strict"* ]] || false
	[ "$(ls "$WT_WORKTREE_REPO_LOCATION")" = main ]
}

@test "wt add --pr checks out a fork's pull request as pr-<number>, tracking its pull ref, with the shared links" {
	sha="$(fork_pr 13)"
	export FAKE_PRS="13:true:main:feature/a"
	# This repo's feature/a is another branch, not the fork's
	git -C "$MAIN" push -q origin main:refs/heads/feature/a 2>/dev/null
	run bash "$WT/wt.sh" add --pr 13
	[ "$status" -eq 0 ]
	folder="$WT_WORKTREE_REPO_LOCATION/pr-13"
	[ "$(git -C "$folder" branch --show-current)" = pr-13 ]
	[ "$(git -C "$folder" rev-parse HEAD)" = "$sha" ]
	[ "$(git -C "$MAIN" config branch.pr-13.remote)" = origin ]
	[ "$(git -C "$MAIN" config branch.pr-13.merge)" = refs/pull/13/head ]
	[ "$folder/node_modules" -ef "$MAIN/node_modules" ]
	[ ! -e "$WT_WORKTREE_REPO_LOCATION/feature_a" ]
	# Again: it's there already
	run bash "$WT/wt.sh" add --pr 13
	[ "$status" -eq 0 ]
	[[ "$output" == *"Worktree folder pr-13 already exists"* ]] || false
	# Its folder removed, the branch is checked out as it is
	git -C "$MAIN" worktree remove --force "$folder"
	run bash "$WT/wt.sh" add --pr 13
	[ "$status" -eq 0 ]
	[ "$(git -C "$folder" branch --show-current)" = pr-13 ]
}

@test "wt add --pr takes a pull request from a branch named as its base for a fork's" {
	sha="$(fork_pr 14)"
	export FAKE_PRS="14:false:main:main"
	run bash "$WT/wt.sh" add --pr 14
	[ "$status" -eq 0 ]
	[ "$(git -C "$WT_WORKTREE_REPO_LOCATION/pr-14" rev-parse HEAD)" = "$sha" ]
}

@test "wt add --pr checks out this repo's pull request's own branch, or its pull ref once the branch is deleted" {
	git -C "$MAIN" push -q origin main:refs/heads/feature/a 2>/dev/null
	gone="$(deleted_after_merge feature/gone 7)"
	export FAKE_PRS="12:false:main:feature/a 7:false:main:feature/gone"
	run bash "$WT/wt.sh" add --pr 12
	[ "$status" -eq 0 ]
	[ "$(git -C "$WT_WORKTREE_REPO_LOCATION/feature_a" rev-parse --abbrev-ref '@{upstream}')" = origin/feature/a ]
	run bash "$WT/wt.sh" add --pr 7
	[ "$status" -eq 0 ]
	[ "$(git -C "$WT_WORKTREE_REPO_LOCATION/pr-7" rev-parse HEAD)" = "$gone" ]
	[ "$(git -C "$MAIN" config branch.pr-7.merge)" = refs/pull/7/head ]
	[ ! -e "$WT_WORKTREE_REPO_LOCATION/feature_gone" ]
}

@test "wt add --pr makes nothing when the pull request's head isn't there or can't be asked for" {
	# gh knows the pull request, but GitHub has no pull ref for it
	export FAKE_PRS="13:true:main:feature/a"
	run bash "$WT/wt.sh" add --pr 13
	[ "$status" -eq 3 ]
	[[ "$output" == *"origin has no refs/pull/13/head"* ]] || false
	# GitHub has no such pull request
	run bash "$WT/wt.sh" add --pr 99
	[ "$status" -eq 3 ]
	[[ "$output" == *"Could not resolve to a PullRequest"* ]] || false
	[[ "$output" == *"GitHub has no pull request #99 in this repo"* ]] || false
	# gh can't reach GitHub
	FAKE_GH_OFFLINE=1 run bash "$WT/wt.sh" add --pr 13
	[ "$status" -eq 4 ]
	[[ "$output" == *"error connecting to api.github.com"* ]] || false
	[[ "$output" == *"couldn't ask gh about PR #13"* ]] || false
	# GitHub can't be asked
	fork_pr 13 >/dev/null
	git -C "$MAIN" remote set-url origin "$BATS_TEST_TMPDIR/nowhere.git"
	run bash "$WT/wt.sh" add --pr 13
	[ "$status" -eq 4 ]
	[[ "$output" == *"couldn't ask origin for refs/pull/13/head"* ]] || false
	# This repo's branch, GitHub not answering
	export FAKE_PRS="12:false:main:feature/a"
	run bash "$WT/wt.sh" add --pr 12
	[ "$status" -eq 4 ]
	[[ "$output" == *"the branch of PR #12, so nothing was made"* ]] || false
	[ "$(ls "$WT_WORKTREE_REPO_LOCATION")" = main ]
}

@test "wt add --pr refuses a number that isn't one, a missing one, and a branch as well" {
	run bash "$WT/wt.sh" add --pr abc
	[ "$status" -eq 2 ]
	[[ "$output" == *"--pr takes a pull request's number, not 'abc'"* ]] || false
	run bash "$WT/wt.sh" add --pr
	[ "$status" -eq 2 ]
	[[ "$output" == *"Usage: wt add"* ]] || false
	run bash "$WT/wt.sh" add --pr 12 feature/a
	[ "$status" -eq 2 ]
	[[ "$output" == *"give a branch or --pr <number>, not both"* ]] || false
	[ "$(ls "$WT_WORKTREE_REPO_LOCATION")" = main ]
}

@test "wt add --pr says how to push to a fork's pull request whose author lets maintainers, and only then" {
	fork_pr 13 >/dev/null
	fork_pr 14 >/dev/null
	# The remote as GitHub's address, https or ssh (git still reaching the local "GitHub" repo,
	# by a path Windows' git can read)
	origin="$BATS_TEST_TMPDIR/origin.git"
	if is_windows; then origin="$(cygpath -m "$origin")"; fi
	git -C "$MAIN" config "url.$origin.insteadOf" https://github.com/acme/shop.git
	git -C "$MAIN" config --add "url.$origin.insteadOf" git@github.com:acme/shop.git
	git -C "$MAIN" remote set-url origin https://github.com/acme/shop.git
	export FAKE_PRS="13:true:main:feature/a:forker/shop 14:true:main:feature/b"
	run bash "$WT/wt.sh" add --pr 13
	[ "$status" -eq 0 ]
	[[ "$output" == *"PR #13's author lets maintainers push to it"* ]] || false
	[[ "$output" == *"git push https://github.com/forker/shop.git HEAD:refs/heads/feature/a"* ]] || false
	run bash "$WT/wt.sh" add --pr 14
	[ "$status" -eq 0 ]
	[[ "$output" != *"git push"* ]] || false
	# Written like the remote's address: ssh's too
	git -C "$MAIN" remote set-url origin git@github.com:acme/shop.git
	fork_pr 15 >/dev/null
	export FAKE_PRS="15:true:main:feature/c:forker/shop"
	run bash "$WT/wt.sh" add --pr 15
	[ "$status" -eq 0 ]
	[[ "$output" == *"git push git@github.com:forker/shop.git HEAD:refs/heads/feature/c"* ]] || false
}

@test "wt add --pr still checks out a fork's pull request once the fork is deleted, with no way to push" {
	fork_pr 13 >/dev/null
	export FAKE_PRS="13:true:main:feature/a:gone"
	run bash "$WT/wt.sh" add --pr 13
	[ "$status" -eq 0 ]
	[ "$(git -C "$WT_WORKTREE_REPO_LOCATION/pr-13" config branch.pr-13.merge)" = refs/pull/13/head ]
	[[ "$output" != *"git push"* ]] || false
}

@test "wt add --pr leaves no temporary files behind" {
	export TMPDIR="$BATS_TEST_TMPDIR/tmp"
	mkdir -p "$TMPDIR"
	fork_pr 13 >/dev/null
	export FAKE_PRS="13:true:main:feature/a"
	bash "$WT/wt.sh" add --pr 13 >/dev/null 2>&1
	bash "$WT/wt.sh" add --pr 99 >/dev/null 2>&1 || true
	FAKE_GH_OFFLINE=1 bash "$WT/wt.sh" add --pr 98 >/dev/null 2>&1 || true
	bash "$WT/wt.sh" cd --pr 13 >/dev/null 2>&1
	[ -z "$(ls -A "$TMPDIR")" ]
}

@test "wt ls shows a pr-<number> branch's pull request, and how far behind its latest commit it is" {
	fork_pr 13 >/dev/null
	export FAKE_PRS="13:true:main:feature/a"
	bash "$WT/wt.sh" add --pr 13 >/dev/null 2>&1
	run bash "$WT/wt.sh" ls
	[ "$status" -eq 0 ]
	[[ "$output" == *"origin PR #13"* ]] || false
	[[ "$output" == *"2 exists, 0 deleted"* ]] || false
	# Its author pushes more: one behind, once fetched
	pr_commit 13 >/dev/null
	run bash "$WT/wt.sh" ls
	[ "$status" -eq 0 ]
	[[ "$output" == *"ahead 0, behind 1"* ]] || false
}

@test "wt cd fetches a pr-<number> branch's pull request, and wt cd --pr goes to its folder, made if need be" {
	fork_pr 13 >/dev/null
	fork_pr 15 >/dev/null
	export FAKE_PRS="13:true:main:feature/a 15:true:main:feature/c"
	bash "$WT/wt.sh" add --pr 13 >/dev/null 2>&1
	sha="$(pr_commit 13)"
	run bash "$WT/wt.sh" cd pr-13
	[ "$status" -eq 0 ]
	[[ "$output" == *"Fetched PR #13's latest commits"* ]] || false
	[[ "$output" != *"not found"* ]] || false
	git -C "$WT_WORKTREE_REPO_LOCATION/pr-13" pull -q --ff-only
	[ "$(git -C "$WT_WORKTREE_REPO_LOCATION/pr-13" rev-parse HEAD)" = "$sha" ]
	# By its number, through the function: there already, and made
	run bash -c '. "$1/wt.sh" && wt cd --pr 13 </dev/null >/dev/null && pwd' _ "$WT"
	[ "$status" -eq 0 ]
	[ "${lines[$((${#lines[@]} - 1))]}" -ef "$WT_WORKTREE_REPO_LOCATION/pr-13" ]
	run bash -c '. "$1/wt.sh" && wt cd --pr 15 </dev/null >/dev/null && pwd' _ "$WT"
	[ "$status" -eq 0 ]
	[ "${lines[$((${#lines[@]} - 1))]}" -ef "$WT_WORKTREE_REPO_LOCATION/pr-15" ]
	# A number that isn't one
	run bash "$WT/wt.sh" cd --pr x
	[ "$status" -eq 2 ]
	[[ "$output" == *"--pr takes a pull request's number, not 'x'"* ]] || false
}

@test "wt clean looks a pr-<number> branch's pull request up by its number: removed once merged, kept while open" {
	fork_pr 13 >/dev/null
	fork_pr 14 >/dev/null
	export FAKE_PRS="13:true:main:feature/a 14:true:main:feature/b"
	export FAKE_OPEN_PRS="14"
	bash "$WT/wt.sh" add --pr 13 >/dev/null 2>&1
	bash "$WT/wt.sh" add --pr 14 >/dev/null 2>&1
	run bash "$WT/wt.sh" clean --apply
	[ "$status" -eq 0 ]
	[[ "$output" == *"GONE"*"pr-13"* ]] || false
	[[ "$output" == *"KEEP"*"pr-14"*"open PR #14"* ]] || false
	[ ! -e "$WT_WORKTREE_REPO_LOCATION/pr-13" ]
	run git -C "$MAIN" show-ref --verify --quiet refs/heads/pr-13
	[ "$status" -ne 0 ]
	[ -d "$WT_WORKTREE_REPO_LOCATION/pr-14" ]
}

@test "wt add and wt cd refuse a folder that holds a different branch with the same folder name" {
	bash "$WT/wt.sh" add feature/x >/dev/null 2>&1
	run bash "$WT/wt.sh" add feature_x
	[ "$status" -ne 0 ]
	[[ "$output" == *"already holds branch feature/x, not feature_x"* ]] || false
	run bash "$WT/wt.sh" cd feature_x
	[ "$status" -ne 0 ]
	[[ "$output" == *"holds branch feature/x, not feature_x"* ]] || false
	# The right name still works
	run bash "$WT/wt.sh" add feature/x
	[ "$status" -eq 0 ]
}

@test "wt add run in the main folder puts the branch folder beside it, whatever the settings say" {
	sha="$(deleted_after_merge feature/gone 7)"
	export FAKE_MERGED_PRS="feature/gone=7"
	# Settings exported for another repo, as an rc file might
	export WT_WORKTREE_REPO_LOCATION="$BATS_TEST_TMPDIR/other"
	export WT_REPO_SLUG=acme/other
	cd "$MAIN"
	run bash "$WT/wt.sh" add feature/new
	[ "$status" -eq 0 ]
	[ "$(git -C "$BATS_TEST_TMPDIR/repo/feature_new" branch --show-current)" = feature/new ]
	[ ! -e "$BATS_TEST_TMPDIR/other" ]
	# gh is asked about main's clone, not the other repo
	run bash "$WT/wt.sh" add feature/gone
	[ "$status" -eq 0 ]
	[ "$(git -C "$BATS_TEST_TMPDIR/repo/feature_gone" rev-parse HEAD)" = "$sha" ]
}

@test "wt add in the main folder keeps WT_REPO_SLUG when the settings are this repo's" {
	sha="$(deleted_after_merge feature/gone 7)"
	export FAKE_MERGED_PRS="feature/gone=7" FAKE_GH_NEEDS_REPO=1
	cd "$MAIN"
	run bash "$WT/wt.sh" add feature/gone
	[ "$status" -eq 0 ]
	[ "$(git -C "$WT_WORKTREE_REPO_LOCATION/feature_gone" rev-parse HEAD)" = "$sha" ]
}

@test "wt ls, link, clean and rm run in the main folder work on its layout, whatever the settings say" {
	git -C "$MAIN" push -q origin main:refs/heads/feature/x 2>/dev/null
	bash "$WT/wt.sh" add feature/x >/dev/null 2>&1
	export WT_WORKTREE_REPO_LOCATION="$BATS_TEST_TMPDIR/other"
	unset WT_REPO_SLUG
	cd "$MAIN"
	run bash "$WT/wt.sh" ls --no-fetch
	[ "$status" -eq 0 ]
	[[ "$output" == *feature_x* ]] || false
	run bash "$WT/wt.sh" link --check --all --no-workspaces
	[ "$status" -eq 0 ]
	[[ "$output" == *feature_x* ]] || false
	# wt clean needs the repo: gh tells it from main's clone
	run bash "$WT/wt.sh" clean
	[ "$status" -eq 0 ]
	[[ "$output" == *"repo: acme/shop"* ]] || false
	[ -d "$BATS_TEST_TMPDIR/repo/feature_x" ]
	run bash "$WT/wt.sh" rm feature/x
	[ "$status" -eq 0 ]
	[ ! -e "$BATS_TEST_TMPDIR/repo/feature_x" ]
	[ ! -e "$BATS_TEST_TMPDIR/other" ]
}

@test "wt clean without WT_REPO_SLUG says so when gh can't tell the repo either" {
	unset WT_REPO_SLUG
	printf '#!/usr/bin/env bash\n[ "$1 $2" = "auth status" ]\n' > "$BATS_TEST_TMPDIR/bin/gh"
	run bash "$WT/wt.sh" clean
	[ "$status" -eq 2 ]
	[[ "$output" == *"WT_REPO_SLUG is not set, and gh couldn't tell the repo"* ]] || false
}

@test "the wt function's cd and main go to the main folder's layout, whatever the settings say" {
	git -C "$MAIN" push -q origin main:refs/heads/feature/x 2>/dev/null
	run bash -c 'export WT_WORKTREE_REPO_LOCATION="$2/other"; cd "$3" && . "$1/wt.sh" && wt main && echo "main at:$PWD" && wt cd feature/x >/dev/null 2>&1 && echo "cd at:$PWD"' _ "$WT" "$BATS_TEST_TMPDIR" "$MAIN"
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | sed -n 's/^main at://p')" -ef "$MAIN" ]
	[ "$(printf '%s\n' "$output" | sed -n 's/^cd at://p')" -ef "$BATS_TEST_TMPDIR/repo/feature_x" ]
}

@test "wt add needs no settings in the main folder" {
	unset WT_WORKTREE_REPO_LOCATION WT_REPO_SLUG
	cd "$MAIN"
	run bash "$WT/wt.sh" add feature/new
	[ "$status" -eq 0 ]
	[ -e "$BATS_TEST_TMPDIR/repo/feature_new/.git" ]
	# Elsewhere it still needs them, and says where it works without
	cd "$BATS_TEST_TMPDIR"
	run bash "$WT/wt.sh" add feature/other
	[ "$status" -eq 2 ]
	[[ "$output" == *"Run it in the repo's main folder"* ]] || false
}

@test "a folder named main that isn't a worktree's top doesn't count as the main folder" {
	bash "$WT/wt.sh" add feature/x >/dev/null 2>&1
	mkdir "$WT_WORKTREE_REPO_LOCATION/feature_x/main"
	cd "$WT_WORKTREE_REPO_LOCATION/feature_x/main"
	run bash "$WT/wt.sh" add feature/y
	[ "$status" -eq 0 ]
	[ -e "$WT_WORKTREE_REPO_LOCATION/feature_y/.git" ]
	[ ! -e "$WT_WORKTREE_REPO_LOCATION/feature_x/feature_y" ]
}

#   -------------------------------
#   THE WT FUNCTION
#   -------------------------------

@test "the wt function moves into the folder wt add made beside main, not the settings' location" {
	run bash -c 'export WT_WORKTREE_REPO_LOCATION="$2/other"; cd "$3" && . "$1/wt.sh" && wt add feature/new >/dev/null && pwd' _ "$WT" "$BATS_TEST_TMPDIR" "$MAIN"
	[ "$status" -eq 0 ]
	[ "${lines[$((${#lines[@]} - 1))]}" -ef "$BATS_TEST_TMPDIR/repo/feature_new" ]
}

@test "zsh's wt does the same" {
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed"
	run zsh -f -c 'export WT_WORKTREE_REPO_LOCATION="$2/other"; cd "$3" && source "$1/wt.sh" && wt add feature/new >/dev/null && pwd' _ "$WT" "$BATS_TEST_TMPDIR" "$MAIN"
	[ "$status" -eq 0 ]
	[ "${lines[$((${#lines[@]} - 1))]}" -ef "$BATS_TEST_TMPDIR/repo/feature_new" ]
}

@test "wt main says so when WT_WORKTREE_REPO_LOCATION isn't set" {
	run bash -c 'unset WT_WORKTREE_REPO_LOCATION; . "$1/wt.sh" && wt main' _ "$WT"
	[ "$status" -eq 2 ]
	[[ "$output" == *"WT_WORKTREE_REPO_LOCATION is not set"* ]] || false
}

@test "wt cd with no branch asks for one, and takes a name with & as it is" {
	git -C "$MAIN" push -q origin 'main:refs/heads/feature/fix-a&b' 2>/dev/null
	run bash -c '. "$1/wt.sh" && wt cd <<< "feature/fix-a&b" >/dev/null && pwd && git branch --show-current' _ "$WT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Branch name: "* ]] || false
	[ "${lines[$((${#lines[@]} - 2))]}" -ef "$WT_WORKTREE_REPO_LOCATION/feature_fix-a&b" ]
	[ "${lines[$((${#lines[@]} - 1))]}" = 'feature/fix-a&b' ]
	[ "$(git -C "$WT_WORKTREE_REPO_LOCATION/feature_fix-a&b" rev-parse --abbrev-ref '@{upstream}')" = 'origin/feature/fix-a&b' ]
}

@test "wt cd split at an unquoted & stops, rather than making the branch before the &" {
	# What bash does with `wt cd feature/fix-a&b`: runs `wt cd feature/fix-a` in the background
	run bash -c '. "$1/wt.sh"; wt cd feature/fix-a&b 2>&1; wait' _ "$WT"
	[[ "$output" == *"wt cd: this ran in the background or a subshell"* ]] || false
	[[ "$output" == *"paste the name when it asks"* ]] || false
	[ "$(ls "$WT_WORKTREE_REPO_LOCATION")" = main ]
	run git -C "$MAIN" show-ref --verify --quiet refs/heads/feature/fix-a
	[ "$status" -ne 0 ]
}

@test "zsh's wt stops in the background too" {
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed"
	run zsh -f -c 'source "$1/wt.sh"; wt add feature/fix-a 2>&1 & wait' _ "$WT"
	[[ "$output" == *"wt add: this ran in the background or a subshell"* ]] || false
	[ "$(ls "$WT_WORKTREE_REPO_LOCATION")" = main ]
}

@test "the wt function moves into the branch's folder after wt add --strict, and asks for the branch with only the option" {
	git -C "$MAIN" push -q origin main:refs/heads/feature/a main:refs/heads/feature/b 2>/dev/null
	run bash -c '. "$1/wt.sh" && wt add --strict feature/a >/dev/null && pwd' _ "$WT"
	[ "$status" -eq 0 ]
	[ "${lines[$((${#lines[@]} - 1))]}" -ef "$WT_WORKTREE_REPO_LOCATION/feature_a" ]
	run bash -c '. "$1/wt.sh" && wt add --strict <<< feature/b >/dev/null && pwd' _ "$WT"
	[ "$status" -eq 0 ]
	[ "${lines[$((${#lines[@]} - 1))]}" -ef "$WT_WORKTREE_REPO_LOCATION/feature_b" ]
	# Refused, it stays where it was, and gives the script's exit code (3: not on the remote), as a
	# tool running it in an interactive shell gets the function, not the script
	run bash -c 'cd "$2" && . "$1/wt.sh"; wt add --strict feature/typo 2>/dev/null; echo "status:$?"; pwd' _ "$WT" "$BATS_TEST_TMPDIR"
	[ "${lines[$((${#lines[@]} - 2))]}" = "status:3" ]
	[ "${lines[$((${#lines[@]} - 1))]}" -ef "$BATS_TEST_TMPDIR" ]
}

@test "zsh's wt gives the script's exit code too" {
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed"
	run zsh -f -c 'cd "$2" && source "$1/wt.sh"; wt add --strict feature/typo 2>/dev/null; echo "status:$?"' _ "$WT" "$BATS_TEST_TMPDIR"
	[ "${lines[$((${#lines[@]} - 1))]}" = "status:3" ]
}

@test "the wt function moves into the folder wt add --pr made, without asking for a branch" {
	fork_pr 13 >/dev/null
	git -C "$MAIN" push -q origin main:refs/heads/feature/a 2>/dev/null
	export FAKE_PRS="13:true:main:feature/a 12:false:main:feature/a"
	run bash -c '. "$1/wt.sh" && wt add --pr 13 </dev/null >/dev/null && pwd' _ "$WT"
	[ "$status" -eq 0 ]
	[ "${lines[$((${#lines[@]} - 1))]}" -ef "$WT_WORKTREE_REPO_LOCATION/pr-13" ]
	run bash -c '. "$1/wt.sh" && wt add --pr 12 </dev/null >/dev/null && pwd' _ "$WT"
	[ "$status" -eq 0 ]
	[ "${lines[$((${#lines[@]} - 1))]}" -ef "$WT_WORKTREE_REPO_LOCATION/feature_a" ]
	# Refused, it stays where it was, with the script's exit code
	run bash -c 'cd "$2" && . "$1/wt.sh"; wt add --pr 99 </dev/null 2>/dev/null; echo "status:$?"; pwd' _ "$WT" "$BATS_TEST_TMPDIR"
	[ "${lines[$((${#lines[@]} - 2))]}" = "status:3" ]
	[ "${lines[$((${#lines[@]} - 1))]}" -ef "$BATS_TEST_TMPDIR" ]
}

@test "zsh's wt moves into the folder wt add --pr made too" {
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed"
	fork_pr 13 >/dev/null
	export FAKE_PRS="13:true:main:feature/a"
	run zsh -f -c 'source "$1/wt.sh" && wt add --pr 13 </dev/null >/dev/null && pwd' _ "$WT"
	[ "$status" -eq 0 ]
	[ "${lines[$((${#lines[@]} - 1))]}" -ef "$WT_WORKTREE_REPO_LOCATION/pr-13" ]
}

@test "the wt function doesn't ask for a branch when an option is wrong, but says so at once" {
	run bash -c '. "$1/wt.sh" && wt add --stirct <<< feature/a' _ "$WT"
	[ "$status" -eq 2 ]
	[[ "$output" != *"Branch name: "* ]] || false
	[[ "$output" == *"wt-add: unknown option --stirct"* ]] || false
	run bash -c '. "$1/wt.sh" && wt cd --strict <<< feature/a' _ "$WT"
	[ "$status" -eq 2 ]
	[[ "$output" != *"Branch name: "* ]] || false
	[[ "$output" == *"wt-cd: unknown option --strict"* ]] || false
	[ "$(ls "$WT_WORKTREE_REPO_LOCATION")" = main ]
}

@test "wt add with no branch asks for one, and stops if none is given" {
	run bash -c '. "$1/wt.sh" && wt add <<< ""' _ "$WT"
	[ "$status" -eq 2 ]
	[[ "$output" == *"wt add: no branch name was given"* ]] || false
	[ "$(ls "$WT_WORKTREE_REPO_LOCATION")" = main ]
}

@test "zsh's wt asks for a branch too" {
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed"
	git -C "$MAIN" push -q origin 'main:refs/heads/fix(a);b' 2>/dev/null
	run zsh -f -c 'source "$1/wt.sh" && wt cd <<< "fix(a);b" >/dev/null && git branch --show-current' _ "$WT"
	[ "$status" -eq 0 ]
	[ "${lines[${#lines[@]} - 1]}" = 'fix(a);b' ]
}

# quote_cases <shell>: Run _wt_quote_branch_arg in <shell> on each line below, printing
# "<line> => <REPLY>", or "<line> => unchanged"
quote_cases() {
	"$1" -c '. "$1/wt.sh"; shift
		for line in "$@"; do
			REPLY=""
			if _wt_quote_branch_arg "$line"; then echo "$line => $REPLY"; else echo "$line => unchanged"; fi
		done' _ "$WT" \
		'shop-wt cd yourname/TICKET-123/Login-&-Signup-Pages' \
		'wt add fix(a);b|c' \
		'shop-wt add --strict a&b' \
		'wt add --strict' \
		'wt cd --strict a&b' \
		'  shop-wt cd a&b  ' \
		'wt cd feature/plain-name_1.2' \
		"wt cd 'a&b'" \
		'wt cd "$branch"' \
		'wt cd a\&b' \
		'wt cd a && ls' \
		'wt rm a&b' \
		'wt-x cd a&b' \
		'git cd a&b' \
		'-wt cd a&b' \
		$'wt cd a&b\nls'
}

QUOTE_EXPECTED="shop-wt cd yourname/TICKET-123/Login-&-Signup-Pages => shop-wt cd 'yourname/TICKET-123/Login-&-Signup-Pages'
wt add fix(a);b|c => wt add 'fix(a);b|c'
shop-wt add --strict a&b => shop-wt add --strict 'a&b'
wt add --strict => unchanged
wt cd --strict a&b => unchanged
  shop-wt cd a&b   => shop-wt cd 'a&b'
wt cd feature/plain-name_1.2 => unchanged
wt cd 'a&b' => unchanged
wt cd \"\$branch\" => unchanged
wt cd a\\&b => unchanged
wt cd a && ls => unchanged
wt rm a&b => unchanged
wt-x cd a&b => unchanged
git cd a&b => unchanged
-wt cd a&b => unchanged
wt cd a&b
ls => unchanged"

@test "_wt_quote_branch_arg quotes just the branch name of a wt cd or add, and only when it needs it" {
	run quote_cases bash
	[ "$status" -eq 0 ]
	[ "$output" = "$QUOTE_EXPECTED" ] || { diff <(echo "$output") <(echo "$QUOTE_EXPECTED") >&2; false; }
}

@test "_wt_quote_branch_arg does the same in zsh" {
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed"
	run quote_cases zsh
	[ "$status" -eq 0 ]
	[ "$output" = "$QUOTE_EXPECTED" ] || { diff <(echo "$output") <(echo "$QUOTE_EXPECTED") >&2; false; }
}

@test "in an interactive zsh, a <name>-wt cd with an unquoted & reaches wt as one branch name" {
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed"
	zsh -fc 'zmodload zsh/zpty' 2>/dev/null || skip "zsh has no zpty module"
	export OUT="$BATS_TEST_TMPDIR/args"
	# Type the line into a real interactive zsh, through a pseudo-terminal, so Enter goes through
	# its line editor as it would for a person. shop-wt stands in for a per-repo command. Each line
	# is typed only once zsh shows a prompt, since what's typed while it starts can be dropped.
	run zsh -fc '
		zmodload zsh/zpty
		zpty t "zsh -fi"
		screen=""
		# wait_for <pattern>: Read what zsh shows until it matches <pattern>, for up to 10 seconds
		wait_for() {
			local chunk i
			for i in {1..100}; do
				while zpty -rt t chunk 2>/dev/null; do screen+=$chunk; done
				[[ $screen == $~1 ]] && return 0
				sleep 0.1
			done
			return 1
		}
		fail() { print -r -- "$1; the terminal showed:"; print -r -- "$screen"; zpty -d t; exit 1; }
		wait_for "*[%#]*" || fail "no first prompt"
		# (The new prompt is written in two parts, so that typing it doesn'"'"'t match it)
		screen=""
		zpty -w t "PS1=\"wt-\"\"ready> \"; source \"$1/wt.sh\"; shop-wt() { print -r -- \"[\$#] \$*\" > \"\$OUT\" }"
		wait_for "*wt-ready> *" || fail "no prompt after loading wt.sh"
		zpty -w t "shop-wt cd yourname/TICKET-123/Login-&-Signup-Pages"
		# Reading what zsh shows while waiting, as a terminal would: on macOS, a pseudo-terminal holds
		# so little that zsh stalls drawing the line, before running it, until someone reads it
		for i in {1..100}; do
			while zpty -rt t chunk 2>/dev/null; do screen+=$chunk; done
			[[ -s $OUT ]] && break
			sleep 0.1
		done
		[[ -s $OUT ]] || { wait_for "*wt-ready> *wt-ready> *"; fail "shop-wt wasn'"'"'t run"; }
		zpty -d t
		cat "$OUT"' _ "$WT"
	[ "$status" -eq 0 ] || { echo "$output" | cat -v >&2; false; }
	[ "$output" = "[2] cd yourname/TICKET-123/Login-&-Signup-Pages" ]
}

@test "zsh loads wt even with FUNCTION_ARGZERO off" {
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed"
	run zsh -f -c 'unsetopt function_argzero; source "$1/wt.sh" && whence -w wt && print -r -- "$WT_DIR"' _ "$WT"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "wt: function" ]
	[ "${lines[1]}" -ef "$WT" ]
}

@test "wt link with no branch fixes the branch folder it's run in, with nothing set" {
	bash "$WT/wt.sh" add feature/x >/dev/null 2>&1
	folder="$WT_WORKTREE_REPO_LOCATION/feature_x"
	rm "$folder/node_modules"
	unset WT_WORKTREE_REPO_LOCATION WT_REPO_SLUG
	mkdir -p "$folder/src"
	cd "$folder/src"
	run bash "$WT/wt.sh" link --no-workspaces
	[ "$status" -eq 0 ]
	[[ "$output" == *"Worktree: feature_x"* ]] || false
	[ "$folder/node_modules" -ef "$MAIN/node_modules" ]
}

@test "wt link given a branch's folder fixes it, from anywhere and with nothing set" {
	bash "$WT/wt.sh" add feature/x >/dev/null 2>&1
	bash "$WT/wt.sh" add feature/y >/dev/null 2>&1
	folder="$WT_WORKTREE_REPO_LOCATION/feature_x"
	rm "$folder/node_modules" "$WT_WORKTREE_REPO_LOCATION/feature_y/node_modules"
	export WT_WORKTREE_REPO_LOCATION="$BATS_TEST_TMPDIR/other"
	unset WT_REPO_SLUG
	cd "$BATS_TEST_TMPDIR"
	run bash "$WT/wt.sh" link --no-workspaces "$folder"
	[ "$status" -eq 0 ]
	[ "$folder/node_modules" -ef "$MAIN/node_modules" ]
	# Only that one
	[ ! -e "$BATS_TEST_TMPDIR/repo/feature_y/node_modules" ]
	# And as .
	cd "$BATS_TEST_TMPDIR/repo/feature_y"
	run bash "$WT/wt.sh" link --no-workspaces .
	[ "$status" -eq 0 ]
	[ "$BATS_TEST_TMPDIR/repo/feature_y/node_modules" -ef "$MAIN/node_modules" ]
}

@test "wt link says so for the main folder, or a folder that isn't a branch's" {
	cd "$MAIN"
	run bash "$WT/wt.sh" link --no-workspaces
	[ "$status" -eq 1 ]
	[[ "$output" == *"this is the main folder, which the links point at"* ]] || false
	cd "$BATS_TEST_TMPDIR"
	run bash "$WT/wt.sh" link --no-workspaces "$MAIN"
	[ "$status" -eq 1 ]
	[[ "$output" == *"is the main folder, which the links point at"* ]] || false
	mkdir "$BATS_TEST_TMPDIR/elsewhere"
	run bash "$WT/wt.sh" link --no-workspaces "$BATS_TEST_TMPDIR/elsewhere"
	[ "$status" -eq 1 ]
	[[ "$output" == *"isn't a branch's folder beside"* ]] || false
	# With nothing set, that's still what it says, not that the location isn't set
	unset WT_WORKTREE_REPO_LOCATION
	run bash "$WT/wt.sh" link --no-workspaces "$BATS_TEST_TMPDIR/elsewhere"
	[ "$status" -eq 1 ]
	[[ "$output" == *"isn't a branch's folder beside a main folder of the same repo"* ]] || false
	[[ "$output" != *"is not set"* ]] || false
}

@test "wt link -h works with nothing set, outside any layout" {
	unset WT_WORKTREE_REPO_LOCATION
	cd "$BATS_TEST_TMPDIR"
	run bash "$WT/wt.sh" link -h
	[ "$status" -eq 0 ]
	[[ "$output" == *"Usage:"* ]] || false
	[[ "$output" == *"wt-link <folder>"* ]] || false
}

@test "the commands run in a branch's folder work on its layout, whatever the settings say" {
	git -C "$MAIN" push -q origin main:refs/heads/feature/x 2>/dev/null
	bash "$WT/wt.sh" add feature/x >/dev/null 2>&1
	export WT_WORKTREE_REPO_LOCATION="$BATS_TEST_TMPDIR/other"
	unset WT_REPO_SLUG
	mkdir -p "$BATS_TEST_TMPDIR/repo/feature_x/src"
	cd "$BATS_TEST_TMPDIR/repo/feature_x/src"
	run bash "$WT/wt.sh" add feature/y
	[ "$status" -eq 0 ]
	[ -e "$BATS_TEST_TMPDIR/repo/feature_y/.git" ]
	run bash "$WT/wt.sh" ls --no-fetch
	[ "$status" -eq 0 ]
	[[ "$output" == *feature_y* ]] || false
	[ ! -e "$BATS_TEST_TMPDIR/other" ]
	# The function's wt main goes to its main
	run bash -c '. "$1/wt.sh" && wt main && echo "main at:$PWD"' _ "$WT"
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | sed -n 's/^main at://p')" -ef "$MAIN" ]
}

@test "the commands work in the bare-repo layout's branch folders too" {
	# fe/.bare with fe/main and fe/feature_x as its worktrees
	bare="$BATS_TEST_TMPDIR/fe"
	git clone -q --bare "$BATS_TEST_TMPDIR/origin.git" "$bare/.bare" 2>/dev/null
	git -C "$bare/.bare" worktree add -q "$bare/main" main 2>/dev/null
	git -C "$bare/.bare" worktree add -q -b feature/x "$bare/feature_x" main 2>/dev/null
	unset WT_WORKTREE_REPO_LOCATION WT_REPO_SLUG
	cd "$bare/feature_x"
	run bash "$WT/wt.sh" ls --no-fetch
	[ "$status" -eq 0 ]
	[[ "$output" == *feature_x* ]] || false
	[[ "$output" == *"2 worktree(s)"* ]] || false
}

@test "a branch folder beside another repo's main folder doesn't count as its layout" {
	git init -q "$BATS_TEST_TMPDIR/mixed/main"
	git -C "$BATS_TEST_TMPDIR/mixed/main" commit -q --allow-empty -m other
	git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/mixed/shop" 2>/dev/null
	unset WT_WORKTREE_REPO_LOCATION
	cd "$BATS_TEST_TMPDIR/mixed/shop"
	run bash "$WT/wt.sh" ls --no-fetch
	[ "$status" -eq 2 ]
	[[ "$output" == *"WT_WORKTREE_REPO_LOCATION is not set"* ]] || false
}

@test "wt link --all leaves out the main folder, whatever branch it holds" {
	git -C "$MAIN" switch -q -c develop
	bash "$WT/wt.sh" add feature/x >/dev/null 2>&1
	run bash "$WT/wt.sh" link --check --all --no-workspaces
	[ "$status" -eq 0 ]
	[[ "$output" == *"Worktree: feature_x"* ]] || false
	[[ "$output" != *"Worktree: main"* ]] || false
}

#   -------------------------------
#   THE DEV BRANCH, AND SETTINGS IN GIT CONFIG
#   -------------------------------

# develop_is_default: Make develop GitHub's default branch, a commit ahead of main, as the clone
# knows it (origin/HEAD). Prints develop's commit.
develop_is_default() {
	git -C "$MAIN" switch -q -c develop
	git -C "$MAIN" commit -q --allow-empty -m "develop's work"
	git -C "$MAIN" push -q origin develop 2>/dev/null
	git -C "$MAIN" switch -q main
	git -C "$BATS_TEST_TMPDIR/origin.git" symbolic-ref HEAD refs/heads/develop
	git -C "$MAIN" remote set-head origin --auto >/dev/null
	git -C "$MAIN" rev-parse develop
}

@test "wt add makes a new branch from origin/HEAD's branch, and CURRENT_DEV_BRANCH still overrides it" {
	develop_sha="$(develop_is_default)"
	run bash "$WT/wt.sh" add feature/new
	[ "$status" -eq 0 ]
	[[ "$output" == *"from develop"* ]] || false
	[ "$(git -C "$WT_WORKTREE_REPO_LOCATION/feature_new" rev-parse HEAD)" = "$develop_sha" ]
	CURRENT_DEV_BRANCH=main run bash "$WT/wt.sh" add feature/from-main
	[ "$status" -eq 0 ]
	[ "$(git -C "$WT_WORKTREE_REPO_LOCATION/feature_from-main" rev-parse HEAD)" = "$(git -C "$MAIN" rev-parse main)" ]
}

@test "without origin/HEAD, the dev branch is main" {
	develop_is_default >/dev/null
	git -C "$MAIN" remote set-head origin -d
	run bash "$WT/wt.sh" add feature/new
	[ "$status" -eq 0 ]
	[[ "$output" == *"from main"* ]] || false
	run bash "$WT/wt.sh" config
	[[ "$output" == *"CURRENT_DEV_BRANCH"*"main"*"git remote set-head origin --auto"* ]] || false
}

@test "wt rm --branch and wt clean keep origin/HEAD's branch" {
	develop_is_default >/dev/null
	bash "$WT/wt.sh" add develop >/dev/null 2>&1
	[ -d "$WT_WORKTREE_REPO_LOCATION/develop" ]
	run bash "$WT/wt.sh" clean
	[ "$status" -eq 0 ]
	[[ "$output" == *"KEEP"*"develop"*"protected branch: develop"* ]] || false
	run bash "$WT/wt.sh" rm --branch develop
	[ "$status" -eq 0 ]
	[[ "$output" == *"Kept branch develop, as it's protected."* ]] || false
	git -C "$MAIN" show-ref --verify --quiet refs/heads/develop
}

@test "the commands use the settings in the clone's git config, with no variables set" {
	unset WT_WORKTREE_REPO_LOCATION WT_REPO_SLUG
	LOC="$BATS_TEST_TMPDIR/repo"
	develop_is_default >/dev/null
	git -C "$MAIN" remote set-head origin -d
	echo SECRET=1 > "$MAIN/.env"
	mkdir "$MAIN/.cache"
	git -C "$MAIN" config wt.devBranch develop
	git -C "$MAIN" config wt.repoSlug acme/shop
	git -C "$MAIN" config --add wt.symlinkPair .env
	git -C "$MAIN" config --add wt.symlinkPair .cache
	git -C "$MAIN" config --add wt.protectedBranch main
	git -C "$MAIN" config --add wt.protectedBranch keep/me
	cd "$MAIN"
	run bash "$WT/wt.sh" config
	echo "$output"
	[[ "$output" == *"WT_REPO_SLUG"*"acme/shop"*"(git config wt.repoSlug)"* ]] || false
	[[ "$output" == *"WT_PROTECTED_BRANCHES"*"main keep/me"*"(git config wt.protectedBranch)"* ]] || false
	[[ "$output" == *"WT_SYMLINK_PAIRS"*".env .cache"* ]] || false
	# add: from wt.devBranch, with both shared links
	run bash "$WT/wt.sh" add feature/new
	[ "$status" -eq 0 ]
	[[ "$output" == *"from develop"* ]] || false
	[ "$LOC/feature_new/.env" -ef "$MAIN/.env" ]
	[ "$LOC/feature_new/.cache" -ef "$MAIN/.cache" ]
	# link: puts a missing one back
	rm "$LOC/feature_new/.env"
	run bash "$WT/wt.sh" link "$LOC/feature_new"
	[ "$status" -eq 0 ]
	[ "$LOC/feature_new/.env" -ef "$MAIN/.env" ]
	# rm and clean: keep both protected branches, and the dev branch
	git -C "$MAIN" branch -q keep/me main
	for b in keep/me develop; do
		git -C "$MAIN" worktree add -q "$LOC/${b//\//_}" "$b"
		git -C "$MAIN" push -q -u origin "$b" 2>/dev/null
	done
	run bash "$WT/wt.sh" clean
	[ "$status" -eq 0 ]
	[[ "$output" == *"protected branch: keep/me"* ]] || false
	[[ "$output" == *"protected branch: develop"* ]] || false
	run bash "$WT/wt.sh" rm --branch keep/me
	[ "$status" -eq 0 ]
	[[ "$output" == *"Kept branch keep/me, as it's protected."* ]] || false
}

@test "settings exported for another repo don't beat this clone's git config, but this repo's own command's do" {
	echo SECRET=1 > "$MAIN/.env"
	echo OTHER=1 > "$MAIN/.other"
	git -C "$MAIN" config wt.symlinkPair .env
	cd "$MAIN"
	# Exported for another repo (its location elsewhere): git config wins
	WT_WORKTREE_REPO_LOCATION="$BATS_TEST_TMPDIR/other-repo" WT_SYMLINK_PAIRS=.other run bash "$WT/wt.sh" add feature/a
	[ "$status" -eq 0 ]
	[ -L "$BATS_TEST_TMPDIR/repo/feature_a/.env" ]
	[ ! -e "$BATS_TEST_TMPDIR/repo/feature_a/.other" ]
	# Exported with no location: git config wins too
	unset WT_WORKTREE_REPO_LOCATION
	WT_SYMLINK_PAIRS=.other run bash "$WT/wt.sh" config
	[[ "$output" == *"WT_SYMLINK_PAIRS"*".env"*"(git config wt.symlinkPair)"* ]] || false
	# This repo's own command (its location is this layout): its values win
	WT_WORKTREE_REPO_LOCATION="$BATS_TEST_TMPDIR/repo" WT_SYMLINK_PAIRS=.other run bash "$WT/wt.sh" add feature/b
	[ "$status" -eq 0 ]
	[ -L "$BATS_TEST_TMPDIR/repo/feature_b/.other" ]
	[ ! -e "$BATS_TEST_TMPDIR/repo/feature_b/.env" ]
	# A setting git config doesn't have is still taken from the variable
	git -C "$MAIN" config --unset-all wt.symlinkPair
	WT_WORKTREE_REPO_LOCATION="$BATS_TEST_TMPDIR/other-repo" WT_SYMLINK_PAIRS=.other run bash "$WT/wt.sh" add feature/c
	[ -L "$BATS_TEST_TMPDIR/repo/feature_c/.other" ]
}

@test "wt config outside a layout, with nothing set, says so" {
	unset WT_WORKTREE_REPO_LOCATION
	cd "$BATS_TEST_TMPDIR"
	run bash "$WT/wt.sh" config
	[ "$status" -eq 2 ]
	[[ "$output" == *"WT_WORKTREE_REPO_LOCATION is not set"* ]] || false
}

#   -------------------------------
#   WT RM AND WORKTREES OUTSIDE THE LAYOUT
#   -------------------------------

@test "wt rm removes a worktree made elsewhere, and --branch deletes its branch" {
	mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
	git -C "$MAIN" worktree add -q -b feature/far "$BATS_TEST_TMPDIR/elsewhere/far"
	echo change >> "$BATS_TEST_TMPDIR/elsewhere/far/.gitignore"
	cd "$MAIN"
	run bash "$WT/wt.sh" rm --yes --branch "$BATS_TEST_TMPDIR/elsewhere/far"
	[ "$status" -eq 0 ]
	[ ! -e "$BATS_TEST_TMPDIR/elsewhere/far" ]
	# Messages name it by its full path
	[[ "$output" == *"Worktree folder $BATS_TEST_TMPDIR/elsewhere/far removed."* ]] || false
	[[ "$output" == *"Branch feature/far deleted."* ]] || false
	run git -C "$MAIN" worktree list --porcelain
	[[ "$output" != *"elsewhere/far"* ]] || false
	# Without --yes, its work stops it, as for a folder beside main
	git -C "$MAIN" worktree add -q -b feature/far2 "$BATS_TEST_TMPDIR/elsewhere/far2"
	echo new > "$BATS_TEST_TMPDIR/elsewhere/far2/new-file.txt"
	run bash "$WT/wt.sh" rm "$BATS_TEST_TMPDIR/elsewhere/far2" </dev/null
	[ "$status" -eq 1 ]
	[[ "${lines[$((${#lines[@]} - 1))]}" == *"$BATS_TEST_TMPDIR/elsewhere/far2 has uncommitted changes"* ]] || false
	[ -d "$BATS_TEST_TMPDIR/elsewhere/far2" ]
}

@test "wt rm removes a worktree made elsewhere from outside any layout, with nothing set" {
	mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
	git -C "$MAIN" worktree add -q -b feature/far "$BATS_TEST_TMPDIR/elsewhere/far"
	git -C "$MAIN" config wt.protectedBranch feature/far
	unset WT_WORKTREE_REPO_LOCATION WT_REPO_SLUG
	cd "$BATS_TEST_TMPDIR"
	run bash "$WT/wt.sh" rm --branch "$BATS_TEST_TMPDIR/elsewhere/far"
	[ "$status" -eq 0 ]
	[ ! -e "$BATS_TEST_TMPDIR/elsewhere/far" ]
	# (Its clone's settings are used: the branch is protected there)
	[[ "$output" == *"Kept branch feature/far, as it's protected."* ]] || false
}

@test "wt rm removes git's record of a worktree made elsewhere that was already deleted" {
	mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
	git -C "$MAIN" worktree add -q -b feature/far "$BATS_TEST_TMPDIR/elsewhere/far"
	rm -rf "$BATS_TEST_TMPDIR/elsewhere/far"
	cd "$MAIN"
	run bash "$WT/wt.sh" rm "$BATS_TEST_TMPDIR/elsewhere/far"
	[ "$status" -eq 0 ]
	[[ "$output" == *"already deleted"* ]] || false
	run git -C "$MAIN" worktree list --porcelain
	[[ "$output" != *"elsewhere/far"* ]] || false
	# One git has no record of
	run bash "$WT/wt.sh" rm "$BATS_TEST_TMPDIR/elsewhere/never"
	[ "$status" -eq 1 ]
	[[ "$output" == *"there's no worktree at"* ]] || false
}

@test "wt rm still refuses main (by path, or a link to it), a folder that isn't a worktree, and another repo's" {
	cd "$MAIN"
	run bash "$WT/wt.sh" rm "$MAIN"
	[ "$status" -eq 1 ]
	[[ "$output" == *"won't delete the main folder"* ]] || false
	ln -s "$MAIN" "$BATS_TEST_TMPDIR/link-to-main"
	run bash "$WT/wt.sh" rm "$BATS_TEST_TMPDIR/link-to-main"
	[ "$status" -eq 1 ]
	[[ "$output" == *"won't delete the main folder"* ]] || false
	# The main worktree, whatever it's called, outside any layout
	unset WT_WORKTREE_REPO_LOCATION
	cd "$BATS_TEST_TMPDIR"
	run bash "$WT/wt.sh" rm "$MAIN"
	[ "$status" -eq 1 ]
	[[ "$output" == *"won't delete the main folder"* ]] || false
	[ -d "$MAIN/.git" ]
	cd "$MAIN"
	# A plain folder
	mkdir "$BATS_TEST_TMPDIR/plain"
	run bash "$WT/wt.sh" rm "$BATS_TEST_TMPDIR/plain"
	[ "$status" -eq 1 ]
	[[ "$output" == *"isn't a worktree of a git repo"* ]] || false
	[ -d "$BATS_TEST_TMPDIR/plain" ]
	# Another repo's worktree, run in this repo's folder
	git init -q "$BATS_TEST_TMPDIR/other"
	git -C "$BATS_TEST_TMPDIR/other" commit -q --allow-empty -m init
	git -C "$BATS_TEST_TMPDIR/other" worktree add -q -b x "$BATS_TEST_TMPDIR/other-x"
	run bash "$WT/wt.sh" rm --yes "$BATS_TEST_TMPDIR/other-x"
	[ "$status" -eq 1 ]
	[[ "$output" == *"is a worktree of a different repo than"* ]] || false
	[ -d "$BATS_TEST_TMPDIR/other-x" ]
}

@test "wt link fixes a worktree of the repo made elsewhere, but not another repo's" {
	mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
	git -C "$MAIN" worktree add -q -b feature/far "$BATS_TEST_TMPDIR/elsewhere/far"
	cd "$MAIN"
	run bash "$WT/wt.sh" link --no-workspaces "$BATS_TEST_TMPDIR/elsewhere/far"
	[ "$status" -eq 0 ]
	[ "$BATS_TEST_TMPDIR/elsewhere/far/node_modules" -ef "$MAIN/node_modules" ]
	git init -q "$BATS_TEST_TMPDIR/other"
	run bash "$WT/wt.sh" link --no-workspaces "$BATS_TEST_TMPDIR/other"
	[ "$status" -eq 1 ]
	[[ "$output" == *"isn't a branch's folder beside"* ]] || false
}

#   -------------------------------
#   --PORCELAIN
#   -------------------------------

# porcelain_run <args...>: wt with stdout and stderr apart: sets status, out, err
porcelain_run() {
	status=0
	out="$(bash "$WT/wt.sh" "$@" 2>"$BATS_TEST_TMPDIR/err" </dev/null)" || status=$?
	err="$(cat "$BATS_TEST_TMPDIR/err")"
}

@test "wt add --porcelain prints only the worktree's full path, also when it already exists" {
	git -C "$MAIN" push -q origin main:refs/heads/feature/a 2>/dev/null
	porcelain_run add --porcelain feature/a
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ]
	[ "$out" -ef "$WT_WORKTREE_REPO_LOCATION/feature_a" ]
	case "$out" in /* | [A-Za-z]:*) ;; *) false ;; esac
	[[ "$err" == *"Creating worktree tracking it"* ]] || false
	# Again: it's there already
	porcelain_run add feature/a --porcelain --strict
	[ "$status" -eq 0 ]
	[ "$out" -ef "$WT_WORKTREE_REPO_LOCATION/feature_a" ]
	[[ "$err" == *"already exists"* ]] || false
	# Exit codes are the same, with nothing on stdout
	porcelain_run add --porcelain --strict feature/missing
	[ "$status" -eq 3 ]
	[ -z "$out" ]
	porcelain_run add --porcelain --bogus x
	[ "$status" -eq 2 ]
	[ -z "$out" ]
}

@test "wt add --pr --porcelain and wt cd --porcelain print the folder too" {
	command -v jq >/dev/null 2>&1 || skip "jq isn't installed, for the tests' gh"
	fork_pr 13 >/dev/null
	export FAKE_PRS="13:true:main:feature/x"
	porcelain_run add --pr 13 --porcelain
	[ "$status" -eq 0 ]
	[ "$out" -ef "$WT_WORKTREE_REPO_LOCATION/pr-13" ]
	git -C "$MAIN" push -q origin main:refs/heads/feature/b 2>/dev/null
	porcelain_run cd --porcelain feature/b
	[ "$status" -eq 0 ]
	[ "$out" -ef "$WT_WORKTREE_REPO_LOCATION/feature_b" ]
	porcelain_run cd feature/b --porcelain
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ]
	[ "$out" -ef "$WT_WORKTREE_REPO_LOCATION/feature_b" ]
}

@test "the wt function doesn't move the terminal with --porcelain, and prints the path" {
	run bash -c '. "$1/wt.sh" && cd "$2" && wt add --porcelain feature/p 2>/dev/null && pwd' _ "$WT" "$MAIN"
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 2 ]
	[ "${lines[0]}" -ef "$WT_WORKTREE_REPO_LOCATION/feature_p" ]
	[ "${lines[1]}" -ef "$MAIN" ]
	run zsh -f -c 'source "$1/wt.sh" && cd "$2" && wt cd --porcelain feature/p 2>/dev/null && pwd' _ "$WT" "$MAIN"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" -ef "$WT_WORKTREE_REPO_LOCATION/feature_p" ]
	[ "${lines[1]}" -ef "$MAIN" ]
}

@test "wt link, run in a worktree git made at ../feature/x (outside the layout), finds the layout" {
	unset WT_WORKTREE_REPO_LOCATION WT_REPO_SLUG
	git -C "$MAIN" worktree add -q -b feature/x "$BATS_TEST_TMPDIR/repo/feature/x"
	cd "$BATS_TEST_TMPDIR/repo/feature/x"
	run bash "$WT/wt.sh" link --no-workspaces
	[ "$status" -eq 0 ]
	[ "$BATS_TEST_TMPDIR/repo/feature/x/node_modules" -ef "$MAIN/node_modules" ]
	run bash "$WT/wt.sh" config
	[[ "$output" == *"WT_WORKTREE_REPO_LOCATION"*"$BATS_TEST_TMPDIR/repo"* ]] || false
	# And wt rm takes it, from main
	cd "$MAIN"
	run bash "$WT/wt.sh" rm --yes --branch "$BATS_TEST_TMPDIR/repo/feature/x"
	[ "$status" -eq 0 ]
	[ ! -e "$BATS_TEST_TMPDIR/repo/feature/x" ]
}
