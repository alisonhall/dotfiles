#!/usr/bin/env bats
# Tests for git/wt/wt-setup.sh: answers its questions through stdin, against a local "GitHub" repo.

setup() {
	SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/wt/wt-setup.sh"
	export HOME="$BATS_TEST_TMPDIR/home"
	export GIT_CONFIG_NOSYSTEM=1
	export SHELL=/bin/bash
	# The OS the script acts as if it's on (some steps only happen on macOS or Windows)
	export WT_SETUP_OS=Linux
	unset GIT_CONFIG_GLOBAL DOTFILES
	mkdir -p "$HOME"
	git config --global user.name Test
	git config --global user.email test@example.com
	git config --global init.defaultBranch main

	# A gh that isn't logged in, so nothing talks to GitHub
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/gh"
	chmod +x "$BATS_TEST_TMPDIR/bin/gh"
	export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

	# The "GitHub" repo, whose default branch is develop
	REMOTE="$BATS_TEST_TMPDIR/shop.git"
	git init -q --bare "$REMOTE"
	git clone -q "$REMOTE" "$BATS_TEST_TMPDIR/seed" 2>/dev/null
	git -C "$BATS_TEST_TMPDIR/seed" commit -q --allow-empty -m init
	git -C "$BATS_TEST_TMPDIR/seed" branch -M develop
	git -C "$BATS_TEST_TMPDIR/seed" push -q origin develop
	git -C "$REMOTE" symbolic-ref HEAD refs/heads/develop

	cd "$BATS_TEST_TMPDIR" || return 1
}

# setup_with <answer>...: Run wt-setup.sh, answering its questions in order (an empty answer
# takes the default)
setup_with() {
	printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/answers"
	run bash "$SCRIPT" "${options[@]}" < "$BATS_TEST_TMPDIR/answers"
}
options=()

# The answers for a fresh clone with every default, in the order they're asked: repo, its
# owner/name, folder, "clone it", startup file, command name, start branch, shared files, go ahead
fresh_clone() {
	setup_with "$REMOTE" acme/shop "" 1 "" "" "" "" y
}

# loads_cleanly <file>: The file loads in bash (with aliases on, as in an interactive shell)
loads_cleanly() {
	run bash --norc --noprofile -c 'shopt -s expand_aliases; . "$1"' _ "$1"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

#   -------------------------------
#   SETTING UP
#   -------------------------------

@test "clones the repo into <folder>/main and adds a command to ~/.bashrc" {
	fresh_clone
	[ "$status" -eq 0 ]
	[ -d "$HOME/code/shop/main/.git" ]
	[ "$(git -C "$HOME/code/shop/main" branch --show-current)" = develop ]
	grep -qF "/wt/wt.sh\"" "$HOME/.bashrc"
	grep -qxF 'shop-wt() {' "$HOME/.bashrc"
	grep -qF 'WT_WORKTREE_REPO_LOCATION="$HOME/code/shop" \' "$HOME/.bashrc"
	grep -qF 'WT_REPO_SLUG="acme/shop" \' "$HOME/.bashrc"
	grep -qF 'CURRENT_DEV_BRANCH="develop" \' "$HOME/.bashrc"
	# (wt clean protects CURRENT_DEV_BRANCH itself, so it isn't repeated in WT_PROTECTED_BRANCHES)
	[ "$(grep -c WT_PROTECTED_BRANCHES "$HOME/.bashrc")" -eq 0 ]
	loads_cleanly "$HOME/.bashrc"
	# On Linux, terminals read ~/.bashrc themselves
	[ ! -e "$HOME/.bash_profile" ]
}

@test "the command it adds runs wt with the repo's settings" {
	fresh_clone
	run bash -c '. "$HOME/.bashrc" && shop-wt add feature/x >/dev/null 2>&1 && pwd && git branch --show-current'
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == */code/shop/feature_x ]] || false
	[ "${lines[1]}" = feature/x ]
}

