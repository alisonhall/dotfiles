#!/usr/bin/env bash
# wt-cd.sh — navigate to a worktree folder and fetch its remote branch.
# If the folder does not exist yet, delegate to wt-add.sh to create it.
# Invoked by the wt function (git/wt/wt.sh), sourced from shell/common/git.sh.
# The wrapper handles the interactive-shell cd; this script does the git work.

if [ -z "${WT_WORKTREE_REPO_LOCATION:-}" ]; then
	echo "error: WT_WORKTREE_REPO_LOCATION is not set." >&2
	echo "       Export it in local/shell_local.sh (the worktree collection folder, e.g. \$HOME/Sites/fe)," >&2
	echo "       or run wt in the repo's main folder." >&2
	exit 2
fi
CURRENT_REMOTE_NAME="${CURRENT_REMOTE_NAME:-origin}"

# --pr <number>: the pull request's folder, made first by wt add --pr if it isn't there (which
# says which folder that is), then its latest commits fetched as for a branch.
PR_NUMBER=""
if [ "${1:-}" = --pr ]; then
	PR_NUMBER="${2:-}"
	case "$PR_NUMBER" in
		'' | *[!0-9]*)
			echo "wt-cd: --pr takes a pull request's number, not '$PR_NUMBER'" >&2
			exit 1
			;;
	esac
	[ $# -eq 2 ] || { echo "Usage: wt-cd <branch-name>, or wt-cd --pr <number>" >&2; exit 1; }
	pr_folder_file="$(mktemp "${TMPDIR:-/tmp}/wt-cd.XXXXXX")" || exit 1
	trap 'rm -f "$pr_folder_file"' EXIT
	trap 'exit 130' INT
	WT_CD_FILE="$pr_folder_file" bash "$(cd "$(dirname "$0")" && pwd)/wt-add.sh" --pr "$PR_NUMBER" || exit
	pr_folder="$(cat "$pr_folder_file")"
	[ -n "$pr_folder" ] || { echo "wt-cd: wt add --pr $PR_NUMBER didn't say which folder it used." >&2; exit 1; }
	# Its branch, as named in the folder (the folder is named after it)
	REMOTE_BRANCH_NAME="$(git -C "$pr_folder" symbolic-ref --quiet --short HEAD 2>/dev/null)" || {
		echo "wt-cd: $pr_folder has no branch checked out." >&2
		exit 1
	}
	set -- "$REMOTE_BRANCH_NAME"
fi

REMOTE_BRANCH_NAME="$1"
LOCAL_BRANCH_NAME="${REMOTE_BRANCH_NAME//\//_}"

# No other options (--strict is wt add's); no branch name starts with -
case "$REMOTE_BRANCH_NAME" in
	-*)
		echo "wt-cd: unknown option $REMOTE_BRANCH_NAME" >&2
		exit 1
		;;
esac

if [ -z "$REMOTE_BRANCH_NAME" ]; then
	echo "Usage: wt-cd <branch-name>, or wt-cd --pr <number>"
	exit 1
fi

# Anchor for fetch_pr_head (wt-common.sh): the main worktree is a valid git
# worktree in both layouts, whereas the collection folder is not a git repo in
# the normal-repo-at-main layout. (The other git calls in this script run from
# the feature worktree after `cd "$worktree_path"`, so they need no anchor.)
MAIN_WT="$WT_WORKTREE_REPO_LOCATION/main"

worktree_path="$WT_WORKTREE_REPO_LOCATION/$LOCAL_BRANCH_NAME"

# Shared helpers (find_merged_pr, etc.)
source "$(cd "$(dirname "$0")" && pwd)/wt-common.sh"

