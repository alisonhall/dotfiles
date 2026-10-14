#!/usr/bin/env bash
#
# wt-setup.sh — set up a repo to use with wt, by answering a few questions.
#
# It asks which GitHub repo to use and where to keep its worktrees, then:
#   * gets the repo into the layout wt expects, <repo-location>/main, by cloning
#     it or by moving a clone you already have
#   * adds a command for the repo to your shell's startup file, which runs wt
#     with that repo's settings:
#
#       <command-name>() {
#           WT_WORKTREE_REPO_LOCATION="<repo-location>" \
#           WT_REPO_SLUG="<repo-owner>/<repo-name>" \
#           wt "$@"
#       }
#
#   * makes the startup file load wt itself, if it doesn't already
#
# Nothing changes until you've answered every question and said yes. The
# startup file is backed up first, and running this again for the same command
# updates that command rather than adding another.
#
# Usage:
#   wt setup [--dry-run]                       (once wt is loaded)
#   bash <wt-folder>/wt-setup.sh [--dry-run]   (before it is)
#
#   --dry-run   ask the questions and show what would change, but change nothing

set -uo pipefail

WT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_DIR="$PWD"
DRY_RUN=0
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY_RUN=1 ;;
		-h | --help)
			sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*)
			echo "wt-setup: unknown option: $arg (see --help)" >&2
			exit 2
			;;
	esac
done

#   -------------------------------
#   HELPERS
#   -------------------------------

say() { printf '%s\n' "$*"; }
heading() { printf '\n== %s ==\n' "$*"; }
die() {
	printf 'wt-setup: %s\n' "$*" >&2
	exit 1
}

# ask <var> <question> [default]: Sets <var> to the answer, or to the default if it's left empty
ask() {
	# (An unusual name, so it can't hide a caller's variable of the same name from printf -v)
	local _ask_reply=""
	if [ -n "${3:-}" ]; then
		printf '%s [%s]: ' "$2" "$3"
	else
		printf '%s: ' "$2"
	fi
	IFS= read -r _ask_reply || [ -n "$_ask_reply" ] || die "no answer given, so stopping. Nothing was changed."
	_ask_reply="${_ask_reply%$'\r'}"
	[ -n "$_ask_reply" ] || _ask_reply="${3:-}"
	printf -v "$1" '%s' "$_ask_reply"
}

# ask_required <var> <question> [default]: Like ask, but asks again until there's an answer
ask_required() {
	while :; do
		ask "$@"
		[ -n "${!1}" ] && return 0
		say "  This one needs an answer."
	done
}

# ask_yes_no <question> <y|n>: Succeeds for yes
ask_yes_no() {
	local answer
	while :; do
		ask answer "$1 (y/n)" "$2"
		case "$answer" in
			[Yy] | [Yy][Ee][Ss]) return 0 ;;
			[Nn] | [Nn][Oo]) return 1 ;;
		esac
		say "  Please answer y or n."
	done
}

# choose <var> <question> <option>...: Sets <var> to the number of the chosen option
choose() {
	local var="$1" question="$2" answer i=1 option
	shift 2
	say "$question"
	for option in "$@"; do
		say "  $i) $option"
		i=$((i + 1))
	done
	while :; do
		ask answer "Choose 1-$#" 1
		case "$answer" in
			'' | *[!0-9]*) ;;
			*)
				if [ "$answer" -ge 1 ] && [ "$answer" -le $# ]; then
					printf -v "$var" '%s' "$answer"
					return 0
				fi
				;;
		esac
		say "  Please enter a number from 1 to $#."
	done
}

# os_name: uname -s, which tests can override with WT_SETUP_OS
os_name() {
	printf '%s' "${WT_SETUP_OS:-$(uname -s)}"
}

# is_windows: Whether this is Git Bash (or another Unix layer) on Windows
is_windows() {
	case "$(os_name)" in MINGW* | MSYS* | CYGWIN*) return 0 ;; esac
	return 1
}

