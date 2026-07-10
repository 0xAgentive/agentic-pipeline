param(
  [string]$RepoRoot = "."
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$Errors = New-Object System.Collections.Generic.List[string]

$ReservedAutomaticVariables = @(
  "args",
  "input",
  "error",
  "matches",
  "host",
  "pid",
  "pwd",
  "psboundparameters",
  "lastexitcode",
  "this",
  "switch"
)

function Add-Error {
  param([string]$Message)
  [void]$Errors.Add($Message)
}

$Files = Get-ChildItem -LiteralPath $Root -Recurse -Force -File -Filter "*.ps1" |
  Where-Object {
    $_.FullName -notmatch "\\.git\\|\\.pipeline_patch_backup\\|\\.artifacts\\|\\docs\\archive\\"
  }

foreach ($File in $Files) {
  $Tokens = $null
  $ParseErrors = $null
  $Ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $File.FullName,
    [ref]$Tokens,
    [ref]$ParseErrors
  )

  foreach ($ParseError in @($ParseErrors)) {
    Add-Error ("PowerShell parse error: {0}:{1}:{2} {3}" -f
      $File.FullName,
      $ParseError.Extent.StartLineNumber,
      $ParseError.Extent.StartColumnNumber,
      $ParseError.Message)
  }

  $ParameterAsts = $Ast.FindAll({
    param($Node)
    $Node -is [System.Management.Automation.Language.ParameterAst]
  }, $true)

  foreach ($ParameterAst in $ParameterAsts) {
    $Name = $ParameterAst.Name.VariablePath.UserPath.ToLowerInvariant()
    if ($ReservedAutomaticVariables -contains $Name) {
      Add-Error ("Automatic variable used as a parameter name: {0}:{1} `${2}" -f
        $File.FullName,
        $ParameterAst.Extent.StartLineNumber,
        $Name)
    }
  }

  $AssignmentAsts = $Ast.FindAll({
    param($Node)
    $Node -is [System.Management.Automation.Language.AssignmentStatementAst]
  }, $true)

  foreach ($AssignmentAst in $AssignmentAsts) {
    if ($AssignmentAst.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
      $Name = $AssignmentAst.Left.VariablePath.UserPath.ToLowerInvariant()
      if ($ReservedAutomaticVariables -contains $Name) {
        Add-Error ("Automatic variable is assigned: {0}:{1} `${2}" -f
          $File.FullName,
          $AssignmentAst.Extent.StartLineNumber,
          $Name)
      }
    }
  }

  $SplattedAutomaticAsts = $Ast.FindAll({
    param($Node)
    $Node -is [System.Management.Automation.Language.VariableExpressionAst] -and
      $Node.Splatted -and
      $Node.VariablePath.UserPath -ieq "args"
  }, $true)

  foreach ($VariableAst in $SplattedAutomaticAsts) {
    Add-Error ("Automatic `$args is used for splatting: {0}:{1}" -f
      $File.FullName,
      $VariableAst.Extent.StartLineNumber)
  }

  $SourceText = [System.IO.File]::ReadAllText($File.FullName, [System.Text.Encoding]::UTF8)
  $GenericListVariables = @()

  foreach ($Match in [regex]::Matches(
    $SourceText,
    '(?im)^\s*\$(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*New-Object\s+System\.Collections\.Generic\.List\[[^\]]+\]'
  )) {
    $GenericListVariables += $Match.Groups['name'].Value
  }

  foreach ($VariableName in ($GenericListVariables | Sort-Object -Unique)) {
    $UnsafePattern = '@\(\s*\$' + [regex]::Escape($VariableName) + '\s*\)'
    foreach ($Match in [regex]::Matches($SourceText, $UnsafePattern)) {
      $LineNumber = 1 + ([regex]::Matches($SourceText.Substring(0, $Match.Index), "`n")).Count
      Add-Error ("Generic List is wrapped in @(), which can fail with 'Argument types do not match'; use .ToArray(): {0}:{1} `${2}" -f
        $File.FullName,
        $LineNumber,
        $VariableName)
    }
  }

  # A zero-byte file may yield $null from Get-Content -Raw in Windows PowerShell 5.1.
  # Calling Trim()/Length/Count directly on that expression is therefore unsafe.
  $NullUnsafeRawPattern = '(?im)\(\s*Get-Content[^\r\n]*-Raw[^\r\n]*\)\s*\.\s*(Trim|Length|Count)\b'
  foreach ($Match in [regex]::Matches($SourceText, $NullUnsafeRawPattern)) {
    $LineNumber = 1 + ([regex]::Matches($SourceText.Substring(0, $Match.Index), "`n")).Count
    Add-Error ("Null-unsafe method/property access on Get-Content -Raw; use [System.IO.File]::ReadAllText or a null guard: {0}:{1}" -f
      $File.FullName,
      $LineNumber)
  }
}

if ($Errors.Count -gt 0) {
  Write-Host "PowerShell runtime-contract validation failed:"
  $Errors | Sort-Object -Unique | ForEach-Object { Write-Host "- $_" }
  exit 1
}

Write-Host "PowerShell runtime-contract validation passed. Files: $($Files.Count)"
exit 0
