[CmdletBinding()]
param([string]$RepoRoot = '.')

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $Root 'scripts\windows\common\NativeProcess.ps1')
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('agentic-runtime-transaction-' + [Guid]::NewGuid().ToString('N'))
$BackupRoot = Join-Path $TempRoot 'backups'
$Pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$Updater = Join-Path $Root 'scripts\windows\Update-AgenticProjectRuntime-v1.2.9.ps1'
$Utf8 = [Text.UTF8Encoding]::new($false)

function Invoke-Required([string]$FilePath, [string[]]$Arguments, [string]$Description) {
  $Result = Invoke-AgenticNativeProcess -FilePath $FilePath -ArgumentList $Arguments
  Assert-AgenticNativeSuccess -Result $Result -Description $Description
  return $Result
}

function New-Fixture([string]$Name) {
  $Project = Join-Path $TempRoot $Name
  New-Item -ItemType Directory -Force -Path $Project | Out-Null
  Copy-Item -LiteralPath (Join-Path $Root 'templates\agy-project-base\.agents') -Destination (Join-Path $Project '.agents') -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $Root 'templates\agy-project-base\.agy') -Destination (Join-Path $Project '.agy') -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $Root 'templates\agy-project-base\scripts') -Destination (Join-Path $Project 'scripts') -Recurse -Force
  New-Item -ItemType Directory -Force -Path (Join-Path $Project 'src') | Out-Null
  [IO.File]::WriteAllText((Join-Path $Project 'src\product.txt'), "protected product bytes`n", $Utf8)
  Invoke-Required 'git' @('-C',$Project,'init','--quiet','--initial-branch=main') 'git init' | Out-Null
  Invoke-Required 'git' @('-C',$Project,'config','user.email','runtime-regression@example.invalid') 'git config email' | Out-Null
  Invoke-Required 'git' @('-C',$Project,'config','user.name','Runtime Regression') 'git config name' | Out-Null
  Invoke-Required 'git' @('-C',$Project,'add','--all') 'git add' | Out-Null
  Invoke-Required 'git' @('-C',$Project,'commit','--quiet','-m','fixture baseline') 'git commit' | Out-Null
  return $Project
}

function Get-TreeSnapshot([string]$Project) {
  $Rows = New-Object System.Collections.Generic.List[string]
  foreach ($File in Get-ChildItem -LiteralPath $Project -Recurse -Force -File | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }) {
    $Relative = $File.FullName.Substring($Project.Length).TrimStart('\').Replace('\','/')
    [void]$Rows.Add("$Relative`0$($File.Length)`0$((Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant())")
  }
  return @($Rows.ToArray() | Sort-Object)
}

function Compare-Snapshot([string[]]$Before, [string[]]$After) {
  return @(Compare-Object -ReferenceObject $Before -DifferenceObject $After)
}

try {
  New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
  $Project = New-Fixture 'idempotent project юникод'
  Remove-Item -LiteralPath (Join-Path $Project '.agy\PROGRESS_STATE.json') -Force
  Remove-Item -LiteralPath (Join-Path $Project '.agy\NEXT_ACTION.json') -Force
  $ProductBefore = (Get-FileHash -LiteralPath (Join-Path $Project 'src\product.txt') -Algorithm SHA256).Hash
  $Common = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Updater,'-ProjectRoot',$Project,'-RepoRoot',$Root,'-Apply','-AllowDirty','-BackupBaseRoot',$BackupRoot)
  Invoke-Required $Pwsh $Common 'runtime updater first apply' | Out-Null
  foreach ($Required in @('.agy\PROGRESS_STATE.json','.agy\NEXT_ACTION.json','.agy\OWNER_AUTONOMY_MIGRATION_RESULT.json','.agy\INSTALLATION_MANIFEST.json','.agy\RUNTIME_UPDATE_RESULT.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Project $Required) -PathType Leaf)) { throw "Runtime updater omitted required state: $Required" }
  }
  if ((Get-FileHash -LiteralPath (Join-Path $Project 'src\product.txt') -Algorithm SHA256).Hash -ne $ProductBefore) { throw 'Runtime updater changed product source.' }
  $BeforeSecond = @(Get-TreeSnapshot $Project)
  Invoke-Required $Pwsh $Common 'runtime updater verification-only second apply' | Out-Null
  $AfterSecond = @(Get-TreeSnapshot $Project)
  $SecondDelta = @(Compare-Snapshot $BeforeSecond $AfterSecond)
  if ($SecondDelta.Count -gt 0) { throw "Second identical updater run changed bytes: $($SecondDelta.InputObject -join ', ')" }

  $FaultProject = New-Fixture 'rollback project'
  Remove-Item -LiteralPath (Join-Path $FaultProject '.agy\PROGRESS_STATE.json') -Force
  Remove-Item -LiteralPath (Join-Path $FaultProject '.agy\NEXT_ACTION.json') -Force
  [IO.File]::AppendAllText((Join-Path $FaultProject '.agents\AGENTS.md'), "fault probe`n", $Utf8)
  $BeforeFault = @(Get-TreeSnapshot $FaultProject)
  $Fault = Invoke-AgenticNativeProcess -FilePath $Pwsh -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Updater,'-ProjectRoot',$FaultProject,'-RepoRoot',$Root,'-Apply','-AllowDirty','-SkipValidation','-BackupBaseRoot',$BackupRoot,'-FaultInjectionAfterWrites','2')
  if ($Fault.ExitCode -eq 0 -or $Fault.StdErr + $Fault.StdOut -notmatch 'Injected runtime update failure') { throw 'Fault injection did not fail at the requested write boundary.' }
  $AfterFault = @(Get-TreeSnapshot $FaultProject)
  $FaultDelta = @(Compare-Snapshot $BeforeFault $AfterFault)
  if ($FaultDelta.Count -gt 0) { throw "Transactional rollback was not byte-exact: $($FaultDelta.InputObject -join ', ')" }
  Write-Host 'Runtime updater transaction, rollback, product preservation and byte-identical second run passed.'
}
finally {
  Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
