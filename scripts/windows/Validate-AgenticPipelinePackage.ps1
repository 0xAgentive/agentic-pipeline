param([string]$RepoRoot=".", [switch]$Strict)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$Errors = New-Object System.Collections.Generic.List[string]

function Add-Err([string]$m){ [void]$Errors.Add($m) }
function Has([string]$p){ Test-Path -LiteralPath (Join-Path $Root $p) }

function Files([string[]]$ext=@()){
  Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue |
    Where-Object {
      $x = $_.FullName -replace "\\","/"
      $x -notmatch "/node_modules/|/dist/|/build/|/\.git/|/\.pipeline_patch_backup/|/docs/archive/"
    } |
    Where-Object { $ext.Count -eq 0 -or ($ext -contains $_.Extension.ToLowerInvariant()) }
}

$required = @(
 "README.md","README.ru.md","VERSION.json","LICENSE","SECURITY.md","CONTRIBUTING.md","CHANGELOG.md",
 "docs/AGENTIC_PIPELINE_PLAYBOOK.md","docs/GITHUB_PUBLICATION.md","docs/PIPELINE_VERSION_MATRIX.md",
 "config/command-inventory.json","schemas/phase-status.schema.json","schemas/command-inventory.schema.json","schemas/version.schema.json",
 "scripts/windows/Validate-AgenticPipelinePackage.ps1","scripts/windows/Test-DistributionIntegrity.ps1","scripts/windows/Test-PowerShellRuntimeContracts.ps1",
 "scripts/windows/Test-StateProfiles.ps1","scripts/windows/Test-CommandInventory.ps1",
 "scripts/windows/Test-TemplateHygiene.ps1","scripts/windows/Test-ProjectLeakage.ps1",
 "scripts/windows/Test-FreshInstall.ps1","scripts/windows/Build-ReleasePackage.ps1",
 "scripts/windows/Initialize-AgenticProject.ps1","scripts/Test-FastPatchAllowed.ps1",
 "scripts/cbm-index-current-rpc.cjs","scripts/cbm-wrapper-smoke.cjs",
 "templates/state-profiles/new-project/PHASE_STATUS.json",
 "templates/state-profiles/adopt-existing/PHASE_STATUS.json",
 "templates/agy-project-base/.cbmignore","templates/agy-project-base/.gitignore",
 "templates/agy-project-base/.agents/AGENTS.md","templates/agy-project-base/.agents/COMMAND_INVENTORY.json",
 "templates/agy-project-base/.agents/hooks.sample.json",
 "templates/agy-project-base/.agents/hooks/Test-HookContract.ps1",
 "templates/agy-project-base/.agents/workflows/githubprepare.md",
 "templates/agy-project-base/.agents/workflows/githubsync.md",
 "templates/agy-project-base/.agy/PHASE_STATUS.json",
 "templates/agy-project-base/.agy/GITHUB_PROFILE.json",
 "templates/agy-project-base/scripts/github/Prepare-GitHubPackage.ps1",
 "templates/agy-project-base/scripts/github/Sync-GitHub.ps1"
)
foreach($p in $required){ if(!(Has $p)){ Add-Err "Missing required file: $p" } }

foreach($f in Files @(".json")){
  try { Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json | Out-Null }
  catch { Add-Err "Invalid JSON: $($f.FullName)" }
}

foreach($f in Files @(".ps1")){
  $t=$null; $e=$null
  [System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$t,[ref]$e) | Out-Null
  if($e.Count -gt 0){ Add-Err "PowerShell parse error: $($f.FullName): $($e[0].Message)" }
}

$node = Get-Command node -ErrorAction SilentlyContinue
if($node){
  foreach($f in Files @(".cjs")){
    & $node.Source --check $f.FullName | Out-Null
    if($LASTEXITCODE -ne 0){ Add-Err "node --check failed: $($f.FullName)" }
  }
} elseif($Strict){ Add-Err "node not found; cannot validate .cjs syntax" }

$hookDir = Join-Path $Root "templates/agy-project-base/.agents/hooks"
if(Test-Path -LiteralPath $hookDir){
  foreach($f in Get-ChildItem -LiteralPath $hookDir -File -Filter *.ps1 -ErrorAction SilentlyContinue){
    $txt = Get-Content -LiteralPath $f.FullName -Raw
    if($txt -match "Hook contract placeholder OK"){ Add-Err "Placeholder hook script detected: $($f.FullName)" }
    if($txt -match "Write-Output\s+['""]\{\}['""]"){ Add-Err "No-op hook script detected: $($f.FullName)" }
  }
}

$cbm = Join-Path $Root "templates/agy-project-base/.cbmignore"
if(Test-Path -LiteralPath $cbm){
  $txt = Get-Content -LiteralPath $cbm -Raw
  foreach($x in @("node_modules/","dist/","build/",".git/",".agy/checkpoints/",".pipeline_patch_backup/",".codebase-memory/","coverage/",".artifacts/","*.log")){
    if($txt -notmatch [regex]::Escape($x)){ Add-Err "templates .cbmignore missing: $x" }
  }
}

$legacy = Join-Path $Root "scripts/windows/Apply-AgenticPipeline-v1.1.1.ps1"
if(Test-Path -LiteralPath $legacy){
  $t = Get-Content -LiteralPath $legacy -Raw
  $danger = '$PlaybookSrc = Join-Path $ScriptDir "agentic_pipeline_playbook_v1.1.1.md"'
  if($t.Contains($danger)){ Add-Err "Legacy installer still uses missing local playbook source path" }
  if(($t -match "agentic_pipeline_playbook_v1\.1\.1\.md") -and ($t -notmatch "docs\\AGENTIC_PIPELINE_PLAYBOOK\.md|docs/AGENTIC_PIPELINE_PLAYBOOK\.md")){
    Add-Err "Legacy installer mentions old playbook without canonical docs fallback"
  }
}


$templateRoot = Join-Path $Root "templates/agy-project-base"
if(Test-Path -LiteralPath $templateRoot){
  $generated = Get-ChildItem -LiteralPath $templateRoot -Recurse -Force -File -ErrorAction SilentlyContinue |
    Where-Object {
      $rel = $_.FullName.Substring($templateRoot.Length).TrimStart("\","/") -replace "\\","/"
      $rel -match '^\.agy/checkpoints/' -or $rel -match '(^|/)(git-status|checkpoint|validation|transcript)-\d{8}'
    }
  foreach($f in $generated){ Add-Err "Generated runtime artifact in template: $($f.FullName)" }
}

foreach($f in Files){
  if($f.Name -like "*.bak-*" -or $f.Name -like "*.bak-v*"){
    $rel = $f.FullName.Substring($Root.Length).TrimStart("\","/")
    if((($rel -replace "\\","/").StartsWith(".pipeline_patch_backup/")) -eq $false){
      Add-Err "Backup file must not live in repo tree: $($f.FullName)"
    }
  }
}

if($Errors.Count -gt 0){
  Write-Host "Validation failed:"
  $Errors | Sort-Object -Unique | ForEach-Object { Write-Host "- $_" }
  exit 1
}
Write-Host "Hard package validation passed."
exit 0