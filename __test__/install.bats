#!/usr/bin/env bats
# Unit tests for install.sh: the shell blocks it manages and the order of ~/.gitconfig.
# Each test gets an empty fake home folder (with a space in its path), so nothing real is touched.
# Run with: tools/run-tests.sh (or: bats __test__)

bats_require_minimum_version 1.5.0

setup() {
	REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	export HOME="$BATS_TEST_TMPDIR/home dir"
	export XDG_CONFIG_HOME="$HOME/.config"
	export GIT_CONFIG_NOSYSTEM=1
	unset GIT_CONFIG_GLOBAL
	mkdir -p "$HOME"
	START="# >>> dotfiles >>>"
	END="# <<< dotfiles <<<"
	SHARED_INCLUDE="$(native "$REPO/git/gitconfig")"
	# $DOTFILES in call() is always this real repo (install.sh derives it from its own path), so
	# LOCAL_DIR must be sandboxed explicitly - otherwise a test touches this checkout's own local/
	LOCAL_DIR="$BATS_TEST_TMPDIR/local"
	export DOTFILES_LOCAL_DIR="$LOCAL_DIR"
}

# native <path>: The path as install.sh writes it to git config (C:/... form on Windows)
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }

# call <function> [args...]: Run one of install.sh's functions with the script's own shell options.
# Set MODE_FLAG=--check to load it in check mode.
call() {
	# The script is passed as $1, not $0: install.sh only runs main when $0 is itself
	run bash -c '
		script="$1"; shift; args=("$@")
		set -- ${MODE_FLAG:-}
		source "$script"
		"${args[@]}"
	' bats-call "$REPO/install.sh" "$@"
}

# call_answering <answer> <function> [args...]: Like call, but feeds <answer> as stdin (for
# ask_yes_no prompts) instead of leaving stdin closed, which is what makes call's own invocations
# take ask_yes_no's default instead of actually prompting
call_answering() {
	local answer="$1"
	shift
	run bash -c '
		script="$1"; shift; args=("$@")
		set -- ${MODE_FLAG:-}
		source "$script"
		"${args[@]}"
	' bats-call "$REPO/install.sh" "$@" <<< "$answer"
}

checksum() { cksum < "$1"; }

#   -------------------------------
#   markers_paired
#   -------------------------------

@test "markers_paired: accepts a complete block, two complete blocks, and no block" {
	printf 'a\n%s\nx\n%s\nb\n' "$START" "$END" > "$HOME/f"
	call markers_paired "$HOME/f"
	[ "$status" -eq 0 ]

	printf '%s\n%s\n%s\n%s\n' "$START" "$END" "$START" "$END" > "$HOME/f"
	call markers_paired "$HOME/f"
	[ "$status" -eq 0 ]

	printf 'a\nb\n' > "$HOME/f"
	call markers_paired "$HOME/f"
	[ "$status" -eq 0 ]
}

@test "markers_paired: rejects a missing end, a stray end, an end before the start, and nesting" {
	printf '%s\nx\n' "$START" > "$HOME/f"
	call markers_paired "$HOME/f"
	[ "$status" -ne 0 ]

	printf 'x\n%s\n' "$END" > "$HOME/f"
	call markers_paired "$HOME/f"
	[ "$status" -ne 0 ]

	printf '%s\n%s\nx\n%s\n' "$END" "$START" "$END" > "$HOME/f"
	call markers_paired "$HOME/f"
	[ "$status" -ne 0 ]

	printf '%s\n%s\n%s\n%s\n' "$START" "$START" "$END" "$END" > "$HOME/f"
	call markers_paired "$HOME/f"
	[ "$status" -ne 0 ]
}

#   -------------------------------
#   ensure_block
#   -------------------------------

@test "ensure_block: creates the file if it's missing" {
	call ensure_block "$HOME/.zshrc" "BODY"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Added dotfiles block"* ]] || false
	grep -qxF "$START" "$HOME/.zshrc"
	grep -qxF "BODY" "$HOME/.zshrc"
}

