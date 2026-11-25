#!/usr/bin/env bash
# Unified installer for the agy-vitals suite:
#   * agy-statusline      — Antigravity CLI terminal statusline
#   * AGY Desktop Status  — Antigravity 2.0 Desktop right-pane panel plugin
#
# Works both as `curl -fsSL .../install.sh | bash` and from a source checkout.
set -euo pipefail

REPO_SLUG="${AGY_STATUSLINE_REPO:-2fa0/agy-vitals}"
RELEASE_TAG="${AGY_STATUSLINE_TAG:-latest}"
CLI_DIR="${AGY_CLI_DIR:-${HOME}/.gemini/antigravity-cli}"
PLUGIN_NAME="agy-desktop-status"
PLUGIN_DIR="${HOME}/.gemini/config/plugins/${PLUGIN_NAME}"
SETTINGS_FILE="${AGY_STATUSLINE_SETTINGS:-${HOME}/.gemini/agy-statusline/config.json}"

WANT_CLI=1
WANT_PANEL=1
MODE="install"
DOCTOR_JSON=0
PANEL_INSTALL_MODE="--copy"

info() { printf '  %s\n' "$*"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() {
  printf '  \033[31m✗\033[0m %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法: ./install.sh [选项]

默认同时安装 CLI 状态栏和 Desktop 右侧面板。

选项:
  --cli-only        安装 CLI 状态栏（macOS 同时安装刘海支持）
  --panel-only      只安装 Desktop 面板插件
  --link            面板用软链接指向当前源码目录（仅本地源码安装时有效）
  --doctor          只打印安装状态诊断，不做任何修改
  --json            与 --doctor 搭配：输出机器可读诊断（含稳定错误码）
  --uninstall       移除 CLI 状态栏与面板插件
  -h, --help        显示本帮助

环境变量:
  AGY_STATUSLINE_TAG   固定版本标签，例如 v0.4.0（默认 latest）
  AGY_STATUSLINE_REPO  覆盖仓库 slug（默认 2fa0/agy-vitals）
  AGY_STATUSLINE_RELEASE_BASE  直接指定发布包基址（镜像/离线分发）
  AGY_CLI_DIR          覆盖 CLI 安装目录
EOF
}

# ---------------------------------------------------------------- 平台与下载

detect_platform() {
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) printf 'macos-arm64' ;;
    Linux-x86_64 | Linux-amd64) printf 'linux-x64' ;;
    Linux-aarch64 | Linux-arm64) printf 'linux-arm64' ;;
    *) printf '' ;;
  esac
}

fetch() { # <url> <dest>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    die "需要 curl 或 wget 才能下载发布包。"
  fi
}

release_base() {
  if [[ -n "${AGY_STATUSLINE_RELEASE_BASE:-}" ]]; then
    printf '%s' "${AGY_STATUSLINE_RELEASE_BASE}"
  elif [[ "${RELEASE_TAG}" == "latest" ]]; then
    printf 'https://github.com/%s/releases/latest/download' "${REPO_SLUG}"
  else
    printf 'https://github.com/%s/releases/download/%s' "${REPO_SLUG}" "${RELEASE_TAG}"
  fi
}

# ------------------------------------------------------- macOS Gatekeeper 处理

# Gatekeeper only evaluates files carrying com.apple.quarantine. Browsers set it,
# curl/wget never do — but a user who unzipped a browser download already has it,
# so strip it unconditionally before trusting the binaries. The strip is then
# verified: swallowing a failure here would surface later as a Gatekeeper kill
# with a misleading error message.
strip_quarantine() { # <path> <label>
  [[ "$(uname -s)" == "Darwin" ]] || return 0
  [[ -e "$1" ]] || return 0
  xattr -dr com.apple.quarantine "$1" 2>/dev/null || true
  local left
  left="$(xattr -r -p com.apple.quarantine "$1" 2>/dev/null || true)"
  if [[ -n "${left}" ]]; then
    warn "$2 仍有文件带 quarantine 标记："
    printf '%s\n' "${left}" | head -5 >&2
    info "请手动执行：xattr -dr com.apple.quarantine \"$1\""
    return 1
  fi
}