# quiet_git <args>: git that fails rather than waiting for a password or an SSH prompt
quiet_git() {
	GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" git "$@"
}

# full_path <path>: The path with ~ expanded, made absolute, without a trailing /. Windows paths
# (C:\Users\...) get forward slashes, which Git Bash and Windows programs both accept.
full_path() {
	local path="${1//\\//}"
	case "$path" in
		"~") path="$HOME" ;;
		"~/"*) path="$HOME/${path#\~/}" ;;
	esac
	case "$path" in
		/* | [A-Za-z]:/*) ;;
		*) path="$PWD/$path" ;;
	esac
	[ "$path" = / ] || path="${path%/}"
	printf '%s' "$path"
}

# pretty_path <path>: The path with $HOME shown as ~, for messages
pretty_path() {
	case "$1" in
		"$HOME") printf '~' ;;
		"$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
		*) printf '%s' "$1" ;;
	esac
}

# quoted <value>: The value in double quotes for a shell startup file, with $HOME kept as $HOME
quoted() {
	local value="$1" prefix=""
	case "$value" in
		"$HOME") value="" prefix='$HOME' ;;
		"$HOME"/*) value="/${value#"$HOME"/}" prefix='$HOME' ;;
	esac
	printf '"%s%s"' "$prefix" "$(printf '%s' "$value" | sed 's/[\\"`$]/\\&/g')"
}

# same_dir <a> <b>: Whether two paths are the same folder (git and bash can write paths differently)
same_dir() {
	[ -d "$1" ] && [ -d "$2" ] && [ "$(cd "$1" && pwd -P)" = "$(cd "$2" && pwd -P)" ]
}

# is_checkout <folder>: Whether the folder is the top of a git checkout (a clone or a worktree)
is_checkout() {
	local top
	top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" && same_dir "$top" "$1"
}

# is_clone <folder>: Whether the folder is the top of an ordinary clone (not a linked worktree)
is_clone() {
	is_checkout "$1" && [ "$(git -C "$1" rev-parse --git-dir)" = "$(git -C "$1" rev-parse --git-common-dir)" ]
}

# github_slug <url>: owner/name from a GitHub URL, or nothing for any other URL. Includes SSH host
# aliases for a second GitHub account, like git@github-work:owner/name.git
github_slug() {
	printf '%s\n' "$1" | sed -nE 's#/$##; s#\.git$##; s#^(https?://|ssh://)?([^@/]+@)?github(\.com)?(-[A-Za-z0-9_.-]+)?[:/]([^/]+/[^/]+)$#\5#p'
}

# clone_remote <folder>: The clone's remote for GitHub: origin, or else its first remote
clone_remote() {
	local remotes
	remotes="$(git -C "$1" remote)"
	if printf '%s\n' "$remotes" | grep -qx origin; then
		printf 'origin'
	else
		printf '%s\n' "$remotes" | head -1
	fi
}

# clone_default_branch <folder> <remote>: The remote's default branch, as the clone knows it
clone_default_branch() {
	local ref
	ref="$(git -C "$1" symbolic-ref --quiet --short "refs/remotes/$2/HEAD" 2>/dev/null)" && printf '%s' "${ref#"$2"/}"
}

# remote_default_branch: The default branch of the repo being cloned, asked of GitHub or the URL
remote_default_branch() {
	if [ -n "$SLUG" ] && [ -z "$CLONE_URL" ] && [ "$GH_READY" = 1 ]; then
		gh repo view "$SLUG" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null && return
	fi
	quiet_git ls-remote --symref "$(clone_source)" HEAD 2>/dev/null | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }'
}

# repo_reachable: Whether the repo to clone exists and this user can read it
repo_reachable() {
	if [ -n "$SLUG" ] && [ -z "$CLONE_URL" ] && [ "$GH_READY" = 1 ]; then
		gh repo view "$SLUG" >/dev/null 2>&1
	else
		quiet_git ls-remote --heads "$(clone_source)" >/dev/null 2>&1
	fi
}

# branch_exists <branch>: Whether the repo has the branch. Also succeeds when there's no way to
# check (a repo that couldn't be reached), so that isn't reported as a missing branch.
branch_exists() {
	if [ "$MODE" = clone ]; then
		[ "$REACHABLE" = 1 ] || return 0
		if [ -n "$SLUG" ] && [ -z "$CLONE_URL" ] && [ "$GH_READY" = 1 ]; then
			gh api "repos/$SLUG/branches/$1" >/dev/null 2>&1
		else
			quiet_git ls-remote --exit-code --heads "$(clone_source)" "refs/heads/$1" >/dev/null 2>&1
		fi
	else
		git -C "$clone_dir" show-ref --verify --quiet "refs/remotes/$REMOTE/$1" ||
			git -C "$clone_dir" show-ref --verify --quiet "refs/heads/$1"
	fi
}

# outside_blocks <file>: The file's lines as "<line number>:<line>", leaving out this script's blocks
outside_blocks() {
	[ -f "$1" ] || return 0
	awk '
		{ line = $0; sub(/\r$/, "", line) }
		line ~ /^# >>> wt: .* >>>$/ { inside = 1; next }
		line ~ /^# <<< wt: .* <<<$/ { inside = 0; next }
		!inside { print FNR ":" line }
	' "$1"
}

# defined_in <file> <name>: Prints the first line outside this script's blocks that defines <name>
# as an alias or function. Defining a function after an alias of the same name is a syntax error.
defined_in() {
	outside_blocks "$1" | NAME="$2" awk '
		{
			number = $0; sub(/:.*/, "", number)
			code = substr($0, length(number) + 2); sub(/^[ \t]+/, "", code)
			n = ENVIRON["NAME"]
			if (index(code, "alias " n "=") == 1 || index(code, n "()") == 1 || index(code, n " ()") == 1 ||
				code == "function " n || index(code, "function " n " ") == 1 || index(code, "function " n "(") == 1 ||
				index(code, "function " n "{") == 1) {
				print "line " number ": " code
				found = 1
				exit
			}
		}
		END { exit !found }'
}

