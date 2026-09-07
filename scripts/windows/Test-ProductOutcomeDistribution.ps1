[CmdletBinding()]
param([string]$RepoRoot = '.')
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$Node = (Get-Command node -ErrorAction Stop).Source
$Tests = @(
  (Join-Path $Root 'tests/product-outcome.test.cjs'),
  (Join-Path $Root 'tests/product-outcome-distribution.test.cjs')
)
foreach ($Test in $Tests) {
  if (-not (Test-Path -LiteralPath $Test -PathType Leaf)) { throw "Product contract test is missing: $Test" }
}
$PreviousRoot = $env:PIPELINE_REPO_ROOT
try {
  $env:PIPELINE_REPO_ROOT = $Root
  & $Node --test @Tests
  if ($LASTEXITCODE -ne 0) { throw 'Product outcome or runtime distribution contract failed.' }
}
finally {
  if ($null -eq $PreviousRoot) { Remove-Item Env:PIPELINE_REPO_ROOT -ErrorAction SilentlyContinue }
  else { $env:PIPELINE_REPO_ROOT = $PreviousRoot }
}
Write-Host 'Product outcome and runtime distribution contracts passed.'
