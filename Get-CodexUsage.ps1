[CmdletBinding()]
param(
    # Print every quota window returned by app-server instead of selecting the seven-day Codex one.
    [switch]$ShowAllBuckets,

    [ValidateRange(1000, 30000)]
    [int]$TimeoutMs = 10000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Rpc([System.Diagnostics.Process]$Process, [object]$Message) {
    $Process.StandardInput.WriteLine(($Message | ConvertTo-Json -Compress -Depth 10))
    $Process.StandardInput.Flush()
}

function Read-RpcResponse([System.Diagnostics.Process]$Process, [int]$Id, [int]$TimeoutMs) {
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.ElapsedMilliseconds -lt $TimeoutMs) {
        $remaining = [Math]::Max(1, $TimeoutMs - [int]$deadline.ElapsedMilliseconds)
        $lineTask = $Process.StandardOutput.ReadLineAsync()
        if (-not $lineTask.Wait($remaining)) {
            throw "Timed out waiting for Codex app-server response $Id."
        }
        $line = $lineTask.Result
        if ($null -eq $line) { throw "Codex app-server exited while waiting for response $Id." }

        try { $message = $line | ConvertFrom-Json -ErrorAction Stop }
        catch { continue } # stderr is separate, but tolerate any non-protocol startup noise.

        $idProperty = $message.PSObject.Properties['id']
        if ($idProperty -and $idProperty.Value -eq $Id) {
            $errorProperty = $message.PSObject.Properties['error']
            if ($errorProperty -and $errorProperty.Value) { throw "Codex app-server: $($errorProperty.Value.message)" }
            return $message.result
        }
        # Ignore notifications such as account/updated. This one-shot client only needs the reply.
    }
    throw "Timed out waiting for Codex app-server response $Id."
}

function Add-LimitBuckets([Collections.Generic.List[object]]$Target, $Limit, [string]$Source) {
    if ($null -eq $Limit) { return }
    foreach ($slot in 'primary', 'secondary') {
        $bucket = $Limit.$slot
        if ($null -eq $bucket) { continue }
        $Target.Add([pscustomobject]@{
            LimitId = $Limit.limitId
            Source = $Source
            UsedPercent = [double]$bucket.usedPercent
            WindowDurationMins = [int]$bucket.windowDurationMins
            ResetsAt = [long]$bucket.resetsAt
        })
    }
}

$command = Get-Command codex -ErrorAction Stop
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true

# On this machine `codex` is an npm PowerShell shim. Invoke its underlying Node entry point directly
# so redirected JSONL stdin/stdout does not pass through an extra PowerShell host.
if ($command.CommandType -eq 'Application' -and $command.Source -notmatch '\.ps1$') {
    $startInfo.FileName = $command.Source
    $startInfo.Arguments = 'app-server'
} else {
    $npmBin = Split-Path $command.Source -Parent
    $entryPoint = Join-Path $npmBin 'node_modules\@openai\codex\bin\codex.js'
    $node = Get-Command node -CommandType Application -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $entryPoint)) { throw "Could not find Codex npm entry point: $entryPoint" }
    $startInfo.FileName = $node.Source
    $startInfo.Arguments = ('"{0}" app-server' -f $entryPoint.Replace('"', '\"'))
}

$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo

try {
    if (-not $process.Start()) { throw 'Could not start codex app-server.' }

    # Initialize is per app-server connection. It does not create an account, session, or a
    # persistent resource; the process is closed in finally below.
    Write-Rpc $process @{
        method = 'initialize'
        id = 1
        params = @{ clientInfo = @{ name = 'codex-usage-helper'; title = 'Codex Usage Helper'; version = '1.0.0' } }
    }
    # `initialized` acknowledges the handshake. App-server does not accept account requests until
    # it has received this notification; send it before waiting for the initialize reply.
    Write-Rpc $process @{ method = 'initialized'; params = @{} }
    [void](Read-RpcResponse $process 1 $TimeoutMs)

    Write-Rpc $process @{ method = 'account/rateLimits/read'; id = 2 }
    $result = Read-RpcResponse $process 2 $TimeoutMs

    $buckets = [Collections.Generic.List[object]]::new()
    Add-LimitBuckets $buckets $result.rateLimits 'rateLimits'
    if ($result.rateLimitsByLimitId) {
        foreach ($property in $result.rateLimitsByLimitId.PSObject.Properties) {
            Add-LimitBuckets $buckets $property.Value "rateLimitsByLimitId.$($property.Name)"
        }
    }

    if ($ShowAllBuckets) {
        $buckets | Sort-Object LimitId, WindowDurationMins, ResetsAt
        return
    }

    $weeklyCandidates = @($buckets | Where-Object { $_.WindowDurationMins -eq 10080 })
    # Some accounts expose additional metered Codex buckets alongside the normal /status quota.
    # The canonical `codex` limit is the one the Codex UI presents; use another weekly bucket only
    # when a response genuinely has no canonical one.
    $weekly = @($weeklyCandidates | Where-Object { $_.LimitId -eq 'codex' } | Select-Object -First 1)
    if ($weekly.Count -eq 0) {
        $weekly = @($weeklyCandidates | Sort-Object ResetsAt -Descending | Select-Object -First 1)
    }
    if ($weekly.Count -eq 0) {
        $available = @($buckets | Sort-Object WindowDurationMins | ForEach-Object { "$($_.LimitId): $($_.WindowDurationMins) minutes" }) -join ', '
        throw "Codex returned no 10,080-minute (7-day) bucket. Available buckets: $available"
    }

    $bucket = $weekly[0]
    $remaining = [Math]::Max(0, 100 - $bucket.UsedPercent)
    [pscustomobject]@{
        WeeklyLimit = ('{0:0.##}% left' -f $remaining)
        UsedPercent = $bucket.UsedPercent
        Reset = [DateTimeOffset]::FromUnixTimeSeconds($bucket.ResetsAt).ToLocalTime().DateTime
        LimitId = $bucket.LimitId
        Source = 'Codex app-server'
    }
}
finally {
    # Closing stdin asks app-server to finish normally. Kill is only a short cleanup fallback for
    # this child process, so repeated one-shot reads never accumulate background servers.
    if ($process -and -not $process.HasExited) {
        try { $process.StandardInput.Close() } catch {}
        if (-not $process.WaitForExit(1000)) {
            try { $process.Kill() } catch {}
        }
    }
    if ($process) { $process.Dispose() }
}
