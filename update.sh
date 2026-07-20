#!/bin/bash
# Bump the deployed app version. appVersion drives the deployed image (image.tag
# defaults to it, see values.yaml). The chart `version` patch is also bumped:
# Flux's default reconcileStrategy (ChartVersion) only redeploys the HelmRelease
# when the chart version changes, so an appVersion-only commit wouldn't roll out.
set -euo pipefail

VERSION="${1:?usage: update.sh <version>}"

# Skip prereleases (e.g. v1.2.3-beta.1) — matches the old deploy-stack flow.
if [[ "$VERSION" == *-* ]]; then
    echo "INFO: $VERSION is a prerelease, ignoring"
    exit 0
fi

sed -i "s/^appVersion:.*/appVersion: ${VERSION}/" Chart.yaml

# Bump the chart version's patch so Flux picks up the change.
current="$(grep -E '^version:' Chart.yaml | awk '{print $2}')"
IFS=. read -r major minor patch <<< "$current"
sed -i "s/^version:.*/version: ${major}.${minor}.$((patch + 1))/" Chart.yaml
