#!/usr/bin/env bash
#
# Checks shell and git aliases for problems, especially ones that only show up on some OSes.
#
# Shell aliases and functions (shell/):
#   1. Syntax errors inside alias bodies, which `bash -n` doesn't look at. Checked with each shell
#      that loads the file (bash, zsh, or both).
#   2. Alias names a shell won't accept
#   3. Double-quoted aliases containing $VAR, which expand once when the shell starts rather
#      than each time the alias runs
#   4. Commands some OSes don't have - e.g. pbcopy (macOS only), clip (Windows only), lsof/man/zip
#      (not in Git Bash). An alias or function in a shared file that uses one needs a replacement
#      in shell/os/<os>.sh for each OS that lacks it: the command itself (like pbcopy in
#      os/windows.sh) or the alias/function.
#   5. Options that only exist in the GNU version of a tool (Linux, Git Bash) or the BSD one
#      (macOS) - e.g. sed -i, date --utc, grep -P. Also checked in bin/ scripts and git aliases.
#
# Git aliases (git/gitconfig):
#   6. Aliases git can't run: the first word isn't a git command or alias (e.g. "git stash ...",
#      which runs `git git stash`), an alias named after a built-in command (git ignores those),
#      or an alias that leads back to itself
#   7. ! aliases with syntax errors, or with bash-only syntax ([[ ]], ==, ${x//...}): git runs
#      them with sh, which is dash on Ubuntu and WSL
#
# To allow a line anyway, add a comment to it containing: alias-check: ignore
#
# Used by the pre-commit hook and the GitHub Actions tests.
# Prints each problem and exits non-zero if there are any.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
failed=0
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# Kept as their authors wrote them
third_party=(bin/git-branch-status)

# report <description> <problems> (duplicates are shown once)
report() {
	[ -n "$2" ] || return 0
	echo "  $1"
	printf '%s\n' "$2" | awk '!seen[$0]++' | cut -c1-220 | sed 's/^/    /'
	failed=$((failed + 1))
}

#   -------------------------------
#   SHARED AWK: COMMANDS AND OPTIONS BY OS
#   -------------------------------

