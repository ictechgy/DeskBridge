#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Pure projections only. Never call the production inactivity inventory or Windows configuration commands.
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'SetupContract.psm1') -Force
$count=0
function Expect([bool] $Value,[string] $Message) { if (-not $Value) {throw $Message};$script:count++ }
$inactive=@{
 InspectionSucceeded=$true;ConfigState='Absent';FirewallRuleCount=0
 AccountCount=0;AccountState='Missing';ServiceCount=0;ServiceState='Missing';WorkerCount=0
}
foreach ($account in @('Missing','Disabled')) {
 foreach ($service in @('Missing','Stopped')) {
  $projection=$inactive.Clone();$projection.AccountState=$account;$projection.AccountCount=if ($account -eq 'Missing') {0} else {1}
  $projection.ServiceState=$service;$projection.ServiceCount=if ($service -eq 'Missing') {0} else {1}
  Expect (Test-FileAccessInactive ([pscustomobject]$projection)) 'Known absent/disabled account and absent/stopped service must allow a no-op.'
 }
}
foreach ($entry in @(@('InspectionSucceeded',$false),@('InspectionSucceeded','True'),@('InspectionSucceeded',1),
 @('ConfigState','Present'),@('ConfigState','Unknown'),@('ConfigState',$null),@('ConfigState',@('Absent')),
 @('FirewallRuleCount',1),@('FirewallRuleCount',2),@('WorkerCount',1),@('WorkerCount',2),
 @('AccountState','Enabled'),@('AccountState','Unknown'),@('AccountState',$null),@('AccountState',@('Missing')),
 @('AccountCount',1),@('AccountCount',2),@('ServiceState','Running'),@('ServiceState','Paused'),
 @('ServiceState','StartPending'),@('ServiceState','StopPending'),@('ServiceState','Unknown'),@('ServiceState',$null),
 @('ServiceCount',1),@('ServiceCount',2))) {
 $projection=$inactive.Clone();$projection[$entry[0]]=$entry[1]
 Expect (-not (Test-FileAccessInactive ([pscustomobject]$projection))) ('Unknown/active/mismatched inactivity condition accepted: '+$entry[0])
}
foreach ($field in @('FirewallRuleCount','AccountCount','ServiceCount','WorkerCount')) {
 foreach ($value in @(-1,0.0,'0',$false,$null)) {
  $projection=$inactive.Clone();$projection[$field]=$value
  Expect (-not (Test-FileAccessInactive ([pscustomobject]$projection))) ('Invalid inventory count accepted: '+$field)
 }
 $projection=$inactive.Clone();$projection[$field]=[long]0
 Expect (Test-FileAccessInactive ([pscustomobject]$projection)) 'Integer inventory representations should remain compatible.'
}
foreach ($field in @($inactive.Keys)) {
 $projection=$inactive.Clone();$projection.Remove($field)
 Expect (-not (Test-FileAccessInactive ([pscustomobject]$projection))) ('Missing inventory field accepted: '+$field)
}
foreach ($entry in @(@('AccountState','Disabled'),@('ServiceState','Stopped'))) {
 $projection=$inactive.Clone();$projection[$entry[0]]=$entry[1]
 Expect (-not (Test-FileAccessInactive ([pscustomobject]$projection))) 'A missing entity cannot claim the disabled/stopped state.'
}
Expect (-not (Test-FileAccessInactive $null)) 'Missing inventory must fail closed.'
# Pure exact path classifier, shared with the actual read-only inventory.
foreach ($name in @('sshd.exe','sshd-session.exe','sshd-auth.exe')) {
 Expect (Test-SystemOpenSSHWorkerPath ([pscustomobject]@{Name=$name;ExecutablePath=('C:\Windows\System32\OpenSSH\'+$name)}) 'C:\Windows') 'OS OpenSSH worker must be counted'
}
Expect (Test-SystemOpenSSHWorkerPath ([pscustomobject]@{Name='SSHD.EXE';ExecutablePath='c:\WINDOWS\SYSTEM32\OPENSSH\sshd.exe'}) 'C:\Windows') 'Windows worker paths compare case insensitively'
foreach ($path in @('C:\Other\sshd.exe','C:\Windows\System32\OpenSSH2\sshd.exe','C:\Windows\System32\OpenSSH\..\OpenSSH\sshd.exe','C:\Windows\System32\OpenSSH\sshd.exe:stream','\host\ssh\sshd.exe','C:\Windows\System32\OpenSSH\sshd.exe --arg','', $null)) {
 Expect (-not (Test-SystemOpenSSHWorkerPath ([pscustomobject]@{Name='sshd.exe';ExecutablePath=$path}) 'C:\Windows')) 'Foreign or malformed worker path must make inventory unknown'
}
Expect (-not (Test-SystemOpenSSHWorkerPath ([pscustomobject]@{Name='other.exe';ExecutablePath='C:\Windows\System32\OpenSSH\other.exe'}) 'C:\Windows')) 'Unrecognized worker name must fail closed'
Expect (-not (Test-SystemOpenSSHWorkerPath $null 'C:\Windows')) 'Missing worker must fail closed'
foreach ($windows in @('C:\Windows\..\Windows','C:\Windows.','C:\Windows\','\server\Windows','C:/Windows')) {
 Expect (-not (Test-SystemOpenSSHWorkerPath ([pscustomobject]@{Name='sshd.exe';ExecutablePath='C:\Windows\System32\OpenSSH\sshd.exe'}) $windows)) 'Noncanonical OS directory must fail closed'
}
# Extract both actual named-query and cleanup functions into the same synthetic scope.
# Module-scoped helpers must never escape the fake cmdlets to inspect machine policy.
$tokens=$null;$errors=$null
$modulePath=Join-Path (Split-Path $PSScriptRoot -Parent) 'SetupContract.psm1'
$ast=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$errors)
$functions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Get-NamedManagedFirewallRules','Remove-ManagedFirewallAccess')},$true))
Expect ($errors.Count -eq 0 -and $functions.Count -eq 2 -and @($functions.Name | Sort-Object -Unique).Count -eq 2) 'Both actual firewall functions must be uniquely parsed'
& {
 param($ActualFunction)
 function Get-NetFirewallRule {
  [CmdletBinding()] param([string] $Name,[string] $PolicyStore)
  if ($ErrorActionPreference -ne 'Stop' -or $Name -cne 'DeskBridge-SFTP-In-TCP' -or $PolicyStore -notin @('PersistentStore','ActiveStore')) {throw 'Query contract changed'}
  $script:queried+=$PolicyStore
  if ($script:queryFailure) {throw 'synthetic policy read failure'}
  if ($script:unrelatedNotFound -or $script:accessDenied) {
   $id=if ($script:accessDenied) {'CmdletizationQuery_NotFound_Name'} else {'SyntheticProviderMissing'}
   $category=if ($script:accessDenied) {[Management.Automation.ErrorCategory]::PermissionDenied} else {[Management.Automation.ErrorCategory]::ObjectNotFound}
   $record=[Management.Automation.ErrorRecord]::new([Exception]::new('synthetic query failure'),$id,$category,$Name)
   $PSCmdlet.ThrowTerminatingError($record)
  }
  if (($PolicyStore -eq 'PersistentStore' -and $script:configured) -or ($PolicyStore -eq 'ActiveStore' -and $script:active)) {
   [pscustomobject]@{Name='DeskBridge-SFTP-In-TCP'}
  } else {
   $record=[Management.Automation.ErrorRecord]::new([Exception]::new('synthetic named rule absent'),'CmdletizationQuery_NotFound_Name',[Management.Automation.ErrorCategory]::ObjectNotFound,$Name)
   $PSCmdlet.ThrowTerminatingError($record)
  }
 }
 function Remove-NetFirewallRule {
  [CmdletBinding()] param([string] $Name,[string] $PolicyStore)
  if ($ErrorActionPreference -ne 'Stop' -or $Name -cne 'DeskBridge-SFTP-In-TCP' -or $PolicyStore -cne 'PersistentStore') {throw 'Removal authority widened'}
  $script:removed++
  if ($script:removeFailure) {throw 'synthetic denied deletion'}
  if (-not $script:retainConfigured) {$script:configured=$false}
  if (-not $script:retainActive) {$script:active=$false}
 }
 . ([scriptblock]::Create($ActualFunction))
 foreach ($case in @('Absent','Present','QueryFailure','UnrelatedNotFound','AccessDenied','RemoveFailure','ResidualPersistent','ResidualActive')) {
  $script:configured=$case -ne 'Absent';$script:active=$case -ne 'Absent'
  $script:queryFailure=$case -eq 'QueryFailure';$script:removeFailure=$case -eq 'RemoveFailure'
  $script:unrelatedNotFound=$case -eq 'UnrelatedNotFound';$script:accessDenied=$case -eq 'AccessDenied'
  $script:retainConfigured=$case -eq 'ResidualPersistent';$script:retainActive=$case -eq 'ResidualActive'
  $script:queried=@();$script:removed=0;$failed=$false
  try {Remove-ManagedFirewallAccess} catch {$failed=$true}
  Expect ($failed -eq ($case -notin @('Absent','Present'))) ('Firewall cleanup failure gate: '+$case)
  if (-not $failed) {
   Expect (($script:queried -join ',') -ceq 'PersistentStore,PersistentStore,ActiveStore') 'Both configured and effective policy must be checked after cleanup'
   Expect ($script:removed -eq [int]($case -eq 'Present')) 'Absent owned rule is a no-op; foreign rules never removed'
  }
 }
} (($functions | ForEach-Object {$_.Extent.Text}) -join [Environment]::NewLine)
@{status='passed';checks=$count;scope='pure typed inactivity/path projections and actual cleanup with synthetic firewall cmdlets; no machine inventory or mutation'} | ConvertTo-Json
