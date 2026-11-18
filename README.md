# agy-statusline — Google Antigravity CLI (AGY) 增强状态栏

轻量、零依赖的 **Google Antigravity CLI (`agy`)** 自定义 `statusLine` 工具（基于 Zig 编写，支持 **macOS / Linux / Windows**）。在 AGY 默认状态栏下方实时展示 **模型剩余额度（Gemini / Argon / Claude）**、**上下文窗口占用（Context Window）**、**Prompt 缓存命中率（Cache Hit）** 与 **平均输出速度（Token/s）**，并在终端宽度不足时自动折行对齐。

> [!NOTE]
> **合规与隐私说明**：本工具完全基于 Antigravity CLI 官方提供的 `statusLine` 扩展机制运行，**仅被动读取 `agy` 通过 `stdin` 主动传入的 JSON 数据**，**零网络请求、不读取任何 OAuth Token 或 API 凭据、不轮询后端接口、不绕过任何 Google / Antigravity 配额或权限限制**。平均输出速度仅以只读方式读取用户本地会话数据库中的历史生成元数据。

## 展示功能与特性

- **缓存命中率与读取量**（`Cache hit` / `Cache read`）：命中率按 `缓存读取 /（未缓存输入 + 缓存读取）` 计算；缺失数据、输入为零或缓存写入非零时显示 `--`。该口径取决于模型和 AGY 提供的字段语义。
- **上下文占用**（`Ctx: 已用/总上下文`）：优先使用当前轮 `current_usage` 中的输入与缓存 token 之和（缺失时回退到 `total_input_tokens`），对比 `context_window_size` 展示。
- **平均输出速度**（`Last avg speed`）：最近一次已完成模型请求的平均输出速度，包含思考 token；通过只读查询当前会话数据库（`~/.gemini/antigravity-cli/conversations/<conversation_id>.db`）中未公开的生成元数据计算，非实时速度；数据缺失、耗时过短或数值异常时显示 `--`（AGY 更新可能改变该格式）。速度低于 `50 token/s` 时主状态栏切换为黄底黑字提示。
- **模型剩余额度**（按 AGY 实际返回的 `quota` 字段动态展示，自动兼容 Free / Plus / Pro / Ultra 各档位）：
  - **Gemini**（青色背景）：展示 `5h · weekly` 双窗口（若仅有周额度则显示单值）。
  - **Argon**（亮青色背景）：Pro 套餐下独立计算周额度时单独展示；Ultra / Plus / Free 套餐无独立 Argon 池时自动隐藏。
  - **Claude / 第三方模型**（橙色背景，匹配 `3p` / `claude` / `gpt` / `anthropic`）：展示 `5h · weekly` 双窗口；无第三方池时自动隐藏。

## 使用方法

### 1. 下载可执行文件

前往本仓库的 [Releases](https://github.com/2fa0/agy-statusline/releases) 页面，下载对应平台的压缩包并解压：

- **Linux (x64)**: `agy-statusline-linux-x64.tar.gz`
- **macOS (Apple Silicon / arm64)**: `agy-statusline-macos-arm64.tar.gz`
- **Windows (x64)**: `agy-statusline-windows-x64.zip`

Linux / macOS 解压后请确保文件有可执行权限，例如：

```sh
tar -xzf agy-statusline-macos-arm64.tar.gz
chmod +x agy-statusline
```

> **macOS 提示**：首次运行从网络下载的二进制文件如遇到 Gatekeeper 拦截，可执行 `xattr -d com.apple.quarantine /path/to/agy-statusline`。

### 2. 配置 AGY

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

### 3. 恢复默认状态栏

在 AGY 中运行 `/statusline delete`，或从 `settings.json` 中删除 `statusLine` 字段即可恢复默认状态栏。

## 从源码构建

需要 Zig 0.14.1。

- **macOS**（使用系统 clang 和 SQLite）：
  在本目录运行 `./build.sh`；如果 Zig 不在 `PATH` 中，运行 `ZIG=/path/to/zig ./build.sh`。
- **Release 静态构建**（Linux x64 / Windows x64）：
  参考 [`.github/workflows/release.yml`](.github/workflows/release.yml) 中使用 SQLite amalgamation 静态链接的方式。
