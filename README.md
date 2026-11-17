# AGY 状态栏

使用 AGY 官方状态栏 JSON，在默认状态栏下方显示最近一次请求的缓存命中率和缓存读取量。命中率按缓存读取 /（未缓存输入 + 缓存读取）计算；缺失数据、输入为零或缓存写入非零时显示 `--`。该口径取决于模型和 AGY 提供的字段语义。

速度是最近一次已完成模型请求的平均输出速度，包含思考 token；使用只读查询当前会话数据库（`~/.gemini/antigravity-cli/conversations/<conversation_id>.db`）中未公开的生成元数据。它不是实时速度；数据缺失、耗时过短或数值异常时显示 `--`。AGY 更新可能改变该格式。

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
