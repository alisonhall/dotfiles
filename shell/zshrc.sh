# Zsh config. Loaded from ~/.zshrc (see install.sh).

export DOTFILES_SHELL=zsh

#   -------------------------------
#   OH MY ZSH
#   -------------------------------

# Loaded before the shared files so their aliases override the plugins' aliases
export ZSH="$HOME/.oh-my-zsh"
if [ -d "$ZSH" ]; then
	ZSH_THEME=""                # The prompt comes from powerlevel10k below
	ENABLE_CORRECTION="true"    # Command auto-correction
	HIST_STAMPS="mm/dd/yyyy"    # Command execution time stamp shown in the history command output
	plugins=(git node npm nvm yarn extract sudo bower docker docker-compose)
	[[ "$OSTYPE" == darwin* ]] && plugins+=(brew macos)
	source "$ZSH/oh-my-zsh.sh"
fi

source "$DOTFILES/shell/common.sh"

#   -------------------------------
#   ZSH ONLY
#   -------------------------------

alias reload-profile='source ~/.zshrc'      # reload-profile:   Reload the shell config
alias reload-zsh='source ~/.zshrc'
alias open-zsh='code ~/.zshrc'
alias zsh-icons='get_icon_names'
alias zsh-colours='for code ({000..255}) print -P -- "$code: %F{$code}This is how your text would look like%f"'

# Automatically run `nvm use` when entering a directory that has a .nvmrc file
if typeset -f nvm_find_nvmrc >/dev/null; then
	autoload -U add-zsh-hook
	load-nvmrc () {
		local node_version="$(nvm version)"
		local nvmrc_path="$(nvm_find_nvmrc)"

		if [ -n "$nvmrc_path" ]; then
			local nvmrc_node_version=$(nvm version "$(cat "${nvmrc_path}")")

			if [ "$nvmrc_node_version" = "N/A" ]; then
				nvm install
			elif [ "$nvmrc_node_version" != "$node_version" ]; then
				nvm use
			fi
		elif [ "$node_version" != "$(nvm version default)" ]; then
			echo "Reverting to nvm default version"
			nvm use default
		fi
	}
	add-zsh-hook chpwd load-nvmrc
	load-nvmrc
fi

#   -------------------------------
#   PROMPT (powerlevel10k)
#   -------------------------------

for p10k_theme in /opt/homebrew/share/powerlevel10k/powerlevel10k.zsh-theme \
	/usr/local/share/powerlevel10k/powerlevel10k.zsh-theme \
	"$HOME/powerlevel10k/powerlevel10k.zsh-theme"; do
	[ -f "$p10k_theme" ] && source "$p10k_theme" && break
done
unset p10k_theme

# Prompt settings: ~/.p10k.zsh if this machine has its own (`p10k configure` writes one), otherwise the shared one
if [ -f ~/.p10k.zsh ]; then
	source ~/.p10k.zsh
else
	source "$DOTFILES/config/p10k.zsh"
fi

# This machine's settings - loaded last so they override everything above
[ -f "$HOME/.shell_local" ] && source "$HOME/.shell_local"

dotfiles_welcome
