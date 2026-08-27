<#
.SYNOPSIS
  Pack src/ into a solution zip and import it into the Power Platform environment.

.DESCRIPTION
  Established in phase 1: pac solution pack -> pac solution import.
  --activate-plugins keeps a flow that was ON before the import ON afterwards;
  a flow that was in Draft stays in Draft (verified 3 times in phase 1).

  Keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less .ps1 as ANSI).
#>
[CmdletBinding()]
param(
    [switch]$SkipPublish
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$config = Get-Content (Join-Path $repoRoot 'local.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$srcFolder = Join-Path $repoRoot 'src'
$distFolder = Join-Path $repoRoot 'dist'
$zipPath = Join-Path $distFolder "$($config.solutionName).zip"

if (-not (Test-Path $distFolder)) { New-Item -ItemType Directory -Path $distFolder | Out-Null }
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

Write-Output "[deploy] pack  : $srcFolder -> $zipPath"
$packOut = & pac solution pack --zipfile $zipPath --folder $srcFolder 2>&1
$packOut | ForEach-Object { Write-Output "  $_" }
if ($LASTEXITCODE -ne 0) { throw "pac solution pack failed (exit $LASTEXITCODE)" }

$importArgs = @('solution', 'import', '--path', $zipPath, '--force-overwrite', '--activate-plugins')
if (-not $SkipPublish) { $importArgs += '--publish-changes' }

Write-Output "[deploy] import : $zipPath"
$importOut = & pac @importArgs 2>&1
$importOut | ForEach-Object { Write-Output "  $_" }
if ($LASTEXITCODE -ne 0) { throw "pac solution import failed (exit $LASTEXITCODE)" }

Write-Output '[deploy] done'