quarantine_state() { # <path>
  if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '不适用'
  elif xattr -p com.apple.quarantine "$1" >/dev/null 2>&1; then
    printf '存在（会被 Gatekeeper 拦截）'
  else
    printf '无'
  fi
}

signature_state() { # <bin>
  if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '不适用'
    return
  fi
  local sig
  sig="$(codesign -dv --verbose=2 "$1" 2>&1 | awk -F= '/^Signature=/{print $2}')"
  case "${sig}" in
    adhoc) printf 'adhoc（开源构建，未公证）' ;;
    "") printf '无签名' ;;
    *) printf '%s' "${sig}" ;;
  esac
}

signature_integrity() { # <bin>
  if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '不适用'
    return
  fi
  if codesign --verify --strict "$1" >/dev/null 2>&1; then
    printf '完整'
  else
    printf '损坏/缺失（系统会直接 SIGKILL）'
  fi
}

spctl_state() {
  case "$(spctl --status 2>/dev/null || true)" in
    *enabled*) printf '启用（带 quarantine 的文件会被评估）' ;;
    *disabled*) printf '已关闭（不评估 quarantine）' ;;
    *) printf '未知' ;;
  esac
}

mdm_state() {
  local out
  out="$(profiles status -type enrollment 2>/dev/null || true)"
  case "${out}" in
    *"MDM enrollment: Yes"*) printf '受 MDM 管理（策略可能要求 Developer ID 签名）' ;;
    *"MDM enrollment: No"*) printf '未纳管' ;;
    *) printf '未知' ;;
  esac
}

developer_id_policy() {
  local out
  out="$(defaults read /Library/Preferences/com.apple.security.syspolicy 2>/dev/null || true)"
  case "${out}" in
    *"AllowIdentifiedDevelopers = 1"*) printf '要求 Developer ID（ad-hoc 会被拒，只能由 IT 按 CDHash 加白名单）' ;;
    "") printf '无托管策略（默认：仅评估带 quarantine 的文件）' ;;
    *) printf '存在托管策略，见 /Library/Preferences/com.apple.security.syspolicy' ;;
  esac
}

# ------------------------------------------------------- 发布包完整性校验

sha256_of() { # <file>
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

verify_checksum() { # <asset-name> <file>
  local name="$1" path="$2" expected actual
  if [[ ! -f "${TMP_DIR}/SHA256SUMS.txt" ]]; then
    return 0
  fi
  expected="$(awk -v n="${name}" '$2 == n || $2 == "*" n {print $1; exit}' "${TMP_DIR}/SHA256SUMS.txt")"
  if [[ -z "${expected}" ]]; then
    warn "校验清单里没有 ${name}，跳过完整性校验。"
    return 0
  fi
  actual="$(sha256_of "${path}")"
  if [[ "${actual}" != "${expected}" ]]; then
    warn "完整性校验失败：${name}"
    info "期望 ${expected}"
    info "实际 ${actual}"
    die "下载可能被篡改或不完整，已中止安装。"
  fi
  ok "完整性校验 ${name}"
}

# --------------------------------------------------------------- 安装后自检

# A Gatekeeper denial is SIGKILL: no stdout, no stderr, no exit message the user
# can act on. Probing here turns a silent white panel into an actionable error.
probe_binary() { # <bin> <install-root> <label>
  local bin="$1" root="$2" label="$3" out
  if out="$("${bin}" --version 2>&1)"; then
    ok "${label}: ${out}"
    return 0
  fi
  warn "${label} 无法启动。"
  case "${out}" in
    *Killed* | *"code signature"* | *"not be opened"*)
      info "macOS Gatekeeper 拦截了该二进制。执行下面这条命令后重试："
      info "  xattr -dr com.apple.quarantine \"${root}\""
      ;;
    "")
      info "无任何输出（可能是签名或架构不匹配）。请运行 --doctor 查看详情："
      info "  ./install.sh --doctor"
      ;;
    *)
      info "错误输出：${out}"
      ;;
  esac
  exit 1
}

# --------------------------------------------------------------------- 安装

