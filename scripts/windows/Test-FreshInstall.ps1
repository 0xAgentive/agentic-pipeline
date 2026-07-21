param(
  [string]$RepoRoot = ".",
  [switch]$KeepTemp
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$HostExe = (Get-Process -Id $PID).Path
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("agentic-fresh-install-" + [guid]::NewGuid().ToString('N'))
$ProjectRoot = Join-Path $TempRoot "Fresh Project"

function Invoke-Child {
  param(
    [Parameter(Mandatory=$true)][string]$Script,
    [string[]]$ArgumentList = @()
  )

  $OldPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    & $HostExe -NoProfile -ExecutionPolicy Bypass -File $Script @ArgumentList 2>&1 |
      ForEach-Object { Write-Host $_ }
    $Code = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $OldPreference
  }

  if ($Code -ne 0) { throw "Child script failed with exit code ${Code}: $Script" }
}

function Invoke-Native {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string[]]$ArgumentList = @()
  )

  $OldPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    & $FilePath @ArgumentList 2>&1 | ForEach-Object { Write-Host $_ }
    $Code = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $OldPreference
  }

  if ($Code -ne 0) {
    throw "Native command failed with exit code ${Code}: $FilePath $($ArgumentList -join ' ')"
  }
}

try {
  New-Item -ItemType Directory -Force $TempRoot | Out-Null

  Invoke-Child -Script (Join-Path $Root 'scripts\windows\Initialize-AgenticProject.ps1') -ArgumentList @(
    '-RepoRoot',$Root,'-TargetRoot',$ProjectRoot,'-Mode','New','-ConflictPolicy','Fail','-Apply'
  )

  foreach ($Rel in @(
    '.agents\AGENTS.md','.agents\COMMAND_INVENTORY.json','.agents\workflows\specdoc.md',
    '.agy\PHASE_STATUS.json','.agy\FLOW_POLICY.json','.agy\INSTALLATION_MANIFEST.json',
    'scripts\Test-FastPatchAllowed.ps1',
    'scripts\windows\companion\New-WorkItem.ps1',
    'scripts\windows\companion\Set-WorkItemStatus.ps1',
    'scripts\windows\companion\Write-ExecutionScope.ps1',
    'scripts\windows\companion\Publish-RunResult.ps1',
    'README_PIPELINE.en.md','README_PIPELINE.ru.md','docs\START_HERE.en.md','docs\START_HERE.ru.md'
  )) {
    if (!(Test-Path -LiteralPath (Join-Path $ProjectRoot $Rel))) { throw "Fresh install missing: $Rel" }
  }

  $State = Get-Content -LiteralPath (Join-Path $ProjectRoot '.agy\PHASE_STATUS.json') -Raw | ConvertFrom-Json
  if ($State.state_profile -ne 'new-project' -or $State.next_required_command -ne '/specdoc') {
    throw "Fresh install did not select the new-project /specdoc state"
  }

  Invoke-Child -Script (Join-Path $Root 'scripts\windows\Test-CommandInventory.ps1') -ArgumentList @(
    '-RepoRoot',$Root,'-ProjectRoot',$ProjectRoot,'-SkipDocumentationScan'
  )

  Invoke-Child -Script (Join-Path $Root 'scripts\windows\Test-TemplateHygiene.ps1') -ArgumentList @(
    '-RepoRoot',$Root,'-TemplateRoot',$ProjectRoot
  )

  foreach ($File in Get-ChildItem -LiteralPath $ProjectRoot -Recurse -Force -File -Filter '*.json') {
    try { Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Json | Out-Null }
    catch { throw "Fresh-install JSON parse failed: $($File.FullName)" }
  }

  foreach ($File in Get-ChildItem -LiteralPath $ProjectRoot -Recurse -Force -File -Filter '*.ps1') {
    $Tokens = $null; $Errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($File.FullName,[ref]$Tokens,[ref]$Errors)
    if ($Errors.Count -gt 0) { throw "Fresh-install PowerShell parse failed: $($File.FullName): $($Errors[0].Message)" }
  }

  $Broken = New-Object System.Collections.Generic.List[string]
  foreach ($File in Get-ChildItem -LiteralPath $ProjectRoot -Recurse -Force -File -Filter '*.md') {
    $Text = Get-Content -LiteralPath $File.FullName -Raw
    foreach ($Match in [regex]::Matches($Text,'\]\((?!https?://|mailto:|#)(?<target>[^)#]+)(?:#[^)]+)?\)')) {
      $Target = [Uri]::UnescapeDataString($Match.Groups['target'].Value)
      $Resolved = Join-Path (Split-Path -Parent $File.FullName) ($Target -replace '/','\')
      if (!(Test-Path -LiteralPath $Resolved)) { [void]$Broken.Add("$($File.FullName) -> $Target") }
    }
  }
  if ($Broken.Count -gt 0) {
    $Broken | ForEach-Object { Write-Host $_ }
    throw "Fresh-install Markdown links are broken"
  }

  if (Get-Command node -ErrorAction SilentlyContinue) {
    foreach ($File in Get-ChildItem -LiteralPath $ProjectRoot -Recurse -Force -File -Filter '*.cjs') {
      Invoke-Native -FilePath 'node' -ArgumentList @('--check',$File.FullName)
    }
  }

  Invoke-Native -FilePath 'git' -ArgumentList @('-C',$ProjectRoot,'init')
  Invoke-Native -FilePath 'git' -ArgumentList @('-C',$ProjectRoot,'config','user.email','fresh-install@example.invalid')
  Invoke-Native -FilePath 'git' -ArgumentList @('-C',$ProjectRoot,'config','user.name','Fresh Install Smoke')
  Invoke-Native -FilePath 'git' -ArgumentList @('-C',$ProjectRoot,'add','-A')
  Invoke-Native -FilePath 'git' -ArgumentList @('-C',$ProjectRoot,'commit','-m','baseline')

  Invoke-Child -Script (Join-Path $ProjectRoot 'scripts\Test-FastPatchAllowed.ps1') -ArgumentList @('-RepoRoot',$ProjectRoot)

  Write-Host "Fresh-install smoke passed."
  exit 0
}
finally {
  if (!$KeepTemp -and (Test-Path -LiteralPath $TempRoot)) { Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
  elseif ($KeepTemp) { Write-Host "Fresh-install temp retained: $TempRoot" }
}
