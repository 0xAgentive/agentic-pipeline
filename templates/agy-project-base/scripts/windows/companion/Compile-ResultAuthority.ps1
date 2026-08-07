[CmdletBinding()]
param(
  [string]$ProjectRoot='.',
  [Parameter(Mandatory=$true)][string]$VerificationReceiptPath,
  [string]$AuditResultPath='',
  [switch]$Apply
)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$Root=(Resolve-Path -LiteralPath $ProjectRoot).Path
$Agy=Join-Path $Root '.agy'
$WorkItem=Get-Content -LiteralPath (Join-Path $Agy 'WORK_ITEM.json') -Raw -Encoding UTF8|ConvertFrom-Json
$Verification=Get-Content -LiteralPath (Resolve-Path -LiteralPath $VerificationReceiptPath).Path -Raw -Encoding UTF8|ConvertFrom-Json
$Findings=@();$FindingPath=Join-Path $Agy 'FINDINGS.json'
if(Test-Path -LiteralPath $FindingPath -PathType Leaf){
  & (Join-Path $Root 'scripts\windows\companion\Test-FindingSet.ps1') -ProjectRoot $Root -FindingSetPath $FindingPath|Out-Null
  if($LASTEXITCODE-ne0){throw 'Finding set validation failed.'}
  $Findings=@((Get-Content -LiteralPath $FindingPath -Raw -Encoding UTF8|ConvertFrom-Json).findings)
}
$ProgressPath=Join-Path $Agy 'PROGRESS_STATE.json'
$Progress=if(Test-Path -LiteralPath $ProgressPath -PathType Leaf){Get-Content -LiteralPath $ProgressPath -Raw -Encoding UTF8|ConvertFrom-Json}else{[pscustomobject]@{status='active';observations_count=0;consecutive_no_progress=0;same_failure_count=0;owner_decision_required=$false}}
$AttestationPath=Join-Path $Agy 'REVIEWER_ATTESTATION.json'
$Attestation=if(Test-Path -LiteralPath $AttestationPath -PathType Leaf){Get-Content -LiteralPath $AttestationPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
$Audit=if($AuditResultPath){Get-Content -LiteralPath (Resolve-Path -LiteralPath $AuditResultPath).Path -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
$Open=@($Findings|Where-Object{$_.lifecycle_status-eq'open_confirmed'})
$Product=@($Open|Where-Object{$_.materiality-eq'product_blocker'})
$VerificationBlockers=@($Open|Where-Object{$_.materiality-eq'verification_blocker'})
$ReleaseBlockers=@($Open|Where-Object{$_.materiality-eq'release_blocker'})
$OwnerDecisions=@($Open|Where-Object{$_.owner_decision_required-eq$true})
$RequiredTests=@($Verification.tests|Where-Object{$_.required-ne$false})
$VerificationPassed=($RequiredTests.Count-gt0-and@($RequiredTests|Where-Object{[int]$_.exit_code-ne0}).Count-eq0)
$Mode=[string]$WorkItem.assurance_mode
$Independent=($Attestation-and[string]$Attestation.independence_status-eq'independent')
$AuditPassed=($Audit-and[string]$Audit.status-eq'passed'-and$Independent)
$Stalled=([string]$Progress.status-eq'stalled'-or[int]$Progress.consecutive_no_progress-ge2-or[int]$Progress.same_failure_count-ge2)
$OwnerDecisionRequired=($OwnerDecisions.Count-gt0-or$Progress.owner_decision_required-eq$true)
$ChangedFiles=@($Verification.changed_files)
$CandidateRequired=$ChangedFiles.Count-gt0
$CandidateCurrent=$true
if($CandidateRequired){
  $StatusPath=Join-Path $Agy 'CANDIDATE_MANIFEST_STATUS.json';$ManifestPath=Join-Path $Agy 'CANDIDATE_MANIFEST.json'
  $CandidateCurrent=$false
  if((Test-Path -LiteralPath $StatusPath -PathType Leaf)-and(Test-Path -LiteralPath $ManifestPath -PathType Leaf)){
    $Status=Get-Content -LiteralPath $StatusPath -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$Status.status-eq'current'){
      $Actual=(Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
      $CandidateCurrent=([string]$Status.manifest_sha256-eq$Actual)
    }
  }
}
$NextWorkflow=$null;$HardStop=$false
if($OwnerDecisionRequired){$Acceptance='blocked';$Implementation='blocked';$VerificationStatus='blocked';$AuditStatus=if($Mode-eq'flow'){'not_required'}else{'blocked'};$Reason='true_owner_decision_required';$HardStop=$true}
elseif($Product.Count-gt0-and-not$Stalled){$Acceptance='not_evaluated';$Implementation='in_progress';$VerificationStatus=if($VerificationPassed){'partial'}else{'not_run'};$AuditStatus=if($Mode-eq'flow'){'not_required'}else{'pending'};$Reason='repair_continues_automatically';$NextWorkflow='/fixcritical'}
elseif($Product.Count-gt0){$Acceptance='blocked';$Implementation='blocked';$VerificationStatus=if($VerificationPassed){'partial'}else{'failed'};$AuditStatus=if($Mode-eq'flow'){'not_required'}else{'blocked'};$Reason='repeated_no_progress';$HardStop=$true}
elseif(-not$VerificationPassed-or-not$CandidateCurrent){$Acceptance='not_evaluated';$Implementation='completed';$VerificationStatus='blocked';$AuditStatus=if($Mode-eq'flow'){'not_required'}else{'pending'};$Reason=if(-not$CandidateCurrent){'candidate_identity_not_current'}else{'verification_continues_automatically'};$NextWorkflow='/auditphase'}
elseif($Mode-ne'flow'-and-not$AuditPassed){$Acceptance='completed_with_verification_debt';$Implementation='completed';$VerificationStatus='partial';$AuditStatus='blocked';$Reason='protected_review_unavailable'}
elseif($VerificationBlockers.Count-gt0-or$ReleaseBlockers.Count-gt0){$Acceptance='completed_with_verification_debt';$Implementation='completed';$VerificationStatus='partial';$AuditStatus=if($Mode-eq'flow'){'not_required'}else{'passed'};$Reason='verification_or_release_debt'}
else{$Acceptance='accepted';$Implementation='completed';$VerificationStatus='passed';$AuditStatus=if($Mode-eq'flow'){'not_required'}else{'passed'};$Reason='all_material_gates_passed'}
$Branch=(@(& git -C $Root branch --show-current 2>&1)-join"`n").Trim();$Head=(@(& git -C $Root rev-parse HEAD 2>&1)-join"`n").Trim();$GitStatus=@(& git -C $Root status --porcelain=v1 --untracked-files=all 2>&1);if($LASTEXITCODE-ne0){throw 'Git state unavailable.'}
$Now=(Get-Date).ToUniversalTime().ToString('o')
$Closure=[ordered]@{schema_version='1.0.0';work_item_id=[string]$WorkItem.work_item_id;implementation_status=$Implementation;verification_status=$VerificationStatus;audit_status=$AuditStatus;acceptance_status=$Acceptance;release_status=if($Acceptance-eq'accepted'-and$Mode-eq'release'){'open'}elseif($Mode-eq'release'-or$Acceptance-eq'completed_with_verification_debt'-or$HardStop){'blocked'}else{'not_applicable'};next_owner_goal_allowed=($Acceptance-in@('accepted','completed_with_verification_debt'));closure_reason=$Reason;open_finding_ids=@($Open.finding_id);generated_at_utc=$Now}
function Convert-Blocker($Finding){[ordered]@{code=([string]$Finding.finding_id).ToUpperInvariant().Replace('-','_');message=[string]$Finding.title;category=[string]$Finding.category;auto_repairable=[bool]$Finding.auto_repairable}}
$ObservationCount=0;if($Progress.PSObject.Properties['observations_count']){$ObservationCount=[int]$Progress.observations_count}
$Run=[ordered]@{schema_version='1.0.0';work_item_id=[string]$WorkItem.work_item_id;assurance_mode=$Mode;branch=$Branch;head=$Head;git_state=if($GitStatus.Count){'dirty'}else{'clean'};implementation_status=$Implementation;verification_status=$VerificationStatus;audit_status=$AuditStatus;acceptance_status=$Acceptance;product_blockers=@($Product|ForEach-Object{Convert-Blocker $_});verification_blockers=@($VerificationBlockers|ForEach-Object{Convert-Blocker $_});release_blockers=@($ReleaseBlockers|ForEach-Object{Convert-Blocker $_});service_warnings=@();changed_files=$ChangedFiles;tests=@($Verification.tests);next_workflow=$NextWorkflow;no_progress=$Stalled;hard_stop=$HardStop;generated_at_utc=$Now;evidence_artifacts=@($Verification.evidence_artifacts);product_artifacts=@($Verification.product_artifacts);execution_lease_id=if(Test-Path -LiteralPath (Join-Path $Agy 'EXECUTION_LEASE.json')){[string](Get-Content -LiteralPath (Join-Path $Agy 'EXECUTION_LEASE.json') -Raw -Encoding UTF8|ConvertFrom-Json).lease_id}else{$null};audit_coverage_status=if(Test-Path -LiteralPath (Join-Path $Agy 'AUDIT_COVERAGE_MATRIX.json')){[string](Get-Content -LiteralPath (Join-Path $Agy 'AUDIT_COVERAGE_MATRIX.json') -Raw -Encoding UTF8|ConvertFrom-Json).status}else{'not_required'};reviewer_independence_status=if($Mode-eq'flow'){'not_required'}elseif($Attestation){[string]$Attestation.independence_status}else{'unavailable'};progress_observations=$ObservationCount;progress_status=[string]$Progress.status;consecutive_no_progress=[int]$Progress.consecutive_no_progress;same_failure_count=[int]$Progress.same_failure_count;closure_state_path='.agy/CLOSURE_STATE.json'}
if($Apply){$Utf8=[Text.UTF8Encoding]::new($false);[IO.File]::WriteAllText((Join-Path $Agy 'CLOSURE_STATE.json'),($Closure|ConvertTo-Json -Depth 40),$Utf8);[IO.File]::WriteAllText((Join-Path $Agy 'RUN_RESULT.json'),($Run|ConvertTo-Json -Depth 50),$Utf8);$DecisionReason=if($OwnerDecisionRequired){$Reason}else{''};& (Join-Path $Root 'scripts\windows\companion\Publish-NextAction.ps1') -ProjectRoot $Root -Route $NextWorkflow -OwnerDecisionRequired:$OwnerDecisionRequired -OwnerDecisionReason $DecisionReason -Apply;Write-Host "Compiled result authority: $Acceptance"}else{[ordered]@{closure=$Closure;run_result=$Run}|ConvertTo-Json -Depth 60}
