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

# Re-run with bash if started some other way (e.g. `sh install.sh` or `zsh install.sh`)
if [ -z "${BASH_VERSION:-}" ]; then
	exec bash "$0" "$@"
fi

set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER_START="# >>> dotfiles >>>"
MARKER_END="# <<< dotfiles <<<"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"

MODE=install
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

	if ! grep -qxF "$MARKER_END" "$file"; then
		problem "$file has a '$MARKER_START' line but no '$MARKER_END' line."
		detail "Fix or delete the block by hand, then run install.sh again."
		return
	fi

	current="$(awk -v start="$MARKER_START" -v end="$MARKER_END" '
		$0 == start { inside = 1; next }
		$0 == end { inside = 0 }
		inside' "$file")"
	if [ "$current" = "$contents" ]; then
		echo "  $file is already set up"
		return
	fi

	cp "$file" "$file.bak.$TIMESTAMP"
	DOTFILES_BLOCK="$contents" awk -v start="$MARKER_START" -v end="$MARKER_END" '
		$0 == start { print; print ENVIRON["DOTFILES_BLOCK"]; skip = 1; next }
		$0 == end { skip = 0 }
		!skip' "$file.bak.$TIMESTAMP" > "$file"
	echo "  Updated the dotfiles block in $file (it was out of date; old version in $file.bak.$TIMESTAMP)"
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

	if [ "$PROBLEMS" -eq "$problems_before" ]; then
		ok "running as $(id -un) with bash $BASH_VERSION and git $(git --version | awk '{ print $3 }'); the repo's files pass syntax checks"
	fi
}

#   -------------------------------
#   SHELL
#   -------------------------------

shell_block() {
	printf 'export DOTFILES="%s"\nsource "$DOTFILES/%s"' "$DOTFILES" "$1"
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
	if command -v zsh >/dev/null 2>&1 || [ -f "$HOME/.zshrc" ]; then
		ensure_block "$HOME/.zshrc" "$(shell_block shell/zshrc.sh)"
	fi

	if [ ! -f "$HOME/.shell_local" ]; then
		cp "$DOTFILES/local.example.sh" "$HOME/.shell_local"
		echo "  Created ~/.shell_local from local.example.sh - fill it in for this machine"
	fi
}

#   -------------------------------
#   GIT
#   -------------------------------

git_unset_include() {
	if git_version_at_least 2 30; then
		git config --global --fixed-value --unset include.path "$1"
	else
		# Older git only matches by regex, so escape the path
		git config --global --unset include.path "^$(printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g')\$"
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

	# Remove includes of a dotfiles gitconfig that no longer exists (e.g. the repo moved).
	# Git silently ignores missing include files, so these would otherwise go unnoticed.
	local old_path
	while IFS= read -r old_path; do
		case "$old_path" in
			"$include_path") ;;
			*/git/gitconfig)
				if [ ! -f "$old_path" ]; then
					git_unset_include "$old_path"
					echo "  Removed include of $old_path (file no longer exists)"
				fi
				;;
		esac
	done < <(git config --global --get-all include.path 2>/dev/null)

	if git config --global --get-all include.path 2>/dev/null | grep -qxF "$include_path"; then
		echo "  $gitconfig already includes the shared config"
	else
		if [ -s "$gitconfig" ]; then
			cp "$gitconfig" "$gitconfig.bak.$TIMESTAMP"
			echo "  Backed up $gitconfig to $gitconfig.bak.$TIMESTAMP"
		fi
		{
			printf '# Shared config from the dotfiles repo. Settings below this override it.\n'
			printf '[include]\n\tpath = %s\n' "$include_path"
			[ -f "$gitconfig" ] && cat "$gitconfig"
		} > "$gitconfig.tmp"
		mv "$gitconfig.tmp" "$gitconfig"
		echo "  Added include for the shared config to the top of $gitconfig"
	fi

	# Point core.excludesfile at the repo's gitignore_global, unless it's set to another file that exists
	local excludes
	excludes="$(git config --global --get core.excludesfile 2>/dev/null || true)"
	if [ -z "$excludes" ] || { [ ! -f "${excludes/#\~/$HOME}" ] && [ "$excludes" != "$(native_path "$DOTFILES/git/gitignore_global")" ]; }; then
		git config --global core.excludesfile "$(native_path "$DOTFILES/git/gitignore_global")"
		echo "  Set core.excludesfile to the repo's gitignore_global${excludes:+, replacing the missing $excludes}"
	fi
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
	if [ "$(defaults read com.googlecode.iterm2 LoadPrefsFromCustomFolder 2>/dev/null || true)" = 1 ] && [ -d "$current_folder" ]; then
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
	git -C "$DOTFILES" config core.hooksPath .githooks
	echo "  Enabled pre-commit checks for secrets, personal info and syntax errors"
	install_gitleaks
	if [ ! -f "$HOME/.dotfiles_blocklist" ]; then
		cat > "$HOME/.dotfiles_blocklist" <<'EOF'
