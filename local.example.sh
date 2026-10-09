# Template for ~/.shell_local - this machine's personal and machine-specific shell settings.
#
# install.sh copies this to ~/.shell_local. That file is NOT in the repo, so anything
# personal, work-related or specific to one computer goes there:
#   - values the shared files read (exported variables below)
#   - work-only aliases and functions, SSH shortcuts, server IPs
#   - extra PATH entries, tool setup that differs per machine
#
# It's loaded last, so it can override anything from the repo.
# Tools that set themselves up (e.g. `conda init`) write to ~/.zshrc / ~/.bashrc instead,
# which is fine - those files aren't in the repo either.

#   -------------------------------
#   Values used by the shared files
#   -------------------------------

# export NAME="Your Name"                 # Shown in the welcome message (default: your username)
# export EMAIL="you@example.com"          # Shown in the welcome message, default for create-ssh-key
# export COMPUTER_TYPE="Work computer"    # Shown by print-workspace-variables
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
