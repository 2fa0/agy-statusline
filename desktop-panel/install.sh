#!/usr/bin/env bash
set -euo pipefail

PLUGIN_NAME="agy-desktop-status"
TARGET_DIR="${HOME}/.gemini/config/plugins/${PLUGIN_NAME}"
REPO_SLUG="${AGY_STATUSLINE_REPO:-2fa0/agy-vitals}"
RELEASE_TAG="${AGY_STATUSLINE_TAG:-latest}"

usage() {
  cat <<EOF
Usage: ./install.sh [OPTIONS]

Install or uninstall the AGY Desktop Status right-pane plugin for Antigravity 2.0 Desktop.

Options:
  --copy         Copy plugin files into ${TARGET_DIR} (default for release archives)
  --link         Symlink ${TARGET_DIR} to the local source directory (best for development)
  --doctor       Diagnose installation status (delegates to root install.sh when available)
  --json         With --doctor: print machine-readable JSON diagnostics
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

ORIG_ARGS=("$@")
MODE="auto"
DOCTOR=0
JSON=0
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
    --doctor)
      DOCTOR=1
      shift
      ;;
    --json)
      JSON=1
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

# ------------------------------------------------------- 平台与原生后台

# Release archives contain all supported native targets; the platform name picks
# the matching bin/<platform>/ directory.
detect_platform() {
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) printf 'macos-arm64' ;;
    Linux-x86_64 | Linux-amd64) printf 'linux-x64' ;;
    Linux-aarch64 | Linux-arm64) printf 'linux-arm64' ;;
    *) printf '' ;;
  esac
}

# Where this package keeps its native backend, for the current (or given)
# platform. Read-only: diagnosing never touches the package, and installing
# copies from whatever this prints.
#   release archive: bin/<platform>/agy-desktop-backend (all targets)
#   source checkout: sidecars/status/agy-desktop-backend (built by build.sh)
resolve_native_source() { # <plugin-dir> [platform]
  local plugin_dir="$1" platform="${2:-}"
  [[ -n "${plugin_dir}" ]] || return 1
  if [[ -z "${platform}" ]]; then platform="$(detect_platform 2>/dev/null || true)"; fi
  if [[ -n "${platform}" && -f "${plugin_dir}/bin/${platform}/agy-desktop-backend" ]]; then
    printf '%s\n' "${plugin_dir}/bin/${platform}/agy-desktop-backend"
    return 0
  fi
  if [[ -f "${plugin_dir}/sidecars/status/agy-desktop-backend" ]]; then
    printf '%s\n' "${plugin_dir}/sidecars/status/agy-desktop-backend"
    return 0
  fi
  return 1
}

# ---------------------------------------------------- 机器可读诊断（--doctor --json）

# The release archive only ships this plugin, so it can diagnose the plugin. It
# must not pretend to be the full suite diagnosis: the JSON says what it covered
# and the exit code reflects the checks it actually ran.
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r\n\t'; }

PANEL_CHECKS=""
PANEL_CODES=""
panel_check() { # <key> <value> <code|ok>
  local key="$1" value="$2" code="$3" sep=""
  if [[ -n "${PANEL_CHECKS}" ]]; then sep=","; fi
  PANEL_CHECKS="${PANEL_CHECKS}${sep}{\"key\":\"$(json_escape "${key}")\",\"value\":\"$(json_escape "${value}")\",\"code\":\"${code}\"}"
  if [[ -n "${code}" && "${code}" != "ok" ]]; then
    PANEL_CODES="${PANEL_CODES}${PANEL_CODES:+,}${code}"
  fi
}

