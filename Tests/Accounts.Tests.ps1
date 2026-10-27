# The accounts file read ignoring case, as the rest of the module and the password stores are: keys and
# settings in any case, accounts found by their name in any case, and two names that differ only in case
# refused, since they would be the same account (and share a password).

BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'ElektoMailPosh.psd1') -Force

    # An empty configuration folder, and the password of the account "work" in the environment, so that
    # no password store is read
    $savedEnvironment = @{}
    foreach ($name in 'SMTP_CONFIG_DIR', 'SMTP_PASS_WORK') {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $env:SMTP_CONFIG_DIR = Join-Path $TestDrive 'config'
    $env:SMTP_PASS_WORK = 'not-a-password'
    New-Item -ItemType Directory -Path $env:SMTP_CONFIG_DIR | Out-Null
    $accountsFile = Join-Path $env:SMTP_CONFIG_DIR 'accounts.json'
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

Describe 'Names in the accounts file that differ only in case' {
    It 'are refused for <Case>' -TestCases @(
        @{ Case = 'two accounts'; Message = "*'Work' and 'work'*differ only in case*"
            Json = '{ "Accounts": { "Work": { "Server": "a.example.com", "User": "a@example.com" }, "work": { "Server": "b.example.com", "User": "b@example.com" } } }' }
        @{ Case = 'a key'; Message = "*key 'Default' is twice*"
            Json = '{ "Default": "work", "default": "work", "Accounts": { "work": { "Server": "smtp.example.com", "User": "me@example.com" } } }' }
        @{ Case = 'a setting'; Message = "*setting 'Server' is twice*"
            Json = '{ "Accounts": { "work": { "Server": "a.example.com", "server": "b.example.com", "User": "me@example.com" } } }' }
    ) {
        Set-Content -Path $accountsFile -Value $Json

        { Get-MailAccount } | Should -Throw -ExpectedMessage $Message
    }
}