# Defines commands_in(code) and option_problem(command, segment), used by the scans below.
# Command lists are what each OS has by default (Windows = Git for Windows' Git Bash).
os_knowledge='
	BEGIN {
		oses = "mac linux windows"
		missing["windows"] = " lsof sudo ifconfig ip man zip rsync watch bc killall top free wget tree xdg-open xclip xsel wl-copy wl-paste open pbcopy pbpaste defaults mdfind mdls qlmanage osascript dscacheutil scselect mkfile diskutil hdiutil launchctl networksetup caffeinate sw_vers say md5 apt apt-get systemctl journalctl "
		missing["mac"] = " xdg-open xclip xsel wl-copy wl-paste clip clip.exe explorer explorer.exe start cmd cmd.exe powershell powershell.exe taskkill tasklist reg winget cygpath tac nproc free ip wget tree watch timeout apt apt-get systemctl journalctl "
		missing["linux"] = " pbcopy pbpaste open defaults mdfind mdls qlmanage osascript dscacheutil scselect mkfile diskutil hdiutil launchctl networksetup caffeinate sw_vers say md5 clip clip.exe explorer explorer.exe start cmd cmd.exe powershell powershell.exe taskkill tasklist reg winget cygpath ipconfig ifconfig "
		os_label["mac"] = "macOS"; os_label["linux"] = "Linux"; os_label["windows"] = "Windows (Git Bash)"
	}
	# The commands a line of code runs: the first word of each pipeline/list part, after
	# keywords, variable assignments and wrappers like sudo. Returns " cmd1 cmd2 ".
	function commands_in(code,    parts, n, i, part, word, out) {
		gsub(/\$\(|`|&&|\|\||[|;(){}]/, "\n", code)
		n = split(code, parts, "\n"); out = " "
		for (i = 1; i <= n; i++) {
			part = parts[i]
			while (1) {
				sub(/^[[:space:]]+/, "", part)
				if (match(part, /^sudo([[:space:]]|$)/)) { out = out "sudo "; part = substr(part, RLENGTH + 1); continue }
				if (match(part, /^(if|then|else|elif|do|while|until|time|!|command|exec|nohup|builtin|env|xargs([[:space:]]+-[^[:space:]]+)*)([[:space:]]|$)/)) { part = substr(part, RLENGTH + 1); continue }
				if (match(part, /^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*([[:space:]]|$)/)) { part = substr(part, RLENGTH + 1); continue }
				break
			}
			word = part; sub(/[[:space:]].*/, "", word); gsub(/["\047\\]/, "", word); sub(/.*\//, "", word)
			if (word != "") out = out word " "
		}
		return out
	}
	# Options that only work in the GNU or the BSD (macOS) version of a tool.
	# Returns "<oses it breaks on>|<message>", or "" if fine.
	function option_problem(word, part) {
		part = " " part " "
		if (word == "sed" && part ~ /[[:space:]]-i[[:space:]]*(\047\047|"")/) return "linux windows|sed -i \047\047 is the macOS form - GNU sed takes the \047\047 as the script. Use sed -i.bak ... then delete the .bak file"
		if (word == "sed" && part ~ /[[:space:]]-i[[:space:]]/) return "mac|sed -i without a backup suffix fails on macOS. Use sed -i.bak ... then delete the .bak file"
		if (word == "date" && part ~ /--utc|--date|[[:space:]]-d[[:space:]]|--iso-8601|--rfc-/) return "mac|GNU-only date option (--utc, -d, --iso-8601) - macOS date doesn\047t have them; -u works on both for UTC"
		if (word == "date" && part ~ /%N/) return "mac|date %N (nanoseconds) is GNU only - macOS prints a literal N"
		if (word == "date" && part ~ /[[:space:]]-v[+-]?[0-9]/) return "linux windows|date -v is macOS only - GNU date uses -d"
		if (word == "grep" && part ~ /[[:space:]]-[A-Za-z]*P|--perl-regexp/) return "mac|grep -P isn\047t in macOS grep - use grep -E"
		if (word == "stat" && part ~ /[[:space:]](-c|--format|--printf)/) return "mac|stat -c is GNU only - macOS uses stat -f"
		if (word == "stat" && part ~ /[[:space:]]-f[[:space:]]/) return "linux windows|stat -f is macOS - in GNU stat it means filesystem info"
		if (word == "find" && part ~ /[[:space:]]-(printf|regextype)[[:space:]]/) return "mac|find -printf / -regextype are GNU only"
		if (word == "xargs" && part ~ /[[:space:]](-d|--delimiter|--no-run-if-empty|--arg-file)/) return "mac|that xargs option is GNU only"
		if (word == "du" && part ~ /--max-depth/) return "mac|du --max-depth is GNU only - du -d works on both"
		if (word == "base64" && part ~ /[[:space:]](-w|--wrap)/) return "mac|base64 -w is GNU only"
		if (word == "head" && part ~ /[[:space:]]-[nc][[:space:]]*-[0-9]/) return "mac|negative head counts (head -n -1) are GNU only"
		if ((word == "cp" || word == "mv") && part ~ /[[:space:]](-t|--target-directory|--parents|--backup)/) return "mac|that cp/mv option is GNU only"
		if (word == "ln" && part ~ /[[:space:]](-[A-Za-z]*r[A-Za-z]*|--relative)[[:space:]]/) return "mac|ln -r is GNU only"
		if (word == "mktemp" && part ~ /--suffix|--tmpdir/) return "mac|mktemp --suffix / --tmpdir are GNU only"
		return ""
	}
	# Each command-list part of a line, with its first word, for option checks: "word<TAB>part" lines.
	# For xargs, only its own options count (not those of the command it runs).
	function parts_with_commands(code,    parts, n, i, part, word, out) {
		gsub(/\$\(|`|&&|\|\||[|;(){}]/, "\n", code)
		n = split(code, parts, "\n"); out = ""
		for (i = 1; i <= n; i++) {
			part = parts[i]; sub(/^[[:space:]]+/, "", part)
			while (match(part, /^(sudo|if|then|else|elif|do|while|until|time|!|command|exec|nohup|builtin|env)[[:space:]]+/)) part = substr(part, RLENGTH + 1)
			if (match(part, /^xargs([[:space:]]+-[^[:space:]]*([[:space:]]+[0-9]+)?)*/)) part = substr(part, 1, RLENGTH)
			word = part; sub(/[[:space:]].*/, "", word); gsub(/["\047\\]/, "", word); sub(/.*\//, "", word)
			if (word != "") out = out word "\t" part "\n"
		}
		return out
	}
	# Option problems in a piece of code that runs on the given OSes. Returns messages, one per line.
	function option_problems(code, run_oses,    lines, n, i, word, part, result, affected, message, k, os_list, hit) {
		n = split(parts_with_commands(code), lines, "\n"); hit = ""
		for (i = 1; i <= n; i++) {
			if (lines[i] == "") continue
			word = lines[i]; sub(/\t.*/, "", word); part = lines[i]; sub(/^[^\t]*\t/, "", part)
			result = option_problem(word, part)
			if (result == "") continue
			affected = result; sub(/\|.*/, "", affected); message = result; sub(/^[^|]*\|/, "", message)
			split(affected, os_list, " ")
			for (k in os_list) if (index(" " run_oses " ", " " os_list[k] " ")) { hit = hit message "\n"; break }
		}
		return hit
	}
'

#   -------------------------------
#   SHELL ALIASES AND FUNCTIONS (1-5)
#   -------------------------------

shell_files=()
for file in shell/*.sh shell/common/*.sh shell/os/*.sh; do
	[ -f "$file" ] && shell_files+=("$file")
done

# Parses aliases and functions. Prints tab-separated records:
#   BODY  <shells> <file:line> <name> <body>   - alias bodies to syntax-check
#   NAME  <shells> <file:line> <name>          - alias names to try defining
#   PROBLEM <kind> <text>                      - problems found while parsing
shell_scan="$os_knowledge"'
	FNR == 1 {
		in_function = ""; depth = 0
		shells = (FILENAME ~ /zshrc\.sh$/) ? "zsh" : (FILENAME ~ /bashrc\.sh$/) ? "bash" : "bash zsh"
		file_os = ""
		if (match(FILENAME, /shell\/os\/[a-z]+\.sh$/)) { file_os = substr(FILENAME, RSTART + 9); sub(/\.sh$/, "", file_os) }
	}
	function record_use(name, code, guard,    cmds, n, i, cmd, problems) {
		cmds = commands_in(code); n = split(cmds, list, " ")
		for (i = 1; i <= n; i++) {
			cmd = list[i]
			if (cmd == "" || cmd == name || index(" " guard " ", " " cmd " ")) continue
			uses[++use_count] = FILENAME SUBSEP FNR SUBSEP file_os SUBSEP name SUBSEP cmd SUBSEP $0
		}
		problems = option_problems(code, file_os == "" ? oses : file_os)
		if (problems != "") {
			n = split(problems, list, "\n")
			for (i = 1; i <= n; i++) if (list[i] != "") print "PROBLEM\toptions\t" FILENAME ":" FNR ":" $0 "  (" list[i] ")"
		}
	}
	/alias-check: ignore/ { next }
	# Inside a multi-line function: record what each line uses, until its closing brace
	in_function != "" {
		line = $0; gsub(/\$\{[^}]*\}/, "", line)
		depth += gsub(/\{/, "{", line) - gsub(/\}/, "}", line)
		if ($0 !~ /^[[:space:]]*#/) record_use(in_function, $0, "")
		if (depth <= 0) in_function = ""
		next
	}
	/^[[:space:]]*#/ { next }
	{
		line = $0
		guard = ""
		if (match(line, /command -v [A-Za-z0-9_.-]+/)) { guard = substr(line, RSTART + 11, RLENGTH - 11) }

		if (match(line, /(^|[;&|][[:space:]]*)alias[[:space:]]+[^=[:space:]]+=/)) {
			name = substr(line, RSTART, RLENGTH); sub(/^.*alias[[:space:]]+/, "", name); sub(/=$/, "", name)
			rest = substr(line, RSTART + RLENGTH)
			quote = substr(rest, 1, 1)
			if (quote == "\047") {
				body = rest; sub(/^\047/, "", body)
				if (match(body, /\047[[:space:]]*(#.*)?$/)) body = substr(body, 1, RSTART - 1)
				gsub(/\047\\\047\047/, "\047", body)
			} else if (quote == "\"") {
				body = rest; sub(/^"/, "", body)
				if (match(body, /"[[:space:]]*(#.*)?$/)) body = substr(body, 1, RSTART - 1)
				if (body ~ /(^|[^\\])\$[A-Za-z_{(]/)
					print "PROBLEM\tdouble\t" FILENAME ":" FNR ":" $0
			} else {
				body = rest; sub(/[[:space:]].*/, "", body)
			}
			print "BODY\t" shells "\t" FILENAME ":" FNR "\t" name "\t" body
			print "NAME\t" shells "\t" FILENAME ":" FNR "\t" name
			defined[file_os, name] = 1
			record_use(name, body, guard)
			next
		}

		if (match(line, /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_.:-]*[[:space:]]*\(\)[[:space:]]*\{?/)) {
			name = substr(line, RSTART, RLENGTH); sub(/^[[:space:]]*(function[[:space:]]+)?/, "", name); sub(/[[:space:]]*\(\).*/, "", name)
			defined[file_os, name] = 1
			code = substr(line, RSTART + RLENGTH)
			stripped = line; gsub(/\$\{[^}]*\}/, "", stripped)
			depth = gsub(/\{/, "{", stripped) - gsub(/\}/, "}", stripped)
			record_use(name, code, guard)
			if (depth > 0 || line !~ /\{/) in_function = name
			if (line !~ /\{/) depth = 0
			next
		}
	}
	END {
		# A command an OS lacks is fine if that OS defines it, or redefines the alias/function using it.
		# Problems are grouped per line: "<name> uses lsof, sudo - not on Windows (Git Bash)"
		for (i = 1; i <= use_count; i++) {
			split(uses[i], u, SUBSEP); file = u[1]; line_no = u[2]; def_os = u[3]; name = u[4]; cmd = u[5]; text = u[6]
			n = split(def_os == "" ? oses : def_os, check_oses, " ")
			for (k = 1; k <= n; k++) {
				os = check_oses[k]
				if (!index(missing[os], " " cmd " ")) continue
				if (((os, cmd) in defined) || ((os, name) in defined) || (("", cmd) in defined)) continue
				key = file ":" line_no ":" text SUBSEP name SUBSEP def_os
				if (!(key in first_seen)) { first_seen[key] = ++key_count; keys[key_count] = key }
				if (!index(" " cmds_for[key] " ", " " cmd " ")) cmds_for[key] = cmds_for[key] (cmds_for[key] == "" ? "" : ", ") cmd
				if (!index(lacking_for[key], os_label[os])) lacking_for[key] = lacking_for[key] (lacking_for[key] == "" ? "" : ", ") os_label[os]
			}
		}
		for (i = 1; i <= key_count; i++) {
			split(keys[i], k_parts, SUBSEP)
			hint = (k_parts[3] == "") ? " - add a version to shell/os/ for that OS" : ""
			print "PROBLEM\tcommand\t" k_parts[1] "  (" k_parts[2] " uses " cmds_for[keys[i]] " - not on " lacking_for[keys[i]] hint ")"
		}
	}