# loads_wt <file>: Whether the file, outside this script's blocks, loads a wt.sh that exists
# (not one in a comment, or a copy that's since been deleted)
loads_wt() {
	local entry path
	while IFS= read -r entry; do
		path="$(printf '%s\n' "${entry#*:}" | sed -nE "s/^[[:space:]]*(\.|source)[[:space:]]+[\"']?([^\"' ;]*wt\.sh)[\"']?([[:space:];].*)?$/\2/p")"
		[ -n "$path" ] || continue
		case "$path" in
			"~/"*) path="$HOME/${path#\~/}" ;;
			'$HOME/'*) path="$HOME/${path#\$HOME/}" ;;
			'${HOME}/'*) path="$HOME/${path#\$\{HOME\}/}" ;;
		esac
		[ -f "$path" ] && return 0
	done < <(outside_blocks "$1")
	return 1
}

# bash_login_file: The file a bash login shell reads (macOS Terminal and Git Bash open login shells,
# which don't read ~/.bashrc themselves): the first of these that exists, or ~/.bash_profile
bash_login_file() {
	local file
	for file in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
		[ -f "$file" ] && { printf '%s' "$file"; return; }
	done
	printf '%s' "$HOME/.bash_profile"
}

# loads_bashrc <file>: Whether the file loads ~/.bashrc, on a line that isn't a comment
loads_bashrc() {
	[ -f "$1" ] && grep -qE '^[[:space:]]*[^#]*(\.|source)[[:space:]]+.*\.bashrc' "$1"
}

