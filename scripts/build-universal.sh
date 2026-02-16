#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME="appmeee-imsg-protocol"
ENTITLEMENTS="${ROOT}/Resources/appmeee-imsg.entitlements"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT}/bin}"
ARCHES_VALUE=${ARCHES:-"arm64 x86_64"}
ARCH_LIST=( ${ARCHES_VALUE} )
BUILD_MODE=${BUILD_MODE:-release}
CODESIGN_IDENTITY=${CODESIGN_IDENTITY:-"-"}

for ARCH in "${ARCH_LIST[@]}"; do
  echo "Building ${ARCH}..."
  swift build -c "$BUILD_MODE" --product "$APP_NAME" --arch "$ARCH"
done

BINARIES=()
for ARCH in "${ARCH_LIST[@]}"; do
  BINARIES+=("${ROOT}/.build/${ARCH}-apple-macosx/${BUILD_MODE}/${APP_NAME}")
done

DIST_DIR="$(mktemp -d "/tmp/${APP_NAME}-universal.XXXXXX")"
trap 'rm -rf "$DIST_DIR"' EXIT

lipo -create "${BINARIES[@]}" -output "${DIST_DIR}/${APP_NAME}"

if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - \
    --entitlements "$ENTITLEMENTS" \
    --identifier com.appmeee.imsg-protocol \
    "${DIST_DIR}/${APP_NAME}"
else
  codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --identifier com.appmeee.imsg-protocol \
    "${DIST_DIR}/${APP_NAME}"
fi

mkdir -p "$OUTPUT_DIR"
cp "${DIST_DIR}/${APP_NAME}" "$OUTPUT_DIR/${APP_NAME}"

echo "Built ${OUTPUT_DIR}/${APP_NAME} (${ARCHES_VALUE})"