@test "ensure_block: appends to an existing file and keeps its lines" {
	printf 'echo mine\n' > "$HOME/.zshrc"
	call ensure_block "$HOME/.zshrc" "BODY"
	[ "$(head -n 1 "$HOME/.zshrc")" = "echo mine" ]
	grep -qxF "BODY" "$HOME/.zshrc"
}

@test "ensure_block: a second run changes nothing" {
	call ensure_block "$HOME/.zshrc" "BODY"
	before="$(checksum "$HOME/.zshrc")"
	call ensure_block "$HOME/.zshrc" "BODY"
	[[ "$output" == *"already set up"* ]] || false
	[ "$(checksum "$HOME/.zshrc")" = "$before" ]
}

@test "ensure_block: updates an out-of-date block in place, keeps the lines around it, and backs up" {
	printf 'before\n%s\nOLD\n%s\nafter\n' "$START" "$END" > "$HOME/.zshrc"
	call ensure_block "$HOME/.zshrc" "NEW"
	[[ "$output" == *"Updated the dotfiles block"* ]] || false
	[ "$(cat "$HOME/.zshrc")" = "$(printf 'before\n%s\nNEW\n%s\nafter' "$START" "$END")" ]
	grep -qx OLD "$HOME"/.zshrc.bak.*
}

@test "ensure_block: refuses a file with two blocks and leaves it unchanged" {
	printf '%s\nA\n%s\n%s\nB\n%s\n' "$START" "$END" "$START" "$END" > "$HOME/.zshrc"
	before="$(checksum "$HOME/.zshrc")"
	call ensure_block "$HOME/.zshrc" "NEW"
	[[ "$output" == *"PROBLEM"*"more than one dotfiles block"* ]] || false
	[ "$(checksum "$HOME/.zshrc")" = "$before" ]
}

@test "ensure_block: refuses a block with no end marker, so the lines after it aren't deleted" {
	printf 'before\n%s\nOLD\nimportant\n' "$START" > "$HOME/.zshrc"
	before="$(checksum "$HOME/.zshrc")"
	call ensure_block "$HOME/.zshrc" "NEW"
	[[ "$output" == *"PROBLEM"*"without a matching"* ]] || false
	[ "$(checksum "$HOME/.zshrc")" = "$before" ]
}

@test "ensure_block: refuses an end marker that comes before the start marker" {
	printf 'x\n%s\n%s\nOLD\n' "$END" "$START" > "$HOME/.zshrc"
	before="$(checksum "$HOME/.zshrc")"
	call ensure_block "$HOME/.zshrc" "NEW"
	[[ "$output" == *"PROBLEM"* ]] || false
	[ "$(checksum "$HOME/.zshrc")" = "$before" ]
}

#   -------------------------------
#   check_startup_files
#   -------------------------------

@test "check_startup_files --check: reports two blocks and broken markers as problems" {
	printf '%s\nA\n%s\n%s\nB\n%s\n' "$START" "$END" "$START" "$END" > "$HOME/.bashrc"
	printf '%s\nA\n' "$START" > "$HOME/.zshrc"
	MODE_FLAG=--check call check_startup_files
	[[ "$output" == *"PROBLEM: $HOME/.bashrc has more than one dotfiles block"* ]] || false
	[[ "$output" == *"PROBLEM: $HOME/.zshrc has a '$START' line without a matching"* ]] || false
}

#   -------------------------------
#   setup_local_dir
#   -------------------------------

@test "setup_local_dir: creates LOCAL_DIR as its own git repo with a fresh shell_local.sh" {
	call setup_local_dir
	[ "$status" -eq 0 ]
	[ -d "$LOCAL_DIR/.git" ]
	cmp -s "$LOCAL_DIR/shell_local.sh" "$REPO/local.example.sh"
	[ -f "$LOCAL_DIR/dotfiles_blocklist" ]
	[ -f "$LOCAL_DIR/.gitignore" ]
	# Committed, not left sitting staged/untracked
	[ -z "$(git -C "$LOCAL_DIR" status --porcelain)" ]
	[ "$(git -C "$LOCAL_DIR" log --oneline | wc -l | tr -d ' ')" -eq 1 ]
}

