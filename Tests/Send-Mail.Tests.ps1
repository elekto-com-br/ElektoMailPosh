# Send-Mail as the scripts written for 1.x call it: parameters by position, body from the pipeline.
# The SMTP client is replaced by one that keeps what it would send, so nothing leaves the machine.

BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'ElektoMailPosh.psd1') -Force

    # Only the SMTP_* variables, and an empty configuration folder: a machine without accounts
    $savedEnvironment = @{}
    foreach ($name in 'SMTP_CONFIG_DIR', 'SMTP_SERVER', 'SMTP_PORT', 'SMTP_USER', 'SMTP_PASS', 'SMTP_FROM', 'SMTP_FROM_NAME', 'SMTP_TO', 'SMTP_CC', 'SMTP_BCC', 'SMTP_REPLY_TO') {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    $env:SMTP_CONFIG_DIR = Join-Path $TestDrive 'config'
    $env:SMTP_USER = 'robot@example.com'
    $env:SMTP_PASS = 'not-a-password'
    $env:SMTP_TO = 'ops@example.com'

    $attachment = Join-Path $TestDrive 'report.txt'
    Set-Content -Path $attachment -Value 'report'

    # Every other object is the real one (Pester 6 no longer calls the command when no filter matches)
    Mock -ModuleName ElektoMailPosh New-Object -MockWith { Microsoft.PowerShell.Utility\New-Object @PesterBoundParameters }

    # What each Send would have sent (the message itself is disposed of right after)
    $sent = [System.Collections.Generic.List[object]]::new()
    Mock -ModuleName ElektoMailPosh New-Object -ParameterFilter { $TypeName -eq 'Net.Mail.SmtpClient' } -MockWith {
        $client = [pscustomobject]@{ EnableSsl = $false; Credentials = $null }
        $client | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        $client | Add-Member -MemberType ScriptMethod -Name Send -Value {
            param($message)
            $sent.Add([pscustomobject]@{
                Subject     = $message.Subject
                Body        = $message.Body
                IsBodyHtml  = $message.IsBodyHtml
                FromName    = $message.From.DisplayName
                To          = @($message.To.Address)
                Cc          = @($message.CC.Address)
                Bcc         = @($message.Bcc.Address)
                ReplyTo     = @($message.ReplyToList.Address)
                MessageId   = $message.Headers['Message-ID']
                Priority    = "$($message.Priority)"
                Attachments = @($message.Attachments.Name)
            })
        }
        return $client
    }
}

AfterAll {
    foreach ($entry in $savedEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
    }
    Remove-Module ElektoMailPosh -ErrorAction SilentlyContinue
}

Describe 'Send-Mail called as in 1.x' {
    BeforeEach {
        $sent.Clear()
    }

    It 'takes the subject and the body by position' {
        Send-Mail 'Disk check' 'Free: 10%'

        $sent.Count | Should -Be 1
        $sent[0].Subject | Should -Be 'Disk check'
        $sent[0].Body | Should -Be 'Free: 10%'
        $sent[0].IsBodyHtml | Should -BeFalse
        $sent[0].To | Should -Be 'ops@example.com'
    }

    It 'takes -IsHtml by position' {
        Send-Mail 'Speed' '<b>Slow</b>' $true

        $sent.Count | Should -Be 1
        $sent[0].Body | Should -Be '<b>Slow</b>'
        $sent[0].IsBodyHtml | Should -BeTrue
    }

    It 'takes parameters by position and by name in the same call' {
        Send-Mail ('Backups') ('<p>Last ones</p>') -IsHtml $true

        $sent.Count | Should -Be 1
        $sent[0].Subject | Should -Be 'Backups'
        $sent[0].IsBodyHtml | Should -BeTrue
    }

    It 'takes every parameter of 1.x by position' {
        Send-Mail 'Report' 'Attached.' $false 'Vilna' 'to@example.com' 'cc@example.com' 'bcc@example.com' 'High' $attachment

        $sent.Count | Should -Be 1
        $sent[0].Subject | Should -Be 'Report'
        $sent[0].Body | Should -Be 'Attached.'
        $sent[0].IsBodyHtml | Should -BeFalse
        $sent[0].FromName | Should -Be 'Vilna'
        $sent[0].To | Should -Be 'to@example.com'
        $sent[0].Cc | Should -Be 'cc@example.com'
        $sent[0].Bcc | Should -Be 'bcc@example.com'
        $sent[0].Priority | Should -Be 'High'
        $sent[0].Attachments | Should -Be 'report.txt'
    }

    It 'takes the body from the pipeline and the subject by position' {
        'line 1', 'line 2' | Send-Mail 'Log'

        $sent.Count | Should -Be 1
        $sent[0].Subject | Should -Be 'Log'
        $sent[0].Body | Should -Be "line 1$([Environment]::NewLine)line 2"
    }
}

Describe 'Send-Mail with the parameters added in 2.0' {
    BeforeEach {
        $sent.Clear()
    }

    # -BodyFile is in a parameter set of its own, where -Body is not needed
    It 'takes -BodyFile by name, with the subject by position' {
        $bodyFile = Join-Path $TestDrive 'monthly.html'
        Set-Content -Path $bodyFile -Value '<p>From a file</p>' -NoNewline

        Send-Mail 'Monthly report' -BodyFile $bodyFile

        $sent.Count | Should -Be 1
        $sent[0].Subject | Should -Be 'Monthly report'
        $sent[0].Body | Should -Be '<p>From a file</p>'
        $sent[0].IsBodyHtml | Should -BeTrue
    }

    It 'takes them by name, after parameters by position' {
        Send-Mail 'Status' 'All good.' $false -ReplyTo 'support@example.com' -MessageId 'status-1@example.com'

        $sent.Count | Should -Be 1
        $sent[0].Body | Should -Be 'All good.'
        $sent[0].ReplyTo | Should -Be 'support@example.com'
        $sent[0].MessageId | Should -Be '<status-1@example.com>'
    }
}

Describe 'Send-Mail positions' {
    # A new parameter with a position, or one moved, would change what an existing call means
    It 'keeps the order of 1.x in the parameter set <Set>, and the parameters added since take names only' -TestCases @(
        @{ Set = 'Body'; Expected = 'Subject, Body, IsHtml, FromName, To, Cc, Bcc, Priority, Attachments' }
        @{ Set = 'BodyFile'; Expected = 'Subject, IsHtml, FromName, To, Cc, Bcc, Priority, Attachments' }
    ) {
        $parameterSet = (Get-Command Send-Mail).ParameterSets | Where-Object Name -eq $Set
        $positional = $parameterSet.Parameters | Where-Object Position -ge 0 | Sort-Object Position

        ($positional.Name -join ', ') | Should -Be $Expected
    }
}
