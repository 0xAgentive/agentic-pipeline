param([string]$RepoRoot = ".")

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$Errors = New-Object System.Collections.Generic.List[string]

function Add-Error([string]$Message) { [void]$Errors.Add($Message) }
function Read-Json([string]$Path) {
  try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
  catch { Add-Error "Invalid JSON: $Path :: $($_.Exception.Message)"; return $null }
}
function Hash([string]$Path) {
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

$SchemaPath = Join-Path $Root "schemas\phase-status.schema.json"
if (!(Test-Path -LiteralPath $SchemaPath -PathType Leaf)) {
  Add-Error "Missing schema: schemas/phase-status.schema.json"
  $Schema = $null
} else {
  $Schema = Read-Json $SchemaPath
}

$RequiredFields = @()
if ($Schema) { $RequiredFields = @($Schema.required) }

$VersionPath = Join-Path $Root "VERSION.json"
$RuntimeVersion = ""
if (!(Test-Path -LiteralPath $VersionPath -PathType Leaf)) {
  Add-Error "Missing VERSION.json"
} else {
  $VersionInfo = Read-Json $VersionPath
  if ($VersionInfo) { $RuntimeVersion = [string]$VersionInfo.runtime_version }
}

$Profiles = @(
  [pscustomobject]@{ Name = "new-project"; Next = "/specdoc"; Current = "specification_required" },
  [pscustomobject]@{ Name = "adopt-existing"; Next = "/landing"; Current = "adoption_audit_required" }
)

foreach ($Profile in $Profiles) {
  $Dir = Join-Path $Root ("templates\state-profiles\" + $Profile.Name)
  $PhasePath = Join-Path $Dir "PHASE_STATUS.json"
  $AgentPath = Join-Path $Dir "AGENT_STATE.md"
  $RecoveryPath = Join-Path $Dir "RECOVERY_PROMPT.md"

  foreach ($Path in @($PhasePath,$AgentPath,$RecoveryPath)) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { Add-Error "Missing state-profile file: $Path" }
  }

  if (Test-Path -LiteralPath $PhasePath -PathType Leaf) {
    $State = Read-Json $PhasePath
    if ($State) {
      foreach ($Field in $RequiredFields) {
        if (!($State.PSObject.Properties.Name -contains $Field)) {
          Add-Error "$($Profile.Name) state missing required field: $Field"
        }
      }

      if ($State.schema_version -ne "1.2.0") { Add-Error "$($Profile.Name) schema_version must be 1.2.0" }
      if ($RuntimeVersion -and $State.framework_version -ne $RuntimeVersion) { Add-Error "$($Profile.Name) framework_version must match VERSION.json runtime_version" }
      if ($State.state_profile -ne $Profile.Name) { Add-Error "$($Profile.Name) state_profile mismatch" }
      if ($State.next_required_command -ne $Profile.Next) { Add-Error "$($Profile.Name) next_required_command must be $($Profile.Next)" }
      if ($State.current_phase -ne $Profile.Current) { Add-Error "$($Profile.Name) current_phase must be $($Profile.Current)" }
      if (@($State.commands_allowed_now) -notcontains $Profile.Next) { Add-Error "$($Profile.Name) commands_allowed_now must include $($Profile.Next)" }
      if ($State.hook_mode -ne "manual") { Add-Error "$($Profile.Name) hook_mode must default to manual" }
    }
  }

  if (Test-Path -LiteralPath $RecoveryPath -PathType Leaf) {
    $Recovery = Get-Content -LiteralPath $RecoveryPath -Raw
    if ($Recovery -notmatch [regex]::Escape($Profile.Next)) {
      Add-Error "$($Profile.Name) recovery prompt does not name $($Profile.Next)"
    }
  }
}

$TemplateDir = Join-Path $Root "templates\agy-project-base\.agy"
$NewDir = Join-Path $Root "templates\state-profiles\new-project"
foreach ($Name in @("PHASE_STATUS.json","AGENT_STATE.md","RECOVERY_PROMPT.md")) {
  $TemplatePath = Join-Path $TemplateDir $Name
  $ProfilePath = Join-Path $NewDir $Name
  if ((Hash $TemplatePath) -ne (Hash $ProfilePath)) {
    Add-Error "Base template $Name must exactly match the new-project profile"
  }
}

if ($Errors.Count -gt 0) {
  Write-Host "State-profile validation failed:"
  $Errors | Sort-Object -Unique | ForEach-Object { Write-Host "- $_" }
  exit 1
}

Write-Host "State-profile validation passed."
exit 0
