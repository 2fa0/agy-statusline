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
  --copy         Copy plugin files into ${TARGET_DIR} (default when run standalone)
  --link         Symlink ${TARGET_DIR} to the local source directory (best for development)
  --uninstall    Remove ${TARGET_DIR}
  -h, --help     Show this help message
EOF
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

if ! command -v python3 >/dev/null 2>&1; then
  echo "Warning: 'python3' was not found in PATH. AGY Desktop Status requires Python 3." >&2
fi

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
LOCAL_DIR=""
if [[ -n "${SCRIPT_SOURCE}" && -f "${SCRIPT_SOURCE}" ]]; then
  CANDIDATE_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
  if [[ -f "${CANDIDATE_DIR}/plugin.json" && -f "${CANDIDATE_DIR}/telemetry.py" ]]; then
    LOCAL_DIR="${CANDIDATE_DIR}"
  elif [[ -f "${CANDIDATE_DIR}/desktop-panel/plugin.json" ]]; then
    LOCAL_DIR="${CANDIDATE_DIR}/desktop-panel"
  fi
fi

mkdir -p "${HOME}/.gemini/config/plugins"

if [[ -n "${LOCAL_DIR}" ]]; then
  rm -rf "${TARGET_DIR}"
  if [[ "${MODE}" == "copy" ]]; then
    mkdir -p "${TARGET_DIR}"
    rsync -a --exclude 'node_modules' --exclude '.DS_Store' --exclude '__pycache__' "${LOCAL_DIR}/" "${TARGET_DIR}/"
    chmod +x "${TARGET_DIR}/install.sh" "${TARGET_DIR}/server.py" "${TARGET_DIR}/hooks/track_active.py" 2>/dev/null || true
    echo "Copied ${LOCAL_DIR} -> ${TARGET_DIR}"
  else
    ln -s "${LOCAL_DIR}" "${TARGET_DIR}"
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
    tar -xzf "${TMP_DIR}/plugin.tar.gz" -C "${TMP_DIR}"
    EXTRACTED_DIR="${TMP_DIR}/agy-desktop-status"
    if [[ ! -f "${EXTRACTED_DIR}/plugin.json" ]]; then
      EXTRACTED_DIR="${TMP_DIR}"
    fi
  else
    echo "Release archive not found; falling back to main branch archive..."
    MAIN_URL="https://github.com/${REPO_SLUG}/archive/refs/heads/main.tar.gz"
    curl -fsSL "${MAIN_URL}" -o "${TMP_DIR}/main.tar.gz"
    tar -xzf "${TMP_DIR}/main.tar.gz" -C "${TMP_DIR}"
    EXTRACTED_DIR="$(find "${TMP_DIR}" -maxdepth 3 -name "plugin.json" -exec dirname {} \; | head -n 1)"
  fi

  if [[ -z "${EXTRACTED_DIR}" || ! -f "${EXTRACTED_DIR}/plugin.json" ]]; then
    echo "Error: failed to download or locate plugin.json." >&2
    exit 1
  fi

  rm -rf "${TARGET_DIR}"
  mkdir -p "${TARGET_DIR}"
  cp -R "${EXTRACTED_DIR}/." "${TARGET_DIR}/"
  chmod +x "${TARGET_DIR}/install.sh" "${TARGET_DIR}/server.py" "${TARGET_DIR}/hooks/track_active.py" 2>/dev/null || true
  echo "Installed AGY Desktop Status to ${TARGET_DIR}"
fi

echo ""
echo "AGY Desktop Status is ready!"
echo "1. Open or restart Antigravity Desktop."
echo "2. Click '+' in the top-right auxiliary pane -> select 'AGY Status'."
