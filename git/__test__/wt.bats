#!/usr/bin/env bats
# Tests for wt add, rm, ls and clean on branch folders (git/wt/), against a local "GitHub" repo and a fake gh.

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
