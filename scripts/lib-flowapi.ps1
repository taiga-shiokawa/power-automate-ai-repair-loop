<#
  Shared helpers for the Power Automate (Flow) management API.
  Dot-source this file: . "$PSScriptRoot\lib-flowapi.ps1"

  Keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less .ps1 as ANSI).
#>

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-RepoRoot {
    Split-Path -Parent $PSScriptRoot
}

function Get-FlowConfig {
    Get-Content (Join-Path (Get-RepoRoot) 'local.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-FlowAccessToken {
    $t = & (Join-Path $PSScriptRoot 'token.ps1') -Mode Get
    if (-not $t) { throw 'Failed to obtain a Flow API access token.' }
    return ($t | Select-Object -Last 1)
}

function Get-FlowApiError($errRecord) {
    $raw = $null
    if ($errRecord.ErrorDetails -and $errRecord.ErrorDetails.Message) { $raw = $errRecord.ErrorDetails.Message }
    elseif ($errRecord.Exception.Response) {
        try {
            $sr = New-Object IO.StreamReader($errRecord.Exception.Response.GetResponseStream())
            $raw = $sr.ReadToEnd(); $sr.Close()
        }
        catch { $raw = $null }
    }
    $code = 'ERR'
    if ($errRecord.Exception.Response) { $code = [int]$errRecord.Exception.Response.StatusCode }
    return [pscustomobject]@{ status = $code; body = $raw }
}

<#
  Invoke the Flow management API.
  $Path is everything after the host, starting with '/providers/...'.
#>
function Invoke-FlowApi {
    param(
        [string]$Path,
        [string]$Method = 'GET',
        $Body = $null,
        [string]$Token,
        [switch]$Raw
    )
    $cfg = Get-FlowConfig
    if (-not $Token) { $Token = Get-FlowAccessToken }
    $uri = $cfg.flowApiBase + $Path
    $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/json' }
    $params = @{ Method = $Method; Uri = $uri; Headers = $headers; UseBasicParsing = $true }
    if ($null -ne $Body) {
        $params['ContentType'] = 'application/json'
        if ($Body -is [string]) { $params['Body'] = $Body }
        else { $params['Body'] = ($Body | ConvertTo-Json -Depth 20 -Compress) }
    }
    elseif ($Method -ne 'GET') {
        # Flow API rejects POST without a body on some endpoints
        $params['ContentType'] = 'application/json'
        $params['Body'] = '{}'
    }
    $resp = Invoke-WebRequest @params
    if ($Raw) { return $resp }
    if (-not $resp.Content) { return $null }
    return ($resp.Content | ConvertFrom-Json)
}

function Get-FlowBasePath {
    $cfg = Get-FlowConfig
    return "/providers/Microsoft.ProcessSimple/environments/$($cfg.environmentId)/flows/$($cfg.workflowId)"
}

function Start-FlowManualRun {
    param([hashtable]$Inputs, [string]$TriggerName = 'manual', [string]$Token)
    $path = (Get-FlowBasePath) + "/triggers/$TriggerName/run?api-version=2016-11-01"
    $body = @{}
    if ($Inputs) { $body = $Inputs }
    return Invoke-FlowApi -Path $path -Method 'POST' -Body $body -Token $Token -Raw
}

function Get-FlowRunList {
    param([int]$Top = 5, [string]$Token)
    $path = (Get-FlowBasePath) + "/runs?api-version=2016-11-01&`$top=$Top"
    $r = Invoke-FlowApi -Path $path -Token $Token
    return $r.value
}

function Get-FlowRunDetail {
    param([string]$RunId, [string]$Token)
    $path = (Get-FlowBasePath) + "/runs/$RunId" + '?api-version=2016-11-01'
    return Invoke-FlowApi -Path $path -Token $Token
}

function Get-FlowRunActions {
    param([string]$RunId, [string]$Token)
    $path = (Get-FlowBasePath) + "/runs/$RunId/actions" + '?api-version=2016-11-01'
    $r = Invoke-FlowApi -Path $path -Token $Token
    return $r.value
}

function Set-FlowState {
    param([ValidateSet('start', 'stop')][string]$Action, [string]$Token)
    $path = (Get-FlowBasePath) + "/$Action" + '?api-version=2016-11-01'
    return Invoke-FlowApi -Path $path -Method 'POST' -Token $Token -Raw
}
