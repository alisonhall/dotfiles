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
	# The pre-commit hook install.sh gives LOCAL_DIR refuses to commit without gitleaks, which CI
	# doesn't install - so install.sh's own commits there would fail, leaving its changes staged
	export SKIP_GITLEAKS=1
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

# symlink <target> <link>: A real symlink, made the way install.sh's make_link makes one. In Git
# Bash, a plain ln -s quietly copies the target instead (and fails if there's nothing to copy).
symlink() { MSYS=winsymlinks:nativestrict ln -s "$1" "$2"; }

# needs_symlinks: Skips the test where symlinks can't be made - Windows without Developer Mode or
# admin rights. (install.sh then says how to turn them on, and leaves the files as they are.)
needs_symlinks() {
	touch "$BATS_TEST_TMPDIR/symlink-target"
	symlink "$BATS_TEST_TMPDIR/symlink-target" "$BATS_TEST_TMPDIR/symlink-check" 2>/dev/null ||
		skip "this system won't make symlinks (on Windows, turn on Developer Mode)"
	rm -f "$BATS_TEST_TMPDIR/symlink-check" "$BATS_TEST_TMPDIR/symlink-target"
}

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
	grep -qx OLD "$LOCAL_DIR"/backups/*/HOME/.zshrc
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

@test "check_startup_files --check: syntax-checks ~/.shell_local when LOCAL_DIR's doesn't exist" {
	printf 'export NAME=Me\nif [ -n "$NAME" ' > "$HOME/.shell_local" # missing ]; then ...; fi
	MODE_FLAG=--check call check_startup_files
	[[ "$output" == *"$HOME/.shell_local has a bash syntax error"* ]] || false
	# (Only checked with the shells that are installed - Git Bash has no zsh)
	if command -v zsh >/dev/null 2>&1; then
		[[ "$output" == *"$HOME/.shell_local has a zsh syntax error"* ]] || false
	fi
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
	[ -f "$LOCAL_DIR/README.md" ]
	[ -f "$LOCAL_DIR/secrets.sh" ]
	grep -qxF secrets.sh "$LOCAL_DIR/.gitignore"
	grep -qF 'source "$DOTFILES/local/secrets.sh"' "$LOCAL_DIR/shell_local.sh"
	[ -x "$LOCAL_DIR/.githooks/pre-commit" ]
	[ "$(git -C "$LOCAL_DIR" config --get core.hooksPath)" = .githooks ]
	# Committed, not left sitting staged/untracked
	[ -z "$(git -C "$LOCAL_DIR" status --porcelain)" ]
	[ "$(git -C "$LOCAL_DIR" log --oneline | wc -l | tr -d ' ')" -eq 1 ]
}

@test "setup_local_dir: adds secrets.sh to an existing .gitignore that predates it" {
	call setup_local_dir
	sed -i.orig '/secrets.sh/d' "$LOCAL_DIR/.gitignore" && rm -f "$LOCAL_DIR/.gitignore.orig"
	! grep -qxF secrets.sh "$LOCAL_DIR/.gitignore" || false
	call setup_local_dir
	[ "$status" -eq 0 ]
	grep -qxF secrets.sh "$LOCAL_DIR/.gitignore"
}

@test "setup_local_dir: adds the secrets.sh sourcing line to a shell_local.sh that predates it" {
	mkdir -p "$LOCAL_DIR"
	printf 'export NAME=Me\n' > "$LOCAL_DIR/shell_local.sh"
	call setup_local_dir
	[ "$status" -eq 0 ]
	[[ "$output" == *"sources $LOCAL_DIR/secrets.sh"* ]] || false
	grep -qF 'source "$DOTFILES/local/secrets.sh"' "$LOCAL_DIR/shell_local.sh"
	grep -qxF 'export NAME=Me' "$LOCAL_DIR/shell_local.sh"
	# secrets.sh source line comes before the pre-existing content
	[ "$(grep -nF 'source "$DOTFILES/local/secrets.sh"' "$LOCAL_DIR/shell_local.sh" | cut -d: -f1)" -lt \
		"$(grep -nxF 'export NAME=Me' "$LOCAL_DIR/shell_local.sh" | cut -d: -f1)" ]
}

@test "setup_local_dir: a second run doesn't duplicate the secrets.sh sourcing line" {
	call setup_local_dir
	before="$(grep -cF 'source "$DOTFILES/local/secrets.sh"' "$LOCAL_DIR/shell_local.sh")"
	call setup_local_dir
	after="$(grep -cF 'source "$DOTFILES/local/secrets.sh"' "$LOCAL_DIR/shell_local.sh")"
	[ "$before" -eq 1 ]
	[ "$after" -eq 1 ]
}

@test "setup_local_dir: asks before creating LOCAL_DIR as a git repo, and a declined answer leaves it a plain folder" {
	call_answering n setup_local_dir
	[ "$status" -eq 0 ]
	[[ "$output" == *"Created $LOCAL_DIR as a plain folder"* ]] || false
	[ -d "$LOCAL_DIR" ]
	[ ! -d "$LOCAL_DIR/.git" ]
	# Created either way, so the folder is ready to become a repo later with nothing to fill in
	[ -f "$LOCAL_DIR/.gitignore" ]
	[ -f "$LOCAL_DIR/README.md" ]
	[ -f "$LOCAL_DIR/shell_local.sh" ]
	[ -f "$LOCAL_DIR/dotfiles_blocklist" ]
}

@test "setup_local_dir: doesn't re-ask the git-repo question once LOCAL_DIR already exists" {
	call_answering n setup_local_dir
	call setup_local_dir
	[ "$status" -eq 0 ]
	[ ! -d "$LOCAL_DIR/.git" ]
}

@test "setup_local_dir: creates the pre-commit hook even when LOCAL_DIR is declined as a git repo" {
	call_answering n setup_local_dir
	[ "$status" -eq 0 ]
	[ -x "$LOCAL_DIR/.githooks/pre-commit" ]
	[[ "$output" != *"Enabled pre-commit checks"* ]] || false
}

@test "setup_local_dir: wires up the pre-commit hook on a later run if LOCAL_DIR becomes a git repo by hand" {
	call_answering n setup_local_dir
	git init -q "$LOCAL_DIR"
	call setup_local_dir
	[ "$status" -eq 0 ]
	[[ "$output" == *"Enabled pre-commit checks"* ]] || false
	[ "$(git -C "$LOCAL_DIR" config --get core.hooksPath)" = .githooks ]
}

@test "setup_local_dir: the pre-commit hook has valid bash syntax and flags a shell_local.sh syntax error" {
	call setup_local_dir
	bash -n "$LOCAL_DIR/.githooks/pre-commit"
	printf 'if [ -n "$NAME" ' > "$LOCAL_DIR/shell_local.sh" # missing ]; then ...; fi
	run env SKIP_GITLEAKS=1 bash -c 'cd "$1" && ./.githooks/pre-commit' bats-call "$LOCAL_DIR"
	[ "$status" -ne 0 ]
	[[ "$output" == *"bash syntax error in shell_local.sh"* ]] || false
}

@test "setup_local_dir: upgrades a pre-commit hook from an older install.sh that only looked for gitleaks in ~/.local/bin" {
	call setup_local_dir
	hook="$LOCAL_DIR/.githooks/pre-commit"
	cp "$hook" "$BATS_TEST_TMPDIR/current-hook"
	# The older hook's two lines, in place of the current six - plus a change of your own
	awk '
		/^# Where install.sh may have put it/ {
			print "# install.sh may have put it in ~/.local/bin, which GUI git clients don'"'"'t have on PATH"
			print "PATH=\"$PATH:$HOME/.local/bin\""
			skip = 5; next
		}
		skip > 0 { skip--; next }
		{ print }
	' "$BATS_TEST_TMPDIR/current-hook" > "$hook"
	echo "# my own check" >> "$hook"
	grep -qxF 'PATH="$PATH:$HOME/.local/bin"' "$hook"

	call setup_local_dir
	[ "$status" -eq 0 ]
	[[ "$output" == *"Updated $hook"* ]] || false
	diff <(cat "$BATS_TEST_TMPDIR/current-hook"; echo "# my own check") "$hook"
	[ -x "$hook" ]
	grep -qxF 'PATH="$PATH:$HOME/.local/bin"' "$(find "$LOCAL_DIR/backups" -name pre-commit)"

	# Only once
	call setup_local_dir
	[[ "$output" != *"Updated $hook"* ]] || false
}

@test "setup_local_dir: moves an existing ~/.shell_local, ~/.p10k.zsh and ~/.dotfiles_blocklist in" {
	printf 'export NAME=Me\n' > "$HOME/.shell_local"
	printf 'existing p10k config\n' > "$HOME/.p10k.zsh"
	printf 'blocked-string\n' > "$HOME/.dotfiles_blocklist"
	call setup_local_dir
	[ "$status" -eq 0 ]
	# Moved content is kept, with the secrets.sh sourcing line added ahead of it
	grep -qxF 'export NAME=Me' "$LOCAL_DIR/shell_local.sh"
	grep -qF 'source "$DOTFILES/local/secrets.sh"' "$LOCAL_DIR/shell_local.sh"
	[ "$(cat "$LOCAL_DIR/p10k.zsh")" = "existing p10k config" ]
	[ "$(cat "$LOCAL_DIR/dotfiles_blocklist")" = "blocked-string" ]
	[ ! -e "$HOME/.shell_local" ]
	[ ! -e "$HOME/.p10k.zsh" ]
	[ ! -e "$HOME/.dotfiles_blocklist" ]
}

@test "setup_local_dir: adds what a leftover ~/.dotfiles_blocklist has that LOCAL_DIR's doesn't, then backs it up" {
	mkdir -p "$LOCAL_DIR"
	printf '# mine\r\nshared@example.com\r\n' > "$LOCAL_DIR/dotfiles_blocklist"
	printf 'shared@example.com\nold-only\nre:PROJ-[0-9]+\n\n# a comment\nold-only\n' > "$HOME/.dotfiles_blocklist"
	call setup_local_dir
	[ "$status" -eq 0 ]
	[[ "$output" == *"Added 2 entries from $HOME/.dotfiles_blocklist"* ]] || false
	[ ! -e "$HOME/.dotfiles_blocklist" ]
	ls "$LOCAL_DIR"/backups/*/HOME/.dotfiles_blocklist
	# Each entry once, after a comment saying where they came from, in the file's own line endings
	list="$(tr -d '\r' < "$LOCAL_DIR/dotfiles_blocklist")"
	[ "$(grep -cxF shared@example.com <<<"$list")" -eq 1 ]
	[ "$(grep -cxF old-only <<<"$list")" -eq 1 ]
	grep -qxF 're:PROJ-[0-9]+' <<<"$list"
	grep -qxF '# From ~/.dotfiles_blocklist (added by install.sh)' <<<"$list"
	[ "$(tr -cd '\r' < "$LOCAL_DIR/dotfiles_blocklist" | wc -c)" -eq "$(wc -l < "$LOCAL_DIR/dotfiles_blocklist")" ]
}

