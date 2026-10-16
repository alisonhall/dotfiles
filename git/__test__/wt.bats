#!/usr/bin/env bats
# Tests for the wt commands (git/wt/), against a local "GitHub" repo and a fake gh.

setup() {
	WT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/wt"
	export HOME="$BATS_TEST_TMPDIR/home"
	export GIT_CONFIG_NOSYSTEM=1
	unset GIT_CONFIG_GLOBAL
	mkdir -p "$HOME"
	git config --global user.name Test
	git config --global user.email test@example.com
	git config --global init.defaultBranch main

	# The "GitHub" repo, and the folder wt manages, with its clone in main/
	git init -q --bare "$BATS_TEST_TMPDIR/origin.git"
	export WT_WORKTREE_REPO_LOCATION="$BATS_TEST_TMPDIR/repo"
	export WT_REPO_SLUG=acme/shop
	MAIN="$WT_WORKTREE_REPO_LOCATION/main"
	git clone -q "$BATS_TEST_TMPDIR/origin.git" "$MAIN" 2>/dev/null
	printf 'node_modules\n.env\n' > "$MAIN/.gitignore"
	git -C "$MAIN" add .gitignore
	git -C "$MAIN" commit -q -m init
	git -C "$MAIN" push -q origin main

	# main's dependencies, which branch folders share
	mkdir -p "$MAIN/node_modules/pkg"
	echo 'module.exports = 42' > "$MAIN/node_modules/pkg/index.js"

	# A gh that's logged in. Asked for every pull request of a branch (wt clean), it says each
	# existing branch's was merged at its current commit (a branch that doesn't exist yet has
	# none). Asked for merged ones only (wt add and wt cd), it lists those in FAKE_MERGED_PRS
	# ("<branch>=<number> ..."). Like the real gh, it needs --repo outside a clone.
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	cat > "$BATS_TEST_TMPDIR/bin/gh" <<-'EOF'
		#!/usr/bin/env bash
		case "$1 $2" in
			"auth status") exit 0 ;;
			"pr list")
				repo="" state="" head=""
				while [ $# -gt 0 ]; do
					case "$1" in
						--repo) repo="$2" ;;
						--state) state="$2" ;;
						--head) head="$2" ;;
					esac
					shift
				done
				if [ -z "$repo" ] && ! git rev-parse --git-dir >/dev/null 2>&1; then
					echo "failed to run git: fatal: not a git repository" >&2
					exit 1
				fi
				if [ "$state" = merged ]; then
					for pr in ${FAKE_MERGED_PRS:-}; do
						[ "${pr%%=*}" = "$head" ] && echo "${pr#*=}"
					done
				else
					oid="$(git -C "$WT_WORKTREE_REPO_LOCATION/main" rev-parse --verify --quiet "refs/heads/$head")" &&
						printf '1\tMERGED\t%s\n' "$oid"
				fi
				;;
			*) exit 1 ;;
		esac
	EOF
	chmod +x "$BATS_TEST_TMPDIR/bin/gh"
	export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

teardown() {
	release_folder
}

# hold_folder <folder>: On Windows, keep a program in the folder, as an editor or a terminal
# would, until release_folder. (It has to be a Windows program: Git Bash's own processes don't
# stop a folder being renamed.)
hold_folder() {
	local waited=0
	(cd "$1" && exec powershell.exe -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 120") >/dev/null 2>&1 3>&- &
	HOLDER=$!
	# Wait until the folder is in use (PowerShell can take a while to start on a busy machine)
	while [ "$waited" -lt 30 ]; do
		mv "$1" "$1.check" 2>/dev/null || return 0
		mv "$1.check" "$1"
		sleep 1
		waited=$((waited + 1))
	done
	echo "hold_folder: $1 still isn't in use" >&2
	return 1
}

release_folder() {
	[ -n "${HOLDER:-}" ] || return 0
	kill "$HOLDER" 2>/dev/null
	wait "$HOLDER" 2>/dev/null || true
	HOLDER=""
}

is_windows() {
	case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) return 0 ;; esac
	return 1
}

# link_dir <target> <link>: Link to a folder the way Windows users get by default: a junction there,
# a symlink elsewhere
link_dir() {
	if is_windows; then
		MSYS2_ARG_CONV_EXCL="*" cmd /c mklink /J "$(cygpath -w "$2")" "$(cygpath -w "$1")" >/dev/null
	else
		ln -s "$1" "$2"
	fi
}

# merged_branch <branch>: A branch folder for <branch>, pushed, with a node_modules link to main's
merged_branch() {
	local folder="$WT_WORKTREE_REPO_LOCATION/${1//\//_}"
	git -C "$MAIN" worktree add -q -b "$1" "$folder"
	git -C "$folder" commit -q --allow-empty -m "work on $1"
	git -C "$folder" push -q -u origin "$1" 2>/dev/null
	link_dir "$MAIN/node_modules" "$folder/node_modules"
	[ -f "$folder/node_modules/pkg/index.js" ]
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

@test "wt rm won't delete the main folder" {
	run bash "$WT/wt.sh" rm main
	[ "$status" -ne 0 ]
	[[ "$output" == *"won't delete the main folder"* ]] || false
	[ -d "$MAIN/.git" ]
}

@test "wt rm won't take anything git wouldn't accept as a branch name, like . or .." {
	for name in . .. .git feature/.hidden; do
		run bash "$WT/wt.sh" rm "$name"
		[ "$status" -ne 0 ]
		[[ "$output" == *"isn't a branch name"* ]] || false
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
	run bash "$WT/wt.sh" rm feature/busy
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

#   -------------------------------
#   THE MAIN FOLDER'S BRANCH
#   -------------------------------

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
	[[ "$output" == *"set"*"CURRENT_DEV_BRANCH"* ]] || false
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

#   -------------------------------
#   THE WT FUNCTION
#   -------------------------------

@test "wt main says so when WT_WORKTREE_REPO_LOCATION isn't set" {
	run bash -c 'unset WT_WORKTREE_REPO_LOCATION; . "$1/wt.sh" && wt main' _ "$WT"
	[ "$status" -eq 2 ]
	[[ "$output" == *"WT_WORKTREE_REPO_LOCATION is not set"* ]] || false
}

@test "zsh loads wt even with FUNCTION_ARGZERO off" {
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed"
	run zsh -f -c 'unsetopt function_argzero; source "$1/wt.sh" && whence -w wt && print -r -- "$WT_DIR"' _ "$WT"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "wt: function" ]
	[ "${lines[1]}" -ef "$WT" ]
}