# The remote branch is gone (e.g. deleted after a squash merge). If the `gh`
# CLI is available, find the merged PR whose head was this branch and check
# out its head commit in a detached worktree so the change set can still be
# reviewed. GitHub keeps every PR's head at refs/pull/<n>/head even after the
# branch is deleted. Exits non-zero (so the wrapper does not cd) when gh is
# missing or no matching merged PR is found.
fetch_branch_or_recover() {
	local number
	# A branch following a pull request's head (wt add --pr's pr-<number>): fetch that, as the
	# remote has no branch of its name. git pull then brings the commits in.
	if number="$(pull_ref_number "$REMOTE_BRANCH_NAME")"; then
		if git fetch "$CURRENT_REMOTE_NAME" "refs/pull/$number/head" 2>/dev/null; then
			echo "Fetched PR #$number's latest commits (git pull to apply them)."
		else
			echo "wt-cd: couldn't fetch refs/pull/$number/head, PR #$number's head, from $CURRENT_REMOTE_NAME. Continuing with the local branch." >&2
		fi
		return 0
	fi
	if git fetch "$CURRENT_REMOTE_NAME" "$REMOTE_BRANCH_NAME" 2>/dev/null; then
		return 0
	fi
	if [ "$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" = "$REMOTE_BRANCH_NAME" ]; then
		echo "Remote branch '$REMOTE_BRANCH_NAME' not found on $CURRENT_REMOTE_NAME. Continuing with the local branch."
		return 0
	fi

	echo "Remote branch '$REMOTE_BRANCH_NAME' not found on $CURRENT_REMOTE_NAME (it may have been deleted after merging)."

	if ! command -v gh >/dev/null 2>&1; then
		echo "wt-cd: the 'gh' CLI is not available, so I can't look up the merged PR to recover this branch."
		echo "Install gh (https://cli.github.com) and re-run, or review the squash commit on the main branch directly."
		exit 1
	fi

	echo "Looking up the merged PR for head branch '$REMOTE_BRANCH_NAME' via gh..."
	local pr_number
	pr_number="$(find_merged_pr)"

	if [ -z "$pr_number" ]; then
		echo "wt-cd: no merged PR found with head branch '$REMOTE_BRANCH_NAME'. Nothing to recover."
		exit 1
	fi

	echo "Found merged PR #$pr_number. Fetching its head commit..."
	# fetch_pr_head returns the full commit SHA (not FETCH_HEAD, which is
	# per-worktree and would be invisible from this worktree's CWD).
	if ! pr_head_sha="$(fetch_pr_head "$pr_number")"; then
		echo "wt-cd: failed to fetch refs/pull/$pr_number/head from $CURRENT_REMOTE_NAME."
		exit 1
	fi

	# Follow wt-add.sh's worktree guard: re-point an existing worktree in
	# place, abort on a stray non-worktree folder (never overwrite), or create
	# the worktree if the folder is missing.
	if [ -e "$worktree_path/.git" ]; then
		if ! git checkout --detach "$pr_head_sha"; then
			echo "wt-cd: failed to check out the PR head commit in $worktree_path."
			exit 1
		fi
	elif [ -e "$worktree_path" ]; then
		echo "wt-cd: a folder named $LOCAL_BRANCH_NAME already exists at $worktree_path but is not a git worktree. Aborting so nothing is overwritten."
		exit 1
	else
		if ! git worktree add --detach "$worktree_path" "$pr_head_sha"; then
			echo "wt-cd: failed to create worktree folder $LOCAL_BRANCH_NAME."
			exit 1
		fi
	fi

	if [ ! -d "$worktree_path" ]; then
		echo "wt-cd: failed to create worktree folder $LOCAL_BRANCH_NAME."
		exit 1
	fi

	echo "Checked out PR #$pr_number head (${pr_head_sha:0:7}) in $worktree_path for review."
}

if [ ! -e "$worktree_path" ]; then
	echo "Worktree folder $LOCAL_BRANCH_NAME does not exist. Creating it via wt-add..."
	exec "$(cd "$(dirname "$0")" && pwd)/wt-add.sh" "$REMOTE_BRANCH_NAME"
fi

if [ -e "$worktree_path/.git" ] && held="$(other_branch_in "$worktree_path" "$REMOTE_BRANCH_NAME")"; then
	echo "wt-cd: the folder $LOCAL_BRANCH_NAME holds branch $held, not $REMOTE_BRANCH_NAME"
	echo "       (/ becomes _ in folder names, so both branches would use that folder)."
	exit 1
fi

cd "$worktree_path" || exit 1
tell_folder "$worktree_path"
fetch_branch_or_recover
