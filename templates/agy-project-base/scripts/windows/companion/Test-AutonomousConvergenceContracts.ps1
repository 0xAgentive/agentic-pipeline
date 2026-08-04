[CmdletBinding()]param([string]$RepoRoot=".")
$ErrorActionPreference="Stop";$Root=(Resolve-Path $RepoRoot).Path;$Node=Get-Command node -ErrorAction Stop;$Core=Join-Path $Root "scripts\control-plane\autonomous-convergence.cjs";$Acceptance=Join-Path $Root "tests\acceptance\autonomous-convergence-contract.cjs";foreach($P in @($Core,$Acceptance)){if(!(Test-Path $P)){throw "Missing: $P"}}
& $Node.Source $Core self-test;if($LASTEXITCODE-ne0){throw "Autonomous convergence self-test failed"}
& $Node.Source $Acceptance;if($LASTEXITCODE-ne0){throw "Autonomous convergence acceptance contract failed"}
Write-Host "Autonomous convergence contracts passed.";exit 0
