# ElektoMailPosh

[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/ElektoMailPosh)](https://www.powershellgallery.com/packages/ElektoMailPosh)
[![PowerShell Gallery Downloads](https://img.shields.io/powershellgallery/dt/ElektoMailPosh)](https://www.powershellgallery.com/packages/ElektoMailPosh)
[![License](https://img.shields.io/github/license/elekto-com-br/ElektoMailPosh)](LICENSE)

A lightweight PowerShell module for sending emails via SMTP. **Zero dependencies**, environment-based configuration, and automatic retry with exponential backoff. Perfect for CI/CD pipelines, automation scripts, and scheduled tasks.

## Why ElektoMailPosh?

- **Simple**: One function, minimal parameters, sensible defaults
- **CI/CD Ready**: Configuration via environment variables (no secrets in code)
- **Reliable**: Automatic retry with exponential backoff on transient failures
- **Lightweight**: No external dependencies, just PowerShell 5.1+
- **Cross-Platform**: Works on Windows, macOS, and Linux

## Installation

### From PowerShell Gallery (Recommended)

```powershell
Install-Module -Name ElektoMailPosh
```

### From Source

```powershell
git clone https://github.com/elekto-com-br/ElektoMailPosh.git
Import-Module ./ElektoMailPosh/ElektoMailPosh.psd1
```

## Configuration

Set SMTP credentials via environment variables. This keeps secrets out of your scripts and works seamlessly with CI/CD secret management.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `SMTP_USER` | Yes | - | SMTP authentication username |
| `SMTP_PASS` | Yes | - | SMTP authentication password |
| `SMTP_SERVER` | No | `smtp.gmail.com` | SMTP server address |
| `SMTP_PORT` | No | `587` | SMTP server port |
| `SMTP_FROM` | No | `SMTP_USER` | Sender email address |
| `SMTP_TO` | No | - | Default recipient (fallback) |

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

### Using Environment Defaults

```powershell
# When SMTP_TO is set, you can omit -To
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
| `-Body` | String | Yes | - | Email body (plain text or HTML) |
| `-To` | String | No | `$env:SMTP_TO` | Recipient email address |
| `-IsHtml` | Bool | No | `$false` | Set to `$true` for HTML body |
| `-FromName` | String | No | Machine name | Sender display name |
| `-Attachments` | String[] | No | `@()` | Array of file paths to attach |

## Troubleshooting

Use `-Verbose` for progress information and `-Debug` for detailed diagnostics:

```powershell
Send-Mail -Subject "Test" -Body "Debug test" -To "test@example.com" -Verbose -Debug
```

## License

MIT License - see [LICENSE](LICENSE) for details.

## Author

**JP Negri** - [Elekto Produtos Financeiros](https://github.com/elekto-com-br)
