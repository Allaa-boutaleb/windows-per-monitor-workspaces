#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'IndependentMonitorWorkspaces'),
    [string]$StartupDirectory = ([Environment]::GetFolderPath('Startup')),
    [string]$RecoveryShortcutDirectory = ([Environment]::GetFolderPath('Programs')),
    [switch]$NoStartup
)

$ErrorActionPreference = 'Stop'
$installedScript = Join-Path $InstallRoot 'IndependentMonitorWorkspaces.ahk'
$shortcutPath = Join-Path $StartupDirectory 'Independent Monitor Workspaces.lnk'
$fallbackStartupPath = Join-Path $StartupDirectory 'Independent Monitor Workspaces.cmd'
$recoveryShortcutPath = Join-Path $RecoveryShortcutDirectory 'Independent Monitor Workspaces Recovery Hotkey 2.lnk'
$legacyRecoveryShortcutPaths = @(
    (Join-Path $RecoveryShortcutDirectory 'Independent Monitor Workspaces Recovery.lnk'),
    (Join-Path $RecoveryShortcutDirectory 'Independent Monitor Workspaces Recovery Hotkey.lnk')
)
$bundledRuntime = Test-Path -LiteralPath (Join-Path $InstallRoot 'runtime\AutoHotkey.exe')
$metadataPath = Join-Path $InstallRoot 'install.json'
if (Test-Path -LiteralPath $metadataPath) {
    try {
        $bundledRuntime = [bool](Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json).BundledRuntime
    } catch {
        Write-Warning 'Install metadata could not be read; removal will continue.'
    }
}

function Resolve-PhysicalFilePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not ('IndependentMonitorWorkspaces.UninstallerPhysicalPath' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
namespace IndependentMonitorWorkspaces {
    public static class UninstallerPhysicalPath {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(
            IntPtr file, StringBuilder path, uint pathLength, uint flags);
        public static string Resolve(string path) {
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete)) {
                StringBuilder result = new StringBuilder(32768);
                uint length = GetFinalPathNameByHandle(
                    stream.SafeFileHandle.DangerousGetHandle(), result,
                    (uint)result.Capacity, 0);
                if (length == 0 || length >= result.Capacity)
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                string finalPath = result.ToString();
                if (finalPath.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase))
                    return @"\\" + finalPath.Substring(8);
                if (finalPath.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase))
                    return finalPath.Substring(4);
                return finalPath;
            }
        }
    }
}
"@
    }
    return [IndependentMonitorWorkspaces.UninstallerPhysicalPath]::Resolve($Path)
}

function Get-WorkspaceProcesses {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)

    $comparisonPath = [IO.Path]::GetFullPath($ScriptPath)
    $comparisonPaths = @($comparisonPath)
    if (Test-Path -LiteralPath $comparisonPath) {
        try {
            $physicalPath = Resolve-PhysicalFilePath -Path $comparisonPath
            if ($physicalPath -ne $comparisonPath) { $comparisonPaths += $physicalPath }
        } catch { }
    }
    return @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $commandLine = $_.CommandLine
            $commandLine -and @($comparisonPaths | Where-Object {
                $commandLine.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0
            }).Count -gt 0
        })
}

function Stop-WorkspaceScript {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)

    $running = @(Get-WorkspaceProcesses -ScriptPath $ScriptPath)
    if (-not $running) { return }

    if (-not ('IndependentMonitorWorkspaces.UninstallerNativeMethods' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace IndependentMonitorWorkspaces {
    public static class UninstallerNativeMethods {
        private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
        [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
        public static void CloseProcessWindows(uint targetPid) {
            EnumWindows((hwnd, lParam) => {
                uint pid;
                GetWindowThreadProcessId(hwnd, out pid);
                if (pid == targetPid) PostMessage(hwnd, 0x0010, IntPtr.Zero, IntPtr.Zero);
                return true;
            }, IntPtr.Zero);
        }
    }
}
"@
    }

    foreach ($process in $running) {
        [IndependentMonitorWorkspaces.UninstallerNativeMethods]::CloseProcessWindows([uint32]$process.ProcessId)
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 100
        $stillRunning = @(Get-WorkspaceProcesses -ScriptPath $ScriptPath)
    } while ($stillRunning -and [DateTime]::UtcNow -lt $deadline)

    if ($stillRunning) {
        throw 'The workspace process did not close cleanly, so no files were removed. Press Win+Ctrl+Shift+Esc, exit it from the tray icon, and rerun the uninstaller.'
    }
}

if (Test-Path -LiteralPath $installedScript) {
    Stop-WorkspaceScript -ScriptPath $installedScript
}

if (-not $NoStartup) {
    Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fallbackStartupPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $recoveryShortcutPath -Force -ErrorAction SilentlyContinue
    foreach ($legacyPath in $legacyRecoveryShortcutPaths) {
        Remove-Item -LiteralPath $legacyPath -Force -ErrorAction SilentlyContinue
    }
}

if (Test-Path -LiteralPath $InstallRoot) {
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force
}

Write-Host 'Independent Monitor Workspaces was removed.' -ForegroundColor Green
if ($bundledRuntime) {
    Write-Host 'Its isolated portable AutoHotkey runtime was removed too.'
} else {
    Write-Host 'The user-managed AutoHotkey runtime was left unchanged.'
}
