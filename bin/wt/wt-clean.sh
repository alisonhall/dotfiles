#!/usr/bin/env bash
#
# wt-clean.sh
#
# Clean up git worktree folders under the configured worktree collection folder
# (a bare-repo + linked-worktrees layout) once their branch has been
# SQUASH-merged into main via a PR.
#
# Configuration (exported from ~/.shell_local; nothing is hardcoded here):
#   WT_WORKTREE_REPO_LOCATION  worktree collection folder (e.g. $HOME/Sites/fe)
#   WT_REPO_SLUG               GitHub repo slug (e.g. owner/repo)
#   WT_PROTECTED_BRANCHES      space-separated branches never removed (default: main)
#   WT_SAFE_ARTIFACTS          extra project-specific safe-to-discard names
#   CURRENT_REMOTE_NAME            git remote name (default: origin)
#
# Because the repo uses squash merges, git ancestry checks (git branch --merged,
# merge-base, git cherry) do NOT work — a squash creates a brand new commit on
# main. So "merged" is determined from the PR state via the `gh` CLI.
#
# A worktree is only removed when ALL of these are true:
#   1. Its PR is no longer open (closed — merged or closed-without-merge). An
#      open PR means the branch is still active.
#   2. The branch was actually pushed (branch.<name>.remote config is set; this
#      survives the remote branch being deleted + fetch --prune, unlike @{u}).
#   3. There are NO local-only commits: the local branch is at or behind the
#      remote branch (while it exists) or, once the remote branch is deleted,
#      at or behind the PR's head commit (headRefOid). A stale local snapshot
#      that is simply behind the PR head is fine (nothing local is lost).
#   4. There are NO uncommitted tracked changes (staged or modified), and NO
#      untracked or gitignored files that are not symlinks.
#   5. There are NO stashes belonging to this branch. NOTE: in a bare+worktree
#      layout refs/stash is SHARED repo-wide (refs/stash lives in the common
#      dir), so `git stash list` shows every worktree's stashes. We therefore
#      match stashes to this branch by their message ("WIP on <branch>:" /
#      "On <branch>:") rather than assuming per-worktree isolation.
#
# Anything that fails a gate is KEPT and reported with the reason.
#
# Usage:
#   wt-clean.sh                # dry run (default) - shows what WOULD be removed
#   wt-clean.sh --apply        # actually remove + prune + delete local branches
#   wt-clean.sh --keep-branch  # remove folders but keep the local branch
#   wt-clean.sh --older-than 30d  # only consider worktrees whose last
#                                          # commit is older than 30d (also: 12h, 4w)
#   wt-clean.sh -h             # help
#
set -euo pipefail

# This is a batch script: never page. Disable git's and gh's pagers so output
# goes straight to stdout even when run from an interactive terminal (a pager
# here would otherwise interleave "less" output with the report).
export GIT_PAGER=cat
export GH_PAGER=cat
export PAGER=cat

# Configuration is supplied by the environment (exported from
# ~/.shell_local, or overridden by a local file). Nothing project- or
# user-specific is hardcoded here, so the script works for any repo/machine.
if [[ -z "${WT_WORKTREE_REPO_LOCATION:-}" ]]; then
  echo "error: WT_WORKTREE_REPO_LOCATION is not set." >&2
  echo "       Export it in ~/.shell_local (the worktree collection folder, e.g. \$HOME/Sites/fe)." >&2
  exit 2
fi
if [[ -z "${WT_REPO_SLUG:-}" ]]; then
  echo "error: WT_REPO_SLUG is not set." >&2
  echo "       Export it in ~/.shell_local (the GitHub repo, e.g. owner/repo)." >&2
  exit 2
fi
REPO_ROOT="$WT_WORKTREE_REPO_LOCATION"
BARE="$REPO_ROOT/.bare"
# Anchor for central git ops: the main worktree is a valid git worktree in BOTH
# the bare-repo layout (fe/.bare + fe/main) and the normal-repo-at-main layout
# (fe/main/.git). The collection folder itself is not a git repo in the latter,
# so we anchor on main rather than the folder. BARE is kept only to skip the
# bare-repo entry in the worktree list (old layout); it is no longer a git anchor.
MAIN_WT="$REPO_ROOT/main"
REPO_SLUG="$WT_REPO_SLUG"
REMOTE_NAME="${CURRENT_REMOTE_NAME:-origin}"
# Branches that must never be removed (space-separated). Defaults to "main".
PROTECTED=(${WT_PROTECTED_BRANCHES:-main})

