#!/usr/bin/env bash
# ADAPTED for delta-dotnet: this repo uses src/, so the version file is src/version.txt.
# Guard src/version.txt against the production/* release tags, in one of two modes:
#
#   ahead       version.txt must be STRICTLY SemVer-greater than the latest production/* release.
#               The MAIN-LINE guard, run by the STAGING DEPLOY (deploy-apps-staging). That job also publishes
#               the preview NuGet packages, so this one guard gates the whole preview train (image + package) —
#               a matched pair on one release train. After a release, it fails until version.txt is bumped.
#
#   unreleased  version.txt must simply NOT already be a production release (production/{version} absent).
#               Allows a LOWER, not-yet-released (hotfix) version. NOTE: currently UNWIRED — the preview train
#               uses `ahead`, and hotfix versions ship through deploy-apps-production (tag-uniqueness guard),
#               which repacks packages from the image's commit rather than via the preview flow. Kept as a
#               utility for any caller that must tolerate behind-main versions.
#
# Reads production tags from the remote (git ls-remote) — no local tags / fetch-depth needed.
# Usage: bash .github/scripts/guard-version.sh <ahead|unreleased> [remote]   (remote defaults to "origin")
set -euo pipefail

MODE="${1:-ahead}"
REMOTE="${2:-origin}"
VERSION=$(tr -d '[:space:]' < src/version.txt)

if ! printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "::error::src/version.txt ('$VERSION') is not a valid X.Y.Z version."
  exit 1
fi

case "$MODE" in
  unreleased)
    if git ls-remote --tags "$REMOTE" "refs/tags/production/$VERSION" | grep -q .; then
      echo "::error::version.txt ($VERSION) is already released as production/$VERSION — bump src/version.txt (a hotfix must use a new, unreleased version)."
      exit 1
    fi
    echo "version.txt = $VERSION is not yet released — OK."
    ;;
  ahead)
    LATEST=$(git ls-remote --tags "$REMOTE" 'production/*' \
              | sed -E 's#.*refs/tags/production/##; s/\^\{\}$//' \
              | sort -uV | tail -n1)
    if [ -z "$LATEST" ]; then
      echo "version.txt = $VERSION — no production releases yet, OK."
      exit 0
    fi
    HIGHEST=$(printf '%s\n%s\n' "$LATEST" "$VERSION" | sort -V | tail -n1)
    if [ "$VERSION" = "$LATEST" ] || [ "$HIGHEST" != "$VERSION" ]; then
      echo "::error::version.txt ($VERSION) must be strictly greater than the latest production release ($LATEST). Bump src/version.txt on main."
      exit 1
    fi
    echo "version.txt = $VERSION > latest production ($LATEST) — OK."
    ;;
  *)
    echo "::error::unknown guard mode '$MODE' (expected 'ahead' or 'unreleased')."
    exit 1
    ;;
esac
