# Template for local/shell_local.sh - this machine's personal and machine-specific shell settings.
#
# install.sh copies this to local/shell_local.sh (in local/, this machine's own gitignored,
# independently-versioned folder - see install.sh's setup_local_dir). Anything personal,
# work-related or specific to one computer goes there:
#   - values the shared files read (exported variables below)
#   - work-only aliases and functions, SSH shortcuts, server IPs
#   - extra PATH entries, tool setup that differs per machine
#
# It's loaded last, so it can override anything from the repo.
# Tools that set themselves up (e.g. `conda init`) write to ~/.zshrc / ~/.bashrc instead,
# which is fine - those files aren't in the repo either.
#
# Other setup scripts (e.g. for a private dotfiles repo) may add a marked block at the top of
# this file. Leave it in place - settings below it override what it loads.

# Secrets (API tokens, credentials) live in secrets.sh instead, so they never need to pass
# this folder's pre-commit hook. Sourced first, so the rest of this file can use them.
[ -f "$DOTFILES/local/secrets.sh" ] && source "$DOTFILES/local/secrets.sh"

#   -------------------------------
#   Values used by the shared files
#   -------------------------------

# export NAME="Your Name"                 # Shown in the welcome message (default: your username)
# export EMAIL="you@example.com"          # Shown in the welcome message, default for create-ssh-key
# export SITES_DIR="$HOME/Sites"          # Where goto-sites goes
# export CURRENT_REMOTE_NAME=origin       # Remote used by the git shortcuts
# export CURRENT_DEV_BRANCH=main          # Branch dev/sprint/gmerge-dev use (default: the remote's default branch)
# DOTFILES_WELCOME=false                  # Turn off the welcome message
# export IMAGE_LIST_CSV_URL="https://docs.google.com/spreadsheets/d/e/.../pub?output=csv"   # For getimagesfromlist.sh

#   -------------------------------
#   This machine only
#   -------------------------------

# alias ssh-myserver='ssh user@host'
# path_add "/some/tool/bin"               # Add a folder to PATH (only if it exists)
#   PATH folders for tools: the shared repo only adds standard ones (~/.local/bin, Homebrew,
#   VS Code's `code`). A tool only this machine has goes here; one you use on all your
#   machines goes in your own private repo, if you have one.
