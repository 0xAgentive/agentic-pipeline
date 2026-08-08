[CmdletBinding()]
param([string]$RepoRoot = '.')

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $Root 'scripts\windows\common\NativeProcess.ps1')
$Checks = New-Object System.Collections.Generic.List[object]
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('agentic-finalization-regression-юникод-' + [Guid]::NewGuid().ToString('N'))
$Utf8 = [Text.UTF8Encoding]::new($false)

function Add-Pass([string]$Id, [string]$Details) {
  [void]$Checks.Add([pscustomobject]@{ id = $Id; status = 'PASS'; details = $Details })
}

function Invoke-Checked([string]$FilePath, [string[]]$Arguments, [string]$Description, [string]$WorkingDirectory = '') {
  $Result = Invoke-AgenticNativeProcess -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory
  Assert-AgenticNativeSuccess -Result $Result -Description $Description
  return $Result
}

function Write-Json([string]$Path, [object]$Value) {
  $Parent = Split-Path -Parent $Path
  if ($Parent) { New-Item -ItemType Directory -Force -Path $Parent | Out-Null }
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30), $Utf8)
}

try {
  New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
  $Pwsh = (Get-Command pwsh -ErrorAction Stop).Source
  if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7 or later is required.' }
  Add-Pass 'KF-004' "pwsh $($PSVersionTable.PSVersion)"

  $Bash = Get-Command bash -ErrorAction SilentlyContinue
  if ($Bash) {
    $Probe = Invoke-AgenticNativeProcess -FilePath $Bash.Source -ArgumentList @('-lc', 'test -x /bin/bash && /bin/bash --version')
    if ($Probe.ExitCode -eq 0 -and $Probe.StdOut -match 'GNU bash') {
      Add-Pass 'KF-003' 'Functional GNU Bash is available.'
    }
    elseif (Test-Path -LiteralPath (Join-Path $Root 'scripts\windows\Validate-AgenticPipelinePackage.ps1') -PathType Leaf) {
      Add-Pass 'KF-003' 'bash.exe is not functional GNU Bash; native Windows validator is present.'
    }
    else { throw 'Fake/nonfunctional bash.exe found and no native validator is available.' }
  }
  else {
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'scripts\windows\Validate-AgenticPipelinePackage.ps1') -PathType Leaf)) { throw 'Neither Bash nor native Windows validator is available.' }
    Add-Pass 'KF-003' 'No Bash found; native Windows validator is present.'
  }

  $UnicodeCommand = "[Console]::OutputEncoding=[Text.UTF8Encoding]::new(`$false);[Console]::Write('stdout-юникод');[Console]::Error.Write('stderr-отдельно')"
  $Unicode = Invoke-Checked -FilePath $Pwsh -Arguments @('-NoProfile', '-Command', $UnicodeCommand) -Description 'Unicode stdout/stderr probe'
  if ($Unicode.StdOut -ne 'stdout-юникод' -or $Unicode.StdErr -ne 'stderr-отдельно') { throw "Unicode streams were corrupted or mixed: stdout=$($Unicode.StdOut), stderr=$($Unicode.StdErr)" }
  Add-Pass 'KF-009/KF-011' 'UTF-8 stdout and stderr are byte-logically separate.'

  $List = New-Object System.Collections.Generic.List[string]
  [void]$List.Add('one')
  [string[]]$Singleton = $List.ToArray()
  [void]$List.Add('two')
  [string[]]$Multiple = $List.ToArray()
  if ($Singleton.Count -ne 1 -or $Multiple.Count -ne 2) { throw 'Generic List singleton/multiple conversion failed.' }
  Add-Pass 'KF-016' 'Generic List singleton and multiple values require .ToArray().' 

  $GitRepo = Join-Path $TempRoot 'git paths with spaces'
  New-Item -ItemType Directory -Force -Path $GitRepo | Out-Null
  Invoke-Checked -FilePath 'git' -Arguments @('-C', $GitRepo, 'init', '--quiet') -Description 'git init' | Out-Null
  Invoke-Checked -FilePath 'git' -Arguments @('-C', $GitRepo, 'config', 'user.email', 'regression@example.invalid') -Description 'git config email' | Out-Null
  Invoke-Checked -FilePath 'git' -Arguments @('-C', $GitRepo, 'config', 'user.name', 'Regression') -Description 'git config name' | Out-Null
  [IO.File]::WriteAllText((Join-Path $GitRepo 'docs-first-entry.txt'), "base`n", $Utf8)
  [IO.File]::WriteAllText((Join-Path $GitRepo 'юникод path.txt'), "base`n", $Utf8)
  Invoke-Checked -FilePath 'git' -Arguments @('-C', $GitRepo, 'add', '--all') -Description 'git add' | Out-Null
  Invoke-Checked -FilePath 'git' -Arguments @('-C', $GitRepo, 'commit', '--quiet', '-m', 'baseline') -Description 'git commit' | Out-Null
  [IO.File]::AppendAllText((Join-Path $GitRepo 'docs-first-entry.txt'), "change`n", $Utf8)
  [IO.File]::AppendAllText((Join-Path $GitRepo 'юникод path.txt'), "change`n", $Utf8)
  $Names = Invoke-Checked -FilePath 'git' -Arguments @('-c', 'core.quotepath=false', '-C', $GitRepo, 'diff', '--name-only', '-z', '--') -Description 'git NUL path list'
  [string[]]$Paths = @(Split-AgenticNulList -Text $Names.StdOut)
  if ($Paths.Count -ne 2 -or $Paths[0] -ne 'docs-first-entry.txt' -or $Paths[1] -ne 'юникод path.txt') { throw "NUL-delimited Git paths were parsed incorrectly: $($Paths -join ' | ')" }
  Add-Pass 'KF-044' 'NUL parsing preserves the first byte, spaces and Unicode.'

  Invoke-Checked -FilePath $Pwsh -Arguments @('-NoProfile', '-File', (Join-Path $Root 'tests\acceptance\Test-CandidateOverlayEolSafety.ps1'), '-RepoRoot', $Root) -Description 'CRLF overlay regression' | Out-Null
  Add-Pass 'KF-043/KF-046' 'Blob-identical overlay leaves CRLF checkout bytes unchanged.'

  $LegacyRepo = Join-Path $TempRoot 'legacy state fixture'
  New-Item -ItemType Directory -Force -Path (Join-Path $LegacyRepo '.agy'), (Join-Path $LegacyRepo 'scripts\control-plane') | Out-Null
  Copy-Item -LiteralPath (Join-Path $Root 'scripts\control-plane\validate-findings.cjs') -Destination (Join-Path $LegacyRepo 'scripts\control-plane\validate-findings.cjs')
  Invoke-Checked -FilePath 'git' -Arguments @('-C', $LegacyRepo, 'init', '--quiet') -Description 'legacy git init' | Out-Null
  Invoke-Checked -FilePath 'git' -Arguments @('-C', $LegacyRepo, 'config', 'user.email', 'regression@example.invalid') -Description 'legacy git config email' | Out-Null
  Invoke-Checked -FilePath 'git' -Arguments @('-C', $LegacyRepo, 'config', 'user.name', 'Regression') -Description 'legacy git config name' | Out-Null
  Write-Json (Join-Path $LegacyRepo '.agy\WORK_ITEM.json') ([ordered]@{ schema_version='1.0.0'; work_item_id='legacy-001'; goal='legacy goal'; goal_epoch=1; assurance_mode='guarded'; stage_profile='implementation' })
  Write-Json (Join-Path $LegacyRepo '.agy\WORK_ITEM_TRANSACTION.json') ([ordered]@{ schema_version='1.0.0'; status='committed'; work_item_id='legacy-001' })
  Write-Json (Join-Path $LegacyRepo '.agy\STAGE_FIREWALL.json') ([ordered]@{ schema_version='1.0.0'; stage_profile='implementation' })
  Invoke-Checked -FilePath 'git' -Arguments @('-C', $LegacyRepo, 'add', '--all') -Description 'legacy git add' | Out-Null
  Invoke-Checked -FilePath 'git' -Arguments @('-C', $LegacyRepo, 'commit', '--quiet', '-m', 'fixture') -Description 'legacy git commit' | Out-Null

  $Coverage = Invoke-Checked -FilePath $Pwsh -Arguments @('-NoProfile', '-File', (Join-Path $Root 'scripts\windows\companion\Publish-AuditCoverageMatrix.ps1'), '-ProjectRoot', $LegacyRepo) -Description 'legacy coverage matrix'
  $CoverageObject = $Coverage.StdOut | ConvertFrom-Json
  if (@($CoverageObject.acceptance_coverage).Count -ne 0 -or @($CoverageObject.dimension_coverage).Count -ne 0) { throw 'Legacy optional coverage fields were not treated as empty.' }

  $FindingPath = Join-Path $TempRoot 'finding-without-optional-fields.json'
  $FindingObject=[ordered]@{ finding_id='F-001'; title='legacy finding'; category='delivery'; severity='medium'; lifecycle_status='open_confirmed'; phase_classification='current_phase_blocker'; materiality='verification_blocker'; auto_repairable=$true; owner_decision_required=$false }
  [IO.File]::WriteAllText($FindingPath, ($FindingObject | ConvertTo-Json -Depth 20 -AsArray), $Utf8)
  Invoke-Checked -FilePath $Pwsh -Arguments @('-NoProfile', '-File', (Join-Path $Root 'scripts\windows\companion\Register-FindingDelta.ps1'), '-ProjectRoot', $LegacyRepo, '-FindingInputPath', $FindingPath) -Description 'legacy finding optional properties' | Out-Null

  $Scope = Invoke-Checked -FilePath $Pwsh -Arguments @('-NoProfile', '-File', (Join-Path $Root 'scripts\windows\companion\Bind-ExecutionScopeTransaction.ps1'), '-ProjectRoot', $LegacyRepo, '-AllowedPaths', 'src/example.txt', '-Route', '/nextphase') -Description 'legacy firewall upsert'
  $ScopeObject = $Scope.StdOut | ConvertFrom-Json
  if ($ScopeObject.firewall.status -ne 'active' -or $ScopeObject.firewall.work_item_id -ne 'legacy-001') { throw 'Legacy firewall properties were not safely upserted.' }
  Add-Pass 'KF-042' 'StrictMode legacy shapes accept missing optional finding, work-item and firewall properties.'

  Invoke-Checked -FilePath $Pwsh -Arguments @('-NoProfile', '-File', (Join-Path $Root 'scripts\windows\Test-PowerShellRuntimeContracts.ps1'), '-RepoRoot', $Root) -Description 'PowerShell AST contract' | Out-Null
  Add-Pass 'KF-007/KF-012/KF-013/KF-014/KF-015' 'Every active PowerShell script is parser and automatic-variable gated.'

  $Unsafe = Get-ChildItem -LiteralPath (Join-Path $Root 'scripts') -Recurse -File -Include '*.ps1' |
    Where-Object { $_.FullName -notmatch '[\\/]archive[\\/]' -and $_.Name -notmatch '^(Test|Validate)-' -and $_.FullName -ne $PSCommandPath } |
    Where-Object {
      $ScriptText=[IO.File]::ReadAllText($_.FullName)
      $ScriptText -match '(?i)git\s+(?:reset\s+--hard|clean\s+-[a-z]*f)' -or
      $ScriptText -match '(?i)["'']reset["'']\s*,\s*["'']--hard["'']' -or
      $ScriptText -match '(?i)["'']clean["'']\s*,\s*["'']-[a-z]*f["'']'
    }
  if (@($Unsafe).Count -gt 0) { throw ('Active scripts contain broad destructive Git rollback: ' + (@($Unsafe.FullName) -join ', ')) }
  Add-Pass 'KF-050/KF-060' 'Active rollback paths contain no broad git reset --hard or clean -f.'

  $Report = [ordered]@{ schema_version='1.0.0'; status='PASS'; checks=$Checks.ToArray() }
  $Report | ConvertTo-Json -Depth 10 | Write-Host
  Write-Host 'Finalization Windows regressions passed.'
}
finally {
  Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