# clone_source: What to clone: the URL given, or the GitHub repo over HTTPS
clone_source() {
	if [ -n "$CLONE_URL" ]; then
		printf '%s' "$CLONE_URL"
	else
		printf 'https://github.com/%s.git' "$SLUG"
	fi
}

# has_block <file> <name>: Whether the file has this script's block called <name>
has_block() {
	[ -f "$1" ] && START="# >>> wt: $2 >>>" awk '{ sub(/\r$/, "") } $0 == ENVIRON["START"] { found = 1 } END { exit !found }' "$1"
}

# set_block <file> <name> <contents>: Adds the block called <name> to the file, or replaces it
set_block() {
	local file="$1" start="# >>> wt: $2 >>>" end="# <<< wt: $2 <<<" tmp
	if has_block "$file" "$2"; then
		tmp="$(mktemp)" || return 1
		START="$start" END="$end" CONTENTS="$3" awk '
			{ line = $0; sub(/\r$/, "", line) }
			line == ENVIRON["START"] { print; print ENVIRON["CONTENTS"]; skip = 1; next }
			line == ENVIRON["END"] { skip = 0 }
			!skip { print }
		' "$file" > "$tmp" && cat "$tmp" > "$file"
		rm -f "$tmp"
	else
		# Start on a new line if the file doesn't end with one
		if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then
			echo >> "$file"
		fi
		printf '\n%s\n%s\n%s\n' "$start" "$3" "$end" >> "$file"
	fi
}

#   -------------------------------
#   REQUIREMENTS
#   -------------------------------

say "This sets up a repo to use with wt. Nothing changes until you've answered every"
say "question and said yes at the end. Press Enter to accept the [default] answer."

heading "Requirements"
command -v git >/dev/null 2>&1 || die "git isn't installed."
GH_READY=0
if ! command -v gh >/dev/null 2>&1; then
	say "  The GitHub CLI (gh) isn't installed. wt clean needs it: https://cli.github.com"
elif ! gh auth status >/dev/null 2>&1; then
	say "  The GitHub CLI (gh) isn't logged in. wt clean needs it: run gh auth login"
else
	GH_READY=1
	say "  git and the GitHub CLI are ready"
fi

#   -------------------------------
#   QUESTIONS
#   -------------------------------

# If this is run from inside a clone, offer that repo
current_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
current_url=""
[ -n "$current_root" ] && current_url="$(git -C "$current_root" remote get-url "$(clone_remote "$current_root")" 2>/dev/null || true)"
default_repo="$(github_slug "$current_url")"
[ -n "$default_repo" ] || default_repo="$current_url"