@test "setup_local_dir: declining to merge a leftover ~/.dotfiles_blocklist leaves both, with a warning" {
	git init -q "$LOCAL_DIR"
	printf 'shared@example.com\n' > "$LOCAL_DIR/dotfiles_blocklist"
	printf 'old-only\n' > "$HOME/.dotfiles_blocklist"
	call_answering n setup_local_dir
	[[ "$output" == *"WARNING: $HOME/.dotfiles_blocklist has 1 entry the pre-commit hook isn't checking"* ]] || false
	[ "$(cat "$HOME/.dotfiles_blocklist")" = old-only ]
	[ "$(cat "$LOCAL_DIR/dotfiles_blocklist")" = shared@example.com ]
}

@test "setup_local_dir: a leftover ~/.dotfiles_blocklist with nothing new in it is just backed up" {
	mkdir -p "$LOCAL_DIR"
	printf 'shared@example.com\nother\n' > "$LOCAL_DIR/dotfiles_blocklist"
	printf '# old\nother\n' > "$HOME/.dotfiles_blocklist"
	before="$(checksum "$LOCAL_DIR/dotfiles_blocklist")"
	call setup_local_dir
	[[ "$output" == *"everything in it is already in $LOCAL_DIR/dotfiles_blocklist"* ]] || false
	[ ! -e "$HOME/.dotfiles_blocklist" ]
	[ "$(checksum "$LOCAL_DIR/dotfiles_blocklist")" = "$before" ]
}

