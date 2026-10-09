# macOS only. Loaded by shell/common.sh after the shared files, so it can replace them.

#   -------------------------------
#   PATH
#   -------------------------------

path_add /usr/local/bin
path_add /usr/local/sbin
path_add /opt/homebrew/bin
path_add /usr/local/share/npm/bin
path_add "/Applications/Visual Studio Code.app/Contents/Resources/app/bin"  # VS Code (code)
path_add "/Library/Application Support/GoodSync"
path_add "$HOME/phantomjs-2.1.1-macosx/bin"

alias java-jdk-versions-installed='/usr/libexec/java_home -V'
alias java-jdk-current='echo $JAVA_HOME'

#   -----------------------------
#   TERMINAL AND FINDER
#   -----------------------------

alias ll='ls -FGlAhp'                       # ll:           Preferred 'ls' implementation
alias f='open -a Finder ./'                 # f:            Opens current directory in MacOS Finder
trash () { command mv "$@" ~/.Trash ; }     # trash:        Moves a file to the MacOS trash
ql () { qlmanage -p "$*" >& /dev/null; }    # ql:           Opens any file in MacOS Quicklook Preview

#   Show/Hide hidden files
alias showFiles='defaults write com.apple.finder AppleShowAllFiles YES; killall Finder /System/Library/CoreServices/Finder.app'
alias hideFiles='defaults write com.apple.finder AppleShowAllFiles NO; killall Finder /System/Library/CoreServices/Finder.app'
alias finderShowHidden='defaults write com.apple.finder ShowAllFiles TRUE'
alias finderHideHidden='defaults write com.apple.finder ShowAllFiles FALSE'

#   cdf:  'Cd's to frontmost window of MacOS Finder
#   ------------------------------------------------------
cdf () {
	currFolderPath=$( /usr/bin/osascript <<EOT
		tell application "Finder"
			try
		set currFolder to (folder of the front window as alias)
			on error
		set currFolder to (path to desktop folder as alias)
			end try
			POSIX path of currFolder
		end tell
EOT
	)
	echo "cd to \"$currFolderPath\""
	cd "$currFolderPath"
}

#   spotlight: Search for a file using MacOS Spotlight's metadata
#   -----------------------------------------------------------
spotlight () { mdfind "kMDItemDisplayName == '$*'wc"; }

alias make1mb='mkfile 1m ./1MB.dat'         # make1mb:      Creates a file of 1mb size (all zeros)
alias make5mb='mkfile 5m ./5MB.dat'         # make5mb:      Creates a file of 5mb size (all zeros)
alias make10mb='mkfile 10m ./10MB.dat'      # make10mb:     Creates a file of 10mb size (all zeros)

#   ---------------------------
#   PROCESSES
#   ---------------------------

alias memHogsTop='top -l 1 -o rsize | head -20'
alias memHogsPs='ps wwaxm -o pid,stat,vsize,rss,time,command | head -10'
alias cpu_hogs='ps wwaxr -o pid,stat,%cpu,time,command | head -10'
alias topForever='top -l 9999999 -s 10 -o cpu'
alias ttop="top -R -F -s 10 -o rsize"       # ttop:         Recommended 'top' invocation to minimize resources
my_ps () { ps "$@" -u "$USER" -o pid,%cpu,%mem,start,time,bsdtime,command ; }    # my_ps:    List processes owned by my user

#   ---------------------------
#   NETWORKING
#   ---------------------------

alias flushDNS='dscacheutil -flushcache'            # flushDNS:     Flush out the DNS Cache
alias ipInfo0='ipconfig getpacket en0'              # ipInfo0:      Get info on connections for en0
alias ipInfo1='ipconfig getpacket en1'              # ipInfo1:      Get info on connections for en1
alias showBlocked='sudo ipfw list'                  # showBlocked:  All ipfw rules inc/ blocked IPs

#   ii:  display useful host related informaton
#   -------------------------------------------------------------------
ii () {
	echo -e "\nYou are logged on ${RED}$HOST"
	echo -e "\nAdditionnal information:$NC " ; uname -a
	echo -e "\n${RED}Users logged on:$NC " ; w -h
	echo -e "\n${RED}Current date :$NC " ; date
	echo -e "\n${RED}Machine stats :$NC " ; uptime
	echo -e "\n${RED}Current network location :$NC " ; scselect
	echo -e "\n${RED}Public facing IP Address :$NC " ;myip
	echo
}

#   ---------------------------------------
#   SYSTEM
#   ---------------------------------------

alias mountReadWrite='/sbin/mount -uw /'    # mountReadWrite:   For use when booted into single-user

#   cleanupLS:  Clean up LaunchServices to remove duplicates in the "Open With" menu
alias cleanupLS="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user && killall Finder"

#   screensaverDesktop: Run a screensaver on the Desktop
alias screensaverDesktop='/System/Library/Frameworks/ScreenSaver.framework/Resources/ScreenSaverEngine.app/Contents/MacOS/ScreenSaverEngine -background'

#   ---------------------------------------
#   WEB DEVELOPMENT (built-in Apache)
#   ---------------------------------------

alias apacheEdit='sudo edit /etc/httpd/httpd.conf'      # apacheEdit:       Edit httpd.conf
alias apacheRestart='sudo apachectl graceful'           # apacheRestart:    Restart Apache
alias herr='tail /var/log/httpd/error_log'              # herr:             Tails HTTP error logs
alias apacheLogs="less +F /var/log/apache2/error_log"   # Apachelogs:   Shows apache error logs

#   ---------------------------------------
#   REMINDERS & NOTES
#   ---------------------------------------

#   remove_disk: spin down unneeded disk
#   diskutil eject /dev/disk1s3

#   to change the password on an encrypted disk image:
#   hdiutil chpass /path/to/the/diskimage

#   to mount a read-only disk image as read-write:
#   hdiutil attach example.dmg -shadow /tmp/example.shadow -noverify

#   mounting a removable drive (of type msdos or hfs)
#   mkdir /Volumes/Foo
#   ls /dev/disk*   to find out the device to use in the mount command)
#   mount -t msdos /dev/disk1s1 /Volumes/Foo
#   mount -t hfs /dev/disk1s1 /Volumes/Foo

#   to create a file of a given size: /usr/sbin/mkfile or /usr/bin/hdiutil
#   e.g.: mkfile 10m 10MB.dat
#   e.g.: hdiutil create -size 10m 10MB.dmg
