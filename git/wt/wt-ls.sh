#!/usr/bin/env bash
# wt-ls.sh — list the status of every git worktree in the front-end repo.
#
# For each worktree it reports:
#   * the folder it lives in (basename) and its full path
#   * the branch checked out (or the detached HEAD commit)
#   * the associated remote branch, and whether it STILL EXISTS on the remote
#     (verified with a single `git ls-remote`, not the stale local ref)
#   * whether the worktree folder is a SEPARATE sibling folder under the repo
#     root (the normal layout), nested inside another folder, or located
#     outside the repo root entirely
#   * whether the worktree has uncommitted TRACKED changes
#   * how many UNTRACKED (non-symlink) files the worktree has
#   * how many commits the local branch is ahead/behind its remote branch
#     (n/a when there is no remote branch, the remote branch was deleted, the
#     remote could not be verified, or the folder is missing)
#   * a "branch ≠ folder" marker when a non-detached worktree's checked-out
#     branch does not match its folder name (folder = branch with / -> _)
#     (happens after a manual checkout, a branch rename, or a non-unique name)
#
# By default this script runs `git fetch` first so the ahead/behind numbers
# (which compare against the remote-tracking refs) are current. Use --no-fetch
# to skip the fetch and report against the last-fetched state (faster, and
# works offline). Fetch only updates remote-tracking refs; it never touches
# your working tree or local branches.
#
# Usage:
#   wt-ls.sh              # fetch, then list (default)
#   wt-ls.sh --no-fetch   # skip the fetch; use last-fetched refs
#   wt-ls.sh --fetch      # explicit fetch (same as default)
#   wt-ls.sh -h           # help
#
# Output is colour-coded when stdout is a TTY (and NO_COLOR is unset):
#   green = remote exists / clean, red = remote deleted / missing folder,
#   yellow = unverified remote / changes present, dim = no upstream.
#
# Invoked by the wt function (git/wt/wt.sh), sourced from shell/common/git.sh.

set -uo pipefail

if [ -z "${WT_WORKTREE_REPO_LOCATION:-}" ]; then
	echo "error: WT_WORKTREE_REPO_LOCATION is not set." >&2
	echo "       Export it in ~/.shell_local (the worktree collection folder, e.g. \$HOME/Sites/fe)." >&2
	exit 2
fi
CURRENT_REMOTE_NAME="${CURRENT_REMOTE_NAME:-origin}"

# Fetch remote-tracking refs before computing ahead/behind (default on). Pass
# --no-fetch to skip it (faster / offline); --fetch is the explicit default.
FETCH=1
while [ $# -gt 0 ]; do
	case "$1" in
		--fetch) FETCH=1 ;;
		--no-fetch) FETCH=0 ;;
		-h|--help)
			sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*)
			echo "wt-ls: unknown option: $1 (see -h)" >&2
			exit 2
			;;
	esac
	shift
done

REPO_ROOT="$WT_WORKTREE_REPO_LOCATION"

# The main worktree must be a valid git worktree. This works in BOTH layouts:
# the bare-repo layout (fe/.bare + fe/main worktree) and the normal-repo-at-main
# layout (fe/main/.git). The collection folder itself is not a git repo in the
# latter, so we anchor on main rather than the folder.
if ! git -C "$REPO_ROOT/main" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	echo "wt-ls: no git worktree found at $REPO_ROOT/main."
	exit 1
fi

# Resolve to a physical path so the sibling/nested/outside classification
# matches the paths git reports. Git canonicalises symlinks (e.g. /var ->
# /private/var on macOS), so a symlinked repo root would otherwise compare
# unequal and mis-classify every worktree.
REPO_ROOT="$(cd "$REPO_ROOT" && pwd -P)"
# Anchor for all central git ops (see the check above).
MAIN_WT="$REPO_ROOT/main"

# --- colour (only when stdout is a TTY and NO_COLOR is unset) ---------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
	C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
else
	C_RESET=""; C_BOLD=""; C_DIM=""; C_GREEN=""; C_RED=""; C_YELLOW=""
fi

