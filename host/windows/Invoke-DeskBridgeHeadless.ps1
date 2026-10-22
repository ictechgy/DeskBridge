#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -PSEdition Desktop
# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('InstallVirtualDisplay','RemoveVirtualDisplay')][string] $Operation,
    [switch] $SuccessReceipt,
    [switch] $NoPause
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'HeadlessSetup.psm1') -Force -ErrorAction Stop
function Write-HeadlessReceipt([string] $Name) {
    if (-not $SuccessReceipt) { return }
    if ($Name -cnotin @('operation-success','reboot-required')) { throw 'Invalid setup receipt.' }
    # This broker-owned stage has already passed protected ancestor and ACL checks.
    $receipt=[IO.File]::Open((Join-Path $PSScriptRoot $Name),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $receipt.Dispose()
}
try {
    if ($Operation -ceq 'InstallVirtualDisplay') { $result=Install-KnotVirtualDisplay }
    else { $result=Remove-KnotVirtualDisplay }
    if ($result.Completed) { Write-HeadlessReceipt 'operation-success' }
    if ($result.RebootRequired) {
        Write-HeadlessReceipt 'reboot-required'
        Write-Host 'Windows requires a restart. Keep the recovery folder and reopen Knot after restarting.'
        exit 3010
    }
    if (-not $result.Completed) { throw 'Virtual display setup could not verify completion.' }
    Write-Host 'The managed virtual display operation completed. Installation alone does not verify a streaming connection.'
    exit 0
} catch {
    Write-Host '가상 디스플레이 작업을 완료하지 못했습니다. 기존 장치와 복구 기록은 보존됩니다. 다시 시작한 뒤 관리형 가상 디스플레이 제거를 시도하거나 관리자에게 확인하세요.' -ForegroundColor Red
    if (-not $NoPause) {
        [void](Read-Host '실패 내용을 확인했습니다. Enter 키를 누르면 관리자 창이 닫힙니다')
        exit 2
    }
    exit 1
}
