#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param([string] $Dotnet = 'dotnet', [string] $Python = 'python', [string] $References, [string] $NativeCompiler)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $References) { $References=Join-Path ${env:ProgramFiles(x86)} 'Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8' }
$sdk=@(& $Dotnet --list-sdks | ForEach-Object {
    if ($_ -match '^([0-9]+\.[0-9]+\.[0-9]+) \[(.+)\]$') {
        [pscustomobject]@{Version=[version]$matches[1];Path=(Join-Path $matches[2] $matches[1])}
    }
} | Sort-Object Version -Descending | Select-Object -First 1)
if ($LASTEXITCODE -ne 0 -or $sdk.Count -ne 1) { throw 'A supported .NET SDK is required to build, not to run, the Windows helper.' }
$compiler=Join-Path $sdk[0].Path 'Roslyn\bincore\csc.dll'
if (-not $NativeCompiler) { $NativeCompiler=(Get-Command zig -ErrorAction Stop).Source }
& $Python (Join-Path $root 'scripts\build_windows_launcher.py') --dotnet $Dotnet --compiler $compiler --references $References --native-compiler $NativeCompiler
if ($LASTEXITCODE -ne 0) { throw 'Windows single-file helper compilation failed' }
