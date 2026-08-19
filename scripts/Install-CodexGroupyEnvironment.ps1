[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$BackupOnly,
    [string]$RestoreBackup,
    [switch]$SkipStartupTask,
    [switch]$SkipStartSupervisor,
    [switch]$RestartGroupy
)

$ErrorActionPreference = 'Stop'

$scriptRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$repoRoot = (Split-Path -Path $scriptRoot -Parent)
$backupRoot = Join-Path $repoRoot 'backups\groupy-settings'
$supervisorPath = Join-Path $scriptRoot 'CodexGroupySupervisor.ps1'
$startWrapperPath = Join-Path $scriptRoot 'Start-CodexGroupyTools.ps1'

$groupyBaseKey = 'HKCU:\Software\Stardock\Groupy'
$groupyRegKey = 'HKCU\Software\Stardock\Groupy'
$groupyIniKey = 'HKCU:\Software\Stardock\Groupy\Groupy.ini\Groupy'

$desiredRegistry = @(
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'AllowHideWin11Tabs'; Value = 0 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'AlsoRegisterCtrlKeys'; Value = 1 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'AlsoRegisterRenameKey'; Value = 0 },
    # Restored VS Code windows should reunite after Windows logon. Groupy's condition
    # preserves explicitly detached Groupy groups such as Ctrl+Shift+N creates.
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'AlwaysGroupIdentical'; Value = 1 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'AlwaysPaintSingleTab'; Value = 1 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'AskedAboutDelayGrouping'; Value = 1 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'AutoHideMode'; Value = 0 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'DefinedHotKeyRename'; Value = 458865 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'ExplorerMiddleButton'; Value = 0 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'ForceShowAddOnAll'; Value = 1 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'G2_ActiveBarColour'; Value = 1184274 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'G2_ActiveTabColour'; Value = 4294967295 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'G2_ForceNoAnimsOnTabs'; Value = 0 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'G2_InactiveBarColour'; Value = 2039583 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'G2_InactiveTabColour'; Value = 4294967295 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'G2_NoSepLine'; Value = 0 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'G2_OldNewTabMode'; Value = 1 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'G2_SquareTabs'; Value = 1 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'GroupNewCtrl'; Value = 1 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'GroupyGroupMode'; Value = 0 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'GroupyHotKey'; Value = 1 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'HideGroupyIcon'; Value = 1 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'HideTitleText'; Value = 0 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'InclusionListMode'; Value = 1 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'MergeTitlebar'; Value = 0 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'NeverShowClose'; Value = 1 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'NewInstallDone'; Value = 1 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'SetupDefaultRules'; Value = 1 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'SetupDefaultRules2'; Value = 1 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'ShowCloseAll'; Value = 0 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'ShowCloseOnActive'; Value = 0 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'ShowCloseOnAll'; Value = 0 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'ShowIcon'; Value = 0 },
    [pscustomobject]@{ Path = $groupyIniKey; Name = 'VariableTabSizes'; Value = 0 },

    [pscustomobject]@{ Path = "$groupyIniKey\AddTab"; Name = 'cmd.exe'; Value = 1 },
    [pscustomobject]@{ Path = "$groupyIniKey\AddTab"; Name = 'explorer.exe'; Value = 1 },
    [pscustomobject]@{ Path = "$groupyIniKey\AddTab"; Name = 'Microsoft.WindowsNotepad_8wekyb3d8bbwe!App'; Value = 1 },
    [pscustomobject]@{ Path = "$groupyIniKey\AddTab"; Name = 'notepad.exe'; Value = 1 },
    [pscustomobject]@{ Path = "$groupyIniKey\AddTab"; Name = 'powershell.exe'; Value = 1 },

    [pscustomobject]@{ Path = "$groupyIniKey\AlwaysShowTabs"; Name = 'cmd.exe'; Value = 1 },
    [pscustomobject]@{ Path = "$groupyIniKey\AlwaysShowTabs"; Name = 'Code.exe'; Value = 1 },
    [pscustomobject]@{ Path = "$groupyIniKey\AlwaysShowTabs"; Name = 'explorer.exe'; Value = 1 },
    [pscustomobject]@{ Path = "$groupyIniKey\AlwaysShowTabs"; Name = 'powershell.exe'; Value = 1 },

    [pscustomobject]@{ Path = "$groupyIniKey\Exclusions"; Name = 'Code.exe'; Value = 1 },
    [pscustomobject]@{ Path = "$groupyIniKey\TabBackgroundMode"; Name = 'Code.exe'; Value = 1 }
)

function ConvertTo-RegistryUInt32($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [uint32]) { return $Value }
    if ($Value -is [int]) { return [uint32]([int64]$Value -band 0xffffffffL) }
    if ($Value -is [long]) { return [uint32]($Value -band 0xffffffffL) }
    if ($Value -is [string]) {
        $text = $Value.Trim()
        if ($text.Length -eq 0) { return $null }
        if ($text.StartsWith('0x', [StringComparison]::OrdinalIgnoreCase)) {
            return [uint32]([Convert]::ToUInt32($text.Substring(2), 16))
        }
        $parsed = [int64]::Parse($text, [Globalization.CultureInfo]::InvariantCulture)
        return [uint32]($parsed -band 0xffffffffL)
    }
    return [uint32]$Value
}

function Get-CurrentRegistryValue([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    $raw = $item.$Name
    if ($null -eq $raw) { return $null }
    return ConvertTo-RegistryUInt32 $raw
}

function Set-DwordRegistryValue([string]$Path, [string]$Name, [uint32]$Value) {
    if (-not (Test-Path -LiteralPath $Path)) {
        [void](New-Item -Path $Path -Force)
    }

    $existing = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value
    }
    else {
        [void](New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType DWord -Value $Value -Force)
    }
}

