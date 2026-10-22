#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference='Stop'
$module=Join-Path (Split-Path $PSScriptRoot -Parent) 'SetupDownload.psm1'
$repository=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($module,[ref]$tokens,[ref]$errors)
if ($errors.Count -ne 0) {throw 'Download module has parse errors'}
$source=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('internal static class BoundedDownload')},$true))
if ($source.Count -ne 1) {throw 'Expected exactly one actual download implementation'}
$fixture=Get-Content -LiteralPath (Join-Path $repository 'scripts/tests/SetupDownloadChecks.cs') -Raw -Encoding UTF8
# Production uses Windows PowerShell/.NET Framework, where this abortable
# HttpWebRequest API is supported. Modern .NET marks it obsolete; suppress only
# that migration diagnostic in this cross-runtime fixture, not compiler errors.
$compileOptions=@{}
if ($PSVersionTable.PSEdition -eq 'Core') { $compileOptions.CompilerOptions='/nowarn:SYSLIB0014' }
Add-Type -TypeDefinition ($source[0].Value + "`n" + $fixture) @compileOptions
$directory=Join-Path ([IO.Path]::GetTempPath()) ('knot-bounded-download-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory) | Out-Null
try {
    $checks=[DeskBridge.Setup.SetupDownloadChecks]::Run($directory)
    if ($checks -lt 30) {throw 'Incomplete download fixture result'}
    @{status='passed';checks=$checks;freshSyntheticOnly=$true;networkUsed=$false;guiUsed=$false} | ConvertTo-Json -Compress
} finally { [IO.Directory]::Delete($directory,$true) }
