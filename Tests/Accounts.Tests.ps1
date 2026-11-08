# The accounts file and the password store. The file is read ignoring case, as the rest of the module and the
# password stores are: keys and settings in any case, accounts found by their name in any case, and two names
# refused when they would be the same account or share a password variable. The folder it is kept in. And the
# file and the passwords kept whole when reading, writing or deleting fails. The password stores are replaced by
# mocks or by SMTP_PASS_<ACCOUNT>, so no real one is read or written, but for the password files of Linux and
# macOS, under the test folder, to see a write and a deletion that fail.

# PSScriptAnalyzer does not see that Pester gives the tests the variables of BeforeDiscovery, BeforeAll and BeforeEach
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables of BeforeDiscovery, BeforeAll and BeforeEach are used by the tests')]
param ()

BeforeDiscovery {
    # Root reads, writes and deletes files whatever their modes and those of their folders
    $isRoot = -not $IsWindows -and (id -u) -eq '0'
}

BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'ElektoMailPosh.psd1') -Force

    # An empty configuration folder, and the password of the account "work" in the environment, so that
    # no password store is read
    $savedEnvironment = @{}
    foreach ($name in 'SMTP_CONFIG_DIR', 'SMTP_PASS_WORK', 'XDG_CONFIG_HOME') {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $env:SMTP_CONFIG_DIR = Join-Path $TestDrive 'config'
    $env:SMTP_PASS_WORK = 'not-a-password'
    New-Item -ItemType Directory -Path $env:SMTP_CONFIG_DIR | Out-Null
    $accountsFile = Join-Path $env:SMTP_CONFIG_DIR 'accounts.json'
    $manifestPath = Join-Path (Split-Path $PSScriptRoot) 'ElektoMailPosh.psd1'

    # Runs a script in a process of its own, as a user's script runs, and returns its output as text. Pester runs each
    # test inside a try/catch, and within one an exception of .NET stops the command, where in a script without one it
    # ends only its own statement and the command goes on (measured); the XML in which PowerShell takes back the output
    # of a script block stops it too (measured), so the output comes back as text. The script gets the module, with
    # the configuration folder of the tests.
    function Invoke-AsUserScript([scriptblock]$Script) {
        & ([Environment]::ProcessPath) -NoProfile -NonInteractive -OutputFormat text -Command {
            param($Manifest, $Config, $Script)
            $env:SMTP_CONFIG_DIR = $Config
            $module = Import-Module $Manifest -PassThru
            & ([scriptblock]::Create($Script)) $module
        } -args $manifestPath, $env:SMTP_CONFIG_DIR, "$Script" 2>$null
    }
}

AfterAll {
    foreach ($entry in $savedEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
    }
    Remove-Module ElektoMailPosh -ErrorAction SilentlyContinue
}

Describe 'The accounts file, read ignoring case' {
    It 'reads Default and Accounts in any case' {
        Set-Content -Path $accountsFile -Value '{ "default": "work", "accounts": { "work": { "Server": "smtp.example.com", "User": "me@example.com" } } }'

        $account = Get-MailAccount
        $account.Name | Should -Be 'work'
        $account.Default | Should -BeTrue
    }

    It 'reads the settings in any case' {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "work": { "server": "smtp.example.com", "USER": "me@example.com", "port": 2525 } } }'

        $account = Get-MailAccount work
        $account.Server | Should -Be 'smtp.example.com'
        $account.User | Should -Be 'me@example.com'
        $account.Port | Should -Be 2525
    }

    It 'finds an account by its name in any case' {
        Set-Content -Path $accountsFile -Value '{ "Default": "WORK", "Accounts": { "Work": { "Server": "smtp.example.com", "User": "me@example.com" } } }'

        (Get-MailAccount wORK).Name | Should -Be 'Work'
        (Get-MailAccount w*).Name | Should -Be 'Work'
        (Get-MailAccount Work).Default | Should -BeTrue
    }

    It 'keeps the spelling of the name when an account is changed by another' {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "Work": { "Server": "smtp.example.com", "User": "me@example.com" } } }'

        Set-MailAccount -Name WORK -FromName 'Office'

        $file = Get-Content -Path $accountsFile -Raw | ConvertFrom-Json -AsHashtable
        @($file.Accounts.Keys) | Should -Be 'Work'
        $file.Accounts.Work.FromName | Should -Be 'Office'
    }

    It 'removes an account by its name in any case' {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "Work": { "Server": "smtp.example.com", "User": "me@example.com" } } }'
        Mock -ModuleName ElektoMailPosh Clear-StoredPassword { $false }

        # It warns, rightly, that SMTP_PASS_WORK still holds the password
        Remove-MailAccount WORK -WarningAction SilentlyContinue

        $file = Get-Content -Path $accountsFile -Raw | ConvertFrom-Json -AsHashtable
        $file.Accounts.Count | Should -Be 0
    }
}

