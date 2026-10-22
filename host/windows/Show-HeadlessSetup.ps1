#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Non-elevated, optional UI. All mutation goes through the fixed native broker.
[CmdletBinding()]
param([Windows.Forms.IWin32Window] $Owner, [string] $LauncherPath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'HeadlessSetup.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SetupDownload.psm1') -Force
$window=New-Object Windows.Forms.Form
$window.Text='Knot · 모니터 없이 사용'; $window.Size=New-Object Drawing.Size(740,740)
$window.MinimumSize=New-Object Drawing.Size(600,480); $window.StartPosition='CenterParent'
$window.AutoScaleDimensions=New-Object Drawing.SizeF(96,96); $window.AutoScaleMode='Dpi'
$window.Font=New-Object Drawing.Font('Segoe UI',10)
$layout=New-Object Windows.Forms.TableLayoutPanel
$layout.Dock='Fill'; $layout.ColumnCount=1; $layout.RowCount=2
[void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',108)))
$window.Controls.Add($layout)
$content=New-Object Windows.Forms.FlowLayoutPanel
$content.Dock='Fill'; $content.FlowDirection='TopDown'; $content.WrapContents=$false; $content.AutoScroll=$true
$content.Padding=New-Object Windows.Forms.Padding(20); $layout.Controls.Add($content,0,0)
$status=New-Object Windows.Forms.TextBox
$status.ReadOnly=$true; $status.Multiline=$true; $status.ScrollBars='Vertical'; $status.BorderStyle='None'
$status.BackColor=[Drawing.SystemColors]::Control; $status.ForeColor=[Drawing.SystemColors]::HotTrack
$status.Dock='Fill'; $status.Margin=New-Object Windows.Forms.Padding(20,8,20,8); $layout.Controls.Add($status,0,1)
$script:headlessBusy=$false; $script:cancelHeadlessDownload=$false; $script:scan=$null
$script:canInstall=$false; $script:canRemove=$false
$script:installHoldText='외부 드라이버의 보안 검토가 끝날 때까지 가상 화면 자동 설치를 보류했습니다. 모니터 또는 HDMI 더미 플러그로 기존 화면 연결을 이용하세요.'
function Add-HeadlessText([string] $Text) {
    $label=New-Object Windows.Forms.Label; $label.Text=$Text; $label.AutoSize=$true
    $label.MaximumSize=New-Object Drawing.Size(660,0); $label.Margin=New-Object Windows.Forms.Padding(3,4,3,12)
    $content.Controls.Add($label); return $label
}
function Add-HeadlessButton([string] $Text,[scriptblock] $Action) {
    $button=New-Object Windows.Forms.Button; $button.Text=$Text; $button.Size=New-Object Drawing.Size(340,36)
    $button.Add_Click($Action); $content.Controls.Add($button); return $button
}
function Set-HeadlessBusy([bool] $Busy) {
    $script:headlessBusy=$Busy; $window.UseWaitCursor=$Busy
    foreach ($control in $content.Controls) { if ($control -is [Windows.Forms.Button]) { $control.Enabled=-not $Busy } }
    $install.Enabled=(-not $Busy -and $script:canInstall -and [bool]$LauncherPath)
    $remove.Enabled=(-not $Busy -and $script:canRemove -and [bool]$LauncherPath)
    $cancel.Enabled=($Busy -and $cancel.Visible)
}
function Show-HeadlessFailure($Record) {
    $cause=$Record.Exception
    while ($cause) {
        if ($cause -is [ComponentModel.Win32Exception] -and $cause.NativeErrorCode -eq 1223) {
            $status.Text='관리자 확인을 취소했습니다. 필요할 때 다시 시작하세요.'; return
        }
        $cause=$cause.InnerException
    }
    $status.Text='완료하지 못했습니다. 네트워크와 관리자 권한을 확인한 뒤 상태를 다시 확인하세요. 기존 드라이버나 변경된 설정은 자동으로 덮어쓰지 않습니다.'
}
function Update-HeadlessState {
    $script:canInstall=$false; $script:canRemove=$false
    $status.Text='가상 화면 상태를 확인하는 중…'; [Windows.Forms.Application]::DoEvents()
    try {
        Initialize-KnotHeadlessNative
        if ($null -eq $script:scan) { $script:scan=[Knot.Headless.Native]::ScanAsync() }
        $timer=[Diagnostics.Stopwatch]::StartNew()
        while (-not $script:scan.IsCompleted -and $timer.Elapsed.TotalSeconds -lt 15) {
            [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 80
        }
        if (-not $script:scan.IsCompleted) { $status.Text=$script:installHoldText+' 장치 확인이 지연되고 있습니다. 잠시 뒤 상태 새로고침을 누르세요.'; return }
        try { $inventory=$script:scan.GetAwaiter().GetResult() } finally { $script:scan=$null }
        $state=Get-KnotHeadlessState
        $foreign=@($inventory.Devices | Where-Object { $_.InstanceId -ine $state.InstanceId })
        if ($state.Status -eq 'Conflict' -or $foreign.Count -gt 0) {
            $status.Text='기존 가상 디스플레이 또는 변경된 설정이 있습니다. Knot이 설치하거나 제거하지 않습니다. 기존 드라이버의 관리 도구를 사용하세요.'; return
        }
        if ($state.Status -eq 'Absent') {
            $availability=Get-KnotHeadlessAvailability
            $script:canInstall=[bool]$availability.Enabled
            $status.Text=if ($script:canInstall) {'Knot 가상 화면이 없습니다. 설치 후 Sunshine에서 사용할 화면을 한 번 지정하세요.'} else {'가상 화면 자동 설치는 현재 사용할 수 없습니다. 외부 드라이버의 보안 검토가 끝날 때까지 설치를 보류했습니다. 모니터 또는 HDMI 더미 플러그로 기존 화면 연결을 이용할 수 있습니다.'}; return
        }
        $script:canRemove=[bool]$state.Managed
        if ($state.Status -ne 'Installed') {
            $status.Text='이전 작업의 복구가 필요합니다. Windows를 재시작한 뒤 “Knot 가상 화면 제거”를 실행하고 다시 설치하세요.'; return
        }
        $devices=@($inventory.Devices | Where-Object { $_.InstanceId -ieq $state.InstanceId })
        $screens=@($inventory.Displays | Where-Object { $_.AdapterInstanceId -ieq $state.InstanceId })
        if ($devices.Count -ne 1) { $status.Text='설치 기록은 있지만 장치를 확인하지 못했습니다. 재시작 후에도 같으면 Knot 가상 화면을 제거한 뒤 다시 설치하세요.'; return }
        $active=@($screens | Where-Object { $_.Active })
        if ($active.Count -gt 0) {
            $names=($active | ForEach-Object { 'name: '+$_.Name+', display_name: '+$_.DisplayName }) -join '; '
            $status.Text='가상 화면 활성 (진단용 이름, Sunshine ID 아님): '+$names+'. Sunshine의 device_id와 실제 원격 연결을 확인하세요.'
        } else { $status.Text='가상 디스플레이 장치는 설치되어 있지만 활성 화면을 확인하지 못했습니다. Windows 디스플레이 설정에서 화면을 확장하거나 재시작한 뒤 다시 확인하세요.' }
        if ($state.RebootRequired) { $status.Text+=' 설치 때 재시작이 요청되었습니다. 아직 재시작하지 않았다면 먼저 재시작하세요.' }
    } catch { $script:scan=$null; Show-HeadlessFailure $_ }
    finally { Set-HeadlessBusy $script:headlessBusy }
}
function Invoke-HeadlessBroker([string] $Operation,[string] $Archive) {
    if (-not $LauncherPath -or $Operation -cnotin @('InstallVirtualDisplay','RemoveVirtualDisplay')) { throw 'A packaged launcher is required.' }
    $arguments='--elevated-operation '+$Operation
    if ($Operation -ceq 'InstallVirtualDisplay') { $arguments+=' --zip-path "'+$Archive+'"' }
    $process=Start-Process -FilePath $LauncherPath -Verb RunAs -ArgumentList $arguments -PassThru
    try {
        $null=$process.Handle
        while (-not $process.HasExited) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
        $process.WaitForExit(); return $process.ExitCode
    } finally { $process.Dispose() }
}
$title=Add-HeadlessText '모니터를 연결하지 않아도 Windows 화면 사용'
$title.Font=New-Object Drawing.Font('Segoe UI',16,[Drawing.FontStyle]::Bold)
$null=Add-HeadlessText 'Windows 11 x64용 선택 기능입니다. 처음 설정할 때는 모니터 또는 다른 원격 접속 수단이 필요합니다. PC가 켜져 있고 Windows에 로그인되어 있어야 하며, 잠자기·로그인 해제 기능은 포함하지 않습니다.'
$null=Add-HeadlessText '1  가상 화면 하나 설치 · 드라이버 검토로 현재 보류'
$null=Add-HeadlessText $script:installHoldText
$null=Add-HeadlessText '이 버전은 드라이버를 설치하지 않습니다. 아래 화면 지정 안내는 이미 사용할 수 있는 화면이 있는 경우에 적용됩니다. Knot 설치 기록이 있는 가상 화면의 상태 확인과 제거는 별도로 사용할 수 있습니다.'
$install=Add-HeadlessButton '가상 화면 설치 (현재 보류)'  {
    # Refresh policy before any confirmation, network activity, or elevation.
    try { $availability=Get-KnotHeadlessAvailability } catch { $availability=$null }
    if (-not $availability -or -not $availability.Enabled) {
        $script:canInstall=$false; Set-HeadlessBusy $false; $status.Text=$script:installHoldText; return
    }
    if ([Windows.Forms.MessageBox]::Show('가상 디스플레이 드라이버와 화면 하나를 설치합니다. 화면은 제거할 때까지 유지되며 관리자 확인이 필요합니다. 계속할까요?','Knot','OKCancel','Information') -ne 'OK') { return }
    Set-HeadlessBusy $true; $folder=$null; $download=$null; $locked=$null
    try {
        $dep=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VirtualDisplayDependency.json') -Raw | ConvertFrom-Json
        if ($dep.url -cne 'https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/download/25.7.23/VirtualDisplayDriver-x86.Driver.Only.zip' -or $dep.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $dep.bytes -ne 132118) { throw 'Invalid package metadata.' }
        $folder=Join-Path ([IO.Path]::GetTempPath()) ('KnotDisplayDownload-'+[Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($folder); $file=Join-Path $folder 'VirtualDisplayDriver.zip'
        $download=Start-SetupDownload -Url $dep.url -Path $file -ExpectedBytes $dep.bytes
        $cancel.Visible=$true; $cancel.Enabled=$true; $script:cancelHeadlessDownload=$false
        while (-not $download.Completion.IsCompleted) {
            [Windows.Forms.Application]::DoEvents()
            if ($script:cancelHeadlessDownload) { $download.Cancel(); $cancel.Enabled=$false }
            $status.Text='가상 화면 설치 파일을 내려받는 중… '+[Math]::Min(100,[Math]::Floor(100.0*$download.Bytes/$dep.bytes))+'%'
            Start-Sleep -Milliseconds 80
        }
        $download.Completion.GetAwaiter().GetResult(); $cancel.Visible=$false
        $locked=[IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $digest=[BitConverter]::ToString($sha.ComputeHash($locked)).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
        if ($locked.Length -ne $dep.bytes -or $digest -cne $dep.sha256) { throw 'Package verification failed.' }
        $status.Text='Windows 관리자 확인과 드라이버 설치를 진행하세요.'
        $result=Invoke-HeadlessBroker 'InstallVirtualDisplay' $file
        Update-HeadlessState
        if ($result -eq 3010) { $status.Text='작업을 마치려면 Windows를 재시작해야 합니다. 재시작 후 Knot에서 상태를 다시 확인하세요.' }
        elseif ($result -ne 0) { $status.Text='설치를 완료하지 못했습니다. 관리자 창의 안내를 확인한 뒤 상태를 새로고침하세요.' }
    } catch [OperationCanceledException] { $status.Text='다운로드를 취소했습니다. 필요할 때 다시 시작하세요.' }
    catch { Show-HeadlessFailure $_ }
    finally {
        $cancel.Visible=$false
        try {
            if ($locked) { $locked.Dispose() }
            if ($download) {
                $download.Cancel()
                while (-not $download.Completion.IsCompleted) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 80 }
                $download.Dispose()
            }
            # Delete only the fresh known download; preserve unexpected content.
            if ($folder -and [IO.Directory]::Exists($folder)) {
                if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
                [IO.Directory]::Delete($folder,$false)
            }
        } catch { $status.Text+=' 임시 다운로드 파일을 정리하지 못했습니다.' }
        finally { Set-HeadlessBusy $false }
    }
}
$cancel=Add-HeadlessButton '다운로드 취소' { $script:cancelHeadlessDownload=$true }; $cancel.Visible=$false
$null=Add-HeadlessText '2  Sunshine에서 전송할 화면 지정 · 처음 한 번'
$null=Add-HeadlessText 'Sunshine 설정의 Troubleshooting에서 표시 장치 목록을 확인하세요. 위 상태에 표시된 화면 이름과 display_name을 비교해 가상 화면의 device_id를 찾고, Configuration → Audio/Video → Display Device ID에 입력하세요. Windows의 DISPLAY 번호 자체를 입력하면 안 됩니다.'
$null=Add-HeadlessText '화면 구성은 “Ensure active”로 설정하고 저장하세요. 다른 화면을 끄는 “Ensure only display”는 선택하지 마세요. 필요하면 Sunshine을 재시작한 뒤 Mac이나 Windows 클라이언트에서 Desktop에 연결하세요. 장치 설치와 실제 화면 전송 성공은 별도로 확인해야 합니다.'
$null=Add-HeadlessButton 'Sunshine 설정 열기' { try { Start-Process 'https://localhost:47990' } catch { Show-HeadlessFailure $_ } }
$null=Add-HeadlessButton 'Windows 디스플레이 설정 열기' { try { Start-Process 'ms-settings:display' } catch { Show-HeadlessFailure $_ } }
$null=Add-HeadlessButton '상태 새로고침' { Set-HeadlessBusy $true; try { Update-HeadlessState } finally { Set-HeadlessBusy $false } }
$null=Add-HeadlessText '3  필요 없어졌을 때'
$null=Add-HeadlessText '먼저 Sunshine의 Display Device ID를 비우거나 사용할 다른 화면 ID로 바꾸세요. Knot이 만든 가상 화면만 제거합니다. Windows의 드라이버 저장소 캐시는 남으며, Knot 앱을 삭제해도 가상 화면은 유지됩니다.'
$remove=Add-HeadlessButton 'Knot 가상 화면 제거…' {
    if ([Windows.Forms.MessageBox]::Show('Sunshine의 화면 설정을 먼저 변경했나요? 가상 화면을 제거하면 해당 화면의 원격 연결이 끊길 수 있습니다. 다른 접속 수단이 준비되어 있을 때 계속하세요.','Knot','OKCancel','Warning') -ne 'OK') { return }
    Set-HeadlessBusy $true
    try {
        $result=Invoke-HeadlessBroker 'RemoveVirtualDisplay' $null
        Update-HeadlessState
        if ($result -eq 3010) { $status.Text='제거를 마치려면 Windows를 재시작한 뒤 여기에서 제거를 다시 실행하세요. 복구 파일은 유지됩니다.' }
        elseif ($result -ne 0) { $status.Text='제거를 완료하지 못했습니다. 기존 설정을 보존했습니다. 상태를 다시 확인하세요.' }
    } catch { Show-HeadlessFailure $_ }
    finally { Set-HeadlessBusy $false }
}
if (-not $LauncherPath) { $null=Add-HeadlessText '설치와 제거는 배포용 Knot EXE에서만 사용할 수 있습니다. 이 개발자 폴더에서는 상태만 확인합니다.' }
$window.Add_Resize({
    $width=[Math]::Max(220,$content.ClientSize.Width-60)
    foreach ($control in $content.Controls) {
        if ($control -is [Windows.Forms.Label]) { $control.MaximumSize=New-Object Drawing.Size($width,0) }
        elseif ($control -is [Windows.Forms.Button]) { $control.Width=[Math]::Min(340,$width) }
    }
})
$window.Add_FormClosing({ param($sender,$eventArgs) if ($script:headlessBusy) { $eventArgs.Cancel=$true } })
$window.Add_Shown({ Set-HeadlessBusy $true; try { Update-HeadlessState } finally { Set-HeadlessBusy $false } })
Set-HeadlessBusy $false
try { [void]$window.ShowDialog($Owner) } finally { $window.Dispose() }
