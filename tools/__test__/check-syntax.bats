#!/usr/bin/env bats
# Tests for tools/check-syntax.sh, which syntax-checks the shell files with bash and zsh and
# catches Windows (CRLF) line endings.

load fixture

@test "passes on valid shell files" {
	add shell/common/a.sh 'greet () { echo "hi $1"; }'
	add_executable bin/tool '#!/usr/bin/env bash' 'echo ok'
	check syntax
	[ "$status" -eq 0 ]
}

@test "flags bash syntax errors in shared files and bin/ scripts" {
	add shell/common/a.sh 'if true; then echo missing-fi'
	add_executable bin/tool '#!/usr/bin/env bash' 'for x in; do'
	check syntax
	[ "$status" -ne 0 ]
	[[ "$output" == *"bash syntax error in shell/common/a.sh"* ]] || false
	[[ "$output" == *"bash syntax error in bin/tool"* ]] || false
}

@test "flags zsh syntax errors in files zsh loads" {
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed"
	add shell/zshrc.sh 'for code ({000..255}) print $code' 'if [[ -n x ]]; then'
	check syntax
	[ "$status" -ne 0 ]
	[[ "$output" == *"zsh syntax error in shell/zshrc.sh"* ]] || false
}

@test "doesn't check zsh-only files with bash" {
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed"
	add shell/zshrc.sh 'for code ({000..255}) print -P -- "%F{$code}colour%f"'
	check syntax
	[ "$status" -eq 0 ]
}

@test "flags Windows (CRLF) line endings" {
	mkdir -p "$FIX/shell/common"
	printf 'echo one\r\necho two\r\n' > "$FIX/shell/common/a.sh"
	git -C "$FIX" -c core.autocrlf=false add shell/common/a.sh
	check syntax
	[ "$status" -ne 0 ]
	[[ "$output" == *"Windows (CRLF) line endings in:"*"shell/common/a.sh"* ]] || false
}
