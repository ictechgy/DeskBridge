#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# The UI is non-elevated. Only explicit installation/file actions ask Windows for UAC.
[CmdletBinding()]
param([string] $LauncherPath)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SetupContract.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ConnectionInvitation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SetupDownload.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
try { Assert-DesktopSetupToken } catch {
    [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Knot','OK','Error') | Out-Null
    return
}
if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or [Environment]::OSVersion.Version.Build -lt 22000) {
    [Windows.Forms.MessageBox]::Show('이 프리뷰는 Windows 11 x64에서 사용할 수 있습니다. PC의 Windows 버전과 시스템 종류를 확인하세요.','Knot','OK','Error') | Out-Null
    exit 3
}
$form = New-Object Windows.Forms.Form
$form.Text = 'Knot · Windows 연결'; $form.Size = New-Object Drawing.Size(780,760)
$form.MinimumSize = New-Object Drawing.Size(640,480); $form.StartPosition = 'CenterScreen'
$form.AutoScaleDimensions=New-Object Drawing.SizeF(96,96); $form.AutoScaleMode='Dpi'
$form.Font = New-Object Drawing.Font('Segoe UI',10)
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'AppIcon.ico') -PathType Leaf) {
    $form.Icon=New-Object Drawing.Icon((Join-Path $PSScriptRoot 'AppIcon.ico'))
}
$flow = New-Object Windows.Forms.FlowLayoutPanel
$flow.Dock = 'Fill'; $flow.FlowDirection = 'TopDown'; $flow.WrapContents = $false; $flow.AutoScroll = $true
$flow.Padding = New-Object Windows.Forms.Padding(20)
$layout=New-Object Windows.Forms.TableLayoutPanel
$layout.Dock='Fill'; $layout.ColumnCount=1; $layout.RowCount=2
[void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',84)))
$form.Controls.Add($layout)
$layout.Controls.Add($flow,0,0)
$script:section=$flow
function Add-Text([string] $Text,[int] $Height=40) {
    $label = New-Object Windows.Forms.Label; $label.Text=$Text; $label.AutoSize=$true
    $label.MinimumSize=New-Object Drawing.Size(0,$Height); $label.MaximumSize=New-Object Drawing.Size(710,0)
    $script:section.Controls.Add($label); return $label
}
function Add-Button([string] $Text,[scriptblock] $Action) {
    $button=New-Object Windows.Forms.Button; $button.Text=$Text; $button.Size=New-Object Drawing.Size(330,34)
    $button.Add_Click($Action); $script:section.Controls.Add($button); return $button
}
$title = Add-Text 'Windows를 Mac의 한 화면으로' 38
$title.Font = New-Object Drawing.Font('Segoe UI',17,[Drawing.FontStyle]::Bold)
$null = Add-Text '먼저 화면부터 연결하세요. 파일 전송은 나중에 추가할 수 있습니다.' 32
$status=New-Object Windows.Forms.TextBox
$status.ReadOnly=$true; $status.Multiline=$true; $status.ScrollBars='Vertical'; $status.BorderStyle='None'; $status.BackColor=[Drawing.SystemColors]::Control
$status.Text='시작하려면 아래 Sunshine 설치를 누르세요.'
$status.Dock='Fill'
$status.Margin=New-Object Windows.Forms.Padding(20,8,20,8)
$layout.Controls.Add($status,0,1)
$status.ForeColor=[Drawing.SystemColors]::HotTrack
function Show-Failure($ErrorRecord) {
    $cause=$ErrorRecord.Exception
    while ($cause) {
        if ($cause -is [ComponentModel.Win32Exception] -and $cause.NativeErrorCode -eq 1223) {
            $status.Text='관리자 확인을 취소했습니다. 필요할 때 다시 시작하세요.'
            return
        }
        $cause=$cause.InnerException
    }
    $message=[string]$ErrorRecord.Exception.Message
    if ($message -notmatch '[가-힣]') { $message='Windows 설정을 완료하지 못했습니다. 네트워크와 관리자 권한을 확인하세요. 기존 OpenSSH 설정이나 조직의 보안 정책이 있으면 수동 통합·승인된 배포 안내를 사용하세요.' }
    $status.Text='완료하지 못했습니다. ' + $message
    [Windows.Forms.MessageBox]::Show($message,'Knot','OK','Error') | Out-Null
}
function Get-SetupControls($Root) {
    foreach ($control in $Root.Controls) { $control; Get-SetupControls $control }
}
function Set-Busy([bool] $Busy) {
    foreach ($control in (Get-SetupControls $flow)) {
        if ($control -is [Windows.Forms.Button] -or $control -is [Windows.Forms.ComboBox]) { $control.Enabled = -not $Busy }
    }
    $form.UseWaitCursor=$Busy
}
$null = Add-Text '1   화면 연결 프로그램 설치' 30
$null = Add-Text 'Sunshine이 Windows 화면을 Mac으로 전달합니다. 이미 설치했다면 다음 단계로 가세요.' 36
$install = Add-Button 'Sunshine 설치' {
    Set-Busy $true; $folder=$null; $download=$null; $verifiedDownload=$null
    try {
        $dep=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'SunshineDependency.json') -Raw | ConvertFrom-Json
        if ($dep.url -notmatch '^https://github\.com/LizardByte/Sunshine/releases/download/v[0-9.]+/Sunshine-Windows-AMD64-installer\.msi$' -or $dep.sha256 -notmatch '^[0-9a-f]{64}$' -or ($dep.bytes -isnot [int] -and $dep.bytes -isnot [long]) -or $dep.bytes -lt 1 -or $dep.bytes -gt 268435456) { throw 'Sunshine 설치 파일 정보가 올바르지 않습니다. 새 Knot 배포 파일을 사용하세요.' }
        $status.Text='Sunshine 공식 설치 파일을 내려받는 중…'; [Windows.Forms.Application]::DoEvents()
        $folder=Join-Path ([IO.Path]::GetTempPath()) ('DeskBridgeDownload-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        $file=Join-Path $folder 'Sunshine.msi'
        $download=Start-SetupDownload -Url $dep.url -Path $file -ExpectedBytes $dep.bytes
        $downloadCancel.Visible=$true; $downloadCancel.Enabled=$true; $script:cancelDownload=$false
        while (-not $download.Completion.IsCompleted) {
            [Windows.Forms.Application]::DoEvents()
            if ($script:cancelDownload) { $download.Cancel(); $downloadCancel.Enabled=$false }
            $status.Text='Sunshine 공식 설치 파일을 내려받는 중… ' + [Math]::Min(100,[Math]::Floor(100.0*$download.Bytes/$dep.bytes)) + '%'
            Start-Sleep -Milliseconds 80
        }
        $download.Completion.GetAwaiter().GetResult()
        $downloadCancel.Visible=$false; $downloadCancel.Enabled=$false
        # Keep this data snapshot locked for the developer-folder fallback too.
        $verifiedDownload=[IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $digest=[BitConverter]::ToString($sha.ComputeHash($verifiedDownload)).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
        if ($verifiedDownload.Length -ne $dep.bytes -or $digest -cne $dep.sha256) { throw 'Sunshine 설치 파일 검증에 실패했습니다. 실행하지 않았습니다. 새로 다운로드해 다시 시도하세요.' }
        $status.Text='공식 Sunshine 설치 안내를 완료하세요. 유료 게임패드 드라이버는 업무용 연결에 필요하지 않습니다.'
        if ($LauncherPath) {
            # The native elevated broker makes and verifies its own protected copy against its embedded pin.
            $installExecutable=$LauncherPath
            $installArguments='--elevated-operation InstallSunshine --msi-path "' + $file + '"'
        } else {
            # Explicit raw developer-folder workflow: the held read handle excludes writes/deletes until exit.
            $installExecutable=Join-Path $env:WINDIR 'System32\msiexec.exe'
            $installArguments='/i "' + $file + '"'
        }
        $process=Start-Process -FilePath $installExecutable -Verb RunAs -ArgumentList $installArguments -PassThru
        $null=$process.Handle
        while (-not $process.HasExited) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
        $process.WaitForExit()
        if ($LauncherPath -and $process.ExitCode -eq 2) { $status.Text='설치를 완료하지 못했습니다. 표시된 오류 안내를 확인한 뒤 다시 시도하세요.'; return }
        if ($process.ExitCode -eq 1602) { $status.Text='Sunshine 설치를 취소했습니다. 필요할 때 다시 시작하세요.'; return }
        if ($null -eq $process.ExitCode -or $process.ExitCode -notin @(0,3010)) { throw 'Sunshine 설치를 완료하지 못했습니다. Windows 설치 안내와 네트워크를 확인한 뒤 다시 시도하세요.' }
        if ($process.ExitCode -eq 3010) { $status.Text='설치를 완료하려면 Windows를 다시 시작해야 합니다. 재시작한 뒤 Sunshine 초기 설정을 진행하세요.'; return }
        $status.Text='설치 완료. 다음은 Sunshine 초기 설정입니다.'
        $install.Text='Sunshine 다시 설치'
        Start-Process 'https://localhost:47990'
    } catch [OperationCanceledException] { $status.Text='Sunshine 다운로드를 취소했습니다. 필요할 때 다시 시작하세요.' }
    catch { Show-Failure $_ }
    finally {
        $downloadCancel.Visible=$false
        try {
            if ($verifiedDownload) { $verifiedDownload.Dispose() }
            if ($download) {
                $download.Cancel()
                while (-not $download.Completion.IsCompleted) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 80 }
                $download.Dispose()
            }
            if ($folder -and (Test-Path -LiteralPath $folder)) {
                try { Remove-Item -LiteralPath $folder -Recurse -Force }
                catch { $status.Text='임시 다운로드 파일을 정리하지 못했습니다. 설정은 다시 시도하거나 창을 닫을 수 있습니다.' }
            }
        } finally { Set-Busy $false }
    }
}
$downloadCancel=Add-Button '다운로드 취소' { $script:cancelDownload=$true }; $downloadCancel.Visible=$false
$null = Add-Text '2   Sunshine 초기 설정 · 처음 한 번' 30
$null = Add-Text "설정 창에서 계정을 만들고, Configuration → Network에서 LAN/WAN 암호화를 모두 Mandatory로 저장하세요. Desktop 앱도 확인하세요.`r`n이 계정은 Windows의 Sunshine 설정용입니다. Mac에서 로그인하지 않습니다." 66
$open = Add-Button 'Sunshine 설정 열기' { try { Start-Process 'https://localhost:47990' } catch { Show-Failure $_ } }
$headless = Add-Button '모니터 없이 사용… (선택)' {
    Set-Busy $true
    try { & (Join-Path $PSScriptRoot 'Show-HeadlessSetup.ps1') -Owner $form -LauncherPath $LauncherPath }
    catch { Show-Failure $_ }
    finally { Set-Busy $false }
}
$null = Add-Text '3   Mac에서 연결' 30
$null = Add-Text 'Mac의 원격 화면에서 근처 PC를 선택하세요. 목록에 없으면 연결 QR / 링크로 가져올 수 있습니다.' 40
$qrButton = Add-Button '연결 QR / 링크 보기…' {
    Set-Busy $true
    try {
        if (-not $addresses.SelectedItem) { throw '먼저 Wi-Fi 또는 Tailscale에 연결한 뒤 주소를 새로고침하세요.' }
        $items=@([string]$addresses.SelectedItem) + @($addresses.Items | ForEach-Object { [string]$_ })
        $unique=@($items | Select-Object -Unique)
        $chosen=@($unique | Select-Object -First 8)
        if ($unique.Count -gt 8) { $status.Text='연결 QR에 선택한 주소를 포함한 8개를 넣었습니다. 나머지 ' + ($unique.Count-8) + '개는 주소 목록에서 선택한 뒤 QR을 다시 만드세요.' }
        $link=New-DeskBridgeConnectionLink -PCName $env:COMPUTERNAME -Address $chosen
        & (Join-Path $PSScriptRoot 'Show-ConnectionQR.ps1') -Link $link -Owner $form
    } catch { Show-Failure $_ }
    finally { Set-Busy $false }
}
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'DeskBridge-QR.dll') -PathType Leaf)) { $qrButton.Text='연결 링크 보기…' }
$null = Add-Text 'PIN은 Mac에 표시됩니다. Sunshine의 PIN 메뉴에 입력하면 화면 페어링이 진행됩니다. Wi-Fi 또는 Tailscale 양쪽에서 도달 가능한 주소를 선택하세요.' 48
$addresses=New-Object Windows.Forms.ComboBox; $addresses.AccessibleName='이 PC의 연결 주소'; $addresses.DropDownStyle='DropDownList'; $addresses.Width=710
function Update-WindowsAddresses {
    $previous=[string]$addresses.SelectedItem
    $addresses.Items.Clear()
    foreach ($item in (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Sort-Object InterfaceMetric,IPAddress)) {
        try {
            $ip=Get-PrivateIPv4 $item.IPAddress
            if ($ip.StartsWith('169.254.') -or [string]$item.AddressState -ne 'Preferred' -or [string]$item.InterfaceAlias -like 'vEthernet*') { continue }
            if (-not $addresses.Items.Contains($ip)) { [void]$addresses.Items.Add($ip) }
        } catch {}
    }
    if ($addresses.Items.Contains($previous)) { $addresses.SelectedItem=$previous }
    elseif ($addresses.Items.Count -gt 0) { $addresses.SelectedIndex=0 }
}
$flow.Controls.Add($addresses)
Update-WindowsAddresses
$copy = Add-Button '선택한 Windows 주소 복사' {
    if ($addresses.SelectedItem) {
        try { [Windows.Forms.Clipboard]::SetText([string]$addresses.SelectedItem); $status.Text='주소를 복사했습니다. Mac의 원격 화면 탭에 입력하세요.' }
        catch { Show-Failure $_ }
    } else { $status.Text='연결 가능한 주소가 없습니다. Wi-Fi 또는 Tailscale에 연결한 뒤 주소를 새로고침하세요.' }
}
$refresh = Add-Button '주소 새로고침' { try { Update-WindowsAddresses } catch { Show-Failure $_ } }
$filesToggle = Add-Button '＋ 파일 전송도 설정하기 (선택)' {}
$filePanel=New-Object Windows.Forms.FlowLayoutPanel
$filePanel.FlowDirection='TopDown'; $filePanel.WrapContents=$false; $filePanel.AutoSize=$true
$filePanel.AutoSizeMode='GrowAndShrink'; $filePanel.Width=710; $filePanel.Visible=$false
$flow.Controls.Add($filePanel)
$filesToggle.Add_Click({
    $filePanel.Visible=-not $filePanel.Visible
    $filesToggle.Text=if ($filePanel.Visible) {'－ 파일 전송 설정 접기'} else {'＋ 파일 전송도 설정하기 (선택)'}
    if ($filePanel.Visible) { $flow.ScrollControlIntoView($filePanel) }
})
$script:section=$filePanel
$null = Add-Text '파일 전송 · 필요할 때 한 번' 30
$null = Add-Text '화면 연결에는 아래 설정이 필요 없습니다. 파일 기능은 Mac 전용 키와 별도의 Windows 파일 계정을 사용합니다.' 42
$null = Add-Text 'Mac의 파일 탭에서 키 만들기 → Mac 주소 찾기 → Windows 설정 파일 저장. 저장한 JSON을 이 PC로 옮겨 불러오세요.' 48
$requestBox = New-Object Windows.Forms.TextBox; $requestBox.ReadOnly=$true; $requestBox.Width=710; $filePanel.Controls.Add($requestBox)
$load = Add-Button 'Mac 설정 파일 불러오기…' {
    try {
        $dialog=New-Object Windows.Forms.OpenFileDialog; $dialog.Filter='Knot JSON (*.json)|*.json'
        if ($dialog.ShowDialog() -eq 'OK') {
            try { $request=Read-MacSetup $dialog.FileName } catch { throw 'Mac 설정 파일의 형식이나 공개 키·허용 주소를 확인하지 못했습니다. Mac의 파일 탭에서 새 설정 JSON을 저장해 다시 불러오세요.' }
            $requestBox.Text=$dialog.FileName
            $status.Text='허용할 Mac: ' + ($request.allowedClientAddresses -join ', ') + '. 파일 설정은 새 전용 계정과 공유 폴더를 만듭니다.'
        }
        $dialog.Dispose()
    } catch { $requestBox.Text=''; Show-Failure $_ }
}
function Invoke-FileSetup([string] $Operation) {
    Set-Busy $true
    try {
        $expected=$null; $requestPath=$null; $selectedAddress=$null
        if ($Operation -ne 'DisableFiles') {
            $requestPath=[string]$requestBox.Text
            if ([string]::IsNullOrWhiteSpace($requestPath)) { throw '먼저 Mac 설정 파일을 불러오세요.' }
            try { $expected=Read-MacSetup $requestPath } catch { throw 'Mac 설정 파일을 읽지 못했습니다. Mac에서 새로 저장한 JSON 파일을 불러오세요.' }
            if (-not $addresses.SelectedItem) { throw 'Windows 주소를 선택하세요.' }
            $selectedAddress=Get-PrivateIPv4 ([string]$addresses.SelectedItem)
        }
        $desktopUser=$null
        if ($Operation -eq 'EnableFiles') {
            # Capture THIS non-elevated user's SID before UAC, including alternate-admin credentials.
            $desktopUser=Resolve-DesktopUser ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        }
        $message=if ($Operation -eq 'DisableFiles') {'파일 접속을 해제하고 현재 파일 연결을 종료합니다. 공유 파일은 보존됩니다.'} elseif ($Operation -eq 'EnableFiles') {
            'OpenSSH Server, 전용 일반 계정, C:\DeskBridgeShare\files, 선택한 Mac 주소 전용 방화벽을 설정합니다. 공유 파일을 사용할 Windows 사용자: ' + $desktopUser.Name + ' (' + $desktopUser.SID.Value + '). 기존 SSH 설정은 바꾸지 않습니다. 계속할까요?'
        } else {'Windows 호스트 공개 키를 내보내기 위해 관리자 확인이 필요합니다.'}
        if ([Windows.Forms.MessageBox]::Show($message,'Knot','OKCancel','Information') -ne 'OK') { return }
        if ($LauncherPath) {
            $elevatedExecutable=$LauncherPath
            $arguments='--elevated-operation ' + $Operation
            if ($Operation -ne 'DisableFiles') {
                # Freeze only validated PUBLIC data; no user-owned script or request-file path crosses UAC.
                $requestJson=$expected | ConvertTo-Json -Depth 4 -Compress
                $requestBytes=[Text.Encoding]::UTF8.GetBytes($requestJson)
                if ($requestBytes.Length -gt 16384) { throw 'Setup request is too large.' }
                $arguments += ' --request-base64 ' + [Convert]::ToBase64String($requestBytes) + ' --windows-address ' + $selectedAddress
            }
            if ($desktopUser) { $arguments += ' --desktop-user-sid ' + $desktopUser.SID.Value }
        } else {
            # Source/developer folders are a manual script workflow, outside the primary EXE broker.
            if ([Windows.Forms.MessageBox]::Show('개발자 폴더의 PowerShell 스크립트를 관리자 권한으로 실행합니다. 배포용 Knot EXE를 사용하는 것이 좋습니다. 계속할까요?','Knot · 수동 개발자 설정','OKCancel','Warning') -ne 'OK') { return }
            $elevatedExecutable=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $script=Join-Path $PSScriptRoot 'Invoke-DeskBridgeSetup.ps1'
            $arguments='-NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "' + $script + '" -Operation ' + $Operation
            if ($Operation -ne 'DisableFiles') { $arguments += ' -RequestPath "' + $requestPath + '" -WindowsAddress "' + $selectedAddress + '"' }
            if ($desktopUser) { $arguments += ' -DesktopUserSid "' + $desktopUser.SID.Value + '"' }
        }
        $status.Text='관리자 창에서 설정을 진행 중입니다. 완료 후 이 창으로 돌아오세요.'
        $process=Start-Process -FilePath $elevatedExecutable -Verb RunAs -ArgumentList $arguments -PassThru
        $null=$process.Handle
        # Keep the non-elevated form repainting while the separate administrator window works.
        while (-not $process.HasExited) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
        $process.WaitForExit()
        if ($LauncherPath -and $process.ExitCode -eq 2) { $status.Text='설정을 완료하지 못했습니다. 표시된 오류 안내를 확인한 뒤 다시 시도하세요.'; return }
        if ($null -eq $process.ExitCode -or $process.ExitCode -ne 0) { throw '설정을 완료하지 못했습니다. 관리자 창의 오류를 확인하세요. 기존 SSH가 있다면 수동 통합 안내를 사용하세요.' }
        if (-not $LauncherPath) { $status.Text='수동 설정 명령이 종료되었습니다. Ctrl+C로 중단해도 성공 코드가 반환될 수 있으므로 관리자 창과 실제 설정에서 완료 여부를 확인하세요. 자동 완료 확인과 연결 파일 저장은 배포용 EXE를 사용하세요.'; return }
        if ($Operation -eq 'DisableFiles') { $status.Text='파일 접속을 해제했습니다. 공유 파일은 유지됩니다.'; return }
        $replyPath=Join-Path $env:ProgramData 'DeskBridgeSetup\connection.json'
        $reply=Get-Content -LiteralPath $replyPath -Raw | ConvertFrom-Json
        if ($reply.requestID -cne $expected.requestID -or $reply.clientPublicKey -cne $expected.clientPublicKey -or $reply.address -cne $selectedAddress) { throw 'Windows 연결 결과가 현재 Mac 설정과 다릅니다. 설정 파일과 선택한 PC 주소를 다시 확인하세요.' }
        $fingerprint=Get-KeyFingerprint $reply.serverPublicKey
        $status.Text="Windows SSH 지문 (Mac 화면과 비교):`r`n" + $fingerprint
        $save=New-Object Windows.Forms.SaveFileDialog; $save.Filter='Knot JSON (*.json)|*.json'; $save.FileName='Knot-Windows-Connection.json'
        $saved=Save-DeskBridgeConnectionReply -Reply $reply -Dialog $save
        if ($saved -eq 'Saved') { $status.Text+="`r`n연결 파일을 저장했습니다. Mac에서 불러오세요." }
        else {
            $detail=if ($saved -eq 'Cancelled') {'연결 파일 저장을 취소했습니다.'} else {'연결 파일을 저장하지 못했습니다.'}
            $status.Text="파일 설정 완료 · " + $detail + "`r`nWindows SSH 지문: " + $fingerprint + "`r`n‘이미 설정한 연결 파일 다시 저장’으로 다시 저장하세요. 설정을 다시 설치할 필요가 없습니다."
        }
    } catch { Show-Failure $_ }
    finally { Set-Busy $false }
}
$enable = Add-Button '파일 전송 설정 · 연결 파일 만들기…' { Invoke-FileSetup 'EnableFiles' }
$export = Add-Button '이미 설정한 연결 파일 다시 저장…' { Invoke-FileSetup 'Export' }
$disable = Add-Button '이 Windows의 파일 접속 해제…' { Invoke-FileSetup 'DisableFiles' }
$null = Add-Text '저장한 Windows 연결 파일을 Mac에서 불러오고, 표시된 SSH 지문이 같은지 직접 비교하세요. 공유 폴더: C:\DeskBridgeShare\files' 50
function Resize-SetupContent {
    $available=[Math]::Max(280,$flow.ClientSize.Width-$flow.Padding.Horizontal-[Windows.Forms.SystemInformation]::VerticalScrollBarWidth-12)
    $filePanel.Width=$available
    foreach ($control in (Get-SetupControls $flow)) {
        if ($control -is [Windows.Forms.Label]) { $control.MaximumSize=New-Object Drawing.Size($available,0) }
        elseif ($control -is [Windows.Forms.TextBox] -or $control -is [Windows.Forms.ComboBox]) { $control.Width=$available }
        elseif ($control -is [Windows.Forms.Button]) { $control.Width=[Math]::Min([int][Math]::Round(330*$form.DeviceDpi/96.0),$available) }
    }
}
$flow.Add_SizeChanged({ Resize-SetupContent })
$form.Add_Shown({
    $area=[Windows.Forms.Screen]::FromControl($form).WorkingArea
    $form.MinimumSize=New-Object Drawing.Size([Math]::Min($form.MinimumSize.Width,$area.Width),[Math]::Min($form.MinimumSize.Height,$area.Height))
    $form.Size=New-Object Drawing.Size([Math]::Min($form.Width,$area.Width),[Math]::Min($form.Height,$area.Height))
    $form.Location=New-Object Drawing.Point(($area.Left+($area.Width-$form.Width)/2),($area.Top+($area.Height-$form.Height)/2))
    Resize-SetupContent
})
$form.Add_FormClosing({param($sender,$eventArgs) if ($form.UseWaitCursor) {$eventArgs.Cancel=$true}})
[void]$form.ShowDialog()
$form.Dispose()
