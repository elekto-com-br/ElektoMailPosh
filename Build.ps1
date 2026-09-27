<#
.SYNOPSIS
Validates the module and stages the files that go to the PowerShell Gallery.

.DESCRIPTION
The PowerShell equivalent of "does it compile": every script is parsed for syntax errors,
the manifest is validated, PSScriptAnalyzer runs (when installed) and the module is imported
in a clean process to check that Send-Mail is exported. If everything passes, the package
files are copied to ./out/ElektoMailPosh, ready for Publish-PSResource.

Used by .github/workflows/publish.yml; can also be run locally before tagging.

.PARAMETER ExpectedVersion
When given (the CI passes the tag version), fails unless the manifest declares this version.

.EXAMPLE
./Build.ps1

.EXAMPLE
./Build.ps1 -ExpectedVersion 0.2.1
#>
param (
    [string]$ExpectedVersion
)

$ErrorActionPreference = 'Stop'
$moduleName = 'ElektoMailPosh'
$manifestPath = Join-Path $PSScriptRoot "$moduleName.psd1"
$packageFiles = @("$moduleName.psd1", "$moduleName.psm1", 'Public', 'LICENSE', 'README.md')

# 1. Syntax: parse every PowerShell file
$scripts = Get-ChildItem -Path $PSScriptRoot -Recurse -Include '*.ps1', '*.psm1', '*.psd1' |
    Where-Object { $_.FullName -notmatch '[\\/](out|\.git)[\\/]' }
$syntaxErrors = foreach ($script in $scripts) {
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$null, [ref]$parseErrors) | Out-Null
    $parseErrors | ForEach-Object { "$($script.Name):$($_.Extent.StartLineNumber): $($_.Message)" }
}
if ($syntaxErrors) { throw "Syntax errors:`n$($syntaxErrors -join "`n")" }
Write-Host "Syntax OK ($($scripts.Count) files)."

# 2. Manifest, and version against the tag
$manifest = Test-ModuleManifest -Path $manifestPath
if ($ExpectedVersion -and $manifest.Version.ToString() -ne $ExpectedVersion) {
    throw "Tag means version '$ExpectedVersion', but the manifest declares '$($manifest.Version)'. Set them to the same value and re-tag."
}
Write-Host "Manifest OK (version $($manifest.Version))."

# 3. Static analysis: errors fail the build, warnings are only shown
if (Get-Module -ListAvailable PSScriptAnalyzer) {
    $findings = Invoke-ScriptAnalyzer -Path $PSScriptRoot -Recurse -ExcludeRule PSAvoidUsingWriteHost
    if ($findings) { $findings | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message | Out-String | Write-Host }
    $analyzerErrors = @($findings | Where-Object Severity -eq 'Error')
    if ($analyzerErrors) { throw "PSScriptAnalyzer found $($analyzerErrors.Count) error(s)." }
    Write-Host "PSScriptAnalyzer OK."
} else {
    Write-Warning "PSScriptAnalyzer not installed; skipping static analysis."
}

# 4. Import in a clean process and check the exported command
$importCheck = "Import-Module '$manifestPath' -Force -ErrorAction Stop; " +
    "if (-not (Get-Command Send-Mail -Module $moduleName -ErrorAction SilentlyContinue)) { throw 'Send-Mail not exported' }"
pwsh -NoProfile -NonInteractive -Command $importCheck
if ($LASTEXITCODE -ne 0) { throw "Module import check failed." }
Write-Host "Import OK."

# 5. Stage the package
$outDir = Join-Path (Join-Path $PSScriptRoot 'out') $moduleName
if (Test-Path $outDir) { Remove-Item -Path $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir | Out-Null
foreach ($file in $packageFiles) {
    Copy-Item -Path (Join-Path $PSScriptRoot $file) -Destination $outDir -Recurse
}
Write-Host "Package staged at $outDir."
