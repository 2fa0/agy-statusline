#!/usr/bin/env bash
set -euo pipefail

PLUGIN_NAME="agy-desktop-status"
TARGET_DIR="${HOME}/.gemini/config/plugins/${PLUGIN_NAME}"
REPO_SLUG="${AGY_STATUSLINE_REPO:-2fa0/agy-statusline}"
RELEASE_TAG="${AGY_STATUSLINE_TAG:-latest}"

usage() {
  cat <<EOF
Usage: ./install.sh [OPTIONS]

Install or uninstall the AGY Desktop Status right-pane plugin for Antigravity 2.0 Desktop.

Options:
  --copy         Copy plugin files into ${TARGET_DIR} (default for release archives)
  --link         Symlink ${TARGET_DIR} to the local source directory (best for development)
  --uninstall    Remove ${TARGET_DIR}
  -h, --help     Show this help message

Without --copy/--link the mode is inferred: a git checkout is linked, anything
else (e.g. an extracted release archive) is copied, so the plugin never points at
a directory you are about to delete.
EOF
}

strip_quarantine() {
  [[ "$(uname -s)" = "Darwin" ]] || return 0
  [[ -e "$1" ]] || return 0
  xattr -dr com.apple.quarantine "$1" 2>/dev/null || true
}

# Integrity check against the release's SHA256SUMS.txt. This is separate from
# Gatekeeper: it catches truncated or tampered downloads.
verify_checksum() { # <archive> <release-base-url>
  local file="$1" base="$2" sums expected actual
  sums="$(mktemp "${TMPDIR:-/tmp}/agy-sums.XXXXXX")"
  if ! curl -fsSL "${base}/SHA256SUMS.txt" -o "${sums}" 2>/dev/null; then
    rm -f "${sums}"
    echo "Warning: this release has no SHA256SUMS.txt; skipping integrity check." >&2
    return 0
  fi
  expected="$(awk '$2 == "agy-desktop-status-plugin.tar.gz" || $2 == "*agy-desktop-status-plugin.tar.gz" {print $1; exit}' "${sums}")"
  rm -f "${sums}"
  if [[ -z "${expected}" ]]; then
    echo "Warning: SHA256SUMS.txt does not list the plugin archive; skipping." >&2
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "${file}" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "${file}" | awk '{print $1}')"
  fi
  if [[ "${actual}" != "${expected}" ]]; then
    echo "Error: checksum mismatch for the plugin archive." >&2
    echo "  expected ${expected}" >&2
    echo "  actual   ${actual}" >&2
    return 1
  fi
  echo "Checksum verified."
}

MODE="auto"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall)
      rm -rf "${TARGET_DIR}"
      echo "Removed ${TARGET_DIR}"
      exit 0
      ;;
    --link)
      MODE="link"
      shift
      ;;
    --copy)
      MODE="copy"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Release archives contain all supported native targets. Source installations
# use the binary produced by ./build.sh; no interpreter is needed at runtime.
prepare_backend() {
  local plugin_dir="$1" platform arch native_source
  arch="$(uname -m)"
  case "$(uname -s)-${arch}" in
    Darwin-arm64) platform="macos-arm64" ;;
    Linux-x86_64) platform="linux-x64" ;;
    *) platform="local" ;;
  esac
  native_source="${plugin_dir}/bin/${platform}/agy-desktop-backend"
  if [[ -f "${native_source}" ]]; then
    cp "${native_source}" "${plugin_dir}/sidecars/status/agy-desktop-backend"
  fi
  if [[ ! -f "${plugin_dir}/sidecars/status/agy-desktop-backend" ]]; then
    echo "Error: native backend missing for $(uname -s)/${arch}." >&2
    echo "Build the source first with Zig 0.14.1 and SQLite: ./build.sh" >&2
    return 1
  fi
  chmod +x "${plugin_dir}/sidecars/status/agy-desktop-backend"
}

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
LOCAL_DIR=""
if [[ -n "${SCRIPT_SOURCE}" && -f "${SCRIPT_SOURCE}" ]]; then
  CANDIDATE_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
  if [[ -f "${CANDIDATE_DIR}/plugin.json" && -f "${CANDIDATE_DIR}/backend.zig" ]]; then
    LOCAL_DIR="${CANDIDATE_DIR}"
  elif [[ -f "${CANDIDATE_DIR}/desktop-panel/plugin.json" ]]; then
    LOCAL_DIR="${CANDIDATE_DIR}/desktop-panel"
  fi
