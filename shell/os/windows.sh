# Windows (Git Bash) only. Loaded by shell/common.sh after the shared files, so it can replace them.
# Mostly Windows versions of macOS commands the shared aliases rely on.

# Clipboard, like macOS (used by copypath and copy-ssh-key)
pbcopy () { clip.exe; }
pbpaste () { powershell.exe -NoProfile -Command Get-Clipboard; }

alias open='start'                          # open:         Open a file or folder with its default app
alias f='explorer.exe .'                    # f:            Opens current directory in File Explorer

lips () {
	# determine local IP address
	ipconfig | tr -d '\r' | awk -F': ' '/IPv4/ { print $2 }'
}

killport () {
	local pids pid
	pids="$(netstat -ano | tr -d '\r' | awk -v port=":$1" '$1 == "TCP" && $4 == "LISTENING" && $2 ~ port"$" { print $5 }' | sort -u)"
	if [ -z "$pids" ]; then
		echo "Nothing is listening on port $1"
		return 1
	fi
	for pid in $pids; do
		taskkill //PID "$pid" //F
	done
}

# findPid <name>: process IDs of programs whose name contains <name>
findPid () { tasklist //FO CSV //NH | tr -d '\r' | grep -i "$1" | cut -d, -f2 | tr -d '"'; }

# Network connections and listening ports, with netstat (Git Bash has no lsof or sudo)
alias netCons='netstat -ano'                        # netCons:      Show all open TCP/IP sockets
alias lsock='netstat -ano'                          # lsock:        Display open sockets
alias lsockU='netstat -ano -p UDP'                  # lsockU:       Display only open UDP sockets
alias lsockT='netstat -ano -p TCP'                  # lsockT:       Display only open TCP sockets
alias openPorts='netstat -ano | grep LISTENING'     # openPorts:    All listening connections
alias lsof-local='netstat -ano | grep LISTENING'

# Edit the hosts file in Notepad, as administrator (Windows will ask)
alias editHosts='powershell.exe -NoProfile -Command '\''Start-Process notepad -Verb RunAs -ArgumentList "$env:SystemRoot\System32\drivers\etc\hosts"'\'''
alias edit-hosts-file='editHosts'

# Git Bash has no man pages - search a command's --help instead (mans <command> <term>)
mans () { "$1" --help 2>&1 | grep -iC2 --color=always "$2" | less; }

# Git Bash has no zip command (zipf <folder>)
zipf () { powershell.exe -NoProfile -Command Compress-Archive -Path "$1" -DestinationPath "$1.zip"; }
