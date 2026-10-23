#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
param([string] $BootstrapPolicyRunner)
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'HeadlessStatus.psm1') -Force
$count=0
function Check([bool] $Condition,[string] $Message) { if (-not $Condition) { throw $Message }; $script:count++ }
foreach ($state in @('Unsupported','DeviceIdentityUnavailable','BootEvidenceUnavailable','Absent','Installed','InstalledPendingRestart','RemovalPending','LegacyRecoveryRequired','RecoveryRequired','Conflict','unknown','installed','')) {
    $text=Get-KnotHeadlessStatusText $state
    Check (-not [string]::IsNullOrWhiteSpace($text)) ('Missing state text: '+$state)
}
Check ((Get-KnotHeadlessStatusText 'LegacyRecoveryRequired') -match '관리자') 'Legacy pending must require manual recovery'
Check ((Get-KnotHeadlessStatusText 'InstalledPendingRestart') -match '재시작') 'Successful install must retain restart notice'
foreach ($operation in @('InstallVirtualDisplay','RemoveVirtualDisplay')) {
    foreach ($code in @(0,12,13,3010,2,1,1602)) {
        $text=Get-KnotHeadlessOperationText $operation $code
        Check (-not [string]::IsNullOrWhiteSpace($text)) 'Missing operation notice'
        if ($code -eq 13) { Check ($text -match '관리자' -and $text -match '반복') 'Blocked recovery must require investigation instead of another restart' }
        if ($code -eq 12) { Check ($text -match '완료하지 못|완료되지') 'Pending recovery must not claim completed installation/removal' }
        if ($code -eq 3010 -and $operation -ceq 'RemoveVirtualDisplay') { Check ($text -match '완료하지 못') 'Unexpected completed-removal restart must not attest success' }
    }
}
# Execute only the real wrapper's receipt helper and try/catch in a fresh child.
# Backend calls are inert, no Requires/elevation/import/device APIs are executed.
$wrapper=Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-DeskBridgeHeadless.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($wrapper,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Wrapper parse failed' }
$helper=@($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq 'Write-HeadlessReceipt' })
$body=@($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
if ($helper.Count -ne 1 -or $body.Count -ne 1) { throw 'Wrapper test requires exact production helper and body' }
$runner=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$root=Join-Path ([IO.Path]::GetTempPath()) ('knot-headless-status-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    $cases=@(
        @{Status='Installed';Completed=$true;Reboot=$false;Code=0;Receipts=@('operation-success')},
        @{Status='InstalledPendingRestart';Completed=$true;Reboot=$true;Code=3010;Receipts=@('operation-success','reboot-required')},
        @{Status='RemovalPending';Completed=$false;Reboot=$true;Code=12;Receipts=@('reboot-required')},
        @{Status='LegacyRecoveryRequired';Completed=$false;Reboot=$false;Code=13;Receipts=@('recovery-blocked')},
        @{Status='BootEvidenceUnavailable';Completed=$false;Reboot=$false;Code=13;Receipts=@('recovery-blocked')},
        @{Status='DeviceIdentityUnavailable';Completed=$false;Reboot=$false;Code=13;Receipts=@('recovery-blocked')},
        @{Status='LegacyRecoveryRequired';Completed=$false;Reboot=$true;Code=1;Receipts=@()},
        @{Status='RecoveryRequired';Completed=$false;Reboot=$false;Code=1;Receipts=@()}
    )
    foreach ($case in $cases) {
        $directory=Join-Path $root ([Guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($directory)
        $fixture=[pscustomobject]@{Status=$case.Status;Completed=$case.Completed;RebootRequired=$case.Reboot} | ConvertTo-Json -Compress
        $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($fixture))
        $prefix='$ErrorActionPreference="Stop"; $SuccessReceipt=$true; $NoPause=$true; $Operation="RemoveVirtualDisplay"; $script:FixtureResult=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("'+$encoded+'")) | ConvertFrom-Json; function Install-KnotVirtualDisplay { return $script:FixtureResult }; function Remove-KnotVirtualDisplay { return $script:FixtureResult }'
        $path=Join-Path $directory 'synthetic-wrapper.ps1'
        [IO.File]::WriteAllText($path,($prefix+[Environment]::NewLine+$helper[0].Extent.Text+[Environment]::NewLine+$body[0].Extent.Text),(New-Object Text.UTF8Encoding($true)))
        $output=@(& $runner -NoLogo -NoProfile -NonInteractive -File $path)
        $actualExit=$LASTEXITCODE; $expectedExit=$case.Code
        if ([IO.Path]::DirectorySeparatorChar -ne [char]92) { $expectedExit=$expectedExit -band 255 }
        Check ($actualExit -eq $expectedExit) ('Wrapper exit mismatch for '+$case.Status+': '+$actualExit)
        foreach ($name in @('operation-success','reboot-required','recovery-blocked')) {
            $receipt=Join-Path $directory $name; $exists=[IO.File]::Exists($receipt)
            Check ($exists -eq ($name -cin $case.Receipts) -and (-not $exists -or (Get-Item -LiteralPath $receipt).Length -eq 0)) ('Wrapper receipt mismatch: '+$case.Status+'/'+$name)
        }
        if ($BootstrapPolicyRunner) {
            $policyInput=$actualExit
            if ([IO.Path]::DirectorySeparatorChar -ne [char]92 -and $actualExit -eq (3010 -band 255) -and $case.Code -eq 3010) { $policyInput=3010 }
            $policyOutput=@(& $BootstrapPolicyRunner --headless-result RemoveVirtualDisplay $policyInput)
            if ($LASTEXITCODE -ne 0 -or $policyOutput.Count -ne 1) { throw 'Compiled outer bootstrap policy returned no result' }
            $policy=$policyOutput[0] | ConvertFrom-Json
            $expectedFinal=$case.Code; if ($expectedFinal -eq 1) { $expectedFinal=2 }
            Check ($policy.exitCode -eq $expectedFinal) ('Actual wrapper result lost at compiled native boundary: '+$case.Status)
            Check ($policy.showFailure -is [bool] -and $policy.showFailure -eq ($case.Code -eq 1)) ('Native boundary showed unexpected generic guidance: '+$case.Status)
        }
    }
} finally { [IO.Directory]::Delete($root,$true) }
[pscustomobject]@{status='passed';checks=$count;freshSyntheticOnly=$true;nativeApisInvoked=$false;bootstrapPolicyComposed=[bool]$BootstrapPolicyRunner} | ConvertTo-Json -Compress
