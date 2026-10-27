<#
.SYNOPSIS
Sends emails using an SMTP server.

.DESCRIPTION
The `Send-Mail` function sends emails with HTML support. The SMTP settings come from an account
(see Set-MailAccount) or from environment variables, and parameters override them. Ideal for
automation scripts, CI/CD pipelines, and scheduled tasks.

.PARAMETER Subject
The email subject. This parameter is required.

.PARAMETER Body
The email body content. This parameter or -BodyFile is required. It can also come from the pipeline:
piped lines (e.g. from Get-Content) are joined into a single body and sent as one email.

.PARAMETER BodyFile
The path of a file whose contents are the email body, for long messages. The file is read as UTF-8
(or as the encoding its byte order mark names). A file ending in .html or .htm is sent as HTML,
unless -IsHtml says otherwise.

.PARAMETER IsHtml
Indicates whether the body is HTML formatted. Default is $False, or $True for an .html or .htm -BodyFile.

.PARAMETER Account
The account to send from, one of those kept by Set-MailAccount. If not provided, uses the default
account, if there is one, or else the SMTP_* environment variables. While an account is in use,
the SMTP_* environment variables are ignored.

.PARAMETER FromName
The sender display name. If not provided, uses the FromName of the account (or the SMTP_FROM_NAME
environment variable) or, failing that, the machine name ([Environment]::MachineName).

.PARAMETER To
One or more recipient email addresses. If not provided, uses the To of the account (or the SMTP_TO
environment variable). Each entry may also be a comma-separated list of addresses.

.PARAMETER Cc
One or more carbon copy addresses. If not provided, uses the Cc of the account (or SMTP_CC).

.PARAMETER Bcc
One or more blind carbon copy addresses. If not provided, uses the Bcc of the account (or SMTP_BCC).

.PARAMETER ReplyTo
One or more addresses that replies should go to, instead of the sender. If not provided, uses the
ReplyTo of the account (or SMTP_REPLY_TO).

.PARAMETER MessageId
The Message-ID of this email, such as "<backup-2026-10-26@host.example.com>" (the angle brackets are
added when missing). Give one to answer this email later with -InReplyTo. If not provided, the server
assigns one.

.PARAMETER InReplyTo
The Message-ID of the email this one answers. With it, mail clients (Gmail included) show both in the
same conversation, as long as the subject is the same, "Re: " in front or not. It also goes to the
References header.

.PARAMETER References
The Message-IDs of the conversation, oldest first, for a reply in a longer thread: the References of
the email answered (its header may be passed as it is). The -InReplyTo is added at the end. If not
provided, the References is just the -InReplyTo.

.PARAMETER Priority
The email priority: Low, Normal or High. Default is Normal.

.PARAMETER Attachments
Array of file paths to attach to the email. Files must exist on the filesystem.

.NOTES
Without an account, SMTP credentials and settings come from environment variables:
- SMTP_USER (required)
- SMTP_PASS (required)
- SMTP_SERVER (optional, default: smtp.gmail.com)
- SMTP_PORT (optional, default: 587)
- SMTP_FROM (optional, default: SMTP_USER)
- SMTP_FROM_NAME (optional, default: machine name)
- SMTP_TO, SMTP_CC, SMTP_BCC, SMTP_REPLY_TO (optional, comma-separated lists)

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

.EXAMPLE
Send-Mail -Subject "Monthly report" -BodyFile ./report.html -To "board@example.com" -Attachments ./report.pdf

Sends the HTML in report.html as the email body, with the report attached.

.EXAMPLE
Send-Mail -Account work -Subject "Maintenance tonight" -Body "..." -To "a@example.com", "b@example.com" -ReplyTo "support@example.com"

Sends from the account "work", with replies going to support@example.com instead of the sender.

.EXAMPLE
Send-Mail -Subject "Backup failed on host" -Body "..." -MessageId "<backup-20261026@host.example.com>"
Send-Mail -Subject "Re: Backup failed on host" -Body "Fixed." -InReplyTo "<backup-20261026@host.example.com>"

