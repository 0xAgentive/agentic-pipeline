[CmdletBinding()]
param(
  [string]$ProjectRoot='.',
  [string]$PacketDirectory='',
  [switch]$Apply,
  [string]$ProjectKey='',
  [string]$RecoveryDatabase='',
  [string]$StandbyState='',
  [switch]$Standalone,
  [Parameter(DontShow=$true)][ValidateRange(0,5)][int]$FaultInjectionAfterPublishes=0
)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$Root=(Resolve-Path -LiteralPath $ProjectRoot).Path
$Python=(Get-Command python -ErrorAction Stop).Source
$Wrapper=Join-Path $Root 'scripts/bridge/activate_action_packet.py'
if(-not(Test-Path -LiteralPath $Wrapper -PathType Leaf)){throw 'Transactional activation wrapper missing. Update the complete runtime package before activation.'}
$Arguments=@($Wrapper,'--project-root',$Root)
if(-not[string]::IsNullOrWhiteSpace($PacketDirectory)){$Arguments+=@('--packet-directory',$PacketDirectory)}
if(-not[string]::IsNullOrWhiteSpace($ProjectKey)){$Arguments+=@('--project-key',$ProjectKey)}
if(-not[string]::IsNullOrWhiteSpace($RecoveryDatabase)){$Arguments+=@('--recovery-db',$RecoveryDatabase)}
if(-not[string]::IsNullOrWhiteSpace($StandbyState)){$Arguments+=@('--standby-state',$StandbyState)}
if($Standalone){$Arguments+='--standalone'}
if($Apply){$Arguments+='--apply'}
if($FaultInjectionAfterPublishes-gt 0){$Arguments+=@('--fault-injection',[string]$FaultInjectionAfterPublishes)}
& $Python @Arguments
if($LASTEXITCODE-ne 0){throw 'Action packet activation was not verified. Inspect the packet-specific observation before retry.'}
