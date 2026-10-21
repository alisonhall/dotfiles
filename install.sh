#!/usr/bin/env bash
#
# Points this machine's shell and git config at this repo, then checks that it all works.
#
# Usage:
#   ./install.sh           Set up (or repair) this machine
#   ./install.sh --check   Only run the checks - change nothing
#
# Safe to re-run: every step checks whether it has already been done.
# Existing files are added to, never replaced. Anything that's a symlink
# (e.g. into an old dotfiles repo) is moved aside to <file>.bak.<timestamp>
# first so nothing gets written through it.
#
# Set DOTFILES_SKIP_GITLEAKS=1 to skip installing gitleaks (e.g. in CI).
# Set DOTFILES_SKIP_P10K=1 to skip installing powerlevel10k and its font.

# Re-run with bash if started some other way (e.g. `sh install.sh` or `zsh install.sh`)
if [ -z "${BASH_VERSION:-}" ]; then
	exec bash "$0" "$@"
fi

set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Everything personal/machine-specific, as its own git repo (see setup_local_dir). Overridable so
# tests never touch this repo's own local/ folder.
LOCAL_DIR="${DOTFILES_LOCAL_DIR:-$DOTFILES/local}"
MARKER_START="# >>> dotfiles >>>"
MARKER_END="# <<< dotfiles <<<"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"

MODE=install
IS_GIT_CLONE=1
case "${1:-}" in
	"") ;;
	--check) MODE=check ;;
	-h | --help)
		awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
		exit 0
		;;
	*)
		echo "Unknown option: $1 (see ./install.sh --help)"
		exit 2
		;;
esac

#   -------------------------------
#   HELPERS
#   -------------------------------

PROBLEMS=0
WARNINGS=0
ok() { echo "  OK: $*"; }
note() { echo "  NOTE: $*"; }
warning() { echo "  WARNING: $*"; WARNINGS=$((WARNINGS + 1)); }
problem() { echo "  PROBLEM: $*"; PROBLEMS=$((PROBLEMS + 1)); }
detail() { echo "    $*"; }

# Git for Windows needs native paths (D:/...) rather than Git Bash paths (/d/...)
native_path() {
	if command -v cygpath >/dev/null 2>&1; then
		cygpath -m "$1"
	else
		printf '%s\n' "$1"
	fi
}

git_version_at_least() {
	local major minor
	read -r major minor <<<"$(git --version | sed -E 's/^[^0-9]*([0-9]+)\.([0-9]+).*/\1 \2/')"
	[ "$major" -gt "$1" ] || { [ "$major" -eq "$1" ] && [ "$minor" -ge "$2" ]; }
}

move_aside_if_symlink() {
	local file="$1"
	if [ -L "$file" ]; then
		mv "$file" "$file.bak.$TIMESTAMP"
		echo "  Moved symlink $file to $file.bak.$TIMESTAMP"
	fi
}

# Prints a file with the dotfiles block (markers included) removed
without_dotfiles_block() {
	awk -v start="$MARKER_START" -v end="$MARKER_END" '
		$0 == start { skip = 1; next }
		$0 == end { skip = 0; next }
		!skip' "$1"
}

# markers_paired <file>: Whether every start marker has a matching end marker (no missing, nested
# or stray ones). Rewriting a file with a broken block could delete everything after the start marker.
markers_paired() {
	awk -v start="$MARKER_START" -v end="$MARKER_END" '
		$0 == start { if (inside) { bad = 1; exit } inside = 1 }
		$0 == end { if (!inside) { bad = 1; exit } inside = 0 }
		END { exit bad || inside }
	' "$1"
}

# Prints what's between the dotfiles block markers in a file
block_contents() {
	awk -v start="$MARKER_START" -v end="$MARKER_END" '
		$0 == start { inside = 1; next }
		$0 == end { inside = 0 }
		inside' "$1"
}

# ensure_block <file> <contents>: Make sure <file> has a dotfiles block with exactly <contents>.
# Creates the file if needed, appends the block if it's missing, and replaces the block's
# contents if they're out of date (e.g. the repo has moved). Everything else in the file is kept.
ensure_block() {
	local file="$1" contents="$2" current
	move_aside_if_symlink "$file"

	if [ ! -f "$file" ] || ! grep -qxF "$MARKER_START" "$file"; then
		printf '\n%s\n%s\n%s\n' "$MARKER_START" "$contents" "$MARKER_END" >> "$file"
		echo "  Added dotfiles block to $file"
		return
	fi

	if ! markers_paired "$file"; then
		problem "$file has a '$MARKER_START' line without a matching '$MARKER_END' line (or the other way round)."
		detail "Fix or delete the block by hand, then run install.sh again."
		return
	fi
	if [ "$(grep -cxF "$MARKER_START" "$file")" -gt 1 ]; then
		problem "$file has more than one dotfiles block, so the dotfiles would load more than once."
		detail "Delete all but one of them by hand, then run install.sh again."
		return
	fi

	current="$(block_contents "$file")"
	if [ "$current" = "$contents" ]; then
		echo "  $file is already set up"
		return
	fi

	local old_location
	old_location="$(printf '%s\n' "$current" | sed -n 's/^export DOTFILES="\(.*\)"$/\1/p')"
	cp "$file" "$file.bak.$TIMESTAMP"
	DOTFILES_BLOCK="$contents" awk -v start="$MARKER_START" -v end="$MARKER_END" '
		$0 == start { print; print ENVIRON["DOTFILES_BLOCK"]; skip = 1; next }
		$0 == end { skip = 0 }
		!skip' "$file.bak.$TIMESTAMP" > "$file"
	echo "  Updated the dotfiles block in $file (it was out of date; old version in $file.bak.$TIMESTAMP)"
	if [ -n "$old_location" ] && [ "$old_location" != "$DOTFILES" ]; then
		detail "It loaded the dotfiles from $old_location - now $DOTFILES"
	fi
}

#   -------------------------------
#   BEFORE STARTING
#   -------------------------------

# Anything that would make setup fail or do the wrong thing. Stops before changing anything.
preflight() {
	echo "Before starting:"
	local problems_before=$PROBLEMS output

	if [ "$(id -u)" = 0 ] && [ -z "${DOTFILES_ALLOW_ROOT:-}" ]; then
		problem "running as root (e.g. with sudo) would set up root's home folder ($HOME), not yours."
		detail "Run it as yourself, without sudo."
	fi

	if ! command -v git >/dev/null 2>&1; then
		problem "git isn't installed."
	fi

	if ! output="$(bash "$DOTFILES/tools/check-syntax.sh")"; then
		problem "the repo's shell files have errors, which every new terminal would hit:"
		echo "$output"
	fi

	check_locations

	if [ "$PROBLEMS" -eq "$problems_before" ]; then
		ok "running as $(id -un) with bash $BASH_VERSION and git $(git --version | awk '{ print $3 }'); the repo's files pass syntax checks"
	fi
}