@test "setup_local_dir: moves an existing ~/.shell_local, ~/.p10k.zsh and ~/.dotfiles_blocklist in" {
	printf 'export NAME=Me\n' > "$HOME/.shell_local"
	printf 'existing p10k config\n' > "$HOME/.p10k.zsh"
	printf 'blocked-string\n' > "$HOME/.dotfiles_blocklist"
	call setup_local_dir
	[ "$status" -eq 0 ]
	[ "$(cat "$LOCAL_DIR/shell_local.sh")" = "export NAME=Me" ]
	[ "$(cat "$LOCAL_DIR/p10k.zsh")" = "existing p10k config" ]
	[ "$(cat "$LOCAL_DIR/dotfiles_blocklist")" = "blocked-string" ]
	[ ! -e "$HOME/.shell_local" ]
	[ ! -e "$HOME/.p10k.zsh" ]
	[ ! -e "$HOME/.dotfiles_blocklist" ]
}

@test "setup_local_dir: a second run changes nothing" {
	call setup_local_dir
	before="$(git -C "$LOCAL_DIR" rev-parse HEAD)"
	call setup_local_dir
	[ "$status" -eq 0 ]
	[ -z "$(git -C "$LOCAL_DIR" status --porcelain)" ]
	[ "$(git -C "$LOCAL_DIR" rev-parse HEAD)" = "$before" ]
}

@test "setup_local_dir: doesn't overwrite an existing shell_local.sh with the template" {
	call setup_local_dir
	printf 'export NAME=Already-here\n' > "$LOCAL_DIR/shell_local.sh"
	printf 'export NAME=Me\n' > "$HOME/.shell_local"
	call setup_local_dir
	[ "$(cat "$LOCAL_DIR/shell_local.sh")" = "export NAME=Already-here" ]
	# The old ~/.shell_local is left alone - migrate_into_local only moves into an empty slot
	[ -f "$HOME/.shell_local" ]
}

@test "setup_local_dir: asks before moving ~/.p10k.zsh, and a declined answer leaves it in place" {
	printf 'existing p10k config\n' > "$HOME/.p10k.zsh"
	call_answering n setup_local_dir
	[ "$status" -eq 0 ]
	[[ "$output" == *"Leaving $HOME/.p10k.zsh where it is"* ]] || false
	[ -f "$HOME/.p10k.zsh" ]
	[ ! -e "$LOCAL_DIR/p10k.zsh" ]
}

@test "setup_local_dir: an accepted answer moves ~/.p10k.zsh" {
	printf 'existing p10k config\n' > "$HOME/.p10k.zsh"
	call_answering y setup_local_dir
	[ "$status" -eq 0 ]
	[ ! -e "$HOME/.p10k.zsh" ]
	[ "$(cat "$LOCAL_DIR/p10k.zsh")" = "existing p10k config" ]
}

#   -------------------------------
#   setup_git: the shared include
#   -------------------------------

@test "setup_git: adds the shared include at the top and keeps existing settings below it" {
	printf '[user]\n\temail = me@example.com\n' > "$HOME/.gitconfig"
	call setup_git
	[ "$status" -eq 0 ]
	[[ "$output" == *"Added include for the shared config to the top"* ]] || false
	[ "$(git config --file "$HOME/.gitconfig" --list | head -n 1)" = "include.path=$SHARED_INCLUDE" ]
	# --includes: user.email moved into $LOCAL_DIR/gitconfig, which --global alone doesn't expand
	[ "$(git config --global --includes user.email)" = "me@example.com" ]
	ls "$HOME"/.gitconfig.bak.*
}

@test "setup_git: a second run changes nothing" {
	call setup_git
	before="$(checksum "$HOME/.gitconfig")"
	call setup_git
	[[ "$output" == *"already includes the shared config"* ]] || false
	[[ "$output" != *"Backed up"* ]] || false
	[ "$(checksum "$HOME/.gitconfig")" = "$before" ]
}

