# Navigation, files and searching. Loaded by shell/common.sh (bash and zsh).

#   -----------------------------
#   MAKE TERMINAL BETTER
#   -----------------------------

alias cp='cp -i'                            # cp:           Confirm before overwriting
alias mv='mv -i'                            # mv:           Confirm before overwriting
alias ln='ln -i'                            # ln:           Confirm before overwriting
alias mkdir='mkdir -pv'                     # mkdir:        Create parent folders as needed
alias ll='ls -FlAhp --color=auto'           # ll:           Preferred 'ls' implementation (os/mac.sh has the macOS version)
alias cd..='cd ../'                         # cd..          Go back 1 directory level (for fast typers)
alias ..='cd ../'                           # ..            Go back 1 directory level
alias ...='cd ../../'                       # ...           Go back 2 directory levels
alias .3='cd ../../../'                     # .3            Go back 3 directory levels
alias .4='cd ../../../../'                  # .4            Go back 4 directory levels
alias .5='cd ../../../../../'               # .5            Go back 5 directory levels
alias .6='cd ../../../../../../'            # .6            Go back 6 directory levels

alias edit='subl'                           # edit:         Opens any file in sublime editor
alias vscode='code'                         # vscode:       Opens VSCode
alias vscodenew='code .'                    # vscodenew:    Opens new window of VSCode
alias ~='cd ~'                              # ~:            Go Home
alias c='clear'                             # c:            Clear terminal display
alias path='pwd'                            # path:         Show the current path
alias pathe='echo -e ${PATH//:/\\n}'        # pathe:        Echo all executable Paths
alias list-path='echo -e ${PATH//:/\\n}'    # list-path:    Echo all executable Paths
alias copypath='pwd | pbcopy'               # copypath:     Copy the path
alias fix_stty='stty sane'                  # fix_stty:     Restore terminal settings when screwed up
alias finda='alias | grep'                  # finda:        Find an alias by part of its name or command
alias h='history'                           # h:            Show command history
alias j='jobs -l'                           # j:            List background jobs
mcd () { mkdir -p "$1" && cd "$1"; }        # mcd:          Makes new Dir and jumps inside
alias DT='tee ~/Desktop/terminalOut.txt'    # DT:           Pipe content to file on the Desktop

#   lr:  Full Recursive Directory Listing
#   ------------------------------------------
alias lr='ls -R | grep ":$" | sed -e '\''s/:$//'\'' -e '\''s/[^-][^\/]*\//--/g'\'' -e '\''s/^/   /'\'' -e '\''s/-/|/'\'' | less'

#   mans:   Search manpage given in argument '1' for term given in argument '2' (case insensitive)
#           displays paginated result with colored search terms and two lines surrounding each hit.
#           Example: mans mplayer codec
#   --------------------------------------------------------------------
mans () {
	man "$1" | grep -iC2 --color=always "$2" | less
}

#   showa: Find an alias or function in these dotfiles by part of its name or command
#   ------------------------------------------------------------
showa () { grep -rn --color=always -i "$@" "$DOTFILES/shell" | less -FSRXc; }

## Colorize the grep command output for ease of use (good for log files)##
alias grep='grep --color=auto'
alias egrep='grep -E --color=auto'
alias fgrep='grep -F --color=auto'

# Start calculator with math support
alias bc='bc -l'

# Colorize diff output (needs the colordiff package)
command -v colordiff >/dev/null 2>&1 && alias diff='colordiff'

# Make mount command output pretty and human readable format
alias mount='mount | column -t'

# Show what shell you're currently in. Note that the environment variable SHELL will tell you what you started in, but if you change it it doesn't update.
shell () {
	ps | grep "$$" | awk '{ print $4 }'
}

alias now='date +"%T"'
alias nowtime=now
alias nowdate='date +"%d-%m-%Y"'

#   -------------------------------
#   FILE AND FOLDER MANAGEMENT
#   -------------------------------

zipf () { zip -r "$1".zip "$1" ; }          # zipf:         To create a ZIP archive of a folder
alias numFiles='echo $(ls -1 | wc -l)'      # numFiles:     Count of non-hidden files in current dir
alias cleanupDS="find . -type f -name '*.DS_Store' -ls -delete"    # cleanupDS:    Recursively delete .DS_Store files
alias make-script-executable='chmod +x'

#   extract:  Extract most known archives with one command
#   ---------------------------------------------------------
extract () {
	if [ -f "$1" ] ; then
		case "$1" in
			*.tar.bz2)   tar xjf "$1"     ;;
			*.tar.gz)    tar xzf "$1"     ;;
			*.bz2)       bunzip2 "$1"     ;;
			*.rar)       unrar e "$1"     ;;
			*.gz)        gunzip "$1"      ;;
			*.tar)       tar xf "$1"      ;;
			*.tbz2)      tar xjf "$1"     ;;
			*.tgz)       tar xzf "$1"     ;;
			*.zip)       unzip "$1"       ;;
			*.Z)         uncompress "$1"  ;;
			*.7z)        7z x "$1"        ;;
			*)     echo "'$1' cannot be extracted via extract()" ;;
		esac
	else
		echo "'$1' is not a valid file"
	fi
}

## https://opensource.com/article/19/8/navigating-bash-shell-pushd-popd
alias dirs="dirs -v" # view the directories on the stack along with their index number

#   ---------------------------
#   SEARCHING
#   ---------------------------

alias qfind="find . -name "                 # qfind:    Quickly search for file
ff () { find . -name "$@" ; }               # ff:       Find file under the current directory
ffs () { find . -name "$@"'*' ; }           # ffs:      Find file whose name starts with a given string
ffe () { find . -name '*'"$@" ; }           # ffe:      Find file whose name ends with a given string