panel_remediation() { # <code>
  case "$1" in
    panel_missing) printf '未找到面板插件目录；运行本脚本或仓库根目录 install.sh --panel-only 安装。' ;;
    manifest_missing) printf '插件目录缺少 plugin.json 清单；重新安装面板插件。' ;;
    manifest_invalid) printf '插件清单 plugin.json 无法读取或没有版本号；重新安装面板插件。' ;;
    backend_missing) printf '插件缺少原生后台；重新安装面板插件。' ;;
    backend_not_runnable) printf '原生后台无法启动；可能是架构不匹配或被 Gatekeeper 拦截，先清除 quarantine 再重试。' ;;
    version_mismatch) printf '插件清单与原生后台版本不一致；重新安装面板插件以同时更新两者。' ;;
    package_backend_missing) printf '发布包内缺少当前平台的原生后台；重新下载完整发布包。' ;;
    package_backend_not_runnable) printf '发布包内的原生后台无法启动；下载可能不完整，重新下载发布包。' ;;
    *) printf '' ;;
  esac
}

panel_doctor_json() {
  # Nothing here may abort before stdout carries a verdict: the caller parses
  # JSON. A permission error on plugin.json once killed the script at `sed`.
  set +e
  trap - ERR
  local backend="${TARGET_DIR}/sidecars/status/agy-desktop-backend"
  local manifest="${TARGET_DIR}/plugin.json"
  local package_dir="" package_backend="" package_version="" plugin_version="" backend_version="" installed=false
  SCRIPT_SELF="${BASH_SOURCE[0]:-}"
  if [[ -n "${SCRIPT_SELF}" && -f "${SCRIPT_SELF}" ]]; then
    package_dir="$(cd "$(dirname "${SCRIPT_SELF}")" && pwd)"
  fi
  package_backend="${package_dir}/sidecars/status/agy-desktop-backend"

  panel_check "platform" "$(uname -s) $(uname -m)" "ok"
  if [[ -d "${TARGET_DIR}" ]]; then
    installed=true
    panel_check "panel.dir" "${TARGET_DIR}" "ok"
    if [[ -f "${manifest}" ]]; then
      panel_check "panel.manifest" "${manifest}" "ok"
      plugin_version="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "${manifest}" 2>/dev/null | head -1 || true)"
      plugin_version="$(printf '%s' "${plugin_version}" | tr -d '[:space:]')"
      if [[ -n "${plugin_version}" ]]; then
        panel_check "panel.version" "${plugin_version}" "ok"
      else
        panel_check "panel.version" "unreadable or missing version" "manifest_invalid"
      fi
    else
      panel_check "panel.manifest" "${manifest}" "manifest_missing"
    fi
    if [[ -f "${backend}" ]]; then
      if backend_version="$("${backend}" --version 2>&1)"; then
        panel_check "backend.version" "${backend_version}" "ok"
        local backend_ver="${backend_version##* }"
        if [[ -n "${plugin_version}" && -n "${backend_ver}" && "${plugin_version}" != "${backend_ver}" ]]; then
          panel_check "backend.version_match" "${plugin_version} != ${backend_ver}" "version_mismatch"
        fi
      else
        panel_check "backend.version" "${backend_version:-no output}" "backend_not_runnable"
      fi
    else
      panel_check "backend.path" "${backend}" "backend_missing"
    fi
  else
    panel_check "panel.dir" "${TARGET_DIR}" "panel_missing"
  fi

  # A release archive is self-contained: a missing or unusable backend in the
  # package means installing from it cannot work. Archives keep the binaries in
  # bin/<platform>/ (prepare_backend copies them into sidecars/ at install
  # time); a source checkout has sidecars/status/ already.
  if [[ -n "${package_dir}" ]]; then
    # Same resolution `prepare_backend` installs from: reading it here must not
    # modify the package (no copy, no chmod).
    package_backend="$(resolve_native_source "${package_dir}" 2>/dev/null || true)"
    if [[ -n "${package_backend}" && -f "${package_backend}" ]]; then
      if package_version="$("${package_backend}" --version 2>&1)"; then
        panel_check "package.backend" "${package_version}" "ok"
      else
        panel_check "package.backend" "${package_version:-no output}" "package_backend_not_runnable"
      fi
    else
      panel_check "package.backend" "${package_dir}/bin/<platform>/agy-desktop-backend (or sidecars/status)" "package_backend_missing"
    fi
  fi

  local ok=true codes_json="" remediation_json="" code
  if [[ -n "${PANEL_CODES}" ]]; then ok=false; fi
  local old_ifs="${IFS}"
  IFS=','
  for code in ${PANEL_CODES:-}; do
    codes_json="${codes_json}${codes_json:+,}\"${code}\""
    remediation_json="${remediation_json}${remediation_json:+,}\"${code}\":\"$(json_escape "$(panel_remediation "${code}")")\""
  done
  IFS="${old_ifs}"
  set -e
  printf '{"ok":%s,"scope":"plugin","complete":false,"installed":%s,"platform":"%s","release":"%s","codes":[%s],"remediation":{%s},"checks":[%s],"note":"%s"}\n' \
    "${ok}" "${installed}" "$(json_escape "$(uname -s) $(uname -m)")" "$(json_escape "${RELEASE_TAG}")" \
    "${codes_json}" "${remediation_json}" "${PANEL_CHECKS}" \
    "$(json_escape "这里只诊断面板插件本身。完整诊断（CLI 状态栏、签名/quarantine、套件版本一致性）请运行仓库根目录 install.sh --doctor --json。")"
  if [[ "${ok}" == "true" ]]; then return 0; fi
  return 1
}

