# Zsh config. Loaded from ~/.zshrc (see install.sh).

source "$DOTFILES/shell/common.sh"

#   -------------------------------
#   ZSH ONLY
#   -------------------------------

# This machine's settings - loaded last so they override everything above
[ -f "$HOME/.shell_local" ] && source "$HOME/.shell_local"
