#!/usr/bin/env bats
# Tests for wt's dev branch and its settings in git config (git/wt/), against a local "GitHub" repo and a fake gh.

load wt-fixture

setup() {
	wt_fixture_setup
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
	# Another repo's settings are ignored even where git config has nothing
	git -C "$MAIN" config --unset-all wt.symlinkPair
	WT_WORKTREE_REPO_LOCATION="$BATS_TEST_TMPDIR/other-repo" WT_SYMLINK_PAIRS=.other run bash "$WT/wt.sh" add feature/c
	[ "$status" -eq 0 ]
	[ ! -e "$BATS_TEST_TMPDIR/repo/feature_c/.other" ]
	# With no location, a variable git config doesn't have is still used
	unset WT_WORKTREE_REPO_LOCATION
	WT_SYMLINK_PAIRS=.other run bash "$WT/wt.sh" add feature/d
	[ "$status" -eq 0 ]
	[ -L "$BATS_TEST_TMPDIR/repo/feature_d/.other" ]
}

@test "a WT_WORKTREE_REPO_LOCATION that doesn't exist is warned about on stderr, but another repo's isn't" {
	cd "$MAIN"
	WT_WORKTREE_REPO_LOCATION="$BATS_TEST_TMPDIR/typo" bash "$WT/wt.sh" config >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err"
	grep -q "WT_WORKTREE_REPO_LOCATION is $BATS_TEST_TMPDIR/typo, which doesn't exist" "$BATS_TEST_TMPDIR/err"
	run grep -q warning "$BATS_TEST_TMPDIR/out"
	[ "$status" -eq 1 ]
	mkdir "$BATS_TEST_TMPDIR/other-repo"
	WT_WORKTREE_REPO_LOCATION="$BATS_TEST_TMPDIR/other-repo" bash "$WT/wt.sh" config >/dev/null 2>"$BATS_TEST_TMPDIR/err"
	[ ! -s "$BATS_TEST_TMPDIR/err" ]
}

@test "another repo's dev branch, remote and protected branches don't apply in this layout" {
	cd "$MAIN"
	export WT_WORKTREE_REPO_LOCATION="$BATS_TEST_TMPDIR/other-repo"
	export CURRENT_DEV_BRANCH=develop CURRENT_REMOTE_NAME=upstream WT_PROTECTED_BRANCHES=release
	run bash "$WT/wt.sh" config
	[ "$status" -eq 0 ]
	[[ "$output" != *develop* ]] || false
	[[ "$output" != *upstream* ]] || false
	[[ "$output" != *release* ]] || false
	# A new branch starts from this repo's main, not the other repo's develop
	run bash "$WT/wt.sh" add feature/new
	[ "$status" -eq 0 ]
	[[ "$output" != *develop* ]] || false
	[ "$(git -C "$BATS_TEST_TMPDIR/repo/feature_new" rev-parse HEAD)" = "$(git -C "$MAIN" rev-parse main)" ]
}

@test "wt config outside a layout, with nothing set, says so" {
	unset WT_WORKTREE_REPO_LOCATION
	cd "$BATS_TEST_TMPDIR"
	run bash "$WT/wt.sh" config
	[ "$status" -eq 2 ]
	[[ "$output" == *"WT_WORKTREE_REPO_LOCATION is not set"* ]] || false
}
