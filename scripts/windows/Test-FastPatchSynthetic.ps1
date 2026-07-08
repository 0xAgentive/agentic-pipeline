$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$GateSource = Join-Path $RepoRoot "scripts\Test-FastPatchAllowed.ps1"

if (!(Test-Path $GateSource)) {
  throw "Missing fastpatch gate: $GateSource"
}

function Get-PowerShellExecutable {
  $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($pwsh) {
    return $pwsh.Source
  }

  $windowsPowerShell = Get-Command powershell -ErrorAction SilentlyContinue
  if ($windowsPowerShell) {
    return $windowsPowerShell.Source
  }

  throw "No PowerShell executable found. Expected pwsh or powershell."
}

function Invoke-NativeChecked {
  param(
    [Parameter(Mandatory=$true)][string]$Exe,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$Args
  )

  & $Exe @Args
  $code = $LASTEXITCODE

  if ($code -ne 0) {
    throw "Native command failed with exit code ${code}: $Exe $($Args -join ' ')"
  }
}

function Invoke-Gate {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][bool]$ShouldPass
  )

  $shell = Get-PowerShellExecutable
  $shellName = [System.IO.Path]::GetFileName($shell)

  $args = @("-NoProfile")

  if ($shellName -match "^(?i:powershell)(\.exe)?$") {
    $args += @("-ExecutionPolicy", "Bypass")
  }

  $args += @("-File", ".\scripts\Test-FastPatchAllowed.ps1")

  & $shell @args
  $code = $LASTEXITCODE

  if ($ShouldPass -and $code -ne 0) {
    throw "Expected fastpatch gate to PASS for test '$Name', but exit code was $code"
  }

  if ((-not $ShouldPass) -and $code -eq 0) {
    throw "Expected fastpatch gate to FAIL for test '$Name', but exit code was 0"
  }

  Write-Host "Synthetic test OK: $Name"
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("agentic-fastpatch-synthetic-" + [System.Guid]::NewGuid().ToString("N"))

New-Item -ItemType Directory -Force $tmp | Out-Null

try {
  Set-Location $tmp

  New-Item -ItemType Directory -Force "scripts" | Out-Null
  New-Item -ItemType Directory -Force "src/frontend/components" | Out-Null
  New-Item -ItemType Directory -Force "src/frontend/styles" | Out-Null
  New-Item -ItemType Directory -Force "src/backend" | Out-Null

  Copy-Item $GateSource "scripts\Test-FastPatchAllowed.ps1" -Force

  git init -b main *> $null
  if ($LASTEXITCODE -ne 0) {
    git init *> $null
    if ($LASTEXITCODE -ne 0) {
      throw "git init failed"
    }

    git branch -M main *> $null
    if ($LASTEXITCODE -ne 0) {
      throw "git branch -M main failed"
    }
  }

  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

  Set-Content "src/frontend/components/AppSelect.tsx" "export function AppSelect(){ return null; }" -Encoding UTF8
  Set-Content "src/frontend/components/OverlayRoot.tsx" "export function OverlayRoot(){ return null; }" -Encoding UTF8
  Set-Content "src/frontend/styles/app.css" ".root { display: block; }" -Encoding UTF8
  Set-Content "src/backend/secret.ts" "export const secret = 1;" -Encoding UTF8

  Invoke-NativeChecked git add .
  Invoke-NativeChecked git commit -m "baseline"

  Add-Content "src/frontend/components/AppSelect.tsx" "// harmless UI-only change"
  Invoke-Gate -Name "allowlisted UI-only file passes" -ShouldPass $true
  Invoke-NativeChecked git checkout -- .

  Add-Content "src/frontend/components/OverlayRoot.tsx" 'import { secret } from "../../backend/secret";'
  Invoke-Gate -Name "backend import in allowlisted UI file is blocked" -ShouldPass $false
  Invoke-NativeChecked git checkout -- .

  Add-Content "src/frontend/components/AppSelect.tsx" 'fetch("https://example.com");'
  Invoke-Gate -Name "fetch in allowlisted UI file is blocked" -ShouldPass $false
  Invoke-NativeChecked git checkout -- .

  Add-Content "src/frontend/components/AppSelect.tsx" 'localStorage.setItem("x","y");'
  Invoke-Gate -Name "localStorage in allowlisted UI file is blocked" -ShouldPass $false
  Invoke-NativeChecked git checkout -- .

  Add-Content "src/frontend/components/AppSelect.tsx" 'export const dangerous = { dangerouslySetInnerHTML: { __html: "<b>x</b>" } };'
  Invoke-Gate -Name "dangerouslySetInnerHTML in allowlisted UI file is blocked" -ShouldPass $false
  Invoke-NativeChecked git checkout -- .

  Set-Content "src/backend/newUnsafe.ts" "export const x = 1;" -Encoding UTF8
  Invoke-Gate -Name "untracked backend file is blocked" -ShouldPass $false

  Write-Host "Fastpatch synthetic tests passed."
  exit 0
}
finally {
  Set-Location $RepoRoot
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}