@test "setup_local_dir: leaves a ~/.dotfiles_blocklist link for local/'s own install.sh to deal with" {
	needs_symlinks
	mkdir -p "$LOCAL_DIR" "$BATS_TEST_TMPDIR/old bin"
	printf 'shared@example.com\n' > "$LOCAL_DIR/dotfiles_blocklist"
	printf 'old-only\n' > "$BATS_TEST_TMPDIR/old bin/dotfiles_blocklist"
	symlink "$BATS_TEST_TMPDIR/old bin/dotfiles_blocklist" "$HOME/.dotfiles_blocklist"
	call setup_local_dir
	[ -L "$HOME/.dotfiles_blocklist" ]
	[ "$(cat "$LOCAL_DIR/dotfiles_blocklist")" = shared@example.com ]
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
	# Existing content is kept, with the secrets.sh sourcing line added ahead of it
	grep -qxF 'export NAME=Already-here' "$LOCAL_DIR/shell_local.sh"
	! grep -qxF 'export NAME=Me' "$LOCAL_DIR/shell_local.sh" || false
	# The old ~/.shell_local is left alone - migrate_into_local only moves into an empty slot
	[ -f "$HOME/.shell_local" ]
}

@test "setup_local_dir: asks before moving ~/.p10k.zsh, and a declined answer leaves it in place" {
	printf 'existing p10k config\n' > "$HOME/.p10k.zsh"
	# First answer accepts the git-repo question, second declines the p10k move
	call_answering $'y\nn' setup_local_dir
	[ "$status" -eq 0 ]
	[[ "$output" == *"Leaving $HOME/.p10k.zsh where it is"* ]] || false
	[ -f "$HOME/.p10k.zsh" ]
	[ ! -e "$LOCAL_DIR/p10k.zsh" ]
}

@test "setup_local_dir: an accepted answer moves ~/.p10k.zsh" {
	printf 'existing p10k config\n' > "$HOME/.p10k.zsh"
	call_answering $'y\ny' setup_local_dir
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
	ls "$LOCAL_DIR"/backups/*/HOME/.gitconfig
	run ! ls "$HOME"/.gitconfig.bak.*
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
#   check_reminders: falls back to the legacy ~/.* paths
#   -------------------------------

@test "check_reminders: flags ~/.shell_local as the unedited template when LOCAL_DIR's doesn't exist" {
	cp "$REPO/local.example.sh" "$HOME/.shell_local"
	call check_reminders
	[[ "$output" == *"$HOME/.shell_local is still the unedited template"* ]] || false
}

@test "check_reminders: doesn't flag ~/.shell_local once it's been edited" {
	printf 'export NAME=Me\n' > "$HOME/.shell_local"
	call check_reminders
	[[ "$output" != *"is still the unedited template"* ]] || false
}

@test "check_reminders: finds the blocklist at ~/.dotfiles_blocklist when LOCAL_DIR's doesn't exist" {
	printf 'something@example.com\n' > "$HOME/.dotfiles_blocklist"
	call check_reminders
	[[ "$output" != *"has no entries"* ]] || false
}

@test "check_reminders: reports the blocklist missing by its legacy path, not LOCAL_DIR's" {
	call check_reminders
	[[ "$output" == *"$HOME/.dotfiles_blocklist has no entries"* ]] || false
}

@test "check_reminders: warns about entries only in a leftover ~/.dotfiles_blocklist" {
	mkdir -p "$LOCAL_DIR"
	printf 'shared@example.com\n' > "$LOCAL_DIR/dotfiles_blocklist"
	printf 'shared@example.com\nold-one\nold-two\n' > "$HOME/.dotfiles_blocklist"
	call check_reminders
	[[ "$output" == *"WARNING: ~/.dotfiles_blocklist has 2 entries that $LOCAL_DIR/dotfiles_blocklist doesn't"* ]] || false
	# Only a note once everything in it is there too
	printf 'shared@example.com\n' > "$HOME/.dotfiles_blocklist"
	call check_reminders
	[[ "$output" != *"WARNING: ~/.dotfiles_blocklist"* ]] || false
	[[ "$output" == *"NOTE: ~/.dotfiles_blocklist is left over"* ]] || false
}

@test "check_reminders: prefers LOCAL_DIR's shell_local.sh and blocklist when both exist" {
	mkdir -p "$LOCAL_DIR"
	printf 'export NAME=Me\n' > "$LOCAL_DIR/shell_local.sh"
	printf 'something@example.com\n' > "$LOCAL_DIR/dotfiles_blocklist"
	cp "$REPO/local.example.sh" "$HOME/.shell_local"
	call check_reminders
	[[ "$output" != *"is still the unedited template"* ]] || false
	[[ "$output" != *"has no entries"* ]] || false
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

#   -------------------------------
#   Linked tool config (~/.npmrc, ~/.m2/settings.xml -> local/)
#   -------------------------------

@test "link_local_file: links ~/.npmrc to local/npmrc when only the local copy exists" {
	needs_symlinks
	mkdir -p "$LOCAL_DIR"
	printf 'registry=https://example.com/\n' > "$LOCAL_DIR/npmrc"
	call link_local_file npmrc .npmrc
	[ "$status" -eq 0 ]
	[[ "$output" == *"Linked ~/.npmrc to $LOCAL_DIR/npmrc"* ]] || false
	[ "$(readlink "$HOME/.npmrc")" = "$LOCAL_DIR/npmrc" ]
	[ "$(cat "$HOME/.npmrc")" = "registry=https://example.com/" ]
}

@test "link_local_file: creates ~/.m2 for Maven's settings.xml" {
	needs_symlinks
	mkdir -p "$LOCAL_DIR"
	printf '<settings/>\n' > "$LOCAL_DIR/m2-settings.xml"
	call link_local_file m2-settings.xml .m2/settings.xml
	[ "$(readlink "$HOME/.m2/settings.xml")" = "$LOCAL_DIR/m2-settings.xml" ]
}

@test "link_local_file: asks to move an existing ~/.npmrc into local/, then links it back" {
	needs_symlinks
	mkdir -p "$LOCAL_DIR"
	printf 'registry=https://example.com/\n' > "$HOME/.npmrc"
	call_answering y link_local_file npmrc .npmrc
	[[ "$output" == *"Move ~/.npmrc into $LOCAL_DIR/npmrc"* ]] || false
	[ "$(cat "$LOCAL_DIR/npmrc")" = "registry=https://example.com/" ]
	[ "$(readlink "$HOME/.npmrc")" = "$LOCAL_DIR/npmrc" ]
}

@test "link_local_file: a declined move leaves ~/.npmrc where it is" {
	mkdir -p "$LOCAL_DIR"
	printf 'registry=https://example.com/\n' > "$HOME/.npmrc"
	call_answering n link_local_file npmrc .npmrc
	[[ "$output" == *"Leaving ~/.npmrc where it is"* ]] || false
	[ ! -L "$HOME/.npmrc" ]
	[ ! -e "$LOCAL_DIR/npmrc" ]
}

@test "link_local_file: an identical ~/.npmrc is backed up and replaced with the link" {
	needs_symlinks
	mkdir -p "$LOCAL_DIR"
	printf 'same\n' > "$LOCAL_DIR/npmrc"
	printf 'same\n' > "$HOME/.npmrc"
	call link_local_file npmrc .npmrc
	[ "$(readlink "$HOME/.npmrc")" = "$LOCAL_DIR/npmrc" ]
	ls "$LOCAL_DIR"/backups/*/HOME/.npmrc
	run ! ls "$HOME"/.npmrc.bak.*
}

