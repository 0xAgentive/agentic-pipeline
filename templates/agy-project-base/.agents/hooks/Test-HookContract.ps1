$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $Root

$hooks = @(
  ".agents\hooks\guard_preflight.ps1",
  ".agents\hooks\guard_context_budget.ps1",
  ".agents\hooks\guard_offline_local_only.ps1",
  ".agents\hooks\agy_checkpoint.ps1"
)

$results = @()
$failed = $false

foreach ($hook in $hooks) {
  if (!(Test-Path $hook)) {
    $results += [pscustomobject]@{ Hook = $hook; Status = "missing"; ExitCode = $null; DurationMs = 0 }
    $failed = $true
    continue
  }

  $start = Get-Date
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = "powershell.exe"
  $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$hook`""
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true

  $p = [System.Diagnostics.Process]::Start($psi)
  $ok = $p.WaitForExit(20000)
  $duration = [int]((Get-Date) - $start).TotalMilliseconds

  if (!$ok) {
    try { $p.Kill() } catch {}
    $results += [pscustomobject]@{ Hook = $hook; Status = "timeout"; ExitCode = $null; DurationMs = $duration }
    $failed = $true
    continue
  }

  $status = if ($p.ExitCode -eq 0) { "ok" } else { "nonzero_exit" }
  if ($p.ExitCode -ne 0) { $failed = $true }
  $results += [pscustomobject]@{ Hook = $hook; Status = $status; ExitCode = $p.ExitCode; DurationMs = $duration }
}

$results | Format-Table -AutoSize

if ($failed) { exit 1 }
exit 0
