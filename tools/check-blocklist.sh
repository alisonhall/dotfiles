#!/usr/bin/env bash
#
# Checks for personal strings - your emails, employer, hostnames and the like - listed in
# local/dotfiles_blocklist (or ~/.dotfiles_blocklist), since this repo is public.
#
#   tools/check-blocklist.sh                   the staged files (used by the pre-commit hook)
#   tools/check-blocklist.sh --message <file>  a commit message (used by the commit-msg hook)
#
# The blocklist has one entry per line, matched anywhere in a line and ignoring case. Blank lines
# and lines starting with # are skipped. A line starting with re: is an extended regular expression
# rather than plain text - e.g. re:PROJ-[0-9]{4,} for every ticket number like PROJ-1234.
#
# Links to this repo on GitHub (from its origin remote) are allowed, even though they contain the
# owner's name.
#
# Prints each match and exits non-zero if there are any, or if a regular expression isn't valid.
# With no blocklist, or an empty one, it says so (for the staged files) and passes.

message=""
if [ "${1:-}" = --message ]; then
	if [ -z "${2:-}" ]; then
		echo "usage: $0 [--message <file>]" >&2
		exit 2
	fi
	# (Relative to where it was run from, which the cd below changes)
	case "$2" in
		/* | [A-Za-z]:*) message="$2" ;;
		*) message="$PWD/$2" ;;
	esac
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

blocklist="$(pwd)/local/dotfiles_blocklist"
[ -f "$blocklist" ] || blocklist="$HOME/.dotfiles_blocklist"

fixed=()
regexes=()
failed=0
if [ -f "$blocklist" ]; then
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%$'\r'}"
		case "$line" in
			'' | '#'*) ;;
			re:*)
				re="${line#re:}"
				# ([[ =~ ]] returns 2 for a regular expression it can't read)
				[[ "" =~ $re ]]
				if [ $? -eq 2 ] || [ -z "$re" ]; then
					echo "$blocklist has a regular expression that isn't valid: $line" >&2
					failed=1
				else
					regexes+=("$re")
				fi
				;;
			*) fixed+=("$line") ;;
		esac
	done < "$blocklist"
fi

if [ ${#fixed[@]} -eq 0 ] && [ ${#regexes[@]} -eq 0 ]; then
	if [ -z "$message" ]; then
		echo "WARNING - $blocklist is missing or empty, so personal strings (emails, employer" >&2
		echo "  names...) aren't being checked. Copy it from another machine or add your own." >&2
	fi
	exit "$failed"
fi

# Lines that might have a blocked string in them, as <where>:<line number>:<text>
if [ -n "$message" ]; then
	# Skipping comments, and everything below the line `git commit -v` adds above the diff
	comment="$(git config core.commentChar 2>/dev/null)"
	case "$comment" in '' | auto) comment='#' ;; esac
	candidates="$(COMMENT="$comment" awk '
		BEGIN { c = ENVIRON["COMMENT"] }
		{ sub(/\r$/, "") }
		$0 == c " ------------------------ >8 ------------------------" { exit }
		substr($0, 1, length(c)) == c { next }
		{ print "commit message:" NR ":" $0 }' "$message")"
else
	fixed_args=()
	regex_args=()
	for entry in "${fixed[@]}"; do fixed_args+=(-e "$entry"); done
	for entry in "${regexes[@]}"; do regex_args+=(-e "$entry"); done
	candidates="$(
		[ ${#fixed_args[@]} -eq 0 ] || git grep --cached -I -n -i -F "${fixed_args[@]}"
		[ ${#regex_args[@]} -eq 0 ] || git grep --cached -I -n -i -E "${regex_args[@]}"
	)"
	candidates="$(printf '%s\n' "$candidates" | sort -t: -k1,1 -k2,2n -u)"
fi

# This repo's own GitHub URL (github.com/<owner>/<repo>) is already public, so it's allowed even when
# the owner's name is blocked: take it out of each line's text (unless it runs on into a longer name,
# like dotfiles-old), and check what's left. The text goes first, then the line as it was.
repo_url="$(git remote get-url origin 2>/dev/null | sed -nE 's#/$##; s#\.git$##; s#^.*github\.com[:/]([^/]+/[^/]+)$#github.com/\1#p')"
if ! without_url="$(printf '%s\n' "$candidates" | REPO_URL="$repo_url" LC_ALL=C awk '
	BEGIN { url = tolower(ENVIRON["REPO_URL"]) }
	$0 != "" {
		first = index($0, ":"); second = index(substr($0, first + 1), ":")
		text = substr($0, first + second + 1); lower = tolower(text); kept = ""
		while (url != "" && (i = index(lower, url)) > 0) {
			end = i + length(url)
			kept = kept substr(text, 1, substr(lower, end, 1) ~ /[a-z0-9_-]/ ? end - 1 : i - 1)
			text = substr(text, end); lower = substr(lower, end)
		}
		printf "%s\037%s\n", kept text, $0
	}')"; then
	# If awk fails, check the whole of every line
	without_url=""
	while IFS= read -r line; do
		without_url+="$line"$'\037'"$line"$'\n'
	done <<<"$candidates"
fi

# (In bash rather than one grep per line: Git Bash's grep can crash there, which would read as "no match")
shopt -s nocasematch
found=""
while IFS=$'\037' read -r text line; do
	[ -n "$line" ] || continue
	hit=0
	for entry in "${fixed[@]}"; do
		if [[ $text == *"$entry"* ]]; then hit=1; break; fi
	done
	if [ "$hit" = 0 ]; then
		for entry in "${regexes[@]}"; do
			if [[ $text =~ $entry ]]; then hit=1; break; fi
		done
	fi
	[ "$hit" = 0 ] || found+="$line"$'\n'
done <<<"$without_url"

if [ -n "$found" ]; then
	echo "Found strings from $blocklist in $([ -n "$message" ] && echo "the commit message" || echo "staged files"):" >&2
	printf '%s' "$found" >&2
	failed=1
fi
exit "$failed"