# Shows a path, plus its Windows form on Windows (e.g. /c/Users/me -> C:\Users\me)
show_path() {
	if command -v cygpath >/dev/null 2>&1; then
		echo "$1 ($(cygpath -w "$1"))"
	else
		echo "$1"
	fi
}

# Where the repo is and which home folder is being set up. The repo can be anywhere and
# called anything, but it has to stay put: every new shell loads it from this path.
check_locations() {
	echo "  Repo: $(show_path "$DOTFILES")"
	echo "  Home: $(show_path "$HOME")"

	# The path is written into the shell startup files inside double quotes
	case "$DOTFILES" in
		*[\"\$\`\\]*)
			problem "the repo's path contains \", \$, \` or \\, which would break the shell setup. Move it somewhere else."
			;;
	esac

	local lower_path
	lower_path="$(printf '%s' "$DOTFILES" | tr '[:upper:]' '[:lower:]')"
	case "$lower_path" in
		*/downloads/* | */temp/* | */tmp/* | /var/folders/*)
			warning "the repo is in a downloads or temporary folder. Every new shell loads it from here, so"
			detail "move it somewhere permanent first (e.g. $(show_path "$HOME/dotfiles")) and run install.sh from there."
			;;
		*onedrive* | *dropbox* | *google\ drive* | *icloud*)
			warning "the repo is in a cloud-synced folder. Sync can keep files offline until they're opened,"
			detail "or create conflicted copies inside .git. A plain folder (e.g. $(show_path "$HOME/dotfiles")) is safer."
			;;
	esac

	# (Compared after cd + pwd, because git prints C:/... paths on Windows)
	local toplevel
	toplevel="$(git -C "$DOTFILES" rev-parse --show-toplevel 2>/dev/null || true)"
	if [ -n "$toplevel" ] && [ "$(cd "$toplevel" && pwd)" = "$DOTFILES" ]; then
		IS_GIT_CLONE=1
	else
		IS_GIT_CLONE=0
		warning "this copy isn't a git clone (was it downloaded as a ZIP?). It will work, but update-dotfiles"
		detail "can't pull updates and commits can't be checked. To fix: git clone the repo and run its install.sh."
	fi

	# On Windows, programs started outside Git Bash (VS Code, GitHub Desktop...) find ~/.gitconfig
	# in the home folder Windows has set, which may not be the one Git Bash is using
	if command -v reg >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
		local windows_home
		# (reg fails when HOME isn't set, which is normal)
		windows_home="$({ reg query 'HKCU\Environment' //v HOME 2>/dev/null || true; } | tr -d '\r' |
			sed -n 's/^ *HOME *REG_[A-Z_]*SZ *//p')"
		if [ -n "$windows_home" ] && [ "$(cygpath -u "$windows_home")" != "$HOME" ]; then
			warning "Windows' HOME setting ($windows_home) isn't the home folder Git Bash is using ($(cygpath -w "$HOME"))."
			detail "Programs started outside Git Bash won't see this setup. Make them match, or remove the Windows setting."
		fi
	fi
}

#   -------------------------------
#   LOCAL SETUP (this machine's own files)
#   -------------------------------
#
# $LOCAL_DIR holds everything personal/machine-specific (shell settings, the blocklist, a p10k
# override) as its own git repo, ignored by this one (see .gitignore), so it's all in one place
# and can be versioned, diffed and backed up independently of the shared repo - e.g. to your own
# private remote. Nothing here needs you to have done that first: a plain, remote-less repo works
# fine as just a local history.

# ask_yes_no <question> <default: y|n>: Prompts and returns 0 for yes, 1 for no. If there's no
# input to read (closed/empty stdin - install.sh sourced non-interactively in tests, or run from a
# script), takes the default immediately rather than blocking.
ask_yes_no() {
	local question="$1" default="${2:-n}" answer
	while :; do
		printf '%s (y/n) [%s]: ' "$question" "$default" >&2
		IFS= read -r answer || answer="$default"
		answer="${answer:-$default}"
		case "$answer" in
			[Yy]*) return 0 ;;
			[Nn]*) return 1 ;;
		esac
		echo "  Please answer y or n." >&2
	done
}

# migrate_into_local <old file outside the repo> <new file in $LOCAL_DIR> [--confirm]: Moves a
# per-machine file into $LOCAL_DIR the first time (does nothing once it's already there, or if
# there's nothing to move). With --confirm, asks first (defaulting to yes) - used for anything
# besides shell_local.sh/dotfiles_blocklist, which are always safe to move without asking.
migrate_into_local() {
	local old="$1" new="$2"
	[ -f "$old" ] && [ ! -f "$new" ] || return 0
	if [ "${3:-}" = --confirm ] && ! ask_yes_no "  Move $old into $new, so it's versioned with everything else there?" y; then
		echo "  Leaving $old where it is - still used from there, just not versioned with $LOCAL_DIR"
		return 0
	fi
	mkdir -p "$(dirname "$new")"
	mv "$old" "$new"
	echo "  Moved $old to $new"
}

# active_local_file <name in $LOCAL_DIR> <legacy path outside the repo>: Echoes whichever of the
# two currently exists, preferring $LOCAL_DIR - so checks here still find the right file whether a
# migration was accepted, declined (p10k.zsh, gitconfig - see setup_local_gitconfig), or a file was
# simply never moved (shell_local.sh, dotfiles_blocklist can be recreated at the legacy path too;
# nothing requires using $LOCAL_DIR). Falls back to the legacy path if neither exists yet.
active_local_file() {
	if [ -f "$LOCAL_DIR/$1" ]; then
		echo "$LOCAL_DIR/$1"
	else
		echo "$2"
	fi
}

# Sourced from the top of shell_local.sh, so secrets are set before anything else in that file
# might use them (e.g. NVM_AUTH_HEADER="Bearer $ARTIFACTORY_AUTH_TOKEN").
SECRETS_SOURCE_LINE='[ -f "$DOTFILES/local/secrets.sh" ] && source "$DOTFILES/local/secrets.sh"'

# ensure_secrets_sourced: Makes sure $LOCAL_DIR/shell_local.sh sources $LOCAL_DIR/secrets.sh, at
# the top of the file, whether shell_local.sh just came from local.example.sh (which already has
# this line) or already existed before secrets.sh did.
ensure_secrets_sourced() {
	local shell_local="$LOCAL_DIR/shell_local.sh"
	[ -f "$shell_local" ] || return 0
	grep -qxF "$SECRETS_SOURCE_LINE" "$shell_local" && return 0
	cp "$shell_local" "$shell_local.bak.$TIMESTAMP"
	{
		printf '# Secrets (API tokens, credentials) live in secrets.sh instead, so they never need to pass\n'
		printf "# this folder's pre-commit hook. Sourced first, so the rest of this file can use them.\n"
		printf '%s\n\n' "$SECRETS_SOURCE_LINE"
		cat "$shell_local.bak.$TIMESTAMP"
	} > "$shell_local"
	echo "  Added a line to $shell_local that sources $LOCAL_DIR/secrets.sh"
}