heading "Repo"
while :; do
	SLUG=""
	CLONE_URL=""
	ask_required repo "Which repo? Its GitHub owner/name (like octocat/hello-world), or a URL to clone" "$default_repo"
	if [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [ ! -e "$repo" ]; then
		SLUG="$repo"
	else
		CLONE_URL="$repo"
		SLUG="$(github_slug "$repo")"
	fi
	# Check now, so a typo doesn't only show up when cloning at the end
	if repo_reachable; then
		REACHABLE=1
		break
	fi
	say "  Couldn't reach $(clone_source). Check the name, and that you have access to it."
	if ask_yes_no "Use it anyway? (Only if you'll use a clone you already have)" n; then
		REACHABLE=0
		break
	fi
done
if [ -n "$SLUG" ]; then
	REPO_NAME="${SLUG#*/}"
else
	ask SLUG "It isn't on github.com, so what's its owner/name there? wt clean needs it (leave empty to skip)"
	REPO_NAME="$(basename "${CLONE_URL%/}")"
	REPO_NAME="${REPO_NAME%.git}"
fi

heading "Folder"
say "wt keeps the repo in one folder, with your clone in a \"main\" folder inside it and"
say "a folder for each branch next to it:  <folder>/main, <folder>/feature_login, ..."
default_location="$HOME/code/$REPO_NAME"
# Run from inside a clone of this repo: suggest the folder it's already in
in_this_repo=0
if [ -n "$current_root" ]; then
	if [ -n "$SLUG" ] && [ "$(github_slug "$current_url")" = "$SLUG" ]; then
		in_this_repo=1
	elif [ -n "$CLONE_URL" ] && [ "$current_url" = "$CLONE_URL" ]; then
		in_this_repo=1
	fi
fi
if [ "$in_this_repo" = 1 ]; then
	if [ "$(basename "$current_root")" = main ]; then
		default_location="$(dirname "$current_root")"
	else
		default_location="$current_root"
	fi
fi
ask_required location "Folder for the repo" "$(pretty_path "$default_location")"
LOCATION="$(full_path "$location")"
MAIN="$LOCATION/main"

MOVE_FROM=""
if is_checkout "$MAIN"; then
	MODE=existing
	say "  $(pretty_path "$MAIN") is already a clone, so wt will use it as it is."
elif is_clone "$LOCATION"; then
	say "  $(pretty_path "$LOCATION") is a clone. wt needs it one level down, in $(pretty_path "$MAIN")."
	ask_yes_no "Move it there?" y || die "stopping, so nothing was changed. Choose a different folder, or move the clone yourself."
	MODE=move
	MOVE_FROM="$LOCATION"
elif [ -e "$LOCATION" ] && [ ! -d "$LOCATION" ]; then
	die "$(pretty_path "$LOCATION") is a file. Choose a folder."
elif [ -d "$LOCATION" ] && [ -n "$(ls -A "$LOCATION")" ]; then
	die "$(pretty_path "$LOCATION") already has files in it, but no clone in $(pretty_path "$MAIN"). Choose a new or empty folder."
else
	choose how "How should the clone get into $(pretty_path "$MAIN")?" \
		"Clone the repo from $(clone_source)" \
		"Move a clone I already have"
	if [ "$how" = 1 ]; then
		[ "$REACHABLE" = 1 ] || die "the repo couldn't be reached, so it can't be cloned. Nothing was changed."
		MODE=clone
	else
		MODE=move
		while :; do
			ask_required from "Where is the clone?" "$(pretty_path "${current_root:-}")"
			MOVE_FROM="$(full_path "$from")"
			if ! is_clone "$MOVE_FROM"; then
				say "  $(pretty_path "$MOVE_FROM") isn't the top folder of a clone."
			else
				case "$LOCATION/" in
					"$MOVE_FROM"/*) say "  The repo's folder can't be inside the clone you're moving." ;;
					*) break ;;
				esac
			fi
		done
	fi
fi

# Windows can't move a folder that a terminal is in
if [ "$MODE" = move ] && is_windows; then
	case "$START_DIR/" in
		"$MOVE_FROM"/*)
			die "this terminal is inside $(pretty_path "$MOVE_FROM"), and Windows can't move a folder that's in use. cd out of it, then run this again."
			;;
	esac
fi

# The remote and default branch, from the clone where there is one
if [ "$MODE" = clone ]; then
	REMOTE=origin
	detected_branch="$(remote_default_branch)"
else
	clone_dir="$MAIN"
	[ "$MODE" = move ] && clone_dir="$MOVE_FROM"
	REMOTE="$(clone_remote "$clone_dir")"
	[ -n "$REMOTE" ] || die "$(pretty_path "$clone_dir") has no git remotes. wt needs one that points at GitHub."
	detected_branch="$(clone_default_branch "$clone_dir" "$REMOTE")"
	if [ -n "$SLUG" ] && [ -n "$(github_slug "$(git -C "$clone_dir" remote get-url "$REMOTE")")" ] && [ "$(github_slug "$(git -C "$clone_dir" remote get-url "$REMOTE")")" != "$SLUG" ]; then
		say "  Note: that clone's $REMOTE remote is $(git -C "$clone_dir" remote get-url "$REMOTE"), not $SLUG."
	fi
fi

heading "Settings"

# Inside this dotfiles repo, personal settings go in ~/.shell_local, which loads after wt does
IN_DOTFILES=0
if [ -n "${DOTFILES:-}" ] && same_dir "$DOTFILES/git/wt" "$WT_DIR"; then
	IN_DOTFILES=1
	default_file="$HOME/.shell_local"
else
	case "${SHELL##*/}" in
		zsh) default_file="$HOME/.zshrc" ;;
		bash) default_file="$HOME/.bashrc" ;;
		*) default_file="" ;;
	esac
