<#
.SYNOPSIS
Envia e-mails usando um servidor SMTP.

.DESCRIPTION
A função `Send-Mail` permite enviar e-mails com suporte a HTML, configurações via variáveis de ambiente 
ou parâmetros explícitos.

.PARAMETER Subject
O assunto do e-mail. Este parâmetro é obrigatório.

.PARAMETER Body
O corpo do e-mail. Este parâmetro é obrigatório.

.PARAMETER IsHtml
Indica se o corpo do e-mail está em formato HTML. O padrão é $False.

.PARAMETER FromName
O nome do remetente. Se não fornecido, usa o nome da máquina.

.PARAMETER To
O destinatário do e-mail. Se não fornecido, será usado o valor da variável de ambiente `SMTP_TO`.

.PARAMETER Attachments
Array de caminhos de arquivos para anexar ao e-mail. Os arquivos devem existir no sistema de arquivos.

.NOTES
As credenciais e configurações do servidor SMTP devem ser definidas nas variáveis de ambiente:
- SMTP_USER
- SMTP_PASS
- SMTP_SERVER (opcional, padrão: smtp.gmail.com)
- SMTP_PORT (opcional, padrão: 587)
- SMTP_FROM (opcional, padrão: SMTP_USER)

.EXAMPLE
Send-Mail -Subject "Teste 1" -Body "Conteúdo do Teste" -FromName "Teste" -To "destinatario@example.com"

Este exemplo envia um e-mail simples para o destinatário.

.EXAMPLE
Send-Mail -Subject "Alerta" -Body "<h1>Alerta</h1><p>Mensagem</p>" -IsHtml $true

Este exemplo envia um e-mail em formato HTML com o assunto "Alerta".

.EXAMPLE
Send-Mail -Subject "Relatório" -Body "Segue em anexo o relatório." -To "destinatario@example.com" -Attachments @("C:\relatorio.pdf", "C:\dados.xlsx")

Este exemplo envia um e-mail com dois arquivos anexados.
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

    # Carregar configurações de ambiente
    Write-Debug "Chamada: Subject='$Subject', Body='$Body', IsHtml='$IsHtml', FromName='$FromName', To='$To'."
    Write-Debug "Ambiente: SMTP_SERVER='$env:SMTP_SERVER', SMTP_PORT='$env:SMTP_PORT', SMTP_FROM='$env:SMTP_FROM', SMTP_TO='$env:SMTP_TO', SMTP_USER='$env:SMTP_USER', SMTP_PASS='$(if($env:SMTP_PASS){"[DEFINIDO]"}else{"[NAO DEFINIDO]"})'"

    $smtpUser = $env:SMTP_USER
    $smtpPass = $env:SMTP_PASS

    if (-not $smtpUser -or -not $smtpPass) {
        Write-Error "As variáveis de ambiente SMTP_USER e/ou SMTP_PASS não estão configuradas."
        return
    }

    $smtpServer = $env:SMTP_SERVER ?? "smtp.gmail.com"
    $smtpPort = $env:SMTP_PORT ?? 587
    $smtpFrom = $env:SMTP_FROM ?? $smtpUser    
    if ([string]::IsNullOrWhiteSpace($FromName)) { $FromName = $env:COMPUTERNAME }
            
    # O To opcional... aparentemente o PowerShell converte os $null de string para "" automaticamente, o que faz com que ?? falhe
    if ([string]::IsNullOrWhiteSpace($To)) { $To = $env:SMTP_TO }        
    if ([string]::IsNullOrWhiteSpace($To)) {
        Write-Error "O parâmetro 'To' é obrigatório, seja na chamada da função ou na variável de ambiente SMTP_TO."
        return
    }

    Write-Debug "Configuração: SMTP_SERVER='$smtpServer', SMTP_PORT='$smtpPort', SMTP_FROM='$smtpFrom', SMTP_USER='$smtpUser', TO='$To'."
    Write-Verbose "Enviando e-mail para '$To' com assunto '$Subject'..."

    # Configuração do cliente SMTP
    $smtpClient = New-Object Net.Mail.SmtpClient($smtpServer, $smtpPort)
    $smtpClient.EnableSsl = $true
    $smtpClient.Credentials = New-Object System.Net.NetworkCredential($smtpUser, $smtpPass)

    # Criação da mensagem de e-mail
    $mailMessage = New-Object Net.Mail.MailMessage
    $mailMessage.From = "$FromName <$smtpFrom>"
    $mailMessage.To.Add($To)
    $mailMessage.Subject = $Subject
    $mailMessage.Body = $Body
    $mailMessage.IsBodyHtml = $IsHtml

    # Validar e adicionar anexos
    $attachmentObjects = @()
    foreach ($attachmentPath in $Attachments) {
        if (-not (Test-Path -Path $attachmentPath -PathType Leaf)) {
            # Limpar recursos já criados antes de sair
            foreach ($att in $attachmentObjects) {
                $att.Dispose()
            }
            $mailMessage.Dispose()
            $smtpClient.Dispose()
            Write-Error "O arquivo de anexo não foi encontrado: '$attachmentPath'"
            return
        }
        $fullPath = (Resolve-Path -Path $attachmentPath).Path
        $attachment = New-Object System.Net.Mail.Attachment($fullPath)
        $mailMessage.Attachments.Add($attachment)
        $attachmentObjects += $attachment
        Write-Verbose "Anexo adicionado: $fullPath"
    }

    # Envio do e-mail com retry e backoff exponencial
    $maxRetries = 5
    $retryCount = 0
    $delay = 1

    try {
        while ($retryCount -lt $maxRetries) {
            try {
                $smtpClient.Send($mailMessage)
                Write-Verbose "E-mail enviado com sucesso."
                return
            } catch {
                $retryCount++
                if ($retryCount -ge $maxRetries) {
                    Write-Error "Erro ao enviar e-mail após $maxRetries tentativas: $_"
                    return
                }
                Write-Warning "Erro ao enviar e-mail: $_. Tentando novamente em $delay segundos..."
                Start-Sleep -Seconds $delay
                $delay *= 2
            }
        }
    } finally {
        # Liberar recursos dos anexos e da mensagem
        foreach ($att in $attachmentObjects) {
            $att.Dispose()
        }
        $mailMessage.Dispose()
        $smtpClient.Dispose()
    }
}