Sends an alert and, later, a follow-up that mail clients show in the same conversation.
#>
Function Send-Mail {
    [CmdletBinding(DefaultParameterSetName = 'Body')]
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$Subject,

        [Parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Body')]
        [AllowEmptyString()]
        [string]$Body,

        [Parameter(Mandatory=$true, ParameterSetName='BodyFile')]
        [ValidateNotNullOrEmpty()]
        [string]$BodyFile,

        [bool]$IsHtml = $False,
        [string]$Account = $null,
        [string]$FromName = $null,
        [string[]]$To = @(),
        [string[]]$Cc = @(),
        [string[]]$Bcc = @(),
        [string[]]$ReplyTo = @(),
        [string]$MessageId = $null,
        [string]$InReplyTo = $null,
        [string[]]$References = @(),

        [ValidateSet('Low', 'Normal', 'High')]
        [string]$Priority = 'Normal',

        [string[]]$Attachments = @()
    )

    begin {
        # Piped lines are collected here and sent as a single email in the end block
        $bodyLines = New-Object System.Collections.Generic.List[string]

        # Returns the non-blank addresses given, or else those of the account (or environment variable)
        function Get-AddressList([string[]]$Addresses, [string[]]$Defaults) {
            $list = ConvertTo-AddressList $Addresses
            if ($list.Count -eq 0) { $list = ConvertTo-AddressList $Defaults }
            return ,$list
        }

        # A Message-ID in angle brackets (added when missing), or $null when the value is not one
        function ConvertTo-MessageId([string]$Value) {
            $id = $Value.Trim() -replace '^<(.*)>$', '$1'
            if ($id -notmatch '^[^\s<>@]+@[^\s<>@]+$') { return $null }
            return "<$id>"
        }
    }

    process {
        $bodyLines.Add($Body)
    }

    end {
        if ($PSCmdlet.ParameterSetName -eq 'BodyFile') {
            if (-not (Test-Path -LiteralPath $BodyFile -PathType Leaf)) {
                Write-Error "Body file not found: '$BodyFile'"
                return
            }
            $Body = Get-Content -LiteralPath $BodyFile -Raw -Encoding utf8
            if (-not $PSBoundParameters.ContainsKey('IsHtml') -and $BodyFile -match '\.html?$') { $IsHtml = $true }
        } else {
            $Body = $bodyLines -join [Environment]::NewLine
        }
        if ([string]::IsNullOrWhiteSpace($Body)) {
            Write-Error "The email body is empty."
            return
        }

        # Settings of the account (given or default), or else of the SMTP_* environment variables
        Write-Debug "Call: Subject='$Subject', Body='$Body', IsHtml='$IsHtml', Account='$Account', FromName='$FromName', To='$To', Cc='$Cc', Bcc='$Bcc', ReplyTo='$ReplyTo', Priority='$Priority'."
        try {
            $settings = Resolve-MailConfiguration $Account
        } catch {
            Write-Error $_.Exception.Message
            return
        }

        $smtpUser = $settings.User
        $smtpPass = $settings.Password

        if (-not $smtpUser -or -not $smtpPass) {
            Write-Error "Environment variables SMTP_USER and/or SMTP_PASS are not configured, and there is no account to send from (see Set-MailAccount)."
            return
        }

        $smtpServer = $settings.Server
        $smtpPort = $settings.Port
        $smtpFrom = if ($settings.From) { $settings.From } else { $smtpUser }
        if ([string]::IsNullOrWhiteSpace($FromName)) { $FromName = $settings.FromName }
        if ([string]::IsNullOrWhiteSpace($FromName)) { $FromName = [Environment]::MachineName }

        $To = Get-AddressList $To $settings.To
        $Cc = Get-AddressList $Cc $settings.Cc
        $Bcc = Get-AddressList $Bcc $settings.Bcc
        $ReplyTo = Get-AddressList $ReplyTo $settings.ReplyTo
        if ($To.Count -eq 0) {
            Write-Error "The 'To' parameter is required, either in the function call, in the account or via the SMTP_TO environment variable."
            return
        }

        # Message-ID, and In-Reply-To with References, which put this email in the conversation it answers.
        # References may come as the header of the email answered: IDs separated by spaces.
        $referenceValues = @($References -split '[\s,]+' | Where-Object { $_ })
        foreach ($value in @($MessageId, $InReplyTo | Where-Object { $_ }) + $referenceValues) {
            if (-not (ConvertTo-MessageId $value)) {
                Write-Error "Not a Message-ID: '$value'. Expected <id@domain>."
                return
            }
        }
        if ($MessageId) { $MessageId = ConvertTo-MessageId $MessageId }
        $referenceIds = @($referenceValues | ForEach-Object { ConvertTo-MessageId $_ })
        if ($InReplyTo) {
            $InReplyTo = ConvertTo-MessageId $InReplyTo
            if ($referenceIds -notcontains $InReplyTo) { $referenceIds += $InReplyTo }
        }

        Write-Debug "Configuration: ACCOUNT='$($settings.Account)', SMTP_SERVER='$smtpServer', SMTP_PORT='$smtpPort', SMTP_FROM='$smtpFrom', FROM_NAME='$FromName', SMTP_USER='$smtpUser', PASSWORD from '$($settings.PasswordSource)', TO='$To', CC='$Cc', BCC='$Bcc', REPLY_TO='$ReplyTo', MESSAGE_ID='$MessageId', IN_REPLY_TO='$InReplyTo', REFERENCES='$referenceIds'."
        Write-Verbose "Sending email to '$($To -join ', ')' with subject '$Subject'..."

        # SMTP client configuration
        $smtpClient = New-Object Net.Mail.SmtpClient($smtpServer, $smtpPort)
        $smtpClient.EnableSsl = $true
        $smtpClient.Credentials = New-Object System.Net.NetworkCredential($smtpUser, $smtpPass)

        # Email message creation (Add accepts a single address or a comma-separated list)
        $mailMessage = New-Object Net.Mail.MailMessage
        $mailMessage.From = New-Object Net.Mail.MailAddress($smtpFrom, $FromName)
        foreach ($address in $To) { $mailMessage.To.Add($address) }
        foreach ($address in $Cc) { $mailMessage.CC.Add($address) }
        foreach ($address in $Bcc) { $mailMessage.Bcc.Add($address) }
        foreach ($address in $ReplyTo) { $mailMessage.ReplyToList.Add($address) }
        if ($MessageId) { $mailMessage.Headers['Message-ID'] = $MessageId }
        if ($InReplyTo) { $mailMessage.Headers['In-Reply-To'] = $InReplyTo }
        if ($referenceIds.Count -gt 0) { $mailMessage.Headers['References'] = $referenceIds -join ' ' }
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
