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
    return [pscustomobject]@{events=(New-Object 'Collections.Generic.List[string]');record=$false;files=$false;registry=$false;instance=$null;removed=$null;foreign=$false;reboot=$false;cleanupReboot=$false;removeEvenOnReboot=$false;boot='boot:2026-01-01T00:00:00.0000000Z';session=('a'*32);saved=$null}
}
function New-RemovalJournal { return [pscustomobject]@{schema=3;publishedInfName='oem42.inf';instanceId=('ROOT\KNOTVDD\'+('A'*32));driverVersion='11.30.4.434';removalBootSession='';removalPending=$false;removalPhase='None';removalBootId='';rebootRequired=$false} }
function Make-RemovalOperations([object] $State,[string] $FailAfter='') {
    $mutate={ param($name) [void]$State.events.Add($name); if ($name -ceq $FailAfter) { throw ('synthetic removal fault after '+$name) } }.GetNewClosure()
    return @{
        Validate={ param($j) if ($State.foreign) { throw 'synthetic foreign device/settings' }; return [bool]$State.instance }.GetNewClosure()
        BootEvidence={ return [pscustomobject]@{BootId=$State.boot;Session=$State.session} }.GetNewClosure()
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
    $Fixture.Journal.removalPhase='Started'; $Fixture.Journal.removalPending=$true; $Fixture.Journal.rebootRequired=$true; $Fixture.Journal.removalBootId='boot:2026-01-01T00:00:00.0000000Z'; $Fixture.Journal.removalBootSession='a'*32
}
$journal=[pscustomobject]@{schema=3;publishedInfName='oem42.inf';instanceId=('ROOT\KNOTVDD\'+('A'*32));driverVersion='11.30.4.434'}
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
        $state.boot='boot:2026-01-02T00:00:00.0000000Z'; $state.session='b'*32
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
        Assert (-not $result.Completed -and $result.Status -ceq 'BootEvidenceUnavailable' -and -not $result.RebootRequired -and $state.registry -and $state.files -and $state.record -and $state.events.Count -eq $eventsBefore) 'Unavailable boot identity never releases pending or unknown removal resources.'
        $state.boot='boot:2026-01-02T00:00:00.0000000Z'; $state.session='b'*32
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
    foreach ($bad in @('deployment','predecessor','generation','schema','inventory','transition','unknown-file','changed-settings','missing-predecessor','acl','hardlink')) {
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
        $state.boot='boot:2026-01-02T00:00:00.0000000Z'; $state.session='b'*32; $fixture.Journal=Read-FixtureJournal $fixture $pins -Recover
        $result=Invoke-KnotHeadlessRemoval $fixture.Journal $ops
        Assert ($result.Completed -and -not $state.registry -and -not [IO.Directory]::Exists($fixture.Directory)) 'A verified changed boot and fresh absent-device result release the actual fixture files.'
    }
    & $module {
        $script:SavedStateSupported=${function:Test-KnotHeadlessStateSupported}; $script:SavedDirectoryReader=${function:Get-KnotDirectory}
        function script:Test-KnotHeadlessStateSupported { return $false }
        function script:Get-KnotDirectory { throw '32-bit state must refuse before resolving a redirected ProgramFiles directory' }
    }
    try { $state32=Get-KnotHeadlessState; Assert ($state32.Status -ceq 'Unsupported' -and -not $state32.Managed -and -not $state32.RebootRequired) 'Read-only 32-bit state inspection refuses before resolving a potentially redirected protected directory.' }
    finally { & $module { Set-Item Function:script:Test-KnotHeadlessStateSupported $script:SavedStateSupported; Set-Item Function:script:Get-KnotDirectory $script:SavedDirectoryReader } }
    $runtimeSource=& $module { (${function:Assert-KnotElevatedRuntime}).ToString() }
    Assert (-not $runtimeSource.Contains('VirtualDisplayDependency.json') -and -not $runtimeSource.Contains('VirtualDisplayFiles.json') -and -not $runtimeSource.Contains('Knot-vdd_settings.xml') -and $runtimeSource.Contains('VirtualDisplayDeployments.json')) 'Common elevated recovery runtime requires trusted historical authority, not current install candidate resources.'
    # Current candidate pins are not recovery authority. The historical profile
    # remains readable when the candidate settings/download policy have changed.
    $fixture=New-JournalFixture $pins; Write-FixtureJournal $fixture $pins
    $fixture.Journal.files=@($fixture.Journal.files | Sort-Object name -Descending | ForEach-Object { [pscustomobject]@{sha256=$_.sha256;name=$_.name;bytes=$_.bytes} })
    Write-FixtureJournal $fixture $pins
    $reordered=Read-FixtureJournal $fixture $pins
    Assert ($reordered.generation -eq 2) 'Fieldwise trusted profile identity permits harmless file/property ordering changes while the exact predecessor byte hash still chains updates.'
    $otherPins=[pscustomobject]@{Dependency=[pscustomobject]@{sha256=('0'*64);driverVersion='99.0.0.0';settingsSha256=('1'*64)};Inventory=$null}
    $read=Read-FixtureJournal $fixture $otherPins
    Assert ($read.manifestId -ceq 'vdd-25.7.23-knot-settings-v1') 'Recovery resolves the exact trusted historical profile independently of candidate pins.'
    & $module { $script:SavedDependencyReader=${function:Read-KnotDependency}; function script:Read-KnotDependency { throw 'synthetic missing current candidate' } }
    try {
        $read=Read-FixtureJournal $fixture $null
        Assert ($read.deploymentId -ceq $fixture.Journal.deploymentId) 'Missing current candidate does not disable historical recovery.'
    } finally { & $module { Set-Item Function:script:Read-KnotDependency $script:SavedDependencyReader } }
    & $module {
        param($fs)
        $script:FixtureFileSystem=$fs; $script:SavedFileSystemFactory=${function:New-KnotJournalFileSystem}; $script:SavedDependencyReader=${function:Read-KnotDependency}; $script:SavedExclusive=${function:Invoke-KnotExclusive}; $script:SavedRemoveOwned=${function:Remove-KnotOwnedDeployment}
        function script:New-KnotJournalFileSystem([switch]$WithoutNative) { return $script:FixtureFileSystem }
        function script:Read-KnotDependency { throw 'synthetic missing current candidate' }
        function script:Invoke-KnotExclusive([scriptblock]$Action) { return & $Action }
        function script:Remove-KnotOwnedDeployment([object]$Journal,[object]$Pins=$null) { return [pscustomobject]@{Completed=$true;RebootRequired=$false;Status='SyntheticRemovalValidated';InstanceId=$Journal.instanceId} }
    } $fixture.FileSystem
    try { $result=Remove-KnotVirtualDisplay; Assert ($result.Completed -and $result.Status -ceq 'SyntheticRemovalValidated' -and $result.InstanceId -ceq $fixture.Journal.instanceId) 'Public managed removal reaches trusted historical recovery without reading missing current install resources; OS mutations are stubbed.' }
    finally { & $module { Set-Item Function:script:New-KnotJournalFileSystem $script:SavedFileSystemFactory; Set-Item Function:script:Read-KnotDependency $script:SavedDependencyReader; Set-Item Function:script:Invoke-KnotExclusive $script:SavedExclusive; Set-Item Function:script:Remove-KnotOwnedDeployment $script:SavedRemoveOwned } }
    foreach ($mode in @('predecessor','pending-orphan')) {
        $guardFixture=New-JournalFixture $pins; Write-FixtureJournal $guardFixture $pins; Start-FixtureRemoval $guardFixture
        $guardFixture.State.Fault='after-flush'; Reject { Write-FixtureJournal $guardFixture $pins } 'Create a protected interrupted update for expected-identity guarding.'; $guardFixture.State.Fault=''
        if ($mode -ceq 'pending-orphan') {
            [IO.File]::Delete($guardFixture.Record)
            $candidate=[IO.File]::ReadAllText($guardFixture.Pending) | ConvertFrom-Json
            $candidate.generation=1; $candidate.previousRecordSha256=''; $candidate.removalPhase='None'; $candidate.removalPending=$false; $candidate.rebootRequired=$false; $candidate.removalBootId=''; $candidate.removalBootSession=''
            [IO.File]::WriteAllText($guardFixture.Pending,($candidate | ConvertTo-Json -Depth 6))
        }
        $before=Hash ([IO.File]::ReadAllBytes($guardFixture.Pending)); $promotions=$guardFixture.State.Promotions
        Reject { & $module { param($path,$pins,$fs) $script:SyntheticDirectory=$path; Read-KnotJournal $pins -Recover -FileSystem $fs -ExpectedDeploymentId ('F'*32) } $guardFixture.Directory $pins $guardFixture.FileSystem } ('Expected deployment mismatch is rejected before recovery: '+$mode)
        Assert ($guardFixture.State.Promotions -eq $promotions -and (Hash ([IO.File]::ReadAllBytes($guardFixture.Pending))) -ceq $before) 'Mismatched expected recovery identity causes zero promotion, quarantine, or content mutation.'
    }
    & $module { param($path) $script:SyntheticDirectory=$path } $fixture.Directory
    $planned=$fixture.Journal | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    $planned.deploymentId='F'*32; $planned.instanceId='ROOT\KNOTVDD\'+$planned.deploymentId
    & $module { param($fs) $script:FixtureFileSystem=$fs; $script:SavedFileSystemFactory=${function:New-KnotJournalFileSystem}; function script:New-KnotJournalFileSystem([switch]$WithoutNative) { return $script:FixtureFileSystem } } $fixture.FileSystem
    try { Assert (-not (& $module { param($j) Test-KnotOwnedDeployment $j } $planned)) 'Compensation authority rejects a valid owned record for a different planned deployment.' }
    finally { & $module { Set-Item Function:script:New-KnotJournalFileSystem $script:SavedFileSystemFactory } }
    $state=New-TestState; $state.foreign=$true; $state.record=$true
    Reject { Invoke-KnotHeadlessTransaction $journal (Make-Operations $state '') } 'A failed preflight cannot enter compensation even if a foreign journal path already exists.'
    Assert ($state.record -and $state.events.Count -eq 0) 'Foreign existing journal survives failed preflight without cleanup.'

    foreach ($failure in @('remaining','probe-error')) {
        $j=New-RemovalJournal; $state=New-TestState; $state.record=$true; $state.files=$true; $state.registry=$true; $state.instance=$j.instanceId
        if ($failure -ceq 'remaining') { $state.cleanupReboot=$true }
        $ops=Make-RemovalOperations $state
        if ($failure -ceq 'probe-error') { $ops.Remaining={ param($j) throw 'synthetic post-removal inventory error' } }
        Reject { Invoke-KnotHeadlessRemoval $j $ops } ('An unverified nonreboot removal cannot publish Ready: '+$failure)
        $persisted=$state.saved | ConvertFrom-Json
        Assert ($persisted.removalPhase -ceq 'Started' -and $persisted.rebootRequired -and $state.registry -and $state.files -and $state.record) 'A remaining or unreadable device inventory preserves the durable unknown-outcome phase.'
        $state.instance=$null
        $result=Invoke-KnotHeadlessRemoval $persisted (Make-RemovalOperations $state)
        Assert (-not $result.Completed -and $result.Status -ceq 'RemovalPending' -and $state.record) 'An absent devnode on the same boot cannot bypass a failed removal verification.'
    }
    foreach ($change in @('boot-only','session-only','missing-session','invalid-session','missing-boot')) {
        $j=New-RemovalJournal; $j.removalPending=$true; $j.removalPhase='PendingReboot'; $j.rebootRequired=$true; $j.removalBootId='boot:2026-01-01T00:00:00.0000000Z'; $j.removalBootSession='a'*32
        $state=New-TestState; $state.record=$true; $state.registry=$true; $state.files=$true
        switch ($change) {
            'boot-only' { $state.boot='boot:2026-01-02T00:00:00.0000000Z' }
            'session-only' { $state.session='b'*32 }
            'missing-session' { $state.session=$null }
            'invalid-session' { $state.session='not-a-session' }
            'missing-boot' { $state.boot=$null }
        }
        $result=Invoke-KnotHeadlessRemoval $j (Make-RemovalOperations $state)
        $expectedStatus='BootEvidenceUnavailable'; $expectedRestart=$false
        if ($change -cin @('boot-only','session-only')) { $expectedStatus='RemovalPending'; $expectedRestart=$true }
        Assert (-not $result.Completed -and $result.Status -ceq $expectedStatus -and $result.RebootRequired -eq $expectedRestart -and $state.events.Count -eq 0 -and $state.files -and $state.registry) ('Independent reboot evidence remains conservative: '+$change)
    }
    $j=New-RemovalJournal; $j.schema=2; $j.PSObject.Properties.Remove('publishedInfName'); $j.PSObject.Properties.Remove('removalBootSession'); $j.removalPending=$true; $j.removalPhase='PendingReboot'; $j.rebootRequired=$true; $j.removalBootId='boot:2026-01-01T00:00:00.0000000Z'
    $state=New-TestState; $state.boot='boot:2026-01-02T00:00:00.0000000Z'; $state.session='b'*32
    $result=Invoke-KnotHeadlessRemoval $j (Make-RemovalOperations $state)
    Assert ($result.Status -ceq 'LegacyRecoveryRequired' -and -not $result.Completed -and -not $result.RebootRequired -and $state.events.Count -eq 0) 'A legacy pending record never invents missing volatile reboot evidence.'

    foreach ($status in @('BootEvidenceUnavailable','LegacyRecoveryRequired','RemovalPending')) {
        $state=New-TestState; $ops=Make-Operations $state 'driver'
        $restart=($status -ceq 'RemovalPending')
        $ops.Cleanup={ param($j) return [pscustomobject]@{Completed=$false;RebootRequired=$restart;Status=$status} }.GetNewClosure()
        $result=Invoke-KnotHeadlessTransaction $journal $ops
        Assert (-not $result.Completed -and $result.Status -ceq $status -and $result.RebootRequired -eq $restart) ('Installation compensation preserves the actionable recovery outcome: '+$status)
    }
    $j=New-RemovalJournal; $j.removalPending=$true; $j.removalPhase='Started'; $j.rebootRequired=$true; $j.removalBootId='boot:2026-01-01T00:00:00.0000000Z'; $j.removalBootSession='a'*32
    $state=New-TestState; $state.record=$true; $state.registry=$true; $state.files=$true; $ops=Make-RemovalOperations $state; $ops.BootEvidence={ throw 'synthetic marker read error' }
    $result=Invoke-KnotHeadlessRemoval $j $ops
    Assert ($result.Status -ceq 'BootEvidenceUnavailable' -and -not $result.Completed -and -not $result.RebootRequired -and $state.events.Count -eq 0 -and $state.record -and $state.files -and $state.registry) 'A boot-evidence read error preserves pending resources and gives a manual recovery outcome without a restart loop.'
    $fixture=New-JournalFixture $pins
    $legacy=$fixture.Journal | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    $legacy.schema=2; foreach ($name in @('manifestId','publishedInfName','removalBootSession')) { $legacy.PSObject.Properties.Remove($name) }
    & $module { param($j) Assert-KnotJournal $j } $legacy; $script:Checks++
    [IO.File]::WriteAllText($fixture.Record,($legacy | ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
    $fixture.Journal=& $module { param($j) Convert-KnotLegacyJournal $j @() } $legacy
    Write-FixtureJournal $fixture $null
    $migrated=Read-FixtureJournal $fixture $null
    Assert ($migrated.schema -eq 3 -and $migrated.manifestId -ceq 'vdd-25.7.23-knot-settings-v1' -and $migrated.generation -eq 2 -and $migrated.removalBootSession -ceq '') 'An exact trusted nonpending legacy deployment migrates through the protected journal sequence.'
    $legacyPending=$migrated | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    $legacyPending.schema=2; foreach ($name in @('manifestId','publishedInfName','removalBootSession')) { $legacyPending.PSObject.Properties.Remove($name) }
    $legacyPending.removalPending=$true; $legacyPending.removalPhase='PendingReboot'; $legacyPending.rebootRequired=$true; $legacyPending.removalBootId='boot:2026-01-01T00:00:00.0000000Z'
    [IO.File]::WriteAllText($fixture.Record,($legacyPending | ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
    & $module { param($fs) $script:FixtureFileSystem=$fs; $script:SavedFileSystemFactory=${function:New-KnotJournalFileSystem}; function script:New-KnotJournalFileSystem([switch]$WithoutNative) { return $script:FixtureFileSystem } } $fixture.FileSystem
    try { $legacyState=Get-KnotHeadlessState; Assert ($legacyState.Managed -and $legacyState.Status -ceq 'LegacyRecoveryRequired' -and -not $legacyState.RebootRequired) 'Read-only legacy pending state directs manual recovery without repeating a restart requirement.' }
    finally { & $module { Set-Item Function:script:New-KnotJournalFileSystem $script:SavedFileSystemFactory } }
    foreach ($token in @('deployment','manifest','published-inf','boot-session','boot-identity','previous-hash')) {
        $j=$migrated | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        switch ($token) {
            'deployment' { $j.deploymentId+="`n"; $j.instanceId='ROOT\KNOTVDD\'+$j.deploymentId }
            'manifest' { $j.manifestId+="`n" }
            'published-inf' { $j.publishedInfName="oem42.inf`n" }
            'boot-session' { $j.removalPending=$true; $j.removalPhase='Started'; $j.rebootRequired=$true; $j.removalBootId='boot:2026-01-01T00:00:00.0000000Z'; $j.removalBootSession=('a'*32)+"`n" }
            'boot-identity' { $j.removalPending=$true; $j.removalPhase='Started'; $j.rebootRequired=$true; $j.removalBootId="boot:2026-01-01T00:00:00.0000000Z`n"; $j.removalBootSession='a'*32 }
            'previous-hash' { $j.previousRecordSha256+="`n" }
        }
        Reject { & $module { param($record) Assert-KnotJournal $record } $j } ('Strict recovery identity tokens reject trailing newlines: '+$token)
    }
    foreach ($bad in @('schema-type','manifest','inf-leading-zero','inf-overflow','boot-session-type')) {
        $j=$migrated | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        switch ($bad) {
            'schema-type' { $j.schema='3' }
            'manifest' { $j.manifestId='untrusted-profile' }
            'inf-leading-zero' { $j.publishedInfName='oem01.inf' }
            'inf-overflow' { $j.publishedInfName='oem4294967296.inf' }
            'boot-session-type' { $j.removalBootSession=42 }
        }
        Reject { & $module { param($record) Assert-KnotJournal $record } $j } ('Schema 3 rejects malformed authority: '+$bad)
    }
    $j=New-RemovalJournal
    $device=[pscustomobject]@{InstanceId=$j.instanceId;HardwareIds=@('Root\MttVDD');DriverVersion=$j.driverVersion;DriverInf='oem43.inf'}
    Reject { Assert-KnotDevices @($device) $j -Installed } 'An arbitrary OEM name cannot satisfy a schema 3 installed device identity.'
    Reject { Assert-KnotDevices @($device) $j } 'Recovery also rejects a changed nonempty published INF name.'
    $device.DriverInf='OEM42.INF'; Assert-KnotDevices @($device) $j -Installed; $script:Checks++

    function New-SyntheticFileSystem([object] $State) {
        # Explicit local capture works in both Windows PowerShell 5.1 and Core.
        # Windows paths are case insensitive; every fixture remains under its fresh root.
        $fixturePrefix=[IO.Path]::GetFullPath($root)+[IO.Path]::DirectorySeparatorChar
        $pathComparison=[StringComparison]::Ordinal
        if ([IO.Path]::DirectorySeparatorChar -eq [char]92) { $pathComparison=[StringComparison]::OrdinalIgnoreCase }
        return @{
            AssertDirectory={ param($path)
                $exists=[IO.Directory]::Exists($path)
                $inside=[IO.Path]::GetFullPath($path).StartsWith($fixturePrefix,$pathComparison)
                if (-not $exists -or -not $inside -or -not $State.AclAllowed) { throw "synthetic private directory guard (exists=$exists, withinFixture=$inside, acl=$($State.AclAllowed))" }
            }.GetNewClosure()
            AssertFile={ param($path) if (-not [IO.File]::Exists($path) -or ([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -or -not $State.AclAllowed -or $State.LinkCount -ne 1) { throw 'synthetic private file guard' } }.GetNewClosure()
            CreateDirectory={ param($path) if (Test-Path -LiteralPath $path) { throw 'synthetic existing path' }; [void][IO.Directory]::CreateDirectory($path); [void]$State.Created.Add($path) }.GetNewClosure()
            MoveDirectory={ param($source,$destination)
                if ($State.Fault -ceq 'before-directory-move') { throw 'synthetic crash before atomic directory publication' }
                if ($State.Fault -ceq 'directory-race') { [void][IO.Directory]::CreateDirectory($destination); [IO.File]::WriteAllText((Join-Path $destination 'foreign.txt'),'synthetic foreign') }
                [IO.Directory]::Move($source,$destination); [void]$State.Moved.Add($destination)
                if ($State.Fault -ceq 'after-directory-move') { throw 'synthetic crash after atomic directory publication' }
            }.GetNewClosure()
            Flush={ param($stream) $stream.Flush($true); $State.Flushes++; if ($State.FailFlush -gt 0 -and $State.Flushes -eq $State.FailFlush) { throw 'synthetic crash after durable file write' } }.GetNewClosure()
            OpenLock={ param($path) [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
            Replace={ param($source,$destination) [IO.File]::Replace($source,$destination,[NullString]::Value) }
            Move={ param($source,$destination) [IO.File]::Move($source,$destination) }
        }
    }
    function New-SyntheticFileState { return [pscustomobject]@{AclAllowed=$true;LinkCount=1;Fault='';FailFlush=0;Flushes=0;Created=(New-Object 'Collections.Generic.List[string]');Moved=(New-Object 'Collections.Generic.List[string]')} }
    & $module { $script:SavedControlDirectory=${function:Get-KnotControlDirectory}; function script:Get-KnotControlDirectory { return $script:SyntheticControlDirectory } }
    try {
        $control=Join-Path $root 'control'; & $module { param($path) $script:SyntheticControlDirectory=$path } $control
        $state=New-SyntheticFileState; $fs=New-SyntheticFileSystem $state
        $first=& $module { param($fs) Enter-KnotControlLock $fs } $fs
        try { Reject { & $module { param($fs) Enter-KnotControlLock $fs } $fs } 'A persistent protected FileShare.None lock rejects a concurrent operation.' }
        finally { $first.Dispose() }
        Assert ([IO.File]::Exists((Join-Path $control 'operation.lock')) -and [IO.File]::Exists((Join-Path $control 'control.json'))) 'Lock release leaves the exact marked control root and stable lock file.'
        $second=& $module { param($fs) Enter-KnotControlLock $fs } $fs; $second.Dispose(); $script:Checks++
        $lockOpened=[pscustomobject]@{Value=$false;Calls=0}
        $guardFs=New-SyntheticFileSystem $state
        $guardFs.AssertFile={ param($path) $lockOpened.Calls++; if ($lockOpened.Value) { throw 'a path/link-count reopen would conflict with the held exclusive handle' }; if (-not [IO.File]::Exists($path)) { throw 'missing synthetic control file' } }.GetNewClosure()
        $guardFs.OpenLock={ param($path) $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $lockOpened.Value=$true; return $stream }.GetNewClosure()
        $guarded=& $module { param($fs) Enter-KnotControlLock $fs } $guardFs
        $guarded.Dispose()
        Assert ($lockOpened.Value -and $lockOpened.Calls -ge 3) 'Exclusive acquisition performs all path/link validation before opening and never reopens its held lock.'
        $state.AclAllowed=$false
        Reject { & $module { param($fs) Enter-KnotControlLock $fs } $fs } 'An untrusted private control ACL cannot be adopted.'
        $state.AclAllowed=$true; $state.LinkCount=2
        Reject { & $module { param($fs) Enter-KnotControlLock $fs } $fs } 'A hard-linked control marker or lock file is rejected.'
        $state.LinkCount=1
        $unknown=Join-Path $root 'unmarked-control'; [void][IO.Directory]::CreateDirectory($unknown); [IO.File]::WriteAllText((Join-Path $unknown 'foreign.txt'),'synthetic foreign')
        & $module { param($path) $script:SyntheticControlDirectory=$path } $unknown
        Reject { & $module { param($fs) Enter-KnotControlLock $fs } $fs } 'An existing unmarked control directory is never adopted based only on its ACL.'
        Assert ([IO.File]::Exists((Join-Path $unknown 'foreign.txt'))) 'Unknown control content is preserved.'
        foreach ($fault in @('before-directory-move','after-directory-move','directory-race','flush')) {
            $path=Join-Path $root ('control-fault-'+[Guid]::NewGuid().ToString('N')); & $module { param($p) $script:SyntheticControlDirectory=$p } $path
            $state=New-SyntheticFileState; $fs=New-SyntheticFileSystem $state
            if ($fault -ceq 'flush') { $state.FailFlush=1 } else { $state.Fault=$fault }
            Reject { & $module { param($fs) Initialize-KnotControlDirectory $fs } $fs } ('Interrupt control-root publication: '+$fault)
            if ($fault -ceq 'after-directory-move') { Assert ([IO.File]::Exists((Join-Path $path 'control.json')) -and [IO.File]::Exists((Join-Path $path 'operation.lock'))) 'A control root appearing after atomic publication is complete.' }
            elseif ($fault -ceq 'directory-race') { Assert ([IO.File]::Exists((Join-Path $path 'foreign.txt'))) 'An atomic publication race preserves the foreign winner without adoption.' }
            else { Assert (-not [IO.Directory]::Exists($path) -and $state.Created.Count -eq 1) 'A prepublication crash leaves only a unique protected stage and no empty active control root.' }
        }

        # A torn successor is copied, flushed, hashed, and atomically quarantined
        # before the original is removed. The exact predecessor remains authority.
        $fixture=New-JournalFixture $pins; Write-FixtureJournal $fixture $pins
        [IO.File]::WriteAllText($fixture.Pending,'{"schema":3,')
        $pendingHash=Hash ([IO.File]::ReadAllBytes($fixture.Pending)); $recordHash=Hash ([IO.File]::ReadAllBytes($fixture.Record))
        $control=Join-Path $root ('quarantine-control-'+[Guid]::NewGuid().ToString('N')); & $module { param($path) $script:SyntheticControlDirectory=$path } $control
        $state=New-SyntheticFileState; $fs=New-SyntheticFileSystem $state
        $fs.Quarantine={ param($path,$record,$hash) & $module { param($path,$record,$hash,$fs) Preserve-KnotTornJournal $path $record $hash $fs } $path $record $hash $fs }.GetNewClosure()
        $fixture.FileSystem=$fs
        $read=Read-FixtureJournal $fixture $pins
        Assert ([IO.File]::Exists($fixture.Pending) -and $read.generation -eq 1) 'Read-only inspection of a torn successor does not discard bytes or query native state.'
        $read=Read-FixtureJournal $fixture $pins -Recover
        $quarantines=@([IO.Directory]::EnumerateDirectories($control,'quarantine-*'))
        Assert ($read.generation -eq 1 -and -not [IO.File]::Exists($fixture.Pending) -and $quarantines.Count -eq 1 -and (Hash ([IO.File]::ReadAllBytes((Join-Path $quarantines[0] 'recovery.new')))) -ceq $pendingHash -and (Hash ([IO.File]::ReadAllBytes($fixture.Record))) -ceq $recordHash) 'Torn successor recovery preserves exact forensic bytes and resumes the unchanged trusted predecessor.'
        $validated=& $module { param($fs) Initialize-KnotControlDirectory $fs } $fs
        Assert ($validated -ceq $control) 'Published quarantine metadata and content are revalidated on later control operations.'
        foreach ($bad in @('orphan','unknown-file','changed-file','parseable-hostile','complete-ambiguous')) {
            $fixture=New-JournalFixture $pins; Write-FixtureJournal $fixture $pins; $fixture.FileSystem=$fs
            [IO.File]::WriteAllText($fixture.Pending,'{"schema":3,')
            switch ($bad) {
                'orphan' { [IO.File]::Delete($fixture.Record) }
                'unknown-file' { [IO.File]::WriteAllText((Join-Path $fixture.Directory 'foreign.txt'),'synthetic foreign') }
                'changed-file' { [IO.File]::WriteAllText((Join-Path $fixture.Directory 'MttVDD.dll'),'synthetic changed') }
                'parseable-hostile' { [IO.File]::WriteAllText($fixture.Pending,'{"schema":3,"owner":"Other"}') }
                'complete-ambiguous' { [IO.File]::WriteAllText($fixture.Pending,'{"schema":3,"SCHEMA":3}') }
            }
            $before=Hash ([IO.File]::ReadAllBytes($fixture.Pending))
            Reject { Read-FixtureJournal $fixture $pins -Recover } ('Torn recovery lacks safe predecessor authority: '+$bad)
            Assert ([IO.File]::Exists($fixture.Pending) -and (Hash ([IO.File]::ReadAllBytes($fixture.Pending))) -ceq $before) 'Untrusted, orphaned, or parseable hostile successor bytes remain in place.'
        }
        # Compose the real exclusive-operation wrapper with interrupted recovery.
        # Any path-based reopen of its held operation.lock fails this adapter.
        $control=Join-Path $root ('held-control-'+[Guid]::NewGuid().ToString('N'))
        & $module { param($path) $script:SyntheticControlDirectory=$path } $control
        $state=New-SyntheticFileState; $heldState=[pscustomobject]@{Open=$false;Stream=$null;HandleChecks=0;ReopenAttempts=0}
        $heldFs=New-SyntheticFileSystem $state
        $ordinaryFileGuard=$heldFs.AssertFile
        $heldLockPath=Join-Path $control 'operation.lock'
        $heldFs.AssertFile={ param($path)
            if ($path -ceq $heldLockPath -and $heldState.Open) { $heldState.ReopenAttempts++; throw 'synthetic exclusive lock path reopen is forbidden' }
            & $ordinaryFileGuard $path
        }.GetNewClosure()
        $heldFs.OpenLock={ param($path)
            $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $heldState.Open=$true; $heldState.Stream=$stream; return $stream
        }.GetNewClosure()
        $heldFs.ValidateHeldLock={ param($context,$path)
            $heldState.HandleChecks++
            $moduleOwnsContext=& $module { param($value) [object]::ReferenceEquals($script:HeldControlLock,$value) } $context
            if (-not $moduleOwnsContext -or -not [object]::ReferenceEquals($context.Stream,$heldState.Stream) -or $context.Stream -isnot [IO.FileStream] -or -not $context.Stream.CanRead -or -not $context.Stream.CanWrite -or $context.Stream.SafeFileHandle.IsClosed -or $context.Stream.SafeFileHandle.IsInvalid -or $context.Path -cne $path -or $context.Stream.Name -cne $path -or $context.Stream.Length -ne 0) { throw 'synthetic held-handle identity verification failed' }
        }.GetNewClosure()
        & $module {
            param($fs)
            $script:SyntheticControlFileSystem=$fs; $script:SavedControlFactory=${function:New-KnotControlFileSystem}; $script:SavedElevatedRuntime=${function:Assert-KnotElevatedRuntime}
            function script:Assert-KnotElevatedRuntime { }
            function script:New-KnotControlFileSystem {
                $copy=@{}; foreach ($key in $script:SyntheticControlFileSystem.Keys) { $copy[$key]=$script:SyntheticControlFileSystem[$key] }
                $copy.HeldLockContext=$script:HeldControlLock
                return $copy
            }
        } $heldFs
        try {
            $fixture=New-JournalFixture $pins; Write-FixtureJournal $fixture $pins
            [IO.File]::WriteAllText($fixture.Pending,'{"schema":3,')
            $pendingHash=Hash ([IO.File]::ReadAllBytes($fixture.Pending)); $recordHash=Hash ([IO.File]::ReadAllBytes($fixture.Record))
            $heldFs.Quarantine={ param($path,$record,$hash) & $module { param($p,$j,$h) Preserve-KnotTornJournal $p $j $h (New-KnotControlFileSystem) } $path $record $hash }.GetNewClosure()
            & $module { param($fs) $script:SyntheticControlFileSystem=$fs } $heldFs
            $fixture.FileSystem=$heldFs
            $action={
                Reject { $conflict=[IO.File]::Open($heldLockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $conflict.Dispose() } 'A second actual FileStream open remains excluded while composed recovery holds its lock.'
                return Read-FixtureJournal $fixture $pins -Recover
            }.GetNewClosure()
            $read=& $module { param($action) Invoke-KnotExclusive $action } $action
            Assert ($read.generation -eq 1 -and -not [IO.File]::Exists($fixture.Pending) -and $heldState.HandleChecks -gt 0 -and $heldState.ReopenAttempts -eq 0 -and $heldState.Stream.SafeFileHandle.IsClosed) 'Exclusive recovery preserves evidence through the same live handle and clears/disposes its context after completion.'
            $contextCleared=& $module { $null -eq $script:HeldControlLock }
            $quarantines=@([IO.Directory]::EnumerateDirectories($control,'quarantine-*'))
            Assert ($contextCleared -and $quarantines.Count -eq 1 -and (Hash ([IO.File]::ReadAllBytes((Join-Path $quarantines[0] 'recovery.new')))) -ceq $pendingHash -and (Hash ([IO.File]::ReadAllBytes($fixture.Record))) -ceq $recordHash) 'The composed wrapper retains exact original evidence and predecessor bytes without an operation.lock path reopen.'
            $heldState.Open=$false
            # Fill only fresh synthetic audit evidence to the documented bound.
            for ($index=1; $index -lt 100; $index++) {
                $folder=Join-Path $control ('quarantine-'+[Guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($folder)
                $evidence=[Text.Encoding]::UTF8.GetBytes('synthetic capacity evidence '+$index)
                [IO.File]::WriteAllBytes((Join-Path $folder 'recovery.new'),$evidence)
                $metadata=[pscustomobject]@{schema=1;deploymentId=('A'*32);sourceName='recovery.new';sha256=(Hash $evidence)}
                [IO.File]::WriteAllText((Join-Path $folder 'evidence.json'),($metadata | ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
            }
            $fixture=New-JournalFixture $pins; Write-FixtureJournal $fixture $pins; $fixture.FileSystem=$heldFs
            [IO.File]::WriteAllText($fixture.Pending,'{"schema":3,'); $pendingHash=Hash ([IO.File]::ReadAllBytes($fixture.Pending)); $createdBefore=$state.Created.Count; $flushBefore=$state.Flushes
            $action={ Read-FixtureJournal $fixture $pins -Recover }.GetNewClosure()
            Reject { & $module { param($action) Invoke-KnotExclusive $action } $action } 'A full protected evidence inventory refuses another quarantine before creating a stage.'
            Assert ([IO.File]::Exists($fixture.Pending) -and (Hash ([IO.File]::ReadAllBytes($fixture.Pending))) -ceq $pendingHash -and @([IO.Directory]::EnumerateFileSystemEntries($control)).Count -eq 102 -and $state.Created.Count -eq $createdBefore -and $state.Flushes -eq $flushBefore -and $heldState.ReopenAttempts -eq 0) 'Capacity refusal leaves the original interrupted bytes untouched and writes no new stage or evidence.'
            Assert ($heldState.Stream.SafeFileHandle.IsClosed -and (& $module { $null -eq $script:HeldControlLock })) 'Failed composed recovery still disposes and clears the exact held lock context.'
        } finally {
            & $module { Set-Item Function:script:New-KnotControlFileSystem $script:SavedControlFactory; Set-Item Function:script:Assert-KnotElevatedRuntime $script:SavedElevatedRuntime; $script:HeldControlLock=$null }
        }
    } finally { & $module { Set-Item Function:script:Get-KnotControlDirectory $script:SavedControlDirectory } }

    # Stage all deployment files plus their canonical journal before one directory
    # rename. These fixtures use a test-only trusted source profile, never a driver.
    $sourceSettings=[IO.File]::ReadAllBytes((Join-Path (Split-Path $PSScriptRoot -Parent) 'Knot-vdd_settings.xml'))
    $testFiles=@(); $testPayload=@{}
    foreach ($name in @('mttvdd.cat','MttVDD.dll','MttVDD.inf')) { $bytes=[Text.Encoding]::UTF8.GetBytes('fresh-synthetic-'+$name); $testPayload['VirtualDisplayDriver/'+$name]=$bytes; $testFiles += [pscustomobject]@{name=$name;bytes=$bytes.Length;sha256=(Hash $bytes)} }
    $testFiles += [pscustomobject]@{name='vdd_settings.xml';bytes=$sourceSettings.Length;sha256=(Hash $sourceSettings)}
    $testProfile=[pscustomobject]@{manifestId='synthetic-v1';archiveSha256=('2'*64);driverVersion='11.30.4.434';catalogSignerCertificateSha256=('3'*64);files=$testFiles}
    $testProfiles=[pscustomobject]@{schema=1;currentManifestId='synthetic-v1';legacySchema2ManifestIds=@('synthetic-v1');profiles=@($testProfile)}
    $testPins=[pscustomobject]@{Dependency=[pscustomobject]@{sha256=$testProfile.archiveSha256;driverVersion=$testProfile.driverVersion;catalogSignerCertificateSha256=$testProfile.catalogSignerCertificateSha256;settingsSha256=(Hash $sourceSettings)};Inventory=[pscustomobject]@{files=@($testFiles | Where-Object { $_.name -cne 'vdd_settings.xml' } | ForEach-Object { [pscustomobject]@{path=('VirtualDisplayDriver/'+$_.name);bytes=$_.bytes;sha256=$_.sha256} })}}
    & $module { param($profiles) $script:SyntheticProfiles=$profiles; $script:SavedProfileReader=${function:Read-KnotDeploymentProfiles}; function script:Read-KnotDeploymentProfiles { return $script:SyntheticProfiles } } $testProfiles
    try {
        foreach ($fault in @('flush-first','flush-file','before-directory-move','after-directory-move','directory-race','')) {
            $path=Join-Path $root ('publish-'+[Guid]::NewGuid().ToString('N')); & $module { param($p) $script:SyntheticDirectory=$p } $path
            $j=& $module { param($p) New-KnotJournal $p } $testPins
            $state=New-SyntheticFileState; $fs=New-SyntheticFileSystem $state
            switch ($fault) { 'flush-first' { $state.FailFlush=1 }; 'flush-file' { $state.FailFlush=3 }; default { $state.Fault=$fault } }
            $action={ & $module { param($j,$pins,$payload,$fs) Publish-KnotDeployment $j $pins $payload $fs } $j $testPins $testPayload $fs }.GetNewClosure()
            if ($fault) { Reject $action ('Interrupt whole deployment publication: '+$fault) } else { & $action; $script:Checks++ }
            if ($fault -cin @('','after-directory-move')) {
                Assert (@([IO.Directory]::EnumerateFileSystemEntries($path)).Count -eq 5) 'An active deployment appears with all four files and the complete protected journal in one publication.'
                $stored=[IO.File]::ReadAllText((Join-Path $path 'recovery.json')) | ConvertFrom-Json
                Assert ($stored.directory -ceq $path -and $stored.directory -cne $state.Created[0]) 'Physical staging never changes the canonical recorded deployment identity.'
                if ($fault -ceq '') { $complete=[pscustomobject]@{Journal=$j;Directory=$path;State=$state;FileSystem=$fs} }
            } elseif ($fault -ceq 'directory-race') { Assert ([IO.File]::Exists((Join-Path $path 'foreign.txt'))) 'Publication never replaces a foreign directory that wins the rename race.' }
            else { Assert (-not [IO.Directory]::Exists($path) -and $state.Created.Count -eq 1) 'Staging faults preserve the unique stage without creating an empty active deployment.' }
        }
        foreach ($fault in @('before-directory-move','after-directory-move','')) {
            $path=Join-Path $root ('retire-'+[Guid]::NewGuid().ToString('N')); & $module { param($p) $script:SyntheticDirectory=$p } $path
            $j=& $module { param($p) New-KnotJournal $p } $testPins; $state=New-SyntheticFileState; $fs=New-SyntheticFileSystem $state
            & $module { param($j,$pins,$payload,$fs) Publish-KnotDeployment $j $pins $payload $fs } $j $testPins $testPayload $fs
            $j.removalPending=$true; $j.removalPhase='Ready'; $j.removalBootId='boot:2026-01-01T00:00:00.0000000Z'; $j.removalBootSession='a'*32
            & $module { param($j,$fs) Write-KnotJournal $j $null $fs } $j $fs
            $state.Fault=$fault
            $action={ & $module { param($j,$fs) Retire-KnotDeployment $j $fs } $j $fs }.GetNewClosure()
            if ($fault) { Reject $action ('Interrupt atomic retirement: '+$fault) } else { & $action; $script:Checks++ }
            if ($fault -ceq 'before-directory-move') { Assert ([IO.File]::Exists((Join-Path $path 'recovery.json')) -and @([IO.Directory]::EnumerateFileSystemEntries($path)).Count -eq 5) 'A crash before retirement keeps all active ownership evidence and payload bytes.' }
            elseif ($fault -ceq 'after-directory-move') { $retired=$state.Moved[$state.Moved.Count-1]; Assert (-not [IO.Directory]::Exists($path) -and [IO.File]::Exists((Join-Path $retired 'recovery.json')) -and @([IO.Directory]::EnumerateFileSystemEntries($retired)).Count -eq 5) 'A crash after retirement preserves the complete journal outside the active path.' }
            else { Assert (-not [IO.Directory]::Exists($path) -and -not [IO.Directory]::Exists($state.Moved[$state.Moved.Count-1])) 'Completed retirement deletes only the exact validated deployment after its active path is gone.' }
        }
    } finally { & $module { Set-Item Function:script:Read-KnotDeploymentProfiles $script:SavedProfileReader } }
    Write-Output ('Headless setup synthetic checks passed: '+$script:Checks)
    [pscustomobject]@{status='passed';checks=$script:Checks;freshSyntheticOnly=$true;nativeApisInvoked=$false} | ConvertTo-Json -Compress
} finally {
    Remove-Module HeadlessSetup -Force -ErrorAction SilentlyContinue
    # The uniquely named test directory contains only fixtures generated by this test.
    [IO.Directory]::Delete($root,$true)
}
