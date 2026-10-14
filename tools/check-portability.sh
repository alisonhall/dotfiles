#!/usr/bin/env bash
#
# Checks for things that work on one OS but break on another (macOS, Linux, Windows/Git Bash).
#
# File names in the repo (from git's index, so problems are caught before anyone clones):
#   1. Names Windows can't create: < > : " | ? * \ or control characters, a name ending in a
#      space or ".", or a reserved name (CON, PRN, AUX, NUL, COM1-9, LPT1-9, even with an extension)
#   2. Names that differ only in case (README.md vs Readme.md) - macOS and Windows can't hold both
#   3. Paths over 200 characters, which can pass Windows' 260 limit once the clone's folder is added
#   4. Symlinks, which Windows usually checks out as small text files
#   5. Executable bits: scripts with a #! line must be executable (Windows doesn't track the bit,
#      so it's easy to lose), and executable files need a #! line
#
# Code:
#   6. Unquoted path variables ($HOME, $DOTFILES, $folderPath...) in code bash runs, including
#      alias bodies. They break on paths with spaces, which are common on Windows
#      (C:\Users\Jane Doe, C:\Program Files) and macOS (/Library/Application Support).
#   7. Windows paths with backslashes (C:\Users\...): bash treats \ as an escape. Use C:/Users/...,
#      which Git Bash and Windows programs both accept.
#   8. Mac-only (/Applications, /opt/homebrew...) or Windows-only (C:/..., /c/Users..., %VAR%) paths
#      outside shell/os/, unless the same line checks the OS or whether the path exists
#      (Darwin, MINGW, $DOTFILES_OS, [ -d ... ], path_add...), is a printf format string (where
#      %s%s-style sequences otherwise look like %VAR%), or it's in a `for ... in` list.
#
# To allow a line anyway, add a comment to it containing: path-check: ignore
#
# Used by the pre-commit hook and the GitHub Actions tests.
# Prints each problem and exits non-zero if there are any.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
failed=0

# Kept as their authors wrote them
third_party=(bin/git-branch-status)

# report <description> <problems>
report() {
	[ -n "$2" ] || return 0
	echo "  $1"
	printf '%s\n' "$2" | cut -c1-200 | sed 's/^/    /'
	failed=$((failed + 1))
}

#   -------------------------------
#   FILE NAMES (1-5)
#   -------------------------------

# Paths and modes from git's index (what gets committed), or from disk if this isn't a git clone
paths=()
modes=()
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	while IFS= read -r -d '' entry; do
		modes+=("${entry%% *}")
		paths+=("${entry#*$'\t'}")
	done < <(git ls-files -s -z)
else
	while IFS= read -r path; do
		path="${path#./}"
		paths+=("$path")
		if [ -L "$path" ]; then modes+=(120000); elif [ -x "$path" ]; then modes+=(100755); else modes+=(100644); fi
	done < <(find . -path ./.git -prune -o \( -type f -o -type l \) -print)
fi

bad_names="" long_paths="" symlinks="" exec_problems=""
for i in "${!paths[@]}"; do
	path="${paths[$i]}"
	mode="${modes[$i]}"

	# 1. Each part of the path must be a valid Windows name
	IFS=/ read -r -a parts <<<"$path"
	for part in "${parts[@]}"; do
		base="$(printf '%s' "${part%%.*}" | tr '[:lower:]' '[:upper:]')"
		case "$part" in
			*[\<\>:\"\|\?\*\\]* | *[[:cntrl:]]*) bad_names+="$path  (\"$part\" has a character Windows doesn't allow)"$'\n' ;;
			*" " | *.) bad_names+="$path  (\"$part\" ends in a space or dot)"$'\n' ;;
		esac
		case "$base" in
			CON | PRN | AUX | NUL | COM[1-9] | LPT[1-9]) bad_names+="$path  (\"$part\" is a reserved name on Windows)"$'\n' ;;
		esac
	done

	# 3. Long paths
	[ "${#path}" -gt 200 ] && long_paths+="$path  (${#path} characters)"$'\n'

	# 4. Symlinks
	[ "$mode" = 120000 ] && symlinks+="$path"$'\n'

	# 5. Executable bit vs #! line
	if [ "$mode" != 120000 ] && [ -f "$path" ]; then
		if [ "$(head -c 2 "$path")" = '#!' ]; then
			[ "$mode" = 100755 ] || exec_problems+="$path  (has a #! line but isn't executable - run: git update-index --chmod=+x $path)"$'\n'
		elif [ "$mode" = 100755 ]; then
			exec_problems+="$path  (is executable but has no #! line, so it may run with the wrong shell)"$'\n'
		fi
	fi
done

report "File names Windows can't check out - rename them:" "${bad_names%$'\n'}"

