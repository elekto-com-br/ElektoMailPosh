<#
.SYNOPSIS
Creates or changes an account that Send-Mail can send from.

.DESCRIPTION
An account is a named set of SMTP settings, like the accounts of msmtp: each one with its own
server, user, sender and default recipients, so the same machine and user can send from several
mailboxes. `Send-Mail -Account <name>` sends from one of them; the default account is used when
Send-Mail is called without -Account.

The settings are kept in accounts.json, in the folder ElektoMailPosh of the user's configuration
folder (%APPDATA% on Windows, ~/.config elsewhere), or in the folder named by SMTP_CONFIG_DIR.
Passwords are never written there:
- On Windows they go to the Credential Manager, as the generic credential "ElektoMailPosh:<name>",
  encrypted with the user's logon (DPAPI).
- On Linux and macOS they go to the file secrets/<name> in that folder, readable only by its owner.
- On any platform, the environment variable SMTP_PASS_<NAME> (the name in upper case, with any
  character other than letters and digits as "_") takes precedence over the stored password.

Only the settings given are changed. An empty value removes a setting.

.PARAMETER Name
The name of the account: letters, digits, '.', '-' and '_', starting with a letter or digit.

.PARAMETER Server
The SMTP server. Required for a new account (unless it comes from -FromEnvironment).

.PARAMETER Port
The SMTP server port. Default is 587. The connection is always encrypted with STARTTLS.

.PARAMETER User
The SMTP authentication username. Required for a new account (unless it comes from -FromEnvironment).

.PARAMETER From
The sender address. Default is the User. Servers such as Gmail only accept the user's own address
or an alias configured in the mailbox.

.PARAMETER FromName
The sender display name. Default is the machine name.

.PARAMETER To
Default recipients, when Send-Mail is called without -To.

.PARAMETER Cc
Default carbon copy recipients, when Send-Mail is called without -Cc.

.PARAMETER Bcc
Default blind carbon copy recipients, when Send-Mail is called without -Bcc.

.PARAMETER ReplyTo
Default addresses for replies, when Send-Mail is called without -ReplyTo.

.PARAMETER Password
The SMTP password (for Gmail, an app password), stored as described above.

.PARAMETER Default
Makes this the default account. -Default:$false stops it from being the default.

.PARAMETER FromEnvironment
Takes the settings not given as parameters, and the password, from the SMTP_* environment variables
(SMTP_SERVER, SMTP_PORT, SMTP_USER, SMTP_PASS, SMTP_FROM, SMTP_FROM_NAME, SMTP_TO, SMTP_CC, SMTP_BCC
and SMTP_REPLY_TO). This moves an installation configured by environment variables to an account.

.EXAMPLE
Set-MailAccount -Name automation -FromEnvironment -Default

Moves the configuration in the SMTP_* environment variables to the account "automation" and makes it
the default. Send-Mail then ignores those variables, which can be removed.

.EXAMPLE
Set-MailAccount -Name work -Server smtp.office365.com -User me@example.com -FromName "My Name" -Password (Read-Host -AsSecureString 'Password')

Creates the account "work", asking for its password without showing it.

.EXAMPLE
Set-MailAccount -Name work -ReplyTo support@example.com

Makes replies to the email sent from "work" go to support@example.com.
#>
Function Set-MailAccount {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
        [string]$Name,

        [string]$Server,
        [ValidateRange(1, 65535)]
        [int]$Port,
        [string]$User,
        [string]$From,
        [string]$FromName,
        [string[]]$To,
        [string[]]$Cc,
        [string[]]$Bcc,
        [string[]]$ReplyTo,
        [securestring]$Password,
        [switch]$Default,
        [switch]$FromEnvironment
    )

    $file = Read-AccountFile
    $accounts = if ($file) { $file.Accounts } else { [ordered]@{} }
    $defaultName = if ($file) { $file.Default } else { $null }

    # An existing account keeps the spelling of its name
    $existingName = Find-AccountName $file $Name
    if ($existingName) { $Name = $existingName }
    $settings = [ordered]@{}
    if ($existingName) { foreach ($key in $accounts[$Name].Keys) { $settings[$key] = $accounts[$Name][$key] } }

    $secret = $null
    if ($FromEnvironment) {
        $environment = Get-EnvironmentConfiguration
        foreach ($key in $script:AccountSettingNames) {
            if (-not $PSBoundParameters.ContainsKey($key) -and $environment[$key]) { $settings[$key] = $environment[$key] }
        }
        $secret = $environment.Password
    }
    foreach ($key in $script:AccountSettingNames) {
        if (-not $PSBoundParameters.ContainsKey($key)) { continue }
        $value = $PSBoundParameters[$key]
        if ($key -in $script:AddressSettingNames) { $value = ConvertTo-AddressList $value }
        if (@($value).Count -eq 0 -or "$value" -eq '') { $settings.Remove($key) } else { $settings[$key] = $value }
    }
    if ($Password) { $secret = [Net.NetworkCredential]::new('', $Password).Password }

    if (-not $settings.Server -or -not $settings.User) {
        throw "Account '$Name' needs a server and a user: give -Server and -User."
    }

    if ($PSBoundParameters.ContainsKey('Default')) {
        if ($Default) { $defaultName = $Name } elseif ($defaultName -eq $Name) { $defaultName = $null }
    }

    if (-not $PSCmdlet.ShouldProcess("account '$Name' in '$(Get-AccountFilePath)'", 'Save')) { return }

    $accounts[$Name] = $settings
    Write-AccountFile $defaultName $accounts
    Write-Verbose "Account '$Name' saved in '$(Get-AccountFilePath)'."

    if ($secret) {
        Save-StoredPassword $Name $settings.User $secret
        Write-Verbose "Password of account '$Name' stored."
    } elseif (-not (Get-AccountPassword $Name)) {
        Write-Warning (Get-MissingPasswordMessage $Name)
    }

    # While an account is the default, the SMTP_* variables are of no use, and SMTP_PASS should not linger
    if ($defaultName -eq $Name) {
        $variables = @('SMTP_SERVER', 'SMTP_PORT', 'SMTP_USER', 'SMTP_PASS', 'SMTP_FROM', 'SMTP_FROM_NAME', 'SMTP_TO', 'SMTP_CC', 'SMTP_BCC', 'SMTP_REPLY_TO') |
            Where-Object { [Environment]::GetEnvironmentVariable($_) }
        if ($variables) {
            Write-Warning "'$Name' is the default account, so Send-Mail no longer reads $($variables -join ', '). Remove them from the environment, above all SMTP_PASS."
        }
    }
}