@test "link_local_file: a different ~/.npmrc gets a warning, and both files are left alone" {
	mkdir -p "$LOCAL_DIR"
	printf 'local\n' > "$LOCAL_DIR/npmrc"
	printf 'home\n' > "$HOME/.npmrc"
	call link_local_file npmrc .npmrc
	[[ "$output" == *"WARNING: ~/.npmrc and $LOCAL_DIR/npmrc are different files"* ]] || false
	[ ! -L "$HOME/.npmrc" ]
	[ "$(cat "$HOME/.npmrc")" = home ]
	[ "$(cat "$LOCAL_DIR/npmrc")" = local ]
}

@test "link_local_file: leaves a ~/.npmrc that links somewhere else on purpose" {
	needs_symlinks
	mkdir -p "$LOCAL_DIR"
	printf 'local\n' > "$LOCAL_DIR/npmrc"
	printf 'elsewhere\n' > "$BATS_TEST_TMPDIR/other-npmrc"
	symlink "$BATS_TEST_TMPDIR/other-npmrc" "$HOME/.npmrc"
	call link_local_file npmrc .npmrc
	[[ "$output" == *"~/.npmrc links to $BATS_TEST_TMPDIR/other-npmrc"*"leaving it as it is"* ]] || false
	[ "$(readlink "$HOME/.npmrc")" = "$BATS_TEST_TMPDIR/other-npmrc" ]
}

@test "link_local_file: re-points a broken link (e.g. after the repo moved)" {
	needs_symlinks
	mkdir -p "$LOCAL_DIR" "$BATS_TEST_TMPDIR/old-repo/local"
	printf 'local\n' > "$LOCAL_DIR/npmrc"
	# Linked while the old copy existed, then the repo moved away (Windows can't link to nothing)
	printf 'old\n' > "$BATS_TEST_TMPDIR/old-repo/local/npmrc"
	symlink "$BATS_TEST_TMPDIR/old-repo/local/npmrc" "$HOME/.npmrc"
	rm -r "$BATS_TEST_TMPDIR/old-repo"
	call link_local_file npmrc .npmrc
	[ "$(readlink "$HOME/.npmrc")" = "$LOCAL_DIR/npmrc" ]
}

@test "link_local_file: does nothing when neither exists, or when it's already linked" {
	needs_symlinks
	mkdir -p "$LOCAL_DIR"
	call link_local_file npmrc .npmrc
	[ -z "$output" ]
	[ ! -e "$HOME/.npmrc" ]
	printf 'local\n' > "$LOCAL_DIR/npmrc"
	call link_local_file npmrc .npmrc
	call link_local_file npmrc .npmrc
	[ -z "$output" ]
}

@test "link_local_file: a file with a token or password is gitignored in local/, but still linked" {
	needs_symlinks
	mkdir -p "$LOCAL_DIR"
	git init -q "$LOCAL_DIR"
	printf '.DS_Store\n' > "$LOCAL_DIR/.gitignore"
	printf '//registry.example.com/:_authToken=abc123\n' > "$LOCAL_DIR/npmrc"
	git -C "$LOCAL_DIR" add npmrc
	call link_local_file npmrc .npmrc
	[[ "$output" == *"looks like it holds passwords or tokens"* ]] || false
	grep -qxF npmrc "$LOCAL_DIR/.gitignore"
	[ "$(readlink "$HOME/.npmrc")" = "$LOCAL_DIR/npmrc" ]
	# No longer staged, so it can't be committed
	[ -z "$(git -C "$LOCAL_DIR" diff --cached --name-only)" ]
}

@test "link_local_file: Maven settings with a <password> are gitignored too" {
	mkdir -p "$LOCAL_DIR"
	printf '<settings><servers><server><password>x</password></server></servers></settings>\n' > "$LOCAL_DIR/m2-settings.xml"
	call link_local_file m2-settings.xml .m2/settings.xml
	grep -qxF m2-settings.xml "$LOCAL_DIR/.gitignore"
}

@test "link_local_file: a file without credentials isn't gitignored" {
	mkdir -p "$LOCAL_DIR"
	printf 'registry=https://example.com/\n' > "$LOCAL_DIR/npmrc"
	call link_local_file npmrc .npmrc
	run ! grep -qxF npmrc "$LOCAL_DIR/.gitignore"
}

@test "setup_local_links: links ~/.npmrc and ~/.m2/settings.xml, and a second run changes nothing" {
	needs_symlinks
	call setup_local_dir
	printf 'registry=https://example.com/\n' > "$LOCAL_DIR/npmrc"
	printf '<settings/>\n' > "$LOCAL_DIR/m2-settings.xml"
	call setup_local_links
	[ "$status" -eq 0 ]
	[ "$(readlink "$HOME/.npmrc")" = "$LOCAL_DIR/npmrc" ]
	[ "$(readlink "$HOME/.m2/settings.xml")" = "$LOCAL_DIR/m2-settings.xml" ]
	# They're your files, not install.sh's, so it leaves committing them to you
	[ "$(git -C "$LOCAL_DIR" status --porcelain -- npmrc m2-settings.xml | wc -l | tr -d ' ')" -eq 2 ]
	call setup_local_links
	[[ "$output" != *"Linked ~/"* ]] || false
}

