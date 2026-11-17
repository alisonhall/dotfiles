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
# Subcommands: add, cd, rm, ls, link, clean, setup, config, help
#
# shell/common/git.sh only needs to source this file (`. "$WT_DIR/wt.sh"`) —
# no per-command aliases. `wt help` lists every command, description, and option.

# --- resolve this folder + detect sourced-vs-executed (works in bash or zsh) ---
# zsh and bash expose the sourced-file path differently, so branch on shell.
# (zsh 5.9 rejects ${.sh.file} as a bad substitution, so we don't use it.)
_wt_sourced=0
if [ -n "${ZSH_VERSION:-}" ]; then
  # zsh: ZSH_EVAL_CONTEXT ends in :file when sourced (toplevel when executed).
  # The %x prompt escape is the file being run, whatever the options; $0 is
  # only that file while FUNCTION_ARGZERO is on. (In eval, because bash can't
  # parse it.)
  case "${ZSH_EVAL_CONTEXT:-}" in
    *:file) _wt_sourced=1 ;;
  esac
  eval 'WT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"'
elif [ -n "${BASH_SOURCE[0]:-}" ]; then
  # bash: sourced when BASH_SOURCE[0] differs from $0.
  [ "${BASH_SOURCE[0]}" != "$0" ] && _wt_sourced=1
  WT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  WT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# _wt_layout_location [<folder>]: Run in (or given) a folder of wt's layout - anywhere in main or
