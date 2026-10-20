#!/usr/bin/env bash
# wt-add.sh — create a new git worktree from a remote branch name.
# Invoked by the wt function (git/wt/wt.sh), sourced from shell/common/git.sh.
# The wrapper handles the interactive-shell cd; this script does the git work.

if [ -z "${WT_WORKTREE_REPO_LOCATION:-}" ]; then
	echo "error: WT_WORKTREE_REPO_LOCATION is not set." >&2
	echo "       Export it in local/shell_local.sh (the worktree collection folder, e.g. \$HOME/Sites/fe)." >&2
	exit 2
fi
CURRENT_REMOTE_NAME="${CURRENT_REMOTE_NAME:-origin}"
CURRENT_DEV_BRANCH="${CURRENT_DEV_BRANCH:-main}"

REMOTE_BRANCH_NAME="$1"
LOCAL_BRANCH_NAME="${REMOTE_BRANCH_NAME//\//_}"

if [ -z "$REMOTE_BRANCH_NAME" ]; then
	echo "Usage: wt-add <branch-name>"
	exit 1
fi

# Anchor all central git operations on the main worktree. The worktree
# collection folder is NOT itself a git repo in the normal-repo-at-main layout
# (the git home lives at main/.git), so bare `git` from the collection folder
# fails there. main is a valid worktree in BOTH layouts (bare-repo and
# normal-repo-at-main), so `git -C main` works everywhere.
MAIN_WT="$WT_WORKTREE_REPO_LOCATION/main"

cd "$WT_WORKTREE_REPO_LOCATION" || exit 1

# Shared helpers (find_merged_pr, fetch_pr_head, link_workspaces,
# setup_worktree_symlinks)
source "$(cd "$(dirname "$0")" && pwd)/wt-common.sh"

# Guard: if the worktree folder already exists, don't try to re-create it
# (git worktree add -b would fail with "branch already exists" and then
# cascade into cd/ln errors). Re-run = switch into it; stray folder = abort.
worktree_path="$WT_WORKTREE_REPO_LOCATION/$LOCAL_BRANCH_NAME"
if [ -e "$worktree_path/.git" ]; then
	if held="$(other_branch_in "$worktree_path" "$REMOTE_BRANCH_NAME")"; then
		echo "wt-add: the folder $LOCAL_BRANCH_NAME already holds branch $held, not $REMOTE_BRANCH_NAME"
		echo "        (/ becomes _ in folder names, so both branches would use that folder)."
		exit 1
	fi
	echo "Worktree folder $LOCAL_BRANCH_NAME already exists. Switching to it..."
	exit 0
fi
if [ -e "$worktree_path" ]; then
	echo "wt-add: a folder named $LOCAL_BRANCH_NAME already exists at $worktree_path but is not a git worktree. Aborting so nothing is overwritten."
	exit 1
fi

# Check whether the branch already exists on the remote. (The full ref: ls-remote matches a
# pattern against the end of each ref name, so "login" alone would also match feature/login.)
if [ -n "$(git -C "$MAIN_WT" ls-remote --heads "$CURRENT_REMOTE_NAME" "refs/heads/$REMOTE_BRANCH_NAME")" ]; then
	echo "Remote branch '$REMOTE_BRANCH_NAME' found on $CURRENT_REMOTE_NAME. Creating worktree tracking it..."
	# Fetch the branch so the local remote-tracking ref ($CURRENT_REMOTE_NAME/$REMOTE_BRANCH_NAME)
	# exists; git worktree add cannot resolve a remote branch that has not been fetched yet.
	git -C "$MAIN_WT" fetch "$CURRENT_REMOTE_NAME" "$REMOTE_BRANCH_NAME"
	if git -C "$MAIN_WT" show-ref --verify --quiet "refs/heads/$REMOTE_BRANCH_NAME"; then
		# Local branch already exists (e.g. the folder was removed) — check it out, don't re-create it.
		git -C "$MAIN_WT" worktree add "$worktree_path" "$REMOTE_BRANCH_NAME"
	else
		# Create a local branch named exactly like the remote branch, tracking it, in the underscore-named folder.
		git -C "$MAIN_WT" worktree add --track -b "$REMOTE_BRANCH_NAME" "$worktree_path" "$CURRENT_REMOTE_NAME/$REMOTE_BRANCH_NAME"
	fi
else
	# Branch not on the remote. Before creating a fresh local branch, check
	# whether it was a previously-merged PR (deleted after squash merge). If so,
	# recover the PR head commit in a detached worktree for review.
	pr_number="$(find_merged_pr)"
	if [ -n "$pr_number" ]; then
		echo "Remote branch '$REMOTE_BRANCH_NAME' not found on $CURRENT_REMOTE_NAME, but merged PR #$pr_number had this head. Recovering PR head..."
		# fetch_pr_head returns the full commit SHA (not FETCH_HEAD, which is
		# per-worktree). The SHA resolves from any worktree via the shared
		# object store.
		if pr_head_sha="$(fetch_pr_head "$pr_number")"; then
			git -C "$MAIN_WT" worktree add --detach "$worktree_path" "$pr_head_sha"
			echo "Checked out PR #$pr_number head (${pr_head_sha:0:7}) in $LOCAL_BRANCH_NAME for review."
			cd "$WT_WORKTREE_REPO_LOCATION/$LOCAL_BRANCH_NAME"
			setup_worktree_symlinks
			exit 0
		else
			echo "wt-add: failed to fetch refs/pull/$pr_number/head; falling back to new local branch."
		fi
	fi

	echo "Remote branch '$REMOTE_BRANCH_NAME' not found on $CURRENT_REMOTE_NAME. Creating a new local branch '$REMOTE_BRANCH_NAME' from $CURRENT_DEV_BRANCH..."
	if git -C "$MAIN_WT" show-ref --verify --quiet "refs/heads/$REMOTE_BRANCH_NAME"; then
		# Local branch already exists — check it out, don't re-create it.
		git -C "$MAIN_WT" worktree add "$worktree_path" "$REMOTE_BRANCH_NAME"
	else
		git -C "$MAIN_WT" worktree add -b "$REMOTE_BRANCH_NAME" "$worktree_path" "$CURRENT_DEV_BRANCH"
	fi
fi

if [ ! -d "$WT_WORKTREE_REPO_LOCATION/$LOCAL_BRANCH_NAME" ]; then
	echo "wt-add: failed to create worktree folder $LOCAL_BRANCH_NAME."
	exit 1
fi
cd "$WT_WORKTREE_REPO_LOCATION/$LOCAL_BRANCH_NAME"
echo "Worktree folder $LOCAL_BRANCH_NAME created and branch checked out."
setup_worktree_symlinks
