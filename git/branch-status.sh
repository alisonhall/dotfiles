#!/usr/bin/env bash
# branch-status.sh — report the status of one or more LOCAL git branches
# compared against a base branch (default: origin/main).
#
# For each branch it reports:
#   * REMOTE        — does a remote branch exist? Three states:
#                       exists        a branch.<name>.remote is set AND the ref
#                                     is present on the remote (verified with a
#                                     single `git ls-remote`, not the stale local
#                                     remote-tracking ref)
#                       deleted       the branch was pushed (upstream configured)
#                                     but the remote ref is gone (deleted + pruned)
#                       never-pushed  no upstream was ever configured
#   * AHEAD/BEHIND  — how the local branch compares to the remote branch. When
#                       the remote branch still exists this is the usual
#                       `git rev-list --left-right --count` vs <remote>/<branch>.
#                       When the remote branch was DELETED it falls back to the
#                       PR's head commit (headRefOid), so a stale local snapshot
#                       that is simply behind the PR head still reads correctly.
#   * PR            — the state of the PR whose head is this branch, via `gh`:
#                       open / merged / closed (closed-without-merge) / none.
#   * WORKTREE      — whether a worktree has this branch checked out (and where).
#   * IN BASE       — whether the branch's work is already in the base branch,
#                       detected in a way that is AGNOSTIC to the merge
#                       technique (merge / squash / rebase). Because a squash
#                       merge creates a brand-new commit on the base, plain
#                       ancestry checks (git branch --merged, merge-base
#                       --is-ancestor) do NOT work for squash. We therefore
#                       combine three independent signals and report which one
#                       fired:
#                         pr        a PR for this branch is MERGED
#                         ancestor  the branch tip is an ancestor of the base
#                                   (true merge / rebase-onto-base)
#                         content   for every file the branch changed, the base's
#                                   content is byte-identical to the branch's
#                                   (the net change is in the base, however it
#                                   got there — this is the squash case)
#                       If none fire, the branch is NOT in the base (it may hold
#                       unrecovered work).
#
# This is a READ-ONLY, repo-AGNOSTIC git tool: it operates on the git repo you
# run it from (any worktree or the main checkout) and does NOT depend on the wt
# worktree tooling. It runs `git fetch --prune` first (default) so the
# remote-existence and ahead/behind numbers are current; pass --no-fetch to skip
# it (faster / offline).
#
# Usage:
#   branch-status.sh [options] [branch ...]
#
#   With no branch arguments, EVERY local branch (except the base) is reported.
#   With one or more branch arguments, only those are reported.
#
#   Options:
#     --base <ref>        base branch to compare against (default: <remote>/main)
#     --remote <name>     remote to compare against (default: origin)
#     --no-fetch          skip the fetch; use last-fetched refs
#     --fetch             explicit fetch (same as default)
#     --fetch-period <m>  only re-fetch if the last fetch was more than <m>
#                         minutes ago (throttles repeated runs; default: always)
#     --dates             show each branch's last-commit date (YYYY-MM-DD)
#     --local-only        only list branches with NO upstream (local-only);
#                         by default every local branch is listed
#     -h, --help          show help
#
# Output is colour-coded when stdout is a TTY (and NO_COLOR is unset).
#
# Invoked by the branch-report git alias (see git/gitconfig). Complements the
# vendored bin/git-branch-status: this one adds PR state (via gh), worktree
# awareness, and squash-merge-aware "in base" detection.

set -uo pipefail

# Batch script: never page. These override the caller's pager settings, so save
# the originals first and restore them on exit (via trap, so it also covers
# early exits and errors) — we must not leak pager overrides into the shell.
_orig_PAGER="${PAGER-__BS_UNSET__}"
_orig_GIT_PAGER="${GIT_PAGER-__BS_UNSET__}"
_orig_GH_PAGER="${GH_PAGER-__BS_UNSET__}"
export GIT_PAGER=cat
export GH_PAGER=cat
export PAGER=cat

