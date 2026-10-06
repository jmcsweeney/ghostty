#!/bin/bash
#
# Fork-only: update this Ghostty fork from upstream, rebuild, and install.
#
# This is what "Check for Updates" in the macOS app runs (see
# macos/Sources/Features/Update/ForkUpdater.swift), but every subcommand
# also works by hand from a terminal.
#
#   fork/update.sh check
#       Fetch origin + upstream and report what's new since the installed
#       build. Prints key=value lines, then "---", then upstream commit
#       subjects.
#
#   fork/update.sh build
#       Merge origin/main and upstream/main into main, build the app with
#       `zig build -Doptimize=ReleaseFast`, then push main to origin.
#
#   fork/update.sh install [--wait-pid PID] [--app PATH] [--defaults-domain ID]
#       Wait for PID to exit, replace PATH (default /Applications/Ghostty.app)
#       with the freshly built app, record the installed commit, relaunch.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH="main"
BUILT_APP="$REPO/macos/build/ReleaseLocal/Ghostty.app"
BUILT_COMMIT_FILE="$REPO/macos/build/ReleaseLocal/.fork-built-commit"
DEFAULTS_DOMAIN="com.mitchellh.ghostty"

cd "$REPO"

# When launched from the app we get the minimal GUI PATH, which won't have
# zig. Borrow the PATH from the user's login shell. printenv prints it
# colon-separated even for fish.
if login_path="$("${SHELL:-/bin/zsh}" -l -c 'printenv PATH' 2>/dev/null | tail -n 1)" &&
    [ -n "$login_path" ]; then
    export PATH="$login_path"
fi

# Homebrew's `zig` tracks the latest release, which can run ahead of what
# Ghostty supports. Prefer a versioned keg (e.g. zig@0.16) matching
# minimum_zig_version when one is installed.
zig_minor="$(sed -nE 's/.*minimum_zig_version = "([0-9]+\.[0-9]+)\..*/\1/p' build.zig.zon)"
for prefix in /opt/homebrew /usr/local; do
    if [ -n "$zig_minor" ] && [ -x "$prefix/opt/zig@$zig_minor/bin/zig" ]; then
        export PATH="$prefix/opt/zig@$zig_minor/bin:$PATH"
        break
    fi
done

fail() {
    echo "error: $*" >&2
    exit 1
}

log() {
    echo "==> $*"
}

require_clean_main() {
    local current
    current="$(git symbolic-ref --quiet --short HEAD || true)"
    [ "$current" = "$BRANCH" ] ||
        fail "checkout is on '${current:-detached HEAD}', expected '$BRANCH'"
    git diff --quiet && git diff --cached --quiet ||
        fail "checkout has uncommitted changes; commit or stash them first"
}

# The commit the installed app was built from, falling back to HEAD for
# builds that didn't go through `install`.
installed_commit() {
    local sha
    sha="$(defaults read "$DEFAULTS_DOMAIN" ForkInstalledCommit 2>/dev/null || true)"
    if [ -n "$sha" ] && git cat-file -e "$sha^{commit}" 2>/dev/null; then
        echo "$sha"
    else
        git rev-parse HEAD
    fi
}

cmd_check() {
    require_clean_main
    git fetch --quiet origin
    git fetch --quiet upstream

    local installed upstream_count total_count
    installed="$(installed_commit)"
    upstream_count="$(git rev-list --count "$installed..upstream/$BRANCH")"
    total_count="$(git rev-list --count "^$installed" "origin/$BRANCH" "upstream/$BRANCH" "$BRANCH")"

    echo "installed=$installed"
    echo "upstream=$(git rev-parse "upstream/$BRANCH")"
    echo "upstream_count=$upstream_count"
    echo "total_count=$total_count"
    echo "---"
    git log --no-merges --max-count=15 --format='%s' "$installed..upstream/$BRANCH"
}

cmd_build() {
    require_clean_main

    log "Fetching origin and upstream"
    git fetch origin
    git fetch upstream

    for ref in "origin/$BRANCH" "upstream/$BRANCH"; do
        log "Merging $ref"
        if ! git merge --no-edit "$ref"; then
            git merge --abort || true
            fail "merging $ref conflicted, so the merge was aborted. Resolve it by hand:
    cd $REPO && git merge $ref"
        fi
    done

    log "Building (zig build -Doptimize=ReleaseFast)"
    zig build -Doptimize=ReleaseFast
    [ -d "$BUILT_APP" ] || fail "build finished but $BUILT_APP is missing"
    git rev-parse HEAD >"$BUILT_COMMIT_FILE"

    log "Pushing $BRANCH to origin"
    if ! git push origin "$BRANCH"; then
        echo "warning: push failed; the build is still fine, push by hand later" >&2
    fi

    log "Build complete: $(git log -1 --format='%h %s')"
}

cmd_install() {
    local wait_pid="" app="/Applications/Ghostty.app"
    while [ $# -gt 0 ]; do
        case "$1" in
        --wait-pid) wait_pid="$2"; shift 2 ;;
        --app) app="$2"; shift 2 ;;
        --defaults-domain) DEFAULTS_DOMAIN="$2"; shift 2 ;;
        *) fail "unknown install option: $1" ;;
        esac
    done

    [ -d "$BUILT_APP" ] || fail "no built app at $BUILT_APP; run build first"

    if [ -n "$wait_pid" ]; then
        log "Waiting for Ghostty (pid $wait_pid) to quit"
        for _ in $(seq 1 300); do
            kill -0 "$wait_pid" 2>/dev/null || break
            sleep 0.2
        done
        kill -0 "$wait_pid" 2>/dev/null && fail "Ghostty didn't quit; not installing"
    fi

    # Running straight out of the build directory: nothing to copy.
    if [ "$(cd "$app" && pwd -P)" != "$(cd "$BUILT_APP" && pwd -P)" ]; then
        log "Installing to $app"
        local staged
        staged="$(dirname "$app")/.$(basename "$app").new"
        rm -rf "$staged"
        ditto "$BUILT_APP" "$staged"
        rm -rf "$app"
        mv "$staged" "$app"
    fi

    if [ -f "$BUILT_COMMIT_FILE" ]; then
        defaults write "$DEFAULTS_DOMAIN" ForkInstalledCommit "$(cat "$BUILT_COMMIT_FILE")"
    fi
    defaults write "$DEFAULTS_DOMAIN" ForkRepoPath "$REPO"

    log "Relaunching"
    open "$app"
}

case "${1:-}" in
check) shift; cmd_check "$@" ;;
build) shift; cmd_build "$@" ;;
install) shift; cmd_install "$@" ;;
*) fail "usage: $0 check | build | install [--wait-pid PID] [--app PATH] [--defaults-domain ID]" ;;
esac
