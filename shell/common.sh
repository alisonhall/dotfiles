# Shared by bash and zsh. Loaded by shell/bashrc.sh and shell/zshrc.sh.
# $DOTFILES is set by the block install.sh adds to ~/.bashrc / ~/.zshrc.

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

# Scripts in this repo, and per-user installs (e.g. gitleaks from install.sh)
for dir in "$HOME/.local/bin" "$DOTFILES/bin"; do
	case ":$PATH:" in
		*":$dir:"*) ;;
		*) export PATH="$dir:$PATH" ;;
	esac
done
unset dir

#   -------------------------------
#   ALIASES AND FUNCTIONS
#   -------------------------------