# --- collect worktrees -------------------------------------------------------
# Parse `git worktree list --porcelain`. Each record starts with
# `worktree <path>` and is followed by `HEAD <sha>`, then one of
# `branch refs/heads/<name>`, `detached`, or `bare` (the bare repo itself,
# which we skip). A record may also carry `prunable <reason>` when its folder
# has been deleted but the registration remains.
paths=()
heads=()
branches=()    # branch name, or "" for detached/bare
prunable=()    # "1" when the record is flagged prunable
bare=()        # "1" for the bare repo record (skipped from the listing)

n=0
while IFS= read -r line; do
	case "$line" in
		worktree\ *)
			# The same physical form as REPO_ROOT, so folder_location can compare them (on
			# Windows, git writes C:/... and Git Bash /c/...). A missing folder is kept as is.
			wt_path="${line#worktree }"
			paths+=("$(cd "$wt_path" 2>/dev/null && pwd -P || printf '%s' "$wt_path")")
			heads+=("")
			branches+=("")
			prunable+=("0")
			bare+=("0")
			n=$((n+1))
			;;
		HEAD\ *)
			heads[$((n-1))]="${line#HEAD }"
			;;
		branch\ *)
			branches[$((n-1))]="${line#branch refs/heads/}"
			;;
		prunable\ *)
			prunable[$((n-1))]="1"
			;;
		bare)
			bare[$((n-1))]="1"
			;;
	esac
done < <(git -C "$MAIN_WT" worktree list --porcelain 2>/dev/null)

# --- verify which branches still exist on the remote ------------------------
# One `git ls-remote` (a single network call) gives the authoritative list of
# branches on the remote. The local remote-tracking refs are stale (they only
# reflect the last fetch), so we check the remote directly. This verifies
# against CURRENT_REMOTE_NAME (the repo's single remote, origin). If the fetch
# fails (e.g. offline) we mark the state "unknown" rather than guessing.

# Optionally refresh the remote-tracking refs first so ahead/behind (which
# compares against @{u}) is current. A single fetch covers every branch. A
# failed fetch (offline) is non-fatal: we fall back to the last-fetched refs
# and the ls-remote below will report "unverified" for the remote state.
if [ "$FETCH" = "1" ]; then
	if ! git -C "$MAIN_WT" fetch --prune "$CURRENT_REMOTE_NAME" --quiet 2>/dev/null; then
		echo "wt-ls: warning: fetch from $CURRENT_REMOTE_NAME failed; ahead/behind may be stale." >&2
	fi
fi

REMOTE_HEADS=""
REMOTE_FETCH_OK=0
if REMOTE_HEADS="$(git -C "$MAIN_WT" ls-remote --heads "$CURRENT_REMOTE_NAME" 2>/dev/null | awk '{print $2}')"; then
	REMOTE_FETCH_OK=1
fi

# 0 if <branch> exists on the remote, 1 if not, 2 if the remote could not be
# queried (offline).
remote_branch_exists() {
	local branch="$1"
	[ "$REMOTE_FETCH_OK" = "1" ] || return 2
	if grep -qxF "refs/heads/${branch}" <<< "$REMOTE_HEADS" 2>/dev/null; then
		return 0
	else
		return 1
	fi
}

# --- per-worktree helpers ----------------------------------------------------

# Associated remote branch for a branch name. Prints one of:
#   "<remote>/<branch>"            remote-tracking ref is present
#   "<remote>/<branch> (pruned)"   upstream configured but the ref is gone
#   "-"                            no upstream configured (never pushed)
remote_for_branch() {
	local branch="$1" remote
	remote="$(git -C "$MAIN_WT" config "branch.${branch}.remote" 2>/dev/null || true)"
	if [ -z "$remote" ]; then
		echo "-"
		return 0
	fi
	if git -C "$MAIN_WT" rev-parse --verify --quiet "refs/remotes/${remote}/${branch}" >/dev/null 2>&1; then
		echo "${remote}/${branch}"
	else
		echo "${remote}/${branch} (pruned)"
	fi
}