function New-GroupyBackup {
    if (-not (Test-Path -LiteralPath $backupRoot)) {
        [void](New-Item -ItemType Directory -Path $backupRoot -Force)
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = Join-Path $backupRoot "GroupySettings-$stamp.reg"
    $regExe = (Get-Command reg.exe -CommandType Application -ErrorAction Stop).Source

    if (Test-Path -LiteralPath $groupyBaseKey) {
        & $regExe export $groupyRegKey $backupPath /y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "reg.exe export failed with exit code $LASTEXITCODE." }
        return $backupPath
    }

    '# Groupy HKCU settings did not exist when this backup was created.' | Set-Content -LiteralPath $backupPath -Encoding UTF8
    return $backupPath
}

function Restore-GroupyBackup([string]$Path) {
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $regExe = (Get-Command reg.exe -CommandType Application -ErrorAction Stop).Source
    & $regExe import $resolved | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg.exe import failed with exit code $LASTEXITCODE." }
    Write-Host "Restored Groupy registry settings from $resolved"
}

function Get-GroupyInstallInfo {
    $keys = @(
        'HKLM:\Software\Stardock\Groupy',
        'HKLM:\Software\WOW6432Node\Stardock\Groupy',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Stardock Groupy',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Stardock Groupy',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Stardock Groupy2',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Stardock Groupy2'
    )

    foreach ($key in $keys) {
        $item = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($item) {
            [pscustomobject]@{
                RegistryKey = $key
                Path = if ($item.Path) { $item.Path } elseif ($item.InstallLocation) { $item.InstallLocation } else { $null }
                Version = if ($item.Version) { $item.Version } elseif ($item.DisplayVersion) { $item.DisplayVersion } else { $null }
            }
        }
    }
}

function Show-Plan {
    $groupyInfo = @(Get-GroupyInstallInfo)
    if ($groupyInfo.Count -gt 0) {
        Write-Host 'Detected Groupy installation:'
        Write-Host (($groupyInfo | Select-Object RegistryKey,Path,Version | Format-Table -AutoSize | Out-String).TrimEnd())
    }
    else {
        Write-Host 'Groupy install info was not found in HKLM. Install Groupy 2 before applying these settings.'
    }

    $rows = foreach ($entry in $desiredRegistry) {
        $current = Get-CurrentRegistryValue -Path $entry.Path -Name $entry.Name
        $desired = ConvertTo-RegistryUInt32 $entry.Value
        [pscustomobject]@{
            Path = $entry.Path.Replace('HKCU:\Software\Stardock\Groupy\Groupy.ini\Groupy', '...\Groupy')
            Name = $entry.Name
            Current = if ($null -eq $current) { '<missing>' } else { $current }
            Desired = $desired
            Action = if ($null -eq $current) { 'create' } elseif ((ConvertTo-RegistryUInt32 $current) -ne $desired) { 'update' } else { 'ok' }
        }
    }

    Write-Host (($rows | Sort-Object Action,Path,Name | Format-Table -AutoSize | Out-String).TrimEnd())

    if (-not $Apply -and -not $BackupOnly) {
        Write-Host ''
        Write-Host 'Dry run only. Re-run with -Apply to back up Groupy settings, write these values, install startup, and start the supervisor.'
    }
}

function Restart-GroupyIfRequested {
    if (-not $RestartGroupy) { return }

    $stopped = @()
    foreach ($processName in @('GroupyConfig', 'GroupyCtrl')) {
        foreach ($process in @(Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                $stopped += "$processName/$($process.Id)"
            }
            catch {
                Write-Warning "Could not stop $processName PID $($process.Id): $($_.Exception.Message)"
            }
        }
    }

    if ($stopped.Count -gt 0) {
        Write-Host "Restart requested; stopped Groupy process(es): $($stopped -join ', ')."
        Write-Host 'If Groupy does not reload automatically, reopen Groupy Configuration or sign out/in.'
    }
    else {
        Write-Host 'Restart requested, but no Groupy UI/control process was running.'
    }
}

if ($RestoreBackup) {
    Restore-GroupyBackup -Path $RestoreBackup
    Write-Host 'Restart Groupy or sign out/in if the restored settings are not reflected immediately.'
    return
}

Show-Plan

if ($BackupOnly) {
    $backupPath = New-GroupyBackup
    Write-Host "Created Groupy settings backup: $backupPath"
    return
}

if (-not $Apply) { return }

$createdBackup = New-GroupyBackup
Write-Host "Created Groupy settings backup: $createdBackup"

foreach ($entry in $desiredRegistry) {
    Set-DwordRegistryValue -Path $entry.Path -Name $entry.Name -Value ([uint32]$entry.Value)
}

Write-Host 'Applied known-good Groupy registry settings for the Codex/VS Code workflow.'

if (-not $SkipStartupTask) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $supervisorPath -InstallStartupTask
    if ($LASTEXITCODE -ne 0) { throw "Failed to install supervisor startup task." }
}

if (-not $SkipStartSupervisor) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startWrapperPath
    if ($LASTEXITCODE -ne 0) { throw "Failed to start Codex/Groupy supervisor." }
}

Restart-GroupyIfRequested

Write-Host ''
Write-Host 'Done. Validate with:'
Write-Host '  .\scripts\CodexGroupySupervisor.ps1 -Status'
