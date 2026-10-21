# Shared by bash and zsh. Loaded by shell/bashrc.sh and shell/zshrc.sh.
# $DOTFILES is set by the block install.sh adds to ~/.bashrc / ~/.zshrc.
#
# Personal and machine-specific settings go in local/shell_local.sh (see local.example.sh).
# It's loaded after this file, so it can override anything here.

#   -------------------------------
#   ENVIRONMENT
#   -------------------------------

# Use for OS-specific sections: if [ "$DOTFILES_OS" = mac ]; then ...; fi
case "$(uname -s)" in
	Darwin*) export DOTFILES_OS=mac ;;
	Linux*) export DOTFILES_OS=linux ;;
	MINGW* | MSYS* | CYGWIN*) export DOTFILES_OS=windows ;;
	*) export DOTFILES_OS=unknown ;;
esac

# Defaults - override any of these in local/shell_local.sh
export NAME="${USER:-$USERNAME}"
export CURRENT_REMOTE_NAME=origin
export SITES_DIR="$HOME/Sites"
export BLOCKSIZE=1k

#   -------------------------------
#   PATH
#   -------------------------------

# path_add <dir> [--prepend]: Add a folder to PATH if it exists and isn't already there
path_add () {
	[ -d "$1" ] || return 0
	case ":$PATH:" in
		*":$1:"*) return 0 ;;
	esac
	if [ "${2:-}" = --prepend ]; then
		export PATH="$1:$PATH"
	else
		export PATH="$PATH:$1"
	fi
}

# Homebrew, first so the tool setup below finds what it installed (bash doesn't read ~/.zprofile,
# where the Homebrew installer puts this). Skipped if already done, so reloading doesn't duplicate PATH.
if [ -z "${HOMEBREW_PREFIX:-}" ]; then
	for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do  # path-check: ignore (Homebrew's fixed Linux location)
		[ -x "$brew_bin" ] && eval "$("$brew_bin" shellenv)" && break
	done
	unset brew_bin
fi

path_add "$HOME/.local/bin" --prepend           # Per-user installs (e.g. gitleaks from install.sh)
path_add "$DOTFILES/bin" --prepend              # Scripts in this repo

# Tools used by one person or one machine go in the private repo or local/shell_local.sh, not here
# (see local.example.sh)

#   -------------------------------
#   TOOLS
#   -------------------------------

# Node: nvm if it's installed, otherwise fnm
export NVM_DIR="$HOME/.nvm"
if [ -s "$NVM_DIR/nvm.sh" ]; then
	source "$NVM_DIR/nvm.sh"
elif command -v fnm >/dev/null 2>&1; then
	eval "$(fnm env --use-on-cd --shell "$DOTFILES_SHELL")"
fi

# path_front <dir>: Put a folder at the start of PATH even if it's already there further along
path_front () {
	[ -d "$1" ] || return 0
	# Compares each entry literally (a ${PATH//pattern/} substitution would treat glob characters in
	# a folder name as a pattern in bash, and leave one copy of a folder that appears twice in a row)
	local remaining="$PATH" entry rest=""
	while [ -n "$remaining" ]; do
		entry="${remaining%%:*}"
		if [ "$remaining" = "$entry" ]; then
			remaining=""
		else
			remaining="${remaining#*:}"
		fi
		[ "$entry" = "$1" ] || rest="${rest:+$rest:}$entry"
	done
	export PATH="$1${rest:+:$rest}"
}

# nvm leaves PATH alone when its version is already active, e.g. in a terminal that inherited a PATH
# with nvm's folder in it. Homebrew's own node (some formulae depend on it) would then win over the
# version nvm reports, so move nvm's folder back to the front.
[ -n "${NVM_BIN:-}" ] && path_front "$NVM_BIN"

# npm: local/npmrc if this machine has one (a custom registry, etc. - most machines won't),
# otherwise npm's own default of ~/.npmrc
[ -f "$DOTFILES/local/npmrc" ] && export NPM_CONFIG_USERCONFIG="$DOTFILES/local/npmrc"

# Maven: local/m2-settings.xml if this machine has one (same idea as npm above), otherwise Maven's
# own default of ~/.m2/settings.xml. A wrapper rather than MAVEN_ARGS, which Maven splits on spaces,
# so a repo path with a space in it would break. oh-my-zsh's mvn plugin aliases mvn to mvn-or-mvnw
# (a project's ./mvnw if it has one), so that alias is replaced by this, which calls mvn-or-mvnw
# itself - the settings reach ./mvnw too. Leaves your own -s/--settings alone.
{ [ -n "${ZSH_VERSION:-}" ] && unalias mvn 2>/dev/null; } || true
function mvn {
	local maven=(command mvn) arg
	typeset -f mvn-or-mvnw >/dev/null 2>&1 && maven=(mvn-or-mvnw)
	if [ ! -f "$DOTFILES/local/m2-settings.xml" ]; then
		"${maven[@]}" "$@"
		return
	fi
	for arg in "$@"; do
		case "$arg" in
			-s | --settings | --settings=*)
				"${maven[@]}" "$@"
				return
				;;
		esac
	done
	"${maven[@]}" --settings "$DOTFILES/local/m2-settings.xml" "$@"
}

