#!/usr/bin/env bats
# Tests for tools/check-blocklist.sh, which keeps the strings in local/dotfiles_blocklist out of the
# staged files and the commit message.

load fixture

# blocklist <line>...: Write the fixture repo's local/dotfiles_blocklist (not staged - local/ is
# never part of the repo)
blocklist() {
	mkdir -p "$FIX/local"
	printf '%s\n' "$@" > "$FIX/local/dotfiles_blocklist"
}

# message <line>...: Write a commit message file, and print its path
message() {
	printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/COMMIT_EDITMSG"
	echo "$BATS_TEST_TMPDIR/COMMIT_EDITMSG"
}

@test "passes with no blocklist, and says so" {
	add notes.md 'jane@example.com'
	check blocklist
	[ "$status" -eq 0 ]
	[[ "$output" == *"missing or empty"* ]] || false
}

@test "flags a listed string in a staged file, ignoring case, and says where" {
	blocklist 'jane@example.com'
	add notes.md 'ok' 'mail JANE@Example.com'
	check blocklist
	[ "$status" -ne 0 ]
	[[ "$output" == *"in staged files:"* ]] || false
	[[ "$output" == *"notes.md:2:mail JANE@Example.com"* ]] || false
}

@test "skips comments and blank lines in the blocklist, and Windows line endings" {
	printf '# Acme\r\n\r\nacme-corp\r\n' > "$BATS_TEST_TMPDIR/list"
	mkdir -p "$FIX/local"
	cp "$BATS_TEST_TMPDIR/list" "$FIX/local/dotfiles_blocklist"
	add notes.md 'Acme makes things' 'and # too'
	check blocklist
	[ "$status" -eq 0 ]
	add notes.md 'works at acme-corp'
	check blocklist
	[ "$status" -ne 0 ]
}

@test "only checks staged changes, not files that aren't staged" {
	blocklist 'jane@example.com'
	add notes.md 'ok'
	echo 'jane@example.com' > "$FIX/notes.md"
	check blocklist
	[ "$status" -eq 0 ]
}

@test "allows this repo's own GitHub URL, though it has a blocked owner name in it" {
	blocklist 'janedoe'
	git -C "$FIX" remote add origin git@github.com:janedoe/dotfiles.git
	add README.md 'See https://github.com/janedoe/dotfiles/actions'
	check blocklist
	[ "$status" -eq 0 ]
	# But not a longer repo name, or the name somewhere else on the line
	add README.md 'See https://github.com/janedoe/dotfiles-old'
	check blocklist
	[ "$status" -ne 0 ]
	add README.md 'https://github.com/janedoe/dotfiles by janedoe'
	check blocklist
	[ "$status" -ne 0 ]
}

@test "a re: line is a regular expression, matched ignoring case" {
	blocklist 're:PROJ-[0-9]{4,}'
	add notes.md 'ticket PROJ-12 is fine'
	check blocklist
	[ "$status" -eq 0 ]
	add notes.md 'branch me/proj-56789/fix'
	check blocklist
	[ "$status" -ne 0 ]
	[[ "$output" == *"notes.md:1:branch me/proj-56789/fix"* ]] || false
}

@test "plain lines are text, even with regex characters in them" {
	blocklist 'a.b+c'
	add notes.md 'axb+c and aab'
	check blocklist
	[ "$status" -eq 0 ]
	add notes.md 'see a.b+c'
	check blocklist
	[ "$status" -ne 0 ]
}

@test "a regular expression that isn't valid fails, and says which" {
	blocklist 'fine' 're:PROJ-[0-9'
	add notes.md 'nothing here'
	check blocklist
	[ "$status" -ne 0 ]
	[[ "$output" == *"isn't valid: re:PROJ-[0-9"* ]] || false
}

@test "uses ~/.dotfiles_blocklist when local/ has none" {
	printf 'jane@example.com\n' > "$HOME/.dotfiles_blocklist"
	add notes.md 'jane@example.com'
	check blocklist
	[ "$status" -ne 0 ]
	[[ "$output" == *"$HOME/.dotfiles_blocklist"* ]] || false
}

@test "--message flags a blocked string in the commit message, with its line" {
	blocklist 'acme' 're:PROJ-[0-9]{4,}'
	check blocklist --message "$(message 'Fix wt' '' 'Seen in ACME-wt cd me/PROJ-1234/x')"
	[ "$status" -ne 0 ]
	[[ "$output" == *"in the commit message:"* ]] || false
	[[ "$output" == *"commit message:3:Seen in ACME-wt cd me/PROJ-1234/x"* ]] || false
}

@test "--message skips comment lines, and the diff below git commit -v's scissors line" {
	blocklist 'acme'
	check blocklist --message "$(message 'Fix wt' '# acme in a comment' \
		'# ------------------------ >8 ------------------------' '+acme in the diff')"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "--message takes a path relative to where it's run from, as git passes it" {
	blocklist 'acme'
	mkdir -p "$BATS_TEST_TMPDIR/work"
	printf 'about acme\n' > "$BATS_TEST_TMPDIR/work/MSG"
	run bash -c 'cd "$1" && bash "$2/tools/check-blocklist.sh" --message MSG' _ "$BATS_TEST_TMPDIR/work" "$FIX"
	[ "$status" -ne 0 ]
}

@test "the commit-msg hook stops a commit whose message has a blocked string, and keeps the message" {
	blocklist 'acme'
	mkdir -p "$FIX/.githooks"
	cp "$REPO/.githooks/commit-msg" "$FIX/.githooks/"
	git -C "$FIX" config core.hooksPath .githooks
	git -C "$FIX" config user.name Test
	git -C "$FIX" config user.email test@example.com
	add notes.md 'ok'
	run git -C "$FIX" commit -q -m 'Use acme-wt'
	[ "$status" -ne 0 ]
	[[ "$output" == *"commit-msg: reword the message"* ]] || false
	[ -z "$(git -C "$FIX" rev-list --all)" ]
	run git -C "$FIX" commit -q -m 'Use shop-wt'
	[ "$status" -eq 0 ]
}