install_cli() { # <tmpdir>
  local tmp="$1" src
  step "安装 CLI 状态栏"
  if [[ -n "${LOCAL_ROOT}" ]]; then
    src="${LOCAL_ROOT}/agy-statusline"
    [[ -f "${src}" ]] || die "本地模式需要先运行 ./build.sh 生成 agy-statusline。"
    mkdir -p "${CLI_DIR}"
    install -m 755 "${src}" "${CLI_DIR}/agy-statusline"
    if [[ "$(uname -s)" == "Darwin" ]]; then
      local sidecars="${LOCAL_ROOT}/desktop-panel/sidecars/status"
      [[ -f "${sidecars}/agy-desktop-backend" && -f "${sidecars}/agy-notch" ]] ||
        die "macOS CLI 刘海支持需要先运行 ./desktop-panel/build.sh。"
      mkdir -p "${CLI_DIR}/sidecars/status"
      install -m 755 "${sidecars}/agy-desktop-backend" "${CLI_DIR}/sidecars/status/agy-desktop-backend"
      install -m 755 "${sidecars}/agy-notch" "${CLI_DIR}/sidecars/status/agy-notch"
    fi
  else
    info "下载 agy-statusline-${PLATFORM}.tar.gz ..."
    fetch "$(release_base)/agy-statusline-${PLATFORM}.tar.gz" "${tmp}/cli.tar.gz"
    verify_checksum "agy-statusline-${PLATFORM}.tar.gz" "${tmp}/cli.tar.gz"
    mkdir -p "${CLI_DIR}"
    tar -xzf "${tmp}/cli.tar.gz" -C "${CLI_DIR}"
    chmod +x "${CLI_DIR}/agy-statusline"
    if [[ "$(uname -s)" == "Darwin" ]]; then
      if [[ -f "${CLI_DIR}/sidecars/status/agy-desktop-backend" && -f "${CLI_DIR}/sidecars/status/agy-notch" ]]; then
        chmod +x "${CLI_DIR}/sidecars/status/agy-desktop-backend" "${CLI_DIR}/sidecars/status/agy-notch"
      else
        warn "该发布包仅包含终端状态栏；CLI 刘海支持需要安装较新版本。"
      fi
    fi
  fi
  strip_quarantine "${CLI_DIR}" "CLI 安装目录" || die "无法清除 CLI 目录的 quarantine 标记。"
  probe_binary "${CLI_DIR}/agy-statusline" "${CLI_DIR}" "agy-statusline"
  if [[ "$(uname -s)" == "Darwin" && -f "${CLI_DIR}/sidecars/status/agy-desktop-backend" ]]; then
    probe_binary "${CLI_DIR}/sidecars/status/agy-desktop-backend" "${CLI_DIR}" "CLI 刘海后台"
  fi
}

install_panel() { # <tmpdir>
  local tmp="$1" root mode
  step "安装 Desktop 右侧面板"
  if [[ -n "${LOCAL_ROOT}" ]]; then
    root="${LOCAL_ROOT}/desktop-panel"
    [[ -f "${root}/sidecars/status/agy-desktop-backend" ]] ||
      die "本地模式需要先运行 ./desktop-panel/build.sh 生成原生后台。"
    "${root}/install.sh" "${PANEL_INSTALL_MODE}"
  else
    # A symlink into the extracted temp dir would break the moment we clean up.
    mode="${PANEL_INSTALL_MODE}"
    if [[ "${mode}" == "--link" ]]; then
      warn "--link 仅适用于本地源码安装，发布包改为复制安装。"
      mode="--copy"
    fi
    info "下载 agy-desktop-status-plugin.tar.gz ..."
    fetch "$(release_base)/agy-desktop-status-plugin.tar.gz" "${tmp}/plugin.tar.gz"
    verify_checksum "agy-desktop-status-plugin.tar.gz" "${tmp}/plugin.tar.gz"
    mkdir -p "${tmp}/plugin"
    tar -xzf "${tmp}/plugin.tar.gz" -C "${tmp}/plugin"
    root="${tmp}/plugin/${PLUGIN_NAME}"
    [[ -f "${root}/plugin.json" ]] || root="${tmp}/plugin"
    ( cd "${root}" && ./install.sh "${mode}" )
    rm -rf "${root}"
  fi
  strip_quarantine "${PLUGIN_DIR}" "插件目录" || die "无法清除插件目录的 quarantine 标记。"
  probe_binary "${PLUGIN_DIR}/sidecars/status/agy-desktop-backend" "${PLUGIN_DIR}" "agy-desktop-backend"
}