# Regenerable build artifacts that are safe to discard on removal (not user
# work). Gate 5 skips these so a worktree with a real node_modules / build
# output can still be cleaned up. The list below is universal; append any
# project-specific names via WT_SAFE_ARTIFACTS (space-separated), e.g.
# "bundle-analysis.html certificates" for repos that gitignore those.
# NOTE: .cache is NOT universal — not every repo shares a .cache dir. A repo
# that does should list it in WT_SAFE_ARTIFACTS.
SAFE_ARTIFACTS=(node_modules .yarn .DS_Store dist build coverage .next .nuxt out .turbo .parcel-cache .vite .pytest_cache __pycache__ .eslintcache)
if [[ -n "${WT_SAFE_ARTIFACTS:-}" ]]; then
  SAFE_ARTIFACTS+=(${WT_SAFE_ARTIFACTS})
fi

APPLY=0
KEEP_BRANCH=0
OLDER_THAN=""        # e.g. 30d, 12h, 4w
CUTOFF_EPOCH=""      # computed from OLDER_THAN

# Convert a duration like 30d / 12h / 4w / 90 (plain = days) to an epoch cutoff.
duration_to_cutoff() {
  local d="$1" num unit secs
  if [[ "$d" =~ ^([0-9]+)([smhdw])?$ ]]; then
    num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]:-d}"
    case "$unit" in
      s) secs=$num ;;
      m) secs=$((num*60)) ;;
      h) secs=$((num*3600)) ;;
      d) secs=$((num*86400)) ;;
      w) secs=$((num*604800)) ;;
    esac
    echo $(( $(date +%s) - secs ))
  else
    return 1
  fi
}

while (( $# )); do
  case "$1" in
    --apply) APPLY=1 ;;
    --keep-branch) KEEP_BRANCH=1 ;;
    --older-than)
      [[ -n "${2:-}" ]] || { echo "--older-than needs a value (e.g. 30d)" >&2; exit 2; }
      OLDER_THAN="$2"; shift ;;
    --older-than=*) OLDER_THAN="${1#*=}" ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1 (see -h)" >&2; exit 2 ;;
  esac
  shift
done

if [[ -n "$OLDER_THAN" ]]; then
  CUTOFF_EPOCH=$(duration_to_cutoff "$OLDER_THAN") \
    || { echo "Bad --older-than value: $OLDER_THAN (use 30d, 12h, 4w, 90m)" >&2; exit 2; }
fi

# --- sanity checks -----------------------------------------------------------
command -v gh >/dev/null || { echo "gh CLI is required but not installed." >&2; exit 1; }
# The main worktree must be a valid git worktree (works in both layouts).
git -C "$MAIN_WT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "No git worktree found at $MAIN_WT (set WT_WORKTREE_REPO_LOCATION)." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not authenticated. Run: gh auth login" >&2; exit 1; }

# Refresh remote refs so upstream comparisons are accurate.
git -C "$MAIN_WT" fetch --prune "$REMOTE_NAME" --quiet || echo "warn: fetch failed, using cached refs" >&2

# --- helpers -----------------------------------------------------------------
is_protected() {
  local name="$1" p
  for p in "${PROTECTED[@]}"; do [[ "$name" == "$p" ]] && return 0; done
  return 1
}

# True if a repo-relative path is (or is under) a known regenerable artifact.
# In a monorepo, build outputs and node_modules live INSIDE each package/surface
# subdirectory (e.g. packages/mp-bundler/dist, surfaces/x/.next, packages/node_modules),
# so we match a known artifact name at ANY path segment, not just the root.
is_safe_artifact() {
  local p="$1" a seg
  local IFS='/'
  for seg in $p; do
    for a in "${SAFE_ARTIFACTS[@]}"; do
      [[ "$seg" == "$a" ]] && return 0
    done
  done
  return 1
}

