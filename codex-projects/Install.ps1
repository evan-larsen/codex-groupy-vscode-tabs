[CmdletBinding()]
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$launcher = Join-Path $PSScriptRoot 'codex-projects.ps1'
$documents = [Environment]::GetFolderPath('MyDocuments')
$profiles = @(
    (Join-Path $documents 'WindowsPowerShell\profile.ps1'),
    (Join-Path $documents 'PowerShell\profile.ps1')
)
$start = '# BEGIN codex-projects launcher'
$end = '# END codex-projects launcher'
$pattern = '(?ms)^' + [regex]::Escape($start) + '\r?\n.*?^' + [regex]::Escape($end) + '(?:\r?\n)?'
$escapedLauncher = $launcher.Replace("'", "''")
$block = @"
$start
function global:codex-projects { & '$escapedLauncher' @args }
$end
"@
foreach ($path in $profiles) {
    $content = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { '' }
    if ($Uninstall -and -not (Test-Path -LiteralPath $path)) { continue }
    if ($content.Contains($start) -xor $content.Contains($end)) { throw "Incomplete launcher block in $path; refusing to edit it." }
    $updated = [regex]::Replace($content, $pattern, '')
    if (-not $Uninstall) {
        if ($updated.Length -gt 0 -and -not $updated.EndsWith("`n")) { $updated += "`r`n" }
        $updated += $block + "`r`n"
    }
    if ($updated -ne $content) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        if (Test-Path -LiteralPath $path) {
            Copy-Item -LiteralPath $path -Destination ($path + '.codex-projects-' + [guid]::NewGuid().ToString('N') + '.bak')
        }
        [IO.File]::WriteAllText($path, $updated, (New-Object Text.UTF8Encoding($true)))
    }
    Write-Host "Updated $path"
}
if (-not $Uninstall) { Write-Host 'Installed. Open a new PowerShell window and run codex-projects.' }