# ------------------------------------------------------------------- 诊断

row() { printf '  %s: %s\n' "$1" "$2"; }

# --------------------------------------------------- 机器可读诊断（--doctor --json）

# Every failure gets a stable code so an agent (or a wrapper script) can branch
# on it instead of pattern-matching Chinese prose.
DOCTOR_CHECKS=""
DOCTOR_CODES=""

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r\n\t'; }

doctor_check() { # <key> <value> <code|ok>
  local key="$1" value="$2" code="$3" sep=""
  if [[ -n "${DOCTOR_CHECKS}" ]]; then sep=","; fi
  DOCTOR_CHECKS="${DOCTOR_CHECKS}${sep}{\"key\":\"$(json_escape "${key}")\",\"value\":\"$(json_escape "${value}")\",\"code\":\"${code}\"}"
  if [[ -n "${code}" && "${code}" != "ok" ]]; then
    DOCTOR_CODES="${DOCTOR_CODES}${DOCTOR_CODES:+,}${code}"
  fi
}

remediation() { # <code>
  case "$1" in
    cli_missing) printf '未找到 CLI 状态栏；运行 ./install.sh --cli-only 安装。' ;;
    cli_quarantine) printf 'CLI 目录带有 quarantine 标记；执行 xattr -dr com.apple.quarantine "%s"。' "${CLI_DIR}" ;;
    cli_signature_invalid) printf 'CLI 二进制签名损坏，macOS 会直接 SIGKILL；重新安装即可。' ;;
    cli_not_runnable) printf 'CLI 二进制无法执行；可能是架构不匹配或被 Gatekeeper 拦截，先清除 quarantine 再重试。' ;;
    panel_missing) printf '未找到面板插件；运行 ./install.sh --panel-only 安装，然后重启 Antigravity Desktop。' ;;
    backend_missing) printf '插件缺少原生后台；重新安装面板插件。' ;;
    backend_quarantine) printf '插件目录带有 quarantine 标记；执行 xattr -dr com.apple.quarantine "%s"。' "${PLUGIN_DIR}" ;;
    backend_signature_invalid) printf '原生后台签名损坏；重新安装面板插件。' ;;
    backend_not_runnable) printf '原生后台无法启动；面板会一直空白，先清除 quarantine 再重启 Antigravity Desktop。' ;;
    version_mismatch) printf '插件清单与原生后台版本不一致；重新安装面板插件以同时更新两者。' ;;
    mdm_requires_developer_id) printf '这台机器受 MDM 托管且要求 Developer ID 签名，ad-hoc 构建会被拒绝；请 IT 按 CDHash 加白名单或改用自建签名。' ;;
    statusline_not_configured) printf 'CLI 已安装但 settings.json 未配置 statusLine；在 AGY 里运行 /statusline 或按诊断输出手动添加。' ;;
    *) printf '' ;;
  esac
}

