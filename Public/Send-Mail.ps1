<#
.SYNOPSIS
Sends emails using an SMTP server.

.DESCRIPTION
The `Send-Mail` function sends emails with HTML support, configured via environment variables
or explicit parameters. Ideal for automation scripts, CI/CD pipelines, and scheduled tasks.

.PARAMETER Subject
The email subject. This parameter is required.

.PARAMETER Body
The email body content. This parameter is required.

.PARAMETER IsHtml
Indicates whether the body is HTML formatted. Default is $False.

.PARAMETER FromName
The sender display name. If not provided, uses the machine name.

.PARAMETER To
The recipient email address. If not provided, uses the SMTP_TO environment variable.

.PARAMETER Attachments
Array of file paths to attach to the email. Files must exist on the filesystem.

.NOTES
SMTP credentials and settings must be defined via environment variables:
- SMTP_USER (required)
- SMTP_PASS (required)
- SMTP_SERVER (optional, default: smtp.gmail.com)
- SMTP_PORT (optional, default: 587)
- SMTP_FROM (optional, default: SMTP_USER)

.EXAMPLE
Send-Mail -Subject "Test" -Body "Test content" -FromName "MyApp" -To "recipient@example.com"

Sends a simple email to the recipient.

.EXAMPLE
Send-Mail -Subject "Alert" -Body "<h1>Alert</h1><p>Check the logs.</p>" -IsHtml $true

Sends an HTML formatted email with subject "Alert".

.EXAMPLE
Send-Mail -Subject "Report" -Body "Please find the report attached." -To "recipient@example.com" -Attachments @("./report.pdf", "./data.xlsx")

Sends an email with two file attachments.
#>
Function Send-Mail {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$Subject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$Body,

        [bool]$IsHtml = $False,
        [string]$FromName = $null,
        [string]$To = $null,
        [string[]]$Attachments = @()
    )

    # Load environment configuration
    Write-Debug "Call: Subject='$Subject', Body='$Body', IsHtml='$IsHtml', FromName='$FromName', To='$To'."
    Write-Debug "Environment: SMTP_SERVER='$env:SMTP_SERVER', SMTP_PORT='$env:SMTP_PORT', SMTP_FROM='$env:SMTP_FROM', SMTP_TO='$env:SMTP_TO', SMTP_USER='$env:SMTP_USER', SMTP_PASS='$(if($env:SMTP_PASS){"[SET]"}else{"[NOT SET]"})'"

    $smtpUser = $env:SMTP_USER
    $smtpPass = $env:SMTP_PASS

    if (-not $smtpUser -or -not $smtpPass) {
        Write-Error "Environment variables SMTP_USER and/or SMTP_PASS are not configured."
        return
    }

    $smtpServer = if ($env:SMTP_SERVER) { $env:SMTP_SERVER } else { "smtp.gmail.com" }
    $smtpPort = if ($env:SMTP_PORT) { $env:SMTP_PORT } else { 587 }
    $smtpFrom = if ($env:SMTP_FROM) { $env:SMTP_FROM } else { $smtpUser }
    if ([string]::IsNullOrWhiteSpace($FromName)) { $FromName = $env:COMPUTERNAME }

    # Optional To parameter - PowerShell converts null strings to "" automatically
    if ([string]::IsNullOrWhiteSpace($To)) { $To = $env:SMTP_TO }
    if ([string]::IsNullOrWhiteSpace($To)) {
        Write-Error "The 'To' parameter is required, either in the function call or via the SMTP_TO environment variable."
        return
    }

    Write-Debug "Configuration: SMTP_SERVER='$smtpServer', SMTP_PORT='$smtpPort', SMTP_FROM='$smtpFrom', SMTP_USER='$smtpUser', TO='$To'."
    Write-Verbose "Sending email to '$To' with subject '$Subject'..."

    # SMTP client configuration
    $smtpClient = New-Object Net.Mail.SmtpClient($smtpServer, $smtpPort)
    $smtpClient.EnableSsl = $true
    $smtpClient.Credentials = New-Object System.Net.NetworkCredential($smtpUser, $smtpPass)

    # Email message creation
    $mailMessage = New-Object Net.Mail.MailMessage
    $mailMessage.From = "$FromName <$smtpFrom>"
    $mailMessage.To.Add($To)
    $mailMessage.Subject = $Subject
    $mailMessage.Body = $Body
    $mailMessage.IsBodyHtml = $IsHtml
    $mailMessage.Headers.Add("X-Mailer", "ElektoMailPosh/0.2.0")

    # Validate and add attachments
    foreach ($attachmentPath in $Attachments) {
        if (-not (Test-Path -Path $attachmentPath -PathType Leaf)) {
            # Clean up resources before exit (Dispose releases already added attachments)
            $mailMessage.Dispose()
            $smtpClient.Dispose()
            Write-Error "Attachment file not found: '$attachmentPath'"
            return
        }
        $fullPath = (Resolve-Path -Path $attachmentPath).Path
        $attachment = New-Object System.Net.Mail.Attachment($fullPath)
        $mailMessage.Attachments.Add($attachment)
        Write-Verbose "Attachment added: $fullPath"
    }

    # Send email with retry and exponential backoff
    $maxRetries = 5
    $retryCount = 0
    $delay = 1

    try {
        while ($retryCount -lt $maxRetries) {
            try {
                $smtpClient.Send($mailMessage)
                Write-Verbose "Email sent successfully."
                return
            } catch {
                $retryCount++
                if ($retryCount -ge $maxRetries) {
                    Write-Error "Failed to send email after $maxRetries attempts: $_"
                    return
                }
                Write-Warning "Failed to send email: $_. Retrying in $delay seconds..."
                Start-Sleep -Seconds $delay
                $delay *= 2
            }
        }
    } finally {
        # Release resources (MailMessage.Dispose() also releases Attachments)
        $mailMessage.Dispose()
        $smtpClient.Dispose()
    }
}
