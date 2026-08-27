<#
.SYNOPSIS
  Wait for a flow run to reach a terminal state and dump the result (including
  per-action failure detail) to logs/latest-flow-run.json.

.DESCRIPTION
  Uses the Power Automate management API:
    GET /flows/{id}/runs                 -> run list (near real time, unlike Dataverse FlowRun)
    GET /flows/{id}/runs/{run}/actions   -> per-action status / code / error
  For a failed action the error text often lives in the action outputs, which the API
  exposes as a pre-signed outputsLink; this script follows that link when present.

  Keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less .ps1 as ANSI).
#>
[CmdletBinding()]
param(
    # Only consider runs that started at or after this UTC time (ISO 8601).
    [string]$SinceUtc,
    [int]$TimeoutSec = 180,
    [int]$PollSec = 5,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib-flowapi.ps1')

$cfg = Get-FlowConfig
$repoRoot = Get-RepoRoot
if (-not $OutFile) { $OutFile = Join-Path $repoRoot 'logs\latest-flow-run.json' }
$logsDir = Split-Path -Parent $OutFile
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir | Out-Null }

$token = Get-FlowAccessToken
$base = "/providers/Microsoft.ProcessSimple/environments/$($cfg.environmentId)/flows/$($cfg.workflowId)"
$terminal = @('Succeeded', 'Failed', 'Cancelled', 'TimedOut', 'Aborted', 'Faulted')

$since = $null
if ($SinceUtc) { $since = [DateTimeOffset]::Parse($SinceUtc).UtcDateTime }

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
$run = $null
$firstSeen = $null

while ([DateTime]::UtcNow -lt $deadline) {
    $list = Invoke-FlowApi -Path ($base + '/runs?api-version=2016-11-01&$top=5') -Token $token
    $candidate = $null
    foreach ($r in $list.value) {
        $st = [DateTimeOffset]::Parse($r.properties.startTime).UtcDateTime
        if ($since -and $st -lt $since) { continue }
        if (-not $candidate) { $candidate = $r; continue }
        $cst = [DateTimeOffset]::Parse($candidate.properties.startTime).UtcDateTime
        if ($st -gt $cst) { $candidate = $r }
    }
    if ($candidate) {
        if (-not $firstSeen) {
            $firstSeen = [DateTime]::UtcNow
            Write-Output "[fetch] run $($candidate.name) detected (status=$($candidate.properties.status))"
        }
        if ($terminal -contains $candidate.properties.status) { $run = $candidate; break }
    }
    Start-Sleep -Seconds $PollSec
}

if (-not $run) {
    throw "No terminal flow run found within $TimeoutSec sec (SinceUtc=$SinceUtc)."
}

Write-Output "[fetch] run $($run.name) status=$($run.properties.status)"

# --- per-action detail ---
$actions = @()
try {
    $a = Invoke-FlowApi -Path ($base + '/runs/' + $run.name + '/actions?api-version=2016-11-01') -Token $token
    $actions = @($a.value)
}
catch {
    $err = Get-FlowApiError $_
    Write-Output "[fetch] WARNING: actions endpoint returned HTTP $($err.status)"
}

function Get-LinkContent($link) {
    if (-not $link) { return $null }
    if (-not $link.uri) { return $null }
    try {
        $r = Invoke-WebRequest -Method Get -Uri $link.uri -UseBasicParsing
        if (-not $r.Content) { return $null }
        $text = $r.Content
        if ($text.Length -gt 4000) { $text = $text.Substring(0, 4000) + '...(truncated)' }
        return $text
    }
    catch { return $null }
}

$failedActions = @()
$actionSummary = @()
foreach ($act in $actions) {
    $actionSummary += [ordered]@{
        name   = $act.name
        status = $act.properties.status
        code   = $act.properties.code
    }
    if ($act.properties.status -ne 'Succeeded' -and $act.properties.status -ne 'Skipped') {
        $detail = [ordered]@{
            name    = $act.name
            status  = $act.properties.status
            code    = $act.properties.code
            error   = $act.properties.error
            inputs  = Get-LinkContent $act.properties.inputsLink
            outputs = Get-LinkContent $act.properties.outputsLink
        }
        $failedActions += $detail
    }
}

$durationMs = $null
if ($run.properties.endTime) {
    $durationMs = [int]([DateTimeOffset]::Parse($run.properties.endTime).UtcDateTime - [DateTimeOffset]::Parse($run.properties.startTime).UtcDateTime).TotalMilliseconds
}

$result = [ordered]@{
    flowName      = $cfg.flowName
    runId         = $run.name
    status        = $run.properties.status
    startTime     = $run.properties.startTime
    endTime       = $run.properties.endTime
    durationMs    = $durationMs
    error         = $run.properties.error
    actions       = $actionSummary
    failedActions = $failedActions
    source        = 'PowerAutomateManagementApi'
    fetchedAtUtc  = [DateTime]::UtcNow.ToString('o')
}

($result | ConvertTo-Json -Depth 12) | Out-File -FilePath $OutFile -Encoding utf8
Write-Output "[fetch] wrote $OutFile"

# keep a history copy
$historyDir = Join-Path $repoRoot 'logs\history'
if (-not (Test-Path $historyDir)) { New-Item -ItemType Directory -Path $historyDir | Out-Null }
$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
Copy-Item $OutFile (Join-Path $historyDir "$stamp-$($run.properties.status).json") -Force

foreach ($f in $failedActions) {
    Write-Output "[fetch] FAILED action: $($f.name)  code=$($f.code)"
}

# Exit code carries the verdict so the loop can branch on it.
if ($run.properties.status -eq 'Succeeded') { exit 0 } else { exit 2 }
