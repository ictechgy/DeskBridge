#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Runs only pure production functions and newly generated synthetic fixtures.
# No registry, device, network, driver installation, or actual user configuration access.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$modulePath=Join-Path (Split-Path $PSScriptRoot -Parent) 'HeadlessSetup.psm1'
Import-Module $modulePath -Force
$module=Get-Module HeadlessSetup
$script:Checks=0
function Assert([bool] $Condition,[string] $Message) { if (-not $Condition) { throw $Message }; $script:Checks++ }
function Reject([scriptblock] $Action,[string] $Message) { $rejected=$false; try { & $Action | Out-Null } catch { $rejected=$true }; Assert $rejected $Message }
function Hash([byte[]] $Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('knot-headless-test-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$names=@('VirtualDisplayDriver/mttvdd.cat','VirtualDisplayDriver/MttVDD.dll','VirtualDisplayDriver/MttVDD.inf','VirtualDisplayDriver/vdd_settings.xml')
$files=@()
foreach ($name in $names) { $bytes=[Text.Encoding]::UTF8.GetBytes(('synthetic-'+$name)); $files += [pscustomobject]@{path=$name;bytes=$bytes.Length;sha256=(Hash $bytes);content=$bytes} }
$inventory=[pscustomobject]@{schema=1;files=@($files | ForEach-Object { [pscustomobject]@{path=$_.path;bytes=$_.bytes;sha256=$_.sha256} })}
Add-Type -AssemblyName System.IO.Compression
function Make-Zip([object[]] $Entries,[string] $Suffix) {
    $path=Join-Path $root ($Suffix+'.zip')
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew)
    $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
    try {
        foreach ($entry in $Entries) {
            $member=$zip.CreateEntry($entry.path,[IO.Compression.CompressionLevel]::Optimal)
            if ($entry.PSObject.Properties['attributes']) { $member.ExternalAttributes=$entry.attributes }
            $output=$member.Open()
            try { $output.Write($entry.content,0,$entry.content.Length) } finally { $output.Dispose() }
        }
    } finally { $zip.Dispose(); $stream.Dispose() }
    return $path
}
function Pin([string] $Path) { $bytes=[IO.File]::ReadAllBytes($Path); return [pscustomobject]@{bytes=$bytes.Length;sha256=(Hash $bytes)} }
function Make-Operations([object] $State,[string] $FailAfter,[bool] $CleanupFails=$false) {
    $mutate={ param($name) [void]$State.events.Add($name); if ($name -ceq $FailAfter) { throw ('synthetic fault after '+$name) } }.GetNewClosure()
    return @{
        Preflight={ param($j) if ($State.foreign) { throw 'synthetic foreign resource' } }.GetNewClosure()
        Prepare={ param($j) $State.record=$true; & $mutate 'journal'; $State.files=$true; & $mutate 'files' }.GetNewClosure()
        Configure={ param($j) if (-not $State.record) { throw 'registry before journal' }; $State.registry=$true; & $mutate 'registry' }.GetNewClosure()
        Create={ param($j) if (-not $State.record) { throw 'device before journal' }; $State.instance=$j.instanceId; & $mutate 'device' }.GetNewClosure()
        Install={ param($j) & $mutate 'driver'; return $State.reboot }.GetNewClosure()
        Verify={ param($j) if ($State.instance -cne $j.instanceId) { throw 'wrong instance' }; & $mutate 'verify' }.GetNewClosure()
        Commit={ param($j,$reboot) & $mutate 'commit' }.GetNewClosure()
        HasJournal={ param($j) return $State.record }.GetNewClosure()
        Cleanup={ param($j)
            [void]$State.events.Add('cleanup')
            if ($CleanupFails) { throw 'synthetic cleanup failure' }
            if ($State.instance -and $State.instance -cne $j.instanceId) { throw 'refuse other instance' }
            if ($State.cleanupReboot) { return [pscustomobject]@{Completed=$false;RebootRequired=$true} }
            $State.removed=$State.instance; $State.instance=$null; $State.files=$false; $State.registry=$false; $State.record=$false
            return [pscustomobject]@{Completed=$true;RebootRequired=$false}
        }.GetNewClosure()
    }
}
function New-TestState {
    return [pscustomobject]@{events=(New-Object 'Collections.Generic.List[string]');record=$false;files=$false;registry=$false;instance=$null;removed=$null;foreign=$false;reboot=$false;cleanupReboot=$false;removeEvenOnReboot=$false;boot='boot:2026-01-01T00:00:00.0000000Z';saved=$null}
}
function New-RemovalJournal { return [pscustomobject]@{instanceId=('ROOT\KNOTVDD\'+('A'*32));driverVersion='11.30.4.434';removalPending=$false;removalPhase='None';removalBootId='';rebootRequired=$false} }
function Make-RemovalOperations([object] $State,[string] $FailAfter='') {
    $mutate={ param($name) [void]$State.events.Add($name); if ($name -ceq $FailAfter) { throw ('synthetic removal fault after '+$name) } }.GetNewClosure()
    return @{
        Validate={ param($j) if ($State.foreign) { throw 'synthetic foreign device/settings' }; return [bool]$State.instance }.GetNewClosure()
        BootIdentity={ return $State.boot }.GetNewClosure()
        Save={ param($j,$step) if (-not $State.record) { throw 'no journal' }; $State.saved=$j | ConvertTo-Json -Depth 6; & $mutate $step }.GetNewClosure()
        RemoveDevice={ param($j)
            if ($State.instance -cne $j.instanceId) { throw 'wrong device' }
            $State.removed=$j.instanceId
            if (($State.removeEvenOnReboot -or -not $State.reboot) -and -not $State.cleanupReboot) { $State.instance=$null }
            & $mutate 'device'; return $State.reboot
        }.GetNewClosure()
        Remaining={ param($j) return [bool]$State.instance }.GetNewClosure()
        RemoveRegistry={ param($j) $State.registry=$false; & $mutate 'registry' }.GetNewClosure()
        RemoveFiles={ param($j) $State.files=$false; & $mutate 'files' }.GetNewClosure()
        Finish={ param($j) $State.record=$false; & $mutate 'finish' }.GetNewClosure()
    }
}
function New-JournalFixture([object] $Pins) {
    $directory=Join-Path $root ('journal-'+[Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($directory)
    & $module { param($path) $script:SyntheticDirectory=$path } $directory
    $journal=& $module { param($p) New-KnotJournal $p } $Pins
    $state=[pscustomobject]@{Fault='';AclAllowed=$true;LinkCount=1;Promotions=0;FileChecks=0}
    $fs=@{
        AssertDirectory={ param($path) if ($path -cne $directory -or -not [IO.Directory]::Exists($path)) { throw 'synthetic directory guard' } }.GetNewClosure()
        AssertFile={ param($path)
            $state.FileChecks++
            if (-not [IO.File]::Exists($path) -or (([IO.File]::GetAttributes($path)) -band [IO.FileAttributes]::ReparsePoint) -or -not $state.AclAllowed -or $state.LinkCount -ne 1) { throw 'synthetic ACL/link guard' }
        }.GetNewClosure()
        Flush={ param($stream) $stream.Flush($true); if ($state.Fault -ceq 'after-flush') { throw 'synthetic crash after durable flush' } }.GetNewClosure()
        Replace={ param($source,$destination)
            if ($state.Fault -ceq 'before-replace') { throw 'synthetic crash before replace' }
            [IO.File]::Replace($source,$destination,[NullString]::Value); $state.Promotions++
            if ($state.Fault -ceq 'after-replace') { throw 'synthetic crash after replace' }
        }.GetNewClosure()
        Move={ param($source,$destination)
            if ($state.Fault -ceq 'before-move') { throw 'synthetic crash before move' }
            [IO.File]::Move($source,$destination); $state.Promotions++
            if ($state.Fault -ceq 'after-move') { throw 'synthetic crash after move' }
        }.GetNewClosure()
    }
    return [pscustomobject]@{Directory=$directory;Journal=$journal;FileSystem=$fs;State=$state;Record=(Join-Path $directory 'recovery.json');Pending=(Join-Path $directory 'recovery.new')}
}
function Write-FixtureJournal([object] $Fixture,[object] $Pins) { & $module { param($j,$p,$fs) Write-KnotJournal $j $p $fs } $Fixture.Journal $Pins $Fixture.FileSystem }
function Read-FixtureJournal([object] $Fixture,[object] $Pins,[switch] $Recover) {
    & $module { param($path,$p,$fs,$repair) $script:SyntheticDirectory=$path; Read-KnotJournal $p -FileSystem $fs -Recover:$repair } $Fixture.Directory $Pins $Fixture.FileSystem ([bool]$Recover)
}
function Start-FixtureRemoval([object] $Fixture) {
    $Fixture.Journal.removalPhase='Started'; $Fixture.Journal.removalPending=$true; $Fixture.Journal.rebootRequired=$true; $Fixture.Journal.removalBootId='boot:2026-01-01T00:00:00.0000000Z'
}
$journal=[pscustomobject]@{instanceId=('ROOT\KNOTVDD\'+('A'*32));driverVersion='11.30.4.434'}
try {
    foreach ($policy in @($null,([pscustomobject]@{}),([pscustomobject]@{installEnabled=$false;driverSafetyReviewStatus='blocked'}),([pscustomobject]@{installEnabled='false';driverSafetyReviewStatus='accepted'}),([pscustomobject]@{installEnabled='true';driverSafetyReviewStatus='accepted'}),([pscustomobject]@{installEnabled=$true;driverSafetyReviewStatus='blocked'}),([pscustomobject]@{installEnabled=$true;driverSafetyReviewStatus='Accepted'}))) {
        Reject { Assert-KnotInstallPolicy $policy } 'The installation policy defaults to disabled without explicit boolean enablement and accepted review.'
    }
    Assert-KnotInstallPolicy ([pscustomobject]@{installEnabled=$true;driverSafetyReviewStatus='accepted'}); $script:Checks++
    $removeSources=& $module { (${function:Remove-KnotVirtualDisplay}).ToString()+(${function:Remove-KnotVirtualDisplayCore}).ToString() }
    Assert (-not $removeSources.Contains('Assert-KnotInstallPolicy')) 'The install safety gate does not disable managed removal.'
    $valid=Make-Zip $files 'valid'
    $payload=Read-KnotDriverArchive $valid (Pin $valid) $inventory
    Assert ($payload.Count -eq 4) 'Accept the exact synthetic inventory.'
    $badHash=Pin $valid; $badHash.sha256='0'*64
    Reject { Read-KnotDriverArchive $valid $badHash $inventory } 'Reject a wrong archive hash.'
    $badSize=Pin $valid; $badSize.bytes++
    Reject { Read-KnotDriverArchive $valid $badSize $inventory } 'Reject a wrong archive size.'
    $duplicate=Make-Zip @($files+$files[0]) 'duplicate'
    Reject { Read-KnotDriverArchive $duplicate (Pin $duplicate) $inventory } 'Reject duplicate ZIP entries.'
    $case=[pscustomobject]@{path=$files[0].path.ToUpperInvariant();content=$files[0].content}
    $collision=Make-Zip @($files+$case) 'case-collision'
    Reject { Read-KnotDriverArchive $collision (Pin $collision) $inventory } 'Reject case-colliding ZIP entries.'
    $extra=[pscustomobject]@{path='VirtualDisplayDriver/extra.txt';content=[byte[]]@(1)}
    $extraPath=Make-Zip @($files+$extra) 'extra'
    Reject { Read-KnotDriverArchive $extraPath (Pin $extraPath) $inventory } 'Reject extra ZIP files.'
    foreach ($path in @('../outside','VirtualDisplayDriver/../MttVDD.inf','VirtualDisplayDriver\MttVDD.inf','/absolute.inf','C:/absolute.inf')) {
        $malformed=@($files[0],$files[1],([pscustomobject]@{path=$path;content=$files[2].content}),$files[3])
        $traversal=Make-Zip $malformed ('path-'+[Guid]::NewGuid().ToString('N'))
        Reject { Read-KnotDriverArchive $traversal (Pin $traversal) $inventory } 'Reject path traversal or a noncanonical ZIP path.'
    }
    $truncated=Join-Path $root 'truncated.zip'; $original=[IO.File]::ReadAllBytes($valid)
    [IO.File]::WriteAllBytes($truncated,$original[0..($original.Length-20)])
    Reject { Read-KnotDriverArchive $truncated (Pin $truncated) $inventory } 'Reject a truncated ZIP.'
    $changed=@($files[0],$files[1],([pscustomobject]@{path=$files[2].path;content=[Text.Encoding]::UTF8.GetBytes(('x'*$files[2].bytes))}),$files[3])
    $changedPath=Make-Zip $changed 'changed-file'
    Reject { Read-KnotDriverArchive $changedPath (Pin $changedPath) $inventory } 'Reject a correct-size file with the wrong hash.'
    $bomb=@($files[0],([pscustomobject]@{path=$files[1].path;content=(New-Object byte[] 400001)}),$files[2],$files[3])
    $bombPath=Make-Zip $bomb 'bomb'
    Reject { Read-KnotDriverArchive $bombPath (Pin $bombPath) $inventory } 'Reject decompression beyond pinned bounds.'
    $symlinkEntry=[pscustomobject]@{path=$files[0].path;content=$files[0].content;attributes=[int](-1610612736)}
    $symlinkPath=Make-Zip @($symlinkEntry,$files[1],$files[2],$files[3]) 'symlink'
    Reject { Read-KnotDriverArchive $symlinkPath (Pin $symlinkPath) $inventory } 'Reject symbolic-link ZIP entries.'
    $directoryEntries=@([pscustomobject]@{path='VirtualDisplayDriver/';content=[byte[]]@()})+$files
    $withDirectory=Make-Zip $directoryEntries 'directory'
    Assert ((Read-KnotDriverArchive $withDirectory (Pin $withDirectory) $inventory).Count -eq 4) 'Allow only the optional canonical empty directory entry.'
    $badInventory=[pscustomobject]@{schema=1;files=@($inventory.files[0],$inventory.files[0],$inventory.files[2],$inventory.files[3])}
    Reject { Read-KnotDriverArchive $valid (Pin $valid) $badInventory } 'Reject duplicate inventory paths.'
    $cert=[pscustomobject]@{RawData=[byte[]]@(1,2,3)}
    Assert-KnotCatalogSignature ([pscustomobject]@{Status='Valid';SignerCertificate=$cert}) (Hash $cert.RawData)
    $script:Checks++
    Reject { Assert-KnotCatalogSignature ([pscustomobject]@{Status='NotTrusted';SignerCertificate=$cert}) (Hash $cert.RawData) } 'Reject an untrusted catalog.'
    Reject { Assert-KnotCatalogSignature ([pscustomobject]@{Status='Valid';SignerCertificate=$cert}) ('0'*64) } 'Reject a wrong catalog certificate.'
    Reject { Assert-KnotCatalogSignature ([pscustomobject]@{Status='Valid';SignerCertificate=$null}) ('0'*64) } 'Reject a missing catalog certificate.'
    Reject { Assert-KnotDriverPackage $payload } 'Reject a package with non-PE driver bytes.'
    $pe=New-Object byte[] 256; $pe[0]=77; $pe[1]=90
    [Array]::Copy([BitConverter]::GetBytes([int]128),0,$pe,60,4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]17744),0,$pe,128,4)
    [Array]::Copy([BitConverter]::GetBytes([uint16]34404),0,$pe,132,2)
    [Array]::Copy([BitConverter]::GetBytes([uint16]523),0,$pe,152,2)
    $inf="Class = Display`r`nClassGUID = {4D36E968-E325-11CE-BFC1-08002BE10318}`r`nDriverVer = 12/24/2024,11.30.4.434`r`n%ManufacturerName%=Standard,NTamd64`r`n%DeviceName%=MyDevice_Install, Root\MttVDD ; synthetic`r`nCatalogFile=MttVDD.cat`r`n"
    $syntheticPackage=@{'VirtualDisplayDriver/MttVDD.dll'=$pe;'VirtualDisplayDriver/MttVDD.inf'=([byte[]]@(255,254)+[Text.Encoding]::Unicode.GetBytes($inf))}
    Assert-KnotDriverPackage $syntheticPackage; $script:Checks++
    $pe[132]=0
    Reject { Assert-KnotDriverPackage $syntheticPackage } 'Reject a non-AMD64 binary.'
    $pe[132]=100
    $syntheticPackage['VirtualDisplayDriver/MttVDD.inf']=[byte[]]@(255,254)+[Text.Encoding]::Unicode.GetBytes($inf.Replace('Root\MttVDD','Root\Other'))
    Reject { Assert-KnotDriverPackage $syntheticPackage } 'Reject an INF with different hardware.'
    $syntheticPackage['VirtualDisplayDriver/MttVDD.inf']=[byte[]]@(255,254)+[Text.Encoding]::Unicode.GetBytes($inf.Replace('Class = Display','Class = Other'))
    Reject { Assert-KnotDriverPackage $syntheticPackage } 'Reject an INF with a different device class.'
    $syntheticPackage['VirtualDisplayDriver/MttVDD.inf']=[Text.Encoding]::UTF8.GetBytes($inf)
    Reject { Assert-KnotDriverPackage $syntheticPackage } 'Require the pinned INF encoding.'

    foreach ($fault in @('journal','files','registry','device','driver','verify','commit')) {
        $state=New-TestState
        $ops=Make-Operations $state $fault
        Reject { Invoke-KnotHeadlessTransaction $journal $ops } ('Surface a failure after '+$fault)
        Assert (-not $state.record -and -not $state.files -and -not $state.registry -and -not $state.instance) ('Compensate a failure after '+$fault)
        Assert ($state.events[0] -ceq 'journal' -and $state.events[$state.events.Count-1] -ceq 'cleanup') 'Journal precedes all resource mutations and cleanup follows failure.'
        if ($state.removed) { Assert ($state.removed -ceq $journal.instanceId) 'Compensation removes only the planned device ID.' }
    }
    $state=New-TestState; $state.foreign=$true
    Reject { Invoke-KnotHeadlessTransaction $journal (Make-Operations $state '') } 'Refuse foreign resources.'
    Assert ($state.events.Count -eq 0) 'Foreign resource preflight makes zero mutations.'
    $state=New-TestState
    Reject { Invoke-KnotHeadlessTransaction $journal (Make-Operations $state 'device' $true) } 'Surface a cleanup failure.'
    Assert ($state.record -and $state.instance -ceq $journal.instanceId) 'Cleanup failure preserves the recovery record and exact device identity.'
    $state=New-TestState; $state.reboot=$true
    $result=Invoke-KnotHeadlessTransaction $journal (Make-Operations $state '')
    Assert ($result.Completed -and $result.RebootRequired -and $state.record) 'Successful installation reports restart and keeps its ownership record.'
    $state=New-TestState; $state.cleanupReboot=$true
    $result=Invoke-KnotHeadlessTransaction $journal (Make-Operations $state 'driver')
    Assert (-not $result.Completed -and $result.RebootRequired -and $state.record) 'Rollback requiring restart retains the journal and never reports completed.'

    foreach ($fault in @('begin','device','registry','files')) {
        $journal=New-RemovalJournal
        $state=New-TestState; $state.record=$true; $state.registry=$true; $state.files=$true; $state.instance=$journal.instanceId
        Reject { Invoke-KnotHeadlessRemoval $journal (Make-RemovalOperations $state $fault) } ('Surface removal failure after '+$fault)
        Assert $state.record 'Interrupted removal always retains its journal.'
        Assert (-not $state.events.Contains('finish')) 'Failure never advances to journal deletion.'
        $state.boot='boot:2026-01-02T00:00:00.0000000Z'
        $result=Invoke-KnotHeadlessRemoval $journal (Make-RemovalOperations $state)
        Assert ($result.Completed -and -not $state.record -and -not $state.files -and -not $state.registry -and -not $state.instance) 'A prepared partial removal can complete idempotently.'
    }
    $journal=New-RemovalJournal
    $state=New-TestState; $state.record=$true; $state.files=$true; $state.registry=$true; $state.instance=$journal.instanceId; $state.foreign=$true
    Reject { Invoke-KnotHeadlessRemoval $journal (Make-RemovalOperations $state) } 'Removal refuses a foreign resource before changing anything.'
    Assert ($state.events.Count -eq 0 -and $state.record -and $state.files -and $state.registry) 'Foreign removal preserves shared settings and journal with zero changes.'
    $state.foreign=$false; $state.reboot=$true
    $result=Invoke-KnotHeadlessRemoval $journal (Make-RemovalOperations $state)
    Assert (-not $result.Completed -and $result.RebootRequired -and $state.record -and $state.files -and $state.registry) 'Reboot-pending removal preserves all configuration and journal.'
    Assert ($state.removed -ceq $journal.instanceId) 'Removal addresses only the exact planned instance.'
    $journal=New-RemovalJournal
    $state=New-TestState; $state.record=$true; $state.files=$true; $state.registry=$true; $state.instance=$journal.instanceId; $state.cleanupReboot=$true
    Reject { Invoke-KnotHeadlessRemoval $journal (Make-RemovalOperations $state) } 'Remaining device without a reboot flag is a failure, not an invented reboot success.'
    Assert ($state.record -and $state.registry -and $state.files) 'An unverified removal preserves configuration.'
    foreach ($fault in @('','device')) {
        $journal=New-RemovalJournal
        $state=New-TestState; $state.record=$true; $state.files=$true; $state.registry=$true; $state.instance=$journal.instanceId; $state.reboot=$true; $state.removeEvenOnReboot=$true
        if ($fault) { Reject { Invoke-KnotHeadlessRemoval $journal (Make-RemovalOperations $state $fault) } 'Crash after native removal leaves its durable outcome unknown.' }
        else { $result=Invoke-KnotHeadlessRemoval $journal (Make-RemovalOperations $state); Assert $result.RebootRequired 'Native reboot result is persisted.' }
        $journal=$state.saved | ConvertFrom-Json
        Assert (-not $state.instance) 'The synthetic native removal made the devnode immediately absent.'
        $eventsBefore=$state.events.Count
        $result=Invoke-KnotHeadlessRemoval $journal (Make-RemovalOperations $state)
        Assert (-not $result.Completed -and $result.RebootRequired -and $state.registry -and $state.files -and $state.record -and $state.events.Count -eq $eventsBefore) 'Same-boot absent-device retry retains all resources without mutations.'
        $state.boot=$null
        $result=Invoke-KnotHeadlessRemoval $journal (Make-RemovalOperations $state)
        Assert (-not $result.Completed -and $result.Status -ceq 'BootIdentityUnavailable' -and $state.registry -and $state.files -and $state.record -and $state.events.Count -eq $eventsBefore) 'Unavailable boot identity never releases pending or unknown removal resources.'
        $state.boot='boot:2026-01-02T00:00:00.0000000Z'
        $result=Invoke-KnotHeadlessRemoval $journal (Make-RemovalOperations $state)
        Assert ($result.Completed -and -not $state.registry -and -not $state.files -and -not $state.record) 'A changed verified boot plus fresh absent-device inventory permits cleanup.'
    }

    $device=[pscustomobject]@{InstanceId=$journal.instanceId;HardwareIds=@('Root\MttVDD');DriverVersion=$journal.driverVersion;DriverInf='oem42.inf'}
    Assert-KnotDevices @($device) $journal -Installed; $script:Checks++
    $foreign=[pscustomobject]@{InstanceId='ROOT\DISPLAY\0000';HardwareIds=@('Root\MttVDD');DriverVersion=$journal.driverVersion;DriverInf='oem42.inf'}
    Reject { Assert-KnotDevices @($device,$foreign) $journal } 'Refuse shared-registry teardown when a foreign VDD appears.'
    $wrong=[pscustomobject]@{InstanceId=$journal.instanceId;HardwareIds=@('Foreign');DriverVersion=$journal.driverVersion;DriverInf='oem42.inf'}
    Reject { Assert-KnotDevices @($wrong) $journal } 'Refuse a reused journaled instance with different hardware.'
    $device.DriverVersion='1.0.0.0'
    Reject { Assert-KnotDevices @($device) $journal } 'Refuse a changed driver even during recovery.'
    Reject { Assert-KnotDevices @() $journal -Installed } 'Do not claim installed success without the exact device.'

    # Exercise production file ownership logic with synthetic files only. ACL queries
    # are replaced in this isolated module; the public install/remove entrypoints are never called.
    & $module { function script:Assert-ProtectedFile([string] $Path) { if (-not [IO.File]::Exists($Path)) { throw 'synthetic file missing' } } }
    $owned=Join-Path $root 'owned'; [void][IO.Directory]::CreateDirectory($owned)
    $settings=[Text.Encoding]::UTF8.GetBytes('<synthetic />')
    [IO.File]::WriteAllBytes((Join-Path $owned 'vdd_settings.xml'),$settings)
    [IO.File]::WriteAllText((Join-Path $owned 'recovery.json'),'synthetic journal')
    $ownedRecord=[pscustomobject]@{directory=$owned;status='Prepared';files=@([pscustomobject]@{name='vdd_settings.xml';bytes=$settings.Length;sha256=(Hash $settings)})}
    & $module { param($j) Assert-KnotOwnedFiles $j -WithoutNative } $ownedRecord; $script:Checks++
    [IO.File]::WriteAllText((Join-Path $owned 'vdd_settings.xml'),'<modified />')
    Reject { & $module { param($j) Assert-KnotOwnedFiles $j -WithoutNative } $ownedRecord } 'Refuse changed settings before cleanup.'
    Assert ([IO.File]::Exists((Join-Path $owned 'recovery.json'))) 'Changed settings retain the recovery record.'
    [IO.File]::WriteAllBytes((Join-Path $owned 'vdd_settings.xml'),$settings)
    [IO.File]::WriteAllText((Join-Path $owned 'unknown.txt'),'synthetic foreign data')
    Reject { & $module { param($j) Assert-KnotOwnedFiles $j -WithoutNative } $ownedRecord } 'Refuse unknown managed-folder content.'
    Assert ([IO.File]::Exists((Join-Path $owned 'unknown.txt'))) 'Unknown content is preserved.'
    [IO.File]::Delete((Join-Path $owned 'unknown.txt')); [IO.File]::Delete((Join-Path $owned 'vdd_settings.xml'))
    & $module { param($j) Assert-KnotOwnedFiles $j -WithoutNative } $ownedRecord; $script:Checks++
    $ownedRecord.status='Installed'
    Reject { & $module { param($j) Assert-KnotOwnedFiles $j -WithoutNative } $ownedRecord } 'Refuse missing installed files, while Prepared recovery permits missing files.'
    # Recovery identity validation uses only source-owned package manifests/settings.
    & $module { $script:SyntheticDirectory='C:\SyntheticKnot'; function script:Get-KnotDirectory { return $script:SyntheticDirectory } }
    $pins=& $module { Read-KnotDependency }
    $validJournal=& $module { param($p) New-KnotJournal $p } $pins
    & $module { param($j,$p) Assert-KnotJournal $j $p } $validJournal $pins; $script:Checks++
    $validJournal.instanceId='ROOT\KNOTVDD\'+('0'*32)
    Reject { & $module { param($j,$p) Assert-KnotJournal $j $p } $validJournal $pins } 'Reject a recovery record whose device is not its deployment ID.'
    $validJournal.instanceId='ROOT\KNOTVDD\'+$validJournal.deploymentId
    $validJournal.files[0].name='../outside.cat'
    Reject { & $module { param($j,$p) Assert-KnotJournal $j $p } $validJournal $pins } 'Reject recovery file paths outside the fixed owned inventory.'

    # Exercise actual production Write/Read journal code. Only ACL/native link
    # checks are replaced; Flush, Replace, Move and all bytes are real fresh files.
    foreach ($fault in @('after-flush','before-move','after-move')) {
        $fixture=New-JournalFixture $pins; $fixture.State.Fault=$fault
        Reject { Write-FixtureJournal $fixture $pins } ('Interrupt initial publication '+$fault)
        $fixture.State.Fault=''; $before=$fixture.State.Promotions
        $read=Read-FixtureJournal $fixture $pins
        Assert ($read.generation -eq 1 -and $read.deploymentId -ceq $fixture.Journal.deploymentId -and $fixture.State.Promotions -eq $before) 'Read-only parsing recognizes a valid interrupted initial record without publishing it.'
        if ($fault -cne 'after-move') {
            Assert ([IO.File]::Exists($fixture.Pending) -and -not [IO.File]::Exists($fixture.Record)) 'An interrupted initial durable write remains new-only before repair.'
            & $module { param($fs) $script:FixtureFileSystem=$fs; $script:SavedFileSystemFactory=${function:New-KnotJournalFileSystem}; function script:New-KnotJournalFileSystem([switch]$WithoutNative) { return $script:FixtureFileSystem } } $fixture.FileSystem
            try { $gui=Get-KnotHeadlessState; Assert ($gui.Managed -and $gui.Status -ceq 'RecoveryRequired' -and $fixture.State.Promotions -eq $before) 'GUI reports managed pending recovery without promoting files or querying boot state.' }
            finally { & $module { Set-Item Function:script:New-KnotJournalFileSystem $script:SavedFileSystemFactory } }
        }
        $read=Read-FixtureJournal $fixture $pins -Recover
        Assert ([IO.File]::Exists($fixture.Record) -and -not [IO.File]::Exists($fixture.Pending) -and $read.generation -eq 1) 'A verified interrupted initial record can be published and recovered.'
    }
    foreach ($fault in @('after-flush','before-replace','after-replace')) {
        $fixture=New-JournalFixture $pins; Write-FixtureJournal $fixture $pins
        $previousHash=Hash ([IO.File]::ReadAllBytes($fixture.Record))
        Start-FixtureRemoval $fixture; $fixture.State.Fault=$fault
        Reject { Write-FixtureJournal $fixture $pins } ('Interrupt successor publication '+$fault)
        $fixture.State.Fault=''; $before=$fixture.State.Promotions
        $read=Read-FixtureJournal $fixture $pins
        Assert ($read.generation -eq 2 -and $read.previousRecordSha256 -ceq $previousHash -and $read.removalPhase -ceq 'Started' -and $fixture.State.Promotions -eq $before) 'A pending successor proves its exact prior bytes and sequence without read-only mutation.'
        $read=Read-FixtureJournal $fixture $pins -Recover
        Assert ($read.generation -eq 2 -and -not [IO.File]::Exists($fixture.Pending)) 'A verified pending successor is atomically promoted.'
    }
    foreach ($bad in @('deployment','predecessor','generation','schema','inventory','transition','truncated','unknown-file','changed-settings','missing-predecessor','acl','hardlink')) {
        $fixture=New-JournalFixture $pins; Write-FixtureJournal $fixture $pins; Start-FixtureRemoval $fixture
        $fixture.State.Fault='after-flush'
        Reject { Write-FixtureJournal $fixture $pins } 'Create a fresh interrupted successor fixture.'
        $fixture.State.Fault=''
        $candidate=[IO.File]::ReadAllText($fixture.Pending) | ConvertFrom-Json
        switch ($bad) {
            'deployment' { $candidate.deploymentId='B'*32; $candidate.instanceId='ROOT\KNOTVDD\'+$candidate.deploymentId }
            'predecessor' { $candidate.previousRecordSha256='0'*64 }
            'generation' { $candidate.generation=3 }
            'schema' { $candidate.schema=1 }
            'inventory' { $candidate.files[0].sha256='0'*64 }
            'transition' { $candidate.removalPhase='PendingReboot' }
            'truncated' { }
            'unknown-file' { [IO.File]::WriteAllText((Join-Path $fixture.Directory 'foreign.txt'),'synthetic foreign') }
            'changed-settings' { [IO.File]::WriteAllText((Join-Path $fixture.Directory 'vdd_settings.xml'),'synthetic changed settings') }
            'missing-predecessor' { [IO.File]::Delete($fixture.Record) }
            'acl' { $fixture.State.AclAllowed=$false }
            'hardlink' { $fixture.State.LinkCount=2 }
        }
        if ($bad -ceq 'truncated') { [IO.File]::WriteAllText($fixture.Pending,'{"schema":2,') }
        else { [IO.File]::WriteAllText($fixture.Pending,($candidate | ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false))) }
        $pendingHash=Hash ([IO.File]::ReadAllBytes($fixture.Pending)); $before=$fixture.State.Promotions
        Reject { Read-FixtureJournal $fixture $pins -Recover } ('Refuse unverified interrupted recovery: '+$bad)
        Assert ($fixture.State.Promotions -eq $before -and (Hash ([IO.File]::ReadAllBytes($fixture.Pending))) -ceq $pendingHash) 'Conflicting or unsafe recovery bytes are preserved without promotion.'
    }
    $fixture=New-JournalFixture $pins; $fixture.State.Fault='after-flush'
    Reject { Write-FixtureJournal $fixture $pins } 'Create an initial orphan fixture.'
    $fixture.State.Fault=''; [IO.File]::WriteAllText((Join-Path $fixture.Directory 'foreign.txt'),'synthetic foreign')
    Reject { Read-FixtureJournal $fixture $pins -Recover } 'An initial new-only journal cannot adopt accompanying unknown resources.'

    # Persist removal phases with the real journal writer, then simulate a new
    # elevated invocation by rereading disk before every retry.
    foreach ($crashAfterNative in @($false,$true)) {
        $fixture=New-JournalFixture $pins; Write-FixtureJournal $fixture $pins
        $settingsPath=Join-Path $fixture.Directory 'vdd_settings.xml'
        [IO.File]::Copy((Join-Path (Split-Path $PSScriptRoot -Parent) 'Knot-vdd_settings.xml'),$settingsPath)
        $state=New-TestState; $state.record=$true; $state.files=$true; $state.registry=$true; $state.instance=$fixture.Journal.instanceId; $state.reboot=$true; $state.removeEvenOnReboot=$true
        $fault=''; if ($crashAfterNative) { $fault='device' }
        $ops=Make-RemovalOperations $state $fault
        $ops.Save={ param($j,$step) & $module { param($record,$p,$fs) Write-KnotJournal $record $p $fs } $j $pins $fixture.FileSystem }.GetNewClosure()
        if ($crashAfterNative) { Reject { Invoke-KnotHeadlessRemoval $fixture.Journal $ops } 'Crash after native success and before outcome publication retains Started on disk.' }
        else { $result=Invoke-KnotHeadlessRemoval $fixture.Journal $ops; Assert $result.RebootRequired 'A reboot-requiring native result is published to disk.' }
        $fixture.Journal=Read-FixtureJournal $fixture $pins -Recover
        $expectedPhase='PendingReboot'; if ($crashAfterNative) { $expectedPhase='Started' }
        Assert ($fixture.Journal.removalPhase -ceq $expectedPhase -and -not $state.instance) 'Disk records pending or unknown removal even when the device is absent.'
        $recordHash=Hash ([IO.File]::ReadAllBytes($fixture.Record)); $settingsHash=Hash ([IO.File]::ReadAllBytes($settingsPath))
        $ops=Make-RemovalOperations $state
        $ops.Save={ param($j,$step) & $module { param($record,$p,$fs) Write-KnotJournal $record $p $fs } $j $pins $fixture.FileSystem }.GetNewClosure()
        $ops.RemoveFiles={ param($j) [IO.File]::Delete($settingsPath); $state.files=$false }.GetNewClosure()
        $ops.Finish={ param($j) [IO.File]::Delete($fixture.Record); [IO.Directory]::Delete($fixture.Directory,$false); $state.record=$false }.GetNewClosure()
        $result=Invoke-KnotHeadlessRemoval $fixture.Journal $ops
        Assert (-not $result.Completed -and $state.registry -and (Hash ([IO.File]::ReadAllBytes($fixture.Record))) -ceq $recordHash -and (Hash ([IO.File]::ReadAllBytes($settingsPath))) -ceq $settingsHash) 'Same-boot retry preserves actual journal/settings bytes and synthetic registry.'
        $state.boot=$null; $fixture.Journal=Read-FixtureJournal $fixture $pins -Recover
        $result=Invoke-KnotHeadlessRemoval $fixture.Journal $ops
        Assert (-not $result.Completed -and $state.registry -and (Hash ([IO.File]::ReadAllBytes($fixture.Record))) -ceq $recordHash -and [IO.File]::Exists($settingsPath)) 'Unavailable boot identity preserves persisted pending recovery.'
        $state.boot='boot:2026-01-02T00:00:00.0000000Z'; $fixture.Journal=Read-FixtureJournal $fixture $pins -Recover
        $result=Invoke-KnotHeadlessRemoval $fixture.Journal $ops
        Assert ($result.Completed -and -not $state.registry -and -not [IO.Directory]::Exists($fixture.Directory)) 'A verified changed boot and fresh absent-device result release the actual fixture files.'
    }
    Write-Output ('Headless setup synthetic checks passed: '+$script:Checks)
    [pscustomobject]@{status='passed';checks=$script:Checks;freshSyntheticOnly=$true;nativeApisInvoked=$false} | ConvertTo-Json -Compress
} finally {
    Remove-Module HeadlessSetup -Force -ErrorAction SilentlyContinue
    # The uniquely named test directory contains only fixtures generated by this test.
    [IO.Directory]::Delete($root,$true)
}
