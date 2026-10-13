#!/usr/bin/env bats
# Unit tests for install.sh: the shell blocks it manages and the order of ~/.gitconfig.
# Each test gets an empty fake home folder (with a space in its path), so nothing real is touched.
# Run with: tools/run-tests.sh (or: bats __test__)

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
#   setup_git: the shared include
#   -------------------------------

@test "setup_git: adds the shared include at the top and keeps existing settings below it" {
	printf '[user]\n\temail = me@example.com\n' > "$HOME/.gitconfig"
	call setup_git
	[ "$status" -eq 0 ]
	[[ "$output" == *"Added include for the shared config to the top"* ]] || false
	[ "$(git config --file "$HOME/.gitconfig" --list | head -n 1)" = "include.path=$SHARED_INCLUDE" ]
	[ "$(git config --global user.email)" = "me@example.com" ]
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
	[ "$(git config --file "$HOME/.gitconfig" --get-all include.path | wc -l | tr -d ' ')" -eq 1 ]
	[ "$(git config --global user.email)" = "me@example.com" ]
	[ "$(git config --global core.editor)" = "vim" ]
	# No empty [include] header left behind
	[ "$(grep -c '^\[include\]' "$HOME/.gitconfig")" -eq 1 ]
}

@test "setup_git: moving the include keeps other includes in the same section" {
	printf '[user]\n\temail = me@example.com\n[include]\n\tpath = %s\n\tpath = ~/other.gitconfig\n' "$SHARED_INCLUDE" > "$HOME/.gitconfig"
	call setup_git
	[ "$(git config --file "$HOME/.gitconfig" --list | head -n 1)" = "include.path=$SHARED_INCLUDE" ]
	git config --file "$HOME/.gitconfig" --get-all include.path | grep -qxF '~/other.gitconfig'
}

@test "setup_git: removes the include of a dotfiles gitconfig that no longer exists" {
	# Written the way install.sh writes paths (C:/... on Windows - Git Bash would convert a /tmp/...
	# path when passing it to git, so it wouldn't match)
	gone="$(native "$BATS_TEST_TMPDIR/gone/git/gitconfig")"
	printf '[include]\n\tpath = %s\n' "$gone" > "$HOME/.gitconfig"
	call setup_git
	[[ "$output" == *"Removed include of $gone"* ]] || false
	[ "$(git config --file "$HOME/.gitconfig" --get-all include.path)" = "$SHARED_INCLUDE" ]
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
	[ "$(git config --global core.excludesfile)" = "$HOME/my-ignore" ]
}

@test "setup_git: replaces core.excludesfile when it points at a file that doesn't exist" {
	printf '[core]\n\texcludesfile = %s\n' "$HOME/missing-ignore" > "$HOME/.gitconfig"
	call setup_git
	[[ "$output" == *"which doesn't exist"* ]] || false
	[ "$(git config --global core.excludesfile)" = "$(native "$REPO/git/gitignore_global")" ]
}