'

shell_output="$(awk "$shell_scan" "${shell_files[@]}")"

# 1 and 2: try the alias bodies and names in each shell that loads them. All at once first,
# since starting a shell per alias is slow (especially on Windows); one at a time only to
# pinpoint problems if the batch fails.
syntax_problems="" name_problems=""
for shell in bash zsh; do
	command -v "$shell" >/dev/null 2>&1 || continue
	printf '%s\n' "$shell_output" | awk -F '\t' -v shell="$shell" '($1 == "BODY" || $1 == "NAME") && index(" " $2 " ", " " shell " ")' > "$work_dir/defs"

	# Bodies: each inside its own function, so one file holds them all
	awk -F '\t' '$1 == "BODY" { print "__alias_check_" NR " () {"; print $5; print "}" }' "$work_dir/defs" > "$work_dir/bodies"
	if ! "$shell" -n "$work_dir/bodies" >/dev/null 2>&1; then
		while IFS=$'\t' read -r _ _ location name body; do
			printf '%s\n' "$body" > "$work_dir/body"
			if ! output="$("$shell" -n "$work_dir/body" 2>&1)"; then
				syntax_problems+="$location: alias $name='$body'  ($shell: $(printf '%s' "$output" | head -1 | sed 's/^.*body: //'))"$'\n'
			fi
		done < <(awk -F '\t' '$1 == "BODY"' "$work_dir/defs")
	fi

	# Names: define them all; any message means a name was rejected
	awk -F '\t' '$1 == "NAME" { print "alias -- \047" $4 "=true\047" }' "$work_dir/defs" > "$work_dir/names"
	if [ -n "$("$shell" "$work_dir/names" 2>&1)" ]; then
		while IFS=$'\t' read -r _ _ location name; do
			if ! output="$("$shell" -c 'alias -- "$1=true"' _ "$name" 2>&1)" || [ -n "$output" ]; then
				name_problems+="$location: alias $name  ($shell: $(printf '%s' "$output" | head -1))"$'\n'
			fi
		done < <(awk -F '\t' '$1 == "NAME"' "$work_dir/defs")
	fi