# Strings that must never be committed to the public dotfiles repo.
# One per line, case-insensitive, matched literally (not regex).
# e.g. personal and work email addresses, employer/client names,
# server hostnames, IP addresses, your home folder name.
EOF
		echo "  Created ~/.dotfiles_blocklist - add personal strings the pre-commit hook should block"
	fi
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

	# A syntax error stops the shell reading the file, so it might never reach the dotfiles block
	for file in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.zshrc" "$HOME/.shell_local"; do
		[ -f "$file" ] || continue
		case "$file" in
			*/.zshrc) shells=zsh ;;
			*/.shell_local) shells="bash zsh" ;;
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
	local gitconfig="$HOME/.gitconfig" overlap count
	if [ ! -f "$gitconfig" ]; then
		problem "$gitconfig doesn't exist - run ./install.sh"
		return
	fi
	overlap="$(comm -12 \
		<(git config --file "$gitconfig" --name-only --list | sort -u) \
		<(git config --file "$DOTFILES/git/gitconfig" --name-only --list | sort -u))"
	if [ -n "$overlap" ]; then
		count="$(printf '%s\n' "$overlap" | wc -l | tr -d ' ')"
		warning "$gitconfig sets $count things the shared git config also sets, so the shared versions are ignored:"
		detail "$(printf '%s\n' "$overlap" | head -5 | paste -sd ' ' -)$([ "$count" -gt 5 ] && echo " ...")"
		detail "If $gitconfig is a copy of an old config, keep only [user] and machine-specific settings below the include."
	else
		ok "$gitconfig doesn't override the shared config"
	fi
}

check_reminders() {
	echo "Reminders:"
	local reminders_shown=0

	if ! git config --global --get user.email >/dev/null 2>&1; then
		note "no git user set on this machine. Run:"
		detail "git config --global user.name \"Your Name\""
		detail "git config --global user.email \"you@example.com\""
		reminders_shown=1
	fi
	if [ -f "$HOME/.shell_local" ] && cmp -s "$HOME/.shell_local" "$DOTFILES/local.example.sh"; then
		note "~/.shell_local is still the unedited template - set your name, email etc. there (run: open-local)"
		reminders_shown=1
	fi
	if [ "$(git -C "$DOTFILES" config --get core.hooksPath || true)" != .githooks ]; then
		warning "the pre-commit checks aren't turned on for this repo - run ./install.sh"
		reminders_shown=1
	fi
	if ! has_gitleaks; then
		note "gitleaks isn't installed, so commits to this repo will be blocked until it is."
		reminders_shown=1
	fi
	if [ ! -f "$HOME/.dotfiles_blocklist" ] || ! grep -qvE '^[[:space:]]*(#|$)' "$HOME/.dotfiles_blocklist"; then
		note "~/.dotfiles_blocklist has no entries. If you commit to this repo from this machine, add"
		detail "your personal strings (emails, employer names...) or copy the file from another machine."
		reminders_shown=1
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
		errors="$(grep -vE 'terminal process group|no job control|tcsetattr|Inappropriate ioctl|default interactive shell is now zsh|chsh -s /bin/zsh|HT208050|^[[:space:]]*$' "$stderr_file" || true)"
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

preflight
if [ "$PROBLEMS" -gt 0 ]; then
	echo
	echo "Stopped before changing anything - fix the problems above, then run install.sh again."
	exit 1
fi

if [ "$MODE" = install ]; then
	setup_shell
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
