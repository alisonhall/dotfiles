#!/usr/bin/env bats
# Tests for tools/check-aliases.sh, which catches shell and git aliases that are broken or only
# work on some OSes.

load fixture

# gitconfig <line>...: Write git/gitconfig with these lines under [alias]
gitconfig() { add git/gitconfig '[alias]' "$@"; }

#   -------------------------------
#   Shell aliases and functions
#   -------------------------------

@test "passes on aliases and functions that work everywhere" {
	add shell/common/a.sh "alias ll='ls -la'" 'mcd () { mkdir -p "$1" && cd "$1"; }'
	gitconfig 'st = status -s' 'last = log -1' '	wip = "!f() { git commit -m WIP; }; f"'
	check aliases
	[ "$status" -eq 0 ]
}

@test "flags alias bodies with syntax errors" {
	add shell/common/a.sh "alias broken='echo \"unterminated'"
	check aliases
	[ "$status" -ne 0 ]
	[[ "$output" == *"Alias bodies with syntax errors"*"alias broken="* ]] || false
}

@test "flags double-quoted aliases that expand \$VAR when the shell starts" {
	add shell/common/a.sh 'alias here="cd $PWD"'
	check aliases
	[ "$status" -ne 0 ]
	[[ "$output" == *"Double-quoted aliases with \$"* ]] || false
}

@test "flags commands an OS doesn't have" {
	add shell/common/a.sh "alias copy='pbcopy'"
	check aliases
	[ "$status" -ne 0 ]
	[[ "$output" == *"Commands some OSes don't have"* ]] || false
	[[ "$output" == *"copy uses pbcopy - not on Linux, Windows (Git Bash)"* ]] || false
}

@test "accepts an OS-only command when shell/os/ has a replacement for each OS that lacks it" {
	add shell/common/a.sh "alias copy='pbcopy'"
	add shell/os/linux.sh 'pbcopy () { xclip -selection clipboard; }'
	add shell/os/windows.sh 'pbcopy () { clip.exe; }'
	check aliases
	[ "$status" -eq 0 ]
}

@test "flags options that only exist in the GNU or macOS version of a tool" {
	add shell/common/a.sh "alias fix='sed -i s/a/b/ file.txt'"
	add_executable bin/stamp '#!/usr/bin/env bash' 'date --utc +%F'
	check aliases
	[ "$status" -ne 0 ]
	[[ "$output" == *"Options that only work on some OSes"* ]] || false
	[[ "$output" == *"sed -i without a backup suffix fails on macOS"* ]] || false
	[[ "$output" == *"bin/stamp:2:"*"GNU-only date option"* ]] || false
}

@test "allows a line marked alias-check: ignore" {
	add shell/common/a.sh "alias copy='pbcopy'  # alias-check: ignore"
	check aliases
	[ "$status" -eq 0 ]
}

#   -------------------------------
#   Git aliases
#   -------------------------------

@test "checks every git alias, not just the first (macOS awk can't split on NUL)" {
	gitconfig 'st = status -s' '	multi = "!f() {\
		echo one; \
	}; f"' 'bad = git log'
	check aliases
	[ "$status" -ne 0 ]
	[[ "$output" == *'bad = git log  (runs `git git ...`'* ]] || false
}

@test "flags git aliases that start with git" {
	gitconfig 'st = git status'
	check aliases
	[ "$status" -ne 0 ]
	[[ "$output" == *'st = git status  (runs `git git ...`'* ]] || false
}

@test "flags git aliases named after a built-in command, which git ignores" {
	gitconfig 'status = status -s'
	check aliases
	[[ "$output" == *"status = status -s  (git ignores aliases named after built-in commands)"* ]] || false
}

@test "flags git aliases that run something that isn't a git command or alias" {
	gitconfig 'oops = notacommand --flag'
	check aliases
	[[ "$output" == *'oops = notacommand --flag  ("notacommand" isn'"'"'t a git command or alias)'* ]] || false
}

@test "flags git aliases that lead back to themselves" {
	gitconfig 'one = two' 'two = one'
	check aliases
	[[ "$output" == *"leads back to itself"* ]] || false
}

@test "flags ! git aliases with bash-only syntax, since git runs them with sh" {
	gitconfig '	same = "!f() { [[ 1 == 1 ]] && echo same; }; f"'
	check aliases
	[ "$status" -ne 0 ]
	[[ "$output" == *"Git ! aliases that fail in sh"*"bash-only syntax"* ]] || false
}

@test "flags ! git aliases using commands some OSes don't have" {
	gitconfig '	copy-branch = "!git branch --show-current | pbcopy"'
	check aliases
	[[ "$output" == *"copy-branch"*"uses pbcopy"* ]] || false
}
