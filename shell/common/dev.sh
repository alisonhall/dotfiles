# SSH keys, Docker, Node and web development. Loaded by shell/common.sh (bash and zsh).

#   ---------------------------------------
#   SSH
#   ---------------------------------------

alias goto-ssh='cd ~/.ssh/'
alias openssh='cd ~/.ssh/'
alias list-ssh-keys='ls -FlAhp ~/.ssh'

# create-ssh-key [email]: Create a new SSH key, labelled with the email (default: $EMAIL)
create-ssh-key () { ssh-keygen -t ed25519 -C "${1:-$EMAIL}"; }

# Prompts for one of the public keys in ~/.ssh and prints its path
_choose_ssh_public_key () {
	local files=(~/.ssh/*.pub) file
	PS3="Enter the number of the key: "
	select file in "${files[@]}"; do
		if [ -n "$file" ]; then
			echo "$file"
			return
		fi
		echo "Please enter a valid number. Retry." >&2
	done
}

# show-ssh-key / copy-ssh-key: Print or copy a public key (e.g. to add it to GitHub)
show-ssh-key () {
	local file
	file="$(_choose_ssh_public_key)" && cat "$file"
}
copy-ssh-key () {
	local file
	file="$(_choose_ssh_public_key)" && pbcopy < "$file" && echo "Copied $file"
}

# Type Enter then ~. to close a frozen SSH session

#   ---------------------------------------
#   DOCKER
#   ---------------------------------------

alias show-docker-images='docker images'
alias show-running-docker-containers='docker ps'
alias show-existing-docker-containers='docker ps -a'
# see-docker-container-console <container> [shell]: Open a shell (default: sh) in a running container
see-docker-container-console () { docker exec -it "$1" "${2:-sh}"; }
remove-docker-container () { docker rm "$@"; }
stop-docker-container () { docker stop "$@"; }
restart-docker-container () { docker restart "$@"; }
remove-docker-image () { docker rmi "$@"; }

#   ---------------------------------------
#   NODE / NPM
#   ---------------------------------------

alias npm-version='npm -v'
alias upgrade-npm='npm install -g npm@latest'
alias global-npm-packages='npm list -g --depth 1'
alias global-npm-packages-all='npm list -g'
alias node-version='node -v'
alias nvm-current-version='nvm current'

#   ---------------------------------------
#   WEB DEVELOPMENT
#   ---------------------------------------

alias editHosts='sudo nano /etc/hosts'                  # editHosts:        Edit /etc/hosts file
alias edit-hosts-file='sudo nano /etc/hosts'
httpHeaders () { curl -I -L "$@" ; }                    # httpHeaders:      Grabs headers from web page

#   httpDebug:  Download a web page and show info on what took time
#   -------------------------------------------------------------------
httpDebug () { curl "$@" -o /dev/null -w "dns: %{time_namelookup} connect: %{time_connect} pretransfer: %{time_pretransfer} starttransfer: %{time_starttransfer} total: %{time_total}\n" ; }
