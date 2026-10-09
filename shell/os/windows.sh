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
