#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Presentation only. Importing this module never probes or changes Windows state.
function Get-SetupFailureText($ErrorRecord,[ValidateSet('General','DesktopUser','ElevatedToken')][string] $Context='General') {
    $cause=$ErrorRecord.Exception
    while ($cause) {
        if ($cause -is [ComponentModel.Win32Exception] -and $cause.NativeErrorCode -eq 1223) {
            return '관리자 확인을 취소했습니다. 필요할 때 다시 시작하세요.'
        }
        $cause=$cause.InnerException
    }
    if ($Context -ceq 'ElevatedToken') {
        return '이 창은 관리자 권한으로 실행되어 설정을 시작할 수 없습니다. 창을 닫고 공유 파일을 사용할 Windows 사용자로 Knot을 일반 실행하세요. UAC를 끈 환경이나 기본 Administrator 계정에서는 일반 실행도 관리자 권한일 수 있습니다. 이 경우 관리자에게 일반 사용자 환경 또는 수동 설정을 요청하세요.'
    }
    if ($Context -ceq 'DesktopUser') {
        return '파일 자동 설정에는 활성화된 로컬 Windows 사용자 계정이 필요합니다. Microsoft 계정에 연결된 로컬 사용자는 지원합니다. 도메인·Entra 계정이나 로컬 사용자 확인이 제한된 조직 PC는 Windows 관리자에게 수동 통합을 요청하세요.'
    }
    $message=[string]$ErrorRecord.Exception.Message
    if ($message -match '[가-힣]') { return $message }
    return 'Windows 설정을 완료하지 못했습니다. 표시된 Windows 오류와 기존 OpenSSH 설정·조직 보안 정책을 확인하세요. 기존 SSH 서버나 조직에서 관리하는 PC는 수동 통합·승인된 배포 안내를 사용하세요.'
}
function Get-SunshineInstallResult([Nullable[int]] $ExitCode,[switch] $Broker) {
    $state='Failed'; $text='Sunshine 설치를 완료하지 못했습니다. Windows 설치 안내의 오류를 확인한 뒤 다시 시도하세요.'
    switch ($ExitCode) {
        0 { $state='Installed'; $text='설치 완료. 다음은 Sunshine 초기 설정입니다.' }
        1602 { $state='Cancelled'; $text='Sunshine 설치를 취소했습니다. 필요할 때 다시 시작하세요.' }
        1618 { $state='Retry'; $text='다른 Windows 설치 작업이 진행 중입니다. 해당 설치가 끝난 뒤 Sunshine 설치를 다시 시작하세요.' }
        1641 { $state='RestartInitiated'; $text='Sunshine 설치가 완료되어 Windows 재시작이 시작되었습니다. 재시작한 뒤 Sunshine 초기 설정을 진행하세요.' }
        3010 { $state='RestartRequired'; $text='설치를 완료하려면 Windows를 다시 시작해야 합니다. 재시작한 뒤 Sunshine 초기 설정을 진행하세요.' }
        2 { if ($Broker) { $state='HandledFailure'; $text='설치를 완료하지 못했습니다. 표시된 오류 안내를 확인한 뒤 다시 시도하세요.' } }
    }
    return [pscustomobject]@{State=$state;Text=$text}
}
function Set-SetupStatusText($Control,[string] $Text) {
    # Repeated download polls must preserve text selection and avoid duplicate accessibility events.
    if ([string]$Control.Text -cne $Text) { $Control.Text=$Text }
}
function Get-KnotHeadlessAvailabilityText([string] $Reason) {
    if ($Reason -ceq 'manifest-invalid') {
        return '함께 제공된 가상 화면 설치 파일 정보를 확인하지 못해 자동 설치를 중단했습니다. 새 Knot 배포 파일로 다시 시도하세요. 기존 화면과 복구 기록은 보존됩니다.'
    }
    return '가상 화면 자동 설치는 현재 사용할 수 없습니다. 외부 드라이버의 보안 검토가 끝날 때까지 설치를 보류했습니다. 모니터 또는 HDMI 더미 플러그로 기존 화면 연결을 이용할 수 있습니다.'
}
function Test-KnotHeadlessDeviceProbeRequired([string] $Status,[bool] $InstallEnabled) {
    # A verified absent deployment with blocked installation has no available device operation.
    # Every managed/recovery state still needs the existing fresh device identity check.
    return ($Status -cne 'Absent' -or $InstallEnabled)
}
Export-ModuleMember -Function Get-SetupFailureText,Get-SunshineInstallResult,Set-SetupStatusText,Get-KnotHeadlessAvailabilityText,Test-KnotHeadlessDeviceProbeRequired
