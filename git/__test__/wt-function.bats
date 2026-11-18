#!/usr/bin/env bats
# Tests for the wt shell function, and where the commands work: the layout they're run in (git/wt/), against a local "GitHub" repo and a fake gh.

load wt-fixture

setup() {
	wt_fixture_setup
}

#   -------------------------------
#   THE WT FUNCTION
#   -------------------------------

@test "the wt function moves into the folder wt add made beside main, not the settings' location" {
	run bash -c 'export WT_WORKTREE_REPO_LOCATION="$2/other"; cd "$3" && . "$1/wt.sh" && wt add feature/new >/dev/null && pwd' _ "$WT" "$BATS_TEST_TMPDIR" "$MAIN"
	[ "$status" -eq 0 ]
	[ "${lines[$((${#lines[@]} - 1))]}" -ef "$BATS_TEST_TMPDIR/repo/feature_new" ]
}

@test "zsh's wt does the same" {
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed"
	run zsh -f -c 'export WT_WORKTREE_REPO_LOCATION="$2/other"; cd "$3" && source "$1/wt.sh" && wt add feature/new >/dev/null && pwd' _ "$WT" "$BATS_TEST_TMPDIR" "$MAIN"
	[ "$status" -eq 0 ]
	[ "${lines[$((${#lines[@]} - 1))]}" -ef "$BATS_TEST_TMPDIR/repo/feature_new" ]
}

@test "wt main says so when WT_WORKTREE_REPO_LOCATION isn't set" {
	run bash -c 'unset WT_WORKTREE_REPO_LOCATION; . "$1/wt.sh" && wt main' _ "$WT"
	[ "$status" -eq 2 ]
	[[ "$output" == *"WT_WORKTREE_REPO_LOCATION is not set"* ]] || false
}

@test "wt cd with no branch asks for one, and takes a name with & as it is" {
	git -C "$MAIN" push -q origin 'main:refs/heads/feature/fix-a&b' 2>/dev/null
	run bash -c '. "$1/wt.sh" && wt cd <<< "feature/fix-a&b" >/dev/null && pwd && git branch --show-current' _ "$WT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Branch name: "* ]] || false
	[ "${lines[$((${#lines[@]} - 2))]}" -ef "$WT_WORKTREE_REPO_LOCATION/feature_fix-a&b" ]
	[ "${lines[$((${#lines[@]} - 1))]}" = 'feature/fix-a&b' ]
	[ "$(git -C "$WT_WORKTREE_REPO_LOCATION/feature_fix-a&b" rev-parse --abbrev-ref '@{upstream}')" = 'origin/feature/fix-a&b' ]
}

@test "wt cd split at an unquoted & stops, rather than making the branch before the &" {
	# What bash does with `wt cd feature/fix-a&b`: runs `wt cd feature/fix-a` in the background
	run bash -c '. "$1/wt.sh"; wt cd feature/fix-a&b 2>&1; wait' _ "$WT"
	[[ "$output" == *"wt cd: this ran in the background or a subshell"* ]] || false
	[[ "$output" == *"paste the name when it asks"* ]] || false
	[ "$(ls "$WT_WORKTREE_REPO_LOCATION")" = main ]
	run git -C "$MAIN" show-ref --verify --quiet refs/heads/feature/fix-a
	[ "$status" -ne 0 ]
}

@test "zsh's wt stops in the background too" {
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed"
	run zsh -f -c 'source "$1/wt.sh"; wt add feature/fix-a 2>&1 & wait' _ "$WT"
	[[ "$output" == *"wt add: this ran in the background or a subshell"* ]] || false
	[ "$(ls "$WT_WORKTREE_REPO_LOCATION")" = main ]
}

