#!/bin/bash

set -euo pipefail

MODE="${1:---run}"
APP_NAME="feeds"
BUNDLE_ID="dev.qiyang.feeds"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_DIR="${FEEDS_DERIVED_DATA_DIR:-/private/tmp/feeds-macos-derived-data}"
SOURCE_PACKAGES_DIR="${FEEDS_SOURCE_PACKAGES_DIR:-/private/tmp/feeds-source-packages}"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

stop_existing_app() {
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

build_app() {
    xcodebuild \
        -project "$ROOT_DIR/feeds.xcodeproj" \
        -scheme "$APP_NAME" \
        -configuration Debug \
        -destination "platform=macOS" \
        -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
        -derivedDataPath "$DERIVED_DATA_DIR" \
        build
}

launch_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

verify_app() {
    for _ in 1 2 3 4 5; do
        if pgrep -x "$APP_NAME" >/dev/null; then
            echo "$APP_NAME is running ($BUNDLE_ID)"
            return 0
        fi
        sleep 1
    done

    echo "$APP_NAME did not stay running" >&2
    return 1
}

case "$MODE" in
    --run|--verify)
        stop_existing_app
        build_app
        launch_app
        verify_app
        ;;
    --build)
        stop_existing_app
        build_app
        ;;
    --debug)
        stop_existing_app
        build_app
        exec lldb -- "$APP_BINARY"
        ;;
    --logs|--telemetry)
        launch_app
        exec /usr/bin/log stream --level debug --style compact \
            --predicate "process == '$APP_NAME' OR subsystem == '$BUNDLE_ID'"
        ;;
    *)
        echo "Usage: $0 [--run|--verify|--build|--debug|--logs|--telemetry]" >&2
        exit 64
        ;;
esac