@test "run_local_install: runs local/install.sh with DOTFILES set, and passes --check on" {
	mkdir -p "$LOCAL_DIR"
	printf '#!/usr/bin/env bash\necho "local install ran with DOTFILES=$DOTFILES args=$*"\n' > "$LOCAL_DIR/install.sh"
	call run_local_install --check
	[ "$status" -eq 0 ]
	[[ "$output" == *"local install ran with DOTFILES=$REPO args=--check"* ]] || false
}

@test "run_local_install: problems from local/install.sh are a warning, not the end of install.sh" {
	mkdir -p "$LOCAL_DIR"
	printf '#!/usr/bin/env bash\nexit 1\n' > "$LOCAL_DIR/install.sh"
	call run_local_install
	[ "$status" -eq 0 ]
	[[ "$output" == *"WARNING: $LOCAL_DIR/install.sh reported problems"* ]] || false
}

@test "run_local_install: does nothing without local/install.sh" {
	mkdir -p "$LOCAL_DIR"
	call run_local_install
	[ -z "$output" ]
}

@test "check_local_links --check: warns when local/npmrc exists but ~/.npmrc doesn't link to it" {
	mkdir -p "$LOCAL_DIR"
	printf 'local\n' > "$LOCAL_DIR/npmrc"
	MODE_FLAG=--check call check_local_links
	[[ "$output" == *"WARNING: ~/.npmrc doesn't link to $LOCAL_DIR/npmrc, so tools use their defaults"* ]] || false
	printf 'home\n' > "$HOME/.npmrc"
	MODE_FLAG=--check call check_local_links
	[[ "$output" == *"so tools use ~/.npmrc instead"* ]] || false
}

@test "commit_local_changes: a commit its pre-commit hook blocks is a warning, not the end of install.sh" {
	mkdir -p "$LOCAL_DIR/.githooks"
	git init -q "$LOCAL_DIR"
	printf '#!/bin/sh\necho "blocked by the hook" >&2\nexit 1\n' > "$LOCAL_DIR/.githooks/pre-commit"
	chmod +x "$LOCAL_DIR/.githooks/pre-commit"
	git -C "$LOCAL_DIR" config core.hooksPath .githooks
	printf 'x\n' > "$LOCAL_DIR/file"
	call eval 'local_changed "$LOCAL_DIR/file"; commit_local_changes Test'
	[ "$status" -eq 0 ]
	[[ "$output" == *"WARNING: couldn't commit the changes in $LOCAL_DIR"* ]] || false
	[ -n "$(git -C "$LOCAL_DIR" diff --cached --name-only)" ]
}

#   -------------------------------
#   local/ as your own private repo (its own loader, README, gitconfig, install.sh...)
#   -------------------------------

# private_repo_local: LOCAL_DIR as a clone of a private repo would be, already committed
private_repo_local() {
	mkdir -p "$LOCAL_DIR/shell" "$LOCAL_DIR/profiles/work"
	git init -q "$LOCAL_DIR"
	printf '%s\n' '# My loader' '[ -f "$DOTFILES/local/secrets.sh" ] && source "$DOTFILES/local/secrets.sh"' \
		'for f in "$DOTFILES/local/shell/"*.sh; do source "$f"; done' > "$LOCAL_DIR/shell_local.sh"
	printf '# My private repo\n' > "$LOCAL_DIR/README.md"
	printf '[user]\n\temail = me@example.com\n' > "$LOCAL_DIR/gitconfig"
	printf '.DS_Store\n*.bak.*\nsecrets.sh\nmachine.sh\n' > "$LOCAL_DIR/.gitignore"
	printf 'my-blocked-string\n' > "$LOCAL_DIR/dotfiles_blocklist"
	printf 'export A=1\n' > "$LOCAL_DIR/shell/common.sh"
	printf 'export WORK=1\n' > "$LOCAL_DIR/profiles/work/shell.sh"
	git -C "$LOCAL_DIR" add -A
	git -C "$LOCAL_DIR" -c user.name=Me -c user.email=me@example.com commit -q -m "My private repo"
}

@test "private-repo local/: install.sh adds only what's missing, and leaves your own files as they are" {
	private_repo_local
	before="$(cd "$LOCAL_DIR" && cksum shell_local.sh README.md gitconfig .gitignore dotfiles_blocklist shell/common.sh)"
	call setup_local_dir
	[ "$status" -eq 0 ]
	[ "$(cd "$LOCAL_DIR" && cksum shell_local.sh README.md gitconfig .gitignore dotfiles_blocklist shell/common.sh)" = "$before" ]
	[ -f "$LOCAL_DIR/secrets.sh" ]
	[ -x "$LOCAL_DIR/.githooks/pre-commit" ]
	# Its one commit holds just the hook it added
	[ "$(git -C "$LOCAL_DIR" show --name-only --format= HEAD)" = .githooks/pre-commit ]
}

@test "private-repo local/: install.sh doesn't commit your own unfinished edits" {
	private_repo_local
	printf 'export WORK=2  # half-finished\n' > "$LOCAL_DIR/profiles/work/shell.sh"
	printf 'export NEW=1\n' > "$LOCAL_DIR/shell/new.sh"
	call setup_local_dir
	[ "$status" -eq 0 ]
	[ -z "$(git -C "$LOCAL_DIR" show --name-only --format= HEAD -- profiles/work/shell.sh shell/new.sh)" ]
	[[ "$(git -C "$LOCAL_DIR" status --porcelain)" == *"M profiles/work/shell.sh"*"?? shell/new.sh"* ]] || false
}

@test "private-repo local/: with your own changes staged, install.sh commits nothing and says why" {
	private_repo_local
	printf 'export WORK=2\n' > "$LOCAL_DIR/profiles/work/shell.sh"
	git -C "$LOCAL_DIR" add profiles/work/shell.sh
	head_before="$(git -C "$LOCAL_DIR" rev-parse HEAD)"
	call setup_local_dir
	[ "$status" -eq 0 ]
	[[ "$output" == *"WARNING: $LOCAL_DIR has other changes staged (profiles/work/shell.sh), so install.sh didn't commit its own (.githooks/pre-commit)"* ]] || false
	[ "$(git -C "$LOCAL_DIR" rev-parse HEAD)" = "$head_before" ]
	# Your staged change is still staged, as you left it
	[ "$(git -C "$LOCAL_DIR" diff --cached --name-only)" = profiles/work/shell.sh ]
}