setup_local_dir() {
	echo "Local setup:"
	if [ ! -e "$LOCAL_DIR" ]; then
		mkdir -p "$LOCAL_DIR"
		if ask_yes_no "  Set up $LOCAL_DIR as its own git repo, so it's versioned independently of this one?" y; then
			git init -q "$LOCAL_DIR"
			echo "  Created $LOCAL_DIR with its own git repo for this machine's files"
		else
			echo "  Created $LOCAL_DIR as a plain folder - its files still work, just without their own history, diffs or backups. Run 'git init' in it yourself later if you change your mind."
		fi
	fi

	# Created either way, even if the git-repo question above was declined, so the folder is ready
	# to become a repo later with nothing to fill in by hand.
	if [ ! -f "$LOCAL_DIR/.gitignore" ]; then
		printf '.DS_Store\n*.bak.*\nsecrets.sh\n' > "$LOCAL_DIR/.gitignore"
	elif ! grep -qxF secrets.sh "$LOCAL_DIR/.gitignore"; then
		printf 'secrets.sh\n' >> "$LOCAL_DIR/.gitignore"
		echo "  Added secrets.sh to $LOCAL_DIR/.gitignore"
	fi
	if [ ! -f "$LOCAL_DIR/README.md" ]; then
		cat > "$LOCAL_DIR/README.md" <<'EOF'
# Local setup

Everything in this folder is specific to this machine: shell settings, git identity, the
commit-blocklist, an optional prompt override. None of it is tracked by the dotfiles repo itself -
see its .gitignore.

- `shell_local.sh` - this machine's shell settings (exported variables, aliases, PATH entries).
  Loaded last by `shell/bashrc.sh`/`shell/zshrc.sh`, so it can override anything from the repo
- `secrets.sh` - real tokens, credentials, anything else that shouldn't be committed even here.
  Listed in `.gitignore`, so it's never staged, committed or scanned by the pre-commit hook below -
  `shell_local.sh` sources it automatically, before everything else in that file
- `dotfiles_blocklist` - personal strings (emails, hostnames...) the dotfiles repo's own
  pre-commit hook should block, so they never get committed there
- `gitconfig` - this machine's personal git settings (`user.name`, `user.email`, anything else).
  Included from `~/.gitconfig`, right after the shared config, so it overrides it
- `p10k.zsh` - an optional prompt override (`p10k configure` writes one to `~/.p10k.zsh`; move or
  copy it here). Only present if you've set one up
- `.githooks/pre-commit` - this folder's own pre-commit hook: gitleaks and shell syntax errors,
  nothing else (no blocklist or cross-OS checks - this folder isn't public). Wired up via
  `core.hooksPath` if this folder is a git repo

If this folder has its own git repo (a .git folder here), its history, diffs and any remote you
push it to are entirely yours to manage - install.sh never sets a remote for it. If it doesn't,
nothing here stops working; it just isn't versioned on its own. Turn it into a repo any time by
running `git init` in this folder (then `git config core.hooksPath .githooks` to turn the
pre-commit hook on, or just re-run install.sh).

Created by install.sh - see the "Local setup" section of the dotfiles README for details.
EOF
	fi

	if [ ! -f "$LOCAL_DIR/secrets.sh" ]; then
		cat > "$LOCAL_DIR/secrets.sh" <<'EOF'
# This machine's secrets - API tokens, credentials, anything else that shouldn't be committed even
# here. Gitignored (see .gitignore), so it's never scanned or blocked by this folder's pre-commit
# hook. shell_local.sh sources it automatically, before everything else in that file.

# export ARTIFACTORY_AUTH_TOKEN="..."
EOF
		echo "  Created $LOCAL_DIR/secrets.sh - put real tokens and credentials here instead of in shell_local.sh"
	fi

	setup_local_hooks

	migrate_into_local "$HOME/.shell_local" "$LOCAL_DIR/shell_local.sh"
	migrate_into_local "$HOME/.p10k.zsh" "$LOCAL_DIR/p10k.zsh" --confirm
	migrate_into_local "$HOME/.dotfiles_blocklist" "$LOCAL_DIR/dotfiles_blocklist"

	if [ ! -f "$LOCAL_DIR/shell_local.sh" ]; then
		cp "$DOTFILES/local.example.sh" "$LOCAL_DIR/shell_local.sh"
		echo "  Created $LOCAL_DIR/shell_local.sh from local.example.sh - fill it in for this machine"
	fi
	ensure_secrets_sourced

	if [ ! -f "$LOCAL_DIR/dotfiles_blocklist" ]; then
		cat > "$LOCAL_DIR/dotfiles_blocklist" <<'EOF'
# Strings that must never be committed to the public dotfiles repo.
# One per line, case-insensitive, matched literally (not regex).
# e.g. personal and work email addresses, employer/client names,
# server hostnames, IP addresses, your home folder name.
EOF
		echo "  Created $LOCAL_DIR/dotfiles_blocklist - add personal strings the pre-commit hook should block"
	fi

	commit_local_changes "Set up $(basename "$LOCAL_DIR")"
}

# setup_local_hooks: Creates $LOCAL_DIR/.githooks/pre-commit - secrets (gitleaks) and shell syntax
# only, unlike the dotfiles repo's own pre-commit: this folder isn't public and is used from one
# machine, so there's no blocklist or cross-OS check to run. Wires it up with core.hooksPath if
# $LOCAL_DIR is a git repo yet (it might not be - see setup_local_dir); if you `git init` it
# yourself later, the next run of install.sh wires it up then.
setup_local_hooks() {
	mkdir -p "$LOCAL_DIR/.githooks"
	if [ ! -f "$LOCAL_DIR/.githooks/pre-commit" ]; then
		cat > "$LOCAL_DIR/.githooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
#
# Checks staged changes in this folder for secrets and shell syntax errors before they're
# committed. This folder is personal and used from one machine, so unlike the dotfiles repo's own
# pre-commit hook, there's no blocklist or cross-OS check here.
#
# Bypass gitleaks for one commit: SKIP_GITLEAKS=1 git commit ...

status=0

# 1. Secrets (API keys, tokens, passwords) - https://github.com/gitleaks/gitleaks
# install.sh may have put it in ~/.local/bin, which GUI git clients don't have on PATH
PATH="$PATH:$HOME/.local/bin"
if [ -n "${SKIP_GITLEAKS:-}" ]; then
	:
elif ! command -v gitleaks >/dev/null 2>&1; then
	echo "pre-commit: gitleaks isn't installed, so staged changes can't be scanned for secrets." >&2
	echo "  Run the dotfiles repo's install.sh to install it, or commit with SKIP_GITLEAKS=1" >&2
	status=1
elif gitleaks git --help >/dev/null 2>&1; then
	gitleaks git --staged --redact --no-banner || status=1
else
	# gitleaks before v8.19 (e.g. older Linux distro packages)
	gitleaks protect --staged --redact --no-banner || status=1
fi

# 2. Shell syntax, so a broken file is never committed
bash_files=(shell_local.sh secrets.sh)
zsh_files=(shell_local.sh secrets.sh p10k.zsh)
for file in "${bash_files[@]}"; do
	[ -f "$file" ] || continue
	if ! output="$(bash -n "$file" 2>&1)"; then
		echo "pre-commit: bash syntax error in $file:" >&2
		echo "$output" | sed 's/^/  /' >&2
		status=1
	fi
done
if command -v zsh >/dev/null 2>&1; then
	for file in "${zsh_files[@]}"; do
		[ -f "$file" ] || continue
		if ! output="$(zsh -n "$file" 2>&1)"; then
			echo "pre-commit: zsh syntax error in $file:" >&2
			echo "$output" | sed 's/^/  /' >&2
			status=1
		fi
	done
fi

# 3. gitconfig syntax
if [ -f gitconfig ] && ! git config --file gitconfig --list >/dev/null 2>&1; then
	echo "pre-commit: gitconfig has invalid syntax - run 'git config --file gitconfig --list' to see the error" >&2
	status=1
fi

exit $status
EOF
		chmod +x "$LOCAL_DIR/.githooks/pre-commit"
	fi

	if [ -d "$LOCAL_DIR/.git" ] &&
		[ "$(git -C "$LOCAL_DIR" config --get core.hooksPath 2>/dev/null || true)" != .githooks ]; then
		git -C "$LOCAL_DIR" config core.hooksPath .githooks
		echo "  Enabled pre-commit checks (secrets, shell syntax) for $LOCAL_DIR"
	fi
}

# commit_local_changes <message>: Commits whatever's pending in $LOCAL_DIR, if anything - e.g. after
# setup_local_dir creates it, or after setup_git adds $LOCAL_DIR/gitconfig to it later. Falls back to
# a generic identity so the commit doesn't depend on git user.name/email being set up yet.
commit_local_changes() {
	[ -d "$LOCAL_DIR/.git" ] || return 0
	[ -n "$(git -C "$LOCAL_DIR" status --porcelain 2>/dev/null)" ] || return 0
	git -C "$LOCAL_DIR" add -A
	git -C "$LOCAL_DIR" \
		-c user.name="$(git config --global user.name 2>/dev/null || id -un)" \
		-c user.email="$(git config --global user.email 2>/dev/null || echo "$(id -un)@localhost")" \
		commit -q -m "$1"
}

#   -------------------------------
#   SHELL
#   -------------------------------

# If the repo has moved or been deleted, new shells say so instead of showing a cryptic error
shell_block() {
	printf '%s\n' \
		"export DOTFILES=\"$DOTFILES\"" \
		"if [ -f \"\$DOTFILES/$1\" ]; then" \
		"	source \"\$DOTFILES/$1\"" \
		"else" \
		"	echo \"dotfiles: can't find \$DOTFILES - if the repo moved, run install.sh from its new location\" >&2" \
		"fi"
}

# macOS Terminal and Git Bash open login shells, which read ~/.bash_profile but not ~/.bashrc.
# On Linux, bash reads ~/.bash_profile *instead of* ~/.profile, so don't create one there if
# ~/.profile already loads ~/.bashrc (as it does on Ubuntu and Debian).
setup_bash_profile() {
	local profile="$HOME/.bash_profile"
	if [ -f "$profile" ] && without_dotfiles_block "$profile" | grep -q '\.bashrc'; then
		echo "  $profile already loads ~/.bashrc"
	elif [ ! -f "$profile" ] && [ -f "$HOME/.profile" ] && grep -q '\.bashrc' "$HOME/.profile"; then
		echo "  ~/.profile already loads ~/.bashrc"
	else
		ensure_block "$profile" '[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"'
	fi
}

setup_shell() {
	echo "Shell:"
	ensure_block "$HOME/.bashrc" "$(shell_block shell/bashrc.sh)"
	setup_bash_profile
	if zsh_available; then
		ensure_block "$HOME/.zshrc" "$(shell_block shell/zshrc.sh)"
	fi
}

#   -------------------------------
#   ZSH PROMPT (powerlevel10k)
#   -------------------------------
#
# config/p10k.zsh assumes powerlevel10k and its MesloLGS NF icon font are
# installed; shell/zshrc.sh otherwise silently falls back to a plain prompt.
# Only attempted when zsh is actually relevant on this machine (see
# zsh_available) - no point installing a zsh theme and a font for a bash-only
# account. Neither is needed to use the dotfiles themselves.

# Whether zsh is relevant on this machine: it's installed, or ~/.zshrc already
# exists (e.g. from a previous install.sh run). Also used by setup_shell.
zsh_available() {
	command -v zsh >/dev/null 2>&1 || [ -f "$HOME/.zshrc" ]
}

has_powerlevel10k() {
	[ -f "/opt/homebrew/share/powerlevel10k/powerlevel10k.zsh-theme" ] ||
		[ -f "/usr/local/share/powerlevel10k/powerlevel10k.zsh-theme" ] ||
		[ -f "$HOME/powerlevel10k/powerlevel10k.zsh-theme" ]
}

has_meslo_font() {
	[ -f "$HOME/Library/Fonts/MesloLGS NF Regular.ttf" ] ||
		[ -f "/Library/Fonts/MesloLGS NF Regular.ttf" ] ||
		[ -f "$HOME/.local/share/fonts/MesloLGS NF Regular.ttf" ] ||
		[ -f "$HOME/.fonts/MesloLGS NF Regular.ttf" ]
}

# Downloads the 4 MesloLGS NF weights straight from the powerlevel10k repo. Used when there's no
# Homebrew (or its cask install isn't allowed). No package manager on Windows handles fonts, so
# this only covers macOS and Linux; Windows users are pointed at the manual install instead.
download_meslo_font() {
	local font_dir
	case "$(uname -s)" in
		Darwin*) font_dir="$HOME/Library/Fonts" ;;
		Linux*) font_dir="$HOME/.local/share/fonts" ;;
		*) return 1 ;;
	esac
	mkdir -p "$font_dir" || return 1
	local weight
	for weight in Regular Bold Italic "Bold%20Italic"; do
		curl -fsSL -o "$font_dir/MesloLGS NF ${weight//%20/ }.ttf" \
			"https://github.com/romkatv/powerlevel10k/raw/master/font/MesloLGS%20NF%20$weight.ttf" || return 1
	done
	command -v fc-cache >/dev/null 2>&1 && fc-cache -f "$font_dir" >/dev/null 2>&1
	return 0
}

