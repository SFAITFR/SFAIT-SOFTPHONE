#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION="${1:-}"
BUILD_NUMBER="${2:-1}"

if [[ -z "${VERSION}" ]]; then
  VERSION="$(awk '/^version:/ {print $2}' "${PROJECT_DIR}/pubspec.yaml" | cut -d+ -f1)"
fi

if [[ -z "${VERSION}" ]]; then
  echo "Version introuvable." >&2
  exit 1
fi

ARCH="$(uname -m)"
case "${ARCH}" in
  arm64|aarch64) RELEASE_ARCH="arm64" ;;
  x86_64|amd64) RELEASE_ARCH="x86_64" ;;
  *) RELEASE_ARCH="${ARCH}" ;;
esac

APP_NAME="SFAIT Softphone.app"
APP_PATH="${PROJECT_DIR}/build/macos/Build/Products/Release/${APP_NAME}"
DIST_DIR="${PROJECT_DIR}/dist/releases/v${VERSION}"
STAGE_ROOT="$(mktemp -d)"
STAGE_DIR="${STAGE_ROOT}/SFAIT Softphone"
DMG_PATH="${DIST_DIR}/sfait-softphone-${VERSION}-${RELEASE_ARCH}.dmg"

cleanup() {
  rm -rf "${STAGE_ROOT}"
}
trap cleanup EXIT

FLUTTER_BIN="${FLUTTER_BIN:-}"
if [[ -z "${FLUTTER_BIN}" ]]; then
  BUNDLED_FLUTTER="${PROJECT_DIR}/../SFAIT-build-tools/SFAIT-dev-tools/flutter-3.24.5-arm64/flutter/bin/flutter"
  if [[ -x "${BUNDLED_FLUTTER}" ]]; then
    FLUTTER_BIN="${BUNDLED_FLUTTER}"
  else
    FLUTTER_BIN="$(command -v flutter)"
  fi
fi

mkdir -p "${DIST_DIR}" "${STAGE_DIR}"

cd "${PROJECT_DIR}"
"${FLUTTER_BIN}" build macos --release \
  --build-name "${VERSION}" \
  --build-number "${BUILD_NUMBER}" \
  --dart-define "SFAIT_APP_VERSION=${VERSION}"

ditto "${APP_PATH}" "${STAGE_DIR}/${APP_NAME}"
ln -s /Applications "${STAGE_DIR}/Applications"

rm -f "${DMG_PATH}"
hdiutil create \
  -volname "SFAIT Softphone" \
  -srcfolder "${STAGE_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

shasum -a 256 "${DMG_PATH}" > "${DMG_PATH}.sha256"

echo "${DMG_PATH}"