@test "the wt function moves into the branch's folder after wt add --strict, and asks for the branch with only the option" {
	git -C "$MAIN" push -q origin main:refs/heads/feature/a main:refs/heads/feature/b 2>/dev/null
	run bash -c '. "$1/wt.sh" && wt add --strict feature/a >/dev/null && pwd' _ "$WT"
	[ "$status" -eq 0 ]
	[ "${lines[$((${#lines[@]} - 1))]}" -ef "$WT_WORKTREE_REPO_LOCATION/feature_a" ]
	run bash -c '. "$1/wt.sh" && wt add --strict <<< feature/b >/dev/null && pwd' _ "$WT"
	[ "$status" -eq 0 ]
	[ "${lines[$((${#lines[@]} - 1))]}" -ef "$WT_WORKTREE_REPO_LOCATION/feature_b" ]
	# Refused, it stays where it was, and gives the script's exit code (3: not on the remote), as a
	# tool running it in an interactive shell gets the function, not the script
	run bash -c 'cd "$2" && . "$1/wt.sh"; wt add --strict feature/typo 2>/dev/null; echo "status:$?"; pwd' _ "$WT" "$BATS_TEST_TMPDIR"
	[ "${lines[$((${#lines[@]} - 2))]}" = "status:3" ]
	[ "${lines[$((${#lines[@]} - 1))]}" -ef "$BATS_TEST_TMPDIR" ]
}

@test "zsh's wt gives the script's exit code too" {
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed"
	run zsh -f -c 'cd "$2" && source "$1/wt.sh"; wt add --strict feature/typo 2>/dev/null; echo "status:$?"' _ "$WT" "$BATS_TEST_TMPDIR"
	[ "${lines[$((${#lines[@]} - 1))]}" = "status:3" ]
}

@test "the wt function moves into the folder wt add --pr made, without asking for a branch" {
	fork_pr 13 >/dev/null
	git -C "$MAIN" push -q origin main:refs/heads/feature/a 2>/dev/null
	export FAKE_PRS="13:true:main:feature/a 12:false:main:feature/a"
	run bash -c '. "$1/wt.sh" && wt add --pr 13 </dev/null >/dev/null && pwd' _ "$WT"
	[ "$status" -eq 0 ]
	[ "${lines[$((${#lines[@]} - 1))]}" -ef "$WT_WORKTREE_REPO_LOCATION/pr-13" ]
	run bash -c '. "$1/wt.sh" && wt add --pr 12 </dev/null >/dev/null && pwd' _ "$WT"
	[ "$status" -eq 0 ]
	[ "${lines[$((${#lines[@]} - 1))]}" -ef "$WT_WORKTREE_REPO_LOCATION/feature_a" ]
	# Refused, it stays where it was, with the script's exit code
	run bash -c 'cd "$2" && . "$1/wt.sh"; wt add --pr 99 </dev/null 2>/dev/null; echo "status:$?"; pwd' _ "$WT" "$BATS_TEST_TMPDIR"
	[ "${lines[$((${#lines[@]} - 2))]}" = "status:3" ]
	[ "${lines[$((${#lines[@]} - 1))]}" -ef "$BATS_TEST_TMPDIR" ]
}

@test "zsh's wt moves into the folder wt add --pr made too" {
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed"
	fork_pr 13 >/dev/null
	export FAKE_PRS="13:true:main:feature/a"
	run zsh -f -c 'source "$1/wt.sh" && wt add --pr 13 </dev/null >/dev/null && pwd' _ "$WT"
	[ "$status" -eq 0 ]
	[ "${lines[$((${#lines[@]} - 1))]}" -ef "$WT_WORKTREE_REPO_LOCATION/pr-13" ]
}

@test "the wt function doesn't ask for a branch when an option is wrong, but says so at once" {
	run bash -c '. "$1/wt.sh" && wt add --stirct <<< feature/a' _ "$WT"
	[ "$status" -eq 2 ]
	[[ "$output" != *"Branch name: "* ]] || false
	[[ "$output" == *"wt-add: unknown option --stirct"* ]] || false
	run bash -c '. "$1/wt.sh" && wt cd --strict <<< feature/a' _ "$WT"
	[ "$status" -eq 2 ]
	[[ "$output" != *"Branch name: "* ]] || false
	[[ "$output" == *"wt-cd: unknown option --strict"* ]] || false
	[ "$(ls "$WT_WORKTREE_REPO_LOCATION")" = main ]
}

@test "wt add with no branch asks for one, and stops if none is given" {
	run bash -c '. "$1/wt.sh" && wt add <<< ""' _ "$WT"
	[ "$status" -eq 2 ]
	[[ "$output" == *"wt add: no branch name was given"* ]] || false
	[ "$(ls "$WT_WORKTREE_REPO_LOCATION")" = main ]
}

