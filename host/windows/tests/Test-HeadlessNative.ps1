#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Compile the actual adapter with inert fixtures. Never call Windows display,
# device, driver, registry, file metadata, or UI APIs from these checks.
$ErrorActionPreference='Stop'
$repository=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$source=Join-Path $repository 'host/windows/HeadlessNative.cs'
$checks=Join-Path $repository 'scripts/tests/HeadlessNativeChecks.cs'
if ([IntPtr]::Size -ne 8) { throw 'Headless native layout checks require a 64-bit process.' }
$windowsFolder=[Environment]::GetFolderPath('Windows')
$compiler=$null
if ($windowsFolder) { $compiler=Join-Path $windowsFolder 'Microsoft.NET\Framework64\v4.0.30319\csc.exe' }
if ($compiler -and (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    $directory=Join-Path ([IO.Path]::GetTempPath()) ('knot-headless-native-'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    try {
        $executable=Join-Path $directory 'SyntheticNativeChecks.exe'
        # Match the protected CodeDOM helper's explicit System.dll + implicit mscorlib.
        # /noconfig prevents csc.rsp from masking missing production references.
        & $compiler /nologo /noconfig /reference:System.dll /target:exe /platform:x64 /langversion:5 /warnaserror+ "/out:$executable" $source $checks
        if ($LASTEXITCODE -ne 0) { throw 'Actual headless native adapter failed Framework C# 5 compilation.' }
        # Compile through the actual non-elevated UI module too, without invoking any native API.
        Import-Module (Join-Path $repository 'host/windows/HeadlessSetup.psm1') -Force
        Initialize-KnotHeadlessNative
        $output=@(& $executable)
        if ($LASTEXITCODE -ne 0) { throw 'Headless native synthetic checks failed.' }
        if ($output.Count -eq 0) { throw 'Headless native fixture returned no result.' }
        $result=$output[-1] | ConvertFrom-Json
        if ($result.status -cne 'passed' -or $result.checks -lt 370 -or -not $result.freshSyntheticOnly -or $result.nativeApisInvoked) { throw 'Incomplete headless native fixture result.' }
        $result | Add-Member -NotePropertyName frameworkCompiler -NotePropertyValue $true
        $result | ConvertTo-Json -Compress
    } finally { [IO.Directory]::Delete($directory,$true) }
} elseif ($PSVersionTable.PSEdition -eq 'Core') {
    # Additional portable execution, still compiling the same actual source.
    $definition=[IO.File]::ReadAllText($source)+"`n"+[IO.File]::ReadAllText($checks)
    Add-Type -TypeDefinition $definition -CompilerOptions '/langversion:5'
    $count=[Knot.Headless.HeadlessNativeChecks]::Run()
    if ($count -lt 370) { throw 'Incomplete headless native fixture result.' }
    @{status='passed';checks=$count;freshSyntheticOnly=$true;nativeApisInvoked=$false;frameworkCompiler=$false} | ConvertTo-Json -Compress
} else {
    throw 'The 64-bit .NET Framework C# compiler is required.'
}
