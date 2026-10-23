#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Read-only official-package verification in Windows CI. Never load or install the driver.
param([Parameter(Mandatory=$true)][string] $Archive)
$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $source 'HeadlessSetup.psm1') -Force
$dependency=Get-Content -LiteralPath (Join-Path $source 'VirtualDisplayDependency.json') -Raw | ConvertFrom-Json
$inventory=Get-Content -LiteralPath (Join-Path $source 'VirtualDisplayFiles.json') -Raw | ConvertFrom-Json
$payload=Read-KnotDriverArchive $Archive $dependency $inventory
Assert-KnotDriverPackage $payload
$directory=Join-Path ([IO.Path]::GetTempPath()) ('knot-artifact-signature-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
try {
    foreach ($name in @('mttvdd.cat','MttVDD.dll')) {
        $path=Join-Path $directory $name
        [IO.File]::WriteAllBytes($path,$payload['VirtualDisplayDriver/'+$name])
        Assert-KnotCatalogSignature (Get-AuthenticodeSignature -LiteralPath $path) $dependency.catalogSignerCertificateSha256
    }
    Write-Output 'Official virtual display archive, INF/PE and Windows signatures passed. Driver was not loaded or installed.'
} finally { [IO.Directory]::Delete($directory,$true) }
