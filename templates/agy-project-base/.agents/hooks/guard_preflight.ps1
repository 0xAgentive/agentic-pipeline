[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $Root

$Required = @(
  ".agents\AGENTS.md",
  ".agents\COMMAND_INVENTORY.json",
  ".agy\PHASE_STATUS.json",
  ".cbmignore"
)

$Missing = @($Required | Where-Object { !(Test-Path -LiteralPath (Join-Path $Root $_)) })
if ($Missing.Count -gt 0) {
  Write-Error ("Pipeline preflight failed. Missing: " + ($Missing -join ", "))
  exit 1
}

$WorkItemPath = Join-Path $Root ".agy\WORK_ITEM.json"
if (!(Test-Path -LiteralPath $WorkItemPath -PathType Leaf)) {
  Write-Host "Pipeline preflight OK. No active work item."
  exit 0
}

try {
  $WorkItem = Get-Content -LiteralPath $WorkItemPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
  Write-Error "Pipeline preflight failed. WORK_ITEM.json is unreadable: $($_.Exception.Message)"
  exit 1
}

if ($WorkItem.owner_approved -ne $true) {
  Write-Error "Pipeline preflight failed. Active work item is not owner-approved."
  exit 1
}

if ($WorkItem.brief_fingerprint -and $WorkItem.goal) {
  $Bytes = [System.Text.Encoding]::UTF8.GetBytes(([string]$WorkItem.goal).Trim())
  $Hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    $LiveFingerprint = ([Convert]::ToHexString($Hasher.ComputeHash($Bytes))).ToLowerInvariant()
  }
  finally {
    $Hasher.Dispose()
  }
  if ($LiveFingerprint -ne [string]$WorkItem.brief_fingerprint) {
    Write-Error "Pipeline preflight failed. Immutable owner brief fingerprint changed."
    exit 1
  }
}

$LeaseRequiredStatuses = @("active", "implementation", "repair", "audit")
if ($LeaseRequiredStatuses -contains [string]$WorkItem.status) {
  $LeaseValidator = Join-Path $Root "scripts\windows\companion\Test-ExecutionLease.ps1"
  if (!(Test-Path -LiteralPath $LeaseValidator -PathType Leaf)) {
    Write-Error "Pipeline preflight failed. Execution-lease validator is missing."
    exit 1
  }

  & $LeaseValidator -ProjectRoot $Root -BeforeWrite
  if ($LASTEXITCODE -ne 0) {
    Write-Error "Pipeline preflight failed. Pre-write execution lease is invalid."
    exit 1
  }
}

$FirewallPath = Join-Path $Root ".agy\STAGE_FIREWALL.json"
if (Test-Path -LiteralPath $FirewallPath -PathType Leaf) {
  try {
    $Firewall = Get-Content -LiteralPath $FirewallPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($Firewall.status -eq "active" -and $Firewall.stage_profile -eq "protocol_freeze" -and $Firewall.algorithm_repair_authorized -ne $true) {
      $Changed = New-Object System.Collections.Generic.List[string]
      foreach ($GitArguments in @(
        @("diff", "--name-only"),
        @("diff", "--cached", "--name-only"),
        @("ls-files", "--others", "--exclude-standard")
      )) {
        $Output = @(& git -C $Root @GitArguments 2>$null)
        if ($LASTEXITCODE -eq 0) {
          foreach ($Item in $Output) {
            $Value = ([string]$Item).Replace("\", "/").Trim()
            if ($Value -and !$Changed.Contains($Value)) { [void]$Changed.Add($Value) }
          }
        }
      }

      $Blocked = New-Object System.Collections.Generic.List[string]
      foreach ($PathValue in $Changed) {
        foreach ($PatternValue in @($Firewall.protected_path_patterns)) {
          $Regex = [regex]::Escape(([string]$PatternValue).Replace("\", "/"))
          $Regex = $Regex.Replace("\*\*", ".*").Replace("\*", "[^/]*")
          if ($PathValue -match ("^" + $Regex + "$")) {
            if (!$Blocked.Contains($PathValue)) { [void]$Blocked.Add($PathValue) }
          }
        }
      }

      if ($Blocked.Count -gt 0) {
        Write-Error ("Pipeline preflight failed. Scientific-stage firewall blocks production analytical changes: " + ($Blocked -join ", "))
        exit 1
      }
    }
  }
  catch {
    Write-Error "Pipeline preflight failed. STAGE_FIREWALL.json is invalid: $($_.Exception.Message)"
    exit 1
  }
}

Write-Host "Pipeline preflight OK."
exit 0
