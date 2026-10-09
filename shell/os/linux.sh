# Linux only. Loaded by shell/common.sh after the shared files, so it can replace them.
# Mostly Linux versions of macOS commands the shared aliases rely on.

# Clipboard, like macOS (used by copypath and copy-ssh-key). Needs wl-clipboard (Wayland),
# or xclip or xsel (X11).
pbcopy () {
	if command -v wl-copy >/dev/null 2>&1; then wl-copy
	elif command -v xclip >/dev/null 2>&1; then xclip -selection clipboard
	else xsel --clipboard --input
	fi
}
pbpaste () {
	if command -v wl-paste >/dev/null 2>&1; then wl-paste
	elif command -v xclip >/dev/null 2>&1; then xclip -selection clipboard -o
	else xsel --clipboard --output
	fi
}

alias open='xdg-open'                       # open:         Open a file or folder with its default app

lips () {
	# determine local IP address (ifconfig isn't installed by default on recent Ubuntu)
	hostname -I | tr ' ' '\n' | sed '/^$/d'
}
