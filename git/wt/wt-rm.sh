#!/usr/bin/env bash
# wt-rm.sh — remove a worktree folder and prune stale worktree registrations.
# Invoked by the wt function (git/wt/wt.sh), sourced from shell/common/git.sh.

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

# folder_in_use, remove_links
source "$(cd "$(dirname "$0")" && pwd)/wt-common.sh"

folder="$WT_WORKTREE_REPO_LOCATION/$LOCAL_BRANCH_NAME"
MAIN_WT="$WT_WORKTREE_REPO_LOCATION/main"

# Never the main folder: it holds the repo's git data, so deleting it would lose every unpushed
# branch and stash, and break every other branch folder. Nor . or .. (the collection folder, or
# the one it's in), which git doesn't allow as branch names anyway.
case "$LOCAL_BRANCH_NAME" in
	. | ..)
		echo "wt-rm: '$REMOTE_BRANCH_NAME' isn't a branch name."
		exit 1
		;;
esac
if [ "$LOCAL_BRANCH_NAME" = main ] || { [ -d "$folder" ] && [ "$folder" -ef "$MAIN_WT" ]; }; then
	echo "wt-rm: won't delete the main folder, which holds the repo itself."
	exit 1
fi

if [ ! -d "$folder" ]; then
	# Already deleted (by hand, say): just remove git's record of it
	echo "wt-rm: there's no folder $LOCAL_BRANCH_NAME in $WT_WORKTREE_REPO_LOCATION, so there's nothing to delete."
	git -C "$MAIN_WT" worktree prune
	echo "Pruned stale worktrees."
	exit 0
fi

in_use=0
folder_in_use "$folder" || in_use=$?
case "$in_use" in
	0)
		echo "wt-rm: $LOCAL_BRANCH_NAME is in use by another program, like an editor or a terminal that's in it."
		echo "       Close it (or cd out of the folder), then run this again. Nothing was deleted."
		exit 1
		;;
	2) exit 1 ;; # Renamed and stuck; folder_in_use said where it is
esac

# Links first, so nothing they point at (like main/node_modules) can be deleted with the folder
remove_links "$folder"
rm -rd "$folder"
echo "Worktree folder $LOCAL_BRANCH_NAME removed."
# Anchor the prune on the main worktree: the collection folder is not a git
# repo in the normal-repo-at-main layout, and the user's CWD may not be a git
# repo at all. main is a valid worktree in both layouts.
git -C "$MAIN_WT" worktree prune
echo "Pruned stale worktrees."