command -v rbenv >/dev/null 2>&1 && eval "$(rbenv init -)"

# jenv and pyenv installed with git (rather than Homebrew) live in these folders
path_add "$HOME/.jenv/bin"
path_add "$HOME/.pyenv/bin"
command -v jenv >/dev/null 2>&1 && eval "$(jenv init -)"
command -v pyenv >/dev/null 2>&1 && eval "$(pyenv init -)"
command -v yarn >/dev/null 2>&1 && path_add "$(yarn global bin 2>/dev/null)"
command -v copilot >/dev/null 2>&1 && export COPILOT_BIN="$(command -v copilot)"

# z: jump to frequently used folders
for z_script in /opt/homebrew/etc/profile.d/z.sh /usr/local/etc/profile.d/z.sh; do
	[ -f "$z_script" ] && source "$z_script" && break
done
unset z_script

#   -------------------------------
#   DOTFILES
#   -------------------------------

alias goto-dotfiles='cd "$DOTFILES"'
alias goto-scripts='cd "$DOTFILES/bin"'
alias goto-sites='cd "$SITES_DIR"'
alias goto-local='cd "$DOTFILES/local"'
alias open-dotfiles='code "$DOTFILES"'
alias open-profile='code "$DOTFILES"'
# open-local: Opens whichever shell_local file is actually in use - local/shell_local.sh, or
# ~/.shell_local if you'd rather keep it there (e.g. you declined install.sh's offer to move it)
open-local () {
	if [ -f "$DOTFILES/local/shell_local.sh" ]; then
		code "$DOTFILES/local/shell_local.sh"
	elif [ -f "$HOME/.shell_local" ]; then
		code "$HOME/.shell_local"
	else
		code "$DOTFILES/local/shell_local.sh"
	fi
}
alias open-gitconfig='code ~/.gitconfig "$DOTFILES/git/gitconfig" "$DOTFILES/local/gitconfig"'

# update-dotfiles: Pull the latest dotfiles and reload them
update-dotfiles () {
	if [ ! -e "$DOTFILES/.git" ]; then
		echo "Can't update: $DOTFILES isn't a git clone (downloaded as a ZIP?). Clone the repo and run its install.sh."
		return 1
	fi
	git -C "$DOTFILES" pull && source "$HOME/.${DOTFILES_SHELL}rc"
}
alias get-updated-scripts='update-dotfiles'

print-workspace-variables () {
	printf '\n'
	printf ' %s: %s\n' \
		NAME "$NAME" \
		EMAIL "${EMAIL:-}" \
		DOTFILES_PROFILE "${DOTFILES_PROFILE:-}" \
		DOTFILES "$DOTFILES" \
		DOTFILES_OS "$DOTFILES_OS" \
		SITES_DIR "$SITES_DIR" \
		CURRENT_REMOTE_NAME "$CURRENT_REMOTE_NAME" \
		CURRENT_DEV_BRANCH "$(git_dev_branch 2>/dev/null)" \
		CURRENT_REPOSITORY "$(git_repository_url 2>/dev/null)" \
		CURRENT_BRANCH "$(parse_git_branch 2>/dev/null)"
	printf '\n'
}

# Welcome message, shown by bashrc.sh / zshrc.sh after local/shell_local.sh is loaded.
# Turn it off with DOTFILES_WELCOME=false in local/shell_local.sh.
dotfiles_welcome () {
	case $- in *i*) ;; *) return 0 ;; esac
	[ "${DOTFILES_WELCOME:-true}" = true ] || return 0
	printf '\n*********************************\nHello %s!\n' "$NAME"
	[ -n "${EMAIL:-}" ] && printf '\n%s\n' "$EMAIL"
	printf '*********************************\n\nUseful commands/aliases:\n'
	printf '%s\n' 'finda *' 'showa *' print-workspace-variables update-dotfiles open-dotfiles open-local \
		reload-profile goto-dotfiles show-ssh-key copy-ssh-key 'g aliases' 'g finda *' ips 'killport ####' list-path
}

#   -------------------------------
#   ALIASES AND FUNCTIONS
#   -------------------------------

# OS-specific files load last so they can replace the general versions
for dotfiles_file in "$DOTFILES"/shell/common/*.sh "$DOTFILES/shell/os/$DOTFILES_OS.sh"; do
	[ -f "$dotfiles_file" ] && source "$dotfiles_file"
done
unset dotfiles_file