_restore_pagers() {
	[ "$_orig_PAGER" = "__BS_UNSET__" ] && unset PAGER || { PAGER="$_orig_PAGER"; export PAGER; }
	[ "$_orig_GIT_PAGER" = "__BS_UNSET__" ] && unset GIT_PAGER || { GIT_PAGER="$_orig_GIT_PAGER"; export GIT_PAGER; }
	[ "$_orig_GH_PAGER" = "__BS_UNSET__" ] && unset GH_PAGER || { GH_PAGER="$_orig_GH_PAGER"; export GH_PAGER; }
}
trap _restore_pagers EXIT

# --- options -----------------------------------------------------------------
FETCH=1
FETCH_PERIOD=""
SHOW_DATES=0
LOCAL_ONLY=0
REMOTE_NAME="origin"
BASE=""
BRANCHES=()
while [ $# -gt 0 ]; do
	case "$1" in
		--fetch) FETCH=1 ;;
		--no-fetch) FETCH=0 ;;
		--fetch-period)
			[ -n "${2:-}" ] || { echo "--fetch-period needs a value (minutes)" >&2; exit 2; }
			FETCH_PERIOD="$2"; shift ;;
		--fetch-period=*) FETCH_PERIOD="${1#*=}" ;;
		--dates) SHOW_DATES=1 ;;
		--local-only) LOCAL_ONLY=1 ;;
		--base)
			[ -n "${2:-}" ] || { echo "--base needs a value (e.g. origin/main)" >&2; exit 2; }
			BASE="$2"; shift ;;
		--base=*) BASE="${1#*=}" ;;
		--remote)
			[ -n "${2:-}" ] || { echo "--remote needs a value (e.g. origin)" >&2; exit 2; }
			REMOTE_NAME="$2"; shift ;;
		--remote=*) REMOTE_NAME="${1#*=}" ;;
		-h|--help)
			sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		--) shift; while [ $# -gt 0 ]; do BRANCHES+=("$1"); shift; done ;;
		-*)
			echo "branch-status: unknown option: $1 (see -h)" >&2
			exit 2
			;;
		*) BRANCHES+=("$1") ;;
	esac
	shift
done
[ -z "$BASE" ] && BASE="${REMOTE_NAME}/main"

# --- anchor ------------------------------------------------------------------
# Operate on the git repo we're run from. `git rev-parse --show-toplevel` works
# from any worktree or the main checkout and returns a valid worktree root, so
# every git op below is anchored there and behaves identically regardless of
# which worktree the user is in.
if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
	echo "branch-status: not run inside a git repository." >&2
	exit 1
fi

# Derive the GitHub repo slug (owner/repo) from the remote URL so `gh` calls
# work with no external config. Empty when the remote is missing or not a
# GitHub URL (PR lookup is then skipped).
REPO_SLUG="$(git -C "$REPO_ROOT" remote get-url "$REMOTE_NAME" 2>/dev/null \
	| sed -E 's#^git@github\.com:##; s#^https?://github\.com/##; s#\.git$##; s#/$##')"

# The base must resolve to a commit.
if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null 2>&1; then
	echo "branch-status: base '$BASE' does not resolve to a commit." >&2
	exit 1
fi

# --- colour ------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
	C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
else
	C_RESET=""; C_BOLD=""; C_DIM=""; C_GREEN=""; C_RED=""; C_YELLOW=""
fi

# --- fetch + remote head list ------------------------------------------------
# Optional fetch throttling: when --fetch-period <m> is set, skip the fetch if
# the last fetch (recorded in a per-repo cache file) is younger than <m> minutes.
# This keeps repeated status runs fast without a network round-trip each time.
DO_FETCH=1
if [ "$FETCH" = "1" ] && [ -n "$FETCH_PERIOD" ]; then
	# Per-repo cache file so different repos don't share a throttle window.
	repo_hash="$(printf '%s' "$REPO_ROOT" | md5 -q 2>/dev/null || printf '%s' "$REPO_ROOT" | shasum 2>/dev/null | cut -c1-12)"
	cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/branch-status"
	cache_file="$cache_dir/last-fetch-${repo_hash:-default}"
	now_ts="$(date +%s)"
	last_ts="$(cat "$cache_file" 2>/dev/null || echo 0)"
	case "$last_ts" in ''|*[!0-9]*) last_ts=0 ;; esac
	if [ $(( now_ts - last_ts )) -lt $(( FETCH_PERIOD * 60 )) ]; then
		DO_FETCH=0
	fi