fi
[ "$IN_DOTFILES" = 1 ] && say "These dotfiles load wt already, so the command goes in ~/.shell_local."
ask_required startup "Startup file to add the command to" "$(pretty_path "$default_file")"
STARTUP_FILE="$(full_path "$startup")"

default_command="$(printf '%s' "$REPO_NAME-wt" | tr -c 'A-Za-z0-9_\n-' '-')"
while :; do
	ask_required COMMAND_NAME "Name for this repo's wt command" "$default_command"
	case "$COMMAND_NAME" in
		[!A-Za-z_]* | *[!A-Za-z0-9_-]*)
			say "  Use letters, numbers, - and _, starting with a letter or _."
			continue
			;;
		wt)
			say "  wt itself is taken. Choose another name."
			continue
			;;
	esac
	case "$(type -t "$COMMAND_NAME")" in
		file | builtin | keyword)
			say "  $COMMAND_NAME is already a command. Choose another name."
			continue
			;;
	esac
	# This script runs in a fresh bash, which can't see the user's aliases and functions, so look
	# for them in the startup file itself
	if existing="$(defined_in "$STARTUP_FILE" "$COMMAND_NAME")"; then
		say "  $(pretty_path "$STARTUP_FILE") already defines $COMMAND_NAME, on $existing"
		say "  Choose another name, or remove that from $(pretty_path "$STARTUP_FILE") and run this again."
		continue
	fi
	break
done

while :; do
	ask_required DEV_BRANCH "Branch that new branches start from" "${detected_branch:-main}"
	branch_exists "$DEV_BRANCH" && break
	say "  The repo has no branch called $DEV_BRANCH."
	ask_yes_no "Use it anyway?" n && break
done

suggest_shared=""
if [ "$MODE" != clone ]; then
	for name in .env .env.local; do
		[ -e "${clone_dir:-}/$name" ] && suggest_shared="${suggest_shared:+$suggest_shared }$name"
	done
fi
say "Files or folders that every branch folder should share with main, rather than have"
say "its own copy of (like .env). node_modules is always shared. Type - for none."
ask SHARED "Shared files, separated by spaces" "${suggest_shared:--}"
[ "$SHARED" = - ] && SHARED=""

# Windows limits paths to 260 characters unless git is told otherwise, and node_modules inside a
# branch folder goes past that easily ("Filename too long")
LONG_PATHS=0
if is_windows && [ "$(git config --global --get core.longpaths)" != true ]; then
	say "Windows limits paths to 260 characters, which deep folders like node_modules can go past"
	say "in a branch folder, and git then fails with \"Filename too long\"."
	ask_yes_no "Let git use longer paths, for all your repos (git config --global core.longpaths true)?" y && LONG_PATHS=1
fi

#   -------------------------------
#   PLAN
#   -------------------------------

command_block="# Added by wt-setup.sh. Running it again for $COMMAND_NAME replaces this whole block."$'\n'"$COMMAND_NAME() {"$'\n'
command_block+="	WT_WORKTREE_REPO_LOCATION=$(quoted "$LOCATION") \\"$'\n'
[ -n "$SLUG" ] && command_block+="	WT_REPO_SLUG=$(quoted "$SLUG") \\"$'\n'
[ "$REMOTE" != origin ] && command_block+="	CURRENT_REMOTE_NAME=$(quoted "$REMOTE") \\"$'\n'
if [ "$DEV_BRANCH" != main ]; then
	command_block+="	CURRENT_DEV_BRANCH=$(quoted "$DEV_BRANCH") \\"$'\n'
	command_block+="	WT_PROTECTED_BRANCHES=$(quoted "main $DEV_BRANCH") \\"$'\n'
