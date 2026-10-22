#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Importing this module does not compile code, enumerate devices, or change the machine.
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'SetupContract.psm1') -ErrorAction Stop
$script:RegistryPath = 'SOFTWARE\MikeTheTech\VirtualDisplayDriver'
$script:TrustedSids = @('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')

function Get-KnotHash([byte[]] $Bytes) {
    $algorithm=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}
function Get-KnotDirectory { return Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'KnotVirtualDisplay' }
function Assert-KnotAncestors([string] $Path) {
    $parent=[IO.DirectoryInfo]([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path)))
    $danger=0x50000000 -bor 65536 -bor 262144 -bor 524288 -bor 64
    while ($parent) {
        Assert-NoReparsePath $parent.FullName
        $acl=Get-Acl -LiteralPath $parent.FullName
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $script:TrustedSids) { throw 'The virtual display path has an untrusted ancestor.' }
        foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -eq 'Allow' -and -not ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and $rule.IdentityReference.Value -notin $script:TrustedSids -and (([int]$rule.FileSystemRights) -band $danger)) { throw 'The virtual display path permits untrusted rename or permission changes.' }
        }
        $parent=$parent.Parent
    }
}
function Assert-KnotFile([string] $Path) {
    Assert-ProtectedFile $Path
    if ([Knot.Headless.Native]::GetFileLinkCount($Path) -ne 1) { throw 'Virtual display files must not have hard links.' }
}
function New-KnotDirectory([string] $Path) {
    Assert-KnotAncestors $Path
    if (Test-Path -LiteralPath $Path) { throw 'The virtual display directory already exists; it will not be adopted.' }
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) { $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))) }
    # UMDF Wudfhost normally runs as LOCAL SERVICE. It needs read access to
    # vdd_settings.xml, but must not write settings or logs in this owned folder.
    foreach ($sid in @('S-1-5-32-545','S-1-5-19')) { $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))) }
    [void][IO.Directory]::CreateDirectory($Path,$acl)
    Assert-ProtectedDirectory $Path
    if (@([IO.Directory]::EnumerateFileSystemEntries($Path)).Count -ne 0) { throw 'The new virtual display directory is not empty.' }
}
function Initialize-KnotHeadlessNative([switch] $Protected) {
    if ('Knot.Headless.Native' -as [type]) { return }
    $source=Join-Path $PSScriptRoot 'HeadlessNative.cs'
    if ($Protected) {
        Assert-KnotAncestors $source
        Assert-ProtectedFile $source
        Invoke-ProtectedCompilation -TypeDefinition ([IO.File]::ReadAllText($source))
        Assert-KnotFile $source
    } else {
        # The desktop launcher owns its freshly copied, non-elevated source stage.
        Add-Type -TypeDefinition ([IO.File]::ReadAllText($source)) -ErrorAction Stop
    }
}
function Read-KnotDependency {
    $dependencyPath=Join-Path $PSScriptRoot 'VirtualDisplayDependency.json'
    $inventoryPath=Join-Path $PSScriptRoot 'VirtualDisplayFiles.json'
    $dependency=[IO.File]::ReadAllText($dependencyPath) | ConvertFrom-Json
    $inventory=[IO.File]::ReadAllText($inventoryPath) | ConvertFrom-Json
    if ($dependency.schema -ne 1 -or $dependency.bytes -ne 132118 -or $dependency.sha256 -cne 'e24210692b442b39af763536330ce78b423f19342b7a7792c26de3944e418b3a' -or $dependency.driverVersion -cne '11.30.4.434' -or $dependency.catalogSignerCertificateSha256 -cne '69dfd3e1cbd49f039463edfe4c0d876c1dc7fdcd3aef08700a41355dc6c15fdb' -or $dependency.settingsSha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'The bundled virtual display dependency manifest is invalid.' }
    Assert-KnotInventory $inventory
    return [pscustomobject]@{Dependency=$dependency;Inventory=$inventory}
}
function Assert-KnotInstallPolicy([object] $Dependency) {
    # Default deny: a download/signature pin establishes provenance, not driver
    # safety. A future accepted release needs an explicit source-reviewed change.
    if (-not $Dependency -or -not $Dependency.PSObject.Properties['installEnabled'] -or -not $Dependency.PSObject.Properties['driverSafetyReviewStatus'] -or $Dependency.installEnabled -isnot [bool] -or -not $Dependency.installEnabled -or $Dependency.driverSafetyReviewStatus -isnot [string] -or $Dependency.driverSafetyReviewStatus -cne 'accepted') { throw 'Installation of this bundled virtual display driver is disabled pending its security review.' }
}
function Get-KnotHeadlessAvailability {
    try {
        $pins=Read-KnotDependency
        try { Assert-KnotInstallPolicy $pins.Dependency }
        catch { return [pscustomobject]@{Enabled=$false;Reason='upstream-ipc-review'} }
        return [pscustomobject]@{Enabled=$true;Reason='accepted'}
    } catch { return [pscustomobject]@{Enabled=$false;Reason='manifest-invalid'} }
}
function Assert-KnotInventory([object] $Inventory) {
    $names=@('VirtualDisplayDriver/mttvdd.cat','VirtualDisplayDriver/MttVDD.dll','VirtualDisplayDriver/MttVDD.inf','VirtualDisplayDriver/vdd_settings.xml')
    if ($Inventory.schema -ne 1 -or @($Inventory.files).Count -ne 4) { throw 'The driver inventory must contain exactly four files.' }
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $total=0L
    foreach ($file in $Inventory.files) {
        if ($file.path -cnotin $names -or -not $seen.Add([string]$file.path) -or $file.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $file.bytes -le 0 -or $file.bytes -gt 300000) { throw 'The driver inventory is invalid.' }
        $total += [long]$file.bytes
    }
    if ($total -gt 400000) { throw 'The driver inventory is too large.' }
}
function Read-KnotDriverArchive([string] $ArchivePath,[object] $Dependency,[object] $Inventory) {
    # Pure bounded parser, also used with fresh synthetic ZIP fixtures in tests.
    Assert-KnotInventory $Inventory
    $item=Get-Item -LiteralPath $ArchivePath -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -ne $Dependency.bytes -or $item.Length -gt 1000000) { throw 'The driver archive size or file type is invalid.' }
    $archiveBytes=[IO.File]::ReadAllBytes($ArchivePath)
    if ((Get-KnotHash $archiveBytes) -cne $Dependency.sha256) { throw 'The driver archive hash does not match the pinned release.' }
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    $memory=New-Object IO.MemoryStream(,$archiveBytes)
    $zip=$null
    try {
        $zip=New-Object IO.Compression.ZipArchive($memory,[IO.Compression.ZipArchiveMode]::Read,$false)
        if ($zip.Entries.Count -lt 4 -or $zip.Entries.Count -gt 5) { throw 'The driver archive has an unexpected entry count.' }
        $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $result=@{}
        foreach ($entry in $zip.Entries) {
            if (-not $seen.Add($entry.FullName)) { throw 'The driver archive contains duplicate or case-colliding entries.' }
            $unixType=(([long]$entry.ExternalAttributes -shr 16) -band 61440)
            if ($entry.FullName -ceq 'VirtualDisplayDriver/') {
                if ($entry.Length -ne 0 -or $unixType -notin @(0,16384)) { throw 'The driver archive directory entry is invalid.' }
                continue
            }
            $expected=@($Inventory.files | Where-Object { $_.path -ceq $entry.FullName })
            if ($expected.Count -ne 1 -or $unixType -notin @(0,32768) -or (($entry.ExternalAttributes -band 1024) -ne 0)) { throw 'The driver archive contains an unexpected path or special file.' }
            $expected=$expected[0]
            if ($entry.Length -ne $expected.bytes -or $entry.CompressedLength -le 0 -or $entry.Length -gt 300000 -or $entry.Length -gt (1000L * $entry.CompressedLength)) { throw 'The driver archive entry exceeds its pinned bounds.' }
            $inputStream=$entry.Open(); $output=New-Object IO.MemoryStream
            try {
                $buffer=New-Object byte[] 8192; $count=0L
                while (($read=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                    $count += $read
                    if ($count -gt $expected.bytes) { throw 'The driver archive entry expands beyond its pinned size.' }
                    $output.Write($buffer,0,$read)
                }
                $bytes=$output.ToArray()
                if ($count -ne $expected.bytes -or (Get-KnotHash $bytes) -cne $expected.sha256) { throw 'The driver archive file does not match its pinned contents.' }
                $result[$entry.FullName]=$bytes
            } finally { $inputStream.Dispose(); $output.Dispose() }
        }
        if ($result.Count -ne 4) { throw 'The driver archive is incomplete.' }
        return $result
    } finally { if ($zip) { $zip.Dispose() }; $memory.Dispose() }
}
function Assert-KnotCatalogSignature([object] $Signature,[string] $CertificateHash) {
    if ([string]$Signature.Status -cne 'Valid' -or -not $Signature.SignerCertificate -or (Get-KnotHash $Signature.SignerCertificate.RawData) -cne $CertificateHash) { throw 'Windows could not verify the pinned virtual display catalog signer.' }
}
function Assert-KnotDriverPackage([hashtable] $Payload) {
    $dll=[byte[]]$Payload['VirtualDisplayDriver/MttVDD.dll']
    if ($dll.Length -lt 256 -or $dll[0] -ne 77 -or $dll[1] -ne 90) { throw 'The driver is not a Windows executable.' }
    $pe=[BitConverter]::ToInt32($dll,60)
    if ($pe -lt 64 -or $pe -gt ($dll.Length-26) -or [BitConverter]::ToUInt32($dll,$pe) -ne 17744 -or [BitConverter]::ToUInt16($dll,$pe+4) -ne 34404 -or [BitConverter]::ToUInt16($dll,$pe+24) -ne 523) { throw 'The virtual display driver must be an AMD64 PE32+ binary.' }
    $infBytes=[byte[]]$Payload['VirtualDisplayDriver/MttVDD.inf']
    if ($infBytes.Length -lt 4 -or ($infBytes.Length % 2) -ne 0 -or $infBytes[0] -ne 255 -or $infBytes[1] -ne 254) { throw 'The pinned driver INF must be UTF-16 little-endian.' }
    $inf=[Text.Encoding]::Unicode.GetString($infBytes,2,$infBytes.Length-2)
    if ($inf -notmatch '(?im)^Class\s*=\s*Display\s*$' -or $inf -notmatch '(?im)^ClassGUID\s*=\s*\{4D36E968-E325-11CE-BFC1-08002BE10318\}\s*$' -or $inf -notmatch '(?im)^DriverVer\s*=\s*12/24/2024,11\.30\.4\.434\s*$' -or $inf -notmatch '(?im)^%ManufacturerName%\s*=\s*Standard,NTamd64\s*$' -or $inf -notmatch '(?im)^%DeviceName%\s*=\s*MyDevice_Install,\s*Root\\MttVDD\s*(;.*)?$' -or $inf -notmatch '(?im)^CatalogFile\s*=\s*MttVDD\.cat\s*$') { throw 'The virtual display INF architecture or hardware contract is invalid.' }
}
function New-KnotJournal([object] $Pins) {
    $id=[Guid]::NewGuid().ToString('N').ToUpperInvariant()
    $files=@()
    foreach ($file in $Pins.Inventory.files) {
        if ($file.path -ceq 'VirtualDisplayDriver/vdd_settings.xml') { continue }
        $files += [pscustomobject]@{name=([IO.Path]::GetFileName($file.path));bytes=[long]$file.bytes;sha256=$file.sha256}
    }
    $settings=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'Knot-vdd_settings.xml'))
    if ((Get-KnotHash $settings) -cne $Pins.Dependency.settingsSha256) { throw 'The fixed virtual display settings failed verification.' }
    $files += [pscustomobject]@{name='vdd_settings.xml';bytes=$settings.Length;sha256=$Pins.Dependency.settingsSha256}
    return [pscustomobject]@{schema=2;owner='Knot';deploymentId=$id;instanceId=('ROOT\KNOTVDD\'+$id);status='Prepared';rebootRequired=$false;removalPending=$false;removalPhase='None';removalBootId='';generation=1;previousRecordSha256='';directory=(Get-KnotDirectory);registryPath=$script:RegistryPath;archiveSha256=$Pins.Dependency.sha256;driverVersion=$Pins.Dependency.driverVersion;catalogSignerCertificateSha256=$Pins.Dependency.catalogSignerCertificateSha256;files=$files}
}
function Assert-KnotJournal([object] $Journal,[object] $Pins) {
    $properties=@('schema','owner','deploymentId','instanceId','status','rebootRequired','removalPending','removalPhase','removalBootId','generation','previousRecordSha256','directory','registryPath','archiveSha256','driverVersion','catalogSignerCertificateSha256','files')
    if (@($Journal.PSObject.Properties).Count -ne $properties.Count) { throw 'The virtual display recovery record has unknown fields.' }
    foreach ($property in $properties) { if ($null -eq $Journal.PSObject.Properties[$property]) { throw 'The virtual display recovery record is incomplete.' } }
    if ($Journal.schema -ne 2 -or $Journal.owner -cne 'Knot' -or $Journal.deploymentId -cnotmatch '^[0-9A-F]{32}$' -or $Journal.instanceId -cne ('ROOT\KNOTVDD\'+$Journal.deploymentId) -or $Journal.status -cnotin @('Prepared','Installed') -or $Journal.rebootRequired -isnot [bool] -or $Journal.removalPending -isnot [bool] -or $Journal.directory -cne (Get-KnotDirectory) -or $Journal.registryPath -cne $script:RegistryPath -or $Journal.archiveSha256 -cne $Pins.Dependency.sha256 -or $Journal.driverVersion -cne $Pins.Dependency.driverVersion -or $Journal.catalogSignerCertificateSha256 -cne $Pins.Dependency.catalogSignerCertificateSha256) { throw 'The virtual display recovery record is not owned by this package.' }
    if (($Journal.generation -isnot [int] -and $Journal.generation -isnot [long]) -or $Journal.generation -lt 1 -or $Journal.generation -gt 1000000 -or $Journal.previousRecordSha256 -isnot [string] -or ($Journal.generation -eq 1 -and $Journal.previousRecordSha256 -cne '') -or ($Journal.generation -gt 1 -and $Journal.previousRecordSha256 -cnotmatch '^[a-f0-9]{64}$')) { throw 'The recovery record sequence is invalid.' }
    if ($Journal.removalPhase -cnotin @('None','Started','PendingReboot','Ready') -or $Journal.removalBootId -isnot [string]) { throw 'The recovery removal phase is invalid.' }
    if ($Journal.removalPhase -ceq 'None') {
        if ($Journal.removalPending -or $Journal.removalBootId -cne '') { throw 'The recovery removal phase is inconsistent.' }
    } elseif (-not $Journal.removalPending -or -not (Test-KnotBootIdentity $Journal.removalBootId) -or ($Journal.removalPhase -ceq 'Ready' -and $Journal.rebootRequired) -or ($Journal.removalPhase -cne 'Ready' -and -not $Journal.rebootRequired)) { throw 'The recovery removal outcome or boot identity is invalid.' }
    $expected=New-KnotJournal $Pins
    if (@($Journal.files).Count -ne 4) { throw 'The recovery file inventory is invalid.' }
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $Journal.files) {
        $match=@($expected.files | Where-Object { $_.name -ceq $file.name -and $_.bytes -eq $file.bytes -and $_.sha256 -ceq $file.sha256 })
        if ($match.Count -ne 1 -or -not $seen.Add([string]$file.name)) { throw 'The recovery file inventory changed.' }
    }
}
function Test-KnotBootIdentity([object] $Value) {
    # Prefix prevents newer ConvertFrom-Json versions coercing an ISO timestamp
    # into DateTime while Windows PowerShell 5.1 keeps it as a string.
    if ($Value -isnot [string] -or $Value -cnotmatch '^boot:\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') { return $false }
    $parsed=[DateTime]::MinValue
    return [DateTime]::TryParseExact($Value.Substring(5),'O',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)
}
function Get-KnotBootIdentity {
    # Elevated operations only. UI state parsing never calls CIM or this function.
    try {
        $os=@(Get-CimInstance -ClassName Win32_OperatingSystem -Property LastBootUpTime -OperationTimeoutSec 5 -ErrorAction Stop)
        if ($os.Count -ne 1 -or $os[0].LastBootUpTime -isnot [DateTime]) { return $null }
        $value='boot:'+$os[0].LastBootUpTime.ToUniversalTime().ToString('O',[Globalization.CultureInfo]::InvariantCulture)
        if (Test-KnotBootIdentity $value) { return $value }
    } catch { return $null }
    return $null
}
function New-KnotJournalFileSystem([switch] $WithoutNative) {
    $assertFile={ param($path) Assert-KnotFile $path }
    if ($WithoutNative) { $assertFile={ param($path) Assert-ProtectedFile $path } }
    return @{
        AssertDirectory={ param($path) Assert-KnotAncestors $path; Assert-ProtectedDirectory $path }
        AssertFile=$assertFile
        Flush={ param($stream) $stream.Flush($true) }
        Replace={ param($source,$destination) [IO.File]::Replace($source,$destination,[NullString]::Value) }
        Move={ param($source,$destination) [IO.File]::Move($source,$destination) }
    }
}
function Read-KnotJournalFile([string] $Path,[object] $Pins,[hashtable] $FileSystem) {
    & $FileSystem.AssertFile $Path
    if ((Get-Item -LiteralPath $Path).Length -gt 16384) { throw 'The virtual display recovery record is too large.' }
    $bytes=[IO.File]::ReadAllBytes($Path)
    $journal=[Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    Assert-KnotJournal $journal $Pins
    return [pscustomobject]@{Journal=$journal;Hash=(Get-KnotHash $bytes)}
}
function Assert-KnotJournalSuccessor([object] $Previous,[object] $Next,[string] $PreviousHash) {
    foreach ($name in @('schema','owner','deploymentId','instanceId','directory','registryPath','archiveSha256','driverVersion','catalogSignerCertificateSha256')) {
        if ($Previous.$name -cne $Next.$name) { throw 'The interrupted recovery update belongs to a different deployment.' }
    }
    if ($Next.generation -ne ($Previous.generation+1) -or $Next.previousRecordSha256 -cne $PreviousHash -or ($Previous.files | ConvertTo-Json -Depth 4 -Compress) -cne ($Next.files | ConvertTo-Json -Depth 4 -Compress)) { throw 'The interrupted recovery update is not the exact successor of the protected record.' }
    $from=$Previous.removalPhase; $to=$Next.removalPhase
    $sameBoot=$Previous.removalBootId -ceq $Next.removalBootId
    $allowed=($from -ceq 'None' -and $to -cin @('None','Started','Ready')) -or
        ($from -ceq 'Started' -and $sameBoot -and $to -cin @('PendingReboot','Ready')) -or
        ($from -cin @('Started','PendingReboot') -and -not $sameBoot -and $to -cin @('Started','Ready')) -or
        ($from -ceq 'Ready' -and $to -ceq 'Started') -or ($from -ceq 'Ready' -and $to -ceq 'Ready' -and $sameBoot)
    if (-not $allowed) { throw 'The interrupted recovery update has an invalid state transition.' }
    if ($Previous.status -cne $Next.status -and -not ($Previous.status -ceq 'Prepared' -and $Next.status -ceq 'Installed' -and $from -ceq 'None' -and $to -ceq 'None') -and -not ($Previous.status -ceq 'Installed' -and $Next.status -ceq 'Prepared' -and $from -ceq 'Ready' -and $to -ceq 'Ready')) { throw 'The interrupted recovery update has an invalid installation transition.' }
}
function Assert-KnotInitialJournal([object] $Journal) {
    if ($Journal.generation -ne 1 -or $Journal.previousRecordSha256 -cne '' -or $Journal.status -cne 'Prepared' -or $Journal.removalPhase -cne 'None' -or $Journal.rebootRequired -or $Journal.removalPending) { throw 'An orphan recovery update is not an initial prepared record.' }
}
function Write-KnotJournal([object] $Journal,[object] $Pins=$null,[hashtable] $FileSystem=$null) {
    if (-not $Pins) { $Pins=Read-KnotDependency }
    if (-not $FileSystem) { $FileSystem=New-KnotJournalFileSystem }
    $path=Join-Path $Journal.directory 'recovery.json'
    $temporary=Join-Path $Journal.directory 'recovery.new'
    & $FileSystem.AssertDirectory $Journal.directory
    if (Test-Path -LiteralPath $temporary) { throw 'Verify and recover the interrupted journal update before making another change.' }
    $candidate=$Journal | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    if (Test-Path -LiteralPath $path) {
        $previous=Read-KnotJournalFile $path $Pins $FileSystem
        if ($candidate.generation -ne $previous.Journal.generation -or $candidate.previousRecordSha256 -cne $previous.Journal.previousRecordSha256) { throw 'The recovery record changed before this update.' }
        $candidate.generation=$previous.Journal.generation+1; $candidate.previousRecordSha256=$previous.Hash
        Assert-KnotJournal $candidate $Pins
        Assert-KnotJournalSuccessor $previous.Journal $candidate $previous.Hash
    } else {
        Assert-KnotJournal $candidate $Pins
        Assert-KnotInitialJournal $candidate
        if (@([IO.Directory]::EnumerateFileSystemEntries($Journal.directory)).Count -ne 0) { throw 'An initial recovery record requires the new empty owned directory.' }
    }
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes(($candidate | ConvertTo-Json -Depth 6))
    $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length); & $FileSystem.Flush $stream } finally { $stream.Dispose() }
    $written=Read-KnotJournalFile $temporary $Pins $FileSystem
    if ($written.Hash -cne (Get-KnotHash $bytes)) { throw 'The interrupted recovery update changed while being written.' }
    if (Test-Path -LiteralPath $path) { & $FileSystem.AssertFile $path; & $FileSystem.Replace $temporary $path }
    else { & $FileSystem.Move $temporary $path }
    $Journal.generation=$candidate.generation; $Journal.previousRecordSha256=$candidate.previousRecordSha256
}
function Read-KnotJournal([object] $Pins,[switch] $WithoutNative,[switch] $Recover,[hashtable] $FileSystem=$null) {
    if ($WithoutNative -and $Recover) { throw 'Read-only journal inspection cannot promote recovery records.' }
    if (-not $FileSystem) { $FileSystem=New-KnotJournalFileSystem -WithoutNative:$WithoutNative }
    $directory=Get-KnotDirectory
    & $FileSystem.AssertDirectory $directory
    $path=Join-Path $directory 'recovery.json'
    $temporary=Join-Path $directory 'recovery.new'
    $previous=$null
    if (Test-Path -LiteralPath $path) { $previous=Read-KnotJournalFile $path $Pins $FileSystem }
    if (Test-Path -LiteralPath $temporary) {
        $pending=Read-KnotJournalFile $temporary $Pins $FileSystem
        if ($previous) { Assert-KnotJournalSuccessor $previous.Journal $pending.Journal $previous.Hash }
        else {
            Assert-KnotInitialJournal $pending.Journal
            if (@([IO.Directory]::EnumerateFileSystemEntries($directory)).Count -ne 1) { throw 'An orphan initial recovery record has unexpected accompanying resources.' }
        }
        Assert-KnotOwnedFiles $pending.Journal -ValidatedPendingJournal -FileSystem $FileSystem
        if ($Recover) {
            if ($previous) { & $FileSystem.Replace $temporary $path }
            else { & $FileSystem.Move $temporary $path }
        }
        return $pending.Journal
    }
    if (-not $previous) { throw 'No protected virtual display recovery record exists.' }
    Assert-KnotOwnedFiles $previous.Journal -FileSystem $FileSystem
    return $previous.Journal
}
function Assert-KnotOwnedFiles([object] $Journal,[switch] $WithoutNative,[switch] $ValidatedPendingJournal,[hashtable] $FileSystem=$null) {
    if (-not $FileSystem) { $FileSystem=New-KnotJournalFileSystem -WithoutNative:$WithoutNative }
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($Journal.directory)) {
        $name=[IO.Path]::GetFileName($entry)
        if ($name -ceq 'recovery.json') { continue }
        if ($ValidatedPendingJournal -and $name -ceq 'recovery.new') { continue }
        $expected=@($Journal.files | Where-Object { $_.name -ceq $name })
        if ($expected.Count -ne 1) { throw 'The managed virtual display folder contains unknown files; all content was preserved.' }
        & $FileSystem.AssertFile $entry
        $item=Get-Item -LiteralPath $entry
        if ($item.Length -ne $expected[0].bytes -or (Get-KnotHash ([IO.File]::ReadAllBytes($entry))) -cne $expected[0].sha256) { throw 'The virtual display settings or package changed; all content was preserved.' }
    }
    if ($Journal.status -ceq 'Installed') {
        foreach ($file in $Journal.files) { if (-not [IO.File]::Exists((Join-Path $Journal.directory $file.name))) { throw 'An installed virtual display file is missing.' } }
    }
}
function Assert-KnotRegistryAcl([Microsoft.Win32.RegistryKey] $Key) {
    $acl=$Key.GetAccessControl()
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $script:TrustedSids) { throw 'The virtual display registry parent has an untrusted owner.' }
    foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($rule.IdentityReference.Value -eq 'S-1-3-0' -and ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $script:TrustedSids -and (([int]$rule.RegistryRights) -band (0x50000000 -bor 2 -bor 4 -bor 32 -bor 65536 -bor 262144 -bor 524288))) { throw 'The virtual display registry parent permits untrusted changes.' }
    }
}
function Open-KnotRegistry { return [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64) }
function Assert-KnotRegistryParents([Microsoft.Win32.RegistryKey] $Base) {
    Assert-KnotRegistryAcl $Base
    foreach ($path in @('SOFTWARE','SOFTWARE\MikeTheTech')) {
        $key=$Base.OpenSubKey($path,$false)
        try { if ($key) { Assert-KnotRegistryAcl $key } } finally { if ($key) { $key.Dispose() } }
    }
}
function Assert-KnotRegistryAbsent {
    $base=Open-KnotRegistry
    try {
        Assert-KnotRegistryParents $base
        $key=$base.OpenSubKey($script:RegistryPath,$false)
        if ($key) { $key.Dispose(); throw 'An existing VirtualDisplayDriver registry key will not be adopted or changed.' }
    } finally { $base.Dispose() }
}
function New-KnotRegistrySecurity {
    $acl=New-Object Security.AccessControl.RegistrySecurity
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) { $acl.AddAccessRule((New-Object Security.AccessControl.RegistryAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit','None','Allow'))) }
    foreach ($sid in @('S-1-5-32-545','S-1-5-19')) { $acl.AddAccessRule((New-Object Security.AccessControl.RegistryAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'ReadKey','ContainerInherit','None','Allow'))) }
    return $acl
}
function Set-KnotRegistry([object] $Journal) {
    Assert-KnotRegistryAbsent
    $base=Open-KnotRegistry; $vendor=$null; $key=$null
    try {
        $acl=New-KnotRegistrySecurity
        $vendor=$base.OpenSubKey('SOFTWARE\MikeTheTech',$true)
        if (-not $vendor) { $vendor=$base.CreateSubKey('SOFTWARE\MikeTheTech',[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,[Microsoft.Win32.RegistryOptions]::None,$acl) }
        Assert-KnotRegistryAcl $vendor
        $existing=$vendor.OpenSubKey('VirtualDisplayDriver',$false)
        if ($existing) { $existing.Dispose(); throw 'The virtual display registry key appeared during setup.' }
        $key=$vendor.CreateSubKey('VirtualDisplayDriver',[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,[Microsoft.Win32.RegistryOptions]::None,$acl)
        Assert-KnotRegistryAcl $key
        if ($key.ValueCount -ne 0 -or $key.SubKeyCount -ne 0) { throw 'The virtual display registry key is not empty.' }
        $key.SetValue('KnotDeploymentId',$Journal.deploymentId,[Microsoft.Win32.RegistryValueKind]::String); $key.Flush()
        $key.SetValue('VDDPATH',$Journal.directory,[Microsoft.Win32.RegistryValueKind]::String); $key.Flush()
    } finally { if ($key) { $key.Dispose() }; if ($vendor) { $vendor.Dispose() }; $base.Dispose() }
}
function Assert-KnotOwnedRegistry([Microsoft.Win32.RegistryKey] $Key,[object] $Journal) {
    Assert-KnotRegistryAcl $Key
    if ($Key.SubKeyCount -ne 0 -or @($Key.GetValueNames() | Where-Object { $_ -cnotin @('KnotDeploymentId','VDDPATH') }).Count -ne 0 -or $Key.GetValue('KnotDeploymentId',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -cne $Journal.deploymentId -or $Key.GetValueKind('KnotDeploymentId') -ne [Microsoft.Win32.RegistryValueKind]::String) { throw 'The virtual display registry ownership changed; it was preserved.' }
    if ($Key.GetValueNames() -contains 'VDDPATH') {
        if ($Key.GetValueKind('VDDPATH') -ne [Microsoft.Win32.RegistryValueKind]::String -or $Key.GetValue('VDDPATH',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -cne $Journal.directory) { throw 'The virtual display registry settings changed; they were preserved.' }
    } elseif ($Journal.status -ceq 'Installed') { throw 'The installed virtual display registry path is missing.' }
}
function Assert-KnotDevices([object[]] $Devices,[object] $Journal,[switch] $Installed) {
    foreach ($device in $Devices) {
        if ($device.InstanceId -ine $Journal.instanceId) { throw 'Another virtual display device exists; no shared virtual display configuration will be changed.' }
        $hardware=@($device.HardwareIds)
        if ($hardware.Count -gt 0 -and @($hardware | Where-Object { $_ -ine 'Root\MttVDD' -and $_ -ine 'MttVDD' }).Count -gt 0) { throw 'The journaled device has a different hardware identity.' }
        if ($device.DriverVersion -and $device.DriverVersion -cne $Journal.driverVersion) { throw 'The journaled device driver version changed.' }
        if ($Installed -and ($hardware.Count -eq 0 -or $device.DriverVersion -cne $Journal.driverVersion -or $device.DriverInf -notmatch '^oem[0-9]+\.inf$')) { throw 'The installed virtual display driver identity could not be verified.' }
    }
    if ($Installed -and $Devices.Count -ne 1) { throw 'The installed virtual display device could not be verified.' }
}
function Invoke-KnotHeadlessRemoval([object] $Journal,[hashtable] $Operations) {
    # Every deletion below is preceded by complete ownership validation. Failure
    # stops immediately; Finish is the only operation permitted to delete a journal.
    $hasDevice=[bool](& $Operations.Validate $Journal)
    $boot=& $Operations.BootIdentity
    $knownBoot=Test-KnotBootIdentity $boot
    if ($Journal.removalPhase -cin @('Started','PendingReboot')) {
        if (-not $knownBoot) { return [pscustomobject]@{Completed=$false;RebootRequired=$false;Status='BootIdentityUnavailable';InstanceId=$Journal.instanceId} }
        if ($boot -ceq $Journal.removalBootId) { return [pscustomobject]@{Completed=$false;RebootRequired=$true;Status='RemovalPending';InstanceId=$Journal.instanceId} }
    }
    if ($hasDevice) {
        if (-not $knownBoot) { return [pscustomobject]@{Completed=$false;RebootRequired=$false;Status='BootIdentityUnavailable';InstanceId=$Journal.instanceId} }
        # This durable unknown-outcome phase precedes the native call. A crash
        # after removal cannot be mistaken for a completed, non-reboot removal.
        $Journal.removalPending=$true; $Journal.removalPhase='Started'; $Journal.removalBootId=$boot; $Journal.rebootRequired=$true
        & $Operations.Save $Journal 'begin'
        $reboot=[bool](& $Operations.RemoveDevice $Journal)
        $Journal.removalPhase='Ready'; $Journal.rebootRequired=$false
        if ($reboot) { $Journal.removalPhase='PendingReboot'; $Journal.rebootRequired=$true }
        & $Operations.Save $Journal 'outcome'
        $remaining=[bool](& $Operations.Remaining $Journal)
        if ($reboot) {
            return [pscustomobject]@{Completed=$false;RebootRequired=$true;Status='RemovalPending';InstanceId=$Journal.instanceId}
        }
        if ($remaining) { throw 'Windows did not confirm removal of the journaled device; recovery data was retained.' }
    } elseif ($Journal.removalPhase -cne 'Ready') {
        if (-not $knownBoot) { return [pscustomobject]@{Completed=$false;RebootRequired=$false;Status='BootIdentityUnavailable';InstanceId=$Journal.instanceId} }
        $Journal.removalPending=$true; $Journal.removalPhase='Ready'; $Journal.removalBootId=$boot; $Journal.rebootRequired=$false
        & $Operations.Save $Journal 'ready'
    }
    & $Operations.RemoveRegistry $Journal
    & $Operations.RemoveFiles $Journal
    & $Operations.Finish $Journal
    return [pscustomobject]@{Completed=$true;RebootRequired=$false;Status='Absent';InstanceId=$Journal.instanceId}
}
function Remove-KnotOwnedDeployment([object] $Journal,[object] $Pins) {
    # Validate every resource before the first removal. Never sweep devices or the driver store.
    $current=Read-KnotJournal $Pins -Recover
    if ($current.deploymentId -cne $Journal.deploymentId) { throw 'The virtual display deployment changed during recovery.' }
    $devices=@([Knot.Headless.Native]::ReadDriverDevices())
    Assert-KnotDevices $devices $current -Installed:($current.status -ceq 'Installed' -and -not $current.removalPending -and $devices.Count -gt 0)
    $base=Open-KnotRegistry; $key=$null
    try {
        Assert-KnotRegistryParents $base
        $key=$base.OpenSubKey($script:RegistryPath,$false)
        if ($key) { Assert-KnotOwnedRegistry $key $current }
        elseif ($current.status -ceq 'Installed' -and $current.removalPhase -cne 'Ready') { throw 'The installed virtual display registry key is missing.' }
    } finally { if ($key) { $key.Dispose() }; $base.Dispose() }
    $operations=@{
        Validate={ param($j) return ($devices.Count -gt 0) }
        BootIdentity={ Get-KnotBootIdentity }
        Save={ param($j,$step) Write-KnotJournal $j }
        RemoveDevice={ param($j) [Knot.Headless.Native]::RemoveDevice($j.instanceId) }
        Remaining={ param($j)
            $remaining=@([Knot.Headless.Native]::ReadDriverDevices())
            Assert-KnotDevices $remaining $j
            return ($remaining.Count -gt 0)
        }
        RemoveRegistry={ param($j)
            # A foreign device created after initial validation also blocks teardown.
            Assert-KnotDevices @([Knot.Headless.Native]::ReadDriverDevices()) $j
            $base=Open-KnotRegistry; $key=$null; $vendor=$null
            try {
                Assert-KnotRegistryParents $base
                $key=$base.OpenSubKey($script:RegistryPath,$true)
                if ($key) {
                    Assert-KnotOwnedRegistry $key $j
                    $key.Dispose(); $key=$null
                    $vendor=$base.OpenSubKey('SOFTWARE\MikeTheTech',$true)
                    # Nonrecursive deletion cannot remove any newly created child key.
                    $vendor.DeleteSubKey('VirtualDisplayDriver',$false)
                }
            } finally { if ($key) { $key.Dispose() }; if ($vendor) { $vendor.Dispose() }; $base.Dispose() }
        }
        RemoveFiles={ param($j)
            $j.status='Prepared'; $j.removalPending=$true; $j.rebootRequired=$false
            Write-KnotJournal $j
            Assert-KnotOwnedFiles $j
            foreach ($file in $j.files) {
                $path=Join-Path $j.directory $file.name
                if ([IO.File]::Exists($path)) { Assert-KnotFile $path; [IO.File]::Delete($path) }
            }
        }
        Finish={ param($j)
            $record=Join-Path $j.directory 'recovery.json'
            Assert-KnotFile $record
            if (@([IO.Directory]::EnumerateFileSystemEntries($j.directory)).Count -ne 1) { throw 'Unknown recovery content was preserved.' }
            [IO.File]::Delete($record)
            [IO.Directory]::Delete($j.directory,$false)
        }
    }
    return Invoke-KnotHeadlessRemoval $current $operations
}
function Invoke-KnotHeadlessTransaction([object] $Journal,[hashtable] $Operations) {
    # The production transaction and fault-injection tests execute this same ordering.
    $prepared=$false
    try {
        & $Operations.Preflight $Journal
        & $Operations.Prepare $Journal
        $prepared=$true
        & $Operations.Configure $Journal
        & $Operations.Create $Journal
        $reboot=[bool](& $Operations.Install $Journal)
        & $Operations.Verify $Journal
        & $Operations.Commit $Journal $reboot
        return [pscustomobject]@{Completed=$true;RebootRequired=$reboot;Status='Installed';InstanceId=$Journal.instanceId}
    } catch {
        $failure=$_
        if ($prepared -or (& $Operations.HasJournal $Journal)) {
            try {
                $cleanup=& $Operations.Cleanup $Journal
                if ($cleanup.RebootRequired) { return [pscustomobject]@{Completed=$false;RebootRequired=$true;Status='RecoveryRequired';InstanceId=$Journal.instanceId} }
                if (-not $cleanup.Completed) { throw 'Recovery did not complete.' }
            } catch { throw 'Virtual display setup failed and protected recovery data was retained. Run managed removal after restarting, or review the recovery folder if its contents changed.' }
        }
        throw $failure
    }
}
function Assert-KnotElevatedRuntime {
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) { throw 'Virtual display installation requires 64-bit Windows PowerShell 5.1.' }
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try { $principal=New-Object Security.Principal.WindowsPrincipal($identity); if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Virtual display setup requires an administrator window.' } } finally { $identity.Dispose() }
    Assert-KnotAncestors (Join-Path $PSScriptRoot 'HeadlessSetup.psm1')
    Assert-ProtectedDirectory $PSScriptRoot
    Initialize-KnotHeadlessNative -Protected
    foreach ($name in @('HeadlessSetup.psm1','HeadlessNative.cs','VirtualDisplayDependency.json','VirtualDisplayFiles.json','Knot-vdd_settings.xml')) { Assert-KnotFile (Join-Path $PSScriptRoot $name) }
}
function Invoke-KnotExclusive([scriptblock] $Action) {
    Assert-KnotElevatedRuntime
    $security=New-Object Security.AccessControl.MutexSecurity
    $security.SetAccessRuleProtection($true,$false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) { $security.AddAccessRule((New-Object Security.AccessControl.MutexAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','Allow'))) }
    $created=$false; $acquired=$false
    $mutex=New-Object Threading.Mutex($false,'Global\Knot.ManagedVirtualDisplay.v1',[ref]$created,$security)
    try {
        try { $acquired=$mutex.WaitOne(0,$false) } catch [Threading.AbandonedMutexException] { $acquired=$true }
        if (-not $acquired) { throw 'Another managed virtual display operation is running.' }
        return & $Action
    } finally { if ($acquired) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
function Install-KnotVirtualDisplayCore {
    $pins=Read-KnotDependency
    Assert-KnotInstallPolicy $pins.Dependency
    $journal=New-KnotJournal $pins
    $archive=Join-Path $PSScriptRoot 'VirtualDisplayDriver.zip'
    Assert-KnotFile $archive
    $payload=Read-KnotDriverArchive $archive $pins.Dependency $pins.Inventory
    Assert-KnotDriverPackage $payload
    $validation=Join-Path $PSScriptRoot ('catalog-check-'+[Guid]::NewGuid().ToString('N'))
    New-KnotDirectory $validation
    $catalog=Join-Path $validation 'mttvdd.cat'
    try {
        [IO.File]::WriteAllBytes($catalog,$payload['VirtualDisplayDriver/mttvdd.cat'])
        Assert-KnotFile $catalog
        Assert-KnotCatalogSignature (Get-AuthenticodeSignature -LiteralPath $catalog) $pins.Dependency.catalogSignerCertificateSha256
    } finally {
        if ([IO.File]::Exists($catalog)) { Assert-KnotFile $catalog; [IO.File]::Delete($catalog) }
        [IO.Directory]::Delete($validation,$false)
    }
    $operations=@{
        Preflight={ param($j)
            Assert-KnotAncestors $j.directory
            if (Test-Path -LiteralPath $j.directory) { throw 'An existing virtual display folder must be removed through managed recovery before installing.' }
            if (@([Knot.Headless.Native]::ReadDriverDevices()).Count -ne 0) { throw 'An existing virtual display device will not be adopted or changed.' }
            Assert-KnotRegistryAbsent
        }
        Prepare={ param($j)
            New-KnotDirectory $j.directory
            try { Write-KnotJournal $j } catch { if (@([IO.Directory]::EnumerateFileSystemEntries($j.directory)).Count -eq 0) { [IO.Directory]::Delete($j.directory,$false) }; throw }
            foreach ($file in $j.files) {
                if ($file.name -ceq 'vdd_settings.xml') { $bytes=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'Knot-vdd_settings.xml')) }
                else { $bytes=$payload['VirtualDisplayDriver/'+$file.name] }
                $target=Join-Path $j.directory $file.name
                $stream=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
            }
            Assert-KnotOwnedFiles $j
        }
        Configure={ param($j) Set-KnotRegistry $j }
        Create={ param($j)
            if (@([Knot.Headless.Native]::ReadDriverDevices()).Count -ne 0) { throw 'A virtual display device appeared during setup.' }
            [Knot.Headless.Native]::CreateDevice($j.instanceId)
        }
        Install={ param($j) [Knot.Headless.Native]::InstallDevice($j.instanceId,(Join-Path $j.directory 'MttVDD.inf')) }
        Verify={ param($j) Assert-KnotDevices @([Knot.Headless.Native]::ReadDriverDevices()) $j -Installed }
        Commit={ param($j,$restart) $j.status='Installed'; $j.rebootRequired=$restart; Write-KnotJournal $j }
        HasJournal={ param($j) [IO.File]::Exists((Join-Path $j.directory 'recovery.json')) -or [IO.File]::Exists((Join-Path $j.directory 'recovery.new')) }
        Cleanup={ param($j) Remove-KnotOwnedDeployment $j $pins }
    }
    return Invoke-KnotHeadlessTransaction $journal $operations
}
function Remove-KnotVirtualDisplayCore {
    $directory=Get-KnotDirectory
    if (-not (Test-Path -LiteralPath $directory)) {
        # Absence is an idempotent no-op; never remove a device or upstream key without our journal.
        return [pscustomobject]@{Completed=$true;RebootRequired=$false;Status='Absent';InstanceId=$null}
    }
    $pins=Read-KnotDependency
    $journal=Read-KnotJournal $pins -Recover
    return Remove-KnotOwnedDeployment $journal $pins
}
function Install-KnotVirtualDisplay {
    # Check before elevation-runtime compilation or any protected scratch creation.
    Assert-KnotInstallPolicy (Read-KnotDependency).Dependency
    return Invoke-KnotExclusive { Install-KnotVirtualDisplayCore }
}
function Remove-KnotVirtualDisplay { return Invoke-KnotExclusive { Remove-KnotVirtualDisplayCore } }
function Get-KnotHeadlessState {
    $directory=Get-KnotDirectory
    try {
        if (-not (Test-Path -LiteralPath $directory)) { return [pscustomobject]@{Status='Absent';Managed=$false;RebootRequired=$false;InstanceId=$null;Displays=@();Message='No managed virtual display is installed.'} }
        $journal=Read-KnotJournal (Read-KnotDependency) -WithoutNative
        $status=$journal.status
        if ($journal.removalPending -or $journal.status -ceq 'Prepared' -or [IO.File]::Exists((Join-Path $directory 'recovery.new'))) { $status='RecoveryRequired' }
        return [pscustomobject]@{Status=$status;Managed=$true;RebootRequired=$journal.rebootRequired;InstanceId=$journal.instanceId;Displays=@();Message='Managed state read. A fresh device and display probe is required.'}
    } catch {
        return [pscustomobject]@{Status='Conflict';Managed=$false;RebootRequired=$false;InstanceId=$null;Displays=@();Message='Existing virtual display state requires manual review and was preserved.'}
    }
}
Export-ModuleMember -Function Initialize-KnotHeadlessNative,Get-KnotHeadlessState,Get-KnotHeadlessAvailability,Install-KnotVirtualDisplay,Remove-KnotVirtualDisplay,Assert-KnotInstallPolicy,Invoke-KnotHeadlessTransaction,Invoke-KnotHeadlessRemoval,Read-KnotDriverArchive,Assert-KnotCatalogSignature,Assert-KnotDevices,Assert-KnotDriverPackage