@test "running it again replaces the repo's command rather than adding another, after a backup" {
	fresh_clone
	# repo, owner/name, folder (already set up), startup file, command name, start branch, shared, go ahead
	setup_with "$REMOTE" acme/shop "" "" "" "" ".env" y
	[ "$status" -eq 0 ]
	[[ "$output" == *"already a clone, so wt will use it as it is"* ]] || false
	[ "$(grep -cxF '# >>> wt: shop-wt >>>' "$HOME/.bashrc")" -eq 1 ]
	[ "$(grep -cxF '# >>> wt: load >>>' "$HOME/.bashrc")" -eq 1 ]
	grep -qF 'WT_SYMLINK_PAIRS=".env" \' "$HOME/.bashrc"
	ls "$HOME"/.bashrc.wt-setup-*.bak
}

@test "--dry-run shows the plan but changes nothing" {
	options=(--dry-run)
	setup_with "$REMOTE" acme/shop "" 1 "" "" "" ""
	[ "$status" -eq 0 ]
	[[ "$output" == *"Add this to ~/.bashrc:"* ]] || false
	[[ "$output" == *"Dry run, so nothing was changed."* ]] || false
	[ ! -e "$HOME/code" ]
	[ ! -e "$HOME/.bashrc" ]
}

@test "answering no at the end changes nothing" {
	setup_with "$REMOTE" acme/shop "" 1 "" "" "" "" n
	[ "$status" -eq 0 ]
	[[ "$output" == *"Nothing was changed."* ]] || false
	[ ! -e "$HOME/code" ]
	[ ! -e "$HOME/.bashrc" ]
}

@test "in these dotfiles, adds the command to ~/.shell_local, which loads after wt" {
	export DOTFILES="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
	fresh_clone
	[ "$status" -eq 0 ]
	grep -qxF 'shop-wt() {' "$HOME/.shell_local"
	[ "$(grep -cF 'wt: load' "$HOME/.shell_local")" -eq 0 ]
	[ ! -e "$HOME/.bashrc" ]
}

#   -------------------------------
#   THE REPO AND ITS FOLDER
#   -------------------------------

@test "asks again when the repo can't be reached" {
	# repo (a typo), "use it anyway?", repo, owner/name, folder, "clone it", startup, command, branch, shared, go ahead
	setup_with "$BATS_TEST_TMPDIR/shpo.git" n "$REMOTE" acme/shop "" 1 "" "" "" "" y
	[ "$status" -eq 0 ]
	[[ "$output" == *"Couldn't reach $BATS_TEST_TMPDIR/shpo.git"* ]] || false
	[ -d "$HOME/code/shop/main/.git" ]
}

@test "recognizes a GitHub SSH host alias, like git@github-work:owner/name.git" {
	git clone -q "$REMOTE" "$BATS_TEST_TMPDIR/work-clone"
	git -C "$BATS_TEST_TMPDIR/work-clone" remote set-url origin git@github-work:acme/shop.git
	cd "$BATS_TEST_TMPDIR/work-clone"
	# No answers: it stops at the first question, which offers this clone's repo
	setup_with
	[[ "$output" == *"or a URL to clone [acme/shop]:"* ]] || false
}

@test "accepts a folder written with Windows backslashes" {
	setup_with "$REMOTE" acme/shop "${HOME//\//\\}\\code\\shop" 1 "" "" "" "" y
	[ "$status" -eq 0 ]
	[ -d "$HOME/code/shop/main/.git" ]
	grep -qF 'WT_WORKTREE_REPO_LOCATION="$HOME/code/shop" \' "$HOME/.bashrc"
}

@test "moves a clone that's in the chosen folder down into main, and its worktrees keep working" {
	git clone -q "$REMOTE" "$HOME/code/shop"
	git -C "$HOME/code/shop" worktree add -q -b feature/old "$HOME/code/shop-old"
	# repo, owner/name, folder, "move it there?", startup file, command name, start branch, shared, go ahead
	setup_with "$REMOTE" acme/shop "" y "" "" "" "" y
	[ "$status" -eq 0 ]
	[ -d "$HOME/code/shop/main/.git" ]
	[ "$(git -C "$HOME/code/shop-old" branch --show-current)" = feature/old ]
	[[ "$output" != *"Couldn't reconnect"* ]] || false
}