install_powerlevel10k() {
	if has_powerlevel10k; then
		echo "  powerlevel10k is installed"
	elif [ -n "${DOTFILES_SKIP_P10K:-}" ]; then
		echo "  Skipping powerlevel10k install (DOTFILES_SKIP_P10K is set)"
	elif command -v brew >/dev/null 2>&1 && brew install powerlevel10k >/dev/null 2>&1; then
		echo "  Installed powerlevel10k with Homebrew"
	elif command -v git >/dev/null 2>&1 &&
		git clone --depth=1 -q https://github.com/romkatv/powerlevel10k.git "$HOME/powerlevel10k" >/dev/null 2>&1; then
		echo "  Installed powerlevel10k to ~/powerlevel10k"
	else
		note "couldn't install powerlevel10k. The zsh prompt (config/p10k.zsh) will be plain until it's installed:"
		detail "https://github.com/romkatv/powerlevel10k#installation"
	fi
}

install_meslo_font() {
	if has_meslo_font; then
		echo "  MesloLGS NF (powerlevel10k's icon font) is installed"
	elif [ -n "${DOTFILES_SKIP_P10K:-}" ]; then
		echo "  Skipping font install (DOTFILES_SKIP_P10K is set)"
	elif command -v brew >/dev/null 2>&1 && brew install --cask font-meslo-for-powerlevel10k >/dev/null 2>&1; then
		echo "  Installed the MesloLGS NF font with Homebrew"
	elif download_meslo_font; then
		echo "  Installed the MesloLGS NF font"
	else
		note "couldn't install the MesloLGS NF font. powerlevel10k's icons won't render correctly until it's installed:"
		detail "https://github.com/romkatv/powerlevel10k#manual-font-installation"
	fi
}