fi
if [ "$FETCH" = "1" ] && [ "$DO_FETCH" = "1" ]; then
	if git -C "$REPO_ROOT" fetch --prune "$REMOTE_NAME" --quiet 2>/dev/null; then
		# Record the fetch time only on success (a failed fetch shouldn't extend
		# the throttle window).
		if [ -n "$FETCH_PERIOD" ]; then
			mkdir -p "$cache_dir" 2>/dev/null && date +%s > "$cache_file" 2>/dev/null
		fi
	else
		echo "branch-status: warning: fetch from $REMOTE_NAME failed; remote state may be stale." >&2
	fi
fi

# Authoritative list of branches currently on the remote (one network call).
REMOTE_HEADS=""
REMOTE_FETCH_OK=0
if REMOTE_HEADS="$(git -C "$REPO_ROOT" ls-remote --heads "$REMOTE_NAME" 2>/dev/null | awk '{print $2}')"; then
	REMOTE_FETCH_OK=1
fi

# 0 exists, 1 not on remote, 2 could not query (offline).
remote_branch_exists() {
	local branch="$1"
	[ "$REMOTE_FETCH_OK" = "1" ] || return 2
	grep -qxF "refs/heads/${branch}" <<< "$REMOTE_HEADS" 2>/dev/null
}

# --- worktree map ------------------------------------------------------------
# Precompute the worktree list once (branch<TAB>path). bash 3.2 (macOS default)
# has no associative arrays, so lookups grep this string instead.
WT_LIST="$(git -C "$REPO_ROOT" worktree list --porcelain \
	| awk '/^worktree /{p=$2} /^branch /{b=$2; sub("refs/heads/","",b); printf "%s\t%s\n", b, p}')"

# Echo the worktree path for a branch (first match), or nothing.
worktree_for_branch() {
	local branch="$1"
	[ -n "$WT_LIST" ] || return 0
	awk -F'\t' -v b="$branch" '$1 == b { print $2; exit }' <<< "$WT_LIST"
}

# --- current branch + head date ----------------------------------------------
# The branch we're currently on (for the leading '*' marker).
CURRENT_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

# Echo a branch's last-commit date (YYYY-MM-DD), or nothing.
head_date() {
	local branch="$1"
	git -C "$REPO_ROOT" log -1 --format=%ai "$branch" 2>/dev/null | cut -c1-10
}

# --- PR lookup (cached per branch) -------------------------------------------
# Sets PR_STATE (open|merged|closed|none), PR_NUM, PR_HEAD_OID.
# A single `gh pr list --head <branch> --state all`, preferring a merged PR's
# headRefOid for the ahead/behind fallback.
PR_STATE=""; PR_NUM=""; PR_HEAD_OID=""
lookup_pr() {
	local branch="$1"
	PR_STATE="none"; PR_NUM=""; PR_HEAD_OID=""
	command -v gh >/dev/null 2>&1 || return 0
	[ -n "$REPO_SLUG" ] || return 0
	local prs num state oid open_pr="" merged_oid="" merged_pr="" closed_oid="" closed_pr=""
	prs=$(gh pr list --repo "$REPO_SLUG" --head "$branch" --state all \
		--json number,state,headRefOid \
		--jq '.[] | "\(.number)\t\(.state)\t\(.headRefOid)"' 2>/dev/null || true)
	while IFS=$'\t' read -r num state oid; do
		[ -z "$num" ] && continue
		case "$state" in
			OPEN)   open_pr="$num" ;;
			MERGED) [ -z "$merged_oid" ] && { merged_oid="$oid"; merged_pr="$num"; } ;;
			*)      [ -z "$closed_oid" ] && { closed_oid="$oid"; closed_pr="$num"; } ;;
		esac
	done <<< "$prs"
	if [ -n "$open_pr" ]; then
		PR_STATE="open"; PR_NUM="$open_pr"
	elif [ -n "$merged_oid" ]; then
		PR_STATE="merged"; PR_NUM="$merged_pr"; PR_HEAD_OID="$merged_oid"
	elif [ -n "$closed_oid" ]; then
		PR_STATE="closed"; PR_NUM="$closed_pr"; PR_HEAD_OID="$closed_oid"
	fi
	return 0
}

