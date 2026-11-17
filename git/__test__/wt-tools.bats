#!/usr/bin/env bats
# Tests for wt as other tools run it, such as view-prs-dashboard: the wt function, in an
# interactive shell (bash -ic, or zsh -ic) that loaded it from the rc file, with no terminal
# (stdin from /dev/null), run in the repo's main folder with no WT_* settings. Each command runs
# under a time limit, so one that waits for an answer fails rather than hanging the run. Also the
# failure contract: the exit code, nothing about the failure on stdout, and a last line on stderr
# that says what went wrong.

load wt-fixture

setup() {
	wt_fixture_setup
	# As a tool's shell: wt from the rc file, and no settings (wt finds the layout from the folder)
	printf '. "%s/wt.sh"\n' "$WT" > "$HOME/.bashrc"
	printf 'source "%s/wt.sh"\n' "$WT" > "$HOME/.zshrc"
	unset WT_WORKTREE_REPO_LOCATION WT_REPO_SLUG
	LOCATION="$BATS_TEST_TMPDIR/repo"
	cd "$MAIN"
}

# with_timeout <seconds> <command...>: The command, stopped once the time is up. (macOS has no
# timeout command; perl's alarm outlasts exec, so it stops the command just the same.)
with_timeout() {
	if command -v timeout >/dev/null 2>&1; then
		timeout "$@"
	else
		perl -e 'alarm shift @ARGV; exec @ARGV or die "exec: $!"' "$@"
	fi
}

# capture <command...>: Runs the command with no terminal and a time limit. Sets status, stdout,
# stderr and last_err (stderr's last line that isn't empty).
capture() {
	status=0
	with_timeout 60 "$@" </dev/null >"$BATS_TEST_TMPDIR/stdout" 2>"$BATS_TEST_TMPDIR/stderr" || status=$?
	stdout="$(cat "$BATS_TEST_TMPDIR/stdout")"
	stderr="$(cat "$BATS_TEST_TMPDIR/stderr")"
	last_err="$(grep -v '^[[:space:]]*$' "$BATS_TEST_TMPDIR/stderr" | tail -n 1)"
	# (Shown beside a test that fails)
	printf 'exit %s\n--- stdout:\n%s\n--- stderr:\n%s\n' "$status" "$stdout" "$stderr"
}

# as_tool <shell> <command line>: The command line, as view-prs-dashboard runs it: in an
# interactive bash or zsh, so the wt function from the rc file is there
as_tool() {
	capture "$1" -ic "$2"
}

needs_shell() {
	command -v "$1" >/dev/null 2>&1 || skip "$1 isn't installed"
}

# no_errors_on_stdout: stdout has none of wt's (or git's) failure lines - they all go to stderr
no_errors_on_stdout() {
	run grep -E '^(wt[- ][a-z]+:|error:|fatal:|Usage:)' <<< "$stdout"
	[ "$status" -ne 0 ]
}

# fails_with <code> <text>: The command failed with that exit code, saying so only on stderr, and
# stderr's last line has the text in it
fails_with() {
	[ "$status" -eq "$1" ]
	[[ "$last_err" == *"$2"* ]] || false
	local code="$status"
	no_errors_on_stdout
	status="$code"
}

# --- the dashboard's four commands, in bash and zsh ----------------------------------------------

checkout_strict() {
	git -C "$MAIN" push -q origin main:refs/heads/feature/a 2>/dev/null
	as_tool "$1" 'wt add feature/a --strict'
	[ "$status" -eq 0 ]
	[ "$(git -C "$LOCATION/feature_a" rev-parse --abbrev-ref '@{upstream}')" = origin/feature/a ]
	# A branch that isn't on GitHub: 3, making nothing
	as_tool "$1" 'wt add feature/missing --strict'
	fails_with 3 "isn't on origin"
	[ ! -e "$LOCATION/feature_missing" ]
}
@test "bash: wt add <branch> --strict makes a worktree tracking the branch, or exits 3 when it isn't there" {
	checkout_strict bash
}
@test "zsh: wt add <branch> --strict makes a worktree tracking the branch, or exits 3 when it isn't there" {
	needs_shell zsh
	checkout_strict zsh
}

