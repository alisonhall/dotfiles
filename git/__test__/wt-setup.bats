#!/usr/bin/env bats
# Tests for git/wt/wt-setup.sh: answers its questions through stdin, against a local "GitHub" repo.

setup() {
	SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/wt/wt-setup.sh"
	export HOME="$BATS_TEST_TMPDIR/home"
	export GIT_CONFIG_NOSYSTEM=1
	export SHELL=/bin/bash
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

# The answers for a fresh clone with every default: repo, its owner/name, folder, "clone it",
# command name, start branch, shared files, startup file, go ahead
fresh_clone() {
	setup_with "$REMOTE" acme/shop "" 1 "" "" "" "" y
}

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
	setup_with acme/shop "" "" "" ".env" "" y
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

@test "moves a clone that's in the chosen folder down into main, and its worktrees keep working" {
	git clone -q "$REMOTE" "$HOME/code/shop"
	git -C "$HOME/code/shop" worktree add -q -b feature/old "$HOME/code/shop-old"
	# repo, owner/name, folder, "move it there?", command name, start branch, shared, startup file, go ahead
	setup_with "$REMOTE" acme/shop "" y "" "" "" "" y
	[ "$status" -eq 0 ]
	[ -d "$HOME/code/shop/main/.git" ]
	[ "$(git -C "$HOME/code/shop-old" branch --show-current)" = feature/old ]
}

@test "moves a clone from another folder into main" {
	git clone -q "$REMOTE" "$HOME/old/shop"
	# repo, owner/name, folder, "move a clone I have", where it is, command name, start branch, shared, startup file, go ahead
	setup_with "$REMOTE" acme/shop "" 2 "$HOME/old/shop" "" "" "" "" y
	[ "$status" -eq 0 ]
	[ -d "$HOME/code/shop/main/.git" ]
	[ ! -e "$HOME/old/shop" ]
}

@test "on Windows, stops before moving a clone that the terminal is inside" {
	case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) ;; *) skip "only Windows can't move a folder in use" ;; esac
	git clone -q "$REMOTE" "$HOME/code/shop"
	cd "$HOME/code/shop"
	setup_with "$REMOTE" acme/shop "" y
	[ "$status" -ne 0 ]
	[[ "$output" == *"Windows can't move a folder that's in use"* ]] || false
	[ ! -e "$HOME/code/shop/main" ]
}

@test "refuses a folder that already has other files in it" {
	mkdir -p "$HOME/code/shop"
	touch "$HOME/code/shop/notes.txt"
	setup_with "$REMOTE" acme/shop ""
	[ "$status" -ne 0 ]
	[[ "$output" == *"already has files in it"* ]] || false
	[ ! -e "$HOME/.bashrc" ]
}

@test "asks again for a command name that's already a command" {
	setup_with "$REMOTE" acme/shop "" 1 ls shop-wt "" "" "" y
	[ "$status" -eq 0 ]
	[[ "$output" == *"ls is already a command"* ]] || false
	grep -qxF 'shop-wt() {' "$HOME/.bashrc"
}

@test "doesn't add a line to load wt when the startup file already loads it" {
	echo '. "$HOME/somewhere/wt/wt.sh"' > "$HOME/.bashrc"
	fresh_clone
	[ "$status" -eq 0 ]
	[ "$(grep -cxF '# >>> wt: load >>>' "$HOME/.bashrc")" -eq 0 ]
	grep -qxF 'shop-wt() {' "$HOME/.bashrc"
}

@test "in these dotfiles, adds the command to ~/.shell_local, which loads after wt" {
	export DOTFILES="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
	fresh_clone
	[ "$status" -eq 0 ]
	grep -qxF 'shop-wt() {' "$HOME/.shell_local"
	[ "$(grep -cF 'wt: load' "$HOME/.shell_local")" -eq 0 ]
	[ ! -e "$HOME/.bashrc" ]
}