@test "zsh's wt asks for a branch too" {
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed"
	git -C "$MAIN" push -q origin 'main:refs/heads/fix(a);b' 2>/dev/null
	run zsh -f -c 'source "$1/wt.sh" && wt cd <<< "fix(a);b" >/dev/null && git branch --show-current' _ "$WT"
	[ "$status" -eq 0 ]
	[ "${lines[${#lines[@]} - 1]}" = 'fix(a);b' ]
}

# quote_cases <shell>: Run _wt_quote_branch_arg in <shell> on each line below, printing
# "<line> => <REPLY>", or "<line> => unchanged"
quote_cases() {
	"$1" -c '. "$1/wt.sh"; shift
		for line in "$@"; do
			REPLY=""
			if _wt_quote_branch_arg "$line"; then echo "$line => $REPLY"; else echo "$line => unchanged"; fi
		done' _ "$WT" \
		'shop-wt cd yourname/TICKET-123/Login-&-Signup-Pages' \
		'wt add fix(a);b|c' \
		'shop-wt add --strict a&b' \
		'wt add --strict' \
		'wt cd --strict a&b' \
		'  shop-wt cd a&b  ' \
		'wt cd feature/plain-name_1.2' \
		"wt cd 'a&b'" \
		'wt cd "$branch"' \
		'wt cd a\&b' \
		'wt cd a && ls' \
		'wt rm a&b' \
		'wt-x cd a&b' \
		'git cd a&b' \
		'-wt cd a&b' \
		$'wt cd a&b\nls'
}

QUOTE_EXPECTED="shop-wt cd yourname/TICKET-123/Login-&-Signup-Pages => shop-wt cd 'yourname/TICKET-123/Login-&-Signup-Pages'
wt add fix(a);b|c => wt add 'fix(a);b|c'
shop-wt add --strict a&b => shop-wt add --strict 'a&b'
wt add --strict => unchanged
wt cd --strict a&b => unchanged
  shop-wt cd a&b   => shop-wt cd 'a&b'
wt cd feature/plain-name_1.2 => unchanged
wt cd 'a&b' => unchanged
wt cd \"\$branch\" => unchanged
wt cd a\\&b => unchanged
wt cd a && ls => unchanged
wt rm a&b => unchanged
wt-x cd a&b => unchanged
git cd a&b => unchanged
-wt cd a&b => unchanged
wt cd a&b
ls => unchanged"

@test "_wt_quote_branch_arg quotes just the branch name of a wt cd or add, and only when it needs it" {
	run quote_cases bash
	[ "$status" -eq 0 ]
	[ "$output" = "$QUOTE_EXPECTED" ] || { diff <(echo "$output") <(echo "$QUOTE_EXPECTED") >&2; false; }
}

@test "_wt_quote_branch_arg does the same in zsh" {
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed"
	run quote_cases zsh
	[ "$status" -eq 0 ]
	[ "$output" = "$QUOTE_EXPECTED" ] || { diff <(echo "$output") <(echo "$QUOTE_EXPECTED") >&2; false; }
}

