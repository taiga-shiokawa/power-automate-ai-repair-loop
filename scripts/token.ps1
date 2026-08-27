<#
.SYNOPSIS
  Acquire an access token for the Power Automate (Flow) API or Dataverse.

.DESCRIPTION
  `pac auth token` is hard-wired to audience api.powerplatform.com and is rejected
  (401) by both the Flow API and the Dataverse Web API. To avoid an app registration
  this script uses the OAuth 2.0 device code flow with a well-known public client and
  caches the refresh token locally, encrypted with DPAPI (user scope).
  .secrets/ is gitignored.

  NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads BOM-less .ps1 as ANSI,
  which corrupts non-ASCII literals.

  Modes:
    Request : issue a device code, print verification URL + user code, exit immediately
    Poll    : wait for the interactive sign-in to complete, then store the token
    Get     : return a valid access token (refreshing silently when needed)
    Status  : print cache state only (never prints the token)

.EXAMPLE
  .\scripts\token.ps1 -Mode Request
  .\scripts\token.ps1 -Mode Poll
  $t = .\scripts\token.ps1 -Mode Get
#>
[CmdletBinding()]
param(
    [ValidateSet('Request', 'Poll', 'Get', 'Status')]
    [string]$Mode = 'Get',

    # Defaults to the Flow API. Pass -Resource <orgUrl> for Dataverse.
    [string]$Resource
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repoRoot = Split-Path -Parent $PSScriptRoot
$config = Get-Content (Join-Path $repoRoot 'local.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $Resource) { $Resource = $config.flowApiResource }

$secretsDir = Join-Path $repoRoot '.secrets'
if (-not (Test-Path $secretsDir)) { New-Item -ItemType Directory -Path $secretsDir | Out-Null }

$slug = ($Resource -replace '^https?://', '' -replace '[^A-Za-z0-9]', '-').Trim('-')
$cachePath = Join-Path $secretsDir "token-$slug.json"
$pendingPath = Join-Path $secretsDir "pending-$slug.json"

$tokenUrl = "https://login.microsoftonline.com/$($config.tenantId)/oauth2/v2.0/token"
$deviceUrl = "https://login.microsoftonline.com/$($config.tenantId)/oauth2/v2.0/devicecode"

function Get-ErrorBody($errRecord) {
    if (-not $errRecord) { return $null }
    $raw = $null
    # PS 5.1: Invoke-RestMethod may already have consumed the response stream, so
    # ErrorDetails.Message is the reliable source for the JSON error body.
    if ($errRecord.ErrorDetails -and $errRecord.ErrorDetails.Message) {
        $raw = $errRecord.ErrorDetails.Message
    }
    elseif ($errRecord.Exception.Response) {
        try {
            $sr = New-Object IO.StreamReader($errRecord.Exception.Response.GetResponseStream())
            $raw = $sr.ReadToEnd(); $sr.Close()
        }
        catch { $raw = $null }
    }
    if (-not $raw) { return $null }
    try { return ($raw | ConvertFrom-Json) }
    catch { return ([pscustomobject]@{ error = 'unparsed'; error_description = $raw }) }
}

function Format-AadError($detail) {
    if (-not $detail) { return 'Token request failed (no detail available)' }
    $desc = ($detail.error_description -split "`r?`n" | Select-Object -First 1)
    return "$($detail.error): $desc"
}

# DPAPI (current user) encryption at rest
function Protect-Str([string]$plain) {
    ConvertTo-SecureString $plain -AsPlainText -Force | ConvertFrom-SecureString
}
function Unprotect-Str([string]$enc) {
    $ss = ConvertTo-SecureString $enc
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Save-Cache($tokenResponse) {
    $obj = [ordered]@{
        resource      = $Resource
        access_token  = Protect-Str $tokenResponse.access_token
        refresh_token = ''
        expires_on    = [DateTimeOffset]::UtcNow.AddSeconds([int]$tokenResponse.expires_in - 60).ToUnixTimeSeconds()
        scope         = $tokenResponse.scope
    }
    if ($tokenResponse.refresh_token) {
        $obj.refresh_token = Protect-Str $tokenResponse.refresh_token
    }
    elseif (Test-Path $cachePath) {
        $old = Get-Content $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $obj.refresh_token = $old.refresh_token
    }
    ($obj | ConvertTo-Json) | Out-File -FilePath $cachePath -Encoding utf8
}

# MSAL-style "<resource>/.default". Try both single and double slash forms because
# tenants differ in how they normalise the App ID URI.
$scopeCandidates = @(($Resource + '/.default'), ($Resource.TrimEnd('/') + '/.default')) | Select-Object -Unique

function Invoke-TokenRequest([hashtable]$body) {
    $lastErr = $null
    foreach ($scope in $scopeCandidates) {
        $b = $body.Clone()
        if ($b.ContainsKey('scope')) { $b['scope'] = "$scope offline_access" }
        try {
            return Invoke-RestMethod -Method Post -Uri $tokenUrl -ContentType 'application/x-www-form-urlencoded' -Body $b
        }
        catch {
            $lastErr = $_
            $detail = Get-ErrorBody $_
            if ($detail -and $detail.error -ne 'invalid_scope' -and $detail.error -ne 'invalid_resource') {
                throw (Format-AadError $detail)
            }
        }
    }
    throw (Format-AadError (Get-ErrorBody $lastErr))
}

switch ($Mode) {

    'Request' {
        $resp = $null
        $lastErr = $null
        foreach ($scope in $scopeCandidates) {
            try {
                $resp = Invoke-RestMethod -Method Post -Uri $deviceUrl -ContentType 'application/x-www-form-urlencoded' -Body @{
                    client_id = $config.publicClientId
                    scope     = "$scope offline_access"
                }
                break
            }
            catch { $lastErr = $_ }
        }
        if (-not $resp) { throw (Format-AadError (Get-ErrorBody $lastErr)) }

        @{
            device_code = $resp.device_code
            interval    = $resp.interval
            expires     = [DateTimeOffset]::UtcNow.AddSeconds([int]$resp.expires_in).ToUnixTimeSeconds()
        } | ConvertTo-Json | Out-File -FilePath $pendingPath -Encoding utf8

        Write-Output "resource         : $Resource"
        Write-Output "verification_uri : $($resp.verification_uri)"
        Write-Output "user_code        : $($resp.user_code)"
        Write-Output "expires_in       : $($resp.expires_in) sec"
    }

    'Poll' {
        if (-not (Test-Path $pendingPath)) { throw "Run -Mode Request first (missing $pendingPath)" }
        $pending = Get-Content $pendingPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $interval = [Math]::Max(5, [int]$pending.interval)
        while ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -lt [int64]$pending.expires) {
            Start-Sleep -Seconds $interval
            try {
                $tok = Invoke-RestMethod -Method Post -Uri $tokenUrl -ContentType 'application/x-www-form-urlencoded' -Body @{
                    grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                    client_id   = $config.publicClientId
                    device_code = $pending.device_code
                }
                Save-Cache $tok
                Remove-Item $pendingPath -Force
                $exp = [DateTimeOffset]::UtcNow.AddSeconds([int]$tok.expires_in).ToLocalTime()
                Write-Output "OK: token cached at $cachePath (expires $exp)"
                return
            }
            catch {
                $d = Get-ErrorBody $_
                if ($d -and $d.error -eq 'authorization_pending') { continue }
                if ($d -and $d.error -eq 'slow_down') { $interval += 5; continue }
                throw (Format-AadError $d)
            }
        }
        throw 'Device code expired. Start over with -Mode Request.'
    }

    'Get' {
        if (-not (Test-Path $cachePath)) { throw 'No token cache. Run -Mode Request then -Mode Poll first.' }
        $cache = Get-Content $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -lt [int64]$cache.expires_on) {
            return (Unprotect-Str $cache.access_token)
        }
        if (-not $cache.refresh_token) { throw 'Access token expired and no refresh token. Run -Mode Request again.' }
        $tok = Invoke-TokenRequest @{
            grant_type    = 'refresh_token'
            client_id     = $config.publicClientId
            refresh_token = (Unprotect-Str $cache.refresh_token)
            scope         = 'placeholder'
        }
        Save-Cache $tok
        return $tok.access_token
    }

    'Status' {
        if (-not (Test-Path $cachePath)) { Write-Output "cache: none ($Resource)"; return }
        $cache = Get-Content $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $exp = [DateTimeOffset]::FromUnixTimeSeconds([int64]$cache.expires_on).ToLocalTime()
        if ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -lt [int64]$cache.expires_on) {
            $accessState = "valid (until $exp)"
        }
        else {
            $accessState = "expired ($exp)"
        }
        if ($cache.refresh_token) { $refreshState = 'present' } else { $refreshState = 'none' }
        Write-Output "resource      : $($cache.resource)"
        Write-Output "access_token  : $accessState"
        Write-Output "refresh_token : $refreshState"
        Write-Output "scope         : $($cache.scope)"
    }
}