# in a branch folder beside it, in either layout - prints the folder that holds them, and
# succeeds. A worktree is in the layout when the folder beside it named main is a worktree of the
# same repo (main itself too). Then the commands work there with no settings, and aren't sent
# elsewhere by a WT_WORKTREE_REPO_LOCATION or WT_REPO_SLUG exported for another repo. (Defined in
# both modes: the function cds with it, the dispatch passes it on. Written for bash 3.2 and zsh
# alike; no cd, which in an interactive zsh may run hooks that print.)
_wt_layout_location() {
  local folder="${1:-$PWD}" top parent common main_common
  top="$(git -C "$folder" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$top" ] || return 1
  parent="$(dirname "$top")"
  [ -e "$parent/main/.git" ] || return 1
  common="$(git -C "$folder" rev-parse --git-common-dir 2>/dev/null)" || return 1
  main_common="$(git -C "$parent/main" rev-parse --git-common-dir 2>/dev/null)" || return 1
  # Relative to the folder git ran in, unless absolute (C:/... from Windows' git too)
  case "$common" in /* | [A-Za-z]:*) ;; *) common="$folder/$common" ;; esac
  case "$main_common" in /* | [A-Za-z]:*) ;; *) main_common="$parent/main/$main_common" ;; esac
  [ "$common" -ef "$main_common" ] || return 1
  printf '%s\n' "$parent"
}

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
        local location
        location="$(_wt_layout_location)" || location="${WT_WORKTREE_REPO_LOCATION:-}"
        if [ -z "$location" ]; then
          echo "error: wt main: WT_WORKTREE_REPO_LOCATION is not set, and this isn't a folder of wt's layout. Run it in a branch's folder beside main, or export WT_WORKTREE_REPO_LOCATION (see wt help)." >&2
          return 2
        fi
        cd "$location/main"
        ;;
      add|cd)
        # In a subshell - e.g. in the background, because the shell split `wt cd fix-a&b` at the &
        # and ran `wt cd fix-a &` - the cd at the end couldn't reach the terminal, and the branch is
        # likely the wrong one, so stop before making anything. (bash and zsh count subshells in
        # different variables.)
        if [ "${BASH_SUBSHELL:-${ZSH_SUBSHELL:-0}}" -gt 0 ]; then
          echo "wt $sub: if the branch name has a character like & or ; in it, the shell split the name there." >&2
          echo "wt $sub: this ran in the background or a subshell, so it couldn't move your terminal, and made nothing. Run \`wt $sub\` on its own and paste the name when it asks, or put the name in single quotes." >&2
          return 1
        fi
        # The branch: the argument that isn't an option, like --strict (no branch name starts
        # with -). With none, ask for it: a name pasted at the prompt is read as typed, whereas on
        # the command line the shell would act on characters like & or ; before wt saw them
        # An option wt doesn't know is left to the script to refuse, before asking for a branch
        # that would go unused. `wt add --pr <number>` (and cd) needs no branch: the script finds it.
        local arg branch="" unknown="" pr="" wants_number="" porcelain=""
        for arg in "$@"; do
          if [ -n "$wants_number" ]; then
            wants_number=""
            continue
          fi
          case "$arg" in
            -*)
              case "$sub $arg" in
                "add --strict") ;;
                "add --porcelain" | "cd --porcelain") porcelain=1 ;;
                "add --pr" | "cd --pr") pr=1; wants_number=1 ;;
                *) unknown=1 ;;
              esac
              ;;
            *) branch="$arg" ;;
          esac
        done
        # (With no terminal, as when a tool runs wt, read finds no input and this stops at once)
        if [ -z "$branch" ] && [ -z "$pr" ] && [ -z "$unknown" ]; then
          printf 'Branch name: ' >&2
          read -r branch || branch=""
          if [ -z "$branch" ]; then
            echo >&2
            echo "wt $sub: no branch name was given, so nothing was done. Name the branch: wt $sub <branch>." >&2
            return 2
          fi
          set -- "$@" "$branch"
        fi
        # Where the folder is: the one the script names in WT_CD_FILE (for --pr, only it knows);
        # else the branch's, beside main when run there (as the dispatch below decides too), else
        # in WT_WORKTREE_REPO_LOCATION
        local location cd_file folder="" code=0
        location="$(_wt_layout_location)" || location="${WT_WORKTREE_REPO_LOCATION:-}"
        cd_file="$(mktemp "${TMPDIR:-/tmp}/wt-cd.XXXXXX" 2>/dev/null)" || cd_file=""
        WT_CD_FILE="$cd_file" bash "$WT_DIR/wt.sh" "$sub" "$@" || code=$?
        if [ -n "$cd_file" ]; then
          folder="$(cat "$cd_file" 2>/dev/null)"
          rm -f "$cd_file"
        fi
        # On failure, the script's own exit code (like --strict's 3 and 4), for a tool that runs wt
        # in an interactive shell and so gets this function
        [ "$code" -eq 0 ] || return "$code"
        # --porcelain: the caller wants the folder's path (printed by the script), not a moved shell
        [ -n "$porcelain" ] && return 0
        if [ -n "$folder" ]; then
          cd "$folder"
        elif [ -n "$branch" ]; then
          cd "$location/${branch//\//_}"
        fi
        ;;
      *)
        bash "$WT_DIR/wt.sh" "$sub" "$@"
        ;;
    esac
  }

  # _wt_quote_branch_arg <line>: For a command line like `wt cd feature/a&b` or `shop-wt add x;y`
  # (wt, or a per-repo <name>-wt command), sets REPLY to the line with the branch name in single
  # quotes, and succeeds. Fails, leaving the line alone, unless there's exactly one name after
  # cd or add (or add --strict), with a character the shell would act on and no quotes, \ or $
  # (which mean it's already quoted, or meant to be expanded). Branch names can't contain spaces,
  # so anything after a space - like `wt cd x && ls` - is left for the shell, as typed.
  _wt_quote_branch_arg() {
    local cmd sub name extra option=""
    case "$1" in *$'\n'*) return 1 ;; esac
    read -r cmd sub name extra <<< "$1"
    if [ "$sub" = add ] && [ "$name" = --strict ]; then
      option=" --strict"
      read -r name extra <<< "$extra"
    fi
    [ -n "$name" ] && [ -z "$extra" ] || return 1
    case "$cmd" in wt | ?*-wt) ;; *) return 1 ;; esac
    case "$cmd" in *[!A-Za-z0-9_.-]*) return 1 ;; esac
    case "$sub" in cd | add) ;; *) return 1 ;; esac
    case "$name" in *[\'\"\\\$\`]*) return 1 ;; esac
    case "$name" in *[!A-Za-z0-9._/@+=:,%-]*) ;; *) return 1 ;; esac
    REPLY="$cmd $sub$option '$name'"
  }

  # In zsh, quote the branch name as Enter is pressed, before the shell reads the line - so a name
  # pasted unquoted, like feature/a&b, isn't split at the &. (It wraps whatever accept-line already
  # does, e.g. from a plugin; the line is saved in history with the quotes.)
  if [ -n "${ZSH_VERSION:-}" ]; then
    eval '
      if [[ -o interactive ]] && zmodload zsh/zleparameter 2>/dev/null &&
        [[ ${widgets[accept-line]-} != user:_wt_accept_line ]]; then
        _wt_accept_line() {
          local REPLY
          if _wt_quote_branch_arg "$BUFFER"; then
            BUFFER=$REPLY
            CURSOR=${#BUFFER}
          fi
          zle _wt_orig_accept_line -- "$@"
        }
        zle -A accept-line _wt_orig_accept_line
        zle -N accept-line _wt_accept_line
      fi
    '
  fi
  return 0
fi
unset _wt_sourced

# --- executed: dispatch to the wt-*.sh scripts ---
set -uo pipefail
sub="${1:-help}"

run() { exec bash "$WT_DIR/$1" "${@:2}"; }

# Shared helpers: WT_SETTINGS, forget_settings, load_git_config
source "$WT_DIR/wt-common.sh"

# show_config: wt config - each setting wt would use here, and where it came from
show_config() {
	local entry var key kind value from ref remote="${CURRENT_REMOTE_NAME:-origin}" main
	if [ -z "${WT_WORKTREE_REPO_LOCATION:-}" ]; then
		echo "error: wt config: WT_WORKTREE_REPO_LOCATION is not set, and this isn't a folder of wt's layout. Run it in the repo's main folder (or a branch's folder beside it), or export WT_WORKTREE_REPO_LOCATION as the folder that holds main." >&2
		exit 2
	fi
	main="$WT_WORKTREE_REPO_LOCATION/main"
	printf '%-26s %s  (%s)\n' WT_WORKTREE_REPO_LOCATION "$WT_WORKTREE_REPO_LOCATION" "${from_location:-env}"
	for entry in $WT_SETTINGS; do
		IFS=: read -r var key kind <<< "$entry"
		value="${!var:-}"
		from="from_$var"
		from="${!from:-}"
		if [ -z "$value" ]; then
			case "$var" in
				WT_REPO_SLUG) value="(none)" from="gh finds the repo from the clone" ;;
				CURRENT_REMOTE_NAME) value=origin from=default ;;
				CURRENT_DEV_BRANCH)
					if ref="$(git -C "$main" symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null)"; then
						value="${ref#"$remote"/}" from="$remote/HEAD"
					else
						value=main from="default; $remote/HEAD isn't set - git remote set-head $remote --auto sets it"
					fi
					;;
				WT_PROTECTED_BRANCHES) value=main from=default ;;
				*) value="(none)" from=default ;;
			esac
		fi
		printf '%-26s %s  (%s)\n' "$var" "$value" "$from"
	done
}

# repo_layout <folder>: For a worktree outside the layout but of a layout's repo - one git made at
# ../feature/x for branch feature/x, say - prints that layout's folder and succeeds: the folder
# holding the repo's main worktree (the first git lists), when that's a layout's main (in the
# bare-repo layout, the first is .bare, beside main).
repo_layout() {
	local first
	first="$(git -C "$1" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
	[ -n "$first" ] || return 1
	case "$first" in */.bare) first="$(dirname "$first")/main" ;; esac
	[ "$(basename "$first")" = main ] && [ -d "$first" ] || return 1
	_wt_layout_location "$first"
}

