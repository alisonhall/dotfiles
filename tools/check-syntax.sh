#!/usr/bin/env bash
#
# Syntax-checks this repo's shell files: `bash -n` for everything bash loads or runs, and
# `zsh -n` (if zsh is installed) for everything zsh loads. Also catches Windows (CRLF) line
# endings, which break scripts with errors like "$'\r': command not found".
#
# Used by install.sh, the pre-commit hook and the GitHub Actions tests.
# Prints each problem and exits non-zero if there are any.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

bash_files=(install.sh .githooks/pre-commit tools/*.sh shell/bashrc.sh shell/common.sh shell/common/*.sh shell/os/*.sh bin/*)
zsh_files=(shell/zshrc.sh shell/common.sh shell/common/*.sh shell/os/mac.sh config/p10k.zsh)
failed=0

check() {
	local shell="$1" file output
	shift
	for file in "$@"; do
		[ -f "$file" ] || continue
		if ! output="$("$shell" -n "$file" 2>&1)"; then
			echo "  $shell syntax error in $file:"
			echo "$output" | sed 's/^/    /'
			failed=$((failed + 1))
		fi
	done
}

check bash "${bash_files[@]}"
if command -v zsh >/dev/null 2>&1; then
	check zsh "${zsh_files[@]}"
fi

# Compares sizes with and without carriage returns, because grep can't be trusted to find
# them everywhere (Git for Windows' grep strips them before matching)
crlf_files="$(
	for file in "${bash_files[@]}" "${zsh_files[@]}"; do
		[ -f "$file" ] || continue
		[ "$(tr -d '\r' < "$file" | wc -c)" -ne "$(wc -c < "$file")" ] && echo "$file"
	done | sort -u
)"
if [ -n "$crlf_files" ]; then
	echo "  Windows (CRLF) line endings in:"
	echo "$crlf_files" | sed 's/^/    /'
	echo "    Convert them to LF (e.g. click 'CRLF' in VS Code's status bar), or re-clone the repo."
	failed=$((failed + 1))
fi

exit $failed
