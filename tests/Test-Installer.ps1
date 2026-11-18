#Requires -Version 5.1
[CmdletBinding()]
param([switch]$SkipLiveDownload)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repoRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repoRoot 'install.ps1'
$uninstaller = Join-Path $repoRoot 'uninstall.ps1'
$sourceScript = Join-Path $repoRoot 'IndependentMonitorWorkspaces.ahk'
$runtimeUrl = 'https://github.com/AutoHotkey/AutoHotkey/releases/download/v2.0.26/AutoHotkey_2.0.26.zip'
$runtimeHash = '43522AA3122A57784AC5DB30ABF85C2244475C36ACD7796E2C993355F9E926AE'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('IMW installer tests ' + $PID + ' ' + [char]0x00FC)
$installRoot = Join-Path $tempRoot 'installed app'
$startupRoot = Join-Path $tempRoot 'startup folder'
$recoveryRoot = Join-Path $tempRoot 'programs folder'
$runtimeArchive = Join-Path $tempRoot 'AutoHotkey.zip'
$oldPath = $env:PATH

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "ASSERTION FAILED: $Message. Expected '$Expected', received '$Actual'."
    }
}

function Assert-ScriptParses {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-Equal 0 @($errors).Count "PowerShell parser errors in $Path"
}

function Get-State {
    param([string[]]$Roots)
    $state = @()
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            $state += "MISSING:$root"
            continue
        }
        foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName) {
            $state += '{0}:{1}' -f $file.FullName, (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
    }
    return ($state -join '|')
}

