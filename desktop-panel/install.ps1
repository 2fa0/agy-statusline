param(
    [switch]$Uninstall,
    [switch]$Link
)

$ErrorActionPreference = "Stop"

$PluginName = "agy-desktop-status"
$PluginsRoot = Join-Path $HOME ".gemini\config\plugins"
$TargetDir = Join-Path $PluginsRoot $PluginName

if ($Uninstall) {
    if (Test-Path $TargetDir) {
        Remove-Item -Recurse -Force $TargetDir
        Write-Host "Removed $TargetDir"
    } else {
        Write-Host "$TargetDir is not installed."
    }
    exit 0
}

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$NativeSource = Join-Path $ScriptDir "bin\windows-x64\agy-desktop-backend.exe"
$NativeTarget = Join-Path $ScriptDir "sidecars\status\agy-desktop-backend.exe"
if (Test-Path $NativeSource) { Copy-Item $NativeSource $NativeTarget -Force }
if (!(Test-Path $NativeTarget)) {
    throw "Native Windows backend missing. Download the release plugin ZIP, or build backend.zig for Windows first."
}
$SidecarPath = Join-Path $ScriptDir "sidecars\status\sidecar.json"
$Sidecar = Get-Content $SidecarPath -Raw | ConvertFrom-Json
$Sidecar.command = "./agy-desktop-backend.exe"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($SidecarPath, ($Sidecar | ConvertTo-Json -Depth 20), $Utf8NoBom)
$HooksPath = Join-Path $ScriptDir "hooks.json"
$NativeHooks = (Get-Content $HooksPath -Raw).Replace("./sidecars/status/agy-desktop-backend hook", "./sidecars/status/agy-desktop-backend.exe hook")
[System.IO.File]::WriteAllText($HooksPath, $NativeHooks, $Utf8NoBom)

New-Item -ItemType Directory -Force -Path $PluginsRoot | Out-Null

$InPlace = [string]::Equals([System.IO.Path]::GetFullPath($TargetDir), [System.IO.Path]::GetFullPath($ScriptDir), [System.StringComparison]::OrdinalIgnoreCase)
if (!$InPlace -and (Test-Path $TargetDir)) {
    Remove-Item -Recurse -Force $TargetDir
}

if ($InPlace) {
    Write-Host "Updated native backend in place at $TargetDir"
} elseif ($Link) {
    New-Item -ItemType SymbolicLink -Path $TargetDir -Target $ScriptDir | Out-Null
    Write-Host "Linked $TargetDir -> $ScriptDir"
} else {
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    Get-ChildItem -Path $ScriptDir -Force | Where-Object {
        $_.Name -notin @("node_modules", "__pycache__", "tests", ".DS_Store")
    } | ForEach-Object {
        $Dest = Join-Path $TargetDir $_.Name
        if ($_.PSIsContainer) {
            if ($_.Name -eq "ui") {
                # Skip node_modules inside ui/ if present
                New-Item -ItemType Directory -Force -Path $Dest | Out-Null
                Get-ChildItem -Path $_.FullName -Force | Where-Object { $_.Name -ne "node_modules" } |
                    Copy-Item -Destination $Dest -Recurse -Force
            } else {
                Copy-Item -Path $_.FullName -Destination $Dest -Recurse -Force
            }
        } else {
            Copy-Item -Path $_.FullName -Destination $Dest -Force
        }
    }
    Write-Host "Installed $PluginName to $TargetDir"
}

Write-Host ""
Write-Host "AGY Desktop Status is ready!"
Write-Host "1. Open or restart Antigravity Desktop."
Write-Host "2. Click '+' in the top-right auxiliary pane -> select 'AGY Status'."
