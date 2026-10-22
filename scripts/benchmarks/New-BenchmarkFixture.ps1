# SPDX-License-Identifier: GPL-3.0-only
# Windows PowerShell 5.1+; creates only a new temp folder. No admin, services or settings.
[CmdletBinding()]
param([ValidateRange(1, 1024)][int]$LargeFileMiB = 100)
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('DeskBridgeBench-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
Write-Output ('New synthetic fixture folder: ' + $fixture)
$manifest = @()
$rng = $null
try {
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    foreach ($size in @(1, $LargeFileMiB) | Select-Object -Unique) {
        $name = 'synthetic-' + $size + 'MiB.bin'
        $path = Join-Path $fixture $name
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $buffer = New-Object byte[] (1024 * 1024)
            for ($index = 0; $index -lt $size; $index++) {
                $rng.GetBytes($buffer)
                $stream.Write($buffer, 0, $buffer.Length)
            }
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest += [pscustomobject]@{ name = $name; bytes = [long]$size * 1024 * 1024; sha256 = $hash; origin = 'new-cryptographic-random-fixture' }
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'synthetic-desktop.html') -Destination (Join-Path $fixture 'synthetic-desktop.html')
    $html = Join-Path $fixture 'synthetic-desktop.html'
    $manifest += [pscustomobject]@{ name = 'synthetic-desktop.html'; bytes = (Get-Item -LiteralPath $html).Length; sha256 = (Get-FileHash -LiteralPath $html -Algorithm SHA256).Hash.ToLowerInvariant(); origin = 'versioned-synthetic-html-fixture' }
    $json = ConvertTo-Json -InputObject @($manifest) -Depth 4
    [IO.File]::WriteAllText((Join-Path $fixture 'manifest.json'), $json, (New-Object Text.UTF8Encoding $false))
    Write-Output 'Open synthetic-desktop.html on the Windows test display. Use only these new files for transfers.'
    Write-Output 'Record client/host versions, resolution/scaling, actual codec, route evidence and monitor input state. No measurements have been collected by this generator.'
    Write-Output 'Delete this specific folder after testing. The script does not change SSH, Sunshine, services, firewall or machine policy.'
} catch {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction Continue
    throw
} finally { if ($null -ne $rng) { $rng.Dispose() } }