function Assert-InstallerFails {
    param([string]$Name, [scriptblock]$Action)
    $failed = $false
    try {
        & $Action
    } catch {
        $failed = $true
        Write-Host "Expected failure [$Name]: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
    Assert-True $failed "$Name should fail"
}

try {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $tempRoot, $startupRoot, $recoveryRoot -Force | Out-Null

    Write-Host 'Checking PowerShell syntax...' -ForegroundColor Cyan
    Assert-ScriptParses $installer
    Assert-ScriptParses $uninstaller

    Write-Host 'Downloading the pinned official runtime fixture...' -ForegroundColor Cyan
    Invoke-WebRequest -UseBasicParsing -Uri $runtimeUrl -OutFile $runtimeArchive
    Assert-Equal $runtimeHash (Get-FileHash -LiteralPath $runtimeArchive -Algorithm SHA256).Hash 'Runtime archive checksum'

    Write-Host 'Testing a clean offline install with no winget or AutoHotkey on PATH...' -ForegroundColor Cyan
    $env:PATH = "$env:SystemRoot\System32\WindowsPowerShell\v1.0;$env:SystemRoot\System32"
    & $installer -InstallRoot $installRoot -StartupDirectory $startupRoot -RecoveryShortcutDirectory $recoveryRoot -SourceScriptPath $sourceScript -RuntimeArchivePath $runtimeArchive -NoLaunch

    $installedScript = Join-Path $installRoot 'IndependentMonitorWorkspaces.ahk'
    $installedRuntime = Join-Path $installRoot 'runtime\AutoHotkey.exe'
    $shortcutPath = Join-Path $startupRoot 'Independent Monitor Workspaces.lnk'
    $recoveryShortcutPath = Join-Path $recoveryRoot 'Independent Monitor Workspaces Recovery Hotkey 2.lnk'
    Assert-True (Test-Path -LiteralPath $installedScript) 'Workspace script should be installed'
    Assert-True (Test-Path -LiteralPath $installedRuntime) 'Portable runtime should be installed'
    Assert-True (Test-Path -LiteralPath $shortcutPath) 'Startup shortcut should be installed'
    Assert-True (Test-Path -LiteralPath $recoveryShortcutPath) 'Recovery shortcut should be installed'
    $metadata = Get-Content -LiteralPath (Join-Path $installRoot 'install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([bool]$metadata.BundledRuntime) 'Install metadata should mark the runtime as bundled'
    Assert-Equal $installedRuntime $metadata.AutoHotkeyPath 'Install metadata runtime path'

    Write-Host 'Testing bounded previous/next navigation...' -ForegroundColor Cyan
    # AutoHotkey is a GUI program; piping its output makes PowerShell wait for
    # it and record the exit code.
    & $installedRuntime /ErrorStdOut $installedScript --navigation-self-test | Out-Host
    Assert-Equal 0 $LASTEXITCODE 'Navigation boundary self-test exit code'
    & (Join-Path $PSScriptRoot 'Test-FullscreenOverview.ps1') -AutoHotkeyPath $installedRuntime

    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
    Assert-Equal $installedRuntime $shortcut.TargetPath 'Startup shortcut target'
    Assert-Equal ('"' + $installedScript + '"') $shortcut.Arguments 'Startup shortcut arguments'
    Assert-Equal '' $shortcut.Hotkey 'Startup shortcut should not own the recovery hotkey'
    $recoveryShortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($recoveryShortcutPath)
    Assert-Equal $installedRuntime $recoveryShortcut.TargetPath 'Recovery shortcut target'
    Assert-Equal ('"' + $installedScript + '"') $recoveryShortcut.Arguments 'Recovery shortcut arguments'
    Assert-Equal 'ALT+CTRL+SHIFT+R' $recoveryShortcut.Hotkey.ToUpperInvariant() 'Explorer recovery hotkey'

    Write-Host 'Testing idempotent recovery-hotkey preservation...' -ForegroundColor Cyan
    $recoveryWriteTime = (Get-Item -LiteralPath $recoveryShortcutPath).LastWriteTimeUtc.Ticks
    Start-Sleep -Milliseconds 1100
    & $installer -InstallRoot $installRoot -StartupDirectory $startupRoot -RecoveryShortcutDirectory $recoveryRoot -SourceScriptPath $sourceScript -RuntimeArchivePath $runtimeArchive -NoLaunch
    Assert-Equal $recoveryWriteTime (Get-Item -LiteralPath $recoveryShortcutPath).LastWriteTimeUtc.Ticks 'Normal update should preserve the registered recovery shortcut'

    Write-Host 'Testing native Unicode shortcut fallback...' -ForegroundColor Cyan
    & $installer -InstallRoot $installRoot -StartupDirectory $startupRoot -RecoveryShortcutDirectory $recoveryRoot -SourceScriptPath $sourceScript -RuntimeArchivePath $runtimeArchive -ForceStartupFallback -NoLaunch
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
    Assert-Equal $installedRuntime $shortcut.TargetPath 'Native fallback shortcut target'
    Assert-Equal ('"' + $installedScript + '"') $shortcut.Arguments 'Native fallback shortcut arguments'
    $recoveryShortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($recoveryShortcutPath)
    Assert-Equal 'ALT+CTRL+SHIFT+R' $recoveryShortcut.Hotkey.ToUpperInvariant() 'Native fallback recovery hotkey'

    $baseline = Get-State @($installRoot, $startupRoot, $recoveryRoot)

    Write-Host 'Testing preflight failure preservation...' -ForegroundColor Cyan
    $badHeader = Join-Path $tempRoot 'bad-header.ahk'
    [IO.File]::WriteAllText($badHeader, 'not an AutoHotkey script')
    Assert-InstallerFails 'invalid header' {
        & $installer -InstallRoot $installRoot -StartupDirectory $startupRoot -RecoveryShortcutDirectory $recoveryRoot -SourceScriptPath $badHeader -RuntimeArchivePath $runtimeArchive -NoLaunch
    }
    Assert-Equal $baseline (Get-State @($installRoot, $startupRoot, $recoveryRoot)) 'Invalid header must preserve installed files and shell entries'

    $badSyntax = Join-Path $tempRoot 'bad-syntax.ahk'
    [IO.File]::WriteAllText($badSyntax, '#Requires AutoHotkey v2' + [Environment]::NewLine + 'this is invalid (')
    Assert-InstallerFails 'invalid AutoHotkey syntax' {
        & $installer -InstallRoot $installRoot -StartupDirectory $startupRoot -RecoveryShortcutDirectory $recoveryRoot -SourceScriptPath $badSyntax -RuntimeArchivePath $runtimeArchive -NoLaunch
    }
    Assert-Equal $baseline (Get-State @($installRoot, $startupRoot, $recoveryRoot)) 'Invalid syntax must preserve installed files and shell entries'

    Assert-InstallerFails 'wrong runtime checksum' {
        & $installer -InstallRoot $installRoot -StartupDirectory $startupRoot -RecoveryShortcutDirectory $recoveryRoot -SourceScriptPath $sourceScript -RuntimeArchivePath $runtimeArchive -RuntimeArchiveSha256 ('0' * 64) -NoLaunch
    }
    Assert-Equal $baseline (Get-State @($installRoot, $startupRoot, $recoveryRoot)) 'Wrong checksum must preserve installed files and shell entries'

    $fakeArchive = Join-Path $tempRoot 'not-a-zip.zip'
    [IO.File]::WriteAllText($fakeArchive, 'not a zip archive')
    $fakeHash = (Get-FileHash -LiteralPath $fakeArchive -Algorithm SHA256).Hash
    Assert-InstallerFails 'malformed runtime archive' {
        & $installer -InstallRoot $installRoot -StartupDirectory $startupRoot -RecoveryShortcutDirectory $recoveryRoot -SourceScriptPath $sourceScript -RuntimeArchivePath $fakeArchive -RuntimeArchiveSha256 $fakeHash -NoLaunch
    }
    Assert-Equal $baseline (Get-State @($installRoot, $startupRoot, $recoveryRoot)) 'Malformed archive must preserve installed files and shell entries'

    Write-Host 'Testing rollback after the install directory swap...' -ForegroundColor Cyan
    $startupFile = Join-Path $tempRoot 'startup-is-a-file'
    [IO.File]::WriteAllText($startupFile, 'forces Startup creation to fail')
    $rootBaseline = Get-State @($installRoot)
    Assert-InstallerFails 'post-swap Startup failure' {
        & $installer -InstallRoot $installRoot -StartupDirectory $startupFile -RecoveryShortcutDirectory $recoveryRoot -SourceScriptPath $sourceScript -RuntimeArchivePath $runtimeArchive -NoLaunch
    }
    Assert-Equal $rootBaseline (Get-State @($installRoot)) 'Post-swap failure must restore the previous install'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $tempRoot -Force | Where-Object { $_.Name -like '.imw-*' }).Count 'Transactions should not leave temporary directories'

    Write-Host 'Testing user-managed AutoHotkey override...' -ForegroundColor Cyan
    $externalRuntime = Join-Path $tempRoot 'user managed AutoHotkey.exe'
    Copy-Item -LiteralPath $installedRuntime -Destination $externalRuntime
    & $uninstaller -InstallRoot $installRoot -StartupDirectory $startupRoot -RecoveryShortcutDirectory $recoveryRoot
    Assert-True (-not (Test-Path -LiteralPath $installRoot)) 'Bundled installation should uninstall cleanly'

    $externalInstall = Join-Path $tempRoot 'external runtime install'
    & $installer -InstallRoot $externalInstall -StartupDirectory $startupRoot -RecoveryShortcutDirectory $recoveryRoot -SourceScriptPath $sourceScript -AutoHotkeyPath $externalRuntime -NoStartup -NoLaunch
    $externalMetadata = Get-Content -LiteralPath (Join-Path $externalInstall 'install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (-not [bool]$externalMetadata.BundledRuntime) 'External runtime should not be marked as bundled'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $externalInstall 'runtime'))) 'External runtime should not be copied'
    & $uninstaller -InstallRoot $externalInstall -StartupDirectory $startupRoot -RecoveryShortcutDirectory $recoveryRoot -NoStartup
    Assert-True (Test-Path -LiteralPath $externalRuntime) 'Uninstall must not remove a user-managed runtime'
    & $uninstaller -InstallRoot $externalInstall -StartupDirectory $startupRoot -RecoveryShortcutDirectory $recoveryRoot -NoStartup

    if (-not $SkipLiveDownload) {
        Write-Host 'Testing the public one-command download path...' -ForegroundColor Cyan
        $liveInstall = Join-Path $tempRoot 'live download install'
        & $installer -InstallRoot $liveInstall -StartupDirectory $startupRoot -RecoveryShortcutDirectory $recoveryRoot -NoStartup -NoLaunch
        Assert-True (Test-Path -LiteralPath (Join-Path $liveInstall 'runtime\AutoHotkey.exe')) 'Live install should download the runtime'
        Assert-True (Test-Path -LiteralPath (Join-Path $liveInstall 'IndependentMonitorWorkspaces.ahk')) 'Live install should download the workspace script'
        & $uninstaller -InstallRoot $liveInstall -StartupDirectory $startupRoot -RecoveryShortcutDirectory $recoveryRoot -NoStartup
    }

    Write-Host ''
    Write-Host 'All installer tests passed.' -ForegroundColor Green
} finally {
    $env:PATH = $oldPath
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
