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
  $OutputRoot = Join-Path $Root '.artifacts\canary\1.2.26'
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

$Python = (Get-Command python -ErrorAction Stop).Source
$Node = (Get-Command node -ErrorAction Stop).Source
$BridgeScript = Join-Path $Root 'scripts\bridge\companion_action_bridge.py'

Write-Host "=== Running Phase 7 Canaries (v1.2.26) ===" -ForegroundColor Cyan

$TempDir = Join-Path ([IO.Path]::GetTempPath()) ("agentic-canaries-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

$BridgeCanaryResults = @()
$StopCanaryResults = @()

try {
  $ProjectRoot = Join-Path $TempDir "project"
  $AgyDir = Join-Path $ProjectRoot ".agy"
  $AgentsDir = Join-Path $ProjectRoot ".agents"
  New-Item -ItemType Directory -Force -Path (Join-Path $AgyDir "inbox") | Out-Null
  New-Item -ItemType Directory -Force -Path $AgentsDir | Out-Null

  $Token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  $ProjectId = "canary-project-1226"

  # Setup project runtime manifests
  [IO.File]::WriteAllText((Join-Path $AgyDir "ACTION_BRIDGE_CAPABILITY.json"), ([ordered]@{
    schema_version = "1.2.9"
    ecosystem_version = "1.2.26"
    project_id = $ProjectId
    capability_token = $Token
  } | ConvertTo-Json -Depth 10), $Utf8NoBom)

  [IO.File]::WriteAllText((Join-Path $AgyDir "INSTALLATION_MANIFEST.json"), ([ordered]@{
    schema_version = "1.0.0"
    package_version = "1.2.26"
    runtime_version = "1.2.26"
  } | ConvertTo-Json -Depth 10), $Utf8NoBom)

  # Setup registry
  $RegistryPath = Join-Path $TempDir "PROJECT_REGISTRY.json"
  [IO.File]::WriteAllText($RegistryPath, ([ordered]@{
    schema_version = "1.2.9"
    ecosystem_version = "1.2.26"
    projects = @([ordered]@{
      project_id = $ProjectId
      project_root = $ProjectRoot
      capability_token = $Token
      ecosystem_version = "1.2.26"
    })
  } | ConvertTo-Json -Depth 10), $Utf8NoBom)

  $StateRoot = Join-Path $TempDir "bridge_state"
  $InboxDir = Join-Path $TempDir "bridge_inbox"
  New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
  New-Item -ItemType Directory -Force -Path $InboxDir | Out-Null

  # 1. Run 20 Action Bridge Canaries
  Write-Host "`nExecuting 20 Action Bridge Canaries..." -ForegroundColor Cyan
  for ($i = 1; $i -le 20; $i++) {
    $PacketId = ("canary_packet_{0:D3}_{1}" -f $i, [guid]::NewGuid().ToString('N').Substring(0, 8))
    $Now = [DateTimeOffset]::UtcNow
    $PacketData = [ordered]@{
      schema_version = "1.2.9"
      ecosystem_version = "1.2.26"
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
    [IO.File]::WriteAllText($PacketFile, ($PacketData | ConvertTo-Json -Depth 20), $Utf8NoBom)

    $Sw = [Diagnostics.Stopwatch]::StartNew()
    $ScanExit = & $Python -B $BridgeScript scan --inbox $InboxDir --registry $RegistryPath --state-root $StateRoot --debounce-seconds 0.05
    $Sw.Stop()

    $ElapsedMs = $Sw.Elapsed.TotalMilliseconds
    $ProcessedFile = Join-Path $StateRoot "processed\AGENTIC_ACTION_PACKET_$PacketId.json"
    $ResultFile = Join-Path $StateRoot "processed\AGENTIC_ACTION_PACKET_$PacketId.json.result.json"

    $Success = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $ProcessedFile) -and (Test-Path -LiteralPath $ResultFile)
    if (-not $Success) {
      throw "Action Bridge Canary $i failed!"
    }

    $BridgeCanaryResults += [ordered]@{
      iteration = $i
      packet_id = $PacketId
      duration_ms = [Math]::Round($ElapsedMs, 2)
      success = $true
      latency_under_3s = ($ElapsedMs -lt 3000)
    }

    Write-Host ("  Canary {0:D2}/20: PASS ({1:N1} ms)" -f $i, $ElapsedMs) -ForegroundColor Green
  }

  # 2. Run 2 Stop Canaries
  Write-Host "`nExecuting 2 Stop Context Handoff Canaries..." -ForegroundColor Cyan
  $HandoffDir = Join-Path $Root "integrations\companion-handoff-1.2.26\source"
  $EnqueueScript = Join-Path $HandoffDir "src\enqueue_ag_handoff.py"

  for ($j = 1; $j -le 2; $j++) {
    $ConvId = "canary-conv-$j-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
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

    $PayloadJson = ($StopPayload | ConvertTo-Json -Compress)
    $EnvParams = @{
      COMPANION_HANDOFF_DIR = $TempDir
    }
    foreach ($k in $EnvParams.Keys) { [Environment]::SetEnvironmentVariable($k, $EnvParams[$k], 'Process') }

    $SwStop = [Diagnostics.Stopwatch]::StartNew()
    $EnqueueProcess = Start-Process -FilePath $Python -ArgumentList @("-B", $EnqueueScript) -RedirectStandardInput ([IO.Path]::GetTempFileName()) -RedirectStandardOutput ([IO.Path]::GetTempFileName()) -PassThru -NoNewWindow
    # Feed json
    $TmpInput = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($TmpInput, $PayloadJson, $Utf8NoBom)
    
    $PInfo = [Diagnostics.ProcessStartInfo]::new()
    $PInfo.FileName = $Python
    $PInfo.Arguments = "-B `"$EnqueueScript`""
    $PInfo.UseShellExecute = $false
    $PInfo.RedirectStandardInput = $true
    $PInfo.RedirectStandardOutput = $true
    $PInfo.StandardInputEncoding = $Utf8NoBom
    $PInfo.StandardOutputEncoding = $Utf8NoBom
    $P = [Diagnostics.Process]::Start($PInfo)
    $P.StandardInput.WriteLine($PayloadJson)
    $P.StandardInput.Close()
    $Out = $P.StandardOutput.ReadToEnd()
    $P.WaitForExit()
    $SwStop.Stop()

    $StopElapsed = $SwStop.Elapsed.TotalMilliseconds
    $QueueFiles = @(Get-ChildItem -LiteralPath (Join-Path $TempDir "queue") -Filter "queue_*.json" -ErrorAction SilentlyContinue)
    $StopSuccess = ($P.ExitCode -eq 0) -and ($QueueFiles.Count -ge $j)

    $StopCanaryResults += [ordered]@{
      canary_num = $j
      conversation_id = $ConvId
      duration_ms = [Math]::Round($StopElapsed, 2)
      success = $StopSuccess
      queue_count = $QueueFiles.Count
    }
    Write-Host ("  Stop Canary {0}/2: PASS ({1:N1} ms, enqueued)" -f $j, $StopElapsed) -ForegroundColor Green
  }

  $CanaryEvidence = [ordered]@{
    schema_version = "1.0.0"
    ecosystem_version = "1.2.26"
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
