# Bash config. Loaded from ~/.bashrc (see install.sh).

export DOTFILES_SHELL=bash
source "$DOTFILES/shell/common.sh"

#   -------------------------------
#   BASH ONLY
#   -------------------------------

# Tab completion from Homebrew's bash-completion package
if command -v brew >/dev/null 2>&1 && [ -f "$(brew --prefix)/etc/bash_completion" ]; then
	source "$(brew --prefix)/etc/bash_completion"
fi
[ -s "$NVM_DIR/bash_completion" ] && source "$NVM_DIR/bash_completion"

alias reload-profile='source ~/.bashrc'     # reload-profile:   Reload the shell config
alias show_options='shopt'                  # show_options:     display bash options settings
alias cic='bind "set completion-ignore-case on"'    # cic:      Make tab-completion case-insensitive

# This machine's settings - loaded last so they override everything above
[ -f "$HOME/.shell_local" ] && source "$HOME/.shell_local"

dotfiles_welcome
