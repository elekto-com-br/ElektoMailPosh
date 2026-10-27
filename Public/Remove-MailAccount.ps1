<#
.SYNOPSIS
Removes an account and its stored password.

.DESCRIPTION
The `Remove-MailAccount` function removes an account from accounts.json and deletes its password
from the Windows Credential Manager (or, on Linux and macOS, its password file). If it was the
default account, there is no default account afterwards. A SMTP_PASS_<NAME> environment variable
is not touched.

.PARAMETER Name
The name of the account.

.EXAMPLE
Remove-MailAccount old
#>
Function Remove-MailAccount {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name
    )

    $file = Read-AccountFile
    $existingName = Find-AccountName $file $Name
    if (-not $existingName) {
        Write-Error "There is no account '$Name'."
        return
    }

    if (-not $PSCmdlet.ShouldProcess("account '$existingName' in '$($file.Path)' and its stored password", 'Remove')) { return }

    $file.Accounts.Remove($existingName)
    $defaultName = if ($file.Default -eq $existingName) { $null } else { $file.Default }
    Write-AccountFile $defaultName $file.Accounts
    Write-Verbose "Account '$existingName' removed from '$($file.Path)'."

    if (Clear-StoredPassword $existingName) { Write-Verbose "Stored password of account '$existingName' deleted." }

    $variable = Get-PasswordVariableName $existingName
    if ([Environment]::GetEnvironmentVariable($variable)) {
        Write-Warning "The environment variable $variable still holds the password of '$existingName'."
    }
}
