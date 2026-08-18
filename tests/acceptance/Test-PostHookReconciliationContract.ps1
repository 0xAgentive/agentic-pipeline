[CmdletBinding()]
param(
  [string]$RepoRoot = '.'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$Node = (Get-Command node -ErrorAction Stop).Source
$Hook = Join-Path $Root 'templates\agy-project-base\.agents\hooks\agentic_runtime_hook.cjs'
if (-not (Test-Path -LiteralPath $Hook -PathType Leaf)) { throw "Hook not found: $Hook" }

$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("agentic-posthook-reconciliation-" + [guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Force -Path (Join-Path $TempRoot '.agy\.hook_pending') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $TempRoot '.agents') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $TempRoot 'src') | Out-Null
  [IO.File]::WriteAllText((Join-Path $TempRoot 'src\demo.txt'),'changed',[Text.UTF8Encoding]::new($false))

  # Force the ledger append to fail after the product write has already happened.
  New-Item -ItemType Directory -Force -Path (Join-Path $TempRoot '.agy\WRITE_LEDGER.ndjson') | Out-Null

  $Pending = Join-Path $TempRoot '.agy\.hook_pending\contract-7.json'
  $PendingBody = [ordered]@{
    kind = 'write'
    data = [ordered]@{ file = (Join-Path $TempRoot 'src\demo.txt'); rel = 'src/demo.txt' }
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
  }
  [IO.File]::WriteAllText($Pending,($PendingBody | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))

  $Payload = [ordered]@{
    workspacePaths = @($TempRoot)
    conversationId = 'contract'
    stepIdx = 7
    toolCall = [ordered]@{ args = [ordered]@{ TargetFile = (Join-Path $TempRoot 'src\demo.txt') } }
    error = $null
  }

  $Raw = ($Payload | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook postwrite
  if ($LASTEXITCODE -ne 0) { throw "postwrite hook exited nonzero: $LASTEXITCODE" }

  $Reconciliation = Join-Path $TempRoot '.agy\HOOK_RECONCILIATION_REQUIRED.json'
  $CandidateStatus = Join-Path $TempRoot '.agy\CANDIDATE_MANIFEST_STATUS.json'
  $PendingStillRecoverable = (Test-Path -LiteralPath $Pending -PathType Leaf) -or
    (Test-Path -LiteralPath (Join-Path $TempRoot '.agy\.hook_recovery') -PathType Container)

  if (-not (Test-Path -LiteralPath $Reconciliation -PathType Leaf)) {
    throw "FAIL: post-hook failure was silent; reconciliation marker missing. Output=$Raw"
  }
  if (-not $PendingStillRecoverable) {
    throw 'FAIL: pending record was discarded before durable reconciliation.'
  }
  if (Test-Path -LiteralPath $CandidateStatus -PathType Leaf) {
    $Status = Get-Content -LiteralPath $CandidateStatus -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$Status.status -notin @('invalidated','reconciliation_required')) {
      throw "FAIL: candidate status remains usable after post-hook failure: $($Status.status)"
    }
  }

  Write-Host 'POST_HOOK_RECONCILIATION_CONTRACT=PASS' -ForegroundColor Green
}
finally {
  Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
