[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$node = Get-Command node.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
$work = Join-Path (Split-Path $PSScriptRoot -Parent) 'work'
[void][IO.Directory]::CreateDirectory($work)
& $node.Source (Join-Path $PSScriptRoot 'CodexGroupySessionIndex.js') (Join-Path $env:USERPROFILE '.codex') (Join-Path $work 'CodexSessionLookup.json') $PID
exit $LASTEXITCODE
