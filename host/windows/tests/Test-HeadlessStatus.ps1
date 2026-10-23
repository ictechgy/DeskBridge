#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'HeadlessStatus.psm1') -Force
$count=0
function Check([bool] $Condition,[string] $Message) { if (-not $Condition) { throw $Message }; $script:count++ }
foreach ($state in @('Absent','Installed','InstalledPendingRestart','RemovalPending','LegacyRecoveryRequired','RecoveryRequired','Conflict','unknown','installed','')) {
    $text=Get-KnotHeadlessStatusText $state
    Check (-not [string]::IsNullOrWhiteSpace($text)) ('Missing state text: '+$state)
}
Check ((Get-KnotHeadlessStatusText 'LegacyRecoveryRequired') -match '관리자') 'Legacy pending must require manual recovery'
Check ((Get-KnotHeadlessStatusText 'InstalledPendingRestart') -match '재시작') 'Successful install must retain restart notice'
foreach ($operation in @('InstallVirtualDisplay','RemoveVirtualDisplay')) {
    foreach ($code in @(0,12,3010,2,1,1602)) {
        $text=Get-KnotHeadlessOperationText $operation $code
        Check (-not [string]::IsNullOrWhiteSpace($text)) 'Missing operation notice'
        if ($code -eq 12) { Check ($text -match '완료하지 못|완료되지') 'Pending recovery must not claim completed installation/removal' }
        if ($code -eq 3010 -and $operation -ceq 'RemoveVirtualDisplay') { Check ($text -match '완료하지 못') 'Unexpected completed-removal restart must not attest success' }
    }
}
[pscustomobject]@{status='passed';checks=$count;freshSyntheticOnly=$true;nativeApisInvoked=$false} | ConvertTo-Json -Compress
