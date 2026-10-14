#!/usr/bin/env bash
# wt-link.sh — check (and optionally fix) the standard symlinks in a worktree:
# node_modules (universal) plus the project-specific pairs from WT_SYMLINK_PAIRS
# (e.g. .cache, surfaces/app/.env), which should all point at the
# matching path in the main worktree. It also checks and fixes the workspace
# (@scope/*) override links that point @scope/* imports at THIS worktree's
# source (via link-workspaces.mjs).
#
# Usage:
#   wt-link <branch>          check & fix one worktree
#   wt-link --all             check & fix every worktree (except main)
#   wt-link --check <branch>  check only, make no changes
#   wt-link --check --all     check only, every worktree
#   wt-link --no-workspaces   skip the workspace (@scope/*) override step
#   wt-link -h                help
#
# The workspace-override step is ON by default; pass --no-workspaces to skip it
# (faster, e.g. for --all). It only runs when node_modules is a symlink to main
# (the shared model); a worktree with a real node_modules is skipped for that
# step (its root-symlink issue is still reported).
#
# A worktree is "correct" when each expected path is a symlink pointing at the
# matching path in the main worktree. Missing, dangling, or mis-pointed
# symlinks are re-created in fix mode. A path that is a REAL file/dir (not a
# symlink) is reported but NOT touched — it may hold real content (e.g. a local
# node_modules from an npm install), so destroying it is left to you.
#
# The expected symlink set comes from worktree_symlink_pairs() in
# wt-common.sh (the same source setup_worktree_symlinks uses).

set -uo pipefail

if [ -z "${WT_WORKTREE_REPO_LOCATION:-}" ]; then
	echo "error: WT_WORKTREE_REPO_LOCATION is not set." >&2
	echo "       Export it in ~/.shell_local (the worktree collection folder, e.g. \$HOME/Sites/fe)." >&2
	exit 2
fi
REPO_ROOT="$WT_WORKTREE_REPO_LOCATION"

# Shared symlink target list (worktree_symlink_pairs).
source "$(cd "$(dirname "$0")" && pwd)/wt-common.sh"

CHECK_ONLY=0
ALL=0
NO_WORKSPACES=0
BRANCH=""

while [ $# -gt 0 ]; do
	case "$1" in
		--check) CHECK_ONLY=1 ;;
		--all) ALL=1 ;;
		--no-workspaces) NO_WORKSPACES=1 ;;
		-h|--help)
			sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		-*)
			echo "wt-link: unknown option: $1 (see -h)" >&2
			exit 2
			;;
		*)
			if [ -n "$BRANCH" ]; then
				echo "wt-link: unexpected argument: $1" >&2
				exit 2
			fi
			BRANCH="$1"
			;;
	esac
	shift
done

# The main worktree must be a valid git worktree. This works in BOTH layouts:
# the bare-repo layout (fe/.bare + fe/main worktree) and the normal-repo-at-main
# layout (fe/main/.git). The collection folder itself is not a git repo in the
# latter, so we anchor on main rather than the folder.
if ! git -C "$REPO_ROOT/main" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	echo "wt-link: no git worktree found at $REPO_ROOT/main."
	exit 1
fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd -P)"
# Anchor for central git ops (see the check above).
MAIN_WT="$REPO_ROOT/main"

if [ "$ALL" -eq 0 ] && [ -z "$BRANCH" ]; then
	echo "Usage: wt-link <branch> | --all   (add --check to only inspect)"
	exit 1
fi

# --- collect the worktrees to process ---------------------------------------
# Each entry is "<path>" (main is excluded — it is the symlink source).
targets=()
if [ "$ALL" -eq 1 ]; then
	while IFS= read -r line; do
		case "$line" in
			worktree\ *) wt_path="${line#worktree }" ;;
			branch\ *)   wt_branch="${line#branch refs/heads/}" ;;
			bare)        wt_bare=1 ;;
			"" )
				# End of a record. Skip the bare repo and the main worktree
				# (main is the source of the symlinks).
				if [ -n "${wt_path:-}" ] && [ -d "$wt_path" ] \
					&& [ "${wt_bare:-0}" -eq 0 ] && [ "${wt_branch:-}" != "main" ]; then
					targets+=("$wt_path")
				fi
				wt_path=""; wt_branch=""; wt_bare=0
				;;
		esac
	done < <(git -C "$MAIN_WT" worktree list --porcelain 2>/dev/null)
else
	local_branch="${BRANCH//\//_}"
	targets+=("$REPO_ROOT/$local_branch")
fi

if [ "${#targets[@]}" -eq 0 ]; then
	echo "wt-link: no worktrees to check."
	exit 0
fi