@test "in an interactive zsh, a <name>-wt cd with an unquoted & reaches wt as one branch name" {
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed"
	zsh -fc 'zmodload zsh/zpty' 2>/dev/null || skip "zsh has no zpty module"
	export OUT="$BATS_TEST_TMPDIR/args"
	# Type the line into a real interactive zsh, through a pseudo-terminal, so Enter goes through
	# its line editor as it would for a person. shop-wt stands in for a per-repo command. Each line
	# is typed only once zsh shows a prompt, since what's typed while it starts can be dropped.
	run zsh -fc '
		zmodload zsh/zpty
		zpty t "zsh -fi"
		screen=""
		# wait_for <pattern>: Read what zsh shows until it matches <pattern>, for up to 10 seconds
		wait_for() {
			local chunk i
			for i in {1..100}; do
				while zpty -rt t chunk 2>/dev/null; do screen+=$chunk; done
				[[ $screen == $~1 ]] && return 0
				sleep 0.1
			done
			return 1
		}
		fail() { print -r -- "$1; the terminal showed:"; print -r -- "$screen"; zpty -d t; exit 1; }
		wait_for "*[%#]*" || fail "no first prompt"
		# (The new prompt is written in two parts, so that typing it doesn'"'"'t match it)
		screen=""
		zpty -w t "PS1=\"wt-\"\"ready> \"; source \"$1/wt.sh\"; shop-wt() { print -r -- \"[\$#] \$*\" > \"\$OUT\" }"
		wait_for "*wt-ready> *" || fail "no prompt after loading wt.sh"
		zpty -w t "shop-wt cd yourname/TICKET-123/Login-&-Signup-Pages"
		# Reading what zsh shows while waiting, as a terminal would: on macOS, a pseudo-terminal holds
		# so little that zsh stalls drawing the line, before running it, until someone reads it
		for i in {1..100}; do
			while zpty -rt t chunk 2>/dev/null; do screen+=$chunk; done
			[[ -s $OUT ]] && break
			sleep 0.1
		done
		[[ -s $OUT ]] || { wait_for "*wt-ready> *wt-ready> *"; fail "shop-wt wasn'"'"'t run"; }
		zpty -d t
		cat "$OUT"' _ "$WT"
	[ "$status" -eq 0 ] || { echo "$output" | cat -v >&2; false; }
	[ "$output" = "[2] cd yourname/TICKET-123/Login-&-Signup-Pages" ]
}

@test "zsh loads wt even with FUNCTION_ARGZERO off" {
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed"
	run zsh -f -c 'unsetopt function_argzero; source "$1/wt.sh" && whence -w wt && print -r -- "$WT_DIR"' _ "$WT"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "wt: function" ]
	[ "${lines[1]}" -ef "$WT" ]
}

@test "wt link with no branch fixes the branch folder it's run in, with nothing set" {
	bash "$WT/wt.sh" add feature/x >/dev/null 2>&1
	folder="$WT_WORKTREE_REPO_LOCATION/feature_x"
	rm "$folder/node_modules"
	unset WT_WORKTREE_REPO_LOCATION WT_REPO_SLUG
	mkdir -p "$folder/src"
	cd "$folder/src"
	run bash "$WT/wt.sh" link --no-workspaces
	[ "$status" -eq 0 ]
	[[ "$output" == *"Worktree: feature_x"* ]] || false
	[ "$folder/node_modules" -ef "$MAIN/node_modules" ]
}

@test "wt link given a branch's folder fixes it, from anywhere and with nothing set" {
	bash "$WT/wt.sh" add feature/x >/dev/null 2>&1
	bash "$WT/wt.sh" add feature/y >/dev/null 2>&1
	folder="$WT_WORKTREE_REPO_LOCATION/feature_x"
	rm "$folder/node_modules" "$WT_WORKTREE_REPO_LOCATION/feature_y/node_modules"
	export WT_WORKTREE_REPO_LOCATION="$BATS_TEST_TMPDIR/other"
	unset WT_REPO_SLUG
	cd "$BATS_TEST_TMPDIR"
	run bash "$WT/wt.sh" link --no-workspaces "$folder"
	[ "$status" -eq 0 ]
	[ "$folder/node_modules" -ef "$MAIN/node_modules" ]
	# Only that one
	[ ! -e "$BATS_TEST_TMPDIR/repo/feature_y/node_modules" ]
	# And as .
	cd "$BATS_TEST_TMPDIR/repo/feature_y"
	run bash "$WT/wt.sh" link --no-workspaces .
	[ "$status" -eq 0 ]
	[ "$BATS_TEST_TMPDIR/repo/feature_y/node_modules" -ef "$MAIN/node_modules" ]
}