checkout_pr() {
	git -C "$MAIN" push -q origin main:refs/heads/feature/b main:refs/pull/12/head 2>/dev/null
	fork_pr 13 >/dev/null
	export FAKE_PRS="12:false:main:feature/b 13:true:main:feature/x"
	as_tool "$1" 'wt add --pr 12'
	[ "$status" -eq 0 ]
	[ "$(git -C "$LOCATION/feature_b" rev-parse --abbrev-ref '@{upstream}')" = origin/feature/b ]
	as_tool "$1" 'wt add --pr 13'
	[ "$status" -eq 0 ]
	[ "$(git -C "$LOCATION/pr-13" config branch.pr-13.merge)" = refs/pull/13/head ]
	as_tool "$1" 'wt add --pr 99'
	fails_with 3 "no pull request #99"
}
@test "bash: wt add --pr checks out this repo's and a fork's pull request" {
	command -v jq >/dev/null 2>&1 || skip "jq isn't installed, for the tests' gh"
	checkout_pr bash
}
@test "zsh: wt add --pr checks out this repo's and a fork's pull request" {
	needs_shell zsh
	command -v jq >/dev/null 2>&1 || skip "jq isn't installed, for the tests' gh"
	checkout_pr zsh
}

link_after_checkout() {
	git -C "$MAIN" push -q origin main:refs/heads/feature/a 2>/dev/null
	git -C "$MAIN" fetch -q origin feature/a
	git -C "$MAIN" worktree add -q --track -b feature/a "$LOCATION/feature_a" origin/feature/a
	cd "$LOCATION/feature_a"
	as_tool "$1" 'wt link'
	[ "$status" -eq 0 ]
	[ "$LOCATION/feature_a/node_modules" -ef "$MAIN/node_modules" ]
}
@test "bash: wt link, run in a worktree git made, links it to main" {
	link_after_checkout bash
}
@test "zsh: wt link, run in a worktree git made, links it to main" {
	needs_shell zsh
	link_after_checkout zsh
}

