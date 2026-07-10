param(
  [string]$RepoRoot = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

$GateSources = @(
  [pscustomobject]@{ Name = "root"; Path = Join-Path $RepoRoot "scripts\Test-FastPatchAllowed.ps1" },
  [pscustomobject]@{ Name = "template"; Path = Join-Path $RepoRoot "templates\agy-project-base\scripts\Test-FastPatchAllowed.ps1" }
)

function Get-PowerShellExecutable {
  $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($pwsh) { return $pwsh.Source }

  $windowsPowerShell = Get-Command powershell -ErrorAction SilentlyContinue
  if ($windowsPowerShell) { return $windowsPowerShell.Source }

  throw "No PowerShell executable found."
}

function Invoke-NativeChecked {
  param(
    [Parameter(Mandatory=$true)][string]$Exe,
    [Parameter(Mandatory=$true)][string[]]$ArgumentList
  )

  # AGY_SYNTHETIC_NATIVE_STDERR_SAFE
  $oldPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    & $Exe @ArgumentList 2>&1 | ForEach-Object { Write-Host $_ }
    $code = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $oldPreference
  }

  if ($code -ne 0) {
    throw "Native command failed with exit code ${code}: $Exe $($ArgumentList -join ' ')"
  }
}

function Invoke-Gate {
  param(
    [Parameter(Mandatory=$true)][string]$GatePath,
    [Parameter(Mandatory=$true)][string]$SyntheticRoot,
    [Parameter(Mandatory=$true)][string]$TestName,
    [Parameter(Mandatory=$true)][bool]$ShouldPass,
    [switch]$RequireChanges,
    [int]$MaxChangedFiles = 3,
    [int]$MaxAddedLines = 80,
    [int]$MaxDeletedLines = 120
  )

  $shell = Get-PowerShellExecutable
  $args = @("-NoProfile")
  if ([System.IO.Path]::GetFileName($shell) -match "^(?i:powershell)(\.exe)?$") {
    $args += @("-ExecutionPolicy", "Bypass")
  }

  $args += @(
    "-File", $GatePath,
    "-RepoRoot", $SyntheticRoot,
    "-MaxChangedFiles", "$MaxChangedFiles",
    "-MaxAddedLines", "$MaxAddedLines",
    "-MaxDeletedLines", "$MaxDeletedLines"
  )

  if ($RequireChanges) { $args += "-RequireChanges" }

  # AGY_GATE_STDERR_SAFE
  $oldPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    & $shell @args 2>&1 | ForEach-Object { Write-Host $_ }
    $code = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $oldPreference
  }

  if ($ShouldPass -and $code -ne 0) {
    throw "Expected PASS: $TestName; exit=$code"
  }
  if (!$ShouldPass -and $code -eq 0) {
    throw "Expected FAIL: $TestName; exit=0"
  }

  Write-Host "Synthetic test OK: $TestName"
}

