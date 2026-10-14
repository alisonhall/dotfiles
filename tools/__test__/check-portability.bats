#!/usr/bin/env bats
# Tests for tools/check-portability.sh, which catches things that work on one OS but not another.
# File names Windows can't create are added to git's index only, so these tests run on Windows too.

load fixture

@test "passes on portable files" {
	add_executable bin/tool '#!/usr/bin/env bash' 'cd "$HOME/projects" || exit' 'dir=$HOME'
	add shell/common/a.sh '[ -d /Applications/Thing.app ] && echo yes'
	add shell/os/mac.sh 'open -a /Applications/Thing.app'
	check portability
	[ "$status" -eq 0 ]
}

#   -------------------------------
#   File names
#   -------------------------------

@test "flags file names with characters Windows doesn't allow" {
	add_index_only 'notes/what?.md'
	add_index_only 'notes/a:b.md'
	check portability
	[ "$status" -ne 0 ]
	[[ "$output" == *"File names Windows can't check out"* ]] || false
	[[ "$output" == *'notes/what?.md'* ]] || false
	[[ "$output" == *'notes/a:b.md'* ]] || false
}

@test "flags reserved Windows names, even with an extension, and names ending in a dot" {
	add_index_only 'CON.md'
	add_index_only 'docs/aux.txt'
	add_index_only 'file.'
	check portability
	[[ "$output" == *'CON.md  ("CON.md" is a reserved name on Windows)'* ]] || false
	[[ "$output" == *'docs/aux.txt'*'reserved name'* ]] || false
	[[ "$output" == *'file.  ("file." ends in a space or dot)'* ]] || false
}

@test "flags names that differ only in case" {
	add_index_only 'README.md'
	add_index_only 'Readme.md'
	check portability
	[ "$status" -ne 0 ]
	[[ "$output" == *"differ only in case"* ]] || false
}

@test "flags paths over 200 characters" {
	add_index_only "$(printf 'a%.0s' {1..200})/b.md"
	check portability
	[[ "$output" == *"Windows' 260-character limit"* ]] || false
}

@test "flags symlinks" {
	add_index_only 'shell/link.sh' 120000
	check portability
	[[ "$output" == *"Symlinks"*"shell/link.sh"* ]] || false
}

@test "flags a script with #! that isn't executable, and an executable file without #!" {
	add bin/not-executable '#!/usr/bin/env bash' 'echo hi'
	add_executable bin/no-shebang 'echo hi'
	check portability
	[ "$status" -ne 0 ]
	[[ "$output" == *"bin/not-executable  (has a #! line but isn't executable"* ]] || false
	[[ "$output" == *"bin/no-shebang  (is executable but has no #! line"* ]] || false
}

#   -------------------------------
#   Code
#   -------------------------------

@test "flags unquoted path variables, including in alias bodies" {
	add shell/common/a.sh 'cd $HOME/projects' "alias proj='cd \$DOTFILES/projects'"
	check portability
	[ "$status" -ne 0 ]
	[[ "$output" == *"Unquoted path variables"* ]] || false
	[[ "$output" == *"shell/common/a.sh:1:"* ]] || false
	[[ "$output" == *"shell/common/a.sh:2:"* ]] || false
}

@test "doesn't flag quoted path variables, assignments, [[ ]] or heredocs" {
	add shell/common/a.sh \
		'cd "$HOME/projects"' \
		'dir=$HOME/projects' \
		'[[ -d $HOME/projects ]] && echo yes' \
		'cat <<EOF' 'Your home is $HOME' 'EOF'
	check portability
	[ "$status" -eq 0 ]
}

@test "flags Windows paths with backslashes" {
	add shell/os/windows.sh 'cd C:\Program Files\Thing'
	check portability
	[[ "$output" == *"Windows paths with backslashes"* ]] || false
}

@test "flags macOS- and Windows-only paths outside shell/os/ without a check" {
	add shell/common/a.sh 'open /Applications/Thing.app' 'cd "/c/Program Files/Thing"'
	check portability
	[ "$status" -ne 0 ]
	[[ "$output" == *"OS-specific paths outside shell/os/"* ]] || false
	[[ "$output" == *"(macOS only)"* ]] || false
	[[ "$output" == *"(Windows only)"* ]] || false
}

@test "doesn't mistake printf's %s%s for a Windows %VAR% path" {
	add shell/common/a.sh "printf '%sYES%s (%s)\\n' \"\$C_GREEN\" \"\$C_RESET\" \"\$reason\""
	check portability
	[ "$status" -eq 0 ]
}

@test "allows a line marked path-check: ignore" {
	add shell/common/a.sh 'cd $HOME/projects  # path-check: ignore'
	check portability
	[ "$status" -eq 0 ]
}
