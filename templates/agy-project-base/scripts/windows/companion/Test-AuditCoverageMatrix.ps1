[CmdletBinding()]param([string]$ProjectRoot=".")
$ErrorActionPreference="Stop";$Root=(Resolve-Path $ProjectRoot).Path;$Agy=Join-Path $Root ".agy";$Wi=Get-Content (Join-Path $Agy "WORK_ITEM.json") -Raw|ConvertFrom-Json;$M=Get-Content (Join-Path $Agy "AUDIT_COVERAGE_MATRIX.json") -Raw|ConvertFrom-Json
$Errors=@();if($M.work_item_id-ne$Wi.work_item_id){$Errors+="WORK_ITEM_MISMATCH"};if($M.audit_cycle-eq"initial_comprehensive" -and $M.status-ne"complete"){$Errors+="INITIAL_AUDIT_NOT_COMPLETE"}
$Rows=@($M.acceptance_coverage);for($i=0;$i-lt@($Wi.acceptance).Count;$i++){if(-not(@($Rows.acceptance_index)-contains$i)){$Errors+="ACCEPTANCE_NOT_COVERED:$i"}}
foreach($R in $Rows){if(@($R.surfaces).Count-eq0){$Errors+="SURFACES_EMPTY:$($R.coverage_id)"};if(@($R.evidence_required).Count-eq0){$Errors+="EVIDENCE_EMPTY:$($R.coverage_id)"};if(@($R.checks).Count-eq0){$Errors+="CHECKS_EMPTY:$($R.coverage_id)"}}
if($Errors.Count){$Errors|ForEach-Object{Write-Host "- $_"};exit 1};Write-Host "Audit coverage matrix valid.";exit 0