setup_zsh_prompt() {
	zsh_available || return 0
	echo "Zsh prompt:"
	install_powerlevel10k
	install_meslo_font
}

#   -------------------------------
#   GIT
#   -------------------------------

# is_dotfiles_copy <path to a file inside a repo's git/ folder>: whether that repo is a copy of this one
is_dotfiles_copy() {
	local repo
	repo="$(dirname "$(dirname "$1")")"
	[ -f "$repo/install.sh" ] && [ -f "$repo/shell/common.sh" ] && [ -f "$repo/git/gitignore_global" ]
}

git_unset_include() {
	if git_version_at_least 2 30; then
		git config --global --fixed-value --unset include.path "$1"
	else
		# Older git only matches by regex, so escape the path
		git config --global --unset include.path "^$(printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g')\$"
	fi
}

# Like git_unset_include, but targets a specific file instead of the global config. Used while
# moving settings out of ~/.gitconfig rather than removing a dead include.
unset_include_in_file() {
	if git_version_at_least 2 30; then
		git config --file "$1" --fixed-value --unset include.path "$2" 2>/dev/null || true
	else
		git config --file "$1" --unset include.path "^$(printf '%s' "$2" | sed 's/[][\.*^$+?(){}|]/\\&/g')\$" 2>/dev/null || true
	fi
}

# Drops the dotfiles' "Shared config..." comment line and collapses a now-empty [include] header,
# left behind after git_unset_include / unset_include_in_file removes the path under it
strip_shared_include_header() {
	local file="$1"
	grep -vxF '# Shared config from the dotfiles repo. Settings below this override it.' "$file" |
		awk '
			pending && /^[[:space:]]*$/ { held = held "\n" $0; next }
			pending { pending = 0; if ($0 !~ /^[[:space:]]*\[/) print held }
			/^\[include\][[:space:]]*$/ { pending = 1; held = $0; next }
			{ print }
		' > "$file.tmp" || true
	mv "$file.tmp" "$file"
}

# shared_include_first <gitconfig> <include path>: Whether the include is the file's first setting
# (git lists settings in file order)
shared_include_first() {
	[ "$(git config --file "$1" --list 2>/dev/null | head -n 1)" = "include.path=$2" ]
}

# prepend_shared_include <gitconfig> <include path> [--move]: Back up the file, then put the include
# at the top. With --move, removes the existing include first.
prepend_shared_include() {
	local gitconfig="$1" include_path="$2"
	if [ -s "$gitconfig" ]; then
		cp "$gitconfig" "$gitconfig.bak.$TIMESTAMP"
		echo "  Backed up $gitconfig to $gitconfig.bak.$TIMESTAMP"
	fi
	if [ "${3:-}" = --move ]; then
		git_unset_include "$include_path"
		strip_shared_include_header "$gitconfig"
	fi
	{
		printf '# Shared config from the dotfiles repo. Settings below this override it.\n'
		printf '[include]\n\tpath = %s\n' "$include_path"
		[ -f "$gitconfig" ] && cat "$gitconfig"
	} > "$gitconfig.tmp"
	mv "$gitconfig.tmp" "$gitconfig"
}

# Adds a second include for $LOCAL_DIR/gitconfig right after the shared one (so it still
# overrides it), and the first time $LOCAL_DIR/gitconfig doesn't exist yet, moves whatever was
# below the shared include into it (user.name, user.email, machine-specific settings), so they're
# versioned with everything else in $LOCAL_DIR instead of sitting directly in ~/.gitconfig. Called
# after the shared include is confirmed to be at the top, so "whatever's below it" is well-defined.
setup_local_gitconfig() {
	local gitconfig="$1" shared_include_path="$2" local_gitconfig="$LOCAL_DIR/gitconfig"
	local local_include_path
	local_include_path="$(native_path "$local_gitconfig")"

	if [ ! -f "$local_gitconfig" ]; then
		mkdir -p "$LOCAL_DIR"
		cp "$gitconfig" "$gitconfig.tmp-local"
		unset_include_in_file "$gitconfig.tmp-local" "$shared_include_path"
		strip_shared_include_header "$gitconfig.tmp-local"

		if [ -s "$gitconfig.tmp-local" ] &&
			ask_yes_no "  Move $gitconfig's personal settings into $local_gitconfig, so they're versioned with everything else there?" y; then
			mv "$gitconfig.tmp-local" "$local_gitconfig"
			cp "$gitconfig" "$gitconfig.local-migration.bak.$TIMESTAMP"
			# Everything but the shared include was just moved out, so replace the whole file with
			# a fresh copy of just that - rather than try to subtract it back out of $gitconfig,
			# which would leave duplicates of anything not exactly matching the include removal.
			printf '# Shared config from the dotfiles repo. Settings below this override it.\n[include]\n\tpath = %s\n' \
				"$shared_include_path" > "$gitconfig"
			echo "  Moved $gitconfig's personal settings into $local_gitconfig"
		else
			[ -s "$gitconfig.tmp-local" ] &&
				echo "  Leaving $gitconfig's personal settings where they are - still used from there, just not versioned with $LOCAL_DIR"
			rm -f "$gitconfig.tmp-local"
			: > "$local_gitconfig"
		fi
	fi

	if ! git config --file "$gitconfig" --get-all include.path 2>/dev/null | grep -qxF "$local_include_path"; then
		git config --file "$gitconfig" --add include.path "$local_include_path"
		echo "  Added include for this machine's local config ($local_gitconfig) to $gitconfig"
	fi
}

# ~/.gitconfig includes the shared config from this repo at the top, so anything
# set below it (user.name, user.email, machine-specific paths) overrides it.
setup_git() {
	echo "Git:"
	local gitconfig="$HOME/.gitconfig"
	local include_path
	include_path="$(native_path "$DOTFILES/git/gitconfig")"
	move_aside_if_symlink "$gitconfig"

	# Remove includes of a dotfiles gitconfig that no longer exists (e.g. the repo moved; git
	# silently ignores missing include files), or that belongs to another copy of this repo
	# (otherwise both copies' settings would load)
	local old_path
	while IFS= read -r old_path; do
		case "$old_path" in
			"$include_path") ;;
			*/git/gitconfig)
				if [ ! -f "$old_path" ]; then
					git_unset_include "$old_path"
					echo "  Removed include of $old_path (file no longer exists)"
				elif is_dotfiles_copy "$old_path"; then
					git_unset_include "$old_path"
					echo "  Removed include of $old_path (another copy of this repo)"
				fi
				;;
		esac
	done < <(git config --global --get-all include.path 2>/dev/null)

	if ! git config --global --get-all include.path 2>/dev/null | grep -qxF "$include_path"; then
		prepend_shared_include "$gitconfig" "$include_path"
		echo "  Added include for the shared config to the top of $gitconfig"
	elif ! shared_include_first "$gitconfig" "$include_path"; then
		# Settings above the include would be overridden by the shared config
		prepend_shared_include "$gitconfig" "$include_path" --move
		echo "  Moved the include for the shared config back to the top of $gitconfig, so the settings below it override it"
	else
		echo "  $gitconfig already includes the shared config"
	fi
	setup_local_gitconfig "$gitconfig" "$include_path"

	# Point core.excludesfile at the repo's gitignore_global, unless it's set to another file that exists
	local excludes ours reason=""
	ours="$(native_path "$DOTFILES/git/gitignore_global")"
	# --includes: core.excludesfile may now be set in $LOCAL_DIR/gitconfig rather than directly in
	# $gitconfig - --global alone only reads $gitconfig's own literal content, not what it includes
	excludes="$(git config --global --includes --get core.excludesfile 2>/dev/null || true)"
	if [ -z "$excludes" ]; then
		reason="it wasn't set"
	elif [ "$excludes" != "$ours" ] && [ ! -f "${excludes/#\~/$HOME}" ]; then
		reason="replacing $excludes, which doesn't exist"
	elif [ "$excludes" != "$ours" ] && is_dotfiles_copy "$excludes"; then
		reason="replacing $excludes, from another copy of this repo"
	fi
	if [ -n "$reason" ]; then
		git config --global core.excludesfile "$ours"
		echo "  Set core.excludesfile to the repo's gitignore_global ($reason)"
	fi
	commit_local_changes "Add local/gitconfig"
}