# Evaluates one worktree. Sets globals:
#   BLOCK_REASON  - short reason string (empty => safe to remove)
#   BLOCK_DETAIL  - optional extra lines to print under a KEEP (e.g. stash lines)
worktree_block_reason() {
  local wt="$1" branch="$2"
  BLOCK_REASON=""; BLOCK_DETAIL=""
  PR_STATE=""; PR_NUM=""

  # 1. Is the branch's PR closed (merged or closed-without-merge)? An open PR
  #    means the branch is still active. Capture the PR head commit (headRefOid)
  #    from a closed PR — prefer a merged one — to use as the "no local-only
  #    work" reference in gate 3.
  local prs num state oid
  local open_pr="" merged_oid="" merged_pr="" closed_oid="" closed_pr=""
  # PR state is literally OPEN / MERGED / CLOSED (closed-without-merge).
  prs=$(gh pr list --repo "$REPO_SLUG" --head "$branch" --state all \
                --json number,state,headRefOid \
                --jq '.[] | "\(.number)\t\(.state)\t\(.headRefOid)"' 2>/dev/null || true)
  while IFS=$'\t' read -r num state oid; do
    [[ -z "$num" ]] && continue
    if [[ "$state" == "OPEN" ]]; then
      open_pr="$num"
    elif [[ "$state" == "MERGED" ]]; then
      [[ -z "$merged_oid" ]] && { merged_oid="$oid"; merged_pr="$num"; }
    else
      # CLOSED (closed without merging)
      [[ -z "$closed_oid" ]] && { closed_oid="$oid"; closed_pr="$num"; }
    fi
  done <<< "$prs"
  local pr headRefOid
  if [[ -n "$open_pr" ]]; then
    BLOCK_REASON="open PR #$open_pr (branch still active)"; return 0
  fi
  if [[ -n "$merged_oid" ]]; then
    pr="$merged_pr"; headRefOid="$merged_oid"
    PR_STATE="merged"; PR_NUM="$pr"
  elif [[ -n "$closed_oid" ]]; then
    pr="$closed_pr"; headRefOid="$closed_oid"
    PR_STATE="closed"; PR_NUM="$pr"
  else
    BLOCK_REASON="no closed PR (branch has no merged or closed PR)"; return 0
  fi

  # 2. Was this branch ever pushed? Use the branch config, which survives the
  #    remote branch being deleted + fetch --prune (unlike @{u}, which breaks
  #    once origin/<branch> is pruned). Gate 1 (merged PR) already implies it
  #    was pushed; this is a safety net for branches that were never pushed.
  local upstream_remote
  upstream_remote=$(git -C "$wt" config "branch.${branch}.remote" 2>/dev/null || true)
  if [[ -z "$upstream_remote" ]]; then
    BLOCK_REASON="branch never pushed (no upstream)"; return 0
  fi

  # 3. Any local-only commits? The local branch must be at or behind the remote
  #    branch (while it exists) or, once the remote branch is deleted, at or
  #    behind the PR's head commit (headRefOid). A local branch that is simply
  #    BEHIND (a stale snapshot) has nothing local to lose, so it passes; only
  #    commits that exist on the local branch but NOT on the reference (ahead >
  #    0) block removal. headRefOid is the branch's own commit at PR time, so it
  #    is independent of how far main has advanced since the branch forked.
  local remote_ref="${upstream_remote}/${branch}"
  local ref ahead
  if git -C "$wt" rev-parse --verify --quiet "$remote_ref" >/dev/null 2>&1; then
    # Remote branch still exists: compare against it.
    ref="$remote_ref"
  else
    # Remote branch deleted: compare against the PR head commit.
    if [[ -z "$headRefOid" ]]; then
      BLOCK_REASON="remote branch deleted and no PR head commit to verify against"; return 0
    fi
    # headRefOid is normally the local branch tip (already present); fetch it as
    # a fallback (e.g. if the local branch was reset/rebased after the merge).
    if ! git -C "$wt" cat-file -e "$headRefOid" 2>/dev/null; then
      git -C "$wt" fetch --quiet "$upstream_remote" "$headRefOid" 2>/dev/null || true
    fi
    if ! git -C "$wt" cat-file -e "$headRefOid" 2>/dev/null; then
      BLOCK_REASON="cannot verify PR head commit ${headRefOid:0:8} (not fetched)"; return 0
    fi
    ref="$headRefOid"
  fi
  ahead=$(git -C "$wt" rev-list --count "${ref}..HEAD" 2>/dev/null || echo "?")
  if [[ "$ahead" != "0" ]]; then
    BLOCK_REASON="$ahead local commit(s) not on the remote branch/PR head (unmerged local work?)"
    return 0
  fi

  # 4. Uncommitted tracked changes, OR untracked/gitignored files that are NOT
  #    symlinks? Symlinks (e.g. the node_modules -> main/node_modules pointer)
  #    are safe to discard on removal; a real file (new work you added, or a
  #    gitignored local file) is not, so it blocks removal and is reported.
  #    'worktree remove --force' deletes the whole directory, including
  #    gitignored files, so those must block too.
  if [[ -n "$(git -C "$wt" status --porcelain --untracked-files=no)" ]]; then
    BLOCK_REASON="uncommitted tracked changes"; return 0
  fi
  local untracked uf bad_untracked="" bad_count=0
  # Union of untracked (non-ignored) and gitignored files. NOTE: the combined
  # form '--others --ignored --exclude-standard' returns ONLY ignored files and
  # drops untracked ones, so we must take the union of the two lists. Skip
  # symlinks and known regenerable build artifacts; anything else is potential
  # user work and blocks removal.
  untracked=$({ git -C "$wt" ls-files --others --exclude-standard
                git -C "$wt" ls-files --others --ignored --exclude-standard; } | sort -u)
  while IFS= read -r uf; do
    [[ -z "$uf" ]] && continue
    [[ -L "$wt/$uf" ]] && continue
    is_safe_artifact "$uf" && continue
    bad_untracked+="$uf"$'\n'
    ((bad_count++)) || true
  done <<< "$untracked"
  if [[ -n "$bad_untracked" ]]; then
    BLOCK_REASON="$bad_count untracked/ignored file(s) present (not a symlink/artifact)"
    return 0
  fi

  # 5. Stashes belonging to this branch? refs/stash is SHARED repo-wide, so scan
  #    all stashes and match by the branch name in the stash message. The trailing
  #    colon anchors the match so 'foo' does not match 'foo-bar'. Case-insensitive
  #    to catch both "WIP on <branch>:" and "On <branch>:" forms. Print the exact
  #    matching stash lines so the user can see what is blocking removal.
  local stash_lines stash_count
  stash_lines=$(git -C "$wt" stash list 2>/dev/null | grep -iF "on ${branch}:" || true)
  if [[ -n "$stash_lines" ]]; then
    stash_count=$(printf '%s\n' "$stash_lines" | grep -c .)
    BLOCK_REASON="kept: $stash_count stash(es) for this branch (review/drop them before removal)"
    BLOCK_DETAIL=$(printf '%s\n' "$stash_lines" | sed 's/^/        stash: /')
    return 0
  fi

  # all gates passed
  return 0
}