doctor_json() {
  local cli_bin backend manifest version plugin_version cli_version backend_version settings cli_ok=0
  local sig_kind
  cli_bin="${CLI_DIR}/agy-statusline"
  backend="${PLUGIN_DIR}/sidecars/status/agy-desktop-backend"
  manifest="${PLUGIN_DIR}/plugin.json"
  settings="${CLI_DIR}/settings.json"
  version=""
  if [[ -n "${LOCAL_ROOT}" && -f "${LOCAL_ROOT}/VERSION" ]]; then
    version="$(tr -d '[:space:]' < "${LOCAL_ROOT}/VERSION")"
  fi

  doctor_check "platform" "$(uname -s) $(uname -m)" "ok"
  doctor_check "release_channel" "${RELEASE_TAG}" "ok"

  if [[ -f "${cli_bin}" ]]; then
    doctor_check "cli.path" "${cli_bin}" "ok"
    if [[ "$(quarantine_state "${cli_bin}")" == 存在* ]]; then
      doctor_check "cli.quarantine" "present" "cli_quarantine"
    else
      doctor_check "cli.quarantine" "none" "ok"
    fi
    if [[ "$(uname -s)" == "Darwin" ]]; then
      if [[ "$(signature_integrity "${cli_bin}")" == 完整 ]]; then
        doctor_check "cli.signature" "valid" "ok"
      else
        doctor_check "cli.signature" "invalid" "cli_signature_invalid"
      fi
    fi
    if cli_version="$("${cli_bin}" --version 2>&1)"; then
      doctor_check "cli.version" "${cli_version}" "ok"
      cli_ok=1
    else
      doctor_check "cli.version" "${cli_version:-no output}" "cli_not_runnable"
    fi
    if [[ "${cli_ok}" == "1" ]]; then
      if [[ -f "${settings}" ]] && grep -q 'agy-statusline' "${settings}" 2>/dev/null; then
        doctor_check "cli.statusline" "configured" "ok"
      else
        doctor_check "cli.statusline" "missing" "statusline_not_configured"
      fi
    fi
  else
    doctor_check "cli.path" "${cli_bin}" "cli_missing"
  fi

  if [[ -d "${PLUGIN_DIR}" ]]; then
    doctor_check "panel.dir" "${PLUGIN_DIR}" "ok"
    plugin_version="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "${manifest}" 2>/dev/null | head -1)"
    doctor_check "panel.version" "${plugin_version:-unknown}" "ok"
    if [[ -f "${backend}" ]]; then
      if [[ "$(quarantine_state "${backend}")" == 存在* ]]; then
        doctor_check "backend.quarantine" "present" "backend_quarantine"
      else
        doctor_check "backend.quarantine" "none" "ok"
      fi
      if [[ "$(uname -s)" == "Darwin" ]]; then
        if [[ "$(signature_integrity "${backend}")" == 完整 ]]; then
          doctor_check "backend.signature" "valid" "ok"
        else
          doctor_check "backend.signature" "invalid" "backend_signature_invalid"
        fi
      fi
      if backend_version="$("${backend}" --version 2>&1)"; then
        doctor_check "backend.version" "${backend_version}" "ok"
        local backend_ver="${backend_version##* }"
        if [[ -n "${plugin_version}" && -n "${backend_ver}" && "${plugin_version}" != "${backend_ver}" ]]; then
          doctor_check "backend.version_match" "${plugin_version} != ${backend_ver}" "version_mismatch"
        elif [[ -n "${version}" && "${plugin_version}" != "${version}" ]]; then
          doctor_check "plugin.bundle_version" "${version}" "version_mismatch"
        fi
      else
        doctor_check "backend.version" "${backend_version:-no output}" "backend_not_runnable"
      fi
    else
      doctor_check "backend.path" "${backend}" "backend_missing"
    fi
  else
    doctor_check "panel.dir" "${PLUGIN_DIR}" "panel_missing"
  fi

  if [[ "$(uname -s)" == "Darwin" ]] && [[ "$(developer_id_policy)" == 要求* ]]; then
    local target_bin=""
    for target_bin in "${cli_bin}" "${backend}"; do
      if [[ -f "${target_bin}" ]]; then
        sig_kind="$(signature_state "${target_bin}" 2>/dev/null || true)"
        if [[ "${sig_kind}" == adhoc* ]]; then
          doctor_check "policy.developer_id" "adhoc-blocks" "mdm_requires_developer_id"
          break
        fi
      fi
    done
  fi

  local ok=true codes_json="" remediation_json="" code sep=""
  if [[ -n "${DOCTOR_CODES}" ]]; then ok=false; fi
  local old_ifs="${IFS}"
  IFS=','
  for code in ${DOCTOR_CODES:-}; do
    codes_json="${codes_json}${codes_json:+,}\"${code}\""
    remediation_json="${remediation_json}${remediation_json:+,}\"${code}\":\"$(json_escape "$(remediation "${code}")")\""
  done
  IFS="${old_ifs}"
  printf '{"ok":%s,"platform":"%s","release":"%s","codes":[%s],"remediation":{%s},"checks":[%s]}\n' \
    "${ok}" "$(json_escape "$(uname -s) $(uname -m)")" "$(json_escape "${RELEASE_TAG}")" \
    "${codes_json}" "${remediation_json}" "${DOCTOR_CHECKS}"
  [[ "${ok}" == "true" ]]
}

