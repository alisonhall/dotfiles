#!/usr/bin/env bats
# Tests for wt rm and wt link on worktrees made outside the layout (git/wt/), against a local "GitHub" repo and a fake gh.

load wt-fixture

setup() {
	wt_fixture_setup
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
	# Git Bash's ln -s copies, so there's no link to follow on Windows
	if ! is_windows; then
		ln -s "$MAIN" "$BATS_TEST_TMPDIR/link-to-main"
		run bash "$WT/wt.sh" rm "$BATS_TEST_TMPDIR/link-to-main"
		[ "$status" -eq 1 ]
		[[ "$output" == *"won't delete the main folder"* ]] || false
	fi
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

@test "wt link, run in a worktree git made at ../feature/x (outside the layout), finds the layout" {
	unset WT_WORKTREE_REPO_LOCATION WT_REPO_SLUG
	git -C "$MAIN" worktree add -q -b feature/x "$BATS_TEST_TMPDIR/repo/feature/x"
	cd "$BATS_TEST_TMPDIR/repo/feature/x"
	run bash "$WT/wt.sh" link --no-workspaces
	[ "$status" -eq 0 ]
	[ "$BATS_TEST_TMPDIR/repo/feature/x/node_modules" -ef "$MAIN/node_modules" ]
	run bash "$WT/wt.sh" config
	# (Compared as folders: Windows' git spells the path as C:/...)
	location="$(printf '%s\n' "$output" | sed -n 's/^WT_WORKTREE_REPO_LOCATION  *\(.*\)  (.*$/\1/p')"
	[ -n "$location" ] && [ "$location" -ef "$BATS_TEST_TMPDIR/repo" ]
	# And wt rm takes it, from main
	cd "$MAIN"
	run bash "$WT/wt.sh" rm --yes --branch "$BATS_TEST_TMPDIR/repo/feature/x"
	[ "$status" -eq 0 ]
	[ ! -e "$BATS_TEST_TMPDIR/repo/feature/x" ]
}