# 2. Case-only differences, for files and for the folders they're in
report "Names that differ only in case - macOS and Windows can only keep one of each pair:" \
	"$(printf '%s\n' "${paths[@]}" | awk '
		{
			n = split($0, parts, "/"); prefix = ""
			for (i = 1; i <= n; i++) {
				prefix = (i == 1 ? parts[1] : prefix "/" parts[i])
				key = tolower(prefix)
				if (key in seen && seen[key] != prefix && !(key in reported)) {
					print seen[key] "  and  " prefix; reported[key] = 1
				}
				if (!(key in seen)) seen[key] = prefix
			}
		}')"

report "Paths long enough to hit Windows' 260-character limit - shorten them:" "${long_paths%$'\n'}"
report "Symlinks, which Windows usually checks out as plain text files - copy the file, or load it from \$DOTFILES:" "${symlinks%$'\n'}"
report "Executable bits:" "${exec_problems%$'\n'}"

#   -------------------------------
#   CODE (6-8)
#   -------------------------------

is_third_party() {
	local item
	for item in "${third_party[@]}"; do
		[ "$1" = "$item" ] && return 0
	done
	return 1
}

# Code that bash runs, and code that only zsh runs (zsh doesn't split unquoted variables)
bash_code=()
zsh_code=()
for path in "${paths[@]}"; do
	[ -f "$path" ] || continue
	is_third_party "$path" && continue
	case "$path" in
		*.md | config/* | .github/*) continue ;;
		shell/zshrc.sh) zsh_code+=("$path"); continue ;;
	esac
	case "$path" in
		*.sh | shell/* | .githooks/* | bin/*) bash_code+=("$path") ;;
		*) [ "$(head -c 2 "$path")" = '#!' ] && head -n 1 "$path" | grep -q 'sh' && bash_code+=("$path") ;;
	esac
done

# Walks the code character by character, tracking quotes with a stack (u = unquoted,
# d = "double", s = 'single', c = $(...) or (...), p = ${...} inside "double"), so
# "$(cd "$dir")" and "${path#"$dir"/}" count as quoted.
# Single-quoted alias bodies are checked as code. Heredoc contents and comments are skipped.
scan_code='
	function is_path_var(name) {
		# Lists of folders separated by ":", not single paths
		if (name ~ /^(PATH|MANPATH|INFOPATH|CDPATH|FPATH|CLASSPATH|PYTHONPATH|NODE_PATH|GOPATH)$/) return 0
		return name ~ /^(HOME|DOTFILES|PWD|OLDPWD|TMPDIR|TMP|TEMP|USERPROFILE|APPDATA|LOCALAPPDATA|OneDrive|ZSH|NVM_DIR)$/ ||
			name ~ /(^|_)([Dd][Ii][Rr]|[Pp][Aa][Tt][Hh]|[Ff][Ii][Ll][Ee]|[Ff][Oo][Ll][Dd][Ee][Rr]|[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]|[Rr][Oo][Oo][Tt])[Ss]?$/ ||
			name ~ /[a-z](Path|Folder|Dir|File|Location)$/
	}
	# Unquoted, but not split: the value of an assignment, inside [[ ]], or after "case"
	function split_safe(before) {
		if (before ~ /(^|[[:space:];&|(])[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*$/) return 1
		if (gsub(/\[\[/, "&", before) > gsub(/\]\]/, "&", before)) return 1
		if (before ~ /(^|[[:space:];])case[[:space:]]+$/) return 1
		return 0
	}
	function problem(kind, text) {
		if (!((FILENAME, FNR, kind) in found)) {
			found[FILENAME, FNR, kind] = 1
			print kind "\t" FILENAME ":" FNR ":" text
		}
	}
	# scan(text, reset): checks code; reset=1 for alias bodies, which have their own quoting
	function scan(text, reset,    i, ch, ctx, rest, name, saved_top) {
		if (reset) { saved_top = top; top = 1; stack[1] = "u" }
		for (i = 1; i <= length(text); i++) {
			ch = substr(text, i, 1); ctx = stack[top]
			if (ctx == "s") { if (ch == "\047") top--; continue }
			if (ch ~ /[A-Za-z]/ && substr(text, i + 1, 2) == ":\\" && (i == 1 || substr(text, i - 1, 1) !~ /[A-Za-z0-9_]/))
				problem("backslash", original)
			if (ch == "\\") { i++; continue }
			if (ctx == "p") {
				if (ch == "}") top--
				else if (ch == "\"") stack[++top] = "d"
				else if (substr(text, i, 2) == "$(") { stack[++top] = "c"; i++ }
				else if (substr(text, i, 2) == "${") { stack[++top] = "p"; i++ }
				continue
			}
			if (ctx == "d") {
				if (ch == "\"") top--
				else if (substr(text, i, 2) == "$(") { stack[++top] = "c"; i++ }
				else if (substr(text, i, 2) == "${") { stack[++top] = "p"; i++ }
				continue
			}
			if (ch == "#" && (i == 1 || substr(text, i - 1, 1) ~ /[[:space:];]/)) break
			if (ch == "\047") { stack[++top] = "s"; continue }
			if (ch == "\"") { stack[++top] = "d"; continue }
			if (substr(text, i, 2) == "$(") { stack[++top] = "c"; i++; continue }
			if (ch == "(") { stack[++top] = "c"; continue }
			if (ch == ")") { if (top > 1) top--; continue }
			if (ch == "$" && check_unquoted) {
				rest = substr(text, i)
				if (match(rest, /^\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
					name = substr(rest, 2, RLENGTH - 1); sub(/^\{/, "", name)
					if (is_path_var(name) && !split_safe(substr(text, 1, i - 1)))
						problem("unquoted", original)
				}
			}
		}
		if (reset) top = saved_top
	}
	FNR == 1 { top = 1; stack[1] = "u"; heredoc = "" }
	{ original = $0 }
	heredoc != "" {
		line = $0; sub(/^\t+/, "", line)
		if (line == heredoc) heredoc = ""
		next
	}
	/path-check: ignore/ { next }
	{
		line = $0
		# alias name='\''body'\'' (body may contain '\''\'\'''\'' for a literal quote): check the body as code
		if (stack[top] == "u" && match(line, /^[[:space:]]*alias[[:space:]]+[^=[:space:]]+=\047/)) {
			body = substr(line, RLENGTH + 1)
			if (match(body, /\047[[:space:]]*(#.*)?$/)) {
				body = substr(body, 1, RSTART - 1)
				gsub(/\047\\\047\047/, "\047", body)
				gsub(/\047/, "", body)
				scan(body, 1)
				next
			}
		}
		# A heredoc starts on this line (<<EOF, <<-'\''EOF'\'', not <<<)
		if (match(line, /(^|[^<])<<-?[[:space:]]*[\047"]?[A-Za-z_]+[\047"]?/)) {
			heredoc = substr(line, RSTART, RLENGTH); sub(/^[^<]*<<-?[[:space:]]*/, "", heredoc); gsub(/[\047"]/, "", heredoc)
		}
		scan(line, 0)
	}
