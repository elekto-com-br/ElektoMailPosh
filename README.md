# ElektoMailPosh

ElektoMailPosh is a lightweight PowerShell module that sends emails through an SMTP server. It focuses on quick setup so you can deliver plain text or HTML messages with minimal ceremony.

## Prerequisites
- PowerShell 7+ (works on Windows, macOS, and Linux)
- Network access to your SMTP provider

## Installation
1. Clone the repository or download the source files.
2. Import the module from the project root:
   ```powershell
   Import-Module ./ElektoMailPosh.psm1
   ```
3. Confirm the command is available:
   ```powershell
   Get-Command Send-Mail
   ```

## Configuration
Provide SMTP credentials through environment variables so you do not need to pass secrets directly in scripts:
- `SMTP_USER` (required)
- `SMTP_PASS` (required)
- `SMTP_SERVER` (optional, default: `smtp.gmail.com`)
- `SMTP_PORT` (optional, default: `587`)
- `SMTP_FROM` (optional, default: value of `SMTP_USER`)
- `SMTP_TO` (optional fallback recipient when `-To` is omitted)

## Usage
Call `Send-Mail` with the subject and body. The command supports both plain text and HTML bodies and retries delivery automatically on transient failures.

### Send a simple message
```powershell
Send-Mail -Subject "Hello" -Body "This is a test message" -To "recipient@example.com"
```

### Send an HTML message with a custom sender name
```powershell
Send-Mail -Subject "Alert" -Body "<h1>Alert</h1><p>Check the logs.</p>" -IsHtml $true -FromName "Monitoring" -To "recipient@example.com"
```

### Rely on environment defaults for the recipient
```powershell
# When SMTP_TO is set, you can omit -To
Send-Mail -Subject "Deployment" -Body "The deployment finished successfully."
```

Use `-Verbose` to see high-level progress and `-Debug` for detailed diagnostics, including the resolved SMTP configuration.