# Run in a folder of a layout (or, for wt link and rm, given one - else the one they're run in): that
# layout, whatever the settings say. Run in (or given) another worktree of a layout's repo, that
# repo's layout. When WT_WORKTREE_REPO_LOCATION is another repo's, every exported setting is that
# repo's, so none is used: only this clone's git config and the defaults (gh finds the repo from
# main's clone). When it isn't set, exported settings are for every repo: git config wins over
# them, and the slug is dropped (gh finds it). When it's this layout, they win over git config.
layout_folder=""
if [ "$sub" = link ] || [ "$sub" = rm ]; then
  for arg in "${@:2}"; do
    # (Written as a path, as is_folder_arg in wt-common.sh says: a plain name is a branch)
    case "$arg" in . | .. | /* | ./* | ../* | [A-Za-z]:*) [ -d "$arg" ] && layout_folder="$arg" ;; esac
  done
fi
case "$sub" in
  add | cd | rm | ls | link | clean | config)
    own=1
    # (A folder given that's outside any layout, like a worktree made elsewhere, is wt rm's and
    # link's to check against the layout they're run in)
    if location="$(_wt_layout_location "$layout_folder")" ||
      location="$(repo_layout "${layout_folder:-$PWD}")" ||
      { [ -n "$layout_folder" ] && location="$(_wt_layout_location)"; }; then
      if [ -z "${WT_WORKTREE_REPO_LOCATION:-}" ]; then
        own=0
        unset WT_REPO_SLUG
      elif ! [ "$WT_WORKTREE_REPO_LOCATION" -ef "$location" ]; then
        own=0
        forget_settings
      fi
      export WT_WORKTREE_REPO_LOCATION="$location"
      from_location="the layout it's run in"
    fi
    [ -n "${WT_WORKTREE_REPO_LOCATION:-}" ] && load_git_config "$WT_WORKTREE_REPO_LOCATION/main" "$own"
    ;;
esac

case "$sub" in
  add)   run wt-add.sh   "${@:2}" ;;
  cd)    run wt-cd.sh    "${@:2}" ;;
  rm)    run wt-rm.sh    "${@:2}" ;;
  ls)    run wt-ls.sh    "${@:2}" ;;
  link)  run wt-link.sh  "${@:2}" ;;
  clean) run wt-clean.sh "${@:2}" ;;
  setup) run wt-setup.sh "${@:2}" ;;
  config)
    if [ $# -gt 1 ]; then
      echo "Usage: wt config" >&2
      echo "wt config: it takes no arguments; change a setting with git config wt.<key> (see wt help)." >&2
      exit 2
    fi
    show_config
    ;;
  help|-h|--help)
    cat <<'HELP'
wt — git worktree manager (works with both the bare-repo and the
normal-repo-at-main layouts)

Usage:
  wt <command> [args...]

Commands:
  add [--strict] [--porcelain] <branch>
                          Create a new worktree from a remote branch name,
                          then cd into it. Recovers squash-merged branches via
                          their PR head when the remote branch is gone.
                            --strict   fail, making nothing, when the branch
                                       isn't on the remote (exit 3) or it
                                       can't be asked (exit 4), rather than
                                       making a new branch from
                                       the dev branch (see below)
  add --pr <number>       The same for a pull request, its branch found by gh:
                          this repo's branch, or for a fork's PR (or a branch
                          since deleted) its pull ref in pr-<number>, tracking
                          refs/pull/<number>/head. Makes nothing when there's
                          no such PR or its head isn't on the remote (exit 3),
                          or gh or the remote can't be asked (exit 4)
  cd <branch>             Go to a worktree, then cd into it. If the worktree
                          does not exist yet, it is created first by running
                          the full `wt add <branch>` (same remote-branch /
                          squash-merge-PR recovery, symlinks, and workspace
                          linking), then cd's into it. A pr-<number> branch
                          (from add --pr) fetches its pull request's head.
  cd --pr <number>        The same for a pull request: its folder, made by
                          add --pr if it isn't there yet.
                          --porcelain (add and cd, with --strict and --pr
                          too): for a tool - print only the worktree's full
                          path on stdout (also when it already existed),
                          everything else on stderr, and don't move the
                          terminal. Exit codes are the same.
                          For add and cd, leave out <branch> to be asked for
                          it: paste a name with characters like & ; ( ) there,
                          or put it in single quotes on the command line.
                          (In zsh, wt adds the quotes itself. In bash, a name
                          split at an & runs wt in the background, and wt
                          stops and says so, rather than using half a name.)
  rm <branch>|<folder>    Remove a worktree folder (a branch's, or one named
                          like . - beside main, or any other worktree of the
                          repo, wherever it is) and prune stale worktree
                          registrations.
                          Asks first if it has work that would be lost
                          (uncommitted changes, new files, commits not on
                          the remote); without a terminal, stops instead.
                            --yes      delete it anyway, without asking
                            --branch   delete the branch too (not a
                                       protected one)
  ls [options]            List every worktree: branch, remote branch (and
                          whether it still exists), separate-folder marker,
                          dirty state, untracked count, ahead/behind.
                            --no-fetch    skip the fetch; use last-fetched refs
                            --fetch       explicit fetch (same as default)
  link [options]          Check/fix a worktree's symlinks (node_modules plus the
                          project-specific WT_SYMLINK_PAIRS, e.g. .cache/.env)
                          and its @scope/* workspace overrides.
                            <branch>          one worktree
                            <folder>          the worktree in that folder (.)
                            (neither)         the worktree it's run in
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
  setup [--dry-run]       Set up a repo for wt: get it into the folder layout
                          wt expects, save its settings in the clone's git
                          config, and (optionally) add a command for it to
                          your shell's startup file. Asks before changing
                          anything.
  config                  Show each setting wt uses here, and where it came
                          from (env, git config, origin/HEAD, default).
  help                    Show this help.

Exit codes (every command):
  0   done
  1   refused or failed: nothing was changed, or it stopped partway and
      says what's left
  2   usage (an unknown option, a missing argument) or not configured
      (no layout found and WT_WORKTREE_REPO_LOCATION not set)
  3   add --strict / add --pr: the branch or pull request isn't there
  4   add --strict / add --pr: the remote or gh couldn't be asked
  On failure, every message goes to stderr, and the last line is one
  sentence saying what went wrong and what to do. (A tool that runs wt can
  show that line, or the first line starting fatal: or error:.)
  Nothing waits for an answer without a terminal: wt rm stops instead of
  asking (add --yes), and wt add/cd with no branch stop instead of asking.

Examples:
  wt add yourname/TICKET-123/my-feature
  wt cd  yourname/TICKET-123/my-feature
  wt ls  --no-fetch
  wt link --check --all
  wt clean                 # preview what would be removed
  wt clean --apply         # remove them

Settings (nothing is hardcoded here). Run in a repo's main folder or a
branch's folder beside it, wt finds the repo from the folder, and reads the
repo's settings from the clone's git config (main/.git/config, shared by
every worktree, never committed). `wt setup` writes them; by hand:
  git config wt.repoSlug owner/repo
  git config --add wt.protectedBranch development   (one entry per value)
  git config --unset-all wt.protectedBranch          (remove them)

  Variable                    git config key       Means
  WT_WORKTREE_REPO_LOCATION   (none: the folder)   the folder holding main,
                                                   for running wt elsewhere
  WT_REPO_SLUG                wt.repoSlug          GitHub repo (owner/repo)
                                                   for gh; else gh asks the
                                                   clone
  CURRENT_DEV_BRANCH          wt.devBranch         branch new branches start
                                                   from, never deleted;
                                                   else <remote>/HEAD (git
                                                   remote set-head origin
                                                   --auto), else main
  CURRENT_REMOTE_NAME         wt.remote            remote (default: origin)
  WT_PROTECTED_BRANCHES       wt.protectedBranch   branches never removed
                                                   (default: main) - multi
  WT_SAFE_ARTIFACTS           wt.safeArtifact      extra safe-to-discard
                                                   names - multi
  WT_SYMLINK_PAIRS            wt.symlinkPair       files every branch folder
                                                   shares with main (e.g.
                                                   .env, .cache) - multi

  The variables still work, e.g. from a per-repo command that sets them
  for one `wt` call, and win over git config. In a layout that
  WT_WORKTREE_REPO_LOCATION points away from, all of them are ignored, as
  they're another repo's. With it unset, git config wins over exported
  ones (and WT_REPO_SLUG is ignored). wt config shows the result.

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
    echo "wt: unknown command '$sub'. Run wt help to see the commands." >&2
    exit 2
    ;;
esac
