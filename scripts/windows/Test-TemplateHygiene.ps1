param(
  [string]$RepoRoot = ".",
  [string]$TemplateRoot = ""
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
if ([string]::IsNullOrWhiteSpace($TemplateRoot)) { $TemplateRoot = Join-Path $Root "templates\agy-project-base" }
$Template = (Resolve-Path -LiteralPath $TemplateRoot).Path
$Errors = New-Object System.Collections.Generic.List[string]
function Add-Error([string]$Message) { [void]$Errors.Add($Message) }

$Files = Get-ChildItem -LiteralPath $Template -Recurse -Force -File
foreach ($File in $Files) {
  $Rel = $File.FullName.Substring($Template.Length).TrimStart("\","/") -replace '\\','/'

  if ($Rel -match '^\.agy/checkpoints/' -or
      $Rel -match '(^|/)(git-status|checkpoint|validation|transcript)-\d{8}' -or
      $Rel -match '\.(log|zip|har|trace|tmp|bak)$' -or
      $Rel -match '(^|/)\.pipeline_.*backup/' -or
      $Rel -match '(^|/)(\.DS_Store|Thumbs\.db)$') {
    Add-Error "Generated or backup artifact in template: $Rel"
  }

  if ($File.Extension.ToLowerInvariant() -in @('.md','.json','.ps1','.cjs','.yml','.yaml','.txt')) {
    $Text = [System.IO.File]::ReadAllText($File.FullName,[System.Text.Encoding]::UTF8)
    if ($Text -match 'file:///') { Add-Error "file:/// URI in template: $Rel" }
    if ($Text -match '(?i)[A-Z]:\\Users\\') { Add-Error "Absolute user path in template: $Rel" }
    if ($Text -match '(?i)Z:\\') { Add-Error "Absolute drive path in template: $Rel" }
    if ($Text -match '\]\(\.\./\.\./') { Add-Error "Markdown link escapes template root: $Rel" }
    if ($Text -match 'docs/AGENTIC_PIPELINE_PLAYBOOK\.md') { Add-Error "Template depends on non-distributed root playbook: $Rel" }
  }
}

foreach ($Rel in @('.agy\evidence.ndjson','.agy\ARTIFACT_INDEX.ndjson')) {
  $Path = Join-Path $Template $Rel
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
    Add-Error "Missing baseline ledger: $Rel"
    continue
  }

  # Get-Content -Raw can produce $null for a zero-byte file in Windows PowerShell.
  # ReadAllText deterministically returns an empty string, so Trim() is safe.
  $LedgerText = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  if ($LedgerText.Trim().Length -ne 0) {
    Add-Error "Baseline ledger must be empty: $Rel"
  }
}

$EvidenceLog = Join-Path $Template '.agy\EVIDENCE_LOG.md'
if (Test-Path -LiteralPath $EvidenceLog -PathType Leaf) {
  $Text = Get-Content -LiteralPath $EvidenceLog -Raw
  if ($Text -match '20\d\d-\d\d-\d\d[T ]') { Add-Error "Template EVIDENCE_LOG contains generated timestamped evidence" }
}

if ($Errors.Count -gt 0) {
  Write-Host "Template-hygiene validation failed:"
  $Errors | Sort-Object -Unique | ForEach-Object { Write-Host "- $_" }
  exit 1
}

Write-Host "Template-hygiene validation passed."
exit 0
