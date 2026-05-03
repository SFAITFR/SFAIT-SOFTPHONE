#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION="${1:-}"
BUILD_NUMBER="${2:-1}"

if [[ -z "${VERSION}" ]]; then
  VERSION="$(awk '/^version:/ {print $2}' "${PROJECT_DIR}/pubspec.yaml" | cut -d+ -f1)"
fi

TAG="v${VERSION}"
DMG_PATH="$("${SCRIPT_DIR}/package-macos-release.sh" "${VERSION}" "${BUILD_NUMBER}")"
SHA_PATH="${DMG_PATH}.sha256"

cd "${PROJECT_DIR}"

if ! git rev-parse "${TAG}" >/dev/null 2>&1; then
  git tag -a "${TAG}" -m "SFAIT Softphone ${VERSION}"
fi

git push origin "${TAG}"

if ! command -v gh >/dev/null 2>&1; then
  cat <<EOF
Release tag pushed: ${TAG}

GitHub CLI n'est pas installe sur cette machine.
Ajoute ces fichiers a la release GitHub ${TAG} :
- ${DMG_PATH}
- ${SHA_PATH}
EOF
  exit 0
fi

gh release create "${TAG}" \
  "${DMG_PATH}" \
  "${SHA_PATH}" \
  --title "SFAIT Softphone ${VERSION}" \
  --notes "Première release publique de SFAIT Softphone."