#   -------------------------------
#   ITERM (macOS)
#   -------------------------------

# Tells iTerm to load its settings from config/iterm. Changes made in iTerm's
# settings are then saved there too, so they can be committed.
setup_iterm() {
	[ "$(uname -s)" = Darwin ] && [ -d "/Applications/iTerm.app" ] || return 0
	echo "iTerm:"
	local current_folder
	current_folder="$(defaults read com.googlecode.iterm2 PrefsCustomFolder 2>/dev/null || true)"
	if [ "$(defaults read com.googlecode.iterm2 LoadPrefsFromCustomFolder 2>/dev/null || true)" = 1 ] &&
		[ -d "$current_folder" ] &&
		{ [ "$current_folder" = "$DOTFILES/config/iterm" ] || ! is_dotfiles_copy "$current_folder"; }; then
		echo "  iTerm already loads settings from $current_folder"
		return
	fi
	defaults write com.googlecode.iterm2 PrefsCustomFolder -string "$DOTFILES/config/iterm"
	defaults write com.googlecode.iterm2 LoadPrefsFromCustomFolder -bool true
	echo "  iTerm will load settings from config/iterm (restart iTerm to apply)"
}

#   -------------------------------
#   THIS REPO
#   -------------------------------

# Downloads the gitleaks release for this OS/CPU into ~/.local/bin, verified against
# the release's checksums. Used when there's no package manager (or it isn't allowed).
download_gitleaks() {
	local os arch ext version asset tmp
	local curl_opts=(-fsSL)
	case "$(uname -s)" in
		Darwin*) os=darwin ext=tar.gz ;;
		Linux*) os=linux ext=tar.gz ;;
		# Windows curl can't always reach the certificate revocation server (common on work networks)
		MINGW* | MSYS* | CYGWIN*) os=windows ext=zip curl_opts+=(--ssl-no-revoke) ;;
		*) return 1 ;;
	esac
	case "$(uname -m)" in
		x86_64 | amd64) arch=x64 ;;
		arm64 | aarch64) arch=arm64 ;;
		*) return 1 ;;
	esac

	version="$(curl "${curl_opts[@]}" https://api.github.com/repos/gitleaks/gitleaks/releases/latest |
		sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')" || return 1
	[ -n "$version" ] || return 1
	asset="gitleaks_${version}_${os}_${arch}.${ext}"

	tmp="$(mktemp -d)"
	(
		cd "$tmp" || exit 1
		local base="https://github.com/gitleaks/gitleaks/releases/download/v$version"
		curl "${curl_opts[@]}" -o "$asset" "$base/$asset" || exit 1
		curl "${curl_opts[@]}" -o checksums.txt "$base/gitleaks_${version}_checksums.txt" || exit 1
		if command -v sha256sum >/dev/null 2>&1; then
			grep " $asset\$" checksums.txt | sha256sum -c --status - || exit 1
		else
			grep " $asset\$" checksums.txt | shasum -a 256 -c --status - || exit 1
		fi
		if [ "$ext" = zip ]; then unzip -q "$asset"; else tar -xzf "$asset"; fi || exit 1
		local binary=gitleaks
		[ "$os" = windows ] && binary=gitleaks.exe
		mkdir -p "$HOME/.local/bin"
		mv "$binary" "$HOME/.local/bin/" || exit 1
	)
	local result=$?
	rm -rf "$tmp"
	return $result
}

has_gitleaks() {
	command -v gitleaks >/dev/null 2>&1 || [ -x "$HOME/.local/bin/gitleaks" ] || [ -x "$HOME/.local/bin/gitleaks.exe" ]
}

