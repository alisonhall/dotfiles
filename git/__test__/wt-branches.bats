#!/usr/bin/env bats
# Tests for wt's branch names and folders: wt add --strict and --pr, and the folder a branch gets (git/wt/), against a local "GitHub" repo and a fake gh.

load wt-fixture

setup() {
	wt_fixture_setup
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
