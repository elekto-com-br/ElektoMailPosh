<#
.SYNOPSIS
Sends emails using an SMTP server.

.DESCRIPTION
The `Send-Mail` function sends emails with HTML support, configured via environment variables
or explicit parameters. Ideal for automation scripts, CI/CD pipelines, and scheduled tasks.

.PARAMETER Subject
The email subject. This parameter is required.

.PARAMETER Body
The email body content. This parameter is required. It can also come from the pipeline:
piped lines (e.g. from Get-Content) are joined into a single body and sent as one email.

.PARAMETER IsHtml
Indicates whether the body is HTML formatted. Default is $False.

.PARAMETER FromName
The sender display name. If not provided, uses the SMTP_FROM_NAME environment variable
or, failing that, the machine name ([Environment]::MachineName).

.PARAMETER To
One or more recipient email addresses. If not provided, uses the SMTP_TO environment variable.
Each entry may also be a comma-separated list of addresses.

.PARAMETER Cc
One or more carbon copy addresses. If not provided, uses the SMTP_CC environment variable.

.PARAMETER Bcc
One or more blind carbon copy addresses. If not provided, uses the SMTP_BCC environment variable.

.PARAMETER Priority
The email priority: Low, Normal or High. Default is Normal.

.PARAMETER Attachments
Array of file paths to attach to the email. Files must exist on the filesystem.

.NOTES
SMTP credentials and settings must be defined via environment variables:
- SMTP_USER (required)
- SMTP_PASS (required)
- SMTP_SERVER (optional, default: smtp.gmail.com)
- SMTP_PORT (optional, default: 587)
- SMTP_FROM (optional, default: SMTP_USER)
- SMTP_FROM_NAME (optional, default: machine name)
- SMTP_TO, SMTP_CC, SMTP_BCC (optional, comma-separated lists)

.EXAMPLE
Send-Mail -Subject "Test" -Body "Test content" -FromName "MyApp" -To "recipient@example.com"

Sends a simple email to the recipient.

.EXAMPLE
Send-Mail -Subject "Alert" -Body "<h1>Alert</h1><p>Check the logs.</p>" -IsHtml $true -Priority High

Sends a high priority HTML formatted email with subject "Alert".

.EXAMPLE
Send-Mail -Subject "Report" -Body "Please find the report attached." -To "recipient@example.com" -Attachments @("./report.pdf", "./data.xlsx")

Sends an email with two file attachments.

.EXAMPLE
Send-Mail -Subject "Status" -Body "All good." -To "a@example.com", "b@example.com" -Cc "c@example.com" -Bcc "audit@example.com"

Sends an email to two recipients, with a carbon copy and a blind carbon copy.

.EXAMPLE
Get-Content ./build.log | Send-Mail -Subject "Build failed" -To "team@example.com"

Sends the contents of a log file as the email body.
#>
Function Send-Mail {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$Subject,

        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [AllowEmptyString()]
        [string]$Body,

        [bool]$IsHtml = $False,
        [string]$FromName = $null,
        [string[]]$To = @(),
        [string[]]$Cc = @(),
        [string[]]$Bcc = @(),

        [ValidateSet('Low', 'Normal', 'High')]
        [string]$Priority = 'Normal',

        [string[]]$Attachments = @()
    )

    begin {
        # Piped lines are collected here and sent as a single email in the end block
        $bodyLines = New-Object System.Collections.Generic.List[string]

        # Returns the non-blank addresses given, or the comma-separated list in the environment variable
        function Get-AddressList([string[]]$Addresses, [string]$EnvValue) {
            $list = @($Addresses | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($list.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($EnvValue)) { $list = @($EnvValue) }
            return ,$list
        }
    }

    process {
        $bodyLines.Add($Body)
    }

    end {
        $Body = $bodyLines -join [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($Body)) {
            Write-Error "The 'Body' parameter is empty."
            return
        }

        # Load environment configuration
        Write-Debug "Call: Subject='$Subject', Body='$Body', IsHtml='$IsHtml', FromName='$FromName', To='$To', Cc='$Cc', Bcc='$Bcc', Priority='$Priority'."
        Write-Debug "Environment: SMTP_SERVER='$env:SMTP_SERVER', SMTP_PORT='$env:SMTP_PORT', SMTP_FROM='$env:SMTP_FROM', SMTP_FROM_NAME='$env:SMTP_FROM_NAME', SMTP_TO='$env:SMTP_TO', SMTP_CC='$env:SMTP_CC', SMTP_BCC='$env:SMTP_BCC', SMTP_USER='$env:SMTP_USER', SMTP_PASS='$(if($env:SMTP_PASS){"[SET]"}else{"[NOT SET]"})'"

        $smtpUser = $env:SMTP_USER
        $smtpPass = $env:SMTP_PASS

        if (-not $smtpUser -or -not $smtpPass) {
            Write-Error "Environment variables SMTP_USER and/or SMTP_PASS are not configured."
            return
        }

        $smtpServer = if ($env:SMTP_SERVER) { $env:SMTP_SERVER } else { "smtp.gmail.com" }
        $smtpPort = if ($env:SMTP_PORT) { $env:SMTP_PORT } else { 587 }
        $smtpFrom = if ($env:SMTP_FROM) { $env:SMTP_FROM } else { $smtpUser }
        if ([string]::IsNullOrWhiteSpace($FromName)) { $FromName = $env:SMTP_FROM_NAME }
        if ([string]::IsNullOrWhiteSpace($FromName)) { $FromName = [Environment]::MachineName }

        $To = Get-AddressList $To $env:SMTP_TO
        $Cc = Get-AddressList $Cc $env:SMTP_CC
        $Bcc = Get-AddressList $Bcc $env:SMTP_BCC
        if ($To.Count -eq 0) {
            Write-Error "The 'To' parameter is required, either in the function call or via the SMTP_TO environment variable."
            return
        }

        Write-Debug "Configuration: SMTP_SERVER='$smtpServer', SMTP_PORT='$smtpPort', SMTP_FROM='$smtpFrom', FROM_NAME='$FromName', SMTP_USER='$smtpUser', TO='$To', CC='$Cc', BCC='$Bcc'."
        Write-Verbose "Sending email to '$($To -join ', ')' with subject '$Subject'..."

        # SMTP client configuration
        $smtpClient = New-Object Net.Mail.SmtpClient($smtpServer, $smtpPort)
        $smtpClient.EnableSsl = $true
        $smtpClient.Credentials = New-Object System.Net.NetworkCredential($smtpUser, $smtpPass)

        # Email message creation (Add accepts a single address or a comma-separated list)
        $mailMessage = New-Object Net.Mail.MailMessage
        $mailMessage.From = "$FromName <$smtpFrom>"
        foreach ($address in $To) { $mailMessage.To.Add($address) }
        foreach ($address in $Cc) { $mailMessage.CC.Add($address) }
        foreach ($address in $Bcc) { $mailMessage.Bcc.Add($address) }
        $mailMessage.Subject = $Subject
        $mailMessage.Body = $Body
        $mailMessage.IsBodyHtml = $IsHtml
        $mailMessage.Priority = [System.Net.Mail.MailPriority]$Priority
        $mailMessage.Headers.Add("X-Mailer", "ElektoMailPosh/$($MyInvocation.MyCommand.Module.Version)")

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
}