done

problems_of_kind() {
	printf '%s\n' "$shell_output" | sed -n "s/^PROBLEM"$'\t'"$1"$'\t'"//p"
}

report "Alias bodies with syntax errors:" "${syntax_problems%$'\n'}"
report "Alias names a shell won't accept:" "${name_problems%$'\n'}"
report "Double-quoted aliases with \$ - these expand once when the shell starts; use single quotes:" "$(problems_of_kind double)"
report "Commands some OSes don't have:" "$(problems_of_kind command)"

# 5 for bin/ scripts too (they run on every OS)
bin_files=()
for file in bin/*; do
	[ -f "$file" ] || continue
	case " ${third_party[*]} " in *" $file "*) continue ;; esac
	bin_files+=("$file")
done
bin_options=""
if [ ${#bin_files[@]} -gt 0 ]; then
	# Inside heredocs, only $(...) runs - the rest is text being printed
	bin_options="$(awk "$os_knowledge"'
		FNR == 1 { heredoc = "" }
		/alias-check: ignore/ { next }
		heredoc != "" {
			line = $0; sub(/^\t+/, "", line)
			if (line == heredoc) { heredoc = ""; next }
			code = ""; rest = $0
			while (match(rest, /\$\([^)]*\)/)) { code = code substr(rest, RSTART + 2, RLENGTH - 3) "; "; rest = substr(rest, RSTART + RLENGTH) }
		}
		heredoc == "" {
			if ($0 ~ /^[[:space:]]*#/) next
			code = $0
			if (match($0, /(^|[^<])<<-?[[:space:]]*[\047"]?[A-Za-z_]+[\047"]?/)) {
				heredoc = substr($0, RSTART, RLENGTH); sub(/^[^<]*<<-?[[:space:]]*/, "", heredoc); gsub(/[\047"]/, "", heredoc)
			}
		}
		{
			problems = option_problems(code, oses)
			n = split(problems, list, "\n")
			for (i = 1; i <= n; i++) if (list[i] != "") print FILENAME ":" FNR ":" $0 "  (" list[i] ")"
		}' "${bin_files[@]}")"