# --- per-worktree check/fix --------------------------------------------------
# Returns 0 if the worktree ends up fully correct, 1 if anything is (or was)
# not correct.
process_worktree() {
	local path="$1"
	local rel main_rel expected p actual state
	local ok=0 problem=0

	echo "Worktree: $(basename "$path")"

	while IFS=$'\t' read -r rel main_rel; do
		[ -z "$rel" ] && continue
		expected="$REPO_ROOT/$main_rel"
		p="$path/$rel"

		# The main target must exist, otherwise a valid symlink is impossible.
		if [ ! -e "$expected" ]; then
			echo "  $rel:  main target missing ($main_rel) — skipped"
			problem=$((problem+1))
			continue
		fi

		# -ef: the same file or folder as main's, through a symlink, a Windows junction or a
		# Windows hard link (see make_link in wt-common.sh)
		if [ "$p" -ef "$expected" ]; then
			state="ok"
		elif [ -L "$p" ]; then
			if [ -e "$p" ]; then
				state="wrong"
			else
				state="broken"
			fi
		elif [ -e "$p" ]; then
			state="real"
		else
			state="missing"
		fi

		case "$state" in
			ok)
				echo "  $rel:  ok"
				ok=$((ok+1))
				;;
			real)
				echo "  $rel:  REAL file/dir (expected symlink) — not touched"
				if wt_is_windows && [ -f "$p" ]; then
					# A hard link stops being shared when an editor saves by replacing the file
					echo "         (if it's an old copy of main's, delete it and run wt link again)"
				fi
				problem=$((problem+1))
				;;
			missing|broken|wrong)
				if [ "$CHECK_ONLY" -eq 1 ]; then
					echo "  $rel:  $state — would re-create -> $expected"
					problem=$((problem+1))
				else
					# Remove a stale/dangling/mis-pointed symlink (never a real
					# file/dir), ensure the parent dir exists, and re-link.
					[ -L "$p" ] && rm "$p"
					mkdir -p "$(dirname "$p")"
					if make_link "$expected" "$p"; then
						echo "  $rel:  $state -> fixed (now -> $expected)"
						ok=$((ok+1))
					else
						echo "  $rel:  $state -> FAILED to create symlink"
						problem=$((problem+1))
					fi
				fi
				;;
		esac
	done < <(worktree_symlink_pairs)

	# --- workspace (@scope/*) override links ---------------------------------
	# Only meaningful when node_modules is a symlink to main (the shared model).
	# In fix mode the root loop above has already re-pointed node_modules, so the
	# overrides resolve against the correct shared node_modules. Skipped entirely
	# with --no-workspaces.
	if [ "$NO_WORKSPACES" -eq 1 ]; then
		echo "  workspaces: skipped (--no-workspaces)"
	elif [ -L "$path/node_modules" ]; then
		if ! command -v node >/dev/null 2>&1; then
			echo "  workspaces: skipped (node not found)"
		else
			local mjs ws_out ws_rc
			mjs="$(cd "$(dirname "$0")" && pwd)/link-workspaces.mjs"
			if [ "$CHECK_ONLY" -eq 1 ]; then
				ws_out="$(node "$mjs" "$path" --relative --check 2>&1)"; ws_rc=$?
				if [ "$ws_rc" -eq 0 ]; then
					echo "  workspaces: ok"
				else
					echo "  workspaces: issues found (check-only; re-run without --check to fix)"
					while IFS= read -r l; do
						case "$l" in "  "*) echo "$l" ;; esac
					done <<< "$ws_out"
					problem=$((problem+1))
				fi
			else
				ws_out="$(node "$mjs" "$path" --relative 2>&1)"; ws_rc=$?
				if [ "$ws_rc" -eq 0 ]; then
					echo "  workspaces: linked"
				else
					echo "  workspaces: FAILED to link"
					problem=$((problem+1))
				fi
			fi
		fi
	else
		echo "  workspaces: skipped (node_modules is not a symlink to main)"
	fi

	if [ "$problem" -eq 0 ]; then
		echo "  result: all symlinks correct"
		return 0
	else
		echo "  result: $problem issue(s)"
		return 1
	fi
}

# --- run ---------------------------------------------------------------------
overall=0
for t in "${targets[@]}"; do
	if [ ! -d "$t" ]; then
		echo "Worktree: $(basename "$t")  (folder missing — skipped)"
		overall=1
		echo
		continue
	fi
	process_worktree "$t" || overall=1
	echo
done

if [ "$overall" -eq 0 ]; then
	echo "All checked worktrees have correct symlinks."
else
	if [ "$CHECK_ONLY" -eq 1 ]; then
		echo "Issues found (check-only; re-run without --check to fix)."
	else
		echo "Done; some issues could not be auto-fixed (see above)."
	fi
fi
exit "$overall"
