#!/bin/zsh
# Checks TypedDateParser against expected.txt. Usage: ./check.sh
# After an intended change in answers, review the diff, then refresh with: ./check.sh --update
cd "$(dirname "$0")"
TZ=Europe/Berlin swiftc -o /tmp/date-parser-check main.swift "../Camera Roll Cleaner/TypedDateParser.swift" || exit 1
if [[ "$1" == "--update" ]]; then
  TZ=Europe/Berlin /tmp/date-parser-check > expected.txt && echo "expected.txt updated"
else
  TZ=Europe/Berlin /tmp/date-parser-check | diff expected.txt - && echo "All phrases match"
fi
