<#
.SYNOPSIS
Lists the accounts Send-Mail can send from.

.DESCRIPTION
The `Get-MailAccount` function returns the accounts kept by Set-MailAccount, with their settings
and where the password of each one comes from (never the password itself):
- Environment: the SMTP_PASS_<ACCOUNT> environment variable
- CredentialManager: the Windows Credential Manager
- File: a file readable only by its owner (Linux and macOS)
- Missing: no password, so Send-Mail cannot use the account yet

The accounts are kept in accounts.json, in the folder ElektoMailPosh of the user's configuration
folder (%APPDATA% on Windows, ~/.config elsewhere), or in the folder named by SMTP_CONFIG_DIR.

.PARAMETER Name
The name of the account, or a wildcard pattern. If not provided, lists all accounts.

.EXAMPLE
Get-MailAccount

Lists all accounts, marking the default one.

.EXAMPLE
Get-MailAccount work | Format-List

Shows the settings of the account "work".
#>
Function Get-MailAccount {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0)]
        [SupportsWildcards()]
        [string]$Name = '*'
    )

    $file = Read-AccountFile
    if (-not $file) {
        Write-Verbose "There is no accounts file at '$(Get-AccountFilePath)'."
    }

    $names = @(if ($file) { $file.Accounts.psbase.Keys | Where-Object { $_ -like $Name } })
    if ($names.Count -eq 0 -and -not [WildcardPattern]::ContainsWildcardCharacters($Name)) {
        Write-Error "There is no account '$Name'."
        return
    }

    foreach ($accountName in $names) {
        $account = $file.Accounts[$accountName]
        try {
            $password = Get-AccountPassword $accountName
            $passwordSource = if ($password) { $password.Source } else { 'Missing' }
        } catch {
            Write-Warning $_.Exception.Message
            $passwordSource = 'Unusable'
        }

        [PSCustomObject]@{
            Name           = $accountName
            Default        = $accountName -eq $file.Default
            Server         = $account.Server
            Port           = if ($account.Port) { $account.Port } else { $script:DefaultPort }
            User           = $account.User
            From           = if ($account.From) { $account.From } else { $account.User }
            FromName       = $account.FromName
            To             = $account.To
            Cc             = $account.Cc
            Bcc            = $account.Bcc
            ReplyTo        = $account.ReplyTo
            PasswordSource = $passwordSource
        }
    }
}
