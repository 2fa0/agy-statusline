# agy-statusline — Google Antigravity CLI & Desktop 状态监控套件

> **Google Antigravity (`agy` CLI & Antigravity 2.0 Desktop)** 专属的**本地会话只读、零外部网络请求**性能与额度遥测套件。
> 实时查看 **输出速度 (`tok/s`)**、**Prompt 缓存命中率**、**上下文窗口与压缩曲线**、**按模型用量统计** 以及 **5h / 周额度绝对重置时间**。

<p align="left">
  <img src="https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20Windows-blue?style=flat-square" alt="Platform" />
  <img src="https://img.shields.io/badge/Antigravity-CLI%20%26%20Desktop%202.0-6366f1?style=flat-square" alt="Antigravity CLI & Desktop 2.0" />
  <img src="https://img.shields.io/badge/Network-Zero%20Network%20(100%25%20Local)-16a34a?style=flat-square" alt="Zero Network" />
  <img src="https://img.shields.io/badge/Compliance-Official%20Extension%20API-0ea5e9?style=flat-square" alt="Official Extension API" />
  <img src="https://img.shields.io/badge/Built%20with-Zig-f59e0b?style=flat-square" alt="Built with Zig" />
  <img src="https://img.shields.io/badge/Memory-~3--7%20MB%20RSS-10b981?style=flat-square" alt="Memory ~3-7 MB RSS" />
</p>

## 实景预览（CLI & Desktop 双端并排）

<table>
  <tr>
    <td width="50%" align="center">
      <strong>Antigravity CLI (<code>agy</code>) 终端状态栏</strong><br />
      <sub>Zig 单二进制 · 零依赖 · 终端底部原生集成</sub>
    </td>
    <td width="50%" align="center">
      <strong>Antigravity 2.0 Desktop 右侧常驻面板</strong><br />
      <sub>官方 <code>AUX_PANE</code> Sidecar · 实时速度 · 交互式趋势图</sub>
    </td>
  </tr>
  <tr>
    <td width="50%">
      <img src="./desktop-panel/assets/cli-preview.png" alt="agy-statusline CLI 终端状态栏实景预览" width="100%" />
    </td>
    <td width="50%">
      <img src="./desktop-panel/assets/desktop-preview.png" alt="AGY Desktop Status 右侧常驻面板实景预览" width="100%" />
    </td>
  </tr>
</table>

---

## 为什么选择 agy-statusline？（核心差异一览）

| 维度 | 默认 Antigravity / 常见外部脚本 | `agy-statusline` |
| :--- | :--- | :--- |
| **双端原生覆盖** | 仅支持单端，或依赖额外悬浮窗/外部浏览器 | **CLI + Desktop 双端同源**：终端 `statusLine`（Zig）+ 桌面端右侧常驻 `AUX_PANE` 面板 |
| **生成中实时速度** | 仅在整轮结束后查看耗时，或根本无速度显示 | **流式实时测速 (`≈ tok/s`)**：生成中 1s 轮询估算，结束后自动切换精确均值 + 12 次趋势柱状图（`<50 tok/s` 黄底告警） |
| **额度重置时间** | 仅显示相对倒计时（如“剩 2 天 4 小时”） | **绝对本地重置时间**：直接换算为 `重置于 11/23 周一 11:29`，并自动区分 Gemini / Argon / Claude 3p 额度池 |
| **上下文与压缩真相** | 只看当前占比，难以定位何时触发压缩 | **120 次交互式上下文曲线 + `CHECKPOINT` 压缩标记**（`Compact: N`），不猜阈值、不伪造数据 |
| **缓存与模型拆分** | 缺少 Prompt 缓存命中率或按模型分拆 | **加权缓存命中率（`Cache hit` / `S.Cache`）+ 按模型统计 Token / 命中率 / 均速** |
| **极致资源开销** | 常驻 Node.js / Python 运行时（常驻内存动辄数十至上百 MB） | **同类插件独一档轻量化**：CLI 单二进制约 `582 KB`、用完即退零常驻；桌面端单 Zig 原生后台约 `2.1 MB`（内嵌 `40 KB` 单文件前端），**实测运行期常驻内存仅约 `3.3–6.8 MB RSS`**；配合文件指纹缓存、分块增量解析与空闲降频 / 隐藏暂停轮询 |

---

## 数据访问与隐私说明

