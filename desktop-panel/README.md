# AGY Desktop Status — Antigravity 2.0 右侧常驻状态面板插件

专为 **Antigravity 2.0 桌面端** 打造的只读性能与上下文遥测面板（不与 CLI 版 Zig 代码耦合）。基于官方 **Plugin + UI Sidecar (`SIDECAR_UI_ENTRYPOINT_AUX_PANE`) + Lifecycle Hooks**（同时保留 MCP App 兼容）架构，在右侧辅助栏常驻展示：

- **平均输出速度 (`Last avg speed`)**：最近一次模型生成的输出速度（`tok/s`），低于 `50 tok/s` 自动黄色高亮提示，附带最近 12 次生成的速度柱状趋势图与明细列表。
- **轮次 / 会话耗时**：基于本地 `transcript.jsonl` 时间戳计算当前轮次耗时与整个会话总耗时。
- **上下文占用 (`Ctx`)** & **Cache 命中率 (`Cache hit`)**：只读解析本地会话库中的输入、缓存读取与缓存写入字段（若本地未落盘对应字段则显示 `--`，不伪造数据）。

## 合规与安全保障

- **100% 官方规范**：仅使用 Antigravity 官方插件机制（`plugin.json`、`sidecars/status/sidecar.json`、`hooks.json`、`mcp_config.json`）。
- **只读与零网络（Local Read-Only · Zero Network）**：SQLite 连接强制使用 `mode=ro` 与 `PRAGMA query_only = ON`；无任何外部网络请求、不读取 OAuth Token 或凭据、不探测未公开的内部 RPC 接口、不绕过任何配额或权限限制。
- **开箱即用**：运行时仅依赖 Antigravity 内置 Node (`sidecar_sdk`) 与系统 `python3`（零第三方 Python 运行时依赖），前端单文件 HTML 已预构建在 `dist/index.html` 中，普通用户无需安装 Node.js 或执行 `npm build`。

---

## 傻瓜式安装与使用

### 方式 A：一行命令自动安装（macOS / Linux）

```sh
curl -fsSL https://raw.githubusercontent.com/2fa0/agy-statusline/main/desktop-panel/install.sh | bash
```

### 方式 B：从 Release 压缩包或本地目录安装

- **macOS / Linux**：
  ```sh
  chmod +x ./install.sh
  ./install.sh          # 本地源码目录默认软链接安装；也可传 --copy 独立复制文件
  ```
- **Windows (PowerShell)**：
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\install.ps1
  ```

### 打开右侧常驻面板

1. 安装或更新插件后，**打开或重启 Antigravity Desktop**；
2. 在任意对话窗口右上角辅助栏点击 **`+` 菜单** → 选择 **`AGY Status`**；
3. 顶部下拉框默认**自动跟随当前面板所属会话 / 活跃会话**，也可随时下拉切换查看历史会话。

### 卸载

- **macOS / Linux**：
  ```sh
  ./install.sh --uninstall
  ```
- **Windows (PowerShell)**：
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
  ```

---

## 开发者指南：从源码重新构建前端 UI & 运行测试

如果你修改了 `ui/src/app.ts` 或 `ui/src/template.html`，可以在本地（需 Node.js >= 20）重新打包单文件 `dist/index.html`：

```sh
cd ui
npm install
npm run build
```

运行后端与协议单元测试：

```sh
python3 -m unittest discover -s tests
```
