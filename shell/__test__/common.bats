#!/usr/bin/env bats
# Tests for shell/common.sh: path_add and the Homebrew setup.
# common.sh sets up nvm, Homebrew etc. when it's loaded, so each test takes just the piece it
# tests out of the file.

setup() {
	COMMON="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/common.sh"
	DIRS="$BATS_TEST_TMPDIR/dirs"
	mkdir -p "$DIRS/a" "$DIRS/b" "$DIRS/with space" "$DIRS/bin2"
}

# piece <start line regex> <end line regex>: Print part of common.sh, failing if it isn't there
piece() {
	local code
	code="$(sed -n "/$1/,/$2/p" "$COMMON")"
	[ -n "$code" ] || { echo "Couldn't find /$1/ in $COMMON - did it move?" >&2; return 1; }
	printf '%s\n' "$code"
}

# with_path_add <PATH> <commands>: Run commands with path_add defined and PATH set, printing PATH after
with_path_add() {
	local definition
	definition="$(piece '^path_add () {' '^}')" || return 1
	run bash -c "$definition"$'\n''PATH="$1"; eval "$2"; printf "%s\n" "$PATH"' _ "$1" "$2"
}

#   -------------------------------
#   path_add
#   -------------------------------

@test "path_add: adds a folder to the end" {
	with_path_add "/usr/bin" "path_add '$DIRS/a'"
	[ "$output" = "/usr/bin:$DIRS/a" ]
}

@test "path_add --prepend: adds a folder to the start" {
	with_path_add "/usr/bin" "path_add '$DIRS/a' --prepend"
	[ "$output" = "$DIRS/a:/usr/bin" ]
}

@test "path_add: skips folders that don't exist" {
	with_path_add "/usr/bin" "path_add '$DIRS/missing'; path_add '$DIRS/missing' --prepend"
	[ "$output" = "/usr/bin" ]
}

@test "path_add: doesn't add a folder that's already there, in either position" {
	with_path_add "$DIRS/a:/usr/bin:$DIRS/b" "path_add '$DIRS/a'; path_add '$DIRS/b' --prepend; path_add '$DIRS/a' --prepend"
	[ "$output" = "$DIRS/a:/usr/bin:$DIRS/b" ]
}

@test "path_add: a folder whose name starts the same as one already there still gets added" {
	mkdir -p "$DIRS/bin"
	with_path_add "/usr/bin:$DIRS/bin2" "path_add '$DIRS/bin'"
	[ "$output" = "/usr/bin:$DIRS/bin2:$DIRS/bin" ]
}

@test "path_add: handles folders with spaces" {
	with_path_add "/usr/bin" "path_add '$DIRS/with space'; path_add '$DIRS/with space'"
	[ "$output" = "/usr/bin:$DIRS/with space" ]
}

#   -------------------------------
#   Homebrew
#   -------------------------------

homebrew_setup() { piece '^if \[ -z "\${HOMEBREW_PREFIX:-}" \]; then' '^fi'; }

@test "Homebrew: skipped when HOMEBREW_PREFIX is already set (e.g. by ~/.zprofile)" {
	code="$(homebrew_setup)"
	run env HOMEBREW_PREFIX=/already/set PATH=/usr/bin:/bin bash -c "$code"$'\n''printf "%s\n" "$PATH"'
	[ "$output" = "/usr/bin:/bin" ]
}

@test "Homebrew: puts its bin first, and reloading doesn't add it twice" {
	brew=""
	for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do  # path-check: ignore (Homebrew's fixed Linux location)
		[ -x "$candidate" ] && brew="$candidate" && break
	done
	[ -n "$brew" ] || skip "Homebrew isn't installed"
	bin_dir="$(dirname "$brew")"

	code="$(homebrew_setup)"
	run env -u HOMEBREW_PREFIX PATH=/usr/bin:/bin bash -c "$code"$'\n'"$code"$'\n''printf "%s\n" "$PATH"'
	[ "$status" -eq 0 ]
	[ "${output%%:*}" = "$bin_dir" ]
	[ "$(printf '%s\n' "$output" | tr ':' '\n' | grep -cxF "$bin_dir")" -eq 1 ]
}

#   -------------------------------
#   path_front
#   -------------------------------

# with_path_front <PATH> <commands>: Like with_path_add, for path_front
with_path_front() {
	local definition
	definition="$(piece '^path_front () {' '^}')" || return 1
	run bash -c "$definition"$'\n''PATH="$1"; eval "$2"; printf "%s\n" "$PATH"' _ "$1" "$2"
}

@test "path_front: moves a folder that is already later in PATH to the start" {
	with_path_front "/usr/bin:$DIRS/a:/bin" "path_front '$DIRS/a'"
	[ "$output" = "$DIRS/a:/usr/bin:/bin" ]
}

@test "path_front: adds a folder that isn't in PATH to the start" {
	with_path_front "/usr/bin" "path_front '$DIRS/a'"
	[ "$output" = "$DIRS/a:/usr/bin" ]
}

@test "path_front: leaves a folder already at the start where it is, without duplicating it" {
	with_path_front "$DIRS/a:/usr/bin" "path_front '$DIRS/a'"
	[ "$output" = "$DIRS/a:/usr/bin" ]
}

@test "path_front: ignores a folder that doesn't exist" {
	with_path_front "/usr/bin" "path_front '$DIRS/nope'"
	[ "$output" = "/usr/bin" ]
}
