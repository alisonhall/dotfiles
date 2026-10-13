# Shared by the tools/__test__ tests. Each test gets a small git repo of its own (with a space in
# its path) holding copies of the check scripts, adds the example files it needs, and runs a check.

setup() {
	REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
	export HOME="$BATS_TEST_TMPDIR/home"
	export GIT_CONFIG_NOSYSTEM=1
	unset GIT_CONFIG_GLOBAL
	mkdir -p "$HOME"

	FIX="$BATS_TEST_TMPDIR/fixture repo"
	mkdir -p "$FIX/tools"
	cp "$REPO"/tools/check-*.sh "$FIX/tools/"
	git -C "$FIX" init -q
}

# add <path> <line>...: Write the lines to a file in the fixture repo and stage it
add() {
	local path="$1"
	shift
	mkdir -p "$(dirname "$FIX/$path")"
	printf '%s\n' "$@" > "$FIX/$path"
	git -C "$FIX" add -- "$path"
}

# add_executable <path> <line>...: Same, marked executable in git (works on Windows too)
add_executable() {
	add "$@"
	git -C "$FIX" update-index --chmod=+x -- "$1"
}

# add_index_only <path> [mode]: Add a file to git's index without creating it, for names this OS
# can't create (Windows can't make "what?.md") or modes like symlinks (120000)
add_index_only() {
	local blob
	blob="$(git -C "$FIX" hash-object -w --stdin </dev/null)"
	# Git for Windows refuses names like these by default (core.protectNTFS), even in the index
	git -C "$FIX" -c core.protectNTFS=false update-index --add --cacheinfo "${2:-100644},$blob,$1"
}

# check <name>: Run tools/check-<name>.sh in the fixture repo (with no input, so anything that
# waits for some fails the test instead of hanging it)
check() {
	run bash "$FIX/tools/check-$1.sh" </dev/null
}