doctor() {
  local cli_bin backend manifest
  cli_bin="${CLI_DIR}/agy-statusline"
  backend="${PLUGIN_DIR}/sidecars/status/agy-desktop-backend"
  manifest="${PLUGIN_DIR}/plugin.json"

  step "AGY Statusline 诊断"
  row "平台" "$(uname -s) $(uname -m)"
  row "发布通道" "${RELEASE_TAG}"
  row "包获取方式" "$([[ -n "${LOCAL_ROOT}" ]] && printf '本地源码 %s' "${LOCAL_ROOT}" || printf '远程发布包')"

  step "系统安全环境"
  row "Gatekeeper" "$(spctl_state)"
  row "设备纳管" "$(mdm_state)"
  row "Developer ID 策略" "$(developer_id_policy)"

  step "CLI 状态栏"
  row "路径" "${cli_bin}"
  if [[ -f "${cli_bin}" ]]; then
    row "quarantine" "$(quarantine_state "${cli_bin}")"
    row "代码签名" "$(signature_state "${cli_bin}")"
    row "签名完整性" "$(signature_integrity "${cli_bin}")"
    local out
    if out="$("${cli_bin}" --version 2>&1)"; then row "自检" "${out}"; else row "自检" "失败（${out:-无输出}）"; fi
  else
    row "状态" "未安装"
  fi

  step "Desktop 面板"
  row "插件目录" "${PLUGIN_DIR}"
  if [[ -d "${PLUGIN_DIR}" ]]; then
    row "插件版本" "$([[ -f "${manifest}" ]] && sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "${manifest}" | head -1 || printf '未知')"
    if [[ -f "${backend}" ]]; then
      row "quarantine" "$(quarantine_state "${backend}")"
      row "代码签名" "$(signature_state "${backend}")"
      row "签名完整性" "$(signature_integrity "${backend}")"
      local out
      if out="$("${backend}" --version 2>&1)"; then row "自检" "${out}"; else row "自检" "失败（${out:-无输出}）"; fi
    else
      row "原生后台" "缺失（${backend}）"
    fi
  else
    row "状态" "未安装"
  fi

  step "说明"
  info "ad-hoc 签名 + 无公证是开源构建的预期状态；只要没有 quarantine 标记，"
  info "Gatekeeper 不会评估这些二进制，可以正常执行。"
  info "若「Developer ID 策略」显示要求 Developer ID，说明这台机器由 IT 托管，"
  info "ad-hoc 二进制会被直接拒绝，只能让 IT 按 CDHash 加白名单，或改用自建签名。"
  info "若面板空白：确认插件目录无 quarantine，然后重启 Antigravity Desktop。"
}

# ------------------------------------------------------------------- 卸载

uninstall() {
  step "卸载 AGY Statusline"
  if [[ -d "${PLUGIN_DIR}" ]]; then
    rm -rf "${PLUGIN_DIR}"
    ok "已移除 ${PLUGIN_DIR}"
  else
    info "面板插件未安装"
  fi
  if [[ -f "${CLI_DIR}/agy-statusline" ]]; then
    rm -f "${CLI_DIR}/agy-statusline"
    ok "已移除 ${CLI_DIR}/agy-statusline"
  else
    info "CLI 状态栏未安装"
  fi
  rm -f "${CLI_DIR}/sidecars/status/agy-desktop-backend" "${CLI_DIR}/sidecars/status/agy-notch"
  info "如果 settings.json 里仍配置了 statusLine，请手动删除（或在 AGY 里运行 /statusline delete）。"
}

# ------------------------------------------------------------------- 入口

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cli-only) WANT_PANEL=0 ;;
    --panel-only) WANT_CLI=0 ;;
    --link) PANEL_INSTALL_MODE="--link" ;;
    --copy) PANEL_INSTALL_MODE="--copy" ;;
    --doctor) MODE="doctor" ;;
    --json) DOCTOR_JSON=1; MODE="doctor" ;;
    --uninstall) MODE="uninstall" ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf '未知选项: %s\n\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

