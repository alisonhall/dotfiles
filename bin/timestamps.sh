#! /bin/bash
# An obvious reference for most commonly requested bash timestamps
# chmod +x timestamps.sh

# %N (nanoseconds) is only in GNU date (Linux, Git Bash) - macOS prints a literal N instead
gnu_date () {
	local output
	output="$(date "$@")"
	case "$output" in
		*N*) echo "(GNU date only)" ;;
		*) echo "$output" ;;
	esac
}

cat << EOD
        Format/result           |       Command              |          Output               |       Example Output
--------------------------------+----------------------------+-------------------------------+----------------------------
YYYY-MM-DD_hh:mm:ss             | date +%F_%T                | $(date +%F_%T)                | 2020-01-31_23:15:08
YYYYMMDD_hhmmss                 | date +%Y%m%d_%H%M%S        | $(date +%Y%m%d_%H%M%S)        | 20200131_231508
YYYYMMDD_hhmmss (UTC version)   | date -u +%Y%m%d_%H%M%SZ    | $(date -u +%Y%m%d_%H%M%SZ)    | 20200131_141508Z
YYYYMMDD_hhmmss (with local TZ) | date +%Y%m%d_%H%M%S%Z      | $(date +%Y%m%d_%H%M%S%Z)      | 20200131_231508JST
YYYYMMSShhmmss                  | date +%Y%m%d%H%M%S         | $(date +%Y%m%d%H%M%S)         | 20200131231508
YYYYMMSShhmmssnnnnnnnnn *       | date +%Y%m%d%H%M%S%N       | $(gnu_date +%Y%m%d%H%M%S%N)   | 20200131231508163085835
YYMMDD_hhmmss                   | date +%y%m%d_%H%M%S        | $(date +%y%m%d_%H%M%S)        | 200131_231508
Seconds since UNIX epoch:       | date +%s                   | $(date +%s)                   | 1580480108
Nanoseconds only: *             | date +%N                   | $(gnu_date +%N)               | 169140987
Nanoseconds since UNIX epoch: * | date +%s%N                 | $(gnu_date +%s%N)             | 1580480108170759606
ISO8601 UTC timestamp           | date -u +%FT%TZ            | $(date -u +%FT%TZ)            | 2020-01-31T14:15:08Z
ISO8601 UTC timestamp + ms *    | date -u +%FT%T.%3NZ        | $(gnu_date -u +%FT%T.%3NZ)    | 2020-01-31T14:15:08.175Z
ISO8601 Local TZ timestamp      | date +%FT%T%Z              | $(date +%FT%T%Z)              | 2020-01-31T23:15:08JST
YYYY-MM-DD (Short day)          | date +%F\(%a\)             | $(date +%F\(%a\))             | 2020-01-31(Wed)
YYYY-MM-DD (Long day)           | date +%F\(%A\)             | $(date +%F\(%A\))             | 2020-01-31(Wednesday)

* Uses %N (nanoseconds), which only GNU date has (Linux, Git Bash). macOS shows "(GNU date only)".
Note: The short and long day-of-week are dependent on the environment variable LANG. After setting LANG=en_CA.UTF-8, we get the preceding results.
EOD