# Classify a worktree folder relative to the repo root:
#   sibling - a direct child of the repo root (the normal, separate layout)
#   nested  - under the repo root but not a direct child
#   outside - not under the repo root at all
folder_location() {
	local path="$1" parent
	parent="$(dirname "$path")"
	if [ "$parent" = "$REPO_ROOT" ]; then
		echo "sibling"
	elif [ "${path#"$REPO_ROOT"/}" != "$path" ]; then
		echo "nested"
	else
		echo "outside"
	fi
}

# True when the worktree has uncommitted tracked changes. `node_modules` is a
# symlink at the root and shows as untracked, so use tracked-only status.
is_dirty() {
	local path="$1"
	[ -n "$(git -C "$path" status --porcelain -uno 2>/dev/null)" ]
}

# Count untracked, non-ignored, non-symlink files in a worktree. `--directory`
# collapses untracked dirs into single entries (fast); symlinks (e.g. the
# node_modules -> main/node_modules link) are skipped so they don't count.
untracked_count() {
	local path="$1"
	local count=0 f
	while IFS= read -r f; do
		[ -z "$f" ] && continue
		f="${f%/}"
		[ -L "$path/$f" ] && continue
		# Shared with main through a Windows hard link (see make_link in wt-common.sh)
		[ "$path" != "$MAIN_WT" ] && [ "$path/$f" -ef "$MAIN_WT/$f" ] && continue
		count=$((count+1))
	done < <(git -C "$path" ls-files --others --exclude-standard --directory 2>/dev/null)
	echo "$count"
}

# Ahead/behind of the local branch relative to its upstream remote-tracking
# ref (the same numbers `git status` shows). Sets AB_TEXT and AB_STATE.
#   AB_STATE: up-to-date | diverged | n/a
# Only call this when the remote branch exists and the folder is present;
# otherwise the caller supplies its own "n/a (...)" text.
ahead_behind() {
	local path="$1" counts ahead behind
	if counts="$(git -C "$path" rev-list --left-right --count HEAD...@{u} 2>/dev/null)"; then
		read -r ahead behind <<< "$counts"
		if [ "${ahead:-0}" -eq 0 ] && [ "${behind:-0}" -eq 0 ]; then
			AB_TEXT="up to date"
			AB_STATE="up-to-date"
		else
			AB_TEXT="ahead ${ahead}, behind ${behind}"
			AB_STATE="diverged"
		fi
	else
		AB_TEXT="n/a (not fetched)"
		AB_STATE="n/a"
	fi
}

# --- build display rows ------------------------------------------------------
disp_folder=()
disp_branch=()
disp_remote=()
disp_remote_state=()   # none | exists | deleted | unknown
disp_loc=()
disp_dirty=()          # yes | no | missing  (tracked changes)
disp_untracked=()      # count, or "missing"
disp_ab=()             # ahead/behind text
disp_ab_state=()       # up-to-date | diverged | n/a
disp_mismatch=()       # 1 if a non-detached branch != its folder name
disp_path=()