fi
[ -n "$SHARED" ] && command_block+="	WT_SYMLINK_PAIRS=$(quoted "$SHARED") \\"$'\n'
command_block+='	wt "$@"'$'\n''}'

# Load wt, unless the dotfiles do it or the file already does
load_block=""
if [ "$IN_DOTFILES" = 0 ]; then
	if has_block "$STARTUP_FILE" load || ! loads_wt "$STARTUP_FILE"; then
		load_block=". $(quoted "$WT_DIR/wt.sh")"
	fi
fi

# macOS Terminal and Git Bash open login shells, which read ~/.bash_profile (or ~/.bash_login, or
# ~/.profile) and not ~/.bashrc, so make sure that file loads ~/.bashrc
LOGIN_FILE=""
login_block=""
if [ "$IN_DOTFILES" = 0 ] && [ "$STARTUP_FILE" = "$HOME/.bashrc" ]; then
	case "$(os_name)" in
		Darwin* | MINGW* | MSYS* | CYGWIN*)
			LOGIN_FILE="$(bash_login_file)"
			if has_block "$LOGIN_FILE" load-bashrc || ! loads_bashrc "$LOGIN_FILE"; then
				login_block='[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"'
			fi
			;;
	esac
fi

heading "Plan"
plan_step=0
# step <text>: Say the plan's next numbered step
step() {
	plan_step=$((plan_step + 1))
	say "$plan_step. $*"
}
case "$MODE" in
	clone) step "Clone $(clone_source) into $(pretty_path "$MAIN")" ;;
	move) step "Move $(pretty_path "$MOVE_FROM") to $(pretty_path "$MAIN")" ;;
	existing) step "Use the clone that's already in $(pretty_path "$MAIN")" ;;
esac
if has_block "$STARTUP_FILE" "$COMMAND_NAME"; then
	step "Replace the $COMMAND_NAME command in $(pretty_path "$STARTUP_FILE") with:"
else
	step "Add this to $(pretty_path "$STARTUP_FILE"):"
fi
[ -n "$load_block" ] && printf '%s\n' "$load_block" | sed 's/^/     /'
printf '%s\n' "$command_block" | sed 's/^/     /'
[ -f "$STARTUP_FILE" ] && say "   (backing it up first)"
if [ -n "$login_block" ]; then
	step "Add this to $(pretty_path "$LOGIN_FILE"), so new terminals (login shells) load ~/.bashrc:"
	printf '%s\n' "$login_block" | sed 's/^/     /'
	[ -f "$LOGIN_FILE" ] && say "   (backing it up first)"
fi
[ "$LONG_PATHS" = 1 ] && step "Let git use long paths: git config --global core.longpaths true"

if [ "$DRY_RUN" = 1 ]; then
	say ""
	say "Dry run, so nothing was changed."
	exit 0
fi
say ""
ask_yes_no "Go ahead?" y || {
	say "Nothing was changed."
	exit 0
}

#   -------------------------------
#   DO IT
#   -------------------------------

