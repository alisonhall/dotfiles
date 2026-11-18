#!/usr/bin/env bash
# wt-rm.sh — remove a worktree folder and prune stale worktree registrations.
# Invoked by the wt function (git/wt/wt.sh), sourced from shell/common/git.sh.
#
# Usage:
#   wt-rm <branch>            remove the branch's folder
#   wt-rm <folder>            remove that worktree, written as a path (., ./x,
#                             ../x or a full path; a plain name is a branch):
#                             beside main, or anywhere else, if it's this repo's
#   wt-rm --branch <...>      also delete the branch it holds (not a protected
#                             one: CURRENT_DEV_BRANCH, WT_PROTECTED_BRANCHES)
#   wt-rm --yes <...>         don't ask when the folder holds work that would be
#                             lost (uncommitted changes, new files, commits
#                             not on the remote)
#   wt-rm -h                  help
#
# With such work, it lists it and asks first - or, not run from a terminal
# (where nobody could answer), stops without deleting anything, unless --yes.

YES=0
DELETE_BRANCH=0
REMOTE_BRANCH_NAME=""
usage() {
	echo "Usage: wt rm [--yes] [--branch] <branch-name | folder>" >&2
	echo "wt-rm: ${1:-name one branch or folder to remove.}" >&2
	exit 2
}
while [ $# -gt 0 ]; do
	case "$1" in
		--yes) YES=1 ;;
		--branch) DELETE_BRANCH=1 ;;
		-h | --help)
			sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		-*)
			usage "unknown option $1."
			;;
		*)
			[ -z "$REMOTE_BRANCH_NAME" ] || usage "name one branch or folder, not '$REMOTE_BRANCH_NAME' and '$1'."
			REMOTE_BRANCH_NAME="$1"
			;;
	esac
	shift
done
[ -n "$REMOTE_BRANCH_NAME" ] || usage

# folder_in_use, remove_links, pull_ref_number, is_folder_arg
source "$(cd "$(dirname "$0")" && pwd)/wt-common.sh"