# --- main --------------------------------------------------------------------
if (( APPLY )); then echo "== APPLY MODE: removing worktrees =="; else echo "== DRY RUN (use --apply to remove) =="; fi
echo "repo: $REPO_SLUG   root: $REPO_ROOT"
echo

removed=0
kept=0

# Global blocker: stashes not attributable to any branch ("On (no branch):"),
# e.g. created on a detached HEAD (during a rebase) or after a branch rename.
# These are NOT lost by deleting a folder (refs/stash is shared and survives
# branch/folder removal), but we cannot tell which folder they belong to, so we
# refuse to remove anything until the user reviews them explicitly.
# refs/stash is shared repo-wide, so any worktree can list it; use the first
# non-bare worktree (not specifically one named "main").
ANY_WT=$(git -C "$MAIN_WT" worktree list --porcelain | awk -v bare="$BARE" '/^worktree /{if ($2 != bare) {print $2; exit}}')
UNATTRIBUTED_STASHES=""
if [[ -n "$ANY_WT" ]]; then
  UNATTRIBUTED_STASHES=$(git -C "$ANY_WT" stash list 2>/dev/null | grep -iF "on (no branch):" || true)
fi
if [[ -n "$UNATTRIBUTED_STASHES" ]]; then
  echo "NOTE: found stash(es) not tied to a branch (detached HEAD / renamed branch)."
  printf '%s\n' "$UNATTRIBUTED_STASHES" | sed 's/^/  stash: /'
  echo "  These are safe from deletion but block removal until reviewed."
  echo "  Review with: git -C <worktree> stash list   (clear with: git stash drop stash@{N})"
  echo
