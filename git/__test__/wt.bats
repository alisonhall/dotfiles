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

	# A gh that's logged in, and says every existing branch's pull request was merged at its
	# current commit (a branch that doesn't exist yet has no pull request)
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	cat > "$BATS_TEST_TMPDIR/bin/gh" <<-'EOF'
		#!/usr/bin/env bash
		case "$1 $2" in
			"auth status") exit 0 ;;
			"pr list")
				while [ $# -gt 0 ]; do [ "$1" = --head ] && head="$2"; shift; done
				oid="$(git -C "$WT_WORKTREE_REPO_LOCATION/main" rev-parse --verify --quiet "refs/heads/$head")" &&
					printf '1\tMERGED\t%s\n' "$oid"
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
	local i
	(cd "$1" && exec powershell.exe -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 60") >/dev/null 2>&1 3>&- &
	HOLDER=$!
	# Wait until the folder is in use
	for i in 1 2 3 4 5 6 7 8 9 10; do
		mv "$1" "$1.check" 2>/dev/null || return 0
		mv "$1.check" "$1"
		sleep 1
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

@test "wt rm says so when the branch has no folder" {
	run bash "$WT/wt.sh" rm feature/nothing
	[ "$status" -ne 0 ]
	[[ "$output" == *"there's no folder feature_nothing"* ]] || false
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