# abs_path <path> <relative to>: The path, made absolute if it's relative
abs_path() {
	case "$1" in /* | [A-Za-z]:*) printf '%s' "$1" ;; *) printf '%s/%s' "$2" "$1" ;; esac
}

# worktree_paths <folder>: Each worktree git has registered for the folder's repo, one per line -
# the first is always the main one (or, for a bare repo, the repo itself)
worktree_paths() {
	git -C "$1" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p'
}

# Given a folder - written as a path (is_folder_arg), which is never a branch name - it must be a
# worktree's top folder (not one inside it, as deleting goes further than what was named), and a
# worktree of this repo: beside main, or anywhere else git has it registered (made by hand, by an
# editor, or by another tool's git worktree add). Its repo comes from git itself, so outside any
# layout, with no location set, it still works.
NAME=""   # how messages name the folder: its name beside main, else its full path
top=""
if is_folder_arg "$REMOTE_BRANCH_NAME" && [ -d "$REMOTE_BRANCH_NAME" ]; then
	top="$(git -C "$REMOTE_BRANCH_NAME" rev-parse --show-toplevel 2>/dev/null)" || top=""
	if [ -z "$top" ]; then
		echo "wt-rm: $REMOTE_BRANCH_NAME isn't a worktree of a git repo, so nothing was deleted." >&2
		exit 1
	fi
	if ! [ "$top" -ef "$REMOTE_BRANCH_NAME" ]; then
		echo "wt-rm: $REMOTE_BRANCH_NAME is inside $(basename "$top"), not a branch's folder itself, so nothing was deleted. Name the folder itself to remove it." >&2
		exit 1
	fi
	first="$(worktree_paths "$top" | head -n 1)"
	if [ -n "${WT_WORKTREE_REPO_LOCATION:-}" ]; then
		# Run in (or set to) a layout: only that repo's worktrees
		MAIN_WT="$WT_WORKTREE_REPO_LOCATION/main"
		if ! same_repo "$top" "$MAIN_WT"; then
			echo "wt-rm: $REMOTE_BRANCH_NAME is a worktree of a different repo than $MAIN_WT, so nothing was deleted." >&2
			exit 1
		fi
	else
		# The repo from the folder: anchor on its main worktree (a bare repo's own folder works too),
		# with that clone's settings
		MAIN_WT="$first"
		use_repo_settings "$MAIN_WT"
	fi
	# Never the main worktree - the first git lists, whatever it's called - or the layout's main
	if [ "$top" -ef "$first" ] || [ "$top" -ef "$MAIN_WT" ]; then
		echo "wt-rm: won't delete the main folder, which holds the repo itself. Nothing was deleted." >&2
		exit 1
	fi
	registered=0
	while IFS= read -r wt_path; do
		[ "$wt_path" -ef "$top" ] && registered=1
	done < <(worktree_paths "$MAIN_WT")
	if [ "$registered" = 0 ]; then
		echo "wt-rm: $REMOTE_BRANCH_NAME isn't a worktree git has registered for this repo, so nothing was deleted." >&2
		exit 1
	fi
	if [ -n "${WT_WORKTREE_REPO_LOCATION:-}" ] && [ "$(dirname "$top")" -ef "$WT_WORKTREE_REPO_LOCATION" ]; then
		LOCAL_BRANCH_NAME="$(basename "$top")"
		folder="$WT_WORKTREE_REPO_LOCATION/$LOCAL_BRANCH_NAME"
		NAME="$LOCAL_BRANCH_NAME"
	else
		# As it was given, made a full path (git may spell it differently, like /private/var/...
		# for /var/... on macOS, or C:/... on Windows)
		folder="$(abs_path "${REMOTE_BRANCH_NAME%/}" "$PWD")"
		NAME="$folder"
	fi
	REMOTE_BRANCH_NAME="$NAME"
elif [ -z "${WT_WORKTREE_REPO_LOCATION:-}" ]; then
	# A branch, or a folder that's gone: there's no telling which repo it's of
	wt_not_configured wt-rm
elif is_folder_arg "$REMOTE_BRANCH_NAME"; then
	# A folder that isn't there (any more): maybe one deleted by hand, whose record git still has
	MAIN_WT="$WT_WORKTREE_REPO_LOCATION/main"
	folder="$(abs_path "${REMOTE_BRANCH_NAME%/}" "$PWD")"
	registered=0
	while IFS= read -r wt_path; do
		# (Compared by name in the same folder: git may write the path differently, like C:/...)
		if [ "$(basename "$wt_path")" = "$(basename "$folder")" ] && [ "$(dirname "$wt_path")" -ef "$(dirname "$folder")" ]; then
			registered=1
		fi
	done < <(worktree_paths "$MAIN_WT")
	if [ "$registered" = 0 ]; then
		echo "wt-rm: there's no worktree at $REMOTE_BRANCH_NAME, so nothing was deleted. Check the folder with wt ls." >&2
		exit 1
	fi
	echo "wt-rm: $folder was already deleted, so this just removes git's record of it."
	git -C "$MAIN_WT" worktree prune
	echo "Pruned stale worktrees."
	exit 0
else
	MAIN_WT="$WT_WORKTREE_REPO_LOCATION/main"
	LOCAL_BRANCH_NAME="${REMOTE_BRANCH_NAME//\//_}"
	folder="$WT_WORKTREE_REPO_LOCATION/$LOCAL_BRANCH_NAME"
	NAME="$LOCAL_BRANCH_NAME"
	# Only ever a branch's folder. Something git wouldn't accept as a branch name could be another
	# folder entirely: .bare (the repo itself, in the bare-repo layout), . or .. (the collection
	# folder, or the one it's in).
	if ! git check-ref-format --branch "$REMOTE_BRANCH_NAME" >/dev/null 2>&1; then
		echo "wt-rm: '$REMOTE_BRANCH_NAME' isn't a branch name, so nothing was deleted. Write a folder as a path, like ./name." >&2
		exit 1
	fi
	# Never the main folder: it holds the repo's git data, so deleting it would lose every unpushed
	# branch and stash, and break every other branch folder
	if [ "$LOCAL_BRANCH_NAME" = main ] || { [ -d "$folder" ] && [ "$folder" -ef "$MAIN_WT" ]; }; then
		echo "wt-rm: won't delete the main folder, which holds the repo itself. Nothing was deleted." >&2
		exit 1
	fi
	if [ ! -d "$folder" ]; then
		# Already deleted (by hand, say): just remove git's record of it, if it has one. If not, the
		# branch name is probably mistyped.
		registered=0
		while IFS= read -r wt_path; do
			if [ "$(basename "$wt_path")" = "$LOCAL_BRANCH_NAME" ] && [ "$(dirname "$wt_path")" -ef "$WT_WORKTREE_REPO_LOCATION" ]; then
				registered=1
			fi
		done < <(worktree_paths "$MAIN_WT")
		if [ "$registered" = 0 ]; then
			echo "wt-rm: there's no worktree for $REMOTE_BRANCH_NAME (no folder $LOCAL_BRANCH_NAME in $WT_WORKTREE_REPO_LOCATION), so nothing was deleted. Check the name with wt ls." >&2
			exit 1
		fi
		echo "wt-rm: $LOCAL_BRANCH_NAME was already deleted, so this just removes git's record of it."
		git -C "$MAIN_WT" worktree prune
		echo "Pruned stale worktrees."
		exit 0
	fi
fi
CURRENT_REMOTE_NAME="${CURRENT_REMOTE_NAME:-origin}"
resolve_dev_branch

# The branch the folder holds (none when detached), for --branch
held_branch="$(git -C "$folder" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

# --- work that deleting the folder would lose --------------------------------
# Uncommitted changes, new files - not ignored ones, nor links (the shared ones, like .cache, may
# not be ignored), as wt clean counts them - and commits on none of the remote's branches, nor in
# its pull requests' latest versions: a merged PR's branch is usually deleted, and a fetch then
# drops git's copy of it.
work=""
lost=""  # what would be lost, in a few words, for the last line
changes="$(git -C "$folder" status --porcelain --untracked-files=no 2>/dev/null)"
nl=$'\n'
while IFS= read -r -d '' new_file; do
	[ -L "$folder/$new_file" ] && continue
	changes="${changes:+$changes$nl}?? $new_file"
done < <(git -C "$folder" ls-files -z --others --exclude-standard 2>/dev/null)
if [ -n "$changes" ]; then
	lost="uncommitted changes"
	work="  uncommitted changes and new files:"$'\n'"$(printf '%s\n' "$changes" | head -n 10 | sed 's/^/    /')"
	[ "$(printf '%s\n' "$changes" | wc -l)" -gt 10 ] && work="$work"$'\n'"    ..."
fi
exclude=()
unpushed="$(git -C "$folder" log --oneline HEAD --not --remotes 2>/dev/null || true)"
if [ -n "$unpushed" ] && [ -n "$held_branch" ]; then
	# Its pull requests' latest commits: a pr-<number> branch's from its pull ref, else gh's by branch
	if number="$(pull_ref_number "$held_branch")"; then
		pr_heads="$(git -C "$MAIN_WT" ls-remote "$CURRENT_REMOTE_NAME" "refs/pull/$number/head" 2>/dev/null | cut -f1)"
	elif command -v gh >/dev/null 2>&1; then
		pr_heads="$(cd "$MAIN_WT" && {
			if [ -n "${WT_REPO_SLUG:-}" ]; then set -- --repo "$WT_REPO_SLUG"; else set --; fi
			gh pr list "$@" --head "$held_branch" --state all --json number,state,headRefOid \
				--jq '.[] | "\(.number)\t\(.state)\t\(.headRefOid)"' 2>/dev/null
		} | cut -f3)"
	else
		pr_heads=""
	fi
	for pr_head in $pr_heads; do
		git -C "$MAIN_WT" cat-file -e "$pr_head^{commit}" 2>/dev/null && exclude+=("$pr_head")
	done
	if [ "${#exclude[@]}" -gt 0 ]; then
		unpushed="$(git -C "$folder" log --oneline HEAD --not --remotes "${exclude[@]}" 2>/dev/null || true)"
	fi
fi
if [ -n "$unpushed" ]; then
	count="$(printf '%s\n' "$unpushed" | wc -l | tr -d ' ')"
	[ -n "$work" ] && work="$work"$'\n'
	work="$work  $count commit(s) not on $CURRENT_REMOTE_NAME:"$'\n'"$(printf '%s\n' "$unpushed" | head -n 5 | sed 's/^/    /')"
	[ "$count" -gt 5 ] && work="$work"$'\n'"    ..."
	lost="${lost:+$lost and }$count commit(s) not on $CURRENT_REMOTE_NAME"
fi

if [ -n "$work" ] && [ "$YES" != 1 ]; then
	echo "wt-rm: $NAME has work that deleting it would lose:" >&2
	printf '%s\n' "$work" >&2
	if [ -t 0 ]; then
		printf 'Delete %s anyway? [y/N] ' "$NAME" >&2
		read -r answer || answer=""
		case "$answer" in
			y | Y | yes | Yes) ;;
			*)
				echo "wt-rm: $NAME has $lost, so nothing was deleted." >&2
				exit 1
				;;
		esac
	else
		echo "wt-rm: $NAME has $lost, and with no terminal to ask in, nothing was deleted. Add --yes to delete it anyway." >&2
		exit 1
	fi
fi

in_use=0
folder_in_use "$folder" || in_use=$?
case "$in_use" in
	0)
		echo "wt-rm: $NAME is in use by another program, like an editor or a terminal that's in it, so nothing was deleted. Close it (or cd out of the folder), then run this again." >&2
		exit 1
		;;
	2)
		# Renamed and stuck; folder_in_use said where it is
		echo "wt-rm: $NAME was renamed while checking whether it was in use and couldn't be renamed back, so nothing was deleted. Put it back as shown above." >&2
		exit 1
		;;
esac

# Links first, so nothing they point at (like main/node_modules) can be deleted with the folder.
# (-f: whether to delete was settled above, so rm doesn't ask about read-only files too.)
remove_links "$folder"
rm -rf "$folder"
echo "Worktree folder $NAME removed."
# Anchor the prune on the main worktree: the collection folder is not a git
# repo in the normal-repo-at-main layout, and the user's CWD may not be a git
# repo at all. main is a valid worktree in both layouts.
git -C "$MAIN_WT" worktree prune
echo "Pruned stale worktrees."

# --branch: the branch it held, with its settings - never a protected one
if [ "$DELETE_BRANCH" = 1 ]; then
	if [ -z "$held_branch" ]; then
		echo "No branch to delete: the folder had none checked out."
	else
		for protected in $CURRENT_DEV_BRANCH ${WT_PROTECTED_BRANCHES:-main}; do
			if [ "$held_branch" = "$protected" ]; then
				echo "Kept branch $held_branch, as it's protected."
				exit 0
			fi
		done
		if git -C "$MAIN_WT" branch -D "$held_branch" >/dev/null; then
			echo "Branch $held_branch deleted."
		else
			echo "error: wt-rm: the folder was removed, but git couldn't delete branch $held_branch (its message is above)." >&2
			exit 1
		fi
	fi
fi
