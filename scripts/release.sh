#!/bin/bash
#
# Release preparation script for llama.vim.
#
# Bumps the version in VERSION on a release candidate branch.
# The branch should then be pushed and a PR created, reviewed, and
# merged. After the PR is merged, the release is finalized by the
# make-release workflow (.github/workflows/make-release.yml), which
# creates the tag.
#
# Usage:
#   ./scripts/release.sh [major|minor|patch] [--dry-run]
#
# Example:
#   $ ./scripts/release.sh patch
#
# The script:
# 1. Creates a release candidate branch (llama-rc-v<major>.<minor>.<patch>)
# 2. Bumps the version in VERSION
# 3. Commits the version bump
#

set -e

if [ ! -f "VERSION" ] || [ ! -d "scripts" ]; then
    echo "Error: Must be run from llama.vim root directory"
    exit 1
fi

# Parse command line arguments
VERSION_TYPE=""
DRY_RUN=false

for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=true
            ;;
        major|minor|patch)
            VERSION_TYPE="$arg"
            ;;
        *)
            echo "Error: Unknown argument '$arg'"
            echo "Usage: $0 [major|minor|patch] [--dry-run]"
            exit 1
            ;;
    esac
done

# Default to patch if no version type specified
VERSION_TYPE="${VERSION_TYPE:-patch}"

# Common validation functions
check_git_status() {
    # Check for uncommitted changes (skip in dry-run)
    if [ "$DRY_RUN" = false ] && ! git diff-index --quiet HEAD --; then
        echo "Error: You have uncommitted changes. Please commit or stash them first."
        exit 1
    fi
}

check_master_branch() {
    # Ensure we're on master branch
    CURRENT_BRANCH=$(git branch --show-current)
    if [ "$CURRENT_BRANCH" != "master" ]; then
        if [ "$DRY_RUN" = true ]; then
            echo "[dry run] Warning: Not on master branch (currently on: $CURRENT_BRANCH). Continuing with dry-run..."
            echo ""
        else
            echo "Error: Must be on master branch. Currently on: $CURRENT_BRANCH"
            exit 1
        fi
    fi
}

check_master_up_to_date() {
    # Check if we have the latest from master (skip in dry-run)
    if [ "$DRY_RUN" = false ]; then
        echo "Checking if local master is up-to-date with remote..."
        git fetch origin master
        LOCAL=$(git rev-parse HEAD)
        REMOTE=$(git rev-parse origin/master)

        if [ "$LOCAL" != "$REMOTE" ]; then
            echo "Error: Your local master branch is not up-to-date with origin/master."
            echo "Please run 'git pull origin master' first."
            exit 1
        fi
        echo "✓ Local master is up-to-date with remote"
        echo ""
    elif [ "$(git branch --show-current)" = "master" ]; then
        echo "[dry run] Warning: Dry-run mode - not checking if master is up-to-date with remote"
        echo ""
    fi
}

prepare_release() {
    if [ "$DRY_RUN" = true ]; then
        echo "[dry-run] Preparing release (no changes will be made)"
    else
        echo "Starting release preparation..."
    fi
    echo ""

    check_git_status
    check_master_branch
    check_master_up_to_date

    # Extract current version from VERSION
    echo "Step 1: Reading current version..."
    CURRENT_VERSION=$(cat VERSION)
    if ! [[ "${CURRENT_VERSION}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        echo "Error: invalid version '${CURRENT_VERSION}' in VERSION (expected <maj>.<min>.<pat>)"
        exit 1
    fi
    MAJOR="${BASH_REMATCH[1]}"
    MINOR="${BASH_REMATCH[2]}"
    PATCH="${BASH_REMATCH[3]}"

    echo "Current version: $MAJOR.$MINOR.$PATCH"

    # Calculate new version
    case $VERSION_TYPE in
        major)
            NEW_MAJOR=$((MAJOR + 1))
            NEW_MINOR=0
            NEW_PATCH=0
            ;;
        minor)
            NEW_MAJOR=$MAJOR
            NEW_MINOR=$((MINOR + 1))
            NEW_PATCH=0
            ;;
        patch)
            NEW_MAJOR=$MAJOR
            NEW_MINOR=$MINOR
            NEW_PATCH=$((PATCH + 1))
            ;;
    esac

    NEW_VERSION="$NEW_MAJOR.$NEW_MINOR.$NEW_PATCH"
    RC_BRANCH="llama-rc-v$NEW_VERSION"
    echo "New release version: $NEW_VERSION"
    echo "Release candidate branch: $RC_BRANCH"
    echo ""

    # Create release candidate branch
    echo "Step 2: Creating release candidate branch..."
    if [ "$DRY_RUN" = true ]; then
        echo "  [dry-run] Would create branch: $RC_BRANCH"
    else
        git checkout -b "$RC_BRANCH"
        echo "✓ Created and switched to branch: $RC_BRANCH"
    fi
    echo ""

    # Update VERSION for release
    echo "Step 3: Updating version in VERSION..."
    if [ "$DRY_RUN" = true ]; then
        echo "  [dry-run] Would update VERSION to $NEW_VERSION"
    else
        echo "$NEW_VERSION" > VERSION
    fi
    echo ""

    # Commit version bump
    echo "Step 4: Committing version bump..."
    if [ "$DRY_RUN" = true ]; then
        echo "  [dry-run] Would commit: 'llama.vim : bump version to $NEW_VERSION'"
    else
        git add VERSION
        git commit -m "llama.vim : bump version to $NEW_VERSION"
    fi
    echo ""

    echo ""
    if [ "$DRY_RUN" = true ]; then
        echo "[dry-run] Summary (no changes were made):"
        echo "  • Would have created branch: $RC_BRANCH"
        echo "  • Would have updated version to: $NEW_VERSION"
    else
        echo "Release preparation completed!"
        echo "Summary:"
        echo "  • Created branch: $RC_BRANCH"
        echo "  • Updated version to: $NEW_VERSION"
        echo ""
        echo "Next steps:"
        echo "  • Push branch to remote: git push origin $RC_BRANCH"
        echo "  • Create a Pull Request from $RC_BRANCH to master"
        echo "  • After the PR is merged, create the release with the make-release"
        echo "    workflow (.github/workflows/make-release.yml)"
    fi
}

prepare_release
