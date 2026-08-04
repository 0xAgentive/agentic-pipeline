[CmdletBinding()]
param(
  [string]$ProjectRoot = ".",
  [ValidateSet("initial_comprehensive","final")][string]$AuditCycle = "initial_comprehensive",
  [string]$CoverageInputPath = "",
  [switch]$Complete,
  [switch]$Apply
)
$ErrorActionPreference="Stop";$Root=(Resolve-Path $ProjectRoot).Path;$Agy=Join-Path $Root ".agy";$WiPath=Join-Path $Agy "WORK_ITEM.json";$Out=Join-Path $Agy "AUDIT_COVERAGE_MATRIX.json";$Utf8=[Text.UTF8Encoding]::new($false)
if(!(Test-Path $WiPath)){throw "WORK_ITEM.json missing"};$Wi=Get-Content $WiPath -Raw|ConvertFrom-Json
$Head=(& git -C $Root rev-parse HEAD).Trim();if($LASTEXITCODE-ne 0){throw "git HEAD unavailable"}
if($CoverageInputPath){$Rows=@(Get-Content (Resolve-Path $CoverageInputPath) -Raw|ConvertFrom-Json)}else{
 $Rows=@();$i=0;foreach($A in @($Wi.acceptance)){ $Rows += [pscustomobject]@{coverage_id=("AC-{0:D3}"-f($i+1));acceptance_index=$i;requirement=[string]$A;surfaces=@("executor_discovery_required");evidence_required=@("actual_product_evidence");checks=@("product_specific_check_required");status="not_evaluated";notes=@()};$i++ }
}
if($Rows.Count-ne @($Wi.acceptance).Count){throw "Coverage row count must equal acceptance outcome count"}
$Ids=@($Rows.coverage_id);if(@($Ids|Select-Object -Unique).Count-ne $Ids.Count){throw "Duplicate coverage IDs"}
$Uncovered=@($Rows|Where-Object{$_.status -eq "not_evaluated"}|ForEach-Object{[int]$_.acceptance_index})
$Status=if($Complete -and $Uncovered.Count-eq 0){"complete"}elseif($Complete){"blocked"}else{"draft"}
$M=[ordered]@{schema_version="1.0.0";work_item_id=[string]$Wi.work_item_id;target_head=$Head;audit_cycle=$AuditCycle;status=$Status;acceptance_coverage=$Rows;uncovered_acceptance_indexes=$Uncovered;generated_at_utc=(Get-Date).ToUniversalTime().ToString("o");completed_at_utc=if($Status-eq"complete"){(Get-Date).ToUniversalTime().ToString("o")}else{$null}}
if($Apply){$T=$Out+".tmp";[IO.File]::WriteAllText($T,($M|ConvertTo-Json -Depth 30),$Utf8);Move-Item $T $Out -Force;Write-Host "Audit coverage matrix published: $Out"}else{$M|ConvertTo-Json -Depth 30}
if($Complete -and $Status-ne"complete"){exit 1}
