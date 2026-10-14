#!/usr/bin/env bash
#
# wt.sh — single entry point for the wt worktree tooling. DUAL-MODE:
#
#   * SOURCED (from shell/common/git.sh): defines the interactive `wt` function
#     in the current shell. It must be defined in the interactive shell because
#     `wt add`/`wt cd`/`wt main` need to `cd` that shell, which a subshell
#     script cannot do. Sourcing has NO side effects on shell options.
#
#   * EXECUTED (bash wt.sh <sub> [args...]): dispatches to the matching
#     wt-*.sh script in this folder.
#
# Subcommands: add, cd, rm, ls, link, clean, help
#
# shell/common/git.sh only needs to source this file (`. "$WT_DIR/wt.sh"`) —
# no per-command aliases. `wt help` lists every command, description, and option.

# --- resolve this folder + detect sourced-vs-executed (works in bash or zsh) ---
# zsh and bash expose the sourced-file path differently, so branch on shell.
# (zsh 5.9 rejects ${.sh.file} as a bad substitution, so we don't use it.)
_wt_sourced=0
if [ -n "${ZSH_VERSION:-}" ]; then
  # zsh: $0 is the sourced file path; ZSH_EVAL_CONTEXT ends in :file when
  # sourced (toplevel when executed).
  case "${ZSH_EVAL_CONTEXT:-}" in
    *:file) _wt_sourced=1 ;;
  esac
  WT_DIR="$(cd "$(dirname "$0")" && pwd)"
elif [ -n "${BASH_SOURCE[0]:-}" ]; then
  # bash: sourced when BASH_SOURCE[0] differs from $0.
  [ "${BASH_SOURCE[0]}" != "$0" ] && _wt_sourced=1
  WT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  WT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# --- sourced: define the interactive `wt` function, then stop ---
if [ "$_wt_sourced" = "1" ]; then
  unset _wt_sourced
  wt() {
    if [ $# -eq 0 ]; then
      bash "$WT_DIR/wt.sh" help
      return
    fi
    local sub="$1"; shift
    case "$sub" in
      main)
        cd "$WT_WORKTREE_REPO_LOCATION/main"
        ;;
      add|cd)
        bash "$WT_DIR/wt.sh" "$sub" "$@" || return 1
        cd "$WT_WORKTREE_REPO_LOCATION/${1//\//_}"
        ;;
      *)
        bash "$WT_DIR/wt.sh" "$sub" "$@"
        ;;
    esac
  }
  return 0
fi
unset _wt_sourced

# --- executed: dispatch to the wt-*.sh scripts ---
set -uo pipefail
sub="${1:-help}"

run() { exec bash "$WT_DIR/$1" "${@:2}"; }

case "$sub" in
  add)   run wt-add.sh   "${@:2}" ;;
  cd)    run wt-cd.sh    "${@:2}" ;;
  rm)    run wt-rm.sh    "${@:2}" ;;
  ls)    run wt-ls.sh    "${@:2}" ;;
  link)  run wt-link.sh  "${@:2}" ;;
  clean) run wt-clean.sh "${@:2}" ;;
  help|-h|--help)
    cat <<'HELP'
wt — git worktree manager (works with both the bare-repo and the
normal-repo-at-main layouts)

Usage:
  wt <command> [args...]

Commands:
  add <branch>            Create a new worktree from a remote branch name,
                          then cd into it. Recovers squash-merged branches via
                          their PR head when the remote branch is gone.
  cd <branch>             Go to a worktree, then cd into it. If the worktree
                          does not exist yet, it is created first by running
                          the full `wt add <branch>` (same remote-branch /
                          squash-merge-PR recovery, symlinks, and workspace
                          linking), then cd's into it.
  rm <branch>             Remove a worktree folder and prune stale worktree
                          registrations.
  ls [options]            List every worktree: branch, remote branch (and
                          whether it still exists), separate-folder marker,
                          dirty state, untracked count, ahead/behind.
                            --no-fetch    skip the fetch; use last-fetched refs
                            --fetch       explicit fetch (same as default)
  link [options]          Check/fix a worktree's symlinks (node_modules plus the
                          project-specific WT_SYMLINK_PAIRS, e.g. .cache/.env)
                          and its @scope/* workspace overrides.
                            <branch>          one worktree
                            --all             every worktree (except main)
                            --check           report only, make no changes
                            --no-workspaces   skip the (slower) workspace step
  clean [options]         Remove merged+clean worktrees. DRY RUN by default.
                            --apply           actually remove + prune + delete
                                              local branches
                            --keep-branch     remove folders but keep branches
                            --older-than <d>  only consider worktrees whose last
                                              commit is older than <d>
                                              (e.g. 30d, 12h, 4w, 90m)
  main                    cd into the main worktree.
  help                    Show this help.

Examples:
  wt add yourname/TICKET-123/my-feature
  wt cd  yourname/TICKET-123/my-feature
  wt ls  --no-fetch
  wt link --check --all
  wt clean                 # preview what would be removed
  wt clean --apply         # remove them

Configuration (nothing is hardcoded here; each repo is configured by a
per-repo alias that passes these WT_* values to `wt`, e.g. `my-repo-wt`):
  WT_WORKTREE_REPO_LOCATION   worktree collection folder (e.g. $HOME/Sites/fe)
  WT_REPO_SLUG                GitHub repo slug (owner/repo) used by `gh`
  WT_PROTECTED_BRANCHES       branches never removed (default: main)
  WT_SAFE_ARTIFACTS           extra safe-to-discard names
  WT_SYMLINK_PAIRS            project-specific worktree symlinks
                              (e.g. .cache, surfaces/x/.env)

Requirements:
  git   always (core of the tool)
  gh    required for `clean` (must be installed AND logged in: `gh auth login`);
        optional for `add`/`cd` — only used to recover a squash-merged branch
        whose remote branch was deleted. Without it, those fall back to a new
        local branch.
  node  >= 14.18, optional — used only by the workspace-linking step in
        `add`/`cd`/`link` (link-workspaces.mjs). If absent, that step is
        skipped with a warning; everything else still works.
HELP
    ;;
  *)
    echo "wt: unknown command '$sub' (see 'wt help')" >&2
    exit 2
    ;;
esac
