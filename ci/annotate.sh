#!/bin/bash
# Stem Eye CI: put a log's important lines into ONE GitHub annotation (annotations are readable without logging in --
# so Claude can see why a run failed). usage: ci/annotate.sh <title> <log file> <grep -E pattern> [max lines]
t="$1"; f="$2"; p="$3"; n="${4:-60}"
[ -f "$f" ] || { echo "::error title=$t::(no log $f)"; exit 0; }
body=$( (grep -E "$p" "$f" || true) | head -n "$n")
[ -n "$body" ] || body=$(tail -n 40 "$f")
body=${body//'%'/'%25'}; body=${body//$'\r'/}; body=${body//$'\n'/'%0A'}
echo "::error title=$t::$body"