clean_list() {
	WT_WORKTREE_REPO_LOCATION="$LOCATION" merged_branch feature/done
	WT_WORKTREE_REPO_LOCATION="$LOCATION" merged_branch feature/also-done
	as_tool "$1" 'wt clean --porcelain'
	[ "$status" -eq 0 ]
	# Only the folders, full paths, one per line; the report is on stderr
	[ "$(printf '%s\n' "$stdout" | wc -l | tr -d ' ')" -eq 2 ]
	local line
	while IFS= read -r line; do
		case "$line" in /* | [A-Za-z]:*) ;; *) false ;; esac
		[ -d "$line" ]
	done <<< "$stdout"
	[[ "$stderr" == *"Would remove: 2"* ]] || false
	# It changed nothing
	[ -d "$LOCATION/feature_done" ] && [ -d "$LOCATION/feature_also-done" ]
}
@test "bash: wt clean --porcelain prints only the folders it would remove, changing nothing" {
	clean_list bash
}
@test "zsh: wt clean --porcelain prints only the folders it would remove, changing nothing" {
	needs_shell zsh
	clean_list zsh
}

clean_remove() {
	WT_WORKTREE_REPO_LOCATION="$LOCATION" merged_branch feature/a
	echo change >> "$LOCATION/feature_a/.gitignore"
	export VIEW_PRS_WORKTREE="$LOCATION/feature_a"
	# Without --yes: it can't ask, so it stops at once, deleting nothing
	as_tool "$1" 'wt rm --branch "$VIEW_PRS_WORKTREE"'
	fails_with 1 "Add --yes to delete it anyway."
	[ -d "$LOCATION/feature_a" ]
	# With it: gone, branch and all
	as_tool "$1" 'wt rm --yes --branch "$VIEW_PRS_WORKTREE"'
	[ "$status" -eq 0 ]
	[ ! -e "$LOCATION/feature_a" ]
	run git -C "$MAIN" show-ref --verify --quiet refs/heads/feature/a
	[ "$status" -ne 0 ]
}
@test "bash: wt rm --yes --branch <folder> removes a worktree with changes without asking; without --yes it stops" {
	clean_remove bash
}
@test "zsh: wt rm --yes --branch <folder> removes a worktree with changes without asking; without --yes it stops" {
	needs_shell zsh
	clean_remove zsh
}

no_branch() {
	as_tool "$1" 'wt add'
	fails_with 2 "no branch name was given"
	[ "$(ls "$LOCATION")" = main ]
}
@test "bash: wt add with no branch and no terminal stops at once" {
	no_branch bash
}
@test "zsh: wt add with no branch and no terminal stops at once" {
	needs_shell zsh
	no_branch zsh
}

# --- failures: exit code, nothing on stdout, and the reason last ---------------------------------

@test "wt rm's failures: exit code, stderr only, and the reason on the last line" {
	WT_WORKTREE_REPO_LOCATION="$LOCATION" merged_branch feature/a
	echo new > "$LOCATION/feature_a/new-file.txt"
	capture bash "$WT/wt.sh" rm main
	fails_with 1 "won't delete the main folder"
	capture bash "$WT/wt.sh" rm "$MAIN"
	fails_with 1 "won't delete the main folder"
	capture bash "$WT/wt.sh" rm 'bad..name'
	fails_with 1 "isn't a branch name, so nothing was deleted"
	capture bash "$WT/wt.sh" rm feature/tpyo
	fails_with 1 "there's no worktree for feature/tpyo"
	capture bash "$WT/wt.sh" rm feature/a
	fails_with 1 "feature_a has uncommitted changes, and with no terminal to ask in, nothing was deleted. Add --yes to delete it anyway."
	capture bash "$WT/wt.sh" rm --bogus feature/a
	fails_with 2 "unknown option --bogus"
	capture bash "$WT/wt.sh" rm
	fails_with 2 "name one branch or folder"
	[ -d "$LOCATION/feature_a" ]
}

@test "wt add's and wt cd's failures: exit code, stderr only, and the reason on the last line" {
	bash "$WT/wt.sh" add feature/x >/dev/null 2>&1
	capture bash "$WT/wt.sh" add feature_x
	fails_with 1 "already holds branch feature/x, not feature_x, so nothing was made"
	mkdir "$LOCATION/stray"
	capture bash "$WT/wt.sh" add stray
	fails_with 1 "already exists but isn't a worktree, so nothing was made"
	capture bash "$WT/wt.sh" add --strict feature/missing
	fails_with 3 "isn't on origin"
	capture bash "$WT/wt.sh" add --pr abc
	fails_with 2 "--pr takes a pull request's number"
	capture bash "$WT/wt.sh" add --bogus feature/a
	fails_with 2 "unknown option --bogus"
	capture bash "$WT/wt.sh" add
	fails_with 2 "give one branch name, or --pr <number>"
	capture bash "$WT/wt.sh" cd --strict
	fails_with 2 "unknown option --strict"
	capture bash "$WT/wt.sh" cd feature_x
	fails_with 1 "holds branch feature/x, not feature_x"
}

@test "the other commands' failures: exit code, stderr only, and the reason on the last line" {
	capture bash "$WT/wt.sh" link
	fails_with 1 "this is the main folder"
	capture bash "$WT/wt.sh" link --bogus
	fails_with 2 "unknown option --bogus"
	capture bash "$WT/wt.sh" ls --bogus
	fails_with 2 "unknown option --bogus"
	capture bash "$WT/wt.sh" clean --bogus
	fails_with 2 "unknown option --bogus"
	capture bash "$WT/wt.sh" clean --porcelain --apply
	fails_with 2 "can't be used with --apply"
	capture bash "$WT/wt.sh" bogus
	fails_with 2 "unknown command 'bogus'"
	# Outside any layout, with nothing set
	cd "$BATS_TEST_TMPDIR"
	local command
	for command in "add feature/a" "rm feature/a" "link feature/a" ls clean; do
		# shellcheck disable=SC2086 # (the command and its argument)
		capture bash "$WT/wt.sh" $command
		fails_with 2 "WT_WORKTREE_REPO_LOCATION is not set"
	done
}

# --- worktrees git made elsewhere, and --porcelain -----------------------------------------------

remove_elsewhere() {
	mkdir -p "$BATS_TEST_TMPDIR/dashboard"
	git -C "$MAIN" worktree add -q -b feature/d "$BATS_TEST_TMPDIR/dashboard/feature-d"
	echo change >> "$BATS_TEST_TMPDIR/dashboard/feature-d/.gitignore"
	export VIEW_PRS_WORKTREE="$BATS_TEST_TMPDIR/dashboard/feature-d"
	as_tool "$1" 'wt rm --yes --branch "$VIEW_PRS_WORKTREE"'
	[ "$status" -eq 0 ]
	[ ! -e "$BATS_TEST_TMPDIR/dashboard/feature-d" ]
	run git -C "$MAIN" show-ref --verify --quiet refs/heads/feature/d
	[ "$status" -ne 0 ]
}
@test "bash: wt rm --yes --branch removes a worktree git made outside the layout" {
	remove_elsewhere bash
}
@test "zsh: wt rm --yes --branch removes a worktree git made outside the layout" {
	needs_shell zsh
	remove_elsewhere zsh
}

add_porcelain() {
	git -C "$MAIN" push -q origin main:refs/heads/feature/a 2>/dev/null
	as_tool "$1" 'wt add feature/a --strict --porcelain'
	[ "$status" -eq 0 ]
	[ "$stdout" -ef "$LOCATION/feature_a" ]
	[ "$(printf '%s\n' "$stdout" | wc -l | tr -d ' ')" -eq 1 ]
}
@test "bash: wt add --strict --porcelain prints only the folder" {
	add_porcelain bash
}
@test "zsh: wt add --strict --porcelain prints only the folder" {
	needs_shell zsh
	add_porcelain zsh
}
