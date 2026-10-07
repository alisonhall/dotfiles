# Template for ~/.shell_local - this machine's personal and machine-specific shell settings.
#
# install.sh copies this to ~/.shell_local. That file is NOT in the repo, so anything
# personal, work-related or specific to one computer goes there:
#   - values the shared files read (exported variables below)
#   - work-only aliases and functions, SSH shortcuts, server IPs
#   - extra PATH entries, tool setup (conda, nvm, jenv...) that differs per machine
#
# It's loaded last, so it can override anything from the repo.

#   -------------------------------
#   Values used by the shared files
#   -------------------------------

# export EMAIL="you@example.com"

#   -------------------------------
#   This machine only
#   -------------------------------

# alias ssh-myserver='ssh user@host'