count=0
for i in "${!paths[@]}"; do
	# Skip the bare repo itself (it has no branch checked out).
	[ "${bare[$i]}" = "1" ] && continue

	path="${paths[$i]}"
	branch="${branches[$i]}"
	head="${heads[$i]}"

	# Folder basename + location classification.
	folder="$(basename "$path")"
	loc="$(folder_location "$path")"

	# Branch line: the branch name, or the detached HEAD short SHA.
	if [ -n "$branch" ]; then
		bdisp="$branch"
		remote_name="$(git -C "$MAIN_WT" config "branch.${branch}.remote" 2>/dev/null || true)"
		if [ -z "$remote_name" ]; then
			remote="-"
			remote_state="none"
		elif [ "$remote_name" != "$CURRENT_REMOTE_NAME" ]; then
			# Tracks a remote we did not query; don't claim it exists.
			remote="${remote_name}/${branch} (unverified)"
			remote_state="unknown"
		else
			remote="${remote_name}/${branch}"
			remote_branch_exists "$branch"
			case $? in
				0) remote_state="exists" ;;
				1) remote_state="deleted"; remote="${remote} (deleted)" ;;
				*) remote_state="unknown"; remote="${remote} (unverified)" ;;
			esac
		fi
	else
		bdisp="(detached ${head:0:8})"
		remote="-"
		remote_state="none"
	fi

	# Tracked-changes + untracked (only meaningful for a folder that exists).
	if [ ! -d "$path" ]; then
		dirty="missing"
		untracked="missing"
	else
		if is_dirty "$path"; then dirty="yes"; else dirty="no"; fi
		untracked="$(untracked_count "$path")"
	fi

	# Ahead/behind vs the upstream remote branch. Only meaningful when the
	# remote branch exists and the folder is present; otherwise "n/a (...)".
	if [ ! -d "$path" ]; then
		ab="n/a (missing folder)"; ab_state="n/a"
	elif [ "$remote_state" = "exists" ]; then
		ahead_behind "$path"
		ab="$AB_TEXT"; ab_state="$AB_STATE"
	elif [ "$remote_state" = "deleted" ]; then
		ab="n/a (remote deleted)"; ab_state="n/a"
	elif [ "$remote_state" = "unknown" ]; then
		ab="n/a (unverified)"; ab_state="n/a"
	else
		ab="n/a (no remote branch)"; ab_state="n/a"
	fi

	# Prunable worktrees (folder deleted, registration stale) get a marker.
	if [ "${prunable[$i]}" = "1" ]; then
		bdisp="$bdisp  [prunable]"
	fi

	# Flag a non-detached worktree whose checked-out branch does not match its
	# folder name (folder = branch with / -> _). Detached worktrees have no
	# branch, so they are not flagged here (already shown as detached).
	if [ -n "$branch" ] && [ "${branch//\//_}" != "$folder" ]; then
		mismatch=1
	else
		mismatch=0
	fi

	disp_folder+=("$folder")
	disp_branch+=("$bdisp")
	disp_remote+=("$remote")
	disp_remote_state+=("$remote_state")
	disp_loc+=("$loc")
	disp_dirty+=("$dirty")
	disp_untracked+=("$untracked")
	disp_ab+=("$ab")
	disp_ab_state+=("$ab_state")
	disp_mismatch+=("$mismatch")
	disp_path+=("$path")
	count=$((count+1))
done

if [ "$count" -eq 0 ]; then
	echo "wt-ls: no worktrees found at $REPO_ROOT."
	exit 0
fi

# --- print list --------------------------------------------------------------
# A per-worktree block (not a wide table) so it wraps cleanly in a normal
# terminal. Each line stays short; the full path is only shown for folders
# that are not a clean sibling of the repo root.
printf '%s\n' "Worktrees in $REPO_ROOT"
printf '%s\n' "remote: $CURRENT_REMOTE_NAME   (read-only status; nothing is modified)"
printf '%s\n' ""

