#!/usr/bin/env bash
# wt-rm.sh — remove a worktree folder and prune stale worktree registrations.
# Invoked by the wt function (bin/wt/wt.sh), sourced from shell/common/git.sh.

if [ -z "${WT_WORKTREE_REPO_LOCATION:-}" ]; then
	echo "error: WT_WORKTREE_REPO_LOCATION is not set." >&2
	echo "       Export it in ~/.shell_local (the worktree collection folder, e.g. \$HOME/Sites/fe)." >&2
	exit 2
fi

REMOTE_BRANCH_NAME="$1"
LOCAL_BRANCH_NAME="${REMOTE_BRANCH_NAME//\//_}"

if [ -z "$REMOTE_BRANCH_NAME" ]; then
	echo "Usage: wt-rm <branch-name>"
	exit 1
fi

rm -rd "$WT_WORKTREE_REPO_LOCATION/$LOCAL_BRANCH_NAME"
echo "Worktree folder $LOCAL_BRANCH_NAME removed."
# Anchor the prune on the main worktree: the collection folder is not a git
# repo in the normal-repo-at-main layout, and the user's CWD may not be a git
# repo at all. main is a valid worktree in both layouts.
git -C "$WT_WORKTREE_REPO_LOCATION/main" worktree prune
echo "Pruned stale worktrees."
