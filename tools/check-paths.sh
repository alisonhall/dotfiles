#!/usr/bin/env bash
#
# Checks that nothing in the repo depends on where the repo (or your home folder) is, so
# it works wherever it's cloned and whatever it's called. Files in the repo should be
# referred to through $DOTFILES, or relative to the script that uses them.
#
# Flags:
#   1. This checkout's own location, in any form (e.g. /d/Code/my-dotfiles, D:\Code\my-dotfiles)
#   2. Absolute paths to files in this repo, e.g. ~/dotfiles/bin/timestamps.sh
#      -> use "$DOTFILES/bin/timestamps.sh"
#   3. Hard-coded home folders, e.g. /Users/me or C:\Users\me -> use $HOME or ~
#
# Markdown files are skipped for 2 and 3, since docs show example paths on purpose.
# To allow a line anyway, add a comment to it containing: path-check: ignore
#
# Used by the pre-commit hook and the GitHub Actions tests.
# Prints each problem and exits non-zero if there are any.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
repo="$(pwd)"
failed=0

# The repo's files: tracked ones (including newly staged), or everything if this isn't a git clone
files=()
while IFS= read -r file; do
	[ -f "$file" ] && files+=("$file")
done < <(git ls-files 2>/dev/null || find . -type f -not -path './.git/*' | sed 's|^\./||')
[ ${#files[@]} -gt 0 ] || exit 0

code_files=()
for file in "${files[@]}"; do
	case "$file" in
		*.md) ;;
		*) code_files+=("$file") ;;
	esac
done

# Drops comment-only lines from search output (file:line:text) - example paths there don't break anything
without_comments() {
	grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
}

# search <grep options and pattern...> -- <files...>: matching lines as file:line:text, minus ignored ones
search() {
	local args=()
	while [ "$1" != -- ]; do
		args+=("$1")
		shift
	done
	shift
	[ $# -gt 0 ] || return 0
	grep -I -H -n "${args[@]}" -- "$@" 2>/dev/null | grep -v 'path-check: ignore'
}

# report <description> <matches>
report() {
	[ -n "$2" ] || return 0
	echo "  $1"
	printf '%s\n' "$2" | cut -c1-200 | sed 's/^/    /'
	failed=$((failed + 1))
}

# 1. This checkout's location (plus its Windows forms on Windows), ignoring case because Windows
# paths aren't case-sensitive. (awk, because Git for Windows' grep crashes with -i -F.)
locations="$repo"
if command -v cygpath >/dev/null 2>&1; then
	locations="$locations"$'\n'"$(cygpath -m "$repo")"$'\n'"$(cygpath -w "$repo")"
fi
text_files=()
while IFS= read -r file; do
	text_files+=("$file")
done < <(grep -I -l '' -- "${files[@]}" 2>/dev/null)
report "This repo's location is hard-coded - use \$DOTFILES or a relative path:" \
	"$(LOCATIONS="$locations" awk '
		BEGIN { count = split(tolower(ENVIRON["LOCATIONS"]), locations, "\n") }
		/path-check: ignore/ { next }
		{
			line = tolower($0)
			for (i = 1; i <= count; i++) {
				if (index(line, locations[i])) { print FILENAME ":" FNR ":" $0; next }
			}
		}' "${text_files[@]}")"

# 2. Absolute paths that end in one of the repo's own files, with / or \ between folders.
# A path starts with ~/ or a single / (not // as in URLs) and has no spaces - otherwise
# `/bin/bash ./install.sh` would look like one path - or starts with a drive letter, where
# spaces are allowed because Windows paths often have them.
escaped_files="$(printf '%s\n' "${files[@]}" | sed -e 's/[][\.*^$+?(){}|]/\\&/g' -e 's|/|[\\/]|g' | paste -sd '|' -)"
report "Absolute paths to files in this repo - use \"\$DOTFILES/...\" instead:" \
	"$(search -E "(^|[[:space:]\"'=(:])((~/|/[^/[:space:]])[^[:space:]\"'\$]*|[A-Za-z]:[\\/][^\"'\$]*)[\\/]($escaped_files)([^A-Za-z0-9_.-]|\$)" -- "${code_files[@]}" | without_comments)"

# 3. Home folders with a literal user name
report "Hard-coded home folders - use \$HOME or ~ instead:" \
	"$(search -E "(^|[^A-Za-z0-9_])(/Users|/home|/[A-Za-z]/Users)/[A-Za-z0-9._-]+|[A-Za-z]:[\\/]{1,2}Users[\\/]{1,2}[A-Za-z0-9._-]+" -- "${code_files[@]}" | without_comments)"

if [ "$failed" -gt 0 ]; then
	echo "    (If one of these is intentional, add a comment containing 'path-check: ignore' to that line.)"
fi
exit $failed