fi
report "Options that only work on some OSes' versions of a tool:" \
	"$(printf '%s\n%s\n' "$(problems_of_kind options)" "$bin_options" | sed '/^$/d')"

#   -------------------------------
#   GIT ALIASES (6-7)
#   -------------------------------

gitconfig=git/gitconfig
if [ -f "$gitconfig" ] && command -v git >/dev/null 2>&1; then
	# name<TAB>value per alias (values can span lines in the file, so read git's NUL-separated
	# output; tabs from their indentation become spaces so they don't split the fields)
	git config --file "$gitconfig" -z --get-regexp '^alias\.' |
		awk 'BEGIN { RS = "\0" } { key = $0; sub(/\n.*/, "", key); value = substr($0, length(key) + 2); sub(/^alias\./, "", key); gsub(/[\n\t]/, " ", value); print key "\t" value }' \
			> "$work_dir/git-aliases"

	# Aliases whose line in the file is marked to skip
	ignored=" $(grep -E 'alias-check: ignore' "$gitconfig" | sed -E 's/^[[:space:]]*([^[:space:]=]+)[[:space:]]*=.*/\1/' | tr '[:upper:]' '[:lower:]' | tr '\n' ' ') "

	builtins=" $(git --list-cmds=builtins 2>/dev/null | tr '\n' ' ') "
	# Every git command (including git-* scripts in this repo's bin/, which is on PATH)
	git_commands=" $(git --list-cmds=main,others,nohelpers 2>/dev/null | tr '\n' ' ') $(for f in bin/git-*; do [ -f "$f" ] && printf '%s ' "${f#bin/git-}"; done) "
	alias_names=" $(cut -f1 "$work_dir/git-aliases" | tr '\n' ' ') "

	# ! aliases: syntax-check them all at once in sh (and dash, if installed), one at a time only
	# if that fails
	sh_problems=""
	awk -F '\t' '$2 ~ /^!/ { print "__alias_check_" NR " () {"; print substr($2, 2); print "}" }' "$work_dir/git-aliases" > "$work_dir/git-bodies"
	for shell in sh dash; do
		command -v "$shell" >/dev/null 2>&1 || continue
		"$shell" -n "$work_dir/git-bodies" >/dev/null 2>&1 && continue
		while IFS=$'\t' read -r name value; do
			case "$ignored" in *" $name "*) continue ;; esac
			printf '%s\n' "${value#!}" > "$work_dir/body"
			if ! output="$("$shell" -n "$work_dir/body" 2>&1)"; then
				sh_problems+="$name = $value  ($shell: $(printf '%s' "$output" | head -1 | sed 's/^.*body: //'))"$'\n'
			fi
		done < <(awk -F '\t' '$2 ~ /^!/' "$work_dir/git-aliases")
	done
	sh_problems+="$(awk -F '\t' -v ignored="$ignored" '
		$2 ~ /^!/ && !index(ignored, " " $1 " ") && $2 ~ /\[\[|\[ [^]]*==|\$\{[A-Za-z_][A-Za-z0-9_]*(\/\/|:[0-9])|<<<|&>|\$\047|(^|[;{[:space:]])(function|source|select)[[:space:]]|echo -e|(^|[^$])\(\(/ {
			print $1 " = " $2 "  (bash-only syntax - fails where sh is dash, e.g. Ubuntu and WSL)"
		}' "$work_dir/git-aliases")"

	run_problems=""
	while IFS=$'\t' read -r name value; do
		case "$ignored" in *" $name "*) continue ;; esac
		if [[ "$builtins" == *" $name "* ]]; then
			run_problems+="$name = $value  (git ignores aliases named after built-in commands)"$'\n'
		fi
		case "$value" in
			'!'*) ;;
			*)
				first="${value%%[[:space:]]*}"
				if [ "$first" = git ]; then
					run_problems+="$name = $value  (runs \`git git ...\` - drop the leading git)"$'\n'
				elif [[ "$git_commands" != *" $first "* && "$alias_names" != *" $first "* ]]; then
					run_problems+="$name = $value  (\"$first\" isn't a git command or alias)"$'\n'
				fi
				;;
		esac
	done < "$work_dir/git-aliases"

	# Aliases that lead back to themselves (a = b, b = a), following up to 20 steps.
	# (Built-in names are already reported above - git ignores those aliases.)
	loops="$(awk -F '\t' -v builtins="$builtins" -v ignored="$ignored" '
		{ value[$1] = $2 }
		END {
			for (name in value) {
				if (index(builtins, " " name " ") || index(ignored, " " name " ")) continue
				current = name
				for (step = 1; step <= 20; step++) {
					if (value[current] ~ /^!/) break
					next_name = value[current]; sub(/[[:space:]].*/, "", next_name)
					if (next_name == name) { print name " = " value[name] "  (leads back to itself)"; break }
					if (!(next_name in value)) break
					current = next_name
				}
			}
		}' "$work_dir/git-aliases")"

	# Commands and options the ! aliases use, which run on every OS
	git_os="$(awk -F '\t' "$os_knowledge"'
		$2 ~ /^!/ {
			body = substr($2, 2)
			cmds = commands_in(body); n = split(cmds, list, " ")
			for (i = 1; i <= n; i++) {
				lacking = ""
				for (os in missing) if (index(missing[os], " " list[i] " ")) lacking = lacking (lacking == "" ? "" : ", ") os_label[os]
				if (lacking != "") print $1 " = " $2 "  (uses " list[i] ", which " lacking " doesn\047t have)"
			}
			problems = option_problems(body, oses)
			n = split(problems, list, "\n")
			for (i = 1; i <= n; i++) if (list[i] != "") print $1 " = " $2 "  (" list[i] ")"
		}' "$work_dir/git-aliases")"
	git_os="$(printf '%s\n' "$git_os" | while IFS= read -r line; do
		name="${line%% =*}"
		case "$ignored" in *" $name "*) ;; *) printf '%s\n' "$line" ;; esac
	done)"

	report "Git aliases git can't run:" "$(printf '%s\n%s\n' "${run_problems%$'\n'}" "$loops" | sed '/^$/d')"
	report "Git ! aliases that fail in sh:" "$(printf '%s\n' "$sh_problems" | sed '/^$/d')"
	report "Git ! aliases using commands or options some OSes don't have:" "$git_os"
fi

if [ "$failed" -gt 0 ]; then
	echo "    (If one of these is intentional, add a comment containing 'alias-check: ignore' to that line.)"
fi
exit $failed