if [[ "${DOCTOR}" -eq 1 ]]; then
  SCRIPT_SELF="${BASH_SOURCE[0]:-}"
  SCRIPT_DIR=""
  if [[ -n "${SCRIPT_SELF}" && -f "${SCRIPT_SELF}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_SELF}")" && pwd)"
  fi
  if [[ -n "${SCRIPT_DIR}" && -f "${SCRIPT_DIR}/../install.sh" ]]; then
    exec bash "${SCRIPT_DIR}/../install.sh" "${ORIG_ARGS[@]}"
  fi
  if [[ "${JSON}" -eq 1 ]]; then
    panel_doctor_json
    exit $?
  fi
  echo "Full installation diagnostics require the repository root install.sh:"
  echo "  curl -fsSL https://raw.githubusercontent.com/${REPO_SLUG}/main/install.sh | bash -s -- --doctor"
  BACKEND="${TARGET_DIR}/sidecars/status/agy-desktop-backend"
  if [[ -x "${BACKEND}" ]]; then
    "${BACKEND}" --version
    exit 0
  fi
  echo "Plugin backend not found at ${BACKEND}" >&2
  exit 1
fi

# Release archives contain all supported native targets. Source installations
# use the binary produced by ./build.sh; no interpreter is needed at runtime.
prepare_backend() {
  local plugin_dir="$1" native_source
  native_source="$(resolve_native_source "${plugin_dir}" 2>/dev/null || true)"
  if [[ -n "${native_source}" && -f "${native_source}" ]]; then
    install -m 755 "${native_source}" "${plugin_dir}/sidecars/status/agy-desktop-backend.new"
    mv -f "${plugin_dir}/sidecars/status/agy-desktop-backend.new" "${plugin_dir}/sidecars/status/agy-desktop-backend"
  fi
  if [[ ! -f "${plugin_dir}/sidecars/status/agy-desktop-backend" ]]; then
    echo "Error: native backend missing for $(uname -s)/$(uname -m) (platform: $(detect_platform 2>/dev/null || printf 'unknown'))." >&2
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
    [[ -f "${TARGET_DIR}/sidecars/status/agy-notch" ]] && chmod +x "${TARGET_DIR}/sidecars/status/agy-notch"
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
  [[ -f "${TARGET_DIR}/sidecars/status/agy-notch" ]] && chmod +x "${TARGET_DIR}/sidecars/status/agy-notch"
  echo "Installed AGY Desktop Status to ${TARGET_DIR}"
fi

echo ""
echo "AGY Desktop Status is ready!"
echo "1. Open or restart Antigravity Desktop."
echo "2. Click '+' in the top-right auxiliary pane -> select 'AGY Status'."