@test "private-repo local/: runs its install.sh after git is set up, and a second run commits nothing" {
	private_repo_local
	printf '#!/usr/bin/env bash\ngit config --global --get-all include.path | grep -qF "local/gitconfig" && echo "local gitconfig is included"\n' > "$LOCAL_DIR/install.sh"
	git -C "$LOCAL_DIR" add install.sh
	git -C "$LOCAL_DIR" -c user.name=Me -c user.email=me@example.com commit -q -m "Add install.sh"
	call eval 'setup_local_dir; setup_git; run_local_install'
	[[ "$output" == *"local gitconfig is included"* ]] || false
	head_after_first="$(git -C "$LOCAL_DIR" rev-parse HEAD)"
	call eval 'setup_local_dir; setup_git; run_local_install; setup_local_links'
	[ "$(git -C "$LOCAL_DIR" rev-parse HEAD)" = "$head_after_first" ]
}

@test "local/'s pre-commit hook syntax-checks any staged .sh file, e.g. a private repo's shell/*.sh" {
	call setup_local_dir
	mkdir -p "$LOCAL_DIR/profiles/work"
	printf 'if true; then echo missing-fi\n' > "$LOCAL_DIR/profiles/work/shell.sh"
	git -C "$LOCAL_DIR" add profiles/work/shell.sh
	run env SKIP_GITLEAKS=1 bash -c 'cd "$1" && ./.githooks/pre-commit' bats-call "$LOCAL_DIR"
	[ "$status" -ne 0 ]
	[[ "$output" == *"bash syntax error in profiles/work/shell.sh"* ]] || false
	printf 'echo fixed\n' > "$LOCAL_DIR/profiles/work/shell.sh"
	git -C "$LOCAL_DIR" add profiles/work/shell.sh
	run env SKIP_GITLEAKS=1 bash -c 'cd "$1" && ./.githooks/pre-commit' bats-call "$LOCAL_DIR"
	[ "$status" -eq 0 ]
}

@test "check_gitconfig --check: warns when ~/.gitconfig overrides a setting in local/gitconfig" {
	mkdir -p "$LOCAL_DIR"
	printf '[user]\n\temail = me@example.com\n\tname = Me\n' > "$LOCAL_DIR/gitconfig"
	printf '[include]\n\tpath = %s\n\tpath = %s\n[user]\n\temail = old@example.com\n\tname = Me\n' \
		"$SHARED_INCLUDE" "$LOCAL_DIR/gitconfig" > "$HOME/.gitconfig"
	MODE_FLAG=--check call check_gitconfig
	[[ "$output" == *"WARNING: $HOME/.gitconfig also sets user.email, with different values from $LOCAL_DIR/gitconfig"* ]] || false
	[[ "$output" != *"user.name"* ]] || false    # Same value in both, so it doesn't matter
}

@test "check_gitconfig --check: no local/gitconfig warning when they agree, or when there's no local/gitconfig" {
	printf '[include]\n\tpath = %s\n[user]\n\temail = me@example.com\n' "$SHARED_INCLUDE" > "$HOME/.gitconfig"
	MODE_FLAG=--check call check_gitconfig
	[[ "$output" != *"also sets"* ]] || false
	mkdir -p "$LOCAL_DIR"
	printf '[user]\n\temail = me@example.com\n' > "$LOCAL_DIR/gitconfig"
	MODE_FLAG=--check call check_gitconfig
	[[ "$output" != *"also sets"* ]] || false
}

#   -------------------------------
#   Backups (local/backups/<run>/)
#   -------------------------------

@test "backup: copies a file under its original path into this run's folder, and keeps the first copy" {
	printf 'first\n' > "$HOME/.zshrc"
	call eval 'backup "$HOME/.zshrc"; printf "second\n" > "$HOME/.zshrc"; backup "$HOME/.zshrc"; echo "DIR=$BACKUP_DIR"'
	[ "$status" -eq 0 ]
	dir="$(printf '%s\n' "$output" | sed -n 's/^DIR=//p')"
	[[ "$dir" == "$LOCAL_DIR/backups/"* ]] || false
	[ "$(cat "$dir/HOME/.zshrc")" = first ]    # The state before the run
	[ "$(cat "$HOME/.zshrc")" = second ]
}

@test "backup --move: moves a file (or a link) there, without overwriting an earlier one" {
	printf 'a\n' > "$HOME/.npmrc"
	call eval 'backup "$HOME/.npmrc" --move; printf "b\n" > "$HOME/.npmrc"; backup "$HOME/.npmrc" --move'
	[ ! -e "$HOME/.npmrc" ]
	first="$(printf '%s\n' "$output" | head -n 1)"
	second="$(printf '%s\n' "$output" | tail -n 1)"
	[ "$(cat "$first")" = a ]
	[ "$(cat "$second")" = b ]
}

@test "backup: files inside local/ go under local/, others under other/" {
	mkdir -p "$LOCAL_DIR"
	printf 'x\n' > "$LOCAL_DIR/shell_local.sh"
	printf 'y\n' > "$BATS_TEST_TMPDIR/elsewhere"
	call eval 'backup "$LOCAL_DIR/shell_local.sh"; backup "$BATS_TEST_TMPDIR/elsewhere"'
	[[ "$output" == *"/backups/"*"/local/shell_local.sh"* ]] || false
	[[ "$output" == *"/backups/"*"/other$BATS_TEST_TMPDIR/elsewhere"* ]] || false
}

@test "backups: ignored in a local/ that install.sh created (via its .gitignore)" {
	call setup_local_dir
	printf 'old\n' > "$HOME/.zshrc"
	call eval 'backup "$HOME/.zshrc" >/dev/null'
	git -C "$LOCAL_DIR" check-ignore -q backups/anything
	[ -z "$(git -C "$LOCAL_DIR" status --porcelain)" ]
	run ! grep -q backups "$LOCAL_DIR/.git/info/exclude"
}

@test "backups: ignored in your own private repo via .git/info/exclude - its .gitignore isn't touched" {
	private_repo_local
	before="$(cksum < "$LOCAL_DIR/.gitignore")"
	printf 'old\n' > "$HOME/.zshrc"
	call eval 'backup "$HOME/.zshrc" >/dev/null; backup "$HOME/.zshrc" >/dev/null'
	git -C "$LOCAL_DIR" check-ignore -q backups/anything
	[ "$(cksum < "$LOCAL_DIR/.gitignore")" = "$before" ]
	[ "$(grep -c '^backups/$' "$LOCAL_DIR/.git/info/exclude")" -eq 1 ]
	[ -z "$(git -C "$LOCAL_DIR" status --porcelain)" ]
}

