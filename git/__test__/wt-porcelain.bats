#!/usr/bin/env bats
# Tests for wt add and wt cd --porcelain (git/wt/), against a local "GitHub" repo and a fake gh.

load wt-fixture

setup() {
	wt_fixture_setup
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
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed (the bash half passed)"
	run zsh -f -c 'source "$1/wt.sh" && cd "$2" && wt cd --porcelain feature/p 2>/dev/null && pwd' _ "$WT" "$MAIN"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" -ef "$WT_WORKTREE_REPO_LOCATION/feature_p" ]
	[ "${lines[1]}" -ef "$MAIN" ]
}
