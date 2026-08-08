Set-StrictMode -Version 3.0

function Invoke-AgenticNativeProcess {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [string]$WorkingDirectory = ''
  )

  $StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $StartInfo.FileName = $FilePath
  $StartInfo.UseShellExecute = $false
  $StartInfo.CreateNoWindow = $true
  $StartInfo.RedirectStandardOutput = $true
  $StartInfo.RedirectStandardError = $true
  $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  $StartInfo.StandardOutputEncoding = $Utf8NoBom
  $StartInfo.StandardErrorEncoding = $Utf8NoBom
  if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
    $StartInfo.WorkingDirectory = [System.IO.Path]::GetFullPath($WorkingDirectory)
  }
  foreach ($Argument in $ArgumentList) { [void]$StartInfo.ArgumentList.Add([string]$Argument) }

  $Process = [System.Diagnostics.Process]::new()
  $Process.StartInfo = $StartInfo
  try {
    if (-not $Process.Start()) { throw "Failed to start native process: $FilePath" }
    $StdOutTask = $Process.StandardOutput.ReadToEndAsync()
    $StdErrTask = $Process.StandardError.ReadToEndAsync()
    $Process.WaitForExit()
    $StdOut = $StdOutTask.GetAwaiter().GetResult()
    $StdErr = $StdErrTask.GetAwaiter().GetResult()
    return [pscustomobject]@{
      ExitCode = [int]$Process.ExitCode
      StdOut = [string]$StdOut
      StdErr = [string]$StdErr
      StdOutLines = @($StdOut -split "\r?\n" | Where-Object { $_.Length -gt 0 })
      StdErrLines = @($StdErr -split "\r?\n" | Where-Object { $_.Length -gt 0 })
    }
  }
  finally { $Process.Dispose() }
}

function Split-AgenticNulList {
  [CmdletBinding()]
  param([AllowEmptyString()][string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return @() }
  return @($Text.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries))
}

function Assert-AgenticNativeSuccess {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)]$Result,[Parameter(Mandatory = $true)][string]$Description)
  if ([int]$Result.ExitCode -ne 0) {
    $Details = if ([string]::IsNullOrWhiteSpace([string]$Result.StdErr)) { [string]$Result.StdOut } else { [string]$Result.StdErr }
    throw "$Description failed with exit code $($Result.ExitCode): $($Details.Trim())"
  }
}