@test "backups: local/install.sh is told this run's backup folder" {
	mkdir -p "$LOCAL_DIR"
	printf '#!/usr/bin/env bash\necho "BACKUPS=$DOTFILES_BACKUP_DIR"\n' > "$LOCAL_DIR/install.sh"
	call eval 'run_local_install; echo "MINE=$BACKUP_DIR"'
	theirs="$(printf '%s\n' "$output" | sed -n 's/^BACKUPS=//p')"
	mine="$(printf '%s\n' "$output" | sed -n 's/^MINE=//p')"
	[ -n "$mine" ]
	[ "$theirs" = "$mine" ]
}

@test "backups: nothing is left behind in the home folder" {
	printf '[user]\n\temail = me@example.com\n' > "$HOME/.gitconfig"
	printf 'echo mine\n%s\nOLD\n%s\n' "# >>> dotfiles >>>" "# <<< dotfiles <<<" > "$HOME/.zshrc"
	call eval 'setup_local_dir; ensure_block "$HOME/.zshrc" NEW; setup_git'
	[ "$status" -eq 0 ]
	run ! ls -d "$HOME"/.*.bak.* "$HOME"/*.bak.*
	[ -f "$(ls -d "$LOCAL_DIR"/backups/*/HOME/.zshrc)" ]
	[ -f "$(ls -d "$LOCAL_DIR"/backups/*/HOME/.gitconfig)" ]
}

#   -------------------------------
#   VS Code settings
#   -------------------------------

# vscode_dir: VS Code's user settings folder in the fake home folder, created (as if VS Code had been used)
vscode_dir() {
	export APPDATA="$HOME/AppData/Roaming"    # Windows; elsewhere it's under $HOME already
	call vscode_settings_dir
	VSCODE_DIR="$output"
	mkdir -p "$VSCODE_DIR"
}

# Whether settings.json is still valid JSON, ignoring // comments and trailing commas like VS Code
# does (checked with python3 when there is one)
valid_settings() {
	command -v python3 >/dev/null 2>&1 || return 0
	python3 -c '
import json, re, sys
text = re.sub(r"^\s*//.*$", "", open(sys.argv[1]).read(), flags=re.M)
json.loads(re.sub(r",(\s*[}\]])", r"\1", text))' "$1"
}

@test "VS Code: adds the terminal font to existing settings, keeping everything else and backing up" {
	vscode_dir
	printf '%s\n' '{' '  // My settings' '  "editor.fontSize": 12,' '  "workbench.colorTheme": "Default Dark+"' '}' > "$VSCODE_DIR/settings.json"
	call setup_vscode
	[ "$status" -eq 0 ]
	[[ "$output" == *'Added "terminal.integrated.fontFamily": "MesloLGS NF"'* ]] || false
	grep -qF '"terminal.integrated.fontFamily": "MesloLGS NF",' "$VSCODE_DIR/settings.json"
	grep -qF '"editor.fontSize": 12,' "$VSCODE_DIR/settings.json"
	grep -qF '// My settings' "$VSCODE_DIR/settings.json"
	valid_settings "$VSCODE_DIR/settings.json"
	[ -n "$(find "$LOCAL_DIR/backups" -name settings.json)" ]
}

@test "VS Code: a font you've already set, even to something else, is left alone" {
	vscode_dir
	printf '{\n  "terminal.integrated.fontFamily": "Fira Code"\n}\n' > "$VSCODE_DIR/settings.json"
	before="$(cksum < "$VSCODE_DIR/settings.json")"
	call setup_vscode
	[[ "$output" == *'NOTE: VS Code'"'"'s terminal.integrated.fontFamily is "Fira Code" rather than "MesloLGS NF" - left as you have it'* ]] || false
	[ "$(cksum < "$VSCODE_DIR/settings.json")" = "$before" ]
}

@test "VS Code: creates settings.json when VS Code has none yet, and handles an empty {}" {
	vscode_dir
	call setup_vscode
	valid_settings "$VSCODE_DIR/settings.json"
	grep -qF '"terminal.integrated.fontFamily": "MesloLGS NF"' "$VSCODE_DIR/settings.json"
	printf '{}\n' > "$VSCODE_DIR/settings.json"
	call setup_vscode
	valid_settings "$VSCODE_DIR/settings.json"
	grep -qF '"terminal.integrated.fontFamily": "MesloLGS NF"' "$VSCODE_DIR/settings.json"
}

@test "VS Code: does nothing where VS Code hasn't been used" {
	export APPDATA="$HOME/AppData/Roaming"
	call setup_vscode
	[ -z "$output" ]
	[ -z "$(find "$HOME" -name settings.json)" ]
}

@test "VS Code: a second run changes nothing" {
	vscode_dir
	printf '{\n  "editor.fontSize": 12\n}\n' > "$VSCODE_DIR/settings.json"
	call setup_vscode
	before="$(cksum < "$VSCODE_DIR/settings.json")"
	call setup_vscode
	[[ "$output" == *'OK: terminal.integrated.fontFamily is "MesloLGS NF"'* ]] || false
	[ "$(cksum < "$VSCODE_DIR/settings.json")" = "$before" ]
}

@test "VS Code --check: says what's missing, and changes nothing" {
	vscode_dir
	printf '{\n  "editor.fontSize": 12\n}\n' > "$VSCODE_DIR/settings.json"
	before="$(cksum < "$VSCODE_DIR/settings.json")"
	MODE_FLAG=--check call setup_vscode
	[[ "$output" == *"NOTE: VS Code's settings don't set terminal.integrated.fontFamily"* ]] || false
	[ "$(cksum < "$VSCODE_DIR/settings.json")" = "$before" ]
}

#   -------------------------------
#   oh-my-zsh
#   -------------------------------

@test "install_oh_my_zsh: leaves an existing oh-my-zsh alone" {
	mkdir -p "$HOME/.oh-my-zsh"
	touch "$HOME/.oh-my-zsh/oh-my-zsh.sh"
	call install_oh_my_zsh
	[ "$status" -eq 0 ]
	[ "$output" = "  oh-my-zsh is installed" ]
}

