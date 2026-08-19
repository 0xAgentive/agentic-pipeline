[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$ProjectRoot = '.',

  [Parameter(Mandatory = $false)]
  [string]$OutputDirectory = "$env:USERPROFILE\Documents\antigravity\companion-packs",

  [string]$EcosystemVersion = '1.2.27',

  [int]$MaxPackageMB = 35,

  [switch]$Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$TargetRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$ProjectName = Split-Path -Leaf $TargetRoot
$ProjectSlug = ($ProjectName -replace '[^A-Za-z0-9_-]+', '_').Trim('_')

Write-Host "=== Generating Companion Context Pack for: $ProjectName ===" -ForegroundColor Cyan
Write-Host "Target Path: $TargetRoot"

# 1. Discover Project Identity & Git
$GitBranch = 'unknown'
$GitHead = 'unknown'
$GitOrigin = 'none'

if (Test-Path (Join-Path $TargetRoot '.git')) {
  try {
    $GitBranch = (git -C $TargetRoot rev-parse --abbrev-ref HEAD 2>$null).Trim()
    $GitHead = (git -C $TargetRoot rev-parse HEAD 2>$null).Trim()
    $GitOrigin = (git -C $TargetRoot remote get-url origin 2>$null).Trim()
  } catch {}
}

# 2. Discover Technology Stack & Dependencies
$StackDescription = @()
$PackageJsonPath = Join-Path $TargetRoot 'package.json'
$PackageJson = $null
if (Test-Path $PackageJsonPath) {
  try {
    $PackageJson = Get-Content -LiteralPath $PackageJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $StackDescription += "Node.js (name: $($PackageJson.name), version: $($PackageJson.version))"
  } catch {}
}

if ((Test-Path (Join-Path $TargetRoot 'requirements.txt')) -or (Test-Path (Join-Path $TargetRoot 'pyproject.toml'))) {
  $StackDescription += "Python 3"
}
if (Test-Path (Join-Path $TargetRoot 'Cargo.toml')) {
  $StackDescription += "Rust / Cargo"
}
if (Test-Path (Join-Path $TargetRoot 'go.mod')) {
  $StackDescription += "Go"
}
if ($StackDescription.Count -eq 0) {
  $StackDescription += "General Multi-Language / Scripting"
}

# 3. Read .agy Control Plane State if present
$AgyDir = Join-Path $TargetRoot '.agy'
$HasAgy = Test-Path $AgyDir
$ActiveWorkItemId = $null
$CurrentPhase = $null
$ProjectId = $ProjectSlug

if ($HasAgy) {
  if (Test-Path (Join-Path $AgyDir 'ACTION_BRIDGE_CAPABILITY.json')) {
    try {
      $Cap = Get-Content -LiteralPath (Join-Path $AgyDir 'ACTION_BRIDGE_CAPABILITY.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($Cap.project_id) { $ProjectId = $Cap.project_id }
    } catch {}
  }
  if (Test-Path (Join-Path $AgyDir 'WORK_ITEM.json')) {
    try {
      $Wi = Get-Content -LiteralPath (Join-Path $AgyDir 'WORK_ITEM.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      $ActiveWorkItemId = $Wi.work_item_id
    } catch {}
  }
  if (Test-Path (Join-Path $AgyDir 'PHASE_STATUS.json')) {
    try {
      $Ps = Get-Content -LiteralPath (Join-Path $AgyDir 'PHASE_STATUS.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      $CurrentPhase = $Ps.current_phase
    } catch {}
  }
}

# 4. Prepare Output Staging Directory
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$PackFolderName = ("{0}_COMPREHENSIVE_COMPANION_PACK" -f ($ProjectSlug.ToUpperInvariant()))
$StagingRoot = Join-Path $OutputDirectory $PackFolderName
$ZipPath = Join-Path $OutputDirectory ("$PackFolderName.zip")

if (Test-Path $StagingRoot) {
  Remove-Item -LiteralPath $StagingRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $StagingRoot | Out-Null

$SourceStaging = Join-Path $StagingRoot ("{0}-source" -f ($ProjectSlug.ToLowerInvariant()))
New-Item -ItemType Directory -Force -Path $SourceStaging | Out-Null

Write-Host "`nFiltering and copying pure architectural files..." -ForegroundColor Cyan

# Pure architectural filter logic
$ExcludedPatterns = @(
  '\\node_modules\\',
  '\\\.venv[^\\]*\\',
  '\\\.python[^\\]*\\',
  '\\data\\',
  '\\\.git\\',
  '\\dist\\',
  '\\build\\',
  '\\out\\',
  '\\coverage\\',
  '\\\.artifacts\\',
  '\\\.pipeline_[^\\]*_backup\\',
  '\\scratch\\',
  '\\\.agy\\checkpoints\\',
  '\\__pycache__\\'
)

$ExcludedExtensions = @('.exe', '.zip', '.tar', '.gz', '.db', '.sqlite', '.pyc', '.mp4', '.avi', '.mov', '.iso')

$AllFiles = Get-ChildItem -Path $TargetRoot -Recurse -File | Where-Object {
  $path = $_.FullName
  $excluded = $false
  foreach ($pat in $ExcludedPatterns) {
    if ($path -match $pat) { $excluded = $true; break }
  }
  if ($excluded) { return $false }
  if ($_.Extension -in $ExcludedExtensions) { return $false }
  if ($_.Name -eq 'package-lock.json' -and $_.Length -gt 150KB) { return $false }
  if ($_.Length -gt 2MB) { return $false }
  return $true
}

$CopiedCount = 0
foreach ($file in $AllFiles) {
  $relPath = $file.FullName.Substring($TargetRoot.Length).TrimStart('\', '/')
  $destFile = Join-Path $SourceStaging $relPath
  $destDir = Split-Path -Parent $destFile
  if (-not (Test-Path $destDir)) {
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
  }
  Copy-Item -LiteralPath $file.FullName -Destination $destFile -Force
  $CopiedCount++
}

Write-Host "Copied $CopiedCount pure architectural files to $SourceStaging" -ForegroundColor Green

# 5. Generate Annotated Codebase Map
Write-Host "`nGenerating codebase map and architecture index..." -ForegroundColor Cyan

$CodebaseMapLines = New-Object System.Collections.Generic.List[string]
$CodebaseMapLines.Add("# Карта кодовой базы: $ProjectName`n")
$CodebaseMapLines.Add("Всего архитектурных файлов в пакете: $CopiedCount`n")
$CodebaseMapLines.Add("## Структура директорий и ключевых модулей`n")

$TopDirs = @(Get-ChildItem -Path $SourceStaging -Directory | Sort-Object Name)
foreach ($td in $TopDirs) {
  $subFiles = @(Get-ChildItem -Path $td.FullName -Recurse -File)
  $CodebaseMapLines.Add("### `/$($td.Name)/` ($($subFiles.Count) файлов)")
  
  $subFiles | Select-Object -First 30 | ForEach-Object {
    $r = $_.FullName.Substring($SourceStaging.Length + 1)
    $lines = @(Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue).Count
    $CodebaseMapLines.Add("- `$r` ($lines строк)")
  }
  if ($subFiles.Count -gt 30) {
    $CodebaseMapLines.Add("- ... и ещё $($subFiles.Count - 30) файлов")
  }
  $CodebaseMapLines.Add("")
}

# Root files
$RootFiles = @(Get-ChildItem -Path $SourceStaging -File | Sort-Object Name)
if ($RootFiles.Count -gt 0) {
  $CodebaseMapLines.Add("### Корневые конфигурации и манифесты")
  foreach ($rf in $RootFiles) {
    $lines = @(Get-Content -LiteralPath $rf.FullName -ErrorAction SilentlyContinue).Count
    $CodebaseMapLines.Add("- `$($rf.Name)` ($lines строк)")
  }
  $CodebaseMapLines.Add("")
}

$CodebaseMapContent = ($CodebaseMapLines -join "`n")
[IO.File]::WriteAllText((Join-Path $StagingRoot '01_CODEBASE_INDEX_AND_ARCHITECTURE_MAP.md'), $CodebaseMapContent, $Utf8NoBom)

# 6. Generate 00_COMPANION_MASTER_GUIDE.md
$ReadMeText = ""
if (Test-Path (Join-Path $TargetRoot 'README.md')) {
  $ReadMeText = Get-Content -LiteralPath (Join-Path $TargetRoot 'README.md') -Raw -Encoding UTF8
}

$GuideLines = @(
  "# $ProjectName — РУКОВОДСТВО АРХИТЕКТОРА ДЛЯ ИИ-КОМПАНЬОНА",
  "",
  "> **Для модели**: В этом пакете находится ПОЛНЫЙ исходный код, тесты, конфигурации, схемы данных и авторитетные манифесты состояния проекта **$ProjectName**. Все тяжеловесные бинарные файлы, дампы и сторонние зависимости (`node_modules`, `venv`) исключены. Вся кодовая база доступна в подкаталоге ``$($ProjectSlug.ToLowerInvariant())-source/``.",
  "",
  "---",
  "",
  "## 1. Паспорт проекта",
  "",
  "| Параметр | Значение |",
  "|---|---|",
  "| **Имя проекта** | $ProjectName |",
  "| **Идентификатор Action Bridge** | `$ProjectId` |",
  "| **Локальный путь** | `$TargetRoot` |",
  "| **Ветка Git** | `$GitBranch` |",
  "| **HEAD commit** | `$GitHead` |",
  "| **Стек технологий** | $($StackDescription -join ', ') |",
  "| **Версия экосистемы** | `$EcosystemVersion` |",
  "| **Текущая фаза / Work Item** | $(if ($CurrentPhase) { $CurrentPhase } else { 'Ready for new work item' }) |",
  "",
  "---",
  "",
  "## 2. Обзор проекта из README",
  "",
  $ReadMeText,
  "",
  "---",
  "",
  "## 3. Правила взаимодействия с локальным агентом Antigravity",
  "",
  "Компаньон формулирует задачи для автономного агента Antigravity в виде **однофайлового JSON Action Packet**:",
  "``AGENTIC_ACTION_PACKET_<project>_<timestamp>.json``",
  "",
  "### Обязательные правила:",
  "1. ``owner_interaction_policy: ""hard_stop_only""`` — агент исполняет план автономно до верификации или реального блокера.",
  "2. ``scope_binding: ""executor_discovery""`` — агент самостоятельно валидирует рабочую ветку и окружение.",
  "3. Отчёт для владельца (``owner_summary_ru``) формируется ровно из 4 секций:",
  "   - ``## Что происходит``",
  "   - ``## Что уже сделано``",
  "   - ``## Что будет дальше``",
  "   - ``## Нужно ли что-то от владельца``",
  "",
  "Примеры готовых валидных пакетов приведены в каталоге ``05_ACTION_PACKET_EXAMPLES/``."
)

[IO.File]::WriteAllText((Join-Path $StagingRoot '00_COMPANION_MASTER_GUIDE.md'), ($GuideLines -join "`n"), $Utf8NoBom)

# 7. Generate 03_COMPANION_SYSTEM_PROMPT.md
$SysPromptLines = @(
  "# Системный промпт для GPT-5 / ChatGPT Companion",
  "",
  "Скопируйте этот текст в диалог с Компаньоном:",
  "",
  '```markdown',
  "Ты — Главный Архитектор и Компаньон проекта $ProjectName ($($StackDescription -join ', ')).",
  "Твоя задача: анализировать кодовую базу, проектировать архитектурные решения, консультировать владельца и формировать для автономного агента Antigravity исполнимые JSON Action Packets по стандарту Agentic Pipeline v$EcosystemVersion.",
  "",
  "Твой рабочий контекст:",
  "- Полный исходный код проекта находится в прикреплённом архиве $PackFolderName.zip (папка $($ProjectSlug.ToLowerInvariant())-source/).",
  "- Идентификатор проекта в Action Bridge: ""$ProjectId"".",
  "- Ветка Git: ""$GitBranch"", HEAD: ""$GitHead"".",
  "- Формат передачи задач агенту: один JSON файл AGENTIC_ACTION_PACKET_<project>_<timestamp>.json со схемой 1.2.9 и ecosystem_version $EcosystemVersion.",
  "- Правила взаимодействия: owner_interaction_policy: ""hard_stop_only"", scope_binding: ""executor_discovery"", отчёт для владельца из 4 разделов (""Что происходит"", ""Что уже сделано"", ""Что будет дальше"", ""Нужно ли что-то от владельца"").",
  '```'
)

[IO.File]::WriteAllText((Join-Path $StagingRoot '03_COMPANION_SYSTEM_PROMPT.md'), ($SysPromptLines -join "`n"), $Utf8NoBom)

# 8. Generate Sample Action Packets
$ActionsDir = Join-Path $StagingRoot '05_ACTION_PACKET_EXAMPLES'
New-Item -ItemType Directory -Force -Path $ActionsDir | Out-Null

$NowUtc = [DateTimeOffset]::UtcNow
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

# Audit packet
$AuditPacket = [ordered]@{
  schema_version = '1.2.9'
  ecosystem_version = $EcosystemVersion
  packet_id = ("packet_{0}_audit_{1}" -f $ProjectSlug.ToLowerInvariant(), $Stamp)
  project_id = $ProjectId
  operation = if ($ActiveWorkItemId) { 'continue_work_item' } else { 'new_work_item' }
  route = '/auditphase'
  goal = ("Выполнить плановый аудит архитектурной целостности и тестов проекта {0}" -f $ProjectName)
  assurance_mode = 'guarded'
  owner_approved = $true
  owner_interaction_policy = 'hard_stop_only'
  scope_binding = 'executor_discovery'
  technical_task_markdown = "# Техническое задание: Аудит кодовой базы $ProjectName`n`n1. Запустить полный цикл модульных и интеграционных тестов.`n2. Проверить целостность контрактов схем и зависимостей.`n3. Провести аудит незакрытых замечаний в FINDINGS.json (если применимо).`n4. Скомпилировать актуальный RUN_RESULT.json с фиксацией результатов.`n"
  owner_summary_ru = "## Что происходит`nЗапуск планового аудита кодовой базы проекта $ProjectName.`n`n## Что уже сделано`nСформирован пакет аудита и проверено соответствие контрактам.`n`n## Что будет дальше`nАгент проверит модули, запустит тесты и обновит отчёт.`n`n## Нужно ли что-то от владельца`nНет, процедура полностью автономна."
  created_at_utc = $NowUtc.ToString('o')
  expires_at_utc = $NowUtc.AddHours(4).ToString('o')
}

if ($ActiveWorkItemId) {
  $AuditPacket['work_item_id'] = $ActiveWorkItemId
  $AuditPacket['goal_epoch'] = 1
}

[IO.File]::WriteAllText((Join-Path $ActionsDir ("AGENTIC_ACTION_PACKET_{0}_AUDIT_SAMPLE.json" -f $ProjectSlug.ToUpperInvariant())), ($AuditPacket | ConvertTo-Json -Depth 20), $Utf8NoBom)

# Next phase packet
$NextPhasePacket = [ordered]@{
  schema_version = '1.2.9'
  ecosystem_version = $EcosystemVersion
  packet_id = ("packet_{0}_nextphase_{1}" -f $ProjectSlug.ToLowerInvariant(), $Stamp)
  project_id = $ProjectId
  operation = 'new_work_item'
  route = '/nextphase'
  goal = ("Разработка и реализация следующей фазы для проекта {0}" -f $ProjectName)
  assurance_mode = 'guarded'
  owner_approved = $true
  owner_interaction_policy = 'hard_stop_only'
  scope_binding = 'executor_discovery'
  technical_task_markdown = "# Техническое задание: Следующая фаза для $ProjectName`n`n1. Изучить текущие архитектурные требования и интерфейсы.`n2. Реализовать запланированную функциональность с сохранением обратной совместимости.`n3. Добавить регрессионные и интеграционные тесты.`n4. Проверить сборку и подтвердить работоспособность.`n"
  owner_summary_ru = "## Что происходит`nИнициализация новой фазы разработки проекта $ProjectName.`n`n## Что уже сделано`nСформировано техническое задание и определены границы скоупа.`n`n## Что будет дальше`nАгент приступит к реализации модулей и автоматической верификации.`n`n## Нужно ли что-то от владельца`nНет."
  created_at_utc = $NowUtc.ToString('o')
  expires_at_utc = $NowUtc.AddHours(4).ToString('o')
}

[IO.File]::WriteAllText((Join-Path $ActionsDir ("AGENTIC_ACTION_PACKET_{0}_NEW_PHASE_SAMPLE.json" -f $ProjectSlug.ToUpperInvariant())), ($NextPhasePacket | ConvertTo-Json -Depth 20), $Utf8NoBom)

# 9. Compress to ZIP
Write-Host "`nCompressing to self-contained ZIP archive..." -ForegroundColor Cyan

if (Test-Path $ZipPath) {
  Remove-Item -LiteralPath $ZipPath -Force
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($StagingRoot, $ZipPath, [IO.Compression.CompressionLevel]::Optimal, $false)

$ZipSize = (Get-Item -LiteralPath $ZipPath).Length
$ZipSizeMB = [Math]::Round($ZipSize / 1MB, 2)

if ($ZipSizeMB -gt $MaxPackageMB) {
  Write-Warning "ZIP size ($ZipSizeMB MB) exceeds target threshold ($MaxPackageMB MB)!"
}

Write-Host "`n[SUCCESS] Companion Project Context Pack generated:" -ForegroundColor Green
Write-Host "Directory:  $StagingRoot"
Write-Host "Archive:    $ZipPath ($ZipSizeMB MB, $ZipSize bytes)"
Write-Host "Files count: $CopiedCount source files + docs & schemas"

try {
  Set-Clipboard -Value $ZipPath
  Write-Host "Clipboard:  Archive path copied to clipboard successfully!" -ForegroundColor Yellow
} catch {
  Write-Warning "Could not copy archive path to clipboard: $($_.Exception.Message)"
}

return [pscustomobject]@{
  ProjectName = $ProjectName
  ProjectId = $ProjectId
  Directory = $StagingRoot
  ArchivePath = $ZipPath
  SizeBytes = $ZipSize
  FilesCount = $CopiedCount
}