> [!IMPORTANT]
> **零外部网络请求 · 会话数据只读（Zero Network & Local Read-Only）**
>
> 1. **仅使用官方扩展入口**：通过 Google Antigravity 官方支持的扩展机制构建——CLI 使用 `statusLine` 扩展协议，Desktop 使用官方 `Plugin` / `UI Sidecar`（`SIDECAR_UI_ENTRYPOINT_AUX_PANE`）与 `Lifecycle Hooks`。
> 2. **全程零外部网络请求**：不发起任何 HTTP / HTTPS / WebSocket 外联请求，不上传、不遥测任何对话或环境信息。
> 3. **零凭据 / Token 接触**：不读取任何 OAuth Token、Cookie、Session Key 或 API 凭据。桌面端额度仅读取 CLI 状态栏自己落盘的本地快照 `quota.json`（仅含百分比与重置时间戳，不含任何账号或凭据）。
> 4. **不探测内部接口、不修改客户端**：不调用或探测任何未公开的内部 RPC 接口，不修改 Antigravity 客户端任何文件，不绕过任何 Google / Antigravity 配额或权限限制。
> 5. **严格本地只读**：SQLite 会话库连接强制使用 `mode=ro` 与 `PRAGMA query_only = ON`（仅当打开已关闭且无 `-wal` 的归档 WAL 数据库时安全回退 `immutable=1` 只读模式）。
>
> *注：本地日志与 SQLite/protobuf 数据格式属于宿主内部落盘格式，而非稳定公开 API，宿主版本升级可能导致部分字段不可用。*

---

## 30 秒快速安装

一条命令同时装好 **CLI 状态栏** 与 **Desktop 右侧面板**。脚本会下载对应平台的原生二进制、按 `SHA256SUMS.txt` 校验完整性、清除 macOS 的 `quarantine` 隔离标记（并回读确认真的清掉了），最后立即自检（被 Gatekeeper 拦截会在那一刻报错，而不是让你面对一个白屏面板）：

```sh
curl -fsSL https://raw.githubusercontent.com/2fa0/agy-statusline/main/install.sh | bash
```

- 只装一端：`... | bash -s -- --cli-only` 或 `--panel-only`
- 固定版本：`AGY_STATUSLINE_TAG=v0.4.0 ... | bash`
- **升级 / 重装：再跑一次同一条命令即可**（幂等，覆盖安装）
- 卸载：`... | bash -s -- --uninstall`

装完还剩两步：