'

code_problems() {
	local check_unquoted="$1"
	shift
	[ $# -gt 0 ] || return 0
	awk -v check_unquoted="$check_unquoted" "$scan_code" "$@"
}

code_output="$(code_problems 1 "${bash_code[@]}"; code_problems 0 "${zsh_code[@]}")"
report "Unquoted path variables - these break on paths with spaces (e.g. C:\\Users\\Jane Doe); put them in double quotes:" \
	"$(printf '%s\n' "$code_output" | sed -n 's/^unquoted\t//p')"
report "Windows paths with backslashes - bash treats \\ as an escape; use forward slashes (C:/Users/...):" \
	"$(printf '%s\n' "$code_output" | sed -n 's/^backslash\t//p')"

# 8. OS-specific paths outside shell/os/ without a guard on the same line
os_path_files=()
for path in "${bash_code[@]}" "${zsh_code[@]}"; do
	case "$path" in
		shell/os/* | tools/check-*.sh) ;;
		*) os_path_files+=("$path") ;;
	esac
done
if [ ${#os_path_files[@]} -gt 0 ]; then
	os_paths="$(awk '
		FNR == 1 { in_for = 0; continued = 0 }
		{
			line = $0
			guarded = (in_for && continued)
			if (line ~ /^[[:space:]]*for[[:space:]]/) { in_for = 1; guarded = 1 }
			continued = (line ~ /\\$/)
			if (!continued) in_for = 0
		}
		/^[[:space:]]*#/ || /path-check: ignore/ { next }
		/Darwin|darwin|MINGW|MSYS|CYGWIN|DOTFILES_OS|OSTYPE|uname|path_add|command -v|\[ -[defx] |\[\[ -[defx] |printf / { guarded = 1 }
		guarded { next }
		/(^|[[:space:]"\047=:(])(~|\$HOME|\$\{HOME\})?\/(Applications|Library|System|Volumes|opt\/homebrew|usr\/local\/Cellar|private)(\/|[[:space:]"\047]|$)/ {
			print FILENAME ":" FNR ":" $0 "  (macOS only)"; next
		}
		/(^|[[:space:]"\047=:(])([A-Za-z]:[\\\/][^[:space:]]|\/[A-Za-z]\/(Users|Program Files|Windows|ProgramData)|%[A-Za-z_]+%)/ {
			print FILENAME ":" FNR ":" $0 "  (Windows only)"
		}
	' "${os_path_files[@]}")"
	report "OS-specific paths outside shell/os/ - move them there, or check the OS or that the path exists on the same line:" "$os_paths"
fi

if [ "$failed" -gt 0 ]; then
	echo "    (If a line of code is intentional, add a comment containing 'path-check: ignore' to it.)"
fi
exit $failed
