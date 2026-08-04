Set-StrictMode -Version 3.0

function Invoke-TransportNative {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [string]$WorkingDirectory = '',
    [switch]$AllowFailure
  )

  $OldPreference = $ErrorActionPreference
  $Pushed = $false
  try {
    $ErrorActionPreference = 'Continue'
    if (![string]::IsNullOrWhiteSpace($WorkingDirectory)) {
      Push-Location -LiteralPath $WorkingDirectory
      $Pushed = $true
    }
    $Lines = @(& $FilePath @ArgumentList 2>&1)
    $Code = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  }
  finally {
    if ($Pushed) { Pop-Location }
    $ErrorActionPreference = $OldPreference
  }

  $Text = ($Lines -join "`n")
  if (!$AllowFailure -and $Code -ne 0) {
    throw "Command failed ($Code): $FilePath $($ArgumentList -join ' ')`n$Text"
  }

  [pscustomobject]@{
    Code = $Code
    Text = $Text
    Lines = $Lines
  }
}

function Normalize-GitHubOrigin {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)][string]$Url)

  $Value = $Url.Trim().TrimEnd('/').ToLowerInvariant()
  if ($Value.EndsWith('.git')) {
    $Value = $Value.Substring(0, $Value.Length - 4)
  }

  if ($Value -match '^git@github\.com:(.+)$') {
    return ('https://github.com/' + $Matches[1].TrimEnd('/'))
  }
  if ($Value -match '^ssh://git@github\.com/(.+)$') {
    return ('https://github.com/' + $Matches[1].TrimEnd('/'))
  }
  return $Value
}

function Test-TransientGitHubNetworkFailure {
  [CmdletBinding()]
  param([AllowEmptyString()][string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }

  return [bool]($Text -match '(?i)(schannel|ssl/tls|tls connection|ssl_connect|failed to receive handshake|connection reset|recv failure|send failure|could not resolve host|failed to connect|connection timed out|operation timed out|http/2 stream|early eof|remote end hung up|unexpected eof|network is unreachable|temporary failure|connection was closed)')
}

function Initialize-GitHubCredentialHelper {
  [CmdletBinding()]
  param([switch]$AllowMissingGh)

  $GhCommand = Get-Command gh -ErrorAction SilentlyContinue
  if (!$GhCommand) {
    if ($AllowMissingGh) { return $null }
    throw 'GitHub CLI (gh) is required.'
  }

  $Status = Invoke-TransportNative -FilePath $GhCommand.Source -ArgumentList @('auth', 'status', '--hostname', 'github.com') -AllowFailure
  if ($Status.Code -ne 0) {
    throw "GitHub CLI authentication is not valid.`n$($Status.Text)"
  }

  $Setup = Invoke-TransportNative -FilePath $GhCommand.Source -ArgumentList @('auth', 'setup-git', '--hostname', 'github.com') -AllowFailure
  if ($Setup.Code -ne 0) {
    throw "Unable to configure Git to use the GitHub CLI credential helper.`n$($Setup.Text)"
  }

  return $GhCommand.Source
}

function Invoke-GitHubGit {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string[]]$GitArguments,
    [string]$WorkingDirectory = '',
    [string]$OperationName = 'GitHub Git operation',
    [int]$AttemptsPerProfile = 2,
    [switch]$AllowFailure
  )

  $GitCommand = (Get-Command git -ErrorAction Stop).Source
  $Profiles = @(
    [pscustomobject]@{
      Name = 'default'
      Prefix = @()
    },
    [pscustomobject]@{
      Name = 'http1'
      Prefix = @('-c', 'http.version=HTTP/1.1', '-c', 'http.maxRequests=1')
    },
    [pscustomobject]@{
      Name = 'openssl-http1'
      Prefix = @('-c', 'http.sslBackend=openssl', '-c', 'http.version=HTTP/1.1', '-c', 'http.maxRequests=1')
    }
  )

  $Failures = New-Object System.Collections.Generic.List[object]

  foreach ($Profile in $Profiles) {
    for ($Attempt = 1; $Attempt -le [Math]::Max(1, $AttemptsPerProfile); $Attempt++) {
      $Arguments = @($Profile.Prefix) + @($GitArguments)
      $Result = Invoke-TransportNative -FilePath $GitCommand -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory -AllowFailure

      if ($Result.Code -eq 0) {
        return [pscustomobject]@{
          Code = 0
          Text = $Result.Text
          Lines = $Result.Lines
          TransportProfile = $Profile.Name
          Attempts = $Failures.Count + 1
        }
      }

      $Failures.Add([pscustomobject]@{
        Profile = $Profile.Name
        Attempt = $Attempt
        Code = $Result.Code
        Text = $Result.Text
      }) | Out-Null

      $IsTransient = Test-TransientGitHubNetworkFailure -Text $Result.Text
      if (!$IsTransient) {
        $Message = "$OperationName failed with a non-transient Git error using profile '$($Profile.Name)'.`n$($Result.Text)"
        if ($AllowFailure) {
          return [pscustomobject]@{
            Code = $Result.Code
            Text = $Message
            Lines = $Result.Lines
            TransportProfile = $Profile.Name
            Attempts = $Failures.Count
          }
        }
        throw $Message
      }

      if ($Attempt -lt $AttemptsPerProfile) {
        Start-Sleep -Seconds ([Math]::Min(8, 2 * $Attempt))
      }
    }
  }

  $DiagnosticLines = New-Object System.Collections.Generic.List[string]
  $DiagnosticLines.Add("$OperationName failed through every safe HTTPS profile.") | Out-Null
  foreach ($Failure in $Failures) {
    $DiagnosticLines.Add("[$($Failure.Profile) attempt $($Failure.Attempt), exit $($Failure.Code)] $($Failure.Text)") | Out-Null
  }

  $GhCommand = Get-Command gh -ErrorAction SilentlyContinue
  if ($GhCommand) {
    $Api = Invoke-TransportNative -FilePath $GhCommand.Source -ArgumentList @('api', 'repos/0xAgentive/agentic-pipeline', '--jq', '.default_branch') -AllowFailure
    if ($Api.Code -eq 0) {
      $DiagnosticLines.Add("GitHub API through gh is reachable, but the Git for Windows HTTPS transport failed. This normally indicates a Git/libcurl Schannel path problem rather than an authentication problem.") | Out-Null
    }
    else {
      $DiagnosticLines.Add("GitHub API diagnostic also failed: $($Api.Text)") | Out-Null
    }
  }

  $DiagnosticLines.Add('Certificate verification and revocation checks were not disabled.') | Out-Null
  $Message = ($DiagnosticLines -join "`n")

  if ($AllowFailure) {
    return [pscustomobject]@{
      Code = 1
      Text = $Message
      Lines = @($Message)
      TransportProfile = 'none'
      Attempts = $Failures.Count
    }
  }
  throw $Message
}

function Test-GitHubTransport {
  [CmdletBinding()]
  param(
    [string]$RepositoryUrl = 'https://github.com/0xAgentive/agentic-pipeline.git',
    [string]$WorkingDirectory = ''
  )

  Initialize-GitHubCredentialHelper | Out-Null
  return Invoke-GitHubGit -GitArguments @('ls-remote', '--heads', $RepositoryUrl, 'refs/heads/main') -WorkingDirectory $WorkingDirectory -OperationName 'GitHub transport preflight'
}
