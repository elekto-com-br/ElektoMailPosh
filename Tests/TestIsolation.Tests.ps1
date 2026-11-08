# The isolation of the tests from the accounts of whoever runs them (Tests/TestIsolation.ps1): every test file that
# imports the module enters it; it clears the variables and puts them back; it replaces the password store where it
# should; and a process of its own refuses accounts outside the test drive, and is reported when it does not start.

# PSScriptAnalyzer does not see that Pester gives AfterAll and the tests the variables of BeforeAll
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables of BeforeAll are used by AfterAll and the tests')]
param ()

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestIsolation.ps1')
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'ElektoMailPosh.psd1') -Force
    $isolation = Enter-TestIsolation
}

AfterAll {
    Exit-TestIsolation $isolation
    Remove-Module ElektoMailPosh -ErrorAction SilentlyContinue
}

Describe 'The isolation of the tests' {
    # A test file that ran the commands of the module without it would reach the accounts of the machine
    It 'is entered and left by every test file that imports the module' {
        $commandsOf = {
            param($File)
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($File.FullName, [ref]$null, [ref]$null)
            @($ast.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        }
        $files = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' | Where-Object { (& $commandsOf $_) -contains 'Import-Module' })
        $files.Count | Should -BeGreaterThan 3

        foreach ($file in $files) {
            $commands = & $commandsOf $file
            $commands | Should -Contain 'Enter-TestIsolation' -Because "$($file.Name) imports the module"
            $commands | Should -Contain 'Exit-TestIsolation' -Because "$($file.Name) imports the module"
        }
    }

    It 'clears every SMTP_* variable, and keeps the accounts in the test drive' {
        @(Get-ChildItem -Path env: | Where-Object Name -Like 'SMTP_*' | ForEach-Object Name) | Should -Be 'SMTP_CONFIG_DIR'
        Test-InFolder $env:SMTP_CONFIG_DIR $TestDrive | Should -BeTrue
        Test-InFolder (InModuleScope ElektoMailPosh { Get-AccountDirectory }) $TestDrive | Should -BeTrue
    }

    It 'puts back the variables it put aside, and clears those the tests set' {
        $env:SMTP_PASS_PUT_ASIDE = 'kept'
        try {
            $inner = Enter-TestIsolation
            $env:SMTP_PASS_PUT_ASIDE | Should -BeNullOrEmpty
            $env:SMTP_PASS_SET_BY_A_TEST = 'set'
            Exit-TestIsolation $inner

            $env:SMTP_PASS_PUT_ASIDE | Should -Be 'kept'
            $env:SMTP_PASS_SET_BY_A_TEST | Should -BeNullOrEmpty
        } finally {
            $env:SMTP_PASS_PUT_ASIDE = $null
        }
    }

    # On Windows the passwords go to the Credential Manager of the user, whatever the folder of the accounts
    It 'replaces the password store as it does on Windows, so that no password is stored' {
        Disable-PasswordStore
        Set-MailAccount -Name store -Server smtp.example.com -User me@example.com -Password ([Net.NetworkCredential]::new('', 'not-a-password').SecurePassword)

        Join-Path $env:SMTP_CONFIG_DIR 'secrets/store' | Should -Not -Exist
        (Get-MailAccount store -WarningAction SilentlyContinue).PasswordSource | Should -Be 'Missing'
        Should -Invoke -ModuleName ElektoMailPosh Save-StoredPassword -Times 1 -Exactly
    }
}

Describe 'A process of its own' {
    It 'refuses to start when its accounts would be outside the test drive' {
        foreach ($config in '', (Join-Path ([IO.Path]::GetTempPath()) 'elsewhere'), "$TestDrive-beside", (Split-Path $TestDrive)) {
            { Invoke-AsUserScript -Config $config { 'never runs' } } | Should -Throw '*must be in a folder of the test drive*' -Because "'$config' is not in the test drive"
        }
    }

    # It would otherwise pass for one in which the command did nothing
    It 'is reported when it fails before its script runs' {
        { Invoke-AsUserScript -Manifest (Join-Path $TestDrive 'missing.psd1') { 'never runs' } } | Should -Throw '*did not start as it should*'
    }

    It 'runs the script with the module, its accounts in the test drive' {
        $output = @(Invoke-AsUserScript { param($Module) & $Module { Get-AccountDirectory }; 'done' })

        $output.Count | Should -Be 2
        Test-InFolder $output[0] $TestDrive | Should -BeTrue
        $output[1] | Should -Be 'done'
    }

    # The password files of Linux and macOS are in the test drive, and the tests of a password file that fails need them
    It 'keeps the password store on Linux and macOS, where it is in the test drive' -Skip:$IsWindows {
        $null = Invoke-AsUserScript {
            Set-MailAccount -Name kept -Server smtp.example.com -User me@example.com -Password ([Net.NetworkCredential]::new('', 'not-a-password').SecurePassword)
        }

        Join-Path $env:SMTP_CONFIG_DIR 'secrets/kept' | Should -Exist
    }

    It 'replaces the password store as it does on Windows, so that no password is stored' {
        $null = Invoke-AsUserScript -ReplaceStore {
            Set-MailAccount -Name child -Server smtp.example.com -User me@example.com -Password ([Net.NetworkCredential]::new('', 'not-a-password').SecurePassword)
        }

        (Get-Content -Path (Join-Path $env:SMTP_CONFIG_DIR 'accounts.json') -Raw | ConvertFrom-Json -AsHashtable).Accounts.Keys | Should -Contain 'child'
        Join-Path $env:SMTP_CONFIG_DIR 'secrets/child' | Should -Not -Exist
    }
}
