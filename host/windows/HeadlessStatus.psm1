#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Pure presentation policy: never probes devices or authorizes a mutation.
function Get-KnotHeadlessStatusText([string] $Status) {
    switch -CaseSensitive ($Status) {
        'Unsupported' { return '이 상태 확인은 64비트 Windows PowerShell에서만 사용할 수 있습니다. 배포용 Knot Windows EXE를 실행하세요.' }
        'DeviceIdentityUnavailable' { return '설치 기록에 맞는 장치 식별 정보를 확인하지 못해 자동 제거를 중단했습니다. 기존 기록과 설정을 보존했습니다. Windows 관리자에게 장치와 복구 기록 점검을 요청하세요.' }
        'BootEvidenceUnavailable' { return '부팅 정보를 안전하게 확인하지 못해 자동 복구를 중단했습니다. 기존 기록은 보존했습니다. Windows 관리자에게 부팅 정보와 복구 기록 점검을 요청하세요.' }
        'Absent' { return 'Knot 가상 화면이 없습니다. 외부 드라이버 보안 검토로 자동 설치는 보류 중입니다.' }
        'Installed' { return '설치 기록을 확인했습니다. 실제 장치와 화면 상태는 추가로 확인해야 합니다.' }
        'InstalledPendingRestart' { return '설치 때 Windows 재시작이 요청되었습니다. 아직 재시작하지 않았다면 먼저 재시작하세요. 이미 했다면 실제 화면과 원격 연결을 확인하세요.' }
        'RemovalPending' { return '기록상 제거 또는 설치 실패 후 복구와 재시작 확인이 남아 있습니다. 관리형 제거에서 상태를 다시 확인하세요. 복구 기록은 보존됩니다.' }
        'LegacyRecoveryRequired' { return '이전 버전의 제거 기록에는 재시작을 안전하게 검증할 정보가 없습니다. 자동 제거를 중단했습니다. 파일을 삭제하지 말고 관리자에게 복구를 요청하세요.' }
        'RecoveryRequired' { return '완료되지 않은 작업 기록이 있습니다. 상태 확인 후 관리형 제거로 복구하세요. 파일을 직접 삭제하거나 재설치하지 마세요.' }
        'Conflict' { return '복구 기록이나 설정을 안전하게 확인하지 못했습니다. 기존 상태를 보존했습니다. 파일을 삭제하지 말고 관리자에게 복구 기록 점검을 요청하세요.' }
        default { return '알 수 없는 복구 상태입니다. 자동 작업을 중단했습니다. 기존 기록을 보존하고 관리자에게 확인하세요.' }
    }
}
function Get-KnotHeadlessOperationText([ValidateSet('InstallVirtualDisplay','RemoveVirtualDisplay')][string] $Operation,[int] $Code) {
    if ($Code -eq 0) {
        if ($Operation -ceq 'InstallVirtualDisplay') { return '설치 작업을 완료했습니다. 실제 화면과 Sunshine 원격 연결은 별도로 확인하세요.' }
        return 'Knot 가상 화면 제거를 완료했습니다. Windows 드라이버 저장소 캐시는 유지됩니다.'
    }
    if ($Code -eq 3010 -and $Operation -ceq 'InstallVirtualDisplay') { return '설치는 완료됐지만 Windows 재시작이 필요합니다. 재시작 후 실제 화면과 원격 연결을 확인하세요.' }
    if ($Code -eq 13) { return '자동 복구를 진행할 수 없습니다. Windows 관리자에게 복구 기록과 장치·부팅 정보 점검을 요청하세요. 재시작만 반복하거나 복구 파일을 삭제하지 마세요.' }
    if ($Code -eq 12) {
        if ($Operation -ceq 'InstallVirtualDisplay') { return '설치를 완료하지 못했고 복구가 남아 있습니다. Windows 재시작 후 관리형 제거를 실행하세요. 복구 파일은 보존됩니다.' }
        return '제거가 아직 완료되지 않았습니다. Windows 재시작 후 여기에서 제거를 다시 실행하세요. 복구 파일은 보존됩니다.'
    }
    return '작업을 완료하지 못했습니다. 관리자 창의 안내와 복구 상태를 확인하세요. 기존 설정과 복구 기록은 보존됩니다.'
}
Export-ModuleMember -Function Get-KnotHeadlessStatusText,Get-KnotHeadlessOperationText