fi

mkdir -p "${HOME}/.gemini/config/plugins"

if [[ -n "${LOCAL_DIR}" ]]; then
  # Inferred mode: only a real git checkout wants a live symlink. An extracted
  # release archive must be copied -- the user will delete the download folder.
  if [[ "${MODE}" == "auto" ]]; then
    if [[ -d "${LOCAL_DIR}/.git" || -d "$(dirname "${LOCAL_DIR}")/.git" ]]; then
      MODE="link"
    else
      MODE="copy"
    fi
  fi
  prepare_backend "${LOCAL_DIR}"
  if [[ "${LOCAL_DIR}" == "${TARGET_DIR}" ]]; then
    strip_quarantine "${TARGET_DIR}"
    echo "Updated native backend in place at ${TARGET_DIR}"
  elif [[ "${MODE}" == "copy" ]]; then
    rm -rf "${TARGET_DIR}"
    mkdir -p "${TARGET_DIR}"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --exclude 'node_modules' --exclude '.DS_Store' --exclude '__pycache__' --exclude 'tests' "${LOCAL_DIR}/" "${TARGET_DIR}/"
    else
      cp -R "${LOCAL_DIR}/." "${TARGET_DIR}/"
      rm -rf "${TARGET_DIR}/ui/node_modules" "${TARGET_DIR}/tests" "${TARGET_DIR}/__pycache__"
    fi
    strip_quarantine "${TARGET_DIR}"
    chmod +x "${TARGET_DIR}/install.sh" "${TARGET_DIR}/sidecars/status/agy-desktop-backend"
    echo "Copied ${LOCAL_DIR} -> ${TARGET_DIR}"
  else
    rm -rf "${TARGET_DIR}"
    ln -s "${LOCAL_DIR}" "${TARGET_DIR}"
    strip_quarantine "${TARGET_DIR}/sidecars/status/agy-desktop-backend"
    echo "Linked ${TARGET_DIR} -> ${LOCAL_DIR}"
  fi
else
  # One-liner remote install mode (e.g. curl -fsSL .../install.sh | bash)
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agy-desktop-status.XXXXXX")"
  trap 'rm -rf "${TMP_DIR}"' EXIT
  if [[ "${RELEASE_TAG}" == "latest" ]]; then
    ARCHIVE_URL="https://github.com/${REPO_SLUG}/releases/latest/download/agy-desktop-status-plugin.tar.gz"
  else
    ARCHIVE_URL="https://github.com/${REPO_SLUG}/releases/download/${RELEASE_TAG}/agy-desktop-status-plugin.tar.gz"
  fi
  echo "Downloading AGY Desktop Status plugin from ${ARCHIVE_URL} ..."
  if curl -fsSL "${ARCHIVE_URL}" -o "${TMP_DIR}/plugin.tar.gz"; then
    verify_checksum "${TMP_DIR}/plugin.tar.gz" "${ARCHIVE_URL%/*}"
    tar -xzf "${TMP_DIR}/plugin.tar.gz" -C "${TMP_DIR}"
    EXTRACTED_DIR="${TMP_DIR}/agy-desktop-status"
    if [[ ! -f "${EXTRACTED_DIR}/plugin.json" ]]; then
      EXTRACTED_DIR="${TMP_DIR}"
    fi
  else
    echo "Error: native release archive unavailable. Download a release, or clone and build the source." >&2
    exit 1
  fi

  if [[ -z "${EXTRACTED_DIR}" || ! -f "${EXTRACTED_DIR}/plugin.json" ]]; then
    echo "Error: failed to download or locate plugin.json." >&2
    exit 1
  fi

  prepare_backend "${EXTRACTED_DIR}"
  rm -rf "${TARGET_DIR}"
  mkdir -p "${TARGET_DIR}"
  cp -R "${EXTRACTED_DIR}/." "${TARGET_DIR}/"
  strip_quarantine "${TARGET_DIR}"
  chmod +x "${TARGET_DIR}/install.sh" "${TARGET_DIR}/sidecars/status/agy-desktop-backend"
  echo "Installed AGY Desktop Status to ${TARGET_DIR}"
fi

echo ""
echo "AGY Desktop Status is ready!"
echo "1. Open or restart Antigravity Desktop."
echo "2. Click '+' in the top-right auxiliary pane -> select 'AGY Status'."
