#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -PSEdition Desktop
# SPDX-License-Identifier: GPL-3.0-only
# Explicit UAC-owned reactivation of this helper's retained deployment, never adoption of another SSH server.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string] $ClientPublicKey,[Parameter(Mandatory=$true)][string[]] $AllowedClientAddress,
      [Parameter(Mandatory=$true)][string] $DesktopUserSid)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SetupContract.psm1') -Force
$key=Get-CanonicalPublicKey $ClientPublicKey
$desktopUser=Resolve-DesktopUser $DesktopUserSid
$addresses=@($AllowedClientAddress | ForEach-Object {Get-PrivateIPv4 $_})
if ($addresses.Count -lt 1 -or $addresses.Count -gt 8 -or @($addresses | Select-Object -Unique).Count -ne $addresses.Count) {throw 'Invalid Mac addresses'}
$deployment=Get-ManagedDeployment -WizardDefaults -DesktopUserSid $desktopUser.SID.Value
$state=$deployment.State; $record=$deployment.Record; $user=$deployment.User
$bin=$deployment.Bin; $sshd=$deployment.Sshd; $service=$deployment.Service
$template=$deployment.Template; $config=$deployment.Config; $keyPath=$deployment.KeyPath
$exists=$deployment.ConfigExists; $configMatches=$exists
$oldKey=Get-CanonicalPublicKey ([IO.File]::ReadAllText($keyPath).Trim())
$rule=Get-NetFirewallRule -Name 'DeskBridge-SFTP-In-TCP' -ErrorAction SilentlyContinue
$addressMatch=Test-ManagedFirewallPolicy (Get-ManagedFirewallPolicy) $addresses
$action=Get-ManagedDeploymentAction -ConfigExists $exists -ConfigMatches $configMatches -ServiceRunning ($service.State -eq 'Running') -AccountEnabled $user.Enabled -KeyMatches ($oldKey -ceq $key) -AddressesMatch $addressMatch -Validated ($record.Phase -ceq 'Validated')
if ($action -eq 'Reuse') {return}
# Stop retained session workers before changing a key, even when the service is already stopped.
Disable-LocalUser -SID $user.SID
Stop-ManagedSessionWorkers
try {
 [IO.File]::WriteAllText($keyPath,$key + "`n",(New-Object Text.UTF8Encoding($false)))
 $keygen=Join-Path $bin 'ssh-keygen.exe'
 & $keygen -l -f $keyPath | Out-Null
 if ($LASTEXITCODE -ne 0) {throw 'The client public key is not accepted by OpenSSH'}
 & $keygen -A
 if ($LASTEXITCODE -ne 0) {throw 'Could not generate server host keys'}
 $sshDirectory=Split-Path $config -Parent
 Assert-ProtectedFile (Join-Path $sshDirectory 'ssh_host_ed25519_key.pub')
 Assert-PrivateHostKey (Join-Path $sshDirectory 'ssh_host_ed25519_key')
 Copy-Item -LiteralPath $template -Destination $config -Force
 Set-ManagedConfigAcl $config $user.SID $record.ConfigSha256
 Assert-ManagedConfig $config $record.ConfigSha256
 & $sshd -t -f $config
 if ($LASTEXITCODE -ne 0) {throw 'sshd rejected the restored configuration'}
 # Prepared records may come from failed first setup: validate policy again before any access.
 $rootForConfig=$record.ShareRoot.Replace('\','/')
 $keyForConfig=$keyPath.Replace('\','/')
 $effective=& $sshd -T -f $config -C "user=$($record.UserName),host=localhost,addr=127.0.0.1"
 if ($LASTEXITCODE -ne 0) {throw 'sshd could not evaluate the restored configuration'}
 $required=@('pubkeyauthentication yes','passwordauthentication no','authenticationmethods publickey',
     "allowusers $($record.UserName)",'disableforwarding yes','permittty no','forcecommand internal-sftp -d /files',
     "chrootdirectory $rootForConfig","authorizedkeysfile $keyForConfig")
 foreach ($setting in $required) {if (-not ($effective -contains $setting)) {throw "Effective SSH restriction did not validate: $setting"}}
 $record.Phase='Validated'
 Write-ManagedRecoveryRecord $state $record
 Assert-ProtectedDirectory (Split-Path $config -Parent)
 Assert-ManagedConfig $config $record.ConfigSha256
 $defaultRule=Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
 if ($defaultRule) {Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'}
 if ($rule) {Remove-NetFirewallRule -Name 'DeskBridge-SFTP-In-TCP'}
 New-NetFirewallRule -Name 'DeskBridge-SFTP-In-TCP' -DisplayName 'DeskBridge SFTP from approved Mac addresses' -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress $addresses -Action Allow -Profile Any | Out-Null
 # A stopped service may retain Disabled startup. Permit this start without
 # leaving an automatic service behind if account enable/start fails.
 Set-Service -Name sshd -StartupType Manual
 Enable-LocalUser -SID $user.SID
 Start-Service sshd
 Set-Service -Name sshd -StartupType Automatic
} catch {
 Stop-Service sshd -ErrorAction SilentlyContinue
 Disable-LocalUser -SID $user.SID -ErrorAction SilentlyContinue
 Set-Service -Name sshd -StartupType $record.StartupBefore -ErrorAction SilentlyContinue
 Stop-ManagedSessionWorkers
 Remove-NetFirewallRule -Name 'DeskBridge-SFTP-In-TCP' -ErrorAction SilentlyContinue
 if (Test-Path -LiteralPath $config) {Move-Item -LiteralPath $config -Destination (Join-Path $state ('sshd_config.failed-' + [Guid]::NewGuid().ToString('N'))) }
 throw
}