@test "moves a clone from another folder into main" {
	git clone -q "$REMOTE" "$HOME/old/shop"
	# repo, owner/name, folder, "move a clone I have", where it is, startup, command, branch, shared, go ahead
	setup_with "$REMOTE" acme/shop "" 2 "$HOME/old/shop" "" "" "" "" y
	[ "$status" -eq 0 ]
	[ -d "$HOME/code/shop/main/.git" ]
	[ ! -e "$HOME/old/shop" ]
}

@test "says so when it can't reconnect worktrees after moving a clone" {
	git clone -q "$REMOTE" "$HOME/code/shop"
	# A git whose worktree repair fails
	real_git="$(command -v git)"
	printf '#!/bin/sh\ncase "$*" in *"worktree repair"*) echo "error: could not repair" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' "$real_git" > "$BATS_TEST_TMPDIR/bin/git"
	chmod +x "$BATS_TEST_TMPDIR/bin/git"
	setup_with "$REMOTE" acme/shop "" y "" "" "" "" y
	[ "$status" -eq 0 ]
	[[ "$output" == *"Couldn't reconnect some worktrees"* ]] || false
	[[ "$output" == *"error: could not repair"* ]] || false
}

@test "on Windows, stops before moving a clone that the terminal is inside" {
	export WT_SETUP_OS=MINGW64_NT-10.0
	git clone -q "$REMOTE" "$HOME/code/shop"
	cd "$HOME/code/shop"
	setup_with "$REMOTE" acme/shop "" y
	[ "$status" -ne 0 ]
	[[ "$output" == *"Windows can't move a folder that's in use"* ]] || false
	[ ! -e "$HOME/code/shop/main" ]
}

# macOS's temp folder ends in /, so its paths can have a // that cd tidies away
@test "on Windows, stops before moving a clone that the terminal is inside, however its path is spelled" {
	export WT_SETUP_OS=MINGW64_NT-10.0
	export HOME="$BATS_TEST_TMPDIR//home"
	git clone -q "$REMOTE" "$HOME/code/shop"
	cd "$HOME/code/shop"
	setup_with "$REMOTE" acme/shop "" y
	[ "$status" -ne 0 ]
	[[ "$output" == *"Windows can't move a folder that's in use"* ]] || false
	[ ! -e "$HOME/code/shop/main" ]
}

@test "after moving a clone that the terminal is inside, says to cd into main" {
	export HOME="$BATS_TEST_TMPDIR//home"
	git clone -q "$REMOTE" "$HOME/code/shop"
	cd "$HOME/code/shop"
	setup_with "$REMOTE" acme/shop "" y "" "" "" "" y
	[ "$status" -eq 0 ]
	[ -d "$HOME/code/shop/main/.git" ]
	[[ "$output" == *"This terminal is still in the clone's old folder"* ]] || false
}

@test "refuses a folder that already has other files in it" {
	mkdir -p "$HOME/code/shop"
	touch "$HOME/code/shop/notes.txt"
	setup_with "$REMOTE" acme/shop ""
	[ "$status" -ne 0 ]
	[[ "$output" == *"already has files in it"* ]] || false
	[ ! -e "$HOME/.bashrc" ]
}

#   -------------------------------
#   SETTINGS
#   -------------------------------

@test "asks again for a command name that's already a command" {
	setup_with "$REMOTE" acme/shop "" 1 "" ls shop-wt "" "" y
	[ "$status" -eq 0 ]
	[[ "$output" == *"ls is already a command"* ]] || false
	grep -qxF 'shop-wt() {' "$HOME/.bashrc"
}

@test "asks again for a command name that the startup file already has an alias for" {
	echo "alias shop-wt='WT_WORKTREE_REPO_LOCATION=\"\$HOME/code/shop\" wt'" > "$HOME/.bashrc"
	# ...startup file, command name (the default, shop-wt), command name, branch, shared, go ahead
	setup_with "$REMOTE" acme/shop "" 1 "" "" other-wt "" "" y
	[ "$status" -eq 0 ]
	[[ "$output" == *"~/.bashrc already defines shop-wt, on line 1: alias shop-wt="* ]] || false
	grep -qxF 'other-wt() {' "$HOME/.bashrc"
	loads_cleanly "$HOME/.bashrc"
}

