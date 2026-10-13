#!/usr/bin/env bash
# Runs every test in the repo: the *.bats files in __test__ folders next to the code they test.
# Needs bats-core: brew install bats-core (macOS), apt install bats (Linux), npm install -g bats (Git Bash).
#
# Usage: tools/run-tests.sh [bats options]   e.g. --filter setup_git

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! command -v bats >/dev/null 2>&1; then
	echo "bats isn't installed. Install it with one of:" >&2
	echo "  brew install bats-core      (macOS)" >&2
	echo "  sudo apt install bats       (Linux)" >&2
	echo "  npm install -g bats         (Windows Git Bash)" >&2
	exit 1
fi

test_dirs=()
while IFS= read -r dir; do
	test_dirs+=("$dir")
done < <(find . -path ./.git -prune -o -type d -name __test__ -print | sort)

if [ "${#test_dirs[@]}" -eq 0 ]; then
	echo "No __test__ folders found."
	exit 0
fi

# Checks that pass silently: on bash 3.2 (macOS) a false [[ ]] only fails a test on its last line,
# and `! command` never fails one. Use `[[ ... ]] || false` and `run ! command`.
silent="$(find "${test_dirs[@]}" -name '*.bats' -exec grep -nE '^[[:space:]]*(\[\[.*\]\][[:space:]]*(#.*)?|![[:space:]].*)$' {} + || true)"
if [ -n "$silent" ]; then
	echo "These checks can't fail a test - add '|| false' to [[ ]] checks, and use 'run !' instead of '!':" >&2
	printf '%s\n' "$silent" | sed 's/^/  /' >&2
	exit 1
fi

# No input, so a script that waits for some fails its test instead of hanging the run
bats "$@" "${test_dirs[@]}" </dev/null