num=0
for i in "${!disp_branch[@]}"; do
	num=$((num+1))
	# Branch line; append a marker when the branch does not match the folder.
	if [ "${disp_mismatch[$i]}" = "1" ]; then
		printf '  %d. %s%s%s  %s⚠ branch ≠ folder%s\n' \
			"$num" "$C_BOLD" "${disp_branch[$i]}" "$C_RESET" "$C_YELLOW" "$C_RESET"
	else
		printf '  %d. %s%s%s\n' "$num" "$C_BOLD" "${disp_branch[$i]}" "$C_RESET"
	fi
	printf '     folder:  %s  [%s]\n' "${disp_folder[$i]}" "${disp_loc[$i]}"

	# Remote line, coloured by whether the branch still exists on the remote.
	case "${disp_remote_state[$i]}" in
		none)    printf '     remote:  %s%s%s\n' "$C_DIM"    "${disp_remote[$i]}" "$C_RESET" ;;
		exists)  printf '     remote:  %s%s%s\n' "$C_GREEN"  "${disp_remote[$i]}" "$C_RESET" ;;
		deleted) printf '     remote:  %s%s%s\n' "$C_RED"    "${disp_remote[$i]}" "$C_RESET" ;;
		*)       printf '     remote:  %s%s%s\n' "$C_YELLOW" "${disp_remote[$i]}" "$C_RESET" ;;
	esac

	# Tracked (committed-file) changes.
	case "${disp_dirty[$i]}" in
		yes)     printf '     tracked: %schanged%s\n' "$C_YELLOW" "$C_RESET" ;;
		no)      printf '     tracked: %sclean%s\n'   "$C_GREEN"  "$C_RESET" ;;
		missing) printf '     tracked: %smissing folder%s\n' "$C_RED" "$C_RESET" ;;
	esac

	# Untracked (non-symlink) files.
	case "${disp_untracked[$i]}" in
		missing) printf '     untracked: %smissing folder%s\n' "$C_RED" "$C_RESET" ;;
		0)       printf '     untracked: %snone%s\n' "$C_GREEN" "$C_RESET" ;;
		*)       printf '     untracked: %s%s file(s)%s\n' "$C_YELLOW" "${disp_untracked[$i]}" "$C_RESET" ;;
	esac

	# Ahead/behind vs the remote branch.
	case "${disp_ab_state[$i]}" in
		up-to-date) printf '     ahead/behind: %sup to date%s\n' "$C_GREEN" "$C_RESET" ;;
		diverged)   printf '     ahead/behind: %s%s%s\n' "$C_YELLOW" "${disp_ab[$i]}" "$C_RESET" ;;
		*)          printf '     ahead/behind: %s%s%s\n' "$C_DIM" "${disp_ab[$i]}" "$C_RESET" ;;
	esac

	# Show the full path for any folder that is not a clean sibling, so the
	# user can see exactly where it lives.
	if [ "${disp_loc[$i]}" != "sibling" ]; then
		printf '     path:    %s\n' "${disp_path[$i]}"
	fi
	printf '%s\n' ""
done

# --- summary -----------------------------------------------------------------
with_remote=0
exists_count=0
deleted_count=0
unknown_count=0
no_remote=0
separate=0
not_separate=0
dirty_count=0
untracked_count=0
missing_count=0
ab_up_to_date=0
ab_diverged=0
mismatch_count=0
for i in "${!disp_branch[@]}"; do
	case "${disp_remote_state[$i]}" in
		none)    no_remote=$((no_remote+1)) ;;
		exists)  exists_count=$((exists_count+1)); with_remote=$((with_remote+1)) ;;
		deleted) deleted_count=$((deleted_count+1)); with_remote=$((with_remote+1)) ;;
		*)       unknown_count=$((unknown_count+1)); with_remote=$((with_remote+1)) ;;
	esac
	case "${disp_loc[$i]}" in
		sibling) separate=$((separate+1)) ;;
		*) not_separate=$((not_separate+1)) ;;
	esac
	case "${disp_dirty[$i]}" in
		yes) dirty_count=$((dirty_count+1)) ;;
		missing) missing_count=$((missing_count+1)) ;;
	esac
	case "${disp_untracked[$i]}" in
		missing) : ;;
		0) : ;;
		*) untracked_count=$((untracked_count+1)) ;;
	esac
	case "${disp_ab_state[$i]}" in
		up-to-date) ab_up_to_date=$((ab_up_to_date+1)) ;;
		diverged)   ab_diverged=$((ab_diverged+1)) ;;
	esac
	[ "${disp_mismatch[$i]}" = "1" ] && mismatch_count=$((mismatch_count+1))
done

printf '%s\n' ""
printf '%s\n' "Summary: $count worktree(s)"
printf '  remote branch: %d with ( %d exists, %d deleted, %d unverified ), %d without\n' \
	"$with_remote" "$exists_count" "$deleted_count" "$unknown_count" "$no_remote"
printf '  separate sibling folders: %d yes, %d no (nested/outside)\n' \
	"$separate" "$not_separate"
printf '  tracked changes: %d   untracked files: %d   missing folders: %d\n' \
	"$dirty_count" "$untracked_count" "$missing_count"
printf '  ahead/behind: %d up to date, %d diverged, %d n/a\n' \
	"$ab_up_to_date" "$ab_diverged" "$((count - ab_up_to_date - ab_diverged))"
printf '  branch ≠ folder: %d\n' "$mismatch_count"