install_gitleaks() {
	if has_gitleaks; then
		echo "  gitleaks is installed"
		return
	fi
	if [ -n "${DOTFILES_SKIP_GITLEAKS:-}" ]; then
		echo "  Skipping gitleaks install (DOTFILES_SKIP_GITLEAKS is set)"
		return
	fi

	echo "  Installing gitleaks (scans commits to this repo for secrets)..."
	if command -v brew >/dev/null 2>&1 && brew install gitleaks >/dev/null 2>&1; then
		echo "  Installed gitleaks with Homebrew"
	elif command -v winget >/dev/null 2>&1 &&
		winget install --id Gitleaks.Gitleaks --exact --source winget --silent --accept-package-agreements --accept-source-agreements >/dev/null 2>&1; then
		echo "  Installed gitleaks with winget"
	elif download_gitleaks; then
		echo "  Installed gitleaks to ~/.local/bin"
	else
		note "couldn't install gitleaks. Commits to this repo will be blocked until it's installed:"
		detail "https://github.com/gitleaks/gitleaks#installing"
		detail "(Using the dotfiles doesn't need it - only committing to this repo does.)"
	fi
}

setup_repo_hooks() {
	echo "Repo:"
	if [ "$IS_GIT_CLONE" = 0 ]; then
		echo "  Skipping commit checks and gitleaks - this copy isn't a git clone, so it can't be committed from"
		return
	fi
	git -C "$DOTFILES" config core.hooksPath .githooks
	echo "  Enabled pre-commit checks for secrets, personal info and syntax errors"
	install_gitleaks
}

#   -------------------------------
#   CHECKS
#   -------------------------------

# warn_if_found <file> <content> <regex> <message>
warn_if_found() {
	if printf '%s\n' "$2" | grep -qE "$3"; then
		warning "$1 $4"
	fi
}

# Startup files can still contain old config outside the dotfiles block (e.g. a copy of an
# old .zshrc). It all still runs, so it can load things twice, override the dotfiles, or
# stop the shell before it reaches the block.
check_startup_files() {
	echo "Startup files:"
	local warnings_before=$WARNINGS problems_before=$PROBLEMS file content alias_count output shells shell

	for file in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc"; do
		[ -f "$file" ] || continue
		local file_warnings=$WARNINGS

		# Ignore comment lines
		content="$(without_dotfiles_block "$file" | grep -vE '^[[:space:]]*#' || true)"
		warn_if_found "$file" "$content" 'oh-my-zsh\.sh' "loads oh-my-zsh outside the dotfiles block, which already loads it."
		warn_if_found "$file" "$content" 'powerlevel10k|p10k\.zsh|POWERLEVEL9K_' "sets up the powerlevel10k prompt outside the dotfiles block, which already does."
		warn_if_found "$file" "$content" 'nvm\.sh' "loads nvm outside the dotfiles block, which already loads it (the nvm installer adds this; it can be removed)."
		warn_if_found "$file" "$content" '(jenv|pyenv|rbenv) init' "sets up jenv/pyenv/rbenv outside the dotfiles block, which already does."
		warn_if_found "$file" "$content" '\.fig/' "still loads Fig, which has been discontinued."
		warn_if_found "$file" "$content" 'shell-scripts' "still refers to the old shell-scripts repo."
		warn_if_found "$file" "$content" '(^|[[:space:];])(export[[:space:]]+)?HOME=' "changes HOME, so the shell and other programs (e.g. git in VS Code) can disagree about where your home folder is."
		if [ "$file" = "$HOME/.zshrc" ]; then
			warn_if_found "$file" "$content" '(source|\.)[[:space:]].*\.bashrc' "loads ~/.bashrc, but zsh now gets everything from the dotfiles block."
		fi
		alias_count="$(printf '%s\n' "$content" | grep -cE '^[[:space:]]*alias ' || true)"
		if [ "$alias_count" -ge 20 ]; then
			warning "$file defines $alias_count aliases outside the dotfiles block - is it a copy of an old config?"
		fi
		if [ "$WARNINGS" -gt "$file_warnings" ]; then
			detail "Everything outside the '$MARKER_START' block in $file still runs. If it's old config,"
			detail "back it up and start fresh: mv $file $file.old && $DOTFILES/install.sh"
		fi
	done

	# The block itself should match what this copy of the repo would write (it may point at a
	# moved or different copy, or be from an older version of install.sh)
	local expected_file expected
	for file in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc"; do
		[ -f "$file" ] && grep -qxF "$MARKER_START" "$file" || continue
		# install mode has already reported these (ensure_block)
		if ! markers_paired "$file"; then
			[ "$MODE" = check ] && problem "$file has a '$MARKER_START' line without a matching '$MARKER_END' line (or the other way round) - fix it by hand"
		elif [ "$(grep -cxF "$MARKER_START" "$file")" -gt 1 ]; then
			[ "$MODE" = check ] && problem "$file has more than one dotfiles block, so the dotfiles load more than once - delete all but one"
		fi
	done
	for expected_file in "$HOME/.bashrc:shell/bashrc.sh" "$HOME/.zshrc:shell/zshrc.sh"; do
		file="${expected_file%%:*}"
		[ -f "$file" ] && grep -qxF "$MARKER_START" "$file" || continue
		markers_paired "$file" && [ "$(grep -cxF "$MARKER_START" "$file")" -eq 1 ] || continue
		expected="$(shell_block "${expected_file#*:}")"
		if [ "$(block_contents "$file")" != "$expected" ]; then
			warning "the dotfiles block in $file is out of date or points at another copy of the repo - run ./install.sh"
		fi
	done

	# A syntax error stops the shell reading the file, so it might never reach the dotfiles block
	for file in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.zshrc" \
		"$(active_local_file shell_local.sh "$HOME/.shell_local")"; do
		[ -f "$file" ] || continue
		case "$file" in
			*/.zshrc) shells=zsh ;;
			*/shell_local.sh | */.shell_local) shells="bash zsh" ;;
			*) shells=bash ;;
		esac
		for shell in $shells; do
			command -v "$shell" >/dev/null 2>&1 || continue
			if ! output="$("$shell" -n "$file" 2>&1)"; then
				problem "$file has a $shell syntax error, so $shell stops reading it there:"
				echo "$output" | sed 's/^/    /'
			fi
		done
	done

	if [ "$WARNINGS" -eq "$warnings_before" ] && [ "$PROBLEMS" -eq "$problems_before" ]; then
		ok "no old config or syntax errors found"
	fi
}

# Settings in ~/.gitconfig override the shared config. A few personal ones are expected
# (user.name etc.), but overriding shared ones usually means an old copy of the config.
check_gitconfig() {
	echo "Git config:"
	local gitconfig="$HOME/.gitconfig" overlap count include_path
	if [ ! -f "$gitconfig" ]; then
		problem "$gitconfig doesn't exist - run ./install.sh"
		return
	fi
	include_path="$(native_path "$DOTFILES/git/gitconfig")"
	if git config --file "$gitconfig" --get-all include.path 2>/dev/null | grep -qxF "$include_path" &&
		! shared_include_first "$gitconfig" "$include_path"; then
		warning "the include for the shared config isn't at the top of $gitconfig, so it overrides the settings above it - run ./install.sh"
	fi
	# Settings both files have, minus the ones with identical values (harmless - e.g. `git lfs install` adds
	# the same [filter "lfs"] settings the shared config has)
	overlap="$(comm -23 \
		<(comm -12 \
			<(git config --file "$gitconfig" --name-only --list | sort -u) \
			<(git config --file "$DOTFILES/git/gitconfig" --name-only --list | sort -u)) \
		<(comm -12 \
			<(git config --file "$gitconfig" --list | sort -u) \
			<(git config --file "$DOTFILES/git/gitconfig" --list | sort -u) | cut -d= -f1 | sort -u))"
	if [ -n "$overlap" ]; then
		count="$(printf '%s\n' "$overlap" | wc -l | tr -d ' ')"
		warning "$gitconfig overrides $count setting(s) from the shared git config with different values:"
		detail "$(printf '%s\n' "$overlap" | head -5 | paste -sd ' ' -)$([ "$count" -gt 5 ] && echo " ...")"
		detail "If $gitconfig is a copy of an old config, keep only [user] and machine-specific settings below the include."
	else
		ok "$gitconfig doesn't override the shared config"
	fi
}