@test "setup_git: moves the include back to the top if it's been moved below other settings" {
	printf '[user]\n\temail = me@example.com\n[include]\n\tpath = %s\n[core]\n\teditor = vim\n' "$SHARED_INCLUDE" > "$HOME/.gitconfig"
	call setup_git
	[[ "$output" == *"Moved the include for the shared config back to the top"* ]] || false
	[ "$(git config --file "$HOME/.gitconfig" --list | head -n 1)" = "include.path=$SHARED_INCLUDE" ]
	# 2, not 1: the shared include plus the local one setup_local_gitconfig always adds after it
	[ "$(git config --file "$HOME/.gitconfig" --get-all include.path | wc -l | tr -d ' ')" -eq 2 ]
	[ "$(git config --global --includes user.email)" = "me@example.com" ]
	[ "$(git config --global --includes core.editor)" = "vim" ]
	# No empty [include] header left behind
	[ "$(grep -c '^\[include\]' "$HOME/.gitconfig")" -eq 1 ]
}

@test "setup_git: moving the include keeps other includes in the same section" {
	printf '[user]\n\temail = me@example.com\n[include]\n\tpath = %s\n\tpath = ~/other.gitconfig\n' "$SHARED_INCLUDE" > "$HOME/.gitconfig"
	call setup_git
	[ "$(git config --file "$HOME/.gitconfig" --list | head -n 1)" = "include.path=$SHARED_INCLUDE" ]
	# --includes: ~/other.gitconfig moved into $LOCAL_DIR/gitconfig along with the rest of what was
	# below the shared include, so it's only visible once includes are expanded
	git config --file "$HOME/.gitconfig" --includes --get-all include.path | grep -qxF '~/other.gitconfig'
}

@test "setup_git: removes the include of a dotfiles gitconfig that no longer exists" {
	# Written the way install.sh writes paths (C:/... on Windows - Git Bash would convert a /tmp/...
	# path when passing it to git, so it wouldn't match)
	gone="$(native "$BATS_TEST_TMPDIR/gone/git/gitconfig")"
	printf '[include]\n\tpath = %s\n' "$gone" > "$HOME/.gitconfig"
	call setup_git
	[[ "$output" == *"Removed include of $gone"* ]] || false
	# Not an exact-match: setup_local_gitconfig always adds a second (local) include alongside it
	git config --file "$HOME/.gitconfig" --get-all include.path | grep -qxF "$SHARED_INCLUDE"
	run ! sh -c "git config --file '$HOME/.gitconfig' --get-all include.path | grep -qxF '$gone'"
}

#   -------------------------------
#   setup_git: local/gitconfig
#   -------------------------------

@test "setup_git: adds a second include for LOCAL_DIR/gitconfig after the shared one" {
	call setup_git
	local_include="$(native "$LOCAL_DIR/gitconfig")"
	lines="$(git config --file "$HOME/.gitconfig" --get-all include.path)"
	[ "$(printf '%s\n' "$lines" | sed -n 1p)" = "$SHARED_INCLUDE" ]
	[ "$(printf '%s\n' "$lines" | sed -n 2p)" = "$local_include" ]
	[[ "$output" == *"Added include for this machine's local config"* ]] || false
}

@test "setup_git: moves settings below the shared include into LOCAL_DIR/gitconfig the first time" {
	printf '[user]\n\temail = me@example.com\n' > "$HOME/.gitconfig"
	call setup_git
	[[ "$output" == *"Moved $HOME/.gitconfig's personal settings into $LOCAL_DIR/gitconfig"* ]] || false
	[ "$(git config --file "$LOCAL_DIR/gitconfig" user.email)" = "me@example.com" ]
	# user.email itself is no longer directly in ~/.gitconfig (core.excludesfile legitimately is -
	# setup_git adds that separately, regardless of what got migrated)
	run ! sh -c "git config --file '$HOME/.gitconfig' --name-only --list | grep -qxF user.email"
}

