<#
.SYNOPSIS
  Start the cloud flow through the Power Automate management API.

.DESCRIPTION
  POST /providers/Microsoft.ProcessSimple/environments/{env}/flows/{flow}/triggers/manual/run
  The manual (Button) trigger accepts the trigger input schema as the request body.
  Prints the run id on the last output line.

  Keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less .ps1 as ANSI).
#>
[CmdletBinding()]
param(
    # Value for the flow's "text" trigger input (skill keyword)
    [string]$SkillInput = 'Python',
    [string]$TriggerName = 'manual'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib-flowapi.ps1')

$token = Get-FlowAccessToken
$inputs = @{ text = $SkillInput }

Write-Output "[trigger] POST triggers/$TriggerName/run  (text='$SkillInput')"
try {
    $resp = Start-FlowManualRun -Inputs $inputs -TriggerName $TriggerName -Token $token
}
catch {
    $err = Get-FlowApiError $_
    Write-Output "[trigger] HTTP $($err.status)"
    if ($err.body) { Write-Output "[trigger] $($err.body)" }
    throw 'Flow trigger failed.'
}

Write-Output "[trigger] HTTP $([int]$resp.StatusCode)"

# The run id arrives either in the response body (.name) or in a response header.
$runId = $null
if ($resp.Content) {
    try {
        $body = $resp.Content | ConvertFrom-Json
        if ($body.name) { $runId = $body.name }
    }
    catch { }
}
if (-not $runId) {
    foreach ($h in @('x-ms-workflow-run-id', 'x-ms-request-id', 'x-ms-client-tracking-id')) {
        if ($resp.Headers[$h]) { $runId = $resp.Headers[$h]; break }
    }
}
if (-not $runId -and $resp.Headers['Location']) {
    $runId = ($resp.Headers['Location'] -split '/runs/')[-1] -replace '\?.*$', ''
}

if ($runId) {
    Write-Output "[trigger] runId: $runId"
    Write-Output $runId
}
else {
    Write-Output '[trigger] WARNING: could not determine the run id from the response'
    Write-Output "[trigger] headers: $(($resp.Headers.Keys | Sort-Object) -join ', ')"
    if ($resp.Content) { Write-Output "[trigger] body: $($resp.Content)" }
}
