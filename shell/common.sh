# Shared by bash and zsh. Loaded by shell/bashrc.sh and shell/zshrc.sh.
# $DOTFILES is set by the block install.sh adds to ~/.bashrc / ~/.zshrc.
#
# Personal and machine-specific settings go in ~/.shell_local (see local.example.sh).
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

# Defaults - override any of these in ~/.shell_local
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

path_add "$HOME/.local/bin" --prepend           # Per-user installs (e.g. gitleaks from install.sh)
path_add "$DOTFILES/bin" --prepend              # Scripts in this repo
path_add "$HOME/.console-ninja/.bin" --prepend  # Console Ninja (VS Code extension)
path_add "$HOME/.jenv/bin"                      # Java jenv
path_add "$HOME/.pyenv/bin"                     # Python pyenv

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

command -v rbenv >/dev/null 2>&1 && eval "$(rbenv init -)"
command -v jenv >/dev/null 2>&1 && eval "$(jenv init -)"
command -v pyenv >/dev/null 2>&1 && eval "$(pyenv init -)"
command -v yarn >/dev/null 2>&1 && path_add "$(yarn global bin 2>/dev/null)"

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
alias open-dotfiles='code "$DOTFILES"'
alias open-profile='code "$DOTFILES"'
alias open-local='code ~/.shell_local'
alias open-gitconfig='code ~/.gitconfig "$DOTFILES/git/gitconfig"'

# update-dotfiles: Pull the latest dotfiles and reload them
update-dotfiles () {
	git -C "$DOTFILES" pull && source "$HOME/.${DOTFILES_SHELL}rc"
}
alias get-updated-scripts='update-dotfiles'

print-workspace-variables () {
	printf '\n'
	printf ' %s: %s\n' \
		NAME "$NAME" \
		EMAIL "${EMAIL:-}" \
		COMPUTER_TYPE "${COMPUTER_TYPE:-}" \
		DOTFILES "$DOTFILES" \
		DOTFILES_OS "$DOTFILES_OS" \
		SITES_DIR "$SITES_DIR" \
		CURRENT_REMOTE_NAME "$CURRENT_REMOTE_NAME" \
		CURRENT_DEV_BRANCH "$(git_dev_branch 2>/dev/null)" \
		CURRENT_REPOSITORY "$(git_repository_url 2>/dev/null)" \
		CURRENT_BRANCH "$(parse_git_branch 2>/dev/null)"
	printf '\n'
}

# Welcome message, shown by bashrc.sh / zshrc.sh after ~/.shell_local is loaded.
# Turn it off with DOTFILES_WELCOME=false in ~/.shell_local.
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