@test "setup_git: asks before moving personal settings, and a declined answer leaves them in ~/.gitconfig" {
	printf '[user]\n\temail = me@example.com\n' > "$HOME/.gitconfig"
	call_answering n setup_git
	[ "$status" -eq 0 ]
	[[ "$output" == *"Leaving $HOME/.gitconfig's personal settings where they are"* ]] || false
	[ "$(git config --global --includes user.email)" = "me@example.com" ]
	git config --file "$HOME/.gitconfig" --name-only --list | grep -qxF user.email
	[ -f "$LOCAL_DIR/gitconfig" ]
	[ ! -s "$LOCAL_DIR/gitconfig" ]
}

@test "setup_git: a second run doesn't move anything, even if ~/.gitconfig gains new settings" {
	call setup_git
	printf '[extra]\n\tthing = added-after-first-run\n' >> "$HOME/.gitconfig"
	call setup_git
	[[ "$output" != *"Moved"* ]] || false
	[ "$(git config --file "$LOCAL_DIR/gitconfig" --get-all --name-only | wc -l | tr -d ' ')" -eq 0 ]
	[ "$(git config --global --includes extra.thing)" = "added-after-first-run" ]
}

@test "setup_git: creates an empty LOCAL_DIR/gitconfig when there's nothing to move" {
	call setup_git
	[ -f "$LOCAL_DIR/gitconfig" ]
	[ ! -s "$LOCAL_DIR/gitconfig" ]
}

@test "setup_git: commits LOCAL_DIR/gitconfig when LOCAL_DIR already exists (e.g. from setup_local_dir)" {
	call setup_local_dir
	call setup_git
	[ "$status" -eq 0 ]
	[ -z "$(git -C "$LOCAL_DIR" status --porcelain)" ]
	git -C "$LOCAL_DIR" log --format=%s | grep -qxF "Add local/gitconfig"
}

@test "setup_git: doesn't error when LOCAL_DIR isn't a git repo yet" {
	call setup_git
	[ "$status" -eq 0 ]
	[ ! -d "$LOCAL_DIR/.git" ]
}

@test "check_gitconfig --check: warns when the include isn't at the top" {
	printf '[user]\n\temail = me@example.com\n[include]\n\tpath = %s\n' "$SHARED_INCLUDE" > "$HOME/.gitconfig"
	MODE_FLAG=--check call check_gitconfig
	[[ "$output" == *"WARNING: the include for the shared config isn't at the top"* ]] || false
}

@test "check_gitconfig --check: no warning when the include is at the top" {
	printf '[include]\n\tpath = %s\n[user]\n\temail = me@example.com\n' "$SHARED_INCLUDE" > "$HOME/.gitconfig"
	MODE_FLAG=--check call check_gitconfig
	[[ "$output" != *"isn't at the top"* ]] || false
}

#   -------------------------------
#   setup_git: core.excludesfile
#   -------------------------------

@test "setup_git: sets core.excludesfile when it isn't set" {
	call setup_git
	[ "$(git config --global core.excludesfile)" = "$(native "$REPO/git/gitignore_global")" ]
}

@test "setup_git: keeps core.excludesfile when it's another file that exists" {
	touch "$HOME/my-ignore"
	printf '[core]\n\texcludesfile = %s\n' "$HOME/my-ignore" > "$HOME/.gitconfig"
	call setup_git
	# --includes: this setting had no shared include to protect it, so it moved into
	# $LOCAL_DIR/gitconfig along with everything else that used to be in ~/.gitconfig
	[ "$(git config --global --includes core.excludesfile)" = "$HOME/my-ignore" ]
}

@test "setup_git: replaces core.excludesfile when it points at a file that doesn't exist" {
	printf '[core]\n\texcludesfile = %s\n' "$HOME/missing-ignore" > "$HOME/.gitconfig"
	call setup_git
	[[ "$output" == *"which doesn't exist"* ]] || false
	[ "$(git config --global core.excludesfile)" = "$(native "$REPO/git/gitignore_global")" ]
}