Describe 'Names in the accounts file that would be the same' {
    It 'are refused for <Case>' -TestCases @(
        @{ Case = 'two accounts'; Message = "*'Work' and 'work'*differ only in case*"
            Json = '{ "Accounts": { "Work": { "Server": "a.example.com", "User": "a@example.com" }, "work": { "Server": "b.example.com", "User": "b@example.com" } } }' }
        @{ Case = 'two accounts with one password variable'; Message = "*'work.prod' and 'work-prod'*share the password variable SMTP_PASS_WORK_PROD*"
            Json = '{ "Accounts": { "work.prod": { "Server": "a.example.com", "User": "a@example.com" }, "work-prod": { "Server": "b.example.com", "User": "b@example.com" } } }' }
        @{ Case = 'a key'; Message = "*key 'Default' is twice*"
            Json = '{ "Default": "work", "default": "work", "Accounts": { "work": { "Server": "smtp.example.com", "User": "me@example.com" } } }' }
        @{ Case = 'a setting'; Message = "*setting 'Server' is twice*"
            Json = '{ "Accounts": { "work": { "Server": "a.example.com", "server": "b.example.com", "User": "me@example.com" } } }' }
    ) {
        Set-Content -Path $accountsFile -Value $Json

        { Get-MailAccount } | Should -Throw -ExpectedMessage $Message
    }

    # SMTP_PASS_WORK_PROD would give the password of one to the server of the other
    It 'are refused for a new account that would share the password variable of another' {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "work.prod": { "Server": "a.example.com", "User": "a@example.com" } } }'
        Mock -ModuleName ElektoMailPosh Read-StoredPassword { $null }

        { Set-MailAccount -Name work-prod -Server b.example.com -User b@example.com } | Should -Throw -ExpectedMessage "*SMTP_PASS_WORK_PROD with the account 'work.prod'*"

        (Get-MailAccount -WarningAction SilentlyContinue).Name | Should -Be 'work.prod'
    }
}