@test "install_oh_my_zsh: doesn't clone over a ~/.oh-my-zsh that isn't oh-my-zsh" {
	mkdir -p "$HOME/.oh-my-zsh"
	echo mine > "$HOME/.oh-my-zsh/notes.txt"
	call install_oh_my_zsh
	[ "$status" -eq 0 ]
	[[ "$output" == *"exists but isn't oh-my-zsh"* ]] || false
	[ "$(ls "$HOME/.oh-my-zsh")" = notes.txt ]
}

@test "install_oh_my_zsh: DOTFILES_SKIP_OH_MY_ZSH skips it" {
	DOTFILES_SKIP_OH_MY_ZSH=1 call install_oh_my_zsh
	[ "$status" -eq 0 ]
	[[ "$output" == *"Skipping oh-my-zsh install"* ]] || false
	[ ! -e "$HOME/.oh-my-zsh" ]
}

#   -------------------------------
#   macOS settings
#   -------------------------------

# fake_defaults: A fake `defaults` command (first on PATH) that keeps each setting in a file, and
# reads bools back as 1/0 like the real one. Plus a small config/macos/defaults to apply.
fake_defaults() {
	FAKE_DEFAULTS="$BATS_TEST_TMPDIR/fake defaults"
	export FAKE_DEFAULTS
	mkdir -p "$FAKE_DEFAULTS/bin" "$FAKE_DEFAULTS/store"
	cat > "$FAKE_DEFAULTS/bin/defaults" <<'FAKE'
#!/usr/bin/env bash
file="$FAKE_DEFAULTS/store/$2.$3"
case "$1" in
	read) [ -f "$file" ] && cat "$file" ;;
	write)
		case "$4:$5" in
			-bool:true) echo 1 ;;
			-bool:false) echo 0 ;;
			*) echo "$5" ;;
		esac > "$file"
		;;
	delete) rm -f "$file" ;;
esac
FAKE
	printf '#!/usr/bin/env bash\n' > "$FAKE_DEFAULTS/bin/killall"
	chmod +x "$FAKE_DEFAULTS/bin/defaults" "$FAKE_DEFAULTS/bin/killall"
	export PATH="$FAKE_DEFAULTS/bin:$PATH"
	MACOS_DEFAULTS_FILE="$BATS_TEST_TMPDIR/macos-defaults"
	printf '%s\n' '# A comment' 'com.apple.dock orientation string left    # Dock on the left' \
		'com.apple.dock autohide bool false' 'NSGlobalDomain AppleShowAllExtensions bool true' > "$MACOS_DEFAULTS_FILE"
}

# macos_defaults <answer> [--check]: Run setup_macos_defaults as if on a Mac, answering <answer>
# (empty: no one to ask)
macos_defaults() {
	local answer="$1"
	shift
	run bash -c '
		script="$1" file="$2" answer="$3"; shift 3
		set -- "$@"
		source "$script"
		MACOS_DEFAULTS="$file"
		BACKUP_DIR="$BATS_TEST_TMPDIR/backups"
		is_macos() { return 0; }
		if [ -n "$answer" ]; then can_ask() { return 0; }; else can_ask() { return 1; }; fi
		setup_macos_defaults
	' bats-call "$REPO/install.sh" "$MACOS_DEFAULTS_FILE" "$answer" "$@" <<<"$answer"
}

@test "macOS settings: applies the ones that differ after asking, and saves a script that undoes them" {
	fake_defaults
	echo right > "$FAKE_DEFAULTS/store/com.apple.dock.orientation"
	echo 0 > "$FAKE_DEFAULTS/store/com.apple.dock.autohide"    # Already matches (false)
	macos_defaults y
	[ "$status" -eq 0 ]
	[[ "$output" == *"com.apple.dock orientation: right -> left"* ]] || false
	[[ "$output" == *"NSGlobalDomain AppleShowAllExtensions: not set -> true"* ]] || false
	[[ "$output" != *"autohide"* ]] || false
	[[ "$output" == *"Applied 2 macOS setting(s)"* ]] || false
	[ "$(cat "$FAKE_DEFAULTS/store/com.apple.dock.orientation")" = left ]
	[ "$(cat "$FAKE_DEFAULTS/store/NSGlobalDomain.AppleShowAllExtensions")" = 1 ]

	# The undo script puts both back
	bash "$BATS_TEST_TMPDIR/backups/macos-defaults-restore.sh"
	[ "$(cat "$FAKE_DEFAULTS/store/com.apple.dock.orientation")" = right ]
	[ ! -e "$FAKE_DEFAULTS/store/NSGlobalDomain.AppleShowAllExtensions" ]

	# Once applied, running it again changes nothing
	macos_defaults y
	macos_defaults y
	[ "$output" = $'macOS settings (config/macos/defaults):\n  All 3 match' ]
}

@test "macOS settings: answering no, --check, or no one to ask changes nothing" {
	fake_defaults
	macos_defaults n
	[[ "$output" == *"Left as they are"* ]] || false
	macos_defaults ""
	[[ "$output" == *"not applied without someone to ask"* ]] || false
	macos_defaults y --check
	[[ "$output" == *"NOTE: 3 differ from config/macos/defaults"* ]] || false
	[ -z "$(ls "$FAKE_DEFAULTS/store")" ]
}

@test "macOS settings: values can have spaces, and lines that aren't settings are skipped with a note" {
	fake_defaults
	printf '%s\n' 'com.example.app Greeting string Hello there' 'com.example.app Broken' > "$MACOS_DEFAULTS_FILE"
	echo old > "$FAKE_DEFAULTS/store/com.example.app.Greeting"
	macos_defaults y
	[ "$status" -eq 0 ]
	[[ "$output" == *'skipped "com.example.app Broken"'* ]] || false
	[ "$(cat "$FAKE_DEFAULTS/store/com.example.app.Greeting")" = "Hello there" ]
	echo "old value" > "$FAKE_DEFAULTS/store/com.example.app.Greeting"
	macos_defaults y
	bash "$(find "$BATS_TEST_TMPDIR/backups" -name macos-defaults-restore.sh)"
	[ "$(cat "$FAKE_DEFAULTS/store/com.example.app.Greeting")" = "old value" ]
}

@test "macOS settings: does nothing on other systems" {
	# Never the real `defaults`, and never this Mac's real settings - tests run from a terminal
	# could otherwise ask, and apply them
	run bash -c '
		script="$1"; shift
		source "$script"
		is_macos() { return 1; }
		defaults() { echo "defaults was run"; }
		setup_macos_defaults
	' bats-call "$REPO/install.sh"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}
