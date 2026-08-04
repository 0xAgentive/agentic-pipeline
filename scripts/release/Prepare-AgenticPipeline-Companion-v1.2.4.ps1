[CmdletBinding()]
param(
  [string]$CompanionZip = "",
  [string]$OutputRoot = "$env:USERPROFILE\Downloads\Agentic-Pipeline-Companion-1.2.4",
  [switch]$OpenFolder,
  [switch]$SkipClipboard
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($CompanionZip)) {
  $KitCandidate = Join-Path $PSScriptRoot 'prebuilt\agentic_pipeline_companion_pack1.2.4.zip'
  if (Test-Path -LiteralPath $KitCandidate -PathType Leaf) {
    $CompanionZip = $KitCandidate
  }
  else {
    $RepoCandidate = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.artifacts\release-kit\1.2.6\companion\agentic_pipeline_companion_pack1.2.4.zip'
    if (Test-Path -LiteralPath $RepoCandidate -PathType Leaf) { $CompanionZip = $RepoCandidate }
  }
}
if ([string]::IsNullOrWhiteSpace($CompanionZip) -or !(Test-Path -LiteralPath $CompanionZip -PathType Leaf)) {
  throw 'Companion 1.2.4 ZIP was not found. Pass -CompanionZip explicitly.'
}

Remove-Item -LiteralPath $OutputRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
Expand-Archive -LiteralPath $CompanionZip -DestinationPath $OutputRoot -Force

$Instructions = Get-ChildItem -LiteralPath $OutputRoot -Recurse -File -Filter '01_PROJECT_INSTRUCTIONS_v1.2.4.md' | Select-Object -First 1
$Knowledge = Get-ChildItem -LiteralPath $OutputRoot -Recurse -Directory -Filter 'knowledge' | Select-Object -First 1
if (!$Instructions) { throw 'Project Instructions file is missing from Companion pack.' }
if (!$Knowledge) { throw 'Knowledge directory is missing from Companion pack.' }

if (!$SkipClipboard) {
  Set-Clipboard -Value (Get-Content -LiteralPath $Instructions.FullName -Raw)
}

Write-Host 'COMPANION 1.2.4 PACKAGE PREPARED.' -ForegroundColor Green
Write-Host "Project Instructions: $($Instructions.FullName)"
Write-Host "Knowledge modules: $($Knowledge.FullName)"
if (!$SkipClipboard) { Write-Host 'Project Instructions were copied to the clipboard.' }
Write-Host 'Replace Project Instructions completely and keep one active copy of knowledge modules 00-15.'

if ($OpenFolder) {
  Start-Process explorer.exe -ArgumentList "/select,`"$($Instructions.FullName)`""
}