1. **CLI**：把下面的 `statusLine` 片段加入 `~/.gemini/antigravity-cli/settings.json`（安装脚本会打印出完整路径）
2. **面板**：重启 Antigravity Desktop，在任意对话右上角辅助栏点击 **`+` → `AGY Status`**

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.gemini/antigravity-cli/agy-statusline",
    "stack_with_default": true
  }
}
```

### 装不上时先跑诊断

```sh
curl -fsSL https://raw.githubusercontent.com/2fa0/agy-statusline/main/install.sh | bash -s -- --doctor
```

会打印平台、安装路径、`quarantine` 状态、代码签名与签名完整性、两个二进制的自检结果，以及**系统安全环境**（Gatekeeper 开关、设备是否受 MDM 纳管、是否被策略要求 Developer ID）——面板白屏、状态栏无输出、企业机器被拒这几类问题基本都在这里能定位。

### macOS 安全机制说明（重要）

本项目用 **ad-hoc 代码签名**（`codesign --sign -`），**没有 Apple Developer ID，也没有公证**。这意味着：

| 安装方式 | 结果 |
| :--- | :--- |
| `curl ... \| bash`（推荐） | ✅ 正常。`curl` 从不写入 `quarantine` 属性，Gatekeeper 不会评估这些二进制 |
| 浏览器下载 `.tar.gz` / `.zip` 后解压运行 | ❌ 被拦。浏览器会打上 `quarantine`，弹出「Apple 无法验证…」，而且新版 macOS 的该对话框只有「完成 / 移到废纸篓」 |

即使已经被拦，修复也只要一行（安装脚本每次运行都会自动执行它）：

```sh
xattr -dr com.apple.quarantine ~/.gemini/config/plugins/agy-desktop-status
xattr -dr com.apple.quarantine ~/.gemini/antigravity-cli
```

> ad-hoc 签名在 Apple Silicon 上是**必需**的（完全未签名的 arm64 二进制会被直接 `Killed: 9`），但它不等于公证，也无法通过 Gatekeeper 的浏览器下载路径。想让「下载双击安装」也能用，只有走 Developer ID + 公证一条路。

#### 这套机制能保证什么、不能保证什么

**能保证**（有实测）：在默认 macOS 配置下走文档里的安装路径，不会因「arm64 未签名」或「quarantine 触发 Gatekeeper」被拦；即使被拦，安装那一刻就会报错并给出修复命令。

**不能保证**（遇到时不是安装器的 bug）：

| 情况 | 说明 |
| :--- | :--- |
| 企业 MDM / 配置档 | 若 `com.apple.security.syspolicy` 要求 Developer ID，ad-hoc 无论有无隔离标记都会被拒。`--doctor` 会直接报告这一点；需联系 IT 按 CDHash 加白名单 |
| 第三方安全软件 / EDR | 它们有独立于 Gatekeeper 的白名单，报错界面也不是 Apple 的 |
| 未来的 macOS | 若评估扩展到非隔离文件，ad-hoc 会整体失效，只能靠公证 |
| 用户后续重新引入隔离属性 | 浏览器重下、AirDrop、从备份恢复都会重新打上；重跑安装器即可修复 |

> Windows 用户请使用 PowerShell 安装脚本，详见下方各章节。

---

## 一、Antigravity 2.0 桌面端右侧面板（`AGY Desktop Status`）

在 Antigravity 2.0 桌面端右侧辅助栏提供常驻监控卡片与可交互趋势图（与对话画布同屏并排展示，不遮挡会话），支持**自动跟随当前活跃会话**、**自适应刷新（活跃时按 `3s` / `5s` / `10s` 刷新，空闲 15s，面板隐藏时暂停；也可选择 `暂停`）**、**深浅色主题自适应**以及手动切换历史会话。

> [!NOTE]
> 入口为官方 `SIDECAR_UI_ENTRYPOINT_AUX_PANE`。Antigravity 2.x 的 sidecar UI 只有 `AUX_PANE` / `FULL_PANE` / `SIDEBAR` 三种入口，**不支持顶栏挂载**，因此无法把状态条贴到窗口上边栏。

### 生成中实时速度（`实时速度`）

模型正在回话时，面板会把“输出速度”卡片切成实时模式：标题变成 `实时速度` 并打上呼吸点，数值是**正在生成的这一步**的速度，页头也会多一个 `生成中 · Ns` 的胶囊：

```
实时速度
≈ 110.7 tok/s
已输出 339 字 · 128 字/s · 2.6s
```

原理：AGY 在生成过程中会先写入这条未完成的 step 行（`PENDING` / `RUNNING` / `GENERATING`），并随着流式文本增长不断重写 `steps.step_payload`。面板只读这一行算出字符增长速率，再用同一会话已完成步骤的「字数 / 输出 token」比例换算成 `≈ tok/s`（实测中文约 `1.15~1.3 字/token`）。**真 token 数只在整步完成后落库**，所以生成中的 tok/s 是估算值（带 `≈`），完成后自动回到精确的平均速度与历史趋势。

生成期间面板会提高到 **1s 一轮**轮询（仍是本地只读，不联网）；上下文占用（`Ctx`）是 prompt 侧实测值，只在每一步完成后刷新，卡片 tooltip 会写明。

### 额度重置时间（不再自己换算 “还剩 2 天 4 小时”）

面板里的 **额度** 标签页把周额度 / 5h 额度的重置写成具体本地时间，例如：

```
Gemini
5小时   今天 11:29       周限   周一 11/23 11:29
```

（鼠标悬浮即可查看 `重置于 ... · 距重置 ...` 明细。）

数据来源说明（**不联网、不读凭据**）：桌面端本身不向插件暴露额度信息，因此 CLI 状态栏在每次渲染时会把 AGY 递交给它的 `quota` 字段（`remaining_fraction` + `reset_in_seconds`）写成本地快照：

- 默认路径：`~/.gemini/agy-statusline/quota.json`（可用 `AGY_STATUSLINE_QUOTA_FILE` 环境变量改写）；
- 只包含百分比与重置时间戳，**不含 token、账号或任何凭据**；
- 长时间没跑过 `agy` CLI 时，面板会按 5h / 7 天的周期把重置时间推算到下一次，并在右上角标注「`时间 · 推算`」（悬浮提示「按 5h / 7 天周期推算」）。

### 会话用量、上下文趋势与模型统计

桌面面板包含三组深度统计，均只读取本地记录，不调用内部 RPC：

- **上下文趋势与压缩事件**：显示最近最多 120 次已完成请求的输入上下文曲线，虚线标出 `status=DONE` 的 `CHECKPOINT`。压缩次数覆盖整份日志；上下文变小不自动算作压缩，也不预设 256k 等压缩阈值。可展开近期记录查看本地时间与数值。
- **最近回复请求 / 会话累计**：在 **用量** 标签页并列展示 token 用量和缓存命中率。累计包含已完成的 `PLANNER_RESPONSE` 与 `CHECKPOINT`；token 按日志的 `input_tokens + cache_read_tokens + output_tokens` 相加，不包含未记录的缓存写入。重复发送的输入会按每次请求累计，并非去重后的上下文大小。
- **按模型统计**：分别展示 token、缓存命中率和平均输出速度；合并同模型的思考档位后缀，缺失模型归入“未知模型”，不使用当前模型回填历史。速度来自本地数据库中能匹配模型的有效样本，按输出总量 / 耗时总量计算，并注明样本数。

只有输入、缓存读取、输出三个字段均有效的请求才进入累计，界面显示“已记录 / 总请求数”覆盖情况。会话缓存命中率为有效请求的缓存读取总量 /（未缓存输入总量 + 缓存读取总量），不是各次百分比的平均。日志缺失时显示未知；缺少速度数据不从日志时间差猜测。

### 桌面端更多安装与卸载方式

#### 从 Releases 下载插件包安装（macOS / Linux / Windows）

> [!NOTE]
> 通过浏览器下载的压缩包会带 `com.apple.quarantine`，请通过下面的 `./install.sh` 安装（会自动清理隔离标记）；切勿直接双击运行解压出的二进制。详见上方 [macOS 安全机制说明](#macos-安全机制说明重要)。

1. 前往 [Releases](https://github.com/2fa0/agy-statusline/releases) 页面下载桌面端插件包：
   - macOS / Linux：`agy-desktop-status-plugin.tar.gz`
   - Windows：`agy-desktop-status-plugin.zip`
2. 解压后运行对应平台的安装脚本：
   - **macOS / Linux**：
     ```sh
     tar -xzf agy-desktop-status-plugin.tar.gz
     cd agy-desktop-status
     ./install.sh
     ```
   - **Windows (PowerShell)**：
     ```powershell
     Expand-Archive -Path agy-desktop-status-plugin.zip -DestinationPath .
     cd agy-desktop-status
     powershell -ExecutionPolicy Bypass -File .\install.ps1
     ```

#### 克隆源码安装（适合开发者自定义修改）

```sh
git clone https://github.com/2fa0/agy-statusline.git
cd agy-statusline/desktop-panel
./build.sh          # 需要 Zig 0.14.1、系统 C 编译器和 SQLite 开发库
./install.sh --link   # 使用软链接安装，本地修改即时生效
```

`--copy` 则复制成独立目录。不传参数时会在仓库内自动选软链接、在解压出来的发布包里自动选复制（避免把插件指向一个你随后会删掉的下载目录）。

#### 卸载桌面端插件

- **macOS / Linux**：
  ```sh
  ~/.gemini/config/plugins/agy-desktop-status/install.sh --uninstall
  ```
- **Windows (PowerShell)**：
  ```powershell
  powershell -ExecutionPolicy Bypass -File "$HOME\.gemini\config\plugins\agy-desktop-status\install.ps1" -Uninstall
  ```

更多关于桌面端插件的架构与前端二次开发说明，请参阅 [desktop-panel/README.md](./desktop-panel/README.md)。

---

## 二、Antigravity CLI 终端状态栏（`agy-statusline`）

轻量、零依赖的 **Google Antigravity CLI (`agy`)** 自定义 `statusLine` 工具（基于 Zig 编写，支持 **macOS / Linux / Windows**），在终端宽度不足时自动折行对齐。

### 展示功能与特性

- **缓存命中率与读取量**（`Cache hit` / `Cache read`）：命中率按 `缓存读取 /（未缓存输入 + 缓存读取）` 计算；缺失数据、输入为零或缓存写入非零时显示 `--`。该口径取决于模型和 AGY 提供的字段语义。
- **上下文占用**（`Ctx: 已用/总上下文`）：优先使用当前轮 `current_usage` 中的输入与缓存 token 之和（缺失时回退到 `total_input_tokens`），对比 `context_window_size` 展示。
- **平均输出速度**（`Last avg speed`）：最近一次已完成模型请求的平均输出速度，包含思考 token；通过只读查询当前会话数据库（`~/.gemini/antigravity-cli/conversations/<conversation_id>.db`）中的生成元数据计算，非实时速度；数据缺失、耗时过短或数值异常时显示 `--`。速度低于 `50 token/s` 时主状态栏切换为黄底黑字提示。
- **压缩与会话日志累计**（`Compact: N` / `Log` / `S.Cache`）：显示压缩次数 `Compact: N`；终端宽度足够时再显示 `Log: … tok` 与 `S.Cache: …%`，分别代表与桌面端相同日志口径的会话累计 token 和加权缓存命中率（用量不完整时附带覆盖数量，例如 `2/3`）。
- **模型剩余额度**（按 AGY 实际返回的 `quota` 字段动态展示，自动兼容 Free / Plus / Pro / Ultra 各档位）：
  - **Gemini**（青色背景）：展示 `5h · weekly` 双窗口（若仅有周额度则显示单值）。
  - **Argon**（亮青色背景）：Pro 套餐下独立计算周额度时单独展示；Ultra / Plus / Free 套餐无独立 Argon 池时自动隐藏。
  - **Claude / 第三方模型**（橙色背景，匹配 `3p` / `claude` / `gpt` / `anthropic`）：展示 `5h · weekly` 双窗口；无第三方池时自动隐藏。
  - 同时把本次 `quota` 快照（百分比 + 重置时间）写入 `~/.gemini/agy-statusline/quota.json`，供桌面端面板换算成绝对本地重置时间；路径可用 `AGY_STATUSLINE_QUOTA_FILE` 覆盖。

### CLI 手动下载与配置说明

#### 1. 从 Releases 页面手动下载（macOS / Linux / Windows）

> [!TIP]
> 通常不需要这节：上方的 `install.sh` 一行命令会下载、校验并安装，同时清除 macOS 隔离属性。

前往本仓库的 [Releases](https://github.com/2fa0/agy-statusline/releases) 页面，下载对应平台的压缩包并解压：

- **Linux (x64)**: `agy-statusline-linux-x64.tar.gz`
- **macOS (Apple Silicon / arm64)**: `agy-statusline-macos-arm64.tar.gz`
- **Windows (x64)**: `agy-statusline-windows-x64.zip`

Linux / macOS 解压后请确保文件有可执行权限，例如：

```sh
tar -xzf agy-statusline-macos-arm64.tar.gz
chmod +x agy-statusline
```

> [!TIP]
> - **macOS 浏览器下载**：若被 Gatekeeper 拦截（后台静默调用时表现为状态栏无输出），请先执行 `xattr -dr com.apple.quarantine /path/to/agy-statusline` 再用 `--version` 自检，原因详见 [macOS 安全机制说明](#macos-安全机制说明重要)。
> - **Intel Mac (`x86_64`) 或 macOS 13 以下系统**：Release 仅提供 `macos-arm64` 产物，请参考下方「从源码构建 CLI」使用 `./build.sh` 本地编译。

#### 2. 配置 AGY CLI

编辑 `~/.gemini/antigravity-cli/settings.json`（Windows 为 `%USERPROFILE%\.gemini\antigravity-cli\settings.json`），添加 `statusLine` 配置：

```json
{
  "statusLine": {
    "type": "command",
    "command": "/path/to/agy-statusline",
    "stack_with_default": true
  }
}
```

Windows 示例（注意路径分隔符转义或使用正斜杠）：

```json
{
  "statusLine": {
    "type": "command",
    "command": "C:/path/to/agy-statusline.exe",
    "stack_with_default": true
  }
}
```

- `stack_with_default`: 设为 `true` 时保留 AGY 默认状态栏并在其下方叠加显示本工具输出；设为 `false` 则仅显示本工具输出。

#### 3. 恢复默认状态栏

在 AGY 中运行 `/statusline delete`，或从 `settings.json` 中删除 `statusLine` 字段即可恢复默认状态栏。

### 从源码构建 CLI

需要 Zig 0.14.1。

- **macOS**（使用系统 clang 和 SQLite）：
  在本目录运行 `./build.sh`；如果 Zig 不在 `PATH` 中，运行 `ZIG=/path/to/zig ./build.sh`。
  构建完可以直接在仓库根目录运行 `./install.sh`（本地源码模式）把 CLI 和面板一起装好，无需联网。
- **Release 静态构建**（Linux x64 / Windows x64）：
  参考 [`.github/workflows/release.yml`](.github/workflows/release.yml) 中使用 SQLite amalgamation 静态链接的方式。

两个二进制都支持 `--version`，版本号来自仓库根目录的 `VERSION` 文件（单一来源，`./install.sh --doctor` 会交叉核对）。
