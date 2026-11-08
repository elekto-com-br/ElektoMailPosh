<#
.SYNOPSIS
Validates the module and stages the files that go to the PowerShell Gallery.

.DESCRIPTION
The PowerShell equivalent of "does it compile": every script is parsed for syntax errors,
the manifest is validated, PSScriptAnalyzer runs (when installed), the module is imported
in a clean process to check that the public commands are exported, and the tests in ./Tests run with
Pester 5 or later (when installed). If everything passes, the package files are copied to
./out/ElektoMailPosh, ready for Publish-PSResource.

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
$packageFiles = @("$moduleName.psd1", "$moduleName.psm1", 'Private', 'Public', 'LICENSE', 'README.md')

# What the accounts of this machine are, as text, enough to see that one changed without reading what it holds: the
# files of their folders, each as its path, size and time of last write, password files among them; and on Windows,
# where the passwords go to the Credential Manager whatever the folder, the credentials of the module, each as its name
# and time of last write. These come from CredEnumerate, as cmdkey writes its list in the language of the system; the
# password of a credential is never read. As ElektoImapPosh does since its #25.
function Get-AccountState([string[]]$Folders) {
    foreach ($folder in $Folders | Select-Object -Unique) {
        if (Test-Path -LiteralPath $folder) {
            Get-ChildItem -LiteralPath $folder -Recurse -Force -File | ForEach-Object { '{0} {1} {2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks }
        }
    }
    if (-not $IsWindows) { return }
    if (-not ('ElektoMailPoshBuild.Credentials' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ElektoMailPoshBuild
{
    public static class Credentials
    {
        private const int ERROR_NOT_FOUND = 1168;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL
        {
            public int Flags;
            public int Type;
            public string TargetName;
            public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public int CredentialBlobSize;
            public IntPtr CredentialBlob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredEnumerateW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredEnumerate(string filter, int flags, out int count, out IntPtr credentials);

        [DllImport("advapi32.dll", EntryPoint = "CredFree")]
        private static extern void CredFree(IntPtr buffer);

        // The credentials whose names match the filter, each as its name and the time it was last written
        public static string[] List(string filter)
        {
            int count;
            IntPtr list;
            if (!CredEnumerate(filter, 0, out count, out list))
            {
                int error = Marshal.GetLastWin32Error();
                if (error == ERROR_NOT_FOUND) { return new string[0]; }
                throw new Win32Exception(error);
            }
            try
            {
                var names = new List<string>();
                for (int i = 0; i < count; i++)
                {
                    var credential = Marshal.PtrToStructure<CREDENTIAL>(Marshal.ReadIntPtr(list, i * IntPtr.Size));
                    long written = ((long)(uint)credential.LastWritten.dwHighDateTime << 32) | (uint)credential.LastWritten.dwLowDateTime;
                    names.Add(credential.TargetName + " " + written);
                }
                return names.ToArray();
            }
            finally
            {
                CredFree(list);
            }
        }
    }
}
'@
    }
    [ElektoMailPoshBuild.Credentials]::List("${moduleName}:*")
}

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

# 4. Import in a clean process and check that every public script exports its command
$publicCommands = (Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1').BaseName -join "', '"
$importCheck = "Import-Module '$manifestPath' -Force -ErrorAction Stop; " +
    "foreach (`$command in '$publicCommands') { " +
    "if (-not (Get-Command `$command -Module $moduleName -ErrorAction SilentlyContinue)) { throw `"`$command not exported`" } }"
pwsh -NoProfile -NonInteractive -Command $importCheck
if ($LASTEXITCODE -ne 0) { throw "Module import check failed." }
Write-Host "Import OK."

# 5. Tests, in a clean process too (Windows PowerShell ships a Pester 3, which can't run them). Whoever runs the build
# may have real accounts, which no test may touch. Each test file keeps its accounts in its test drive and reaches no
# real password store (Tests/TestIsolation.ps1); besides, the tests run with SMTP_CONFIG_DIR and, on Linux and macOS,
# HOME in a temporary folder, so that the default folder of accounts is not the real one either. The build fails if the
# real accounts changed (Get-AccountState: the files of their folders, and on Windows the credentials of the module,
# compared by name, size and time, never by what they hold), or if a test left accounts in the temporary folder.
if (Get-Module -ListAvailable Pester | Where-Object Version -ge '5.0') {
    # The folders in which the module keeps the accounts of this machine, as it finds them
    $realFolders = @(pwsh -NoProfile -NonInteractive -Command "Import-Module '$manifestPath' -ErrorAction Stop; & (Get-Module $moduleName) { Get-AccountDirectory; Get-ApplicationDataDirectory }" | Select-Object -Unique)
    if ($LASTEXITCODE -ne 0 -or $realFolders.Count -eq 0) { throw 'Could not find the folders of the accounts of this machine.' }
    $before = @(Get-AccountState $realFolders)

    $testHome = Join-Path ([IO.Path]::GetTempPath()) "$moduleName-tests-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $testHome | Out-Null
    $savedEnvironment = @{}
    foreach ($name in 'HOME', 'XDG_CONFIG_HOME', 'SMTP_CONFIG_DIR') { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        if (-not $IsWindows) {
            $env:HOME = $testHome
            $env:XDG_CONFIG_HOME = $null
        }
        $env:SMTP_CONFIG_DIR = Join-Path $testHome 'config'
        $testRun = "Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop; " +
            "if ((Invoke-Pester -Path '$(Join-Path $PSScriptRoot 'Tests')' -Output Detailed -PassThru).Result -ne 'Passed') { exit 1 }"
        pwsh -NoProfile -NonInteractive -Command $testRun
        $testsFailed = $LASTEXITCODE -ne 0
    } finally {
        # Through the provider: [Environment]::SetEnvironmentVariable($name, $null) leaves the variable, empty, since
        # .NET 9 (PowerShell 7.5), and a build run in a session would leave it so there
        foreach ($entry in $savedEnvironment.GetEnumerator()) {
            if ($null -eq $entry.Value) { Remove-Item -Path "env:$($entry.Key)" -ErrorAction Ignore }
            else { Set-Item -Path "env:$($entry.Key)" -Value $entry.Value }
        }
    }

    $after = @(Get-AccountState $realFolders)
    $changed = @($before | Where-Object { $_ -notin $after } | ForEach-Object { "before: $_" }) + @($after | Where-Object { $_ -notin $before } | ForEach-Object { "after:  $_" })
    $strays = @('config', ".config/$moduleName", "Library/Application Support/$moduleName" | ForEach-Object { Join-Path $testHome $_ } | Where-Object { Test-Path -LiteralPath $_ })
    Remove-Item -LiteralPath $testHome -Recurse -Force -ErrorAction Ignore
    if ($changed) { throw "The tests changed the accounts of this machine ($($realFolders -join ', ')$(if ($IsWindows) { ", credentials ${moduleName}:*" })):`n$($changed -join "`n")" }
    if ($strays) { throw "A test kept accounts outside its test drive: $($strays -join ', ')." }
    if ($testsFailed) { throw "Tests failed." }
    Write-Host "Tests OK, and the accounts of this machine untouched."
} else {
    Write-Warning "Pester 5 or later not installed; skipping tests."
}

# 6. Stage the package
$outDir = Join-Path (Join-Path $PSScriptRoot 'out') $moduleName
if (Test-Path $outDir) { Remove-Item -Path $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir | Out-Null
foreach ($file in $packageFiles) {
    Copy-Item -Path (Join-Path $PSScriptRoot $file) -Destination $outDir -Recurse
}
Write-Host "Package staged at $outDir."