Describe 'The configuration folder' {
    BeforeAll {
        $env:SMTP_CONFIG_DIR = $null
    }

    AfterAll {
        $env:SMTP_CONFIG_DIR = Join-Path $TestDrive 'config'
        $env:XDG_CONFIG_HOME = $savedEnvironment.XDG_CONFIG_HOME
    }

    It 'is ElektoMailPosh in %APPDATA% on Windows' -Skip:(-not $IsWindows) {
        InModuleScope ElektoMailPosh { Get-AccountDirectory } | Should -Be (Join-Path $env:APPDATA 'ElektoMailPosh')
    }

    # The same code for Linux and macOS, where .NET 8 and later give ~/Library/Application Support instead. The
    # folder of 2.0.3 and before is put out of the way, as a real one of this machine would be taken instead.
    It 'is ElektoMailPosh in ~/.config on Linux and macOS, or in XDG_CONFIG_HOME when it is an absolute path' -Skip:$IsWindows {
        Mock -ModuleName ElektoMailPosh Get-ApplicationDataDirectory { Join-Path $TestDrive 'nowhere' }

        $env:XDG_CONFIG_HOME = $null
        InModuleScope ElektoMailPosh { Get-AccountDirectory } | Should -Be (Join-Path $HOME '.config/ElektoMailPosh')
        $env:XDG_CONFIG_HOME = Join-Path $TestDrive 'xdg'
        InModuleScope ElektoMailPosh { Get-AccountDirectory } | Should -Be (Join-Path $TestDrive 'xdg/ElektoMailPosh')
        $env:XDG_CONFIG_HOME = 'relative/xdg'
        InModuleScope ElektoMailPosh { Get-AccountDirectory } | Should -Be (Join-Path $HOME '.config/ElektoMailPosh') -Because 'XDG_CONFIG_HOME counts only as an absolute path'
    }

    # 2.0.0 to 2.0.3 kept it in the folder .NET gives for ApplicationData: ~/Library/Application Support on macOS
    It 'is that of 2.0.3 and before while it has an accounts file and the new one has none' -Skip:$IsWindows {
        $env:XDG_CONFIG_HOME = Join-Path $TestDrive 'moved/xdg'
        $new = Join-Path $env:XDG_CONFIG_HOME 'ElektoMailPosh'
        $previous = Join-Path $TestDrive 'moved/Library/Application Support/ElektoMailPosh'
        Mock -ModuleName ElektoMailPosh Get-ApplicationDataDirectory { $previous }
        $json = '{ "Accounts": { "work": { "Server": "smtp.example.com", "User": "me@example.com" } } }'

        InModuleScope ElektoMailPosh { Get-AccountDirectory } | Should -Be $new -Because 'neither has an accounts file'

        New-Item -ItemType Directory -Path $previous -Force | Out-Null
        Set-Content -Path (Join-Path $previous 'accounts.json') -Value $json
        InModuleScope ElektoMailPosh { Get-AccountDirectory } | Should -Be $previous -Because 'only the folder of 2.0.3 has an accounts file'
        InModuleScope ElektoMailPosh { Get-PasswordFilePath work } | Should -Be (Join-Path $previous 'secrets/work')
        (Get-MailAccount).Name | Should -Be 'work'

        New-Item -ItemType Directory -Path $new -Force | Out-Null
        Set-Content -Path (Join-Path $new 'accounts.json') -Value '{ "Accounts": {} }'
        InModuleScope ElektoMailPosh { Get-AccountDirectory } | Should -Be $new -Because 'the new folder has an accounts file'
    }
}

