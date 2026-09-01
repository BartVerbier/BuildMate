#!/bin/sh
# Bump CURRENT_PROJECT_VERSION in project.yml and regenerate the project.
# Run before every TestFlight/App Store upload; commit the result.
set -eu
cd "$(dirname "$0")"
current=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: \([0-9]*\)$/\1/p' project.yml)
[ -n "$current" ] || { echo "CURRENT_PROJECT_VERSION not found in project.yml" >&2; exit 1; }
next=$((current + 1))
sed -i '' "s/^\( *CURRENT_PROJECT_VERSION:\) $current\$/\1 $next/" project.yml
echo "build number: $current -> $next"
xcodegen generate