# --- "in base" detection (merge/squash/rebase agnostic) ----------------------
# Sets IN_BASE (yes|no) and IN_BASE_HOW (pr|ancestor|content|none).
in_base() {
	local branch="$1"
	IN_BASE="no"; IN_BASE_HOW="none"

	# 1. PR merged (covers squash + merge + rebase, since the PR was merged).
	if [ "$PR_STATE" = "merged" ]; then
		IN_BASE="yes"; IN_BASE_HOW="pr"; return 0
	fi

	# 2. Ancestor of the base (true merge / rebase-onto-base).
	if git -C "$REPO_ROOT" merge-base --is-ancestor "$branch" "$BASE" 2>/dev/null; then
		IN_BASE="yes"; IN_BASE_HOW="ancestor"; return 0
	fi

	# 3. Content identical for every file the branch changed (the squash case:
	#    the net change is in the base even though the commits are not ancestors).
	local mb f files=()
	mb=$(git -C "$REPO_ROOT" merge-base "$branch" "$BASE" 2>/dev/null || true)
	[ -z "$mb" ] && return 0
	while IFS= read -r f; do
		[ -n "$f" ] && files+=("$f")
	done < <(git -C "$REPO_ROOT" diff --name-only "$mb" "$branch" 2>/dev/null)
	if [ "${#files[@]}" -gt 0 ] && git -C "$REPO_ROOT" diff --quiet "$BASE" "$branch" -- "${files[@]}" 2>/dev/null; then
		IN_BASE="yes"; IN_BASE_HOW="content"
	fi
	return 0
}

# --- ahead/behind ------------------------------------------------------------
# Sets AB_TEXT and AB_STATE.
#   ref = <remote>/<branch> when the remote exists, else the PR headRefOid when
#   the remote was deleted, else none.
ahead_behind() {
	local branch="$1" rstate="$2"
	AB_TEXT="n/a"; AB_STATE="n/a"
	local ref=""
	if [ "$rstate" = "exists" ]; then
		ref="${REMOTE_NAME}/${branch}"
	elif [ "$rstate" = "deleted" ] && [ -n "$PR_HEAD_OID" ]; then
		# Ensure the PR head object is present (it usually is, being the branch tip).
		if ! git -C "$REPO_ROOT" cat-file -e "$PR_HEAD_OID" 2>/dev/null; then
			git -C "$REPO_ROOT" fetch --quiet "$REMOTE_NAME" "$PR_HEAD_OID" 2>/dev/null || true
		fi
		if git -C "$REPO_ROOT" cat-file -e "$PR_HEAD_OID" 2>/dev/null; then
			ref="$PR_HEAD_OID"
		fi
	fi
	[ -z "$ref" ] && return 0
	local counts ahead behind
	if counts="$(git -C "$REPO_ROOT" rev-list --left-right --count "${branch}...${ref}" 2>/dev/null)"; then
		# left = commits on branch not on ref (ahead); right = on ref not on branch (behind)
		read -r ahead behind <<< "$counts"
		if [ "${ahead:-0}" -eq 0 ] && [ "${behind:-0}" -eq 0 ]; then
			AB_TEXT="up to date"; AB_STATE="up-to-date"
		else
			AB_TEXT="ahead ${ahead}, behind ${behind}"
			AB_STATE="diverged"
		fi
	else
		AB_TEXT="n/a (not fetched)"; AB_STATE="n/a"
	fi
	return 0
}

