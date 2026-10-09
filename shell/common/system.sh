# Processes and networking. Loaded by shell/common.sh (bash and zsh).
# os/mac.sh and os/windows.sh replace some of these with OS-specific versions.

#   ---------------------------
#   PROCESS MANAGEMENT
#   ---------------------------

#   findPid: find out the pid of a specified process
#   -----------------------------------------------------
#       Note that the command name can be specified via a regex
#       E.g. findPid '/d$/' finds pids of all processes with names ending in 'd'
#       Without the 'sudo' it will only find processes of the current user
#   -----------------------------------------------------
findPid () { lsof -t -c "$@" ; }

#   killPid: kill the pid of a specified process
#   -----------------------------------------------------
killPid () { kill -9 "$@" ; }

#   killport: kill whatever is listening on a port, e.g. killport 3000
#   -----------------------------------------------------
killport () {
	local pids
	pids="$(lsof -ti :"$1")"
	if [ -z "$pids" ]; then
		echo "Nothing is listening on port $1"
		return 1
	fi
	echo "$pids" | xargs kill -9
}

alias lsof-local="lsof -Pi | grep LISTEN | grep \*:"

#   ---------------------------
#   NETWORKING
#   ---------------------------

alias myip='curl ifconfig.me'                       # myip:         Public/External facing IP Address
alias externalIP='curl ifconfig.me'                 # externalIP:   Public/External facing IP Address
exip () {
	# gather external ip address
	echo -n "Current External IP: "
	curl ifconfig.me
}
lips () {
	# determine local IP address
	ifconfig | grep "inet " | awk '{ print $2 }'
}
ips () {
	# show external and local IP addresses
	exip
	echo
	echo "Local IP addresses:"
	lips
}
alias netCons='lsof -i'                             # netCons:      Show all open TCP/IP sockets
alias lsock='sudo lsof -i -P'                       # lsock:        Display open sockets
alias lsockU='sudo lsof -nP | grep UDP'             # lsockU:       Display only open UDP sockets
alias lsockT='sudo lsof -nP | grep TCP'             # lsockT:       Display only open TCP sockets
alias openPorts='sudo lsof -i | grep LISTEN'        # openPorts:    All listening connections