Describe 'Keeping the accounts file whole' {
    BeforeEach {
        Set-Content -Path $accountsFile -Value '{ "Default": "work", "Accounts": { "work": { "Server": "smtp.example.com", "User": "me@example.com" } } }'
        Mock -ModuleName ElektoMailPosh Save-StoredPassword { }
        Mock -ModuleName ElektoMailPosh Read-StoredPassword { $null }
        $password = [Net.NetworkCredential]::new('', 'not-a-password').SecurePassword
    }

    # Taken as empty, Send-Mail went back to the SMTP_* variables, and Set-MailAccount wrote the new account over the
    # others
    It 'stops a command when the file cannot be read, rather than take it as empty' {
        $lock = [IO.File]::Open($accountsFile, 'Open', 'ReadWrite', 'None')
        try {
            { Get-MailAccount } | Should -Throw -ExpectedMessage '*Could not read the accounts file*'
            { InModuleScope ElektoMailPosh { Resolve-MailConfiguration '' } } | Should -Throw -ExpectedMessage '*Could not read the accounts file*'
            { Set-MailAccount -Name home -Server smtp.example.net -User me@example.net -Password $password } | Should -Throw -ExpectedMessage '*Could not read the accounts file*'
        } finally {
            $lock.Dispose()
        }
        (Get-MailAccount).Name | Should -Be 'work'
    }

    It 'leaves the previous file whole when writing fails halfway' {
        Mock -ModuleName ElektoMailPosh Set-Content { [IO.File]::WriteAllText($LiteralPath, '{ "Accounts": {'); throw 'The disk is full.' }

        { Set-MailAccount -Name home -Server smtp.example.net -User me@example.net -Password $password } | Should -Throw -ExpectedMessage '*disk is full*'

        (Get-MailAccount).Name | Should -Be 'work'
        @(Get-ChildItem -Path $env:SMTP_CONFIG_DIR -Filter '*.tmp') | Should -BeNullOrEmpty
        Should -Invoke -ModuleName ElektoMailPosh Save-StoredPassword -Times 0 -Exactly
    }

    # The rename throws an exception of .NET, as on Windows while another program has the file open, which ended only
    # its own statement: Set-MailAccount went on to store the password of an account it had not written
    It 'stops the command when the new file cannot be put in its place' {
        # A folder where accounts.json goes, which the rename cannot replace
        Remove-Item -LiteralPath $accountsFile -Force
        New-Item -ItemType Directory -Path $accountsFile | Out-Null
        try {
            $null = Invoke-AsUserScript {
                param($Module)
                # A password store that leaves a mark, and touches no real one
                & $Module { function script:Save-StoredPassword { New-Item -ItemType File -Path (Join-Path $env:SMTP_CONFIG_DIR 'stored') | Out-Null } }
                Set-MailAccount -Name home -Server smtp.example.net -User me@example.net -Password ([Net.NetworkCredential]::new('', 'not-a-password').SecurePassword)
            }

            Join-Path $env:SMTP_CONFIG_DIR 'stored' | Should -Not -Exist -Because 'Set-MailAccount stops before it stores the password of an account it did not write'
            @(Get-ChildItem -Path $env:SMTP_CONFIG_DIR -Filter '*.tmp') | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $accountsFile -Recurse -Force
        }
    }

    It 'keeps an account whose password could not be deleted' {
        Mock -ModuleName ElektoMailPosh Clear-StoredPassword { throw 'Access to the password is denied.' }

        { Remove-MailAccount work -WarningAction SilentlyContinue } | Should -Throw -ExpectedMessage '*denied*'

        (Get-MailAccount).Name | Should -Be 'work'
    }
}

# A file its owner can write but not read was taken as empty, and the write that followed emptied it before it
# failed: every account was lost (measured). Not as root, who reads it all the same.
Describe 'An accounts file that can be written but not read' -Skip:($IsWindows -or $isRoot) {
    It 'stops Set-MailAccount, and stays as it was' {
        $json = '{ "Accounts": { "work": { "Server": "smtp.example.com", "User": "me@example.com" } } }'
        Set-Content -Path $accountsFile -Value $json
        [IO.File]::SetUnixFileMode($accountsFile, 'UserWrite')
        try {
            { Set-MailAccount -Name home -Server smtp.example.net -User me@example.net -WarningAction SilentlyContinue } | Should -Throw -ExpectedMessage '*Could not read the accounts file*'
        } finally {
            [IO.File]::SetUnixFileMode($accountsFile, 'UserRead, UserWrite')
        }

        (Get-Content -Path $accountsFile -Raw).Trim() | Should -Be $json
    }
}