@test "asks again for a command name that the startup file already has a function for" {
	printf '%s\n' '# My wt command' 'function shop-wt {' '	wt "$@"' '}' > "$HOME/.bashrc"
	options=(--dry-run)
	setup_with "$REMOTE" acme/shop "" 1 "" "" other-wt "" ""
	[ "$status" -eq 0 ]
	[[ "$output" == *"already defines shop-wt, on line 2: function shop-wt {"* ]] || false
}

@test "asks again for a start branch the repo doesn't have" {
	# ...command name, start branch (a typo), "use it anyway?", start branch (the default), shared, go ahead
	setup_with "$REMOTE" acme/shop "" 1 "" "" devlop n "" "" y
	[ "$status" -eq 0 ]
	[[ "$output" == *"The repo has no branch called devlop"* ]] || false
	grep -qF 'CURRENT_DEV_BRANCH="develop" \' "$HOME/.bashrc"
}

#   -------------------------------
#   LOADING WT
#   -------------------------------

@test "doesn't add a line to load wt when the startup file already loads it" {
	mkdir -p "$HOME/somewhere/wt"
	touch "$HOME/somewhere/wt/wt.sh"
	echo '. "$HOME/somewhere/wt/wt.sh"' > "$HOME/.bashrc"
	fresh_clone
	[ "$status" -eq 0 ]
	[ "$(grep -cxF '# >>> wt: load >>>' "$HOME/.bashrc")" -eq 0 ]
	grep -qxF 'shop-wt() {' "$HOME/.bashrc"
}

@test "adds a line to load wt when the startup file's only one is commented out, or its wt.sh is gone" {
	mkdir -p "$HOME/somewhere/wt"
	touch "$HOME/somewhere/wt/wt.sh"
	printf '%s\n' '# . "$HOME/somewhere/wt/wt.sh"' 'source ~/deleted/wt/wt.sh' > "$HOME/.bashrc"
	fresh_clone
	[ "$status" -eq 0 ]
	[ "$(grep -cxF '# >>> wt: load >>>' "$HOME/.bashrc")" -eq 1 ]
}

@test "on macOS, makes ~/.bash_profile load ~/.bashrc, since Terminal opens login shells" {
	export WT_SETUP_OS=Darwin
	fresh_clone
	[ "$status" -eq 0 ]
	grep -qxF '[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"' "$HOME/.bash_profile"
	run bash --login -c 'type -t shop-wt'
	[ "${lines[${#lines[@]} - 1]}" = function ]
}

@test "on macOS, leaves ~/.bash_profile alone when it already loads ~/.bashrc" {
	export WT_SETUP_OS=Darwin
	echo 'source ~/.bashrc' > "$HOME/.bash_profile"
	fresh_clone
	[ "$status" -eq 0 ]
	[ "$(cat "$HOME/.bash_profile")" = 'source ~/.bashrc' ]
}

@test "on Windows, offers to let git use long paths, and turns them on" {
	export WT_SETUP_OS=MINGW64_NT-10.0
	# ...fresh-clone answers, then "let git use longer paths?", go ahead
	setup_with "$REMOTE" acme/shop "" 1 "" "" "" "" y y
	[ "$status" -eq 0 ]
	[[ "$output" == *"Let git use long paths: git config --global core.longpaths true"* ]] || false
	[ "$(git config --global --get core.longpaths)" = true ]
}

@test "on Windows, doesn't ask about long paths when git already allows them" {
	export WT_SETUP_OS=MINGW64_NT-10.0
	git config --global core.longpaths true
	fresh_clone
	[ "$status" -eq 0 ]
	[[ "$output" != *"Let git use longer paths"* ]] || false
}

@test "doesn't ask about long paths on other systems" {
	fresh_clone
	[ "$status" -eq 0 ]
	[[ "$output" != *"Let git use longer paths"* ]] || false
	[ -z "$(git config --global --get core.longpaths)" ]
}

@test "on Windows, doesn't ask about long paths when git's system config allows them" {
	export WT_SETUP_OS=MINGW64_NT-10.0
	unset GIT_CONFIG_NOSYSTEM
	export GIT_CONFIG_SYSTEM="$BATS_TEST_TMPDIR/system-gitconfig"
	git config --system core.longpaths true
	fresh_clone
	[ "$status" -eq 0 ]
	[[ "$output" != *"Let git use longer paths"* ]] || false
}
