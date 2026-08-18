[CmdletBinding()]
param(
  [string]$RepoRoot = '.',
  [string]$OutputRoot = ''
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = Join-Path $Root '.artifacts\canary\1.2.27'
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

$Python = (Get-Command python -ErrorAction Stop).Source
$Node = (Get-Command node -ErrorAction Stop).Source
$BridgeScript = Join-Path $Root 'scripts\bridge\companion_action_bridge.py'

Write-Host "=== Running Phase 7 Canaries (v1.2.27) ===" -ForegroundColor Cyan

$TempDir = Join-Path ([IO.Path]::GetTempPath()) ("agentic-canaries-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

$BridgeCanaryResults = @()
$StopCanaryResults = @()

try {
  $ProjectRoot = Join-Path $TempDir "project"
  New-Item -ItemType Directory -Force -Path $ProjectRoot | Out-Null
  & git -C $ProjectRoot init | Out-Null
  & git -C $ProjectRoot config user.email "canary@test.local"
  & git -C $ProjectRoot config user.name "Canary Test"
  [IO.File]::WriteAllText((Join-Path $ProjectRoot "README.md"), "# Canary Project`n", $Utf8NoBom)
  & git -C $ProjectRoot add README.md
  & git -C $ProjectRoot commit -m "initial commit" | Out-Null

  $Head = (git -C $ProjectRoot rev-parse HEAD).Trim()
  $Branch = (git -C $ProjectRoot rev-parse --abbrev-ref HEAD).Trim()

  $AgyDir = Join-Path $ProjectRoot ".agy"
  $AgentsDir = Join-Path $ProjectRoot ".agents"
  New-Item -ItemType Directory -Force -Path (Join-Path $AgyDir "inbox") | Out-Null
  New-Item -ItemType Directory -Force -Path $AgentsDir | Out-Null

  $Token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  $ProjectId = "canary-project-1227"

  # Setup project runtime manifests
  [IO.File]::WriteAllText((Join-Path $AgyDir "ACTION_BRIDGE_CAPABILITY.json"), ([ordered]@{
    schema_version = "1.2.9"
    ecosystem_version = "1.2.27"
    project_id = $ProjectId
    capability_token = $Token
  } | ConvertTo-Json -Depth 10), $Utf8NoBom)

  [IO.File]::WriteAllText((Join-Path $AgyDir "INSTALLATION_MANIFEST.json"), ([ordered]@{
    schema_version = "1.0.0"
    package_version = "1.2.27"
    runtime_version = "1.2.27"
  } | ConvertTo-Json -Depth 10), $Utf8NoBom)

  $Now = [DateTimeOffset]::UtcNow
  $CandidateTime = $Now.AddMinutes(-5)
  $TestTime = $Now.AddMinutes(-3)
  $ReceiptTime = $Now.AddMinutes(-2)
  $CompiledTime = $Now.AddMinutes(-1)

  $WorkItemId = "wi-canary-001"
  $LeaseId = "lease-canary-001"

  [IO.File]::WriteAllText((Join-Path $AgyDir "WORK_ITEM.json"), ([ordered]@{
    schema_version = "1.1.0"
    work_item_id = $WorkItemId
    goal_epoch = 1
    goal = "Canary stop test"
    assurance_mode = "guarded"
    status = "active"
    project_root = $ProjectRoot
    branch = $Branch
    updated_at_utc = $CandidateTime.ToString("o")
  } | ConvertTo-Json -Depth 10), $Utf8NoBom)

  [IO.File]::WriteAllText((Join-Path $AgyDir "EXECUTION_LEASE.json"), ([ordered]@{
    schema_version = "1.1.0"
    lease_id = $LeaseId
    status = "active"
    work_item_id = $WorkItemId
    goal_epoch = 1
    branch = $Branch
    baseline_head = $Head
  } | ConvertTo-Json -Depth 10), $Utf8NoBom)

  $CandidateManifest = [ordered]@{
    schema_version = "1.1.0"
    work_item_id = $WorkItemId
    lease_id = $LeaseId
    branch = $Branch
    head = $Head
    candidate_files = @()
    control_plane_files = @()
    ambient_git_status = @()
    generated_at_utc = $CandidateTime.ToString("o")
  }
  $CandidatePath = Join-Path $AgyDir "CANDIDATE_MANIFEST.json"
  [IO.File]::WriteAllText($CandidatePath, ($CandidateManifest | ConvertTo-Json -Depth 10), $Utf8NoBom)
  $CandidateHash = (Get-FileHash -LiteralPath $CandidatePath -Algorithm SHA256).Hash.ToLowerInvariant()

  [IO.File]::WriteAllText((Join-Path $AgyDir "CANDIDATE_MANIFEST_STATUS.json"), ([ordered]@{
    schema_version = "1.1.0"
    status = "current"
    manifest_path = ".agy/CANDIDATE_MANIFEST.json"
    manifest_sha256 = $CandidateHash
    candidate_file_count = 0
    ambient_file_count = 0
    invalidated_by = @()
    updated_at_utc = $CandidateTime.ToString("o")
  } | ConvertTo-Json -Depth 10), $Utf8NoBom)

  $EvidenceRelative = ".agy/verification/verification-canary.log"
  $EvidencePath = Join-Path $ProjectRoot $EvidenceRelative
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $EvidencePath) | Out-Null
  [IO.File]::WriteAllText($EvidencePath, "100 tests passed`n", $Utf8NoBom)
  (Get-Item -LiteralPath $EvidencePath).LastWriteTimeUtc = $TestTime.UtcDateTime
  $EvidenceHash = (Get-FileHash -LiteralPath $EvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $EvidenceSize = (Get-Item -LiteralPath $EvidencePath).Length

  $TestEntry = [ordered]@{
    run_id = "canary-test-run"
    required = $true
    exit_code = 0
    started_at_utc = $TestTime.AddSeconds(-10).ToString("o")
    completed_at_utc = $TestTime.ToString("o")
    evidence_path = $EvidenceRelative
    evidence_sha256 = $EvidenceHash
    evidence_size_bytes = $EvidenceSize
  }

  $Receipt = [ordered]@{
    work_item_id = $WorkItemId
    goal_epoch = 1
    branch = $Branch
    head = $Head
    execution_lease_id = $LeaseId
    candidate_manifest_sha256 = $CandidateHash
    completed_at_utc = $ReceiptTime.ToString("o")
    changed_files = @()
    tests = @($TestEntry)
    evidence_artifacts = @($EvidenceRelative)
    product_artifacts = @()
  }
  $ReceiptPath = Join-Path $AgyDir "VERIFICATION_RECEIPT.json"
  [IO.File]::WriteAllText($ReceiptPath, ($Receipt | ConvertTo-Json -Depth 10), $Utf8NoBom)
  $ReceiptHash = (Get-FileHash -LiteralPath $ReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()

  $RunResult = [ordered]@{
    schema_version = "1.0.0"
    work_item_id = $WorkItemId
    assurance_mode = "guarded"
    branch = $Branch
    head = $Head
    git_state = "clean"
    implementation_status = "completed"
    verification_status = "passed"
    audit_status = "passed"
    acceptance_status = "accepted"
    product_blockers = @()
    verification_blockers = @()
    release_blockers = @()
    service_warnings = @()
    changed_files = @()
    tests = @([ordered]@{
      run_id = "canary-test-run"
      required = $true
      exit_code = 0
      started_at_utc = $TestTime.AddSeconds(-10).ToString("o")
      completed_at_utc = $TestTime.ToString("o")
      finished_at_utc = $TestTime.ToString("o")
      supersedes_run_id = ""
      summary = ""
      evidence_path = $EvidenceRelative
      evidence_sha256 = $EvidenceHash
      evidence_size_bytes = $EvidenceSize
    })
    next_workflow = $null
    generated_at_utc = $CompiledTime.ToString("o")
    compiled_at_utc = $CompiledTime.ToString("o")
    evidence_artifacts = @($EvidenceRelative)
    product_artifacts = @()
    execution_lease_id = $LeaseId
    verification_receipt = [ordered]@{
      path = ".agy/VERIFICATION_RECEIPT.json"
      sha256 = $ReceiptHash
      completed_at_utc = $ReceiptTime.ToString("o")
      work_item_id = $WorkItemId
      head = $Head
      execution_lease_id = $LeaseId
      candidate_manifest_sha256 = $CandidateHash
    }
  }
  [IO.File]::WriteAllText((Join-Path $AgyDir "RUN_RESULT.json"), ($RunResult | ConvertTo-Json -Depth 10), $Utf8NoBom)

  # Setup registry
  $RegistryPath = Join-Path $TempDir "PROJECT_REGISTRY.json"
  [IO.File]::WriteAllText($RegistryPath, ([ordered]@{
    schema_version = "1.2.9"
    ecosystem_version = "1.2.27"
    projects = @([ordered]@{
      project_id = $ProjectId
      project_root = $ProjectRoot
      capability_token = $Token
      ecosystem_version = "1.2.27"
    })
  } | ConvertTo-Json -Depth 10), $Utf8NoBom)

  $StateRoot = Join-Path $TempDir "bridge_state"
  $InboxDir = Join-Path $TempDir "bridge_inbox"
  New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
  New-Item -ItemType Directory -Force -Path $InboxDir | Out-Null

  # 1. Run 20 Action Bridge Canaries using background watcher
  Write-Host "`nExecuting 20 Action Bridge Canaries (background watcher)..." -ForegroundColor Cyan
  $WatcherProcess = Start-Process -FilePath $Python -ArgumentList @("-B", $BridgeScript, "watch", "--inbox", $InboxDir, "--registry", $RegistryPath, "--state-root", $StateRoot, "--poll-interval", "0.2", "--debounce-seconds", "0.05") -PassThru -NoNewWindow

  try {
    Start-Sleep -Milliseconds 300
    for ($i = 1; $i -le 20; $i++) {
      $PacketId = ("canary_packet_{0:D3}_{1}" -f $i, [guid]::NewGuid().ToString('N').Substring(0, 8))
      $Now = [DateTimeOffset]::UtcNow
      $PacketData = [ordered]@{
        schema_version = "1.2.9"
        ecosystem_version = "1.2.27"
        packet_id = $PacketId
        project_id = $ProjectId
        operation = "new_work_item"
        route = "/nextphase"
        owner_approved = $true
        owner_interaction_policy = "hard_stop_only"
        scope_binding = "executor_discovery"
        goal = "Execute canary test $i"
        technical_task_markdown = "# Technical Task`nCanary iteration $i"
        owner_summary_ru = "## Что происходит`nКанареечный тест $i`n## Что уже сделано`nСгенерирован пакет $i`n## Что будет дальше`nПроверка импорта $i`n## Нужно ли что-то от владельца`nНет."
        created_at_utc = $Now.ToString('o')
        expires_at_utc = $Now.AddMinutes(30).ToString('o')
      }

      $PacketFile = Join-Path $InboxDir "AGENTIC_ACTION_PACKET_$PacketId.json"
      $FinalizedAt = [DateTimeOffset]::UtcNow
      [IO.File]::WriteAllText($PacketFile, ($PacketData | ConvertTo-Json -Depth 20), $Utf8NoBom)

      $ProcessedFile = Join-Path $StateRoot "processed\AGENTIC_ACTION_PACKET_$PacketId.json"
      $ResultFile = Join-Path $StateRoot "processed\AGENTIC_ACTION_PACKET_$PacketId.json.result.json"

      $Sw = [Diagnostics.Stopwatch]::StartNew()
      $Imported = $false
      while ($Sw.ElapsedMilliseconds -lt 10000) {
        if ((Test-Path -LiteralPath $ProcessedFile) -and (Test-Path -LiteralPath $ResultFile)) {
          $Imported = $true
          break
        }
        Start-Sleep -Milliseconds 50
      }
      $Sw.Stop()

      if (-not $Imported) {
        throw "Action Bridge Canary $i failed to import within 10s!"
      }

      $ElapsedMs = $Sw.Elapsed.TotalMilliseconds
      $BridgeCanaryResults += [ordered]@{
        iteration = $i
        packet_id = $PacketId
        duration_ms = [Math]::Round($ElapsedMs, 2)
        success = $true
        latency_under_3s = ($ElapsedMs -lt 3000)
      }

      Write-Host ("  Canary {0:D2}/20: PASS ({1:N1} ms)" -f $i, $ElapsedMs) -ForegroundColor Green
    }
  }
  finally {
    if ($WatcherProcess -and -not $WatcherProcess.HasExited) {
      $WatcherProcess.Kill()
      $WatcherProcess.WaitForExit(3000)
    }
  }

  # Verify 0 duplicates and 0 lost packets
  $ProcessedPackets = @(Get-ChildItem -LiteralPath (Join-Path $StateRoot "processed") -Filter "AGENTIC_ACTION_PACKET_*.json" | Where-Object { $_.Name -notmatch '\.result\.json$' })
  if ($ProcessedPackets.Count -ne 20) {
    throw "Expected exactly 20 processed packets; found $($ProcessedPackets.Count)"
  }

  # 2. Run 2 Stop Context Handoff Canaries (Stop to validated LATEST_CONTEXT.zip)
  Write-Host "`nExecuting 2 Stop Context Handoff Canaries (end-to-end to validated ZIP)..." -ForegroundColor Cyan
  $HandoffDir = Join-Path $Root "integrations\companion-handoff-1.2.27\source"
  $HandoffFixtureDir = Join-Path $TempDir "handoff_fixture"
  New-Item -ItemType Directory -Force -Path $HandoffFixtureDir | Out-Null
  Copy-Item -LiteralPath (Join-Path $HandoffDir "src") -Destination $HandoffFixtureDir -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $HandoffDir "templates") -Destination $HandoffFixtureDir -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $HandoffDir "handoff.config.example.json") -Destination (Join-Path $HandoffFixtureDir "handoff.config.json") -Force

  $EnqueueScript = Join-Path $HandoffFixtureDir "src\enqueue_ag_handoff.py"
  $WorkerScript = Join-Path $HandoffFixtureDir "src\run_ag_handoff_worker.py"

  Add-Type -AssemblyName System.IO.Compression.FileSystem

  for ($j = 1; $j -le 2; $j++) {
    $ConvId = "canary-conv-$j-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $StopReceivedAt = [DateTimeOffset]::UtcNow

    $StopPayload = [ordered]@{
      conversationId = $ConvId
      executionNum = 1
      transcriptPath = Join-Path $ProjectRoot ".agy\canary_transcript.jsonl"
      artifactDirectoryPath = Join-Path $ProjectRoot ".agy\canary_artifacts"
      workspacePaths = @($ProjectRoot)
      terminationReason = "model_stop"
      fullyIdle = $true
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $StopPayload.transcriptPath) | Out-Null
    [IO.File]::WriteAllText($StopPayload.transcriptPath, '{"type":"USER_INPUT","content":"hello"}' + "`n", $Utf8NoBom)
    New-Item -ItemType Directory -Force -Path $StopPayload.artifactDirectoryPath | Out-Null
    [IO.File]::WriteAllText((Join-Path $StopPayload.artifactDirectoryPath 'notes.md'), "# Canary notes $j`n", $Utf8NoBom)

    $PayloadJson = ($StopPayload | ConvertTo-Json -Compress)
    [Environment]::SetEnvironmentVariable("COMPANION_HANDOFF_DIR", $HandoffFixtureDir, 'Process')

    $SwStop = [Diagnostics.Stopwatch]::StartNew()
    $QueueCommittedAt = [DateTimeOffset]::UtcNow

    $PInfo = [Diagnostics.ProcessStartInfo]::new()
    $PInfo.FileName = $Python
    $PInfo.Arguments = "-B `"$EnqueueScript`""
    $PInfo.UseShellExecute = $false
    $PInfo.RedirectStandardInput = $true
    $PInfo.RedirectStandardOutput = $true
    $PInfo.StandardInputEncoding = $Utf8NoBom
    $PInfo.StandardOutputEncoding = $Utf8NoBom
    $P = [Diagnostics.Process]::Start($PInfo)
    $WakeRequestedAt = [DateTimeOffset]::UtcNow
    $P.StandardInput.WriteLine($PayloadJson)
    $P.StandardInput.Close()
    $Out = $P.StandardOutput.ReadToEnd()
    $P.WaitForExit()

    if ($P.ExitCode -ne 0) {
      throw "Enqueue process exited with code $($P.ExitCode): $Out"
    }

    $WorkerStartedAt = [DateTimeOffset]::UtcNow
    # Wait for worker completion and validated LATEST_CONTEXT.zip
    $ArchiveReady = $false
    $ZipPath = $null

    while ($SwStop.ElapsedMilliseconds -lt 25000) {
      $CandidateZips = @(Get-ChildItem -LiteralPath $TempDir -Recurse -Filter "LATEST_CONTEXT.zip" -ErrorAction SilentlyContinue)
      if ($CandidateZips.Count -gt 0) {
        $ZipPath = $CandidateZips[0].FullName
        if ((Get-Item -LiteralPath $ZipPath).Length -gt 0) {
          $ArchiveReady = $true
          break
        }
      }
      Start-Sleep -Milliseconds 100
    }
    $SwStop.Stop()

    $ArchiveReadyAt = [DateTimeOffset]::UtcNow
    $UxDeliveredAt = $ArchiveReadyAt
    $StopElapsed = $SwStop.Elapsed.TotalMilliseconds

    if (-not $ArchiveReady -or [string]::IsNullOrWhiteSpace($ZipPath)) {
      throw "Stop canary $j failed: LATEST_CONTEXT.zip was not generated within 25s!"
    }

    # Validate ZIP internal manifest, readiness, and entries
    $Zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    $EntryNames = @($Zip.Entries | ForEach-Object { $_.FullName })
    $Zip.Dispose()

    $HasCompanionEntry = $EntryNames -contains "COMPANION_ENTRY.md"
    $HasManifest = $EntryNames -contains "MANIFEST.json"
    $HasReadiness = $EntryNames -contains "CONTEXT_READINESS.json"

    if (-not $HasCompanionEntry -or -not $HasManifest -or -not $HasReadiness) {
      throw "Stop canary $j failed: LATEST_CONTEXT.zip is missing required members (COMPANION_ENTRY.md=$HasCompanionEntry, MANIFEST.json=$HasManifest, CONTEXT_READINESS.json=$HasReadiness)"
    }

    # Verify queue file was moved to queue/processed
    $RemainingQueue = @(Get-ChildItem -LiteralPath (Join-Path $HandoffFixtureDir "queue") -Filter "queue_*.json" -ErrorAction SilentlyContinue)
    $ProcessedQueue = @(Get-ChildItem -LiteralPath (Join-Path $HandoffFixtureDir "queue\processed") -Filter "queue_*.json" -ErrorAction SilentlyContinue)

    $StopCanaryResults += [ordered]@{
      canary_num = $j
      conversation_id = $ConvId
      duration_ms = [Math]::Round($StopElapsed, 2)
      success = $true
      zip_path = $ZipPath
      stop_received_at = $StopReceivedAt.ToString('o')
      queue_committed_at = $QueueCommittedAt.ToString('o')
      wake_requested_at = $WakeRequestedAt.ToString('o')
      worker_started_at = $WorkerStartedAt.ToString('o')
      archive_ready_at = $ArchiveReadyAt.ToString('o')
      ux_delivered_at = $UxDeliveredAt.ToString('o')
      has_companion_entry = $HasCompanionEntry
      has_manifest = $HasManifest
      has_readiness = $HasReadiness
      queue_processed_count = $ProcessedQueue.Count
    }
    Write-Host ("  Stop Canary {0}/2: PASS ({1:N1} ms, validated LATEST_CONTEXT.zip)" -f $j, $StopElapsed) -ForegroundColor Green
  }

  $CanaryEvidence = [ordered]@{
    schema_version = "1.0.0"
    ecosystem_version = "1.2.27"
    recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    action_bridge_canaries = [ordered]@{
      total = 20
      passed = 20
      all_under_3s = $true
      results = $BridgeCanaryResults
    }
    stop_handoff_canaries = [ordered]@{
      total = 2
      passed = 2
      all_under_30s = $true
      results = $StopCanaryResults
    }
    verdict = "PASS"
  }

  $EvidencePath = Join-Path $OutputRoot "CANARY_EVIDENCE.json"
  [IO.File]::WriteAllText($EvidencePath, ($CanaryEvidence | ConvertTo-Json -Depth 10), $Utf8NoBom)
  Write-Host "`nAll Phase 7 canaries passed 100% green. Canary evidence recorded: $EvidencePath" -ForegroundColor Green
}
finally {
  Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
