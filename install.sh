#!/usr/bin/env bash
#
# Points this machine's shell and git config at this repo.
#
# Usage: ./install.sh
#
# Safe to re-run: every step checks whether it has already been done.
# Existing files are added to, never replaced. Anything that's a symlink
# (e.g. into an old dotfiles repo) is moved aside to <file>.bak.<timestamp>
# first so nothing gets written through it.

set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER_START="# >>> dotfiles >>>"
MARKER_END="# <<< dotfiles <<<"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"

# Git for Windows needs native paths (D:/...) rather than Git Bash paths (/d/...)
native_path() {
	if command -v cygpath >/dev/null 2>&1; then
		cygpath -m "$1"
	else
		printf '%s\n' "$1"
	fi
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
		echo "  PROBLEM: $file has a '$MARKER_START' line but no '$MARKER_END' line."
		echo "    Fix or delete the block by hand, then run install.sh again."
		return 1
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
					git config --global --fixed-value --unset include.path "$old_path"
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

	if ! git config --global --get user.email >/dev/null 2>&1; then
		echo "  NOTE: no git user set on this machine. Run:"
		echo "    git config --global user.name \"Your Name\""
		echo "    git config --global user.email \"you@example.com\""
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
	if [ "$(defaults read com.googlecode.iterm2 LoadPrefsFromCustomFolder 2>/dev/null)" = 1 ] && [ -d "$current_folder" ]; then
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

install_gitleaks() {
	if command -v gitleaks >/dev/null 2>&1 || [ -x "$HOME/.local/bin/gitleaks" ] || [ -x "$HOME/.local/bin/gitleaks.exe" ]; then
		echo "  gitleaks is installed"
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
		echo "  NOTE: couldn't install gitleaks. Commits to this repo will be blocked until it's installed:"
		echo "    https://github.com/gitleaks/gitleaks#installing"
		echo "  (Using the dotfiles doesn't need it - only committing to this repo does.)"
	fi
}

setup_repo_hooks() {
	echo "Repo:"
	git -C "$DOTFILES" config core.hooksPath .githooks
	echo "  Enabled pre-commit checks for secrets and personal info"
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
#   CHECK
#   -------------------------------

# Starts each shell the way a new terminal would and checks it loaded this repo
verify_setup() {
	echo "Check:"
	local problems=0 shell result
	for shell in bash zsh; do
		[ "$shell" = zsh ] && { command -v zsh >/dev/null 2>&1 || continue; }
		result="$(DOTFILES_WELCOME=false "$shell" -ic 'typeset -f showa >/dev/null && echo "LOADED:$DOTFILES"' </dev/null 2>/dev/null | tail -n 1)"
		if [ "$result" = "LOADED:$DOTFILES" ]; then
			echo "  OK: new $shell shells load the dotfiles from $DOTFILES"
		else
			echo "  PROBLEM: a new $shell shell didn't load the dotfiles (got: ${result:-nothing})"
			problems=$((problems + 1))
		fi
	done

	if git config --get-all include.path | grep -qxF "$(native_path "$DOTFILES/git/gitconfig")" &&
		[ "$(git config --get alias.aliases | head -c 1)" = '!' ]; then
		echo "  OK: git loads the shared config"
	else
		echo "  PROBLEM: git isn't loading $DOTFILES/git/gitconfig"
		problems=$((problems + 1))
	fi
	return $problems
}

setup_shell
setup_git
setup_iterm
setup_repo_hooks
echo
if verify_setup; then
	echo
	echo "Done. Open a new terminal to load the changes."
else
	echo
	echo "Finished with problems - see above."
	exit 1
fi
