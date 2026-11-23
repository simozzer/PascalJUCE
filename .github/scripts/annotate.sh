#!/usr/bin/env bash
#
# GitHub annotations for CI failures. Annotations are public, so they name
# what failed and nothing else: no compiler, sanitizer or test output, stack
# traces, seeds or log tails. The details stay in the job log.
#
#   annotate.sh build <log>              "build failed"
#   annotate.sh ctest <log>              one error per failed test, by name, and
#                                        a notice with the pass count
#   annotate.sh fail <title>             one error with this title
#   annotate.sh notice <title> <file>    a notice holding the file (for output
#                                        that is ours, such as display formats)
#   annotate.sh show <lines> <file>      prints the last lines of a log to the
#                                        job log with workflow commands disabled
set -u
mode=$1

# Workflow-command escaping: one annotation, many lines.
esc() { sed -e 's/%/%25/g' -e 's/\r//g' | awk 'BEGIN { ORS = "%0A" } { print }'; }
# Property values (titles) must not hold ':' or ',' either.
escTitle() { printf '%s' "$1" | tr -d '\r\n' | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/,/%2C/g'; }
# Message text: one line, '%' escaped.
escMsg() { printf '%s' "$1" | tr -d '\r\n' | sed -e 's/%/%25/g'; }

case "$mode" in
build)
    echo "::error title=build failed::The build failed; see the job log."
    ;;
ctest)
    log=$2
    [ -f "$log" ] || { echo "::error::annotate.sh: no log"; exit 0; }
    # Failed tests: "  12 - name (Failed)" after "The following tests FAILED:".
    sed -n '/The following tests FAILED:/,$p' "$log" | grep -E '^[[:space:]]+[0-9]+ - ' | head -20 |
    while read -r num dash name rest; do
        t=$(escTitle "ctest $name failed")
        echo "::error title=$t::$(escMsg "Test $name failed"); see the job log."
    done
    body=$(grep -E "tests passed|tests failed out of" "$log" | tail -1 | esc)
    echo "::notice title=ctest summary::$body"
    ;;
fail)
    t=$(escTitle "$2")
    echo "::error title=$t::$(escMsg "$2"); see the job log."
    ;;
notice)
    t=$(escTitle "$2")
    [ -f "$3" ] && echo "::notice title=$t::$(esc < "$3")"
    ;;
show)
    [ -f "$3" ] || exit 0
    token=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    echo "::stop-commands::$token"
    tail -n "$2" "$3"
    echo "::$token::"
    ;;
esac
exit 0