check_reminders() {
	echo "Reminders:"
	local reminders_shown=0 shell_local blocklist

	# --includes: user.email may be set in $LOCAL_DIR/gitconfig rather than directly in ~/.gitconfig
	if ! git config --global --includes --get user.email >/dev/null 2>&1; then
		note "no git user set on this machine. Run:"
		detail "git config --global user.name \"Your Name\""
		detail "git config --global user.email \"you@example.com\""
		reminders_shown=1
	fi
	shell_local="$(active_local_file shell_local.sh "$HOME/.shell_local")"
	if [ -f "$shell_local" ] && cmp -s "$shell_local" "$DOTFILES/local.example.sh"; then
		note "$shell_local is still the unedited template - set your name, email etc. there (run: open-local)"
		reminders_shown=1
	fi
	# The rest only matter for committing, which needs a git clone
	if [ "$IS_GIT_CLONE" = 0 ]; then
		:
	elif [ "$(git -C "$DOTFILES" config --get core.hooksPath || true)" != .githooks ]; then
		warning "the pre-commit checks aren't turned on for this repo - run ./install.sh"
		reminders_shown=1
	fi
	if [ "$IS_GIT_CLONE" = 1 ] && ! has_gitleaks; then
		note "gitleaks isn't installed, so commits to this repo will be blocked until it is."
		reminders_shown=1
	fi
	if zsh_available && ! has_powerlevel10k; then
		note "powerlevel10k isn't installed, so new zsh shells get a plain prompt instead of config/p10k.zsh's."
		reminders_shown=1
	fi
	if zsh_available && has_powerlevel10k && ! has_meslo_font; then
		note "the MesloLGS NF font isn't installed, so powerlevel10k's icons won't render correctly."
		reminders_shown=1
	fi
	if [ "$IS_GIT_CLONE" = 0 ]; then
		:
	else
		blocklist="$(active_local_file dotfiles_blocklist "$HOME/.dotfiles_blocklist")"
		if [ ! -f "$blocklist" ] || ! grep -qvE '^[[:space:]]*(#|$)' "$blocklist"; then
			note "$blocklist has no entries. If you commit to this repo from this machine, add"
			detail "your personal strings (emails, employer names...) or copy the file from another machine."
			reminders_shown=1
		fi
	fi

	if [ "$reminders_shown" = 0 ]; then
		ok "nothing to follow up"
	fi
}

# Starts each shell the way a new terminal would, checks it loaded this repo,
# and reports anything it printed as an error and how long it took
check_new_shells() {
	echo "New shells:"
	local shell result errors elapsed stdout_file stderr_file
	local TIMEFORMAT=%R
	stdout_file="$(mktemp)"
	stderr_file="$(mktemp)"

	for shell in bash zsh; do
		command -v "$shell" >/dev/null 2>&1 || continue
		elapsed="$( { time DOTFILES_WELCOME=false BASH_SILENCE_DEPRECATION_WARNING=1 \
			"$shell" -ic 'typeset -f dotfiles_welcome >/dev/null && echo "LOADED:$DOTFILES"' \
			</dev/null >"$stdout_file" 2>"$stderr_file"; } 2>&1 )" || true
		result="$(tail -n 1 "$stdout_file")"

		if [ "$result" = "LOADED:$DOTFILES" ]; then
			ok "new $shell shells load the dotfiles from $DOTFILES (${elapsed}s)"
		else
			problem "a new $shell shell didn't load the dotfiles from $DOTFILES - see the startup file and error messages."
		fi

		# Ignore the noise from starting an interactive shell without a terminal
		errors="$(grep -vE 'terminal process group|no job control|tcsetattr|Inappropriate ioctl|default interactive shell is now zsh|chsh -s /bin/zsh|HT208050|can.t change option: monitor|gitstatus failed to initialize|GITSTATUS_LOG_LEVEL|Restart Zsh to retry gitstatus initialization|Add the following parameter.*for extra diagnostics|exec zsh|^[[:space:]]*$' "$stderr_file" || true)"
		if [ -n "$errors" ]; then
			warning "new $shell shells print errors while starting:"
			printf '%s\n' "$errors" | head -10 | cut -c1-200 | sed 's/^/    /'
		fi

		if awk -v t="$elapsed" 'BEGIN { exit !(t > 1.0) }'; then
			warning "new $shell shells take ${elapsed}s to start. Slow steps are often nvm, \`yarn global bin\` or \`brew --prefix\`."
		fi
	done
	rm -f "$stdout_file" "$stderr_file"

	if git config --get-all include.path | grep -qxF "$(native_path "$DOTFILES/git/gitconfig")" &&
		[ "$(git config --get alias.aliases | head -c 1)" = '!' ]; then
		ok "git loads the shared config"
	else
		problem "git isn't loading $DOTFILES/git/gitconfig"
	fi
}

#   -------------------------------
#   MAIN
#   -------------------------------

main() {
	preflight
	if [ "$PROBLEMS" -gt 0 ]; then
		echo
		echo "Stopped before changing anything - fix the problems above, then run install.sh again."
		exit 1
	fi

	if [ "$MODE" = install ]; then
		setup_local_dir
		setup_shell
		setup_zsh_prompt
		setup_git
		setup_iterm
		setup_repo_hooks
	fi

	echo
	check_startup_files
	check_gitconfig
	check_new_shells
	check_reminders

	echo
	if [ "$PROBLEMS" -gt 0 ]; then
		echo "Finished with $PROBLEMS problem(s) and $WARNINGS warning(s) - see above."
		exit 1
	elif [ "$MODE" = check ] && [ "$WARNINGS" -gt 0 ]; then
		echo "Checks finished with $WARNINGS warning(s) - see above."
	elif [ "$MODE" = check ]; then
		echo "All checks passed."
	elif [ "$WARNINGS" -gt 0 ]; then
		echo "Done, with $WARNINGS warning(s) - see above. Open a new terminal to load the changes."
	else
		echo "Done. Open a new terminal to load the changes."
	fi
}

# Only run when executed - tests source this file to call its functions
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main
fi