fi

# Iterate registered worktrees (skip the bare repo itself).
# Read from fd 3 (not fd 0) so that commands inside the loop body that read
# stdin (e.g. git/gh/sort) inherit the script's real stdin instead of draining
# the worktree list being fed to this loop.
while IFS=$'\t' read -r path branch <&3; do
  [[ "$path" == "$BARE" ]] && continue
  [[ ! -d "$path" ]] && continue

  name=$(basename "$path")

  if is_protected "$branch"; then
    printf 'KEEP  %-60s (protected branch: %s)\n' "$name" "$branch"
    ((kept++)) || true
    continue
  fi

  if [[ -z "$branch" ]]; then
    printf 'KEEP  %-60s (detached HEAD - not managed here)\n' "$name"
    ((kept++)) || true
    continue
  fi

  # Optional age filter: skip worktrees whose last commit is newer than cutoff.
  if [[ -n "$CUTOFF_EPOCH" ]]; then
    local_epoch=$(git -C "$path" log -1 --format=%ct 2>/dev/null || echo "")
    if [[ -z "$local_epoch" || "$local_epoch" -gt "$CUTOFF_EPOCH" ]]; then
      printf 'KEEP  %-60s [%s] -> newer than --older-than %s\n' "$name" "$branch" "$OLDER_THAN"
      ((kept++)) || true
      continue
    fi
  fi

  worktree_block_reason "$path" "$branch"

  if [[ -n "$UNATTRIBUTED_STASHES" ]]; then
    printf 'KEEP  %-60s [%s] -> unattributed stash present (see note above)\n' "$name" "$branch"
    ((kept++)) || true
    continue
  fi

  if [[ -n "$BLOCK_REASON" ]]; then
    printf 'KEEP  %-60s [%s] -> %s\n' "$name" "$branch" "$BLOCK_REASON"
    [[ -n "$BLOCK_DETAIL" ]] && printf '%s\n' "$BLOCK_DETAIL"
    ((kept++)) || true
    continue
  fi

  # Safe to remove.
  if (( APPLY )); then
    # --force is safe here: gate 5 already guarantees the only untracked items
    # left are symlinks (e.g. node_modules), which --force discards without
    # touching the real files they point at. Tracked changes and stashes are
    # already blocked by gates 5 and 6.
    if git -C "$MAIN_WT" worktree remove --force "$path"; then
      if (( ! KEEP_BRANCH )); then
        git -C "$MAIN_WT" branch -D "$branch" >/dev/null 2>&1 || true
      fi
      printf 'GONE  %-60s [%s] removed\n' "$name" "$branch"
    else
      printf 'KEEP  %-60s [%s] -> worktree remove refused (dirty?)\n' "$name" "$branch"
      ((kept++)) || true
      continue
    fi
  else
    printf 'RM    %-60s [%s] (would remove) [%s PR #%s]\n' "$name" "$branch" "$PR_STATE" "$PR_NUM"
  fi
  ((removed++)) || true

done 3< <(git -C "$MAIN_WT" worktree list --porcelain \
  | awk '/^worktree /{p=$2} /^branch /{b=$2; sub("refs/heads/","",b); printf "%s\t%s\n", p, b}')

echo
if (( APPLY )); then
  git -C "$MAIN_WT" worktree prune
  echo "Done. Removed: $removed   Kept: $kept"
else
  echo "Would remove: $removed   Kept: $kept   (re-run with --apply)"
fi