# The real password files, under the test folder (so not on Windows, where the store is the Credential Manager)
Describe 'A password file that cannot be written or deleted' -Skip:$IsWindows {
    BeforeAll {
        $env:SMTP_PASS_WORK = $null
        $secrets = Join-Path $env:SMTP_CONFIG_DIR 'secrets'
        $password = [Net.NetworkCredential]::new('', 'not-a-password').SecurePassword
    }

    AfterAll {
        $env:SMTP_PASS_WORK = 'not-a-password'
    }

    BeforeEach {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "work": { "Server": "smtp.example.com", "User": "me@example.com" } } }'
    }

    # Written through .NET, whose exceptions ended only their own statement: Set-MailAccount went on as if stored
    It 'stops Set-MailAccount when it cannot be written, and leaves the account without a password' {
        # A folder where the password file goes
        $folder = New-Item -ItemType Directory -Path (Join-Path $secrets 'work') -Force
        try {
            $output = Invoke-AsUserScript { Set-MailAccount -Name work -Password ([Net.NetworkCredential]::new('', 'not-a-password').SecurePassword) -Verbose 4>&1 }

            $output -join "`n" | Should -Not -BeLike "*Password of account 'work' stored*" -Because 'Set-MailAccount stops, rather than report the password stored'
            (Get-MailAccount work -WarningAction SilentlyContinue).PasswordSource | Should -Be 'Missing'
        } finally {
            [IO.File]::SetUnixFileMode($folder.FullName, 'UserRead, UserWrite, UserExecute')
            Remove-Item -LiteralPath $folder.FullName -Recurse -Force
        }
    }

    # In a folder where it cannot be deleted (so not as root). It is deleted by .NET, as a credential of Windows is,
    # so this checks the stop that the Credential Manager relies on too.
    It 'is reported when it cannot be deleted, and its account kept' -Skip:$isRoot {
        Set-MailAccount -Name work -Password $password
        [IO.File]::SetUnixFileMode($secrets, 'UserRead, UserExecute')
        try {
            $null = Invoke-AsUserScript { Remove-MailAccount work }
        } finally {
            [IO.File]::SetUnixFileMode($secrets, 'UserRead, UserWrite, UserExecute')
        }

        (Get-MailAccount).Name | Should -Be 'work' -Because 'Remove-MailAccount stops before it removes the account whose password stays'
        Join-Path $secrets 'work' | Should -Exist
        Remove-MailAccount work
        Join-Path $secrets 'work' | Should -Not -Exist
    }
}

# The settings hold no password, but servers and users: a file the user made owner-only stays so
Describe 'The mode of the accounts file' -Skip:$IsWindows {
    It 'is kept when the file is written, and the new file has it before anything is written to it' {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "work": { "Server": "smtp.example.com", "User": "me@example.com" } } }'
        $ownerOnly = [IO.UnixFileMode]'UserRead, UserWrite'
        [IO.File]::SetUnixFileMode($accountsFile, $ownerOnly)
        # The mode of the new file when its settings are written to it
        $seen = @{}
        Mock -ModuleName ElektoMailPosh Set-Content {
            $seen.Mode = if (Test-Path -LiteralPath $LiteralPath) { [IO.File]::GetUnixFileMode($LiteralPath) } else { 'not created yet' }
            [IO.File]::WriteAllText($LiteralPath, "$Value")
        }

        Set-MailAccount -Name work -Port 2525

        $seen.Mode | Should -Be $ownerOnly
        [IO.File]::GetUnixFileMode($accountsFile) | Should -Be $ownerOnly
        (Get-MailAccount work).Port | Should -Be 2525
    }
}

# accounts.json kept in a dotfiles repository and linked into the configuration folder, as GNU stow does. A link on
# Windows needs a privilege, so not there.
Describe 'An accounts file that is a link' -Skip:$IsWindows {
    It 'stays a link, and the file it points to gets the change' {
        $dotfiles = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'dotfiles') -Force
        $real = Join-Path $dotfiles.FullName 'accounts.json'
        Set-Content -Path $real -Value '{ "Accounts": { "work": { "Server": "smtp.example.com", "User": "me@example.com" } } }'
        Remove-Item -LiteralPath $accountsFile -Force -ErrorAction Ignore
        New-Item -ItemType SymbolicLink -Path $accountsFile -Target $real | Out-Null
        try {
            Set-MailAccount -Name work -Port 2525

            (Get-Item -LiteralPath $accountsFile).LinkTarget | Should -Be $real
            (Get-Content -Path $real -Raw | ConvertFrom-Json -AsHashtable).Accounts.work.Port | Should -Be 2525
            @(Get-ChildItem -Path $env:SMTP_CONFIG_DIR, $dotfiles.FullName -Filter '*.tmp') | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $accountsFile -Force
        }
    }
}
