$ErrorActionPreference = "Stop"

param(
    [switch]$Uninstall,
    [switch]$Link
)

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
New-Item -ItemType Directory -Force -Path $PluginsRoot | Out-Null

if (Test-Path $TargetDir) {
    Remove-Item -Recurse -Force $TargetDir
}

if ($Link) {
    New-Item -ItemType SymbolicLink -Path $TargetDir -Target $ScriptDir | Out-Null
    Write-Host "Linked $TargetDir -> $ScriptDir"
} else {
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    Get-ChildItem -Path $ScriptDir -Force | Where-Object {
        $_.Name -notin @("node_modules", "__pycache__", ".DS_Store")
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
