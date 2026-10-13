#!/usr/bin/env bats
# Tests for tools/check-paths.sh, which keeps machine-specific paths out of the repo.
# The example home folders are built from pieces so this file doesn't trip the check itself.

load fixture

users="/Users"
home="/home"
windows_users="C:/Users"

@test "passes when paths go through \$HOME and \$DOTFILES" {
	add bin/tool.sh '#!/usr/bin/env bash' 'cd "$HOME/projects"' '"$DOTFILES/bin/tool.sh"'
	check paths
	[ "$status" -eq 0 ]
}

@test "flags this repo's own location" {
	add shell/common.sh "source \"$FIX/shell/extra.sh\""
	check paths
	[ "$status" -ne 0 ]
	[[ "$output" == *"This repo's location is hard-coded"* ]] || false
}

@test "flags absolute paths to the repo's own files" {
	add bin/tool.sh '#!/usr/bin/env bash' 'echo tool'
	add shell/common.sh 'alias t="~/dotfiles/bin/tool.sh"'
	check paths
	[ "$status" -ne 0 ]
	[[ "$output" == *"Absolute paths to files in this repo"* ]] || false
	[[ "$output" == *"shell/common.sh:1:"* ]] || false
}

@test "flags home folders with a user name in them (macOS, Linux and Windows forms)" {
	add shell/a.sh "cd $users/jane/projects"
	add shell/b.sh "cd $home/jane/projects"
	add shell/c.sh "cd $windows_users/jane/projects"
	check paths
	[ "$status" -ne 0 ]
	[[ "$output" == *"Hard-coded home folders"* ]] || false
	[[ "$output" == *"shell/a.sh:1:"* ]] || false
	[[ "$output" == *"shell/b.sh:1:"* ]] || false
	[[ "$output" == *"shell/c.sh:1:"* ]] || false
}

@test "allows a line marked path-check: ignore" {
	add shell/a.sh "cd $users/jane/projects  # path-check: ignore"
	check paths
	[ "$status" -eq 0 ]
}

@test "ignores comment lines and Markdown files" {
	add shell/a.sh "# e.g. $users/jane/projects"
	add README.md "Clone it to $users/jane/dotfiles"
	check paths
	[ "$status" -eq 0 ]
}