heading "Setting up"
case "$MODE" in
	clone)
		mkdir -p "$LOCATION" || die "couldn't create $(pretty_path "$LOCATION")."
		if [ -n "$SLUG" ] && [ -z "$CLONE_URL" ] && [ "$GH_READY" = 1 ]; then
			gh repo clone "$SLUG" "$MAIN" || die "couldn't clone $SLUG. $(pretty_path "$STARTUP_FILE") wasn't changed."
		else
			git clone "$(clone_source)" "$MAIN" || die "couldn't clone $(clone_source). $(pretty_path "$STARTUP_FILE") wasn't changed."
		fi
		;;
	move)
		cd "$HOME" || exit 1
		if [ "$MOVE_FROM" = "$LOCATION" ]; then
			# Rename it aside, then make the folder again and move the clone into it
			aside="$LOCATION.wt-setup-$$"
			mv "$LOCATION" "$aside" || die "couldn't move $(pretty_path "$LOCATION"). Is it open in an editor or another terminal? Nothing was changed."
			if ! { mkdir "$LOCATION" && mv "$aside" "$MAIN"; }; then
				rmdir "$LOCATION" 2>/dev/null
				mv "$aside" "$LOCATION" || die "couldn't finish moving the clone, and couldn't put it back. It's at $(pretty_path "$aside")."
				die "couldn't move the clone into $(pretty_path "$MAIN"), so it was put back. Nothing was changed."
			fi
		else
			mkdir -p "$LOCATION" || die "couldn't create $(pretty_path "$LOCATION")."
			mv "$MOVE_FROM" "$MAIN" || die "couldn't move $(pretty_path "$MOVE_FROM"). Is it open in an editor or another terminal? $(pretty_path "$STARTUP_FILE") wasn't changed."
		fi
		say "Moved the clone to $(pretty_path "$MAIN")"
		# Reconnect any worktrees made from the clone before it moved
		if ! repair_output="$(git -C "$MAIN" worktree repair 2>&1)"; then
			say "Couldn't reconnect some worktrees made from this clone before it moved:"
			printf '%s\n' "$repair_output" | sed 's/^/  /'
			say "To fix one, run: git -C $(quoted "$MAIN") worktree repair <its folder>"
		fi
		;;
esac

# backup <file>: Copy the file aside before changing it
backup() {
	local copy="$1.wt-setup-$(date +%Y%m%d-%H%M%S).bak"
	[ -f "$1" ] || return 0
	cp "$1" "$copy" || die "couldn't back up $(pretty_path "$1"), so it wasn't changed."
	say "Backed up $(pretty_path "$1") to $(pretty_path "$copy")"
}

mkdir -p "$(dirname "$STARTUP_FILE")"
backup "$STARTUP_FILE"
[ -n "$load_block" ] && { set_block "$STARTUP_FILE" load "$load_block" || die "couldn't update $(pretty_path "$STARTUP_FILE")."; }
set_block "$STARTUP_FILE" "$COMMAND_NAME" "$command_block" || die "couldn't update $(pretty_path "$STARTUP_FILE")."
if [ -n "$login_block" ]; then
	backup "$LOGIN_FILE"
	set_block "$LOGIN_FILE" load-bashrc "$login_block" || die "couldn't update $(pretty_path "$LOGIN_FILE")."
	say "Made $(pretty_path "$LOGIN_FILE") load ~/.bashrc"
fi
if [ "$LONG_PATHS" = 1 ]; then
	git config --global core.longpaths true || die "couldn't turn on core.longpaths in git."
	say "Let git use long paths"
fi
say "Added the $COMMAND_NAME command to $(pretty_path "$STARTUP_FILE")"

heading "Done"
say "Open a new terminal (or run: . $(pretty_path "$STARTUP_FILE")), then try:"
printf '  %-*s  %s\n' $((${#COMMAND_NAME} + 13)) "$COMMAND_NAME ls" "list the repo's branch folders" \
	$((${#COMMAND_NAME} + 13)) "$COMMAND_NAME add <branch>" "make a folder for a branch and go to it" \
	$((${#COMMAND_NAME} + 13)) "$COMMAND_NAME help" "everything else"
if [ "$MODE" = move ]; then
	case "$START_DIR/" in
		"$MOVE_FROM"/*) say "This terminal is still in the clone's old folder. Run: cd $(quoted "$MAIN")" ;;
	esac
fi
[ "$GH_READY" = 1 ] || say "Install the GitHub CLI and run gh auth login before using $COMMAND_NAME clean."
