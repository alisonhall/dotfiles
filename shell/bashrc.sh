# Bash config. Loaded from ~/.bashrc (see install.sh).

source "$DOTFILES/shell/common.sh"

#   -------------------------------
#   BASH ONLY
#   -------------------------------

# This machine's settings - loaded last so they override everything above
[ -f "$HOME/.shell_local" ] && source "$HOME/.shell_local"
