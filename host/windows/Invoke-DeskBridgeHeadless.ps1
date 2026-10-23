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
    if ($Name -cnotin @('operation-success','reboot-required','recovery-blocked')) { throw 'Invalid setup receipt.' }
    # This broker-owned stage has already passed protected ancestor and ACL checks.
    $receipt=[IO.File]::Open((Join-Path $PSScriptRoot $Name),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $receipt.Dispose()
}
try {
    if ($Operation -ceq 'InstallVirtualDisplay') { $result=Install-KnotVirtualDisplay }
    else { $result=Remove-KnotVirtualDisplay }
    if (-not $result.Completed -and $result.Status -cin @('LegacyRecoveryRequired','BootEvidenceUnavailable','DeviceIdentityUnavailable')) {
        if ($result.RebootRequired) { throw 'Blocked recovery must not request another restart.' }
        Write-HeadlessReceipt 'recovery-blocked'
        Write-Host '자동 복구를 진행할 수 없습니다. 관리자에게 복구 기록과 장치·부팅 정보 점검을 요청하세요. 재시작만 반복하거나 복구 파일을 삭제하지 마세요.' -ForegroundColor Red
        if (-not $NoPause) { [void](Read-Host '안내를 확인했습니다. Enter 키를 누르면 관리자 창이 닫힙니다') }
        exit 13
    }
    if ($result.Completed) { Write-HeadlessReceipt 'operation-success' }
    if ($result.RebootRequired) {
        Write-HeadlessReceipt 'reboot-required'
        if ($result.Completed) {
            Write-Host 'Installation completed and requires a Windows restart. Reopen Knot afterward to check the display.'
            exit 3010
        }
        Write-Host 'The operation is incomplete. Recovery requires a Windows restart; keep the recovery folder and retry managed removal afterward.'
        exit 12
    }
    if (-not $result.Completed) { throw 'Virtual display setup could not verify completion.' }
    Write-Host 'The managed virtual display operation completed. Installation alone does not verify a streaming connection.'
    exit 0
} catch {
    Write-Host '가상 디스플레이 작업을 완료하지 못했습니다. 기존 장치와 복구 기록은 보존됩니다. 관리형 가상 디스플레이 상태를 확인하고 관리자에게 복구 기록 점검을 요청하세요.' -ForegroundColor Red
    if (-not $NoPause) {
        [void](Read-Host '실패 내용을 확인했습니다. Enter 키를 누르면 관리자 창이 닫힙니다')
        exit 2
    }
    exit 1
}
