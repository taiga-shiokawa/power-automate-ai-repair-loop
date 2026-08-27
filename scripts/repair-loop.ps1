<#
.SYNOPSIS
  One command that runs the whole loop:
  pack -> import -> activate -> trigger -> wait for the run -> AI repair -> repeat.

.DESCRIPTION
  Phase 2 orchestrator. Each iteration:
    1. deploy.ps1                 pac solution pack + import
    2. POST /flows/{id}/start     re-activate (import can drop the flow to Draft)
    3. trigger-flow.ps1           POST /triggers/manual/run
    4. fetch-flow-runs.ps1        wait for a terminal run, dump logs/latest-flow-run.json
                                  exit 0 = Succeeded, exit 2 = failed
    5. claude -p                  non-interactive repair driven by prompts/repair-flow.md

  Stops on the first Succeeded run, or after -MaxIterations.

  Keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less .ps1 as ANSI).

.EXAMPLE
  .\scripts\repair-loop.ps1
  .\scripts\repair-loop.ps1 -MaxIterations 5 -NoAi
#>
[CmdletBinding()]
param(
    [int]$MaxIterations = 3,
    [int]$RunTimeoutSec = 180,
    [string]$SkillInput = 'Python',
    # Skip the claude invocation (useful to verify deploy/trigger/monitor only)
    [switch]$NoAi
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib-flowapi.ps1')

$cfg = Get-FlowConfig
$repoRoot = Get-RepoRoot
$base = "/providers/Microsoft.ProcessSimple/environments/$($cfg.environmentId)/flows/$($cfg.workflowId)"

function Write-Step($msg) {
    Write-Output ''
    Write-Output "=============================================================="
    Write-Output "  $msg"
    Write-Output "=============================================================="
}

function Ensure-FlowStarted([string]$Token) {
    # A solution import can leave the flow in Draft. POST /start re-activates it.
    # Right after an import the licensing check can transiently return 403; retry.
    for ($i = 1; $i -le 5; $i++) {
        $flow = Invoke-FlowApi -Path ($base + '?api-version=2016-11-01') -Token $Token
        if ($flow.properties.state -eq 'Started') {
            Write-Output "[loop] flow state: Started"
            return
        }
        Write-Output "[loop] flow state: $($flow.properties.state) -> POST /start (attempt $i)"
        try {
            Invoke-FlowApi -Path ($base + '/start?api-version=2016-11-01') -Method 'POST' -Token $Token -Raw | Out-Null
        }
        catch {
            $err = Get-FlowApiError $_
            Write-Output "[loop] /start HTTP $($err.status)"
            if ($err.body) { Write-Output "[loop] $($err.body)" }
        }
        Start-Sleep -Seconds 10
    }
    throw 'Could not bring the flow to the Started state.'
}

# --- preflight -------------------------------------------------------------
Write-Step 'preflight'
$token = Get-FlowAccessToken
Write-Output '[loop] Flow API token: OK'
& pac org who | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'pac is not connected to Dataverse. Run: pac auth create --environment <orgUrl>' }
Write-Output '[loop] pac Dataverse connection: OK'

$succeeded = $false

for ($iter = 1; $iter -le $MaxIterations; $iter++) {

    Write-Step "iteration $iter / $MaxIterations"

    # 1. deploy
    & (Join-Path $PSScriptRoot 'deploy.ps1')
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "deploy failed on iteration $iter" }

    # 2. activate
    $token = Get-FlowAccessToken
    Ensure-FlowStarted -Token $token

    # 3. trigger
    $sinceUtc = [DateTime]::UtcNow.AddSeconds(-5).ToString('o')
    $triggerStart = [DateTime]::UtcNow
    & (Join-Path $PSScriptRoot 'trigger-flow.ps1') -SkillInput $SkillInput | Out-Host

    # 4. monitor
    & (Join-Path $PSScriptRoot 'fetch-flow-runs.ps1') -SinceUtc $sinceUtc -TimeoutSec $RunTimeoutSec | Out-Host
    $verdict = $LASTEXITCODE
    $elapsed = [int]([DateTime]::UtcNow - $triggerStart).TotalSeconds
    Write-Output "[loop] trigger -> verdict in ${elapsed}s (exit $verdict)"

    if ($verdict -eq 0) {
        Write-Output "[loop] run Succeeded on iteration $iter"
        $succeeded = $true
        break
    }

    if ($iter -eq $MaxIterations) {
        Write-Output "[loop] reached MaxIterations ($MaxIterations) without success"
        break
    }

    if ($NoAi) {
        Write-Output '[loop] -NoAi set: stopping instead of invoking the AI'
        break
    }

    # 5. AI repair
    Write-Step "AI repair (iteration $iter)"
    Push-Location $repoRoot
    try {
        $instruction = 'Follow the instructions in prompts/repair-flow.md to diagnose the failure recorded in logs/latest-flow-run.json and apply the minimal fix to the flow definition under src/.'
        & claude -p $instruction --permission-mode acceptEdits --allowedTools Read Edit Write Grep Glob | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "claude -p exited with $LASTEXITCODE" }
    }
    finally {
        Pop-Location
    }

    Write-Output '[loop] git diff after AI repair:'
    & git -C $repoRoot diff --stat -- src | Out-Host
}

Write-Step 'summary'
if ($succeeded) {
    Write-Output 'RESULT: Succeeded'
    exit 0
}
Write-Output 'RESULT: not repaired'
exit 1
