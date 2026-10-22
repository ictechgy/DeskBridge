#Requires -Version 5.1
#Requires -RunAsAdministrator
# SPDX-License-Identifier: GPL-3.0-only
# New temporary filesystem fixtures only. No accounts, services, firewall, GUI or live setup state.
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'SetupContract.psm1') -Force
$count=0
function Expect([bool] $Condition,[string] $Message) { if (-not $Condition) { throw $Message }; $script:count++ }
function Reject([scriptblock] $Body,[string] $Message) { $rejected=$false; try {& $Body | Out-Null} catch {$rejected=$true}; Expect $rejected $Message }
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('deskbridge-setup-fixture-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
try {
    $state=Join-Path $fixture 'state'
    [void][IO.Directory]::CreateDirectory($state)
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $admins=New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $acl.SetOwner($admins); $acl.SetAccessRuleProtection($true,$false)
    foreach ($value in @('S-1-5-32-544','S-1-5-18')) {
        $sid=New-Object Security.Principal.SecurityIdentifier($value)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    }
    Set-Acl -LiteralPath $state -AclObject $acl
    $record=@{Schema=2;Phase='Prepared';Marker='synthetic'}
    Write-ManagedRecoveryRecord $state $record
    Expect ((Get-Content -LiteralPath (Join-Path $state 'rollback.json') -Raw | ConvertFrom-Json).Phase -ceq 'Prepared') 'Initial record'
    $record.Phase='Validated'
    Write-ManagedRecoveryRecord $state $record
    $saved=Get-Content -LiteralPath (Join-Path $state 'rollback.json') -Raw | ConvertFrom-Json
    Expect ($saved.Phase -ceq 'Validated' -and $saved.Marker -ceq 'synthetic') 'Atomic replacement record'
    Assert-ProtectedMetadata (Join-Path $state 'rollback.json')
    Assert-ProtectedDirectory $state
    Assert-ProtectedFile (Join-Path $state 'rollback.json')
    Expect $true 'Protected directory and ordinary file accepted'
    Reject {Assert-ProtectedFile $state} 'Directory rejected where protected file is required'
    Reject {Assert-ProtectedDirectory (Join-Path $state 'rollback.json')} 'File rejected where protected directory is required'
    $writable=Join-Path $fixture 'writable'
    [void][IO.Directory]::CreateDirectory($writable)
    $openAcl=New-Object Security.AccessControl.DirectorySecurity
    $openAcl.SetOwner($admins); $openAcl.SetAccessRuleProtection($true,$false)
    $openAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($admins,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    $everyone=New-Object Security.Principal.SecurityIdentifier('S-1-1-0')
    $openAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($everyone,'Modify','ContainerInherit,ObjectInherit','None','Allow')))
    Set-Acl -LiteralPath $writable -AclObject $openAcl
    Reject {Assert-ProtectedDirectory $writable} 'Administrator-owned directory with untrusted write access rejected'
    $child=Join-Path $state 'child'; [void][IO.Directory]::CreateDirectory($child)
    $ordinary=Join-Path $child 'ordinary.txt'; [IO.File]::WriteAllText($ordinary,'synthetic ordinary file')
    Assert-NoReparsePath $child
    Assert-NoReparsePath $ordinary
    Expect $true 'Raw .NET parent traversal accepts nested ordinary directories and files'
    $junction=Join-Path $fixture 'state-alias'
    try {
        New-Item -ItemType Junction -Path $junction -Target $state | Out-Null
        Reject {Assert-ProtectedDirectory (Join-Path $junction 'child')} 'Reparse ancestor rejected on a new synthetic path'
        Reject {Assert-NoReparsePath (Join-Path $junction 'child\ordinary.txt')} 'File traversal also rejects a junction ancestor'
    } finally { if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction,$false) } }
    [IO.File]::Delete($ordinary)
    [IO.Directory]::Delete($child,$false)
    $configFixture=Join-Path $state 'config-fixture'
    [IO.File]::WriteAllText($configFixture,"# DeskBridge dedicated SFTP deployment. Synthetic fixture.`nPort 22`n")
    $fixtureSid=New-Object Security.Principal.SecurityIdentifier('S-1-5-21-111-222-333-1001')
    $configHash=(Get-FileHash -LiteralPath $configFixture -Algorithm SHA256).Hash
    Set-ManagedConfigAcl $configFixture $fixtureSid $configHash
    Assert-ManagedConfig $configFixture $configHash
    Expect $true 'A fresh protected config receives and retains its verified ACL/hash'
    Reject {Set-ManagedConfigAcl $configFixture $fixtureSid ('0'*64)} 'Unknown config content is not adopted while setting its ACL'
    $keyAcl=New-Object Security.AccessControl.FileSecurity
    $keyAcl.SetOwner($admins); $keyAcl.SetAccessRuleProtection($true,$false)
    foreach ($value in @('S-1-5-32-544','S-1-5-18')) {
        $sid=New-Object Security.Principal.SecurityIdentifier($value)
        $keyAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','Allow')))
    }
    Set-Acl -LiteralPath $configFixture -AclObject $keyAcl
    Assert-PrivateHostKey $configFixture
    Expect $true 'Administrator/SYSTEM-only synthetic private key metadata accepted'
    $keyAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($everyone,'Read','Allow')))
    Set-Acl -LiteralPath $configFixture -AclObject $keyAcl
    Reject {Assert-PrivateHostKey $configFixture} 'World-readable synthetic private key metadata rejected'
    Remove-Item -LiteralPath $configFixture -Force
    # Resume rewrites a deserialized PSCustomObject, rather than Enable's hashtable.
    $saved.Phase='Prepared'; Write-ManagedRecoveryRecord $state $saved
    $saved.Phase='Validated'; Write-ManagedRecoveryRecord $state $saved
    Expect ((Get-Content -LiteralPath (Join-Path $state 'rollback.json') -Raw | ConvertFrom-Json).Phase -ceq 'Validated') 'Deserialized Resume record replacement'
    Assert-ProtectedMetadata (Join-Path $state 'rollback.json')
    Expect (@(Get-ChildItem -LiteralPath $state -Force).Count -eq 1) 'No temporary or backup records remain'
    $empty=Join-Path $fixture 'empty'; [void][IO.Directory]::CreateDirectory($empty)
    Remove-NewEmptyDirectory $empty
    Expect (-not (Test-Path -LiteralPath $empty)) 'Empty directory removed'
    $notEmpty=Join-Path $fixture 'not-empty'; [void][IO.Directory]::CreateDirectory($notEmpty)
    $sentinel=Join-Path $notEmpty 'retained.txt'; [IO.File]::WriteAllText($sentinel,'synthetic retained data')
    $rejected=$false
    try { Remove-NewEmptyDirectory $notEmpty } catch { $rejected=$true }
    Expect $rejected 'Nonempty directory refused without prompting'
    Expect ([IO.File]::ReadAllText($sentinel) -ceq 'synthetic retained data') 'Child data retained'
    Remove-NewEmptyDirectory (Join-Path $fixture 'absent')
    Expect $true 'Missing directory is a no-op'
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        $unsupported=Join-Path $fixture 'unsupported-export'
        Reject { Initialize-ConnectionExportDirectory $unsupported } 'Unsupported Core export fails before creating a path'
        Expect (-not (Test-Path -LiteralPath $unsupported)) 'Unsupported Core export has no filesystem mutation'
    } else {
        # Production export requires a protected ancestor. Use ONLY a fresh random fixture,
        # never the real DeskBridgeSetup/DeskBridgeSFTP directories in ProgramData.
        $exportFixture=Join-Path $env:ProgramData ('DeskBridgeExportFixture-'+[Guid]::NewGuid().ToString('N'))
        if (Test-Path -LiteralPath $exportFixture) { throw 'Synthetic fixture already exists.' }
        [void][IO.Directory]::CreateDirectory($exportFixture,$acl)
        try {
            Assert-ProtectedDirectory $exportFixture
            Expect (@([IO.Directory]::EnumerateFileSystemEntries($exportFixture)).Count -eq 0) 'Fresh protected export fixture starts empty'
            $output=Join-Path $exportFixture 'new-output'
            Initialize-ConnectionExportDirectory $output
            $outputAcl=Get-Acl -LiteralPath $output
            Expect ($outputAcl.AreAccessRulesProtected -and $outputAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ceq 'S-1-5-32-544') 'New export receives protected administrator ACL at creation'
            Assert-ProtectedDirectory $output
            $usersRules=@($outputAcl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object {$_.IdentityReference.Value -ceq 'S-1-5-32-545' -and $_.AccessControlType -eq 'Allow'})
            Expect ($usersRules.Count -eq 1 -and ($usersRules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq [Security.AccessControl.FileSystemRights]::ReadAndExecute) 'Standard desktop users retain read access to the public connection result'
            $before=$outputAcl.Sddl
            Initialize-ConnectionExportDirectory $output
            Expect ((Get-Acl -LiteralPath $output).Sddl -ceq $before) 'Safe existing export is validated without changing its ACL'
            $target=Join-Path $output 'connection.json'
            [IO.Directory]::CreateDirectory($target) | Out-Null
            Reject { Initialize-ConnectionExportDirectory $output } 'Existing directory cannot replace the connection result file'
            [IO.Directory]::Delete($target,$false)
            [IO.File]::WriteAllText($target,'synthetic public connection result')
            Assert-ProtectedFile $target
            Initialize-ConnectionExportDirectory $output
            Expect ([IO.File]::ReadAllText($target) -ceq 'synthetic public connection result') 'Safe existing public connection file remains unchanged'
            $badFileAcl=New-Object Security.AccessControl.FileSecurity
            $badFileAcl.SetOwner($admins); $badFileAcl.SetAccessRuleProtection($true,$false)
            $badFileAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($admins,'FullControl','Allow')))
            $badFileAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($everyone,'Modify','Allow')))
            Set-Acl -LiteralPath $target -AclObject $badFileAcl
            $badSddl=(Get-Acl -LiteralPath $target).Sddl
            Reject { Initialize-ConnectionExportDirectory $output } 'Writable existing connection file is rejected'
            Expect ((Get-Acl -LiteralPath $target).Sddl -ceq $badSddl -and [IO.File]::ReadAllText($target) -ceq 'synthetic public connection result') 'Rejected connection file is never repaired or overwritten'
            Remove-Item -LiteralPath $target -Force
            $untrusted=Join-Path $exportFixture 'writable-output'
            [IO.Directory]::CreateDirectory($untrusted,$openAcl) | Out-Null
            $badSddl=(Get-Acl -LiteralPath $untrusted).Sddl
            Reject { Initialize-ConnectionExportDirectory $untrusted } 'Administrator-owned writable output is not adopted'
            Expect ((Get-Acl -LiteralPath $untrusted).Sddl -ceq $badSddl) 'Rejected writable output ACL remains unchanged'
            $untrustedChild=Join-Path $untrusted 'child-output'
            Reject { Initialize-ConnectionExportDirectory $untrustedChild } 'Writable ancestor cannot rename a protected export'
            Expect (-not (Test-Path -LiteralPath $untrustedChild)) 'Unsafe ancestor is rejected before child creation'
            $alias=Join-Path $exportFixture 'output-alias'
            try {
                New-Item -ItemType Junction -Path $alias -Target $output | Out-Null
                Reject { Initialize-ConnectionExportDirectory $alias } 'Junction output is not adopted'
                Reject { Initialize-ConnectionExportDirectory (Join-Path $alias 'child') } 'Junction ancestor is rejected before creation'
            } finally { if (Test-Path -LiteralPath $alias) { [IO.Directory]::Delete($alias,$false) } }
        } finally {
            # Only this invocation's random synthetic ProgramData fixture is removed.
            if (Test-Path -LiteralPath $exportFixture) { Remove-Item -LiteralPath $exportFixture -Recurse -Force }
        }
    }

} finally {
    # Cleanup is restricted to this invocation's random synthetic fixture.
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
@{status='passed';checks=$count;scope='fresh synthetic record/export ACL and path refusal, replacement and nonrecursive deletion only; no accounts/services/firewall'} | ConvertTo-Json
