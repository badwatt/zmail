#!/bin/sh
# Release notes, from the commits themselves.
#
# A commit whose message does not follow the `type: subject` convention still
# happened. Grouping the ones that do and dropping the rest is how a release with
# forty changes ends up advertising two dependabot bumps: everything lands in a
# bucket here, and the last bucket takes whatever matched nothing.
#
# Usage: changelog.sh [previous-tag] [tag-or-ref]
set -eu

from=${1:-}
to=${2:-HEAD}

if [ -z "$from" ]; then
    range=$to
else
    range="$from..$to"
fi

git log --no-merges --pretty=format:'%s' "$range" | awk '
function bucket(subject,   s) {
    s = tolower(subject)
    if (s ~ /^breaking:|!/) return "Breaking changes"
    if (s ~ /^(feat|feature)(\(|:|!)/) return "Features"
    if (s ~ /^fix(\(|:|!)/) return "Fixes"
    if (s ~ /^perf(\(|:|!)/) return "Performance"
    if (s ~ /^refactor(\(|:|!)/) return "Refactoring"
    if (s ~ /^test(\(|:|!)/) return "Tests"
    if (s ~ /^docs(\(|:|!)/) return "Docs"
    if (s ~ /^style(\(|:|!)/) return "Style"
    if (s ~ /^ci(\(|:|!)/) return "CI"
    if (s ~ /^(chore|build)(\(|:|!)/) return "Chores"
    return "Other changes"
}
{
    count += 1
    order[count] = bucket($0)
    subject[count] = $0
    seen[order[count]] = 1
}
END {
    headings = "Breaking changes|Features|Fixes|Performance|Refactoring|Tests|Docs|Style|CI|Chores|Other changes"
    split(headings, names, "|")
    for (n = 1; n <= 11; n++) {
        title = names[n]
        if (!(title in seen)) continue
        printf "## %s\n\n", title
        for (i = 1; i <= count; i++) {
            if (order[i] == title) printf "- %s\n", subject[i]
        }
        printf "\n"
    }
}'