# `curl | bash` leaves BASH_SOURCE empty, which is how we tell remote from local.
LOCAL_ROOT=""
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
if [[ -n "${SCRIPT_SOURCE}" && -f "${SCRIPT_SOURCE}" ]]; then
  candidate="$(cd "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
  if [[ -f "${candidate}/main.zig" && -f "${candidate}/desktop-panel/plugin.json" ]]; then
    LOCAL_ROOT="${candidate}"
  fi
fi

if [[ "${MODE}" == "doctor" ]]; then
  if [[ "${DOCTOR_JSON}" == "1" ]]; then
    doctor_json
    exit $?
  fi
  doctor
  exit 0
fi
if [[ "${MODE}" == "uninstall" ]]; then
  uninstall
  exit 0
fi

PLATFORM="$(detect_platform)"

if [[ -z "${PLATFORM}" && -z "${LOCAL_ROOT}" ]]; then
  die "尚不支持 $(uname -s) $(uname -m) 的原生发布包。
     macOS 目前仅提供 Apple Silicon 产物（Intel Mac 请从源码构建）；
     Windows 请使用 PowerShell 安装脚本：
     https://raw.githubusercontent.com/${REPO_SLUG}/main/desktop-panel/install.ps1"
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agy-statusline-install.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

if [[ -z "${LOCAL_ROOT}" ]]; then
  fetch "$(release_base)/SHA256SUMS.txt" "${TMP_DIR}/SHA256SUMS.txt" 2>/dev/null ||
    warn "本次发布未提供 SHA256SUMS.txt，跳过完整性校验。"
fi

step "AGY Statusline 安装"
row "平台" "${PLATFORM:-$(uname -s) $(uname -m)（本地构建）}"
row "发布通道" "${RELEASE_TAG}"

if [[ "${WANT_CLI}" == "0" && "${WANT_PANEL}" == "0" ]]; then
  die "没有选中任何组件；请使用默认（同时安装）、--cli-only 或 --panel-only。"
fi
if [[ "${WANT_CLI}" == "1" ]]; then install_cli "${TMP_DIR}"; fi
if [[ "${WANT_PANEL}" == "1" ]]; then install_panel "${TMP_DIR}"; fi

step "完成"
seed_settings() {
  if [[ -f "${SETTINGS_FILE}" ]]; then
    info "面板配置已存在，保留不动：${SETTINGS_FILE}"
    return 0
  fi
  mkdir -p "$(dirname "${SETTINGS_FILE}")"
  cat >"${SETTINGS_FILE}" <<'JSON'
{
  "enabled": true,
  "layout": "compact",
  "pollSec": 0,
  "lowSpeedWarnTokS": 50,
  "thresholds": { "waitSec": 20, "stallSec": 25, "toolGraceSec": 120 },
  "modules": { "session": true, "quota": true, "history": true, "context": true, "models": true },
  "debug": false
}
JSON
  ok "已写入默认面板配置 ${SETTINGS_FILE}"
  info "改这个文件即可调整布局/模块/阈值，约 1 个轮询周期内生效，无需重启 Antigravity。"
}
if [[ "${WANT_PANEL}" == "1" ]]; then
  seed_settings
fi
if [[ "${WANT_CLI}" == "1" ]]; then
  info "CLI：在 ~/.gemini/antigravity-cli/settings.json 中加入"
  printf '\n    {\n      "statusLine": {\n        "type": "command",\n        "command": "%s",\n        "stack_with_default": true\n      }\n    }\n\n' "${CLI_DIR}/agy-statusline"
  if [[ "$(uname -s)" == "Darwin" && -f "${CLI_DIR}/sidecars/status/agy-notch" ]]; then
    info "CLI：下一次状态栏刷新会自动启动刘海；关闭 Desktop 不会关闭 CLI 刘海。"
  fi
fi
if [[ "${WANT_PANEL}" == "1" ]]; then
  info "面板：重启 Antigravity Desktop，右上角辅助栏 + → AGY Status"
fi
info "诊断：重新运行本脚本并加 --doctor（源码目录下为 ./install.sh --doctor）"
