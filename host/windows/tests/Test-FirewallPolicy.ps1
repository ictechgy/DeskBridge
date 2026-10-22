#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'SetupContract.psm1') -Force
$count=0
function Expect([bool] $Value) { if (-not $Value) {throw 'Synthetic firewall contract failed'}; $script:count++ }
$valid=@{
 RuleCount=1;AddressFilterCount=1;PortFilterCount=1;ApplicationFilterCount=1;ServiceFilterCount=1
 InterfaceFilterCount=1;InterfaceTypeFilterCount=1;SecurityFilterCount=1
 Name='DeskBridge-SFTP-In-TCP';Enabled='True';Direction='Inbound';Action='Allow';Profile='Any'
 LocalPort='22';RemotePort='Any';LocalAddress='Any';RemoteAddress=@('192.168.1.10','100.80.1.2')
 Program='Any';Service='Any';InterfaceAlias='Any';InterfaceType='Any';EdgeTraversalPolicy='Block';Protocol='TCP'
 Authentication='NotRequired';Encryption='NotRequired';LocalUser='Any';RemoteUser='Any';RemoteMachine='Any'
}
$addresses=@('100.80.1.2','192.168.1.10')
Expect (Test-ManagedFirewallPolicy ([pscustomobject]$valid) $addresses)
$numeric=$valid.Clone();$numeric.Protocol=6
Expect (Test-ManagedFirewallPolicy ([pscustomobject]$numeric) $addresses)
foreach ($mutation in @(@('Enabled','False'),@('Direction','Outbound'),@('Action','Block'),@('Profile','Private'),
 @('Protocol','UDP'),@('LocalPort','Any'),@('RemotePort','12345'),@('LocalAddress','10.0.0.1'),
 @('Program','C:\synthetic.exe'),@('Service','Other'),@('InterfaceAlias','Ethernet'),@('InterfaceType','Wireless'),
 @('EdgeTraversalPolicy','Allow'),@('Authentication','Required'),@('Encryption','Required'),
 @('LocalUser','Other'),@('RemoteUser','Other'),@('RemoteMachine','Other'),@('Name','Unrelated'),
 @('RemoteAddress',@('Any')),@('RemoteAddress',@('8.8.8.8')),@('RemoteAddress',@('192.168.1.10')),
 @('RemoteAddress',@('100.80.1.2','100.80.1.2')),@('LocalPort',@('22','80')))) {
 $changed=$valid.Clone();$changed[$mutation[0]]=$mutation[1]
 Expect (-not (Test-ManagedFirewallPolicy ([pscustomobject]$changed) $addresses))
}
foreach ($name in @($valid.Keys)) {
 $missing=$valid.Clone();$missing.Remove($name)
 Expect (-not (Test-ManagedFirewallPolicy ([pscustomobject]$missing) $addresses))
}
foreach ($name in @('RuleCount','AddressFilterCount','PortFilterCount','ApplicationFilterCount','ServiceFilterCount','InterfaceFilterCount','InterfaceTypeFilterCount','SecurityFilterCount')) {
 foreach ($value in @(0,2)) {
  $changed=$valid.Clone();$changed[$name]=$value
  Expect (-not (Test-ManagedFirewallPolicy ([pscustomobject]$changed) $addresses))
 }
}
Expect (-not (Test-ManagedFirewallPolicy $null $addresses))
Expect (-not (Test-ManagedFirewallPolicy ([pscustomobject]$valid) @('100.80.1.2','100.80.1.2')))
Expect (-not (Test-ManagedFirewallPolicy ([pscustomobject]$valid) @()))
Expect (-not (Test-ManagedFirewallPolicy ([pscustomobject]$valid) @('8.8.8.8')))
Expect (-not (Test-ManagedFirewallPolicy ([pscustomobject]$valid) @('192.168.1.1','192.168.1.2','192.168.1.3','192.168.1.4','192.168.1.5','192.168.1.6','192.168.1.7','192.168.1.8','192.168.1.9')))
# A manually chosen link-local endpoint remains an advanced policy exception, never an automatic suggestion.
$manual=$valid.Clone();$manual.RemoteAddress=@('169.254.1.2')
Expect (Test-ManagedFirewallPolicy ([pscustomobject]$manual) @('169.254.1.2'))
@{status='passed';checks=$count;scope='pure synthetic rule/filter projections; no firewall lookup or mutation'} | ConvertTo-Json
