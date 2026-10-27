# ElektoMailPosh

[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/ElektoMailPosh)](https://www.powershellgallery.com/packages/ElektoMailPosh)
[![PowerShell Gallery Downloads](https://img.shields.io/powershellgallery/dt/ElektoMailPosh)](https://www.powershellgallery.com/packages/ElektoMailPosh)
[![License](https://img.shields.io/github/license/elekto-com-br/ElektoMailPosh)](LICENSE)

A lightweight PowerShell module for sending emails via SMTP. **Zero dependencies**, several sending accounts on the same machine (like msmtp) or environment-based configuration, and automatic retry with exponential backoff. Perfect for CI/CD pipelines, automation scripts, and scheduled tasks.

## Why ElektoMailPosh?

- **Simple**: One function to send, minimal parameters, sensible defaults
- **Several accounts**: Send from your work mailbox, your personal one or an automation account, each with its own server, user and sender
- **No secrets in code**: Passwords in the Windows Credential Manager, in a file only you can read, or in environment variables
- **CI/CD Ready**: Configuration via environment variables
- **Reliable**: Automatic retry with exponential backoff on transient failures
- **Lightweight**: No external dependencies, just PowerShell 7.4+
- **Cross-Platform**: Works on Windows, macOS, and Linux

## Installation

Requires PowerShell 7.4 or later. Version 1.x still runs on Windows PowerShell 5.1.

### From PowerShell Gallery (Recommended)

```powershell
Install-Module -Name ElektoMailPosh
```

### From a Release (No Gallery Access)

Each version has a [release](https://github.com/elekto-com-br/ElektoMailPosh/releases) with the package as `ElektoMailPosh-<version>.zip`: extract it into a folder listed in `$env:PSModulePath`.

### From Source

```powershell
git clone https://github.com/elekto-com-br/ElektoMailPosh.git
Import-Module ./ElektoMailPosh/ElektoMailPosh.psd1
```

## Configuration

There are two ways to configure the SMTP settings:

- **Accounts**: named sets of settings, like the accounts of msmtp, for machines that send from more than one mailbox. Best for workstations and servers.
- **Environment variables**: one set of settings, for CI/CD pipelines, containers and machines that send from a single account.

When an account is in use (given with `-Account`, or the default account), the `SMTP_*` environment variables are ignored.

### Accounts

Create an account with `Set-MailAccount`, which asks for the password without showing it:

```powershell
Set-MailAccount -Name work -Server smtp.office365.com -User me@example.com -FromName "My Name" -Password (Read-Host -AsSecureString 'Password')
Set-MailAccount -Name personal -Server smtp.gmail.com -User me@gmail.com -FromName "My Name" -Password (Read-Host -AsSecureString 'Password')
Set-MailAccount -Name automation -Server smtp.gmail.com -User robot@gmail.com -FromName "Automation" -To ops@example.com -Default
```

Then send from one of them with `-Account`, or from the default account without it (`-Account` completes the names with Tab):

```powershell
Send-Mail -Account work -Subject "Maintenance tonight" -Body "..." -To "client@example.com"
Send-Mail -Subject "Backup finished" -Body "..."   # the default account, "automation"
```

`Set-MailAccount` changes only the settings given (an empty value removes one), `Get-MailAccount` lists the accounts and where each password comes from, and `Remove-MailAccount` removes accounts and their stored passwords. Both take wildcards, and `Get-MailAccount test* | Remove-MailAccount -WhatIf` shows what would be removed.

| Setting | Required | Default | Description |
|---------|----------|---------|-------------|
| `Server` | Yes | - | SMTP server address |
| `Port` | No | `587` | SMTP server port |
| `User` | Yes | - | SMTP authentication username |
| `From` | No | `User` | Sender email address |
| `FromName` | No | Machine name | Sender display name |
| `To`, `Cc`, `Bcc`, `ReplyTo` | No | - | Default addresses, when `Send-Mail` gets none |

The settings are kept in `accounts.json`, in the folder `ElektoMailPosh` of your configuration folder (`%APPDATA%` on Windows, `~/.config` on Linux and macOS), or in the folder named by `SMTP_CONFIG_DIR`. It holds no passwords, so it can be read and edited by hand:

```json
{
  "Default": "automation",
  "Accounts": {
    "work": { "Server": "smtp.office365.com", "Port": 587, "User": "me@example.com", "FromName": "My Name" },
    "automation": { "Server": "smtp.gmail.com", "User": "robot@gmail.com", "FromName": "Automation", "To": "ops@example.com" }
  }
}
```

The file is read ignoring case, as PowerShell reads names: keys and settings can be written in any case, and `Send-Mail -Account WORK` sends from the account `work`. So two accounts whose names differ only in case are refused, since they would be the same account and share its password.

#### Where the passwords go

| Platform | Store | Protection |
|----------|-------|------------|
| Windows | Credential Manager, generic credential `ElektoMailPosh:<account>` | Encrypted with your logon (DPAPI), like any password Windows remembers |
| Linux, macOS | File `secrets/<account>` next to `accounts.json` | Readable only by you (mode 600, folder 700), as with msmtp, ssh or `.pgpass`; a file others can read is refused |

On any platform, the environment variable `SMTP_PASS_<ACCOUNT>` (the account name in upper case, other characters than letters and digits as `_`, e.g. `SMTP_PASS_WORK`) takes precedence over the stored password, for pipelines and services that get their secrets from the environment.

On Windows the credential can also be stored or seen with the system tools: `cmdkey /generic:ElektoMailPosh:work /user:me@example.com /pass` asks for the password, and the credentials appear in Control Panel > Credential Manager > Windows Credentials.

#### Upgrading from 1.x

Updating the module is all it takes (`Update-PSResource ElektoMailPosh`, or `Update-Module ElektoMailPosh`): with no default account, `Send-Mail` reads the `SMTP_*` environment variables as before. CI/CD pipelines, containers and machines that send from a single account need nothing else.

A second mailbox doesn't require moving the first one either: an account created without `-Default` is used only with `-Account`, and `Send-Mail` without it keeps reading the variables.

To move the configuration to an account anyway, `-FromEnvironment` copies the `SMTP_*` variables, password included:

```powershell
Set-MailAccount -Name automation -FromEnvironment -Default
```

From then on `Send-Mail` uses that account and ignores the variables, so remove them, above all `SMTP_PASS`. On Windows:

```powershell
foreach ($name in 'SMTP_SERVER', 'SMTP_PORT', 'SMTP_USER', 'SMTP_PASS', 'SMTP_FROM', 'SMTP_FROM_NAME', 'SMTP_TO', 'SMTP_CC', 'SMTP_BCC') {
    [Environment]::SetEnvironmentVariable($name, $null, 'User')   # 'Machine', from an elevated shell, for variables set for the whole machine
}
```

On Linux and macOS, remove them from wherever they are set (shell profile, PowerShell profile, systemd unit).

To go back to the variables, take the default away from the account (`Set-MailAccount automation -Default:$false`), or remove every account and its stored password with `Remove-MailAccount *`. Set the `SMTP_*` variables again if they were removed.

> [!WARNING]
> **Scheduled tasks and services:** check how they run before moving them to an account. Accounts and their passwords belong to the user who created them, so a task or service that runs as another user (SYSTEM, a service account, root) doesn't see them. On Windows, a scheduled task set to run whether the user is logged on or not with *Do not store password* (logon type S4U) runs as you but can't read the Credential Manager, which needs your logon password to decrypt. Senders like these should stay on the `SMTP_*` variables: don't make an account the default, and leave the variables where the task reads them (often at machine level).

### Environment Variables

Without accounts, set SMTP credentials via environment variables. This keeps secrets out of your scripts and works seamlessly with CI/CD secret management.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `SMTP_USER` | Yes | - | SMTP authentication username |
| `SMTP_PASS` | Yes | - | SMTP authentication password |
| `SMTP_SERVER` | No | `smtp.gmail.com` | SMTP server address |
| `SMTP_PORT` | No | `587` | SMTP server port |
| `SMTP_FROM` | No | `SMTP_USER` | Sender email address |
| `SMTP_FROM_NAME` | No | Machine name | Sender display name |
| `SMTP_TO` | No | - | Default recipients (comma-separated) |
| `SMTP_CC` | No | - | Default carbon copy recipients (comma-separated) |
| `SMTP_BCC` | No | - | Default blind carbon copy recipients (comma-separated) |
| `SMTP_REPLY_TO` | No | - | Default reply-to addresses (comma-separated) |

### Server Notes

- The connection is always encrypted with STARTTLS (usually port 587). Servers that only offer implicit TLS on port 465 are not supported.
- Gmail and Google Workspace need an [app password](https://myaccount.google.com/apppasswords), and only send as the account itself or as an alias configured under "Send mail as". The message is saved in the Sent folder of the account.

## Usage

### Basic Email

```powershell
Send-Mail -Subject "Hello" -Body "This is a test message" -To "recipient@example.com"
```

### HTML Email

```powershell
Send-Mail -Subject "Alert" -Body "<h1>Alert</h1><p>Check the logs.</p>" -IsHtml $true -To "recipient@example.com"
```

### With Attachments

```powershell
Send-Mail -Subject "Report" -Body "Please find the files attached." -To "recipient@example.com" -Attachments @("./report.pdf", "./data.xlsx")
```

### Multiple Recipients, Cc and Bcc

```powershell
Send-Mail -Subject "Status" -Body "All good." -To "a@example.com", "b@example.com" -Cc "c@example.com" -Bcc "audit@example.com"
```

### Replies to Another Address

Useful for an email to many people, so that the answers go to a team mailbox instead of the sender:

```powershell
Send-Mail -Account work -Subject "Security update" -Body "..." -Bcc $clients -ReplyTo "support@example.com"
```

### Replying in a Thread

Mail clients, Gmail included, show an email in the conversation of another when it has the same subject (with `Re: ` or not) and its `In-Reply-To` names the other's `Message-ID`. Give the first email a `Message-ID` of your own to answer it later, as in an alert followed by its resolution:

```powershell
Send-Mail -Subject "Backup failed on host" -Body "..." -MessageId "<backup-20261026@host.example.com>"
Send-Mail -Subject "Re: Backup failed on host" -Body "Fixed." -InReplyTo "<backup-20261026@host.example.com>"
```

To answer an email deeper in a conversation, pass its `References` header as it is with `-References`; the `-InReplyTo` is added at the end.

### High Priority

```powershell
Send-Mail -Subject "Disk almost full" -Body "Only 2% free on /data." -Priority High
```

### Body from the Pipeline

Piped lines are joined into a single body and sent as one email:

```powershell
Get-Content ./build.log | Send-Mail -Subject "Build failed" -To "team@example.com"
```

### Body from a File

For long messages, the body can come from a file, read as UTF-8. A file ending in `.html` or `.htm` is sent as HTML:

```powershell
Send-Mail -Subject "Monthly report" -BodyFile ./report.html -To "board@example.com" -Attachments ./report.pdf
```

### Using Defaults

```powershell
# When the account has a To (or SMTP_TO is set), you can omit -To; likewise Cc, Bcc, ReplyTo and FromName
Send-Mail -Subject "Deployment Complete" -Body "Build #123 deployed successfully."
```

## CI/CD Integration

### GitHub Actions

```yaml
name: Notify on Release

on:
  release:
    types: [published]

jobs:
  notify:
    runs-on: ubuntu-latest
    steps:
      - name: Send notification email
        shell: pwsh
        env:
          SMTP_USER: ${{ secrets.SMTP_USER }}
          SMTP_PASS: ${{ secrets.SMTP_PASS }}
          SMTP_TO: team@example.com
        run: |
          Install-Module -Name ElektoMailPosh -Force -Scope CurrentUser
          Import-Module ElektoMailPosh
          Send-Mail -Subject "Release ${{ github.event.release.tag_name }}" `
                    -Body "New release published: ${{ github.event.release.html_url }}"
```

### Azure Pipelines

```yaml
trigger:
  - main

pool:
  vmImage: 'windows-latest'

steps:
  - task: PowerShell@2
    displayName: 'Send build notification'
    env:
      SMTP_USER: $(SMTP_USER)
      SMTP_PASS: $(SMTP_PASS)
      SMTP_TO: $(NOTIFICATION_EMAIL)
    inputs:
      targetType: 'inline'
      script: |
        Install-Module -Name ElektoMailPosh -Force -Scope CurrentUser
        Import-Module ElektoMailPosh
        Send-Mail -Subject "Build $(Build.BuildNumber) completed" `
                  -Body "Pipeline: $(Build.DefinitionName)`nStatus: $(Agent.JobStatus)`nCommit: $(Build.SourceVersionMessage)"
```

### GitLab CI

```yaml
notify:
  stage: deploy
  image: mcr.microsoft.com/powershell:latest
  script:
    - pwsh -Command "Install-Module -Name ElektoMailPosh -Force -Scope CurrentUser"
    - pwsh -Command "Import-Module ElektoMailPosh; Send-Mail -Subject 'Pipeline $CI_PIPELINE_ID' -Body 'Deployment completed for $CI_PROJECT_NAME'"
  variables:
    SMTP_USER: $SMTP_USER
    SMTP_PASS: $SMTP_PASS
    SMTP_TO: $NOTIFICATION_EMAIL
```

## Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-Subject` | String | Yes | - | Email subject line |
| `-Body` | String | Yes, or `-BodyFile` | - | Email body (plain text or HTML); accepts pipeline input |
| `-BodyFile` | String | Yes, or `-Body` | - | File whose contents are the body (UTF-8); `.html`/`.htm` is sent as HTML |
| `-Account` | String | No | The default account, then the environment variables | Account to send from |
| `-To` | String[] | No | The account's `To`, or `$env:SMTP_TO` | Recipient email addresses |
| `-Cc` | String[] | No | The account's `Cc`, or `$env:SMTP_CC` | Carbon copy addresses |
| `-Bcc` | String[] | No | The account's `Bcc`, or `$env:SMTP_BCC` | Blind carbon copy addresses |
| `-ReplyTo` | String[] | No | The account's `ReplyTo`, or `$env:SMTP_REPLY_TO` | Addresses replies should go to |
| `-MessageId` | String | No | Assigned by the server | `Message-ID` of this email, to answer it later |
| `-InReplyTo` | String | No | - | `Message-ID` of the email answered, to show this one in its conversation |
| `-References` | String[] | No | The `-InReplyTo` | `Message-ID`s of the conversation, oldest first |
| `-IsHtml` | Bool | No | `$false` (`$true` for an HTML `-BodyFile`) | Set to `$true` for HTML body |
| `-FromName` | String | No | The account's `FromName`, or `$env:SMTP_FROM_NAME`, then machine name | Sender display name |
| `-Priority` | String | No | `Normal` | `Low`, `Normal` or `High` |
| `-Attachments` | String[] | No | `@()` | Array of file paths to attach |

As in 1.x, the parameters `-Subject`, `-Body`, `-IsHtml`, `-FromName`, `-To`, `-Cc`, `-Bcc`, `-Priority` and `-Attachments` may also be given by position, in this order: `Send-Mail $subject $body $true` is `Send-Mail -Subject $subject -Body $body -IsHtml $true`. The others take names only.

## Troubleshooting

Use `-Verbose` for progress information and `-Debug` for detailed diagnostics:

```powershell
Send-Mail -Subject "Test" -Body "Debug test" -To "test@example.com" -Verbose -Debug
```

## License

MIT License - see [LICENSE](LICENSE) for details.

## Author

**JP Negri** - [Elekto Produtos Financeiros](https://github.com/elekto-com-br)
