#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Importing this module does not compile code, enumerate devices, or change the machine.
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'SetupContract.psm1') -ErrorAction Stop
$script:HeldControlLock = $null
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
function New-KnotDirectory([string] $Path,[switch] $Private) {
    Assert-KnotAncestors $Path
    if (Test-Path -LiteralPath $Path) { throw 'The virtual display directory already exists; it will not be adopted.' }
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) { $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))) }
    # UMDF Wudfhost normally runs as LOCAL SERVICE. It needs read access to
    # vdd_settings.xml, but must not write settings or logs in this owned folder.
    if (-not $Private) { foreach ($sid in @('S-1-5-32-545','S-1-5-19')) { $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))) } }
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
    if ($dependency.schema -ne 1 -or $dependency.bytes -ne 132118 -or $dependency.sha256 -cne 'e24210692b442b39af763536330ce78b423f19342b7a7792c26de3944e418b3a' -or $dependency.driverVersion -cne '11.30.4.434' -or $dependency.catalogSignerCertificateSha256 -cne '69dfd3e1cbd49f039463edfe4c0d876c1dc7fdcd3aef08700a41355dc6c15fdb' -or $dependency.settingsSha256 -cnotmatch '^[a-f0-9]{64}\z') { throw 'The bundled virtual display dependency manifest is invalid.' }
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
        if ($file.path -cnotin $names -or -not $seen.Add([string]$file.path) -or $file.sha256 -cnotmatch '^[a-f0-9]{64}\z' -or $file.bytes -le 0 -or $file.bytes -gt 300000) { throw 'The driver inventory is invalid.' }
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
function Read-KnotDeploymentProfiles {
    # This source-owned allowlist survives current download pin/settings changes.
    # Recovery data never supplies its own authority or expected content hashes.
    $document=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VirtualDisplayDeployments.json')) | ConvertFrom-Json
    if ($document.schema -ne 1 -or $document.currentManifestId -isnot [string] -or @($document.profiles).Count -lt 1 -or @($document.profiles).Count -gt 32) { throw 'The trusted deployment profile list is invalid.' }
    $seen=@{}
    foreach ($profile in $document.profiles) {
        if (@($profile.PSObject.Properties).Count -ne 5 -or $profile.manifestId -isnot [string] -or $profile.manifestId -cnotmatch '^[a-z0-9][a-z0-9.-]{0,79}\z' -or $seen.ContainsKey($profile.manifestId) -or $profile.archiveSha256 -cnotmatch '^[a-f0-9]{64}\z' -or $profile.driverVersion -cnotmatch '^\d+\.\d+\.\d+\.\d+\z' -or $profile.catalogSignerCertificateSha256 -cnotmatch '^[a-f0-9]{64}\z' -or @($profile.files).Count -ne 4) { throw 'A trusted deployment profile is invalid.' }
        $seen[$profile.manifestId]=$true; $names=@{}
        foreach ($file in $profile.files) {
            if (@($file.PSObject.Properties).Count -ne 3 -or $file.name -cnotin @('mttvdd.cat','MttVDD.dll','MttVDD.inf','vdd_settings.xml') -or $names.ContainsKey($file.name) -or ($file.bytes -isnot [int] -and $file.bytes -isnot [long]) -or $file.bytes -lt 1 -or $file.bytes -gt 300000 -or $file.sha256 -cnotmatch '^[a-f0-9]{64}\z') { throw 'A trusted deployed-file inventory is invalid.' }
            $names[$file.name]=$true
        }
    }
    if (-not $seen.ContainsKey($document.currentManifestId)) { throw 'The current trusted deployment profile is missing.' }
    foreach ($id in @($document.legacySchema2ManifestIds)) { if ($id -isnot [string] -or -not $seen.ContainsKey($id)) { throw 'A trusted legacy deployment mapping is invalid.' } }
    return $document
}
function Test-KnotProfileIdentity([object] $Journal,[object] $Profile) {
    if ($Journal.archiveSha256 -cne $Profile.archiveSha256 -or $Journal.driverVersion -cne $Profile.driverVersion -or $Journal.catalogSignerCertificateSha256 -cne $Profile.catalogSignerCertificateSha256 -or @($Journal.files).Count -ne 4) { return $false }
    $seen=@{}
    foreach ($file in $Journal.files) {
        if (@($file.PSObject.Properties).Count -ne 3 -or $seen.ContainsKey([string]$file.name) -or ($file.bytes -isnot [int] -and $file.bytes -isnot [long])) { return $false }
        $seen[[string]$file.name]=$true
        if (@($Profile.files | Where-Object { $_.name -ceq $file.name -and $_.bytes -eq $file.bytes -and $_.sha256 -ceq $file.sha256 }).Count -ne 1) { return $false }
    }
    return $true
}
function Resolve-KnotJournalProfile([object] $Journal) {
    $profiles=Read-KnotDeploymentProfiles
    if ($Journal.schema -eq 2) { $matches=@($profiles.profiles | Where-Object { $_.manifestId -cin @($profiles.legacySchema2ManifestIds) -and (Test-KnotProfileIdentity $Journal $_) }) }
    elseif ($Journal.schema -eq 3 -and $Journal.PSObject.Properties['manifestId'] -and $Journal.manifestId -is [string]) { $matches=@($profiles.profiles | Where-Object { $_.manifestId -ceq $Journal.manifestId -and (Test-KnotProfileIdentity $Journal $_) }) }
    else { throw 'The recovery schema has no trusted deployment mapping.' }
    if ($matches.Count -ne 1) { throw 'The recovery deployment does not match an exact trusted historical profile.' }
    return $matches[0]
}
function Get-KnotCurrentDeploymentProfile([object] $Pins) {
    $profiles=Read-KnotDeploymentProfiles
    $profile=@($profiles.profiles | Where-Object { $_.manifestId -ceq $profiles.currentManifestId })[0]
    $files=@()
    foreach ($file in $Pins.Inventory.files) { if ($file.path -cne 'VirtualDisplayDriver/vdd_settings.xml') { $files += [pscustomobject]@{name=([IO.Path]::GetFileName($file.path));bytes=[long]$file.bytes;sha256=$file.sha256} } }
    $settings=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'Knot-vdd_settings.xml'))
    if ((Get-KnotHash $settings) -cne $Pins.Dependency.settingsSha256) { throw 'The current fixed virtual display settings failed verification.' }
    $files += [pscustomobject]@{name='vdd_settings.xml';bytes=$settings.Length;sha256=$Pins.Dependency.settingsSha256}
    $identity=[pscustomobject]@{archiveSha256=$Pins.Dependency.sha256;driverVersion=$Pins.Dependency.driverVersion;catalogSignerCertificateSha256=$Pins.Dependency.catalogSignerCertificateSha256;files=$files}
    if (-not (Test-KnotProfileIdentity $identity $profile)) { throw 'The current install pins do not match their trusted deployment profile.' }
    return $profile
}
function New-KnotJournal([object] $Pins) {
    $profile=Get-KnotCurrentDeploymentProfile $Pins
    $id=[Guid]::NewGuid().ToString('N').ToUpperInvariant()
    return [pscustomobject]@{schema=3;manifestId=$profile.manifestId;owner='Knot';deploymentId=$id;instanceId=('ROOT\KNOTVDD\'+$id);status='Prepared';publishedInfName='';rebootRequired=$false;removalPending=$false;removalPhase='None';removalBootId='';removalBootSession='';generation=1;previousRecordSha256='';directory=(Get-KnotDirectory);registryPath=$script:RegistryPath;archiveSha256=$profile.archiveSha256;driverVersion=$profile.driverVersion;catalogSignerCertificateSha256=$profile.catalogSignerCertificateSha256;files=@($profile.files | ForEach-Object { [pscustomobject]@{name=$_.name;bytes=[long]$_.bytes;sha256=$_.sha256} })}
}
function Assert-KnotJournal([object] $Journal,[object] $Pins=$null) {
    $properties=@('schema','owner','deploymentId','instanceId','status','rebootRequired','removalPending','removalPhase','removalBootId','generation','previousRecordSha256','directory','registryPath','archiveSha256','driverVersion','catalogSignerCertificateSha256','files')
    if ($Journal.schema -eq 3) { $properties += @('manifestId','publishedInfName','removalBootSession') }
    if (@($Journal.PSObject.Properties).Count -ne $properties.Count) { throw 'The virtual display recovery record has unknown fields.' }
    foreach ($property in $properties) { if ($null -eq $Journal.PSObject.Properties[$property]) { throw 'The virtual display recovery record is incomplete.' } }
    foreach ($name in @('owner','deploymentId','instanceId','status','directory','registryPath','archiveSha256','driverVersion','catalogSignerCertificateSha256','removalPhase','removalBootId','previousRecordSha256')) { if ($Journal.$name -isnot [string]) { throw 'A recovery string field has an invalid type.' } }
    if (($Journal.schema -isnot [int] -and $Journal.schema -isnot [long]) -or $Journal.schema -notin @(2,3) -or $Journal.owner -cne 'Knot' -or $Journal.deploymentId -isnot [string] -or $Journal.deploymentId -cnotmatch '^[0-9A-F]{32}\z' -or $Journal.instanceId -cne ('ROOT\KNOTVDD\'+$Journal.deploymentId) -or $Journal.status -cnotin @('Prepared','Installed') -or $Journal.rebootRequired -isnot [bool] -or $Journal.removalPending -isnot [bool] -or $Journal.directory -cne (Get-KnotDirectory) -or $Journal.registryPath -cne $script:RegistryPath) { throw 'The virtual display recovery record is not owned by this package.' }
    [void](Resolve-KnotJournalProfile $Journal)
    if (($Journal.generation -isnot [int] -and $Journal.generation -isnot [long]) -or $Journal.generation -lt 1 -or $Journal.generation -gt 1000000 -or $Journal.previousRecordSha256 -isnot [string] -or ($Journal.generation -eq 1 -and $Journal.previousRecordSha256 -cne '') -or ($Journal.generation -gt 1 -and $Journal.previousRecordSha256 -cnotmatch '^[a-f0-9]{64}\z')) { throw 'The recovery record sequence is invalid.' }
    if ($Journal.removalPhase -cnotin @('None','Started','PendingReboot','Ready') -or $Journal.removalBootId -isnot [string]) { throw 'The recovery removal phase is invalid.' }
    if ($Journal.schema -eq 3) {
        if ($Journal.publishedInfName -isnot [string] -or ($Journal.publishedInfName -cne '' -and -not (Test-KnotPublishedInf $Journal.publishedInfName)) -or ($Journal.status -ceq 'Installed' -and $Journal.publishedInfName -ceq '') -or $Journal.removalBootSession -isnot [string]) { throw 'The recovery driver-store or boot-session identity is invalid.' }
        if (($Journal.removalPhase -ceq 'None' -and $Journal.removalBootSession -cne '') -or ($Journal.removalPhase -cne 'None' -and -not (Test-KnotBootSession $Journal.removalBootSession))) { throw 'The recovery boot-session evidence is invalid.' }
    }
    if ($Journal.removalPhase -ceq 'None') {
        if ($Journal.removalPending -or $Journal.removalBootId -cne '') { throw 'The recovery removal phase is inconsistent.' }
    } elseif (-not $Journal.removalPending -or -not (Test-KnotBootIdentity $Journal.removalBootId) -or ($Journal.removalPhase -ceq 'Ready' -and $Journal.rebootRequired) -or ($Journal.removalPhase -cne 'Ready' -and -not $Journal.rebootRequired)) { throw 'The recovery removal outcome or boot identity is invalid.' }
}
function Test-KnotBootSession([object] $Value) { return ($Value -is [string] -and $Value -cmatch '^[a-f0-9]{32}\z') }
function Test-KnotBootIdentity([object] $Value) {
    # Prefix prevents newer ConvertFrom-Json versions coercing an ISO timestamp
    # into DateTime while Windows PowerShell 5.1 keeps it as a string.
    if ($Value -isnot [string] -or $Value -cnotmatch '^boot:\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z\z') { return $false }
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
function Get-KnotBootEvidence {
    # Both independent observations must change before an unknown/reboot removal
    # may release resources. The volatile, protected value survives process exits
    # but is discarded by Windows on restart. A clock/CIM-only change is insufficient.
    $boot=Get-KnotBootIdentity
    if (-not (Test-KnotBootIdentity $boot)) { return $null }
    $base=$null; $parent=$null; $key=$null
    try {
        $base=Open-KnotRegistry
        Assert-KnotRegistryAcl $base
        $software=$base.OpenSubKey('SOFTWARE',$false)
        try { Assert-KnotRegistryAcl $software } finally { $software.Dispose() }
        $acl=New-KnotRegistrySecurity -Private
        $parent=$base.OpenSubKey('SOFTWARE\Knot',$true)
        if (-not $parent) { $parent=$base.CreateSubKey('SOFTWARE\Knot',[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,[Microsoft.Win32.RegistryOptions]::None,$acl) }
        Assert-KnotRegistryAcl $parent
        $key=$parent.OpenSubKey('VirtualDisplayBootSession',$true)
        if (-not $key) {
            $key=$parent.CreateSubKey('VirtualDisplayBootSession',[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,[Microsoft.Win32.RegistryOptions]::Volatile,$acl)
            if ($key.ValueCount -ne 0 -or $key.SubKeyCount -ne 0) { throw 'The new boot-session key is not empty.' }
            $key.SetValue('Owner','Knot',[Microsoft.Win32.RegistryValueKind]::String)
            $key.SetValue('Session',[Guid]::NewGuid().ToString('N'),[Microsoft.Win32.RegistryValueKind]::String); $key.Flush()
        }
        Assert-KnotRegistryAcl $key -Private
        if ($key.SubKeyCount -ne 0 -or $key.ValueCount -ne 2 -or $key.GetValueKind('Owner') -ne [Microsoft.Win32.RegistryValueKind]::String -or $key.GetValue('Owner') -cne 'Knot' -or $key.GetValueKind('Session') -ne [Microsoft.Win32.RegistryValueKind]::String -or -not (Test-KnotBootSession $key.GetValue('Session'))) { throw 'The protected boot-session marker changed.' }
        return [pscustomobject]@{BootId=$boot;Session=$key.GetValue('Session')}
    } catch { return $null }
    finally { if ($key) { $key.Dispose() }; if ($parent) { $parent.Dispose() }; if ($base) { $base.Dispose() } }
}
function Get-KnotControlDirectory { return Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'KnotVirtualDisplayControl' }
function Assert-KnotPrivateDirectory([string] $Path) {
    Assert-KnotAncestors $Path; Assert-ProtectedDirectory $Path
    $acl=Get-Acl -LiteralPath $Path
    foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') -and -not ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and [int]$rule.FileSystemRights -ne 0) { throw 'The control directory permits untrusted access.' }
    }
}
function Assert-KnotPrivateFile([string] $Path) {
    Assert-KnotFile $Path
    $acl=Get-Acl -LiteralPath $Path
    foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') -and -not ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and [int]$rule.FileSystemRights -ne 0) { throw 'The control file permits untrusted access.' }
    }
}
function Assert-KnotHeldControlLock([object] $Context,[string] $ExpectedPath) {
    # Only Invoke-KnotExclusive creates this module-private context. Validate the
    # exact live stream and metadata through its existing handle, never reopen it.
    if ($null -eq $Context -or $null -eq $script:HeldControlLock -or -not [object]::ReferenceEquals($Context,$script:HeldControlLock) -or $Context.Stream -isnot [IO.FileStream] -or -not $Context.Stream.CanRead -or -not $Context.Stream.CanWrite -or $Context.Path -cne $ExpectedPath -or [IO.Path]::GetFullPath($Context.Stream.Name) -cne [IO.Path]::GetFullPath($ExpectedPath) -or $Context.Stream.SafeFileHandle.IsClosed -or $Context.Stream.SafeFileHandle.IsInvalid) { throw 'The held virtual display control lock context is invalid.' }
    [Knot.Headless.Native]::ValidateControlLockHandle($Context.Stream.SafeFileHandle)
}
function New-KnotControlFileSystem {
    $held=$script:HeldControlLock
    return @{
        HeldLockContext=$held
        ValidateHeldLock={ param($context,$expectedPath) Assert-KnotHeldControlLock $context $expectedPath }
        AssertDirectory={ param($path) Assert-KnotPrivateDirectory $path }
        AssertFile={ param($path) Assert-KnotPrivateFile $path }
        CreateDirectory={ param($path) New-KnotDirectory $path -Private }
        MoveDirectory={ param($from,$to) [IO.Directory]::Move($from,$to) }
        Flush={ param($stream) $stream.Flush($true) }
        OpenLock={ param($path) [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    }
}
function Write-KnotDurableFile([string] $Path,[byte[]] $Bytes,[hashtable] $FileSystem) {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($Bytes,0,$Bytes.Length); & $FileSystem.Flush $stream } finally { $stream.Dispose() }
    & $FileSystem.AssertFile $Path
    if ((Get-KnotHash ([IO.File]::ReadAllBytes($Path))) -cne (Get-KnotHash $Bytes)) { throw 'A newly written protected file failed verification.' }
}
function Initialize-KnotControlDirectory([hashtable] $FileSystem=$null) {
    if (-not $FileSystem) { $FileSystem=New-KnotControlFileSystem }
    $directory=Get-KnotControlDirectory
    $marker=[Text.Encoding]::UTF8.GetBytes('{"schema":1,"owner":"Knot","purpose":"VirtualDisplayControl"}')
    if (-not (Test-Path -LiteralPath $directory)) {
        $stage=$directory+'.'+[Guid]::NewGuid().ToString('N')+'.new'
        & $FileSystem.CreateDirectory $stage
        Write-KnotDurableFile (Join-Path $stage 'control.json') $marker $FileSystem
        Write-KnotDurableFile (Join-Path $stage 'operation.lock') ([byte[]]@()) $FileSystem
        & $FileSystem.AssertDirectory $stage
        # Same-volume publish; a race never adopts or overwrites the winner.
        & $FileSystem.MoveDirectory $stage $directory
    }
    & $FileSystem.AssertDirectory $directory
    $held=$null; $heldLockPath=Join-Path $directory 'operation.lock'
    if ($FileSystem.ContainsKey('HeldLockContext') -and $null -ne $FileSystem.HeldLockContext) {
        $held=$FileSystem.HeldLockContext
        if (-not $FileSystem.ContainsKey('ValidateHeldLock')) { throw 'A held lock requires explicit same-handle validation.' }
        & $FileSystem.ValidateHeldLock $held $heldLockPath
    }
    $lockEntry=$null
    $entries=@([IO.Directory]::EnumerateFileSystemEntries($directory))
    if ($entries.Count -lt 2 -or $entries.Count -gt 102) { throw 'The protected control directory inventory is invalid.' }
    foreach ($entry in $entries) {
        $name=[IO.Path]::GetFileName($entry)
        if ($name -ceq 'operation.lock') {
            if ($entry -cne $heldLockPath) { throw 'The control lock path changed.' }
            $lockEntry=$entry
            if ($null -eq $held) { & $FileSystem.AssertFile $entry }
            continue
        }
        if ($name -ceq 'control.json') { & $FileSystem.AssertFile $entry; continue }
        if ($name -cnotmatch '^quarantine-[a-f0-9]{32}\z' -or -not [IO.Directory]::Exists($entry)) { throw 'Unknown control content was preserved.' }
        & $FileSystem.AssertDirectory $entry
        if (@([IO.Directory]::EnumerateFileSystemEntries($entry)).Count -ne 2) { throw 'Incomplete quarantined recovery evidence was preserved.' }
        $metadataPath=Join-Path $entry 'evidence.json'; $payloadPath=Join-Path $entry 'recovery.new'
        & $FileSystem.AssertFile $metadataPath; & $FileSystem.AssertFile $payloadPath
        if ((Get-Item -LiteralPath $metadataPath).Length -gt 1024 -or (Get-Item -LiteralPath $payloadPath).Length -gt 16384) { throw 'Quarantined recovery evidence exceeds its bounds.' }
        $metadata=[IO.File]::ReadAllText($metadataPath) | ConvertFrom-Json
        if (@($metadata.PSObject.Properties).Count -ne 4 -or $metadata.schema -ne 1 -or $metadata.deploymentId -cnotmatch '^[0-9A-F]{32}\z' -or $metadata.sourceName -cne 'recovery.new' -or $metadata.sha256 -cne (Get-KnotHash ([IO.File]::ReadAllBytes($payloadPath)))) { throw 'Quarantined recovery evidence changed.' }
    }
    if ($null -eq $lockEntry -or (Get-KnotHash ([IO.File]::ReadAllBytes((Join-Path $directory 'control.json')))) -cne (Get-KnotHash $marker) -or ($null -eq $held -and (Get-Item -LiteralPath $heldLockPath).Length -ne 0)) { throw 'An existing control directory does not have the exact source-owned marker.' }
    return $directory
}
function Enter-KnotControlLock([hashtable] $FileSystem=$null) {
    if (-not $FileSystem) { $FileSystem=New-KnotControlFileSystem }
    $directory=Initialize-KnotControlDirectory $FileSystem
    $path=Join-Path $directory 'operation.lock'
    & $FileSystem.AssertFile $path
    try { $stream=& $FileSystem.OpenLock $path }
    catch [IO.IOException] { throw 'Another managed virtual display operation is running, or the protected lock could not be opened.' }
    # Do not reopen the path for metadata while this exclusive stream is held.
    # Its file and parent were validated before acquisition; both deny all
    # nonadministrative access, so untrusted callers cannot replace the lock.
    return $stream
}
function Preserve-KnotTornJournal([string] $Path,[object] $Journal,[string] $ExpectedHash,[hashtable] $FileSystem=$null) {
    $fs=$FileSystem; $sourceFs=$FileSystem
    if (-not $fs) { $fs=New-KnotControlFileSystem; $sourceFs=New-KnotJournalFileSystem }
    $control=Initialize-KnotControlDirectory $fs
    # Leave the original untouched if the bounded evidence inventory is full.
    # This check precedes creating a stage or writing any new evidence bytes.
    if (@([IO.Directory]::EnumerateFileSystemEntries($control)).Count -ge 102) { throw 'Protected recovery evidence capacity was reached; the original interrupted update was preserved.' }
    & $sourceFs.AssertFile $Path
    $bytes=[IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -gt 16384 -or (Get-KnotHash $bytes) -cne $ExpectedHash) { throw 'Interrupted recovery bytes changed before preservation.' }
    $id=[Guid]::NewGuid().ToString('N'); $stage=$control+'.quarantine-'+$id+'.new'; $destination=Join-Path $control ('quarantine-'+$id)
    & $fs.CreateDirectory $stage
    Write-KnotDurableFile (Join-Path $stage 'recovery.new') $bytes $fs
    $metadata=[pscustomobject]@{schema=1;deploymentId=$Journal.deploymentId;sourceName='recovery.new';sha256=$ExpectedHash}
    Write-KnotDurableFile (Join-Path $stage 'evidence.json') ((New-Object Text.UTF8Encoding($false)).GetBytes(($metadata | ConvertTo-Json -Compress))) $fs
    & $fs.MoveDirectory $stage $destination
    # Delete only after the exact bytes are durable and independently verifiable.
    & $sourceFs.AssertFile $Path
    if ((Get-KnotHash ([IO.File]::ReadAllBytes($Path))) -cne $ExpectedHash) { throw 'Interrupted recovery bytes changed after preservation.' }
    [IO.File]::Delete($Path)
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
        MoveDirectory={ param($source,$destination) [IO.Directory]::Move($source,$destination) }
        CreateDirectory={ param($path) New-KnotDirectory $path }
        Quarantine={ param($path,$journal,$hash) Preserve-KnotTornJournal $path $journal $hash }
    }
}
function Test-KnotIncompleteJson([byte[]] $Bytes) {
    # Deliberately narrow: complete-but-ambiguous JSON (for example duplicate
    # case-colliding keys rejected by ConvertFrom-Json) is never quarantined.
    try { $text=(New-Object Text.UTF8Encoding($false,$true)).GetString($Bytes) } catch { return $false }
    if ($text -cnotmatch '^\s*\{\s*"schema"\s*:\s*[23]\s*[,}]') { return $false }
    $stack=New-Object 'Collections.Generic.List[char]'; $quoted=$false; $escaped=$false
    foreach ($character in $text.ToCharArray()) {
        if ($quoted) {
            if ($escaped) { $escaped=$false; continue }
            if ($character -eq '\') { $escaped=$true; continue }
            if ($character -eq '"') { $quoted=$false }
            continue
        }
        if ($character -eq '"') { $quoted=$true; continue }
        if ($character -eq '{' -or $character -eq '[') { $stack.Add($character); continue }
        if ($character -eq '}' -or $character -eq ']') {
            if ($stack.Count -eq 0) { return $false }
            $expected='['; if ($character -eq '}') { $expected='{' }
            if ($stack[$stack.Count-1] -ne $expected) { return $false }
            $stack.RemoveAt($stack.Count-1)
        }
    }
    return ($stack.Count -gt 0)
}
function Read-KnotJournalFile([string] $Path,[object] $Pins,[hashtable] $FileSystem,[switch] $AllowUnparseable) {
    & $FileSystem.AssertFile $Path
    if ((Get-Item -LiteralPath $Path).Length -gt 16384) { throw 'The virtual display recovery record is too large.' }
    $bytes=[IO.File]::ReadAllBytes($Path)
    try { $journal=[Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop }
    catch { if ($AllowUnparseable -and (Test-KnotIncompleteJson $bytes)) { return [pscustomobject]@{Journal=$null;Hash=(Get-KnotHash $bytes);Unparseable=$true} }; throw }
    Assert-KnotJournal $journal $Pins
    return [pscustomobject]@{Journal=$journal;Hash=(Get-KnotHash $bytes);Unparseable=$false}
}
function Assert-KnotJournalSuccessor([object] $Previous,[object] $Next,[string] $PreviousHash) {
    foreach ($name in @('owner','deploymentId','instanceId','directory','registryPath','archiveSha256','driverVersion','catalogSignerCertificateSha256')) {
        if ($Previous.$name -cne $Next.$name) { throw 'The interrupted recovery update belongs to a different deployment.' }
    }
    $migration=($Previous.schema -eq 2 -and $Next.schema -eq 3 -and $Previous.removalPhase -ceq 'None' -and $Next.removalPhase -ceq 'None' -and $Next.manifestId -ceq (Resolve-KnotJournalProfile $Previous).manifestId)
    if ($Previous.schema -ne $Next.schema -and -not $migration) { throw 'The recovery schema transition is not a trusted legacy migration.' }
    if ($Previous.schema -eq 3 -and ($Previous.manifestId -cne $Next.manifestId -or ($Previous.publishedInfName -cne '' -and $Previous.publishedInfName -cne $Next.publishedInfName))) { throw 'The recovery deployment manifest or published INF identity changed.' }
    $previousProfile=Resolve-KnotJournalProfile $Previous; $nextProfile=Resolve-KnotJournalProfile $Next
    if ($Next.generation -ne ($Previous.generation+1) -or $Next.previousRecordSha256 -cne $PreviousHash -or $previousProfile.manifestId -cne $nextProfile.manifestId) { throw 'The interrupted recovery update is not the exact successor of the protected record.' }
    $from=$Previous.removalPhase; $to=$Next.removalPhase
    $sameBoot=$Previous.removalBootId -ceq $Next.removalBootId
    if ($Previous.schema -eq 3 -and $Next.schema -eq 3) { $sameBoot=$sameBoot -or ($Previous.removalBootSession -ceq $Next.removalBootSession) }
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
function Write-KnotJournal([object] $Journal,[object] $Pins=$null,[hashtable] $FileSystem=$null,[string] $StorageDirectory='') {
    if (-not $FileSystem) { $FileSystem=New-KnotJournalFileSystem }
    if ($StorageDirectory -ceq '') { $StorageDirectory=$Journal.directory }
    $path=Join-Path $StorageDirectory 'recovery.json'
    $temporary=Join-Path $StorageDirectory 'recovery.new'
    & $FileSystem.AssertDirectory $StorageDirectory
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
        if (@([IO.Directory]::EnumerateFileSystemEntries($StorageDirectory)).Count -ne 0) { throw 'An initial recovery record requires the new empty owned directory.' }
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
function Read-KnotJournal([object] $Pins,[switch] $WithoutNative,[switch] $Recover,[hashtable] $FileSystem=$null,[string] $ExpectedDeploymentId='') {
    if ($WithoutNative -and $Recover) { throw 'Read-only journal inspection cannot promote recovery records.' }
    if ($ExpectedDeploymentId -cne '' -and $ExpectedDeploymentId -cnotmatch '^[0-9A-F]{32}\z') { throw 'The expected recovery deployment identity is invalid.' }
    if (-not $FileSystem) { $FileSystem=New-KnotJournalFileSystem -WithoutNative:$WithoutNative }
    $directory=Get-KnotDirectory
    & $FileSystem.AssertDirectory $directory
    $path=Join-Path $directory 'recovery.json'
    $temporary=Join-Path $directory 'recovery.new'
    $previous=$null
    if (Test-Path -LiteralPath $path) {
        $previous=Read-KnotJournalFile $path $Pins $FileSystem
        if ($ExpectedDeploymentId -cne '' -and $previous.Journal.deploymentId -cne $ExpectedDeploymentId) { throw 'The recovery deployment changed before any recovery mutation.' }
    }
    if (Test-Path -LiteralPath $temporary) {
        $pending=Read-KnotJournalFile $temporary $Pins $FileSystem -AllowUnparseable
        if ($pending.Unparseable) {
            if (-not $previous) { throw 'An unparseable orphan recovery update has no trusted predecessor; it was preserved.' }
            Assert-KnotOwnedFiles $previous.Journal -ValidatedPendingJournal -FileSystem $FileSystem
            if ($Recover) { & $FileSystem.Quarantine $temporary $previous.Journal $pending.Hash }
            return $previous.Journal
        }
        if ($ExpectedDeploymentId -cne '' -and $pending.Journal.deploymentId -cne $ExpectedDeploymentId) { throw 'The interrupted recovery deployment does not match the expected operation.' }
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
function Assert-KnotOwnedFiles([object] $Journal,[switch] $WithoutNative,[switch] $ValidatedPendingJournal,[hashtable] $FileSystem=$null,[string] $StorageDirectory='') {
    if (-not $FileSystem) { $FileSystem=New-KnotJournalFileSystem -WithoutNative:$WithoutNative }
    if ($StorageDirectory -ceq '') { $StorageDirectory=$Journal.directory }
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($StorageDirectory)) {
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
        foreach ($file in $Journal.files) { if (-not [IO.File]::Exists((Join-Path $StorageDirectory $file.name))) { throw 'An installed virtual display file is missing.' } }
    }
}
function Assert-KnotRegistryAcl([Microsoft.Win32.RegistryKey] $Key,[switch] $Private) {
    $acl=$Key.GetAccessControl()
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $script:TrustedSids) { throw 'The virtual display registry parent has an untrusted owner.' }
    foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($Private -and $rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') -and -not ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { throw 'The boot-session registry key permits untrusted access.' }
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
function New-KnotRegistrySecurity([switch] $Private) {
    $acl=New-Object Security.AccessControl.RegistrySecurity
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) { $acl.AddAccessRule((New-Object Security.AccessControl.RegistryAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit','None','Allow'))) }
    if (-not $Private) { foreach ($sid in @('S-1-5-32-545','S-1-5-19')) { $acl.AddAccessRule((New-Object Security.AccessControl.RegistryAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'ReadKey','ContainerInherit','None','Allow'))) } }
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
function Test-KnotPublishedInf([object] $Value) { return ($Value -is [string] -and $Value -cmatch '^oem(?:0|[1-9][0-9]{0,9})\.inf\z' -and [uint64]::Parse($Value.Substring(3,$Value.Length-7)) -le [uint32]::MaxValue) }
function Assert-KnotDevices([object[]] $Devices,[object] $Journal,[switch] $Installed) {
    foreach ($device in $Devices) {
        if ($device.InstanceId -ine $Journal.instanceId) { throw 'Another virtual display device exists; no shared virtual display configuration will be changed.' }
        $hardware=@($device.HardwareIds)
        if ($hardware.Count -gt 0 -and @($hardware | Where-Object { $_ -ine 'Root\MttVDD' -and $_ -ine 'MttVDD' }).Count -gt 0) { throw 'The journaled device has a different hardware identity.' }
        if ($device.DriverVersion -and $device.DriverVersion -cne $Journal.driverVersion) { throw 'The journaled device driver version changed.' }
        $hasExactInf=$Journal.PSObject.Properties['publishedInfName'] -and $Journal.publishedInfName -cne ''
        if ($hasExactInf -and $device.DriverInf -and $device.DriverInf -ine $Journal.publishedInfName) { throw 'The journaled device published INF identity changed.' }
        if ($Installed -and ($hardware.Count -eq 0 -or $device.DriverVersion -cne $Journal.driverVersion -or -not (Test-KnotPublishedInf ([string]$device.DriverInf).ToLowerInvariant()) -or ($Journal.schema -eq 3 -and (-not $hasExactInf -or $device.DriverInf -ine $Journal.publishedInfName)))) { throw 'The installed virtual display driver identity could not be verified.' }
    }
    if ($Installed -and $Devices.Count -ne 1) { throw 'The installed virtual display device could not be verified.' }
}
function Test-KnotBootEvidence([object] $Evidence) { return ($null -ne $Evidence -and $null -ne $Evidence.PSObject.Properties['BootId'] -and $null -ne $Evidence.PSObject.Properties['Session'] -and (Test-KnotBootIdentity $Evidence.BootId) -and (Test-KnotBootSession $Evidence.Session)) }
function Invoke-KnotHeadlessRemoval([object] $Journal,[hashtable] $Operations) {
    # Validation must be fresh on every invocation, including after a reboot.
    $hasDevice=[bool](& $Operations.Validate $Journal)
    if ($Journal.schema -eq 2 -and $Journal.removalPhase -cne 'None') { return [pscustomobject]@{Completed=$false;RebootRequired=$false;Status='LegacyRecoveryRequired';InstanceId=$Journal.instanceId} }
    if ($Journal.schema -ne 3) { throw 'Legacy recovery requires exact trusted migration before removal.' }
    if ($Journal.PSObject.Properties['status'] -and $Journal.status -ceq 'Installed' -and $Journal.removalPhase -ceq 'None' -and -not $hasDevice) { return [pscustomobject]@{Completed=$false;RebootRequired=$false;Status='DeviceIdentityUnavailable';InstanceId=$Journal.instanceId} }
    try { $evidence=& $Operations.BootEvidence } catch { $evidence=$null }
    $knownBoot=Test-KnotBootEvidence $evidence
    if ($Journal.removalPhase -cin @('Started','PendingReboot')) {
        if (-not $knownBoot) { return [pscustomobject]@{Completed=$false;RebootRequired=$false;Status='BootEvidenceUnavailable';InstanceId=$Journal.instanceId} }
        if ($evidence.BootId -ceq $Journal.removalBootId -or $evidence.Session -ceq $Journal.removalBootSession) { return [pscustomobject]@{Completed=$false;RebootRequired=$true;Status='RemovalPending';InstanceId=$Journal.instanceId} }
    }
    if ($hasDevice) {
        if (-not $knownBoot) { return [pscustomobject]@{Completed=$false;RebootRequired=$false;Status='BootEvidenceUnavailable';InstanceId=$Journal.instanceId} }
        $Journal.removalPending=$true; $Journal.removalPhase='Started'; $Journal.removalBootId=$evidence.BootId; $Journal.removalBootSession=$evidence.Session; $Journal.rebootRequired=$true
        & $Operations.Save $Journal 'begin'
        $reboot=[bool](& $Operations.RemoveDevice $Journal)
        if ($reboot) {
            $Journal.removalPhase='PendingReboot'; $Journal.rebootRequired=$true
            & $Operations.Save $Journal 'outcome'
            return [pscustomobject]@{Completed=$false;RebootRequired=$true;Status='RemovalPending';InstanceId=$Journal.instanceId}
        }
        # Keep durable Started until a fresh inventory proves absence. A failed
        # or unavailable verification must never create a same-boot Ready escape.
        $remaining=[bool](& $Operations.Remaining $Journal)
        if ($remaining) { throw 'Windows did not confirm removal of the journaled device; recovery data was retained.' }
        $Journal.removalPhase='Ready'; $Journal.rebootRequired=$false
        & $Operations.Save $Journal 'outcome'
    } elseif ($Journal.removalPhase -cne 'Ready') {
        if (-not $knownBoot) { return [pscustomobject]@{Completed=$false;RebootRequired=$false;Status='BootEvidenceUnavailable';InstanceId=$Journal.instanceId} }
        $Journal.removalPending=$true; $Journal.removalPhase='Ready'; $Journal.removalBootId=$evidence.BootId; $Journal.removalBootSession=$evidence.Session; $Journal.rebootRequired=$false
        & $Operations.Save $Journal 'ready'
    }
    & $Operations.RemoveRegistry $Journal
    & $Operations.RemoveFiles $Journal
    & $Operations.Finish $Journal
    return [pscustomobject]@{Completed=$true;RebootRequired=$false;Status='Absent';InstanceId=$Journal.instanceId}
}
function Publish-KnotDeployment([object] $Journal,[object] $Pins,[hashtable] $Payload,[hashtable] $FileSystem=$null) {
    if (-not $FileSystem) { $FileSystem=New-KnotJournalFileSystem }
    $stage=$Journal.directory+'.'+$Journal.deploymentId+'.'+[Guid]::NewGuid().ToString('N')+'.new'
    & $FileSystem.CreateDirectory $stage
    # The stored identity remains the canonical final path, never the scratch path.
    Write-KnotJournal $Journal $Pins $FileSystem $stage
    foreach ($file in $Journal.files) {
        if ($file.name -ceq 'vdd_settings.xml') { $bytes=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'Knot-vdd_settings.xml')) }
        else { $bytes=[byte[]]$Payload['VirtualDisplayDriver/'+$file.name] }
        if ($bytes.Length -ne $file.bytes -or (Get-KnotHash $bytes) -cne $file.sha256) { throw 'A deployment file did not match the trusted deployed inventory.' }
        Write-KnotDurableFile (Join-Path $stage $file.name) $bytes $FileSystem
    }
    Assert-KnotOwnedFiles $Journal -FileSystem $FileSystem -StorageDirectory $stage
    $staged=Read-KnotJournalFile (Join-Path $stage 'recovery.json') $Pins $FileSystem
    if ($staged.Journal.deploymentId -cne $Journal.deploymentId) { throw 'The prepared deployment identity changed.' }
    & $FileSystem.MoveDirectory $stage $Journal.directory
    & $FileSystem.AssertDirectory $Journal.directory
    Assert-KnotOwnedFiles $Journal -FileSystem $FileSystem
}
function Retire-KnotDeployment([object] $Journal,[hashtable] $FileSystem=$null) {
    if (-not $FileSystem) { $FileSystem=New-KnotJournalFileSystem }
    & $FileSystem.AssertDirectory $Journal.directory
    $record=Join-Path $Journal.directory 'recovery.json'
    $current=Read-KnotJournalFile $record $null $FileSystem
    if ($current.Journal.deploymentId -cne $Journal.deploymentId -or $current.Journal.removalPhase -cne 'Ready' -or $current.Journal.status -cne 'Prepared') { throw 'The final recovery record changed before retirement.' }
    Assert-KnotOwnedFiles $current.Journal -FileSystem $FileSystem
    $retired=$Journal.directory+'.retired.'+$Journal.deploymentId+'.'+[Guid]::NewGuid().ToString('N')
    # Keep the complete ownership record until the entire final directory is off
    # the active path. Any interrupted cleanup is preserved under this unique name.
    & $FileSystem.MoveDirectory $Journal.directory $retired
    & $FileSystem.AssertDirectory $retired
    Assert-KnotOwnedFiles $current.Journal -FileSystem $FileSystem -StorageDirectory $retired
    foreach ($file in $current.Journal.files) { $path=Join-Path $retired $file.name; if ([IO.File]::Exists($path)) { & $FileSystem.AssertFile $path; [IO.File]::Delete($path) } }
    $record=Join-Path $retired 'recovery.json'; & $FileSystem.AssertFile $record
    if (@([IO.Directory]::EnumerateFileSystemEntries($retired)).Count -ne 1) { throw 'Unknown retired recovery content was preserved.' }
    [IO.File]::Delete($record); [IO.Directory]::Delete($retired,$false)
}
function Convert-KnotLegacyJournal([object] $Journal,[object[]] $Devices) {
    Assert-KnotJournal $Journal
    if ($Journal.schema -ne 2 -or $Journal.removalPhase -cne 'None' -or ($Journal.status -ceq 'Installed' -and $Devices.Count -ne 1)) { throw 'Legacy recovery requires manual review; pending records have no durable boot-session evidence.' }
    Assert-KnotDevices $Devices $Journal -Installed:($Journal.status -ceq 'Installed')
    $profile=Resolve-KnotJournalProfile $Journal
    $inf=''; if ($Devices.Count -eq 1 -and $Devices[0].DriverInf) { $inf=([string]$Devices[0].DriverInf).ToLowerInvariant(); if (-not (Test-KnotPublishedInf $inf)) { throw 'The legacy device published INF identity cannot be migrated.' } }
    $Journal.schema=3
    Add-Member -InputObject $Journal -NotePropertyName manifestId -NotePropertyValue $profile.manifestId
    Add-Member -InputObject $Journal -NotePropertyName publishedInfName -NotePropertyValue $inf
    Add-Member -InputObject $Journal -NotePropertyName removalBootSession -NotePropertyValue ''
    Assert-KnotJournal $Journal
    return $Journal
}
function Test-KnotOwnedDeployment([object] $Planned) {
    try { $owned=Read-KnotJournal $null; return ($owned.deploymentId -ceq $Planned.deploymentId -and $owned.instanceId -ceq $Planned.instanceId) } catch { return $false }
}
function Read-KnotDriverDevices { return [Knot.Headless.Native]::ReadDriverDevices() }
function Remove-KnotOwnedDeployment([object] $Journal,[object] $Pins=$null) {
    # Validate every resource before the first removal. Never sweep devices or the driver store.
    $current=Read-KnotJournal $Pins -Recover -ExpectedDeploymentId $Journal.deploymentId
    if ($current.deploymentId -cne $Journal.deploymentId) { throw 'The virtual display deployment changed during recovery.' }
    $devices=@(Read-KnotDriverDevices)
    Assert-KnotDevices $devices $current -Installed:($current.status -ceq 'Installed' -and -not $current.removalPending -and $devices.Count -gt 0)
    if ($current.schema -eq 3 -and $current.status -ceq 'Installed' -and $current.removalPhase -ceq 'None' -and $devices.Count -eq 0) { return [pscustomobject]@{Completed=$false;RebootRequired=$false;Status='DeviceIdentityUnavailable';InstanceId=$current.instanceId} }
    $base=Open-KnotRegistry; $key=$null
    try {
        Assert-KnotRegistryParents $base
        $key=$base.OpenSubKey($script:RegistryPath,$false)
        if ($key) { Assert-KnotOwnedRegistry $key $current }
        elseif ($current.status -ceq 'Installed' -and $current.removalPhase -cne 'Ready') { throw 'The installed virtual display registry key is missing.' }
    } finally { if ($key) { $key.Dispose() }; $base.Dispose() }
    if ($current.schema -eq 2) {
        if ($current.removalPhase -cne 'None' -or ($current.status -ceq 'Installed' -and $devices.Count -ne 1)) { return [pscustomobject]@{Completed=$false;RebootRequired=$false;Status='LegacyRecoveryRequired';InstanceId=$current.instanceId} }
        $current=Convert-KnotLegacyJournal $current $devices
        Write-KnotJournal $current
    }
    $operations=@{
        Validate={ param($j) return ($devices.Count -gt 0) }
        BootEvidence={ Get-KnotBootEvidence }
        Save={ param($j,$step) Write-KnotJournal $j }
        RemoveDevice={ param($j) [Knot.Headless.Native]::RemoveDevice($j.instanceId) }
        Remaining={ param($j)
            $remaining=@(Read-KnotDriverDevices)
            Assert-KnotDevices $remaining $j
            return ($remaining.Count -gt 0)
        }
        RemoveRegistry={ param($j)
            # A foreign device created after initial validation also blocks teardown.
            Assert-KnotDevices @(Read-KnotDriverDevices) $j
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
        }
        Finish={ param($j) Retire-KnotDeployment $j }

    }
    return Invoke-KnotHeadlessRemoval $current $operations
}
function Invoke-KnotHeadlessTransaction([object] $Journal,[hashtable] $Operations) {
    # A failed preflight must never compensate somebody else's existing resources.
    & $Operations.Preflight $Journal
    $preparationStarted=$false
    try {
        $preparationStarted=$true
        & $Operations.Prepare $Journal
        & $Operations.Configure $Journal
        & $Operations.Create $Journal
        $reboot=[bool](& $Operations.Install $Journal)
        & $Operations.Verify $Journal
        & $Operations.Commit $Journal $reboot
        $status='Installed'; if ($reboot) { $status='InstalledPendingRestart' }
        return [pscustomobject]@{Completed=$true;RebootRequired=$reboot;Status=$status;InstanceId=$Journal.instanceId}
    } catch {
        $failure=$_
        if ($preparationStarted -and (& $Operations.HasJournal $Journal)) {
            try {
                $cleanup=& $Operations.Cleanup $Journal
                if (-not $cleanup.Completed) {
                    $status='RecoveryRequired'
                    if ($cleanup.PSObject.Properties['Status'] -and $cleanup.Status -cin @('RemovalPending','LegacyRecoveryRequired','BootEvidenceUnavailable','DeviceIdentityUnavailable','RecoveryRequired')) { $status=$cleanup.Status }
                    return [pscustomobject]@{Completed=$false;RebootRequired=[bool]$cleanup.RebootRequired;Status=$status;InstanceId=$Journal.instanceId}
                }
            } catch { throw 'Virtual display setup failed and exact owned recovery data was retained. Run managed removal after restarting, or review the recovery folder if its contents changed.' }
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
    foreach ($name in @('HeadlessSetup.psm1','HeadlessNative.cs','VirtualDisplayDeployments.json')) { Assert-KnotFile (Join-Path $PSScriptRoot $name) }
}
function Invoke-KnotExclusive([scriptblock] $Action) {
    Assert-KnotElevatedRuntime
    if ($null -ne $script:HeldControlLock) { throw 'A virtual display operation already holds this module control lock.' }
    $lock=Enter-KnotControlLock
    try {
        $script:HeldControlLock=[pscustomobject]@{Stream=$lock;Path=(Join-Path (Get-KnotControlDirectory) 'operation.lock')}
        return & $Action
    } finally { $script:HeldControlLock=$null; $lock.Dispose() }
}
function Install-KnotVirtualDisplayCore {
    foreach ($name in @('VirtualDisplayDependency.json','VirtualDisplayFiles.json','Knot-vdd_settings.xml')) { Assert-KnotFile (Join-Path $PSScriptRoot $name) }
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
        Prepare={ param($j) Publish-KnotDeployment $j $pins $payload }
        Configure={ param($j) Set-KnotRegistry $j }
        Create={ param($j)
            if (@([Knot.Headless.Native]::ReadDriverDevices()).Count -ne 0) { throw 'A virtual display device appeared during setup.' }
            [Knot.Headless.Native]::CreateDevice($j.instanceId)
        }
        Install={ param($j)
            $inf=Join-Path $j.directory 'MttVDD.inf'
            Assert-KnotOwnedFiles $j
            $published=[Knot.Headless.Native]::StageDriverPackage($inf)
            if (-not (Test-KnotPublishedInf $published)) { throw 'Windows returned a noncanonical published driver INF identity.' }
            $j.publishedInfName=$published; Write-KnotJournal $j
            [Knot.Headless.Native]::InstallDevice($j.instanceId,$inf,$j.publishedInfName)
        }
        Verify={ param($j) Assert-KnotDevices @([Knot.Headless.Native]::ReadDriverDevices()) $j -Installed }
        Commit={ param($j,$restart) $j.status='Installed'; $j.rebootRequired=$restart; Write-KnotJournal $j }
        HasJournal={ param($j) Test-KnotOwnedDeployment $j }
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
    $journal=Read-KnotJournal $null -Recover
    return Remove-KnotOwnedDeployment $journal
}
function Install-KnotVirtualDisplay {
    # Check before elevation-runtime compilation or any protected scratch creation.
    Assert-KnotInstallPolicy (Read-KnotDependency).Dependency
    return Invoke-KnotExclusive { Install-KnotVirtualDisplayCore }
}
function Remove-KnotVirtualDisplay { return Invoke-KnotExclusive { Remove-KnotVirtualDisplayCore } }
function Test-KnotHeadlessStateSupported { return ([IntPtr]::Size -eq 8) }
function Get-KnotHeadlessState {
    if (-not (Test-KnotHeadlessStateSupported)) { return [pscustomobject]@{Status='Unsupported';Managed=$false;RebootRequired=$false;InstanceId=$null;Displays=@();Message='Managed virtual display state requires a 64-bit process.'} }
    $directory=Get-KnotDirectory
    try {
        if (-not (Test-Path -LiteralPath $directory)) { return [pscustomobject]@{Status='Absent';Managed=$false;RebootRequired=$false;InstanceId=$null;Displays=@();Message='No managed virtual display is installed.'} }
        $journal=Read-KnotJournal $null -WithoutNative
        $status=$journal.status
        if ($journal.status -ceq 'Installed' -and $journal.rebootRequired) { $status='InstalledPendingRestart' }
        if ($journal.removalPending -or $journal.status -ceq 'Prepared' -or [IO.File]::Exists((Join-Path $directory 'recovery.new'))) { $status='RecoveryRequired' }
        if ($journal.schema -eq 2 -and $journal.removalPhase -cne 'None') { $status='LegacyRecoveryRequired' }
        elseif ($journal.removalPhase -cin @('Started','PendingReboot')) { $status='RemovalPending' }
        $restart=$journal.rebootRequired
        if ($status -ceq 'LegacyRecoveryRequired') { $restart=$false }
        return [pscustomobject]@{Status=$status;Managed=$true;RebootRequired=$restart;InstanceId=$journal.instanceId;Displays=@();Message='Managed state read. A fresh device and display probe is required.'}
    } catch {
        return [pscustomobject]@{Status='Conflict';Managed=$false;RebootRequired=$false;InstanceId=$null;Displays=@();Message='Existing virtual display state requires manual review and was preserved.'}
    }
}
Export-ModuleMember -Function Initialize-KnotHeadlessNative,Get-KnotHeadlessState,Get-KnotHeadlessAvailability,Install-KnotVirtualDisplay,Remove-KnotVirtualDisplay,Assert-KnotInstallPolicy,Invoke-KnotHeadlessTransaction,Invoke-KnotHeadlessRemoval,Read-KnotDriverArchive,Assert-KnotCatalogSignature,Assert-KnotDevices,Assert-KnotDriverPackage
