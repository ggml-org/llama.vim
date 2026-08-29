#!/bin/bash
# Determine the release version and run the pre-release checks.
#
# Usage: make-release-checks.sh
#
# Checks:
#   - the version tag does not already exist on origin
#
# Env (when running in GitHub Actions):
#   GITHUB_OUTPUT: version is written here
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION="$(cat "$REPO_ROOT/VERSION")"
if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: invalid version '${VERSION}' in VERSION (expected <maj>.<min>.<pat>)"
    exit 1
fi
VERSION="v${VERSION}"
echo "Determined version: ${VERSION}"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "version=${VERSION}" >> "$GITHUB_OUTPUT"
fi

echo "Checking that tag ${VERSION} does not already exist..."
if git ls-remote --tags origin "${VERSION}" | grep -q "${VERSION}"; then
    echo "Error: tag ${VERSION} already exists on remote"
    exit 1
fi
echo "Tag ${VERSION} does not exist on remote - OK"