# --- resolve the branch list -------------------------------------------------
if [ "${#BRANCHES[@]}" -eq 0 ]; then
	# All local branches except the base (and its short name). With --local-only,
	# keep only branches that have NO upstream (i.e. are local-only).
	local_base_short="${BASE##*/}"
	while IFS= read -r b; do
		[ -z "$b" ] && continue
		[ "$b" = "$BASE" ] && continue
		[ "$b" = "$local_base_short" ] && continue
		if [ "$LOCAL_ONLY" = "1" ]; then
			[ -z "$(git -C "$REPO_ROOT" config "branch.${b}.remote" 2>/dev/null)" ] || continue
		fi
		BRANCHES+=("$b")
	done < <(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' refs/heads/)
fi

if [ "${#BRANCHES[@]}" -eq 0 ]; then
	echo "branch-status: no branches to report."
	exit 0
fi

# --- report ------------------------------------------------------------------
printf '%s\n' "Branch status vs ${C_BOLD}${BASE}${C_RESET}  (read-only; nothing is modified)"
printf '%s\n' "remote: $REMOTE_NAME   repo: ${REPO_SLUG:-<unset>}"
printf '%s\n' ""

n=0
sum_exists=0; sum_deleted=0; sum_never=0; sum_unknown=0
sum_open=0; sum_merged=0; sum_closed=0; sum_nopr=0
sum_inbase=0; sum_notinbase=0
sum_wt=0; sum_ahead=0; sum_behind=0; sum_uptodate=0

for branch in "${BRANCHES[@]}"; do
	n=$((n+1))
	[ "$branch" = "$CURRENT_BRANCH" ] && star="*" || star=" "

	# Does the local branch exist?
	if ! git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/${branch}"; then
		printf '%s%d. %s%s%s  %s(not a local branch)%s\n' "$star" "$n" "$C_BOLD" "$branch" "$C_RESET" "$C_RED" "$C_RESET"
		printf '%s\n' ""
		continue
	fi

	# Remote state.
	upstream_remote="$(git -C "$REPO_ROOT" config "branch.${branch}.remote" 2>/dev/null || true)"
	if [ -z "$upstream_remote" ]; then
		rstate="never-pushed"; rdisp="-"
	elif [ "$upstream_remote" != "$REMOTE_NAME" ]; then
		rstate="unknown"; rdisp="${upstream_remote}/${branch} (unverified)"
	else
		rdisp="${REMOTE_NAME}/${branch}"
		remote_branch_exists "$branch"
		case $? in
			0) rstate="exists" ;;
			1) rstate="deleted"; rdisp="${rdisp} (deleted)" ;;
			*) rstate="unknown"; rdisp="${rdisp} (unverified)" ;;
		esac
	fi

	# PR state.
	lookup_pr "$branch"

	# Ahead/behind.
	ahead_behind "$branch" "$rstate"

	# In-base detection.
	in_base "$branch"

	# Worktree.
	wt="$(worktree_for_branch "$branch")"

	# --- print block ---
	printf '%s%d. %s%s%s\n' "$star" "$n" "$C_BOLD" "$branch" "$C_RESET"
	if [ "$SHOW_DATES" = "1" ]; then
		hd="$(head_date "$branch")"
		[ -n "$hd" ] && printf '     head:     %s%s%s\n' "$C_DIM" "$hd" "$C_RESET"
	fi

	# Scope: local-only (no upstream) vs tracked (has an upstream).
	if [ "$rstate" = "never-pushed" ]; then
		printf '     scope:    %slocal-only%s (no upstream)\n' "$C_DIM" "$C_RESET"
	else
		printf '     scope:    %stracked%s\n' "$C_GREEN" "$C_RESET"
	fi

	case "$rstate" in
		exists)       printf '     remote:   %s%s%s\n' "$C_GREEN"  "$rdisp" "$C_RESET"; sum_exists=$((sum_exists+1)) ;;
		deleted)      printf '     remote:   %s%s%s\n' "$C_RED"    "$rdisp" "$C_RESET"; sum_deleted=$((sum_deleted+1)) ;;
		never-pushed) printf '     remote:   %s%s%s\n' "$C_DIM"    "$rdisp" "$C_RESET"; sum_never=$((sum_never+1)) ;;
		*)            printf '     remote:   %s%s%s\n' "$C_YELLOW" "$rdisp" "$C_RESET"; sum_unknown=$((sum_unknown+1)) ;;
	esac

	case "$AB_STATE" in
		up-to-date) printf '     a/b:      %s%s%s\n' "$C_GREEN"  "$AB_TEXT" "$C_RESET"; sum_uptodate=$((sum_uptodate+1)) ;;
		diverged)   printf '     a/b:      %s%s%s\n' "$C_YELLOW" "$AB_TEXT" "$C_RESET"
			# tally ahead/behind from the text
			case "$AB_TEXT" in
				"ahead "*) sum_ahead=$((sum_ahead+1)) ;;
			esac
			case "$AB_TEXT" in
				*" behind "*) sum_behind=$((sum_behind+1)) ;;
			esac
			;;
		*)          printf '     a/b:      %s%s%s\n' "$C_DIM"    "$AB_TEXT" "$C_RESET" ;;
	esac

	case "$PR_STATE" in
		open)   printf '     PR:       %s#%s open%s\n'   "$C_YELLOW" "$PR_NUM" "$C_RESET"; sum_open=$((sum_open+1)) ;;
		merged) printf '     PR:       %s#%s merged%s\n' "$C_GREEN"  "$PR_NUM" "$C_RESET"; sum_merged=$((sum_merged+1)) ;;
		closed) printf '     PR:       %s#%s closed%s\n' "$C_RED"    "$PR_NUM" "$C_RESET"; sum_closed=$((sum_closed+1)) ;;
		*)      printf '     PR:       %snone%s\n'       "$C_DIM"    "$C_RESET"; sum_nopr=$((sum_nopr+1)) ;;
	esac

	if [ -n "$wt" ]; then
		printf '     worktree: %syes%s (%s)\n' "$C_YELLOW" "$C_RESET" "$wt"
		sum_wt=$((sum_wt+1))
	else
		printf '     worktree: %snone%s\n' "$C_DIM" "$C_RESET"
	fi

	case "$IN_BASE" in
		yes)
			printf '     in base:  %sYES%s (%s)\n' "$C_GREEN" "$C_RESET" "$IN_BASE_HOW"
			sum_inbase=$((sum_inbase+1))
			;;
		*)
			printf '     in base:  %sNO%s (may hold unrecovered work)\n' "$C_RED" "$C_RESET"
			sum_notinbase=$((sum_notinbase+1))
			;;
	esac

	printf '%s\n' ""
done

# --- summary -----------------------------------------------------------------
printf '%s\n' ""
printf '%s\n' "Summary: $n branch(es) vs $BASE"
printf '  scope:    %d local-only, %d tracked\n' \
	"$sum_never" "$(( sum_exists + sum_deleted + sum_unknown ))"
printf '  remote:   %d exists, %d deleted, %d never-pushed, %d unverified\n' \
	"$sum_exists" "$sum_deleted" "$sum_never" "$sum_unknown"
printf '  PR:       %d open, %d merged, %d closed, %d none\n' \
	"$sum_open" "$sum_merged" "$sum_closed" "$sum_nopr"
printf '  in base:  %d yes, %d no\n' "$sum_inbase" "$sum_notinbase"
printf '  worktree: %d checked out in a worktree\n' "$sum_wt"
printf '  a/b:      %d up to date, %d ahead, %d behind, %d n/a\n' \
	"$sum_uptodate" "$sum_ahead" "$sum_behind" "$((n - sum_uptodate - sum_ahead - sum_behind))"