foreach ($gate in $GateSources) {
  if (!(Test-Path -LiteralPath $gate.Path -PathType Leaf)) {
    throw "Missing $($gate.Name) fastpatch gate: $($gate.Path)"
  }

  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("agentic-fastpatch-" + $gate.Name + "-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force $tmp | Out-Null

  try {
    New-Item -ItemType Directory -Force (Join-Path $tmp "src\frontend\components") | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $tmp "src\frontend\styles") | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $tmp "src\backend") | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $tmp ".agy") | Out-Null

    Set-Content -LiteralPath (Join-Path $tmp "src\frontend\components\AppSelect.tsx") -Value "export function AppSelect(){ return null; }" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $tmp "src\frontend\components\OverlayRoot.tsx") -Value "export function OverlayRoot(){ return null; }" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $tmp "src\frontend\styles\app.css") -Value ".root { display: block; }" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $tmp "src\backend\secret.ts") -Value "export const secret = 1;" -Encoding UTF8

    Invoke-NativeChecked -Exe "git" -ArgumentList @("-C", $tmp, "init")
    Invoke-NativeChecked -Exe "git" -ArgumentList @("-C", $tmp, "config", "user.name", "agentic-tests")
    Invoke-NativeChecked -Exe "git" -ArgumentList @("-C", $tmp, "config", "user.email", "agentic-tests@example.invalid")
    Invoke-NativeChecked -Exe "git" -ArgumentList @("-C", $tmp, "add", ".")
    Invoke-NativeChecked -Exe "git" -ArgumentList @("-C", $tmp, "commit", "-m", "baseline")

    Invoke-Gate -GatePath $gate.Path -SyntheticRoot $tmp -TestName "$($gate.Name): clean preflight passes" -ShouldPass $true
    Invoke-Gate -GatePath $gate.Path -SyntheticRoot $tmp -TestName "$($gate.Name): clean RequireChanges fails" -ShouldPass $false -RequireChanges

    Add-Content -LiteralPath (Join-Path $tmp "src\frontend\components\AppSelect.tsx") -Value "// harmless UI change"
    Invoke-Gate -GatePath $gate.Path -SyntheticRoot $tmp -TestName "$($gate.Name): harmless UI change passes" -ShouldPass $true -RequireChanges
    Invoke-NativeChecked -Exe "git" -ArgumentList @("-C", $tmp, "reset", "--hard", "HEAD")
    Invoke-NativeChecked -Exe "git" -ArgumentList @("-C", $tmp, "clean", "-fd")

    Add-Content -LiteralPath (Join-Path $tmp "src\frontend\components\AppSelect.tsx") -Value 'fetch("https://example.com");'
    Invoke-Gate -GatePath $gate.Path -SyntheticRoot $tmp -TestName "$($gate.Name): fetch blocked" -ShouldPass $false -RequireChanges
    Invoke-NativeChecked -Exe "git" -ArgumentList @("-C", $tmp, "reset", "--hard", "HEAD")
    Invoke-NativeChecked -Exe "git" -ArgumentList @("-C", $tmp, "clean", "-fd")

    Add-Content -LiteralPath (Join-Path $tmp "src\frontend\components\AppSelect.tsx") -Value 'localStorage.setItem("x","y");'
    Invoke-Gate -GatePath $gate.Path -SyntheticRoot $tmp -TestName "$($gate.Name): localStorage blocked" -ShouldPass $false -RequireChanges
    Invoke-NativeChecked -Exe "git" -ArgumentList @("-C", $tmp, "reset", "--hard", "HEAD")
    Invoke-NativeChecked -Exe "git" -ArgumentList @("-C", $tmp, "clean", "-fd")

    Add-Content -LiteralPath (Join-Path $tmp "src\frontend\components\OverlayRoot.tsx") -Value 'import { secret } from "../../backend/secret";'
    Invoke-Gate -GatePath $gate.Path -SyntheticRoot $tmp -TestName "$($gate.Name): backend import blocked" -ShouldPass $false -RequireChanges
    Invoke-NativeChecked -Exe "git" -ArgumentList @("-C", $tmp, "reset", "--hard", "HEAD")
    Invoke-NativeChecked -Exe "git" -ArgumentList @("-C", $tmp, "clean", "-fd")

    Set-Content -LiteralPath (Join-Path $tmp "src\backend\newUnsafe.ts") -Value "export const x = 1;" -Encoding UTF8
    Invoke-Gate -GatePath $gate.Path -SyntheticRoot $tmp -TestName "$($gate.Name): untracked backend file blocked" -ShouldPass $false -RequireChanges
    Remove-Item -LiteralPath (Join-Path $tmp "src\backend\newUnsafe.ts") -Force

    Set-Content -LiteralPath (Join-Path $tmp "src\frontend\components\NewWidget.tsx") -Value "export const NewWidget = 1;" -Encoding UTF8
    Invoke-Gate -GatePath $gate.Path -SyntheticRoot $tmp -TestName "$($gate.Name): new UI file blocked by default" -ShouldPass $false -RequireChanges
    Remove-Item -LiteralPath (Join-Path $tmp "src\frontend\components\NewWidget.tsx") -Force

    Add-Content -LiteralPath (Join-Path $tmp "src\frontend\components\AppSelect.tsx") -Value "// one"
    Add-Content -LiteralPath (Join-Path $tmp "src\frontend\components\OverlayRoot.tsx") -Value "// two"
    Add-Content -LiteralPath (Join-Path $tmp "src\frontend\styles\app.css") -Value "/* three */"
    Set-Content -LiteralPath (Join-Path $tmp "src\frontend\styles\extra.css") -Value "/* four */" -Encoding UTF8
    # AGY_SYNTHETIC_POLICY_DIR
    New-Item -ItemType Directory -Force (Join-Path $tmp ".agy") | Out-Null
    Set-Content -LiteralPath (Join-Path $tmp ".agy\FASTPATCH_POLICY.json") -Value '{"allowNewFiles":true}' -Encoding UTF8
    Invoke-Gate -GatePath $gate.Path -SyntheticRoot $tmp -TestName "$($gate.Name): max file count enforced" -ShouldPass $false -RequireChanges -MaxChangedFiles 3
    Invoke-NativeChecked -Exe "git" -ArgumentList @("-C", $tmp, "reset", "--hard", "HEAD")
    Invoke-NativeChecked -Exe "git" -ArgumentList @("-C", $tmp, "clean", "-fd")

    1..6 | ForEach-Object { Add-Content -LiteralPath (Join-Path $tmp "src\frontend\components\AppSelect.tsx") -Value ("// line " + $_) }
    Invoke-Gate -GatePath $gate.Path -SyntheticRoot $tmp -TestName "$($gate.Name): added line limit enforced" -ShouldPass $false -RequireChanges -MaxAddedLines 5

    Write-Host "Fastpatch synthetic suite passed for $($gate.Name)."
  }
  finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host "All root/template fastpatch synthetic tests passed."
exit 0