@test "wt link says so for the main folder, or a folder that isn't a branch's" {
	cd "$MAIN"
	run bash "$WT/wt.sh" link --no-workspaces
	[ "$status" -eq 1 ]
	[[ "$output" == *"this is the main folder, which the links point at"* ]] || false
	cd "$BATS_TEST_TMPDIR"
	run bash "$WT/wt.sh" link --no-workspaces "$MAIN"
	[ "$status" -eq 1 ]
	[[ "$output" == *"is the main folder, which the links point at"* ]] || false
	mkdir "$BATS_TEST_TMPDIR/elsewhere"
	run bash "$WT/wt.sh" link --no-workspaces "$BATS_TEST_TMPDIR/elsewhere"
	[ "$status" -eq 1 ]
	[[ "$output" == *"isn't a branch's folder beside"* ]] || false
	# With nothing set, that's still what it says, not that the location isn't set
	unset WT_WORKTREE_REPO_LOCATION
	run bash "$WT/wt.sh" link --no-workspaces "$BATS_TEST_TMPDIR/elsewhere"
	[ "$status" -eq 1 ]
	[[ "$output" == *"isn't a branch's folder beside a main folder of the same repo"* ]] || false
	[[ "$output" != *"is not set"* ]] || false
}

@test "wt link -h works with nothing set, outside any layout" {
	unset WT_WORKTREE_REPO_LOCATION
	cd "$BATS_TEST_TMPDIR"
	run bash "$WT/wt.sh" link -h
	[ "$status" -eq 0 ]
	[[ "$output" == *"Usage:"* ]] || false
	[[ "$output" == *"wt-link <folder>"* ]] || false
}

@test "the commands run in a branch's folder work on its layout, whatever the settings say" {
	git -C "$MAIN" push -q origin main:refs/heads/feature/x 2>/dev/null
	bash "$WT/wt.sh" add feature/x >/dev/null 2>&1
	export WT_WORKTREE_REPO_LOCATION="$BATS_TEST_TMPDIR/other"
	unset WT_REPO_SLUG
	mkdir -p "$BATS_TEST_TMPDIR/repo/feature_x/src"
	cd "$BATS_TEST_TMPDIR/repo/feature_x/src"
	run bash "$WT/wt.sh" add feature/y
	[ "$status" -eq 0 ]
	[ -e "$BATS_TEST_TMPDIR/repo/feature_y/.git" ]
	run bash "$WT/wt.sh" ls --no-fetch
	[ "$status" -eq 0 ]
	[[ "$output" == *feature_y* ]] || false
	[ ! -e "$BATS_TEST_TMPDIR/other" ]
	# The function's wt main goes to its main
	run bash -c '. "$1/wt.sh" && wt main && echo "main at:$PWD"' _ "$WT"
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | sed -n 's/^main at://p')" -ef "$MAIN" ]
}

@test "the commands work in the bare-repo layout's branch folders too" {
	# fe/.bare with fe/main and fe/feature_x as its worktrees
	bare="$BATS_TEST_TMPDIR/fe"
	git clone -q --bare "$BATS_TEST_TMPDIR/origin.git" "$bare/.bare" 2>/dev/null
	git -C "$bare/.bare" worktree add -q "$bare/main" main 2>/dev/null
	git -C "$bare/.bare" worktree add -q -b feature/x "$bare/feature_x" main 2>/dev/null
	unset WT_WORKTREE_REPO_LOCATION WT_REPO_SLUG
	cd "$bare/feature_x"
	run bash "$WT/wt.sh" ls --no-fetch
	[ "$status" -eq 0 ]
	[[ "$output" == *feature_x* ]] || false
	[[ "$output" == *"2 worktree(s)"* ]] || false
}

@test "a branch folder beside another repo's main folder doesn't count as its layout" {
	git init -q "$BATS_TEST_TMPDIR/mixed/main"
	git -C "$BATS_TEST_TMPDIR/mixed/main" commit -q --allow-empty -m other
	git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/mixed/shop" 2>/dev/null
	unset WT_WORKTREE_REPO_LOCATION
	cd "$BATS_TEST_TMPDIR/mixed/shop"
	run bash "$WT/wt.sh" ls --no-fetch
	[ "$status" -eq 2 ]
	[[ "$output" == *"WT_WORKTREE_REPO_LOCATION is not set"* ]] || false
}

@test "wt link --all leaves out the main folder, whatever branch it holds" {
	git -C "$MAIN" switch -q -c develop
	bash "$WT/wt.sh" add feature/x >/dev/null 2>&1
	run bash "$WT/wt.sh" link --check --all --no-workspaces
	[ "$status" -eq 0 ]
	[[ "$output" == *"Worktree: feature_x"* ]] || false
	[[ "$output" != *"Worktree: main"* ]] || false
}
