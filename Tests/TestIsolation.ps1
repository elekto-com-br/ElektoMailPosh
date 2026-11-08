# What keeps the tests away from the accounts of whoever runs them: a developer who downloads the module and runs its
# tests must never see a real account, password or setting changed, nor read. Every test file that imports the module
# calls Enter-TestIsolation in its BeforeAll and Exit-TestIsolation in its AfterAll, and Tests/TestIsolation.Tests.ps1
# fails on a file that does not:
# - every SMTP_* variable, and XDG_CONFIG_HOME, is put aside and cleared, so that no password, server or folder of this
#   machine reaches a test;
# - SMTP_CONFIG_DIR is a folder of the test drive, which holds accounts.json and, on Linux and macOS, the password files;
# - on Windows, where the passwords go to the Credential Manager of the user whatever the folder, the functions that
#   read, store and delete them are replaced by ones that touch nothing.
# Invoke-AsUserScript runs a script in a process of its own with the same isolation, and refuses to run one whose
# accounts would be outside the test drive. Build.ps1 adds a check of its own: the real accounts (their folders, and on
# Windows the credentials of the module in the Credential Manager), compared before and after the tests.

# Clears the variables, points SMTP_CONFIG_DIR into the test drive and, on Windows (or with -ReplaceStore),
# replaces the password store. Returns what Exit-TestIsolation puts back.
# Variables are deleted through the provider (Remove-Item env:): [Environment]::SetEnvironmentVariable($name, $null) no
# longer deletes one since .NET 9 (PowerShell 7.5), as $null reaches it as an empty string, which now leaves the
# variable, empty (measured with PowerShell 7.6, where the variables the tests set were still listed afterwards).
function Enter-TestIsolation([switch]$ReplaceStore = $IsWindows) {
    $saved = @{}
    foreach ($name in @(Get-ChildItem -Path env: | Where-Object Name -Like 'SMTP_*' | ForEach-Object Name) + 'XDG_CONFIG_HOME') {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        Remove-Item -Path "env:$name" -ErrorAction Ignore
    }
    $env:SMTP_CONFIG_DIR = Join-Path $TestDrive 'config'
    New-Item -ItemType Directory -Path $env:SMTP_CONFIG_DIR -Force | Out-Null
    if ($ReplaceStore) { Disable-PasswordStore }
    return $saved
}

# Replaces the functions of the module that read, store and delete passwords by ones that touch nothing, in the block
# of tests it is called from
function Disable-PasswordStore {
    Mock -ModuleName ElektoMailPosh Read-StoredPassword { $null }
    Mock -ModuleName ElektoMailPosh Save-StoredPassword { }
    Mock -ModuleName ElektoMailPosh Clear-StoredPassword { $false }
}

# Clears every SMTP_* variable, those the tests set among them, and puts back those Enter-TestIsolation cleared
function Exit-TestIsolation([hashtable]$Saved) {
    foreach ($name in @(Get-ChildItem -Path env: | Where-Object Name -Like 'SMTP_*' | ForEach-Object Name) + 'XDG_CONFIG_HOME') {
        Remove-Item -Path "env:$name" -ErrorAction Ignore
    }
    foreach ($entry in $Saved.GetEnumerator()) {
        if ($null -ne $entry.Value) { Set-Item -Path "env:$($entry.Key)" -Value $entry.Value }
    }
}

# Whether a path is a folder, or a folder within it, compared as the file system of the platform compares names
function Test-InFolder([string]$Path, [string]$Folder) {
    if (-not $Path -or -not $Folder) { return $false }
    $separator = [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath($Path).TrimEnd($separator) + $separator
    $root = [IO.Path]::GetFullPath($Folder).TrimEnd($separator) + $separator
    return $full.StartsWith($root, $(if ($IsLinux) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }))
}

# Runs a script in a process of its own, as a user's script runs, and returns its output as text. Pester runs each test
# inside a try/catch, and within one an exception of .NET stops the command, where in a script without one it ends only
# its own statement and the command goes on (measured); the XML in which PowerShell takes back the output of a script
# block stops it too (measured), so the output comes back as text. The script gets the module as its argument.
# The accounts are those of -Config, by default SMTP_CONFIG_DIR, which must be a folder of the test drive: a test that
# got there with the variable cleared would otherwise change the real accounts. The process refuses to run without
# it, replaces the password store as Enter-TestIsolation does, and says, before the script runs, that the module is
# imported and where it keeps the accounts: a process that fails before that throws here, rather than pass for one in
# which the command did nothing. With -Culture the process starts in that culture, before the module is loaded, as
# PowerShell keeps the regexes it built.
function Invoke-AsUserScript(
    [Parameter(Mandatory)][scriptblock]$Script,
    [string]$Config = $env:SMTP_CONFIG_DIR,
    [string]$Culture,
    [switch]$ReplaceStore = $IsWindows,
    [string]$Manifest = (Join-Path (Split-Path $PSScriptRoot) 'ElektoMailPosh.psd1')
) {
    if (-not (Test-InFolder $Config $TestDrive)) {
        throw "Refusing to run a test process with the accounts in '$Config': they must be in a folder of the test drive '$TestDrive', or the real accounts would be at stake."
    }
    $ready = 'ElektoMailPosh test process, accounts in '
    $output = @(& ([Environment]::ProcessPath) -NoProfile -NonInteractive -OutputFormat text -Command {
            param($Manifest, $Config, $Culture, $ReplaceStore, $Ready, $Script)
            if (-not $Config) { throw 'No folder for the accounts: refusing to run, as the module would use the real ones.' }
            if ($Culture) { [cultureinfo]::CurrentCulture = $Culture }
            $env:SMTP_CONFIG_DIR = $Config
            $module = Import-Module $Manifest -PassThru -ErrorAction Stop
            if ($ReplaceStore -eq $true) {
                & $module {
                    function script:Read-StoredPassword { $null }
                    function script:Save-StoredPassword { }
                    function script:Clear-StoredPassword { $false }
                }
            }
            $Ready + (& $module { Get-AccountDirectory })
            & ([scriptblock]::Create($Script)) $module
        } -args $Manifest, $Config, $Culture, ([bool]$ReplaceStore), $ready, "$Script" 2>$null)
    $first = if ($output.Count) { "$($output[0])" } else { '' }
    if (-not $first.StartsWith($ready, [StringComparison]::Ordinal) -or -not (Test-InFolder $first.Substring($ready.Length) $TestDrive)) {
        throw "The test process did not start as it should: $(if ($output.Count) { $output -join ' | ' } else { 'no output' })"
    }
    return $output | Select-Object -Skip 1
}
