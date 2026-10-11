#!/bin/sh
set -eu

# Use the identity of the Xcode Cloud product, not the public checkout defaults.
# This file is intentionally ignored by Git and is read by Signing.xcconfig.
: "${CI_PRIMARY_REPOSITORY_PATH:?Xcode Cloud repository path is required}"
: "${CI_TEAM_ID:?Xcode Cloud development team is required}"
: "${CI_BUNDLE_ID:?Xcode Cloud product bundle identifier is required}"

case "$CI_TEAM_ID" in
    *[!A-Za-z0-9]*) echo "Invalid Xcode Cloud team ID" >&2; exit 1 ;;
esac
case "$CI_BUNDLE_ID" in
    *[!A-Za-z0-9.-]*) echo "Invalid Xcode Cloud bundle identifier" >&2; exit 1 ;;
esac

printf 'DEVELOPMENT_TEAM = %s\nLIFTLOG_BUNDLE_IDENTIFIER = %s\n' \
    "$CI_TEAM_ID" "$CI_BUNDLE_ID" \
    > "$CI_PRIMARY_REPOSITORY_PATH/Config/Signing.local.xcconfig"
