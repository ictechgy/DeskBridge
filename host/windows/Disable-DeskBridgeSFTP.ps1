#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -PSEdition Desktop
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param([switch] $Apply)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SetupContract.psm1') -Force
if (-not $Apply) { Write-Output 'Review mode: -Apply stops the dedicated sshd deployment, disables its account and firewall rule, and archives its SSH config. Shared files and host keys are retained.'; return }
if (-not $PSCmdlet.ShouldProcess('DeskBridge SFTP deployment', 'Disable remote file access; retain shared data')) { return }
$deployment=Get-ManagedDeployment -Revoke
$state=$deployment.State; $record=$deployment.Record; $config=$deployment.Config
if (-not $deployment.ConfigExists) {
    if ($deployment.User.Enabled -or $deployment.Service.State -ne 'Stopped') { throw 'The retained deployment is not fully disabled. Review manually; no service/account changes were made.' }
} else {
    Stop-Service -Name sshd
    Disable-LocalUser -SID $deployment.User.SID
}
# This helper owns a dedicated system OpenSSH deployment. Stop existing session workers too;
# disabling a user/key by itself only prevents future authentication.
Stop-ManagedSessionWorkers
Remove-ManagedFirewallAccess
if (-not $deployment.ConfigExists) {
    Set-Service -Name sshd -StartupType $record.StartupBefore
    Write-Output 'DeskBridge access is already disabled. Verified retained metadata/account and terminated any remaining owned sessions.'
    return
}
Move-Item -LiteralPath $config -Destination (Join-Path $state ('sshd_config.disabled-' + (Get-Date -Format 'yyyyMMddTHHmmss'))) 
Set-Service -Name sshd -StartupType $record.StartupBefore
if ($record.DefaultRuleEnabled -eq 'True') { Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' }
Write-Output 'DeskBridge access disabled. Files, disabled account, host keys and archived configuration remain for review. OpenSSH optional feature remains installed. The service stays stopped.'
