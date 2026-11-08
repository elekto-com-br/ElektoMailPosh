# Accounts: named sets of SMTP settings kept in accounts.json, like the accounts of msmtp. An account
# is self-contained: while one is in use, the SMTP_* environment variables are ignored (its password
# may still come from SMTP_PASS_<ACCOUNT>, see PasswordStore.ps1).

$script:AccountSettingNames = @('Server', 'Port', 'User', 'From', 'FromName', 'To', 'Cc', 'Bcc', 'ReplyTo')
$script:AddressSettingNames = @('To', 'Cc', 'Bcc', 'ReplyTo')
# Matched telling case apart (-cnotmatch, and Options None in the ValidatePattern of Set-MailAccount), as it names
# both: ignoring case as the culture does, it took a dotless i in a session in Turkish and a dotted capital I in any
# session, and the file such a name went to was then refused in sessions in other cultures (measured)
$script:AccountNamePattern = '^[A-Za-z0-9][A-Za-z0-9_.-]*$'
$script:DefaultServer = 'smtp.gmail.com'
$script:DefaultPort = 587

# Account names are keys of dictionaries, where PowerShell gives a key precedence over a property of the
# same name: an account called "Keys" would hide .Keys. So the names are always listed with .psbase.Keys.

# Whether an account name matches a wildcard pattern, ignoring case alike in every culture. -like ignores case as
# the culture of the session does, and in Turkish "I" is not the capital of "i": "work-inbox" missed the account
# "WORK-INBOX" (measured). Elsewhere the module compares text only in the forms that tell case apart (-cmatch,
# -creplace, -csplit) or with -eq and -in, which no culture changes; Tests/Culture.Tests.ps1 reads the code and fails
# on any other. A pattern that is not valid ("work[") throws with the message of PowerShell, as -like did, rather than
# with the 'Exception calling "IsMatch"' that wraps it.
function Test-Wildcard([string]$Text, [string]$Pattern) {
    try {
        return [WildcardPattern]::new($Pattern, [System.Management.Automation.WildcardOptions]'IgnoreCase, CultureInvariant').IsMatch($Text)
    } catch [System.Management.Automation.MethodInvocationException] {
        throw $_.Exception.InnerException
    }
}

# The folder of accounts.json (and, outside Windows, of the password files): SMTP_CONFIG_DIR, or else
# ElektoMailPosh in the user's configuration folder (%APPDATA% on Windows; XDG_CONFIG_HOME, or else ~/.config, on
# Linux and macOS)
function Get-AccountDirectory {
    # A relative SMTP_CONFIG_DIR is resolved here against the current location: the .NET file calls that
    # keep the passwords would resolve it against the process folder, which Set-Location does not change
    if ($env:SMTP_CONFIG_DIR) { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($env:SMTP_CONFIG_DIR) }
    if ($IsWindows) { return Get-ApplicationDataDirectory }
    # Linux and macOS alike, as command-line tools do, and as ElektoImapPosh does: since .NET 8, ApplicationData is
    # ~/Library/Application Support on macOS. On Linux this is what .NET gives (XDG_CONFIG_HOME, when an absolute path).
    $configuration = $env:XDG_CONFIG_HOME
    if (-not $configuration -or -not [IO.Path]::IsPathRooted($configuration)) { $configuration = Join-Path $HOME '.config' }
    $directory = Join-Path $configuration 'ElektoMailPosh'
    # 2.0.0 to 2.0.4 kept it where .NET puts ApplicationData, which on macOS is ~/Library/Application Support: that
    # folder, with its password files, is still the one while it has an accounts file and the new one has none
    $previous = Get-ApplicationDataDirectory
    if ($previous -ne $directory -and -not (Test-Path -LiteralPath (Join-Path $directory 'accounts.json') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $previous 'accounts.json') -PathType Leaf)) {
        return $previous
    }
    return $directory
}

# ElektoMailPosh in the folder .NET gives for ApplicationData: %APPDATA% on Windows, ~/Library/Application Support
# on macOS. Without DoNotVerify, a folder that does not exist yet (~/.config of a new Linux user, a container) comes
# back as '', and even sending by the SMTP_* variables would fail.
function Get-ApplicationDataDirectory {
    return Join-Path ([Environment]::GetFolderPath('ApplicationData', 'DoNotVerify')) 'ElektoMailPosh'
}

function Get-AccountFilePath {
    return Join-Path (Get-AccountDirectory) 'accounts.json'
}

# A list of addresses from a string (which may itself be a comma-separated list) or an array of them
function ConvertTo-AddressList($Value) {
    return ,[string[]]@($Value | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

# The settings in the SMTP_* environment variables, with the defaults Send-Mail has always applied
function Get-EnvironmentConfiguration {
    return @{
        Server   = if ($env:SMTP_SERVER) { $env:SMTP_SERVER } else { $script:DefaultServer }
        Port     = if ($env:SMTP_PORT) { [int]$env:SMTP_PORT } else { $script:DefaultPort }
        User     = $env:SMTP_USER
        Password = $env:SMTP_PASS
        From     = $env:SMTP_FROM
        FromName = $env:SMTP_FROM_NAME
        To       = ConvertTo-AddressList $env:SMTP_TO
        Cc       = ConvertTo-AddressList $env:SMTP_CC
        Bcc      = ConvertTo-AddressList $env:SMTP_BCC
        ReplyTo  = ConvertTo-AddressList $env:SMTP_REPLY_TO
    }
}

# Reads the accounts file into Path, Default (an account name or $null) and Accounts (name -> settings,
# both looked up ignoring case). Returns $null when there is no file; throws when it is not valid.
# ConvertFrom-Json keeps the case of the keys, and keeps apart keys that differ only in case. The rest
# of the module ignores case (as do the Credential Manager and the SMTP_PASS_<ACCOUNT> variables), so
# the keys, account names and settings of the file are read ignoring case too, and two that differ only
# in case are an error rather than one of them lost.
function Read-AccountFile {
    $path = Get-AccountFilePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }

    # A file that cannot be read stops the command: taken as empty, Send-Mail went back to the SMTP_* variables, and
    # Set-MailAccount wrote the new account over the others
    try {
        $text = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    } catch {
        throw "Could not read the accounts file '$path': $($_.Exception.Message)"
    }
    try {
        $json = $text | ConvertFrom-Json -AsHashtable
    } catch {
        throw "The accounts file '$path' is not valid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $json) { $json = @{} }
    if ($json -isnot [System.Collections.IDictionary]) { throw "The accounts file '$path' must hold a JSON object." }
    $data = @{}
    foreach ($entry in $json.GetEnumerator()) {
        $key = 'Default', 'Accounts' | Where-Object { $_ -eq $entry.Key }
        if (-not $key) { throw "Unknown key '$($entry.Key)' in the accounts file '$path'." }
        if ($data.ContainsKey($key)) { throw "The key '$key' is twice in the accounts file '$path', in different case." }
        $data[$key] = $entry.Value
    }

    $accounts = [ordered]@{}
    if ($null -ne $data.Accounts) {
        if ($data.Accounts -isnot [System.Collections.IDictionary]) { throw "'Accounts' in '$path' must be a JSON object." }
        foreach ($entry in $data.Accounts.GetEnumerator()) {
            $name = $entry.Key
            if ($name -cnotmatch $script:AccountNamePattern) {
                throw "Invalid account name '$name' in '$path': use letters from A to Z, digits, '.', '-' and '_', starting with a letter or digit."
            }
            $sameName = @($accounts.psbase.Keys | Where-Object { $_ -eq $name })
            if ($sameName) { throw "The accounts '$($sameName[0])' and '$name' in '$path' differ only in case, which makes them the same account: rename or remove one." }
            $sameVariable = Find-PasswordVariableOwner $accounts.psbase.Keys $name
            if ($sameVariable) { throw "The accounts '$sameVariable' and '$name' in '$path' would share the password variable $(Get-PasswordVariableName $name), which would give one the password of the other: rename one." }
            if ($entry.Value -isnot [System.Collections.IDictionary]) { throw "Account '$name' in '$path' must be a JSON object." }

            $settings = [ordered]@{}
            foreach ($setting in $entry.Value.GetEnumerator()) {
                $key = $script:AccountSettingNames | Where-Object { $_ -eq $setting.Key }
                if (-not $key) {
                    throw "Unknown setting '$($setting.Key)' in account '$name' of '$path'. Settings: $($script:AccountSettingNames -join ', ')."
                }
                if ($settings.Contains($key)) { throw "The setting '$key' is twice in account '$name' of '$path', in different case." }
                $value = $setting.Value
                if ($key -eq 'Port') {
                    if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 1 -or $value -gt 65535) { throw "Port of account '$name' in '$path' must be a number from 1 to 65535." }
                    $value = [int]$value
                } elseif ($key -in $script:AddressSettingNames) {
                    $value = ConvertTo-AddressList $value
                } elseif ($value -isnot [string]) {
                    throw "$key of account '$name' in '$path' must be a string."
                }
                $settings[$key] = $value
            }
            if (-not $settings.Server -or -not $settings.User) { throw "Account '$name' in '$path' needs both Server and User." }
            $accounts[$name] = $settings
        }
    }

    $default = $data.Default
    if ($default) {
        $match = @($accounts.psbase.Keys | Where-Object { $_ -eq $default })
        if (-not $match) { throw "The default account '$default' is not one of the accounts in '$path'." }
        $default = $match[0]
    } else {
        $default = $null
    }

    return @{ Path = $path; Default = $default; Accounts = $accounts }
}

# The account of $Names whose password variable (SMTP_PASS_<ACCOUNT>, where all but letters and digits become '_')
# would be that of $Name, such as work.prod for work-prod; or $null
function Find-PasswordVariableOwner($Names, [string]$Name) {
    $variable = Get-PasswordVariableName $Name
    return @($Names | Where-Object { (Get-PasswordVariableName $_) -eq $variable })[0]
}

# Writes the accounts file, settings in a fixed order and without the empty ones. Any failure stops the caller here,
# before it stores or deletes a password that would then not match: an exception of .NET, as the rename below may
# throw, would otherwise end only its own statement, and the command went on as if the file were written (measured).
function Write-AccountFile([string]$Default, [System.Collections.IDictionary]$Accounts) {
    $ErrorActionPreference = 'Stop'
    $path = Get-AccountFilePath
    $data = [ordered]@{}
    if ($Default) { $data.Default = $Default }
    $data.Accounts = [ordered]@{}
    foreach ($name in $Accounts.psbase.Keys) {
        $settings = [ordered]@{}
        foreach ($key in $script:AccountSettingNames) {
            $value = $Accounts[$name][$key]
            if ($key -in $script:AddressSettingNames) {
                $value = ConvertTo-AddressList $value
                if ($value.Count -eq 0) { continue }
                # A single address is written as a string, which reads better than a one-item array
                if ($value.Count -eq 1) { $value = $value[0] }
            } elseif ($null -eq $value -or "$value" -eq '') {
                continue
            }
            $settings[$key] = $value
        }
        $data.Accounts[$name] = $settings
    }

    New-Item -ItemType Directory -Path (Split-Path -Path $path) -Force -ErrorAction Stop | Out-Null
    # When accounts.json is a link, as GNU stow makes one into a dotfiles repository, the file it finally points to is
    # the one written: the rename below, over the link, would put a regular file in its place, and the file in the
    # repository would get no more changes, without a word (measured)
    if (Test-Path -LiteralPath $path) {
        $target = [IO.File]::ResolveLinkTarget($path, $true)
        if ($target) { $path = $target.FullName }
    }
    # Written beside it and then put in its place (a rename, atomic), so a write that fails or is interrupted
    # leaves the previous file whole: written in place, the file was emptied first, and a write that then failed
    # left it with no accounts (measured). Outside Windows, the new file has the mode of the one it replaces from
    # the start, before anything is written: a file the user made owner-only is never readable by others, not even
    # halfway. The umask can only take bits from the mode it is created with, so it is set again.
    $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        if (-not $IsWindows -and (Test-Path -LiteralPath $path)) {
            $mode = [IO.File]::GetUnixFileMode($path)
            [IO.FileStream]::new($temporary, [IO.FileStreamOptions]@{ Mode = 'CreateNew'; Access = 'Write'; UnixCreateMode = $mode }).Dispose()
            [IO.File]::SetUnixFileMode($temporary, $mode)
        }
        Set-Content -LiteralPath $temporary -Value ($data | ConvertTo-Json -Depth 5) -Encoding utf8NoBOM -ErrorAction Stop
        [IO.File]::Move($temporary, $path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction Ignore }
    }
}

# The name of an account as the file spells it, or $null when the file has no such account
function Find-AccountName($File, [string]$Name) {
    if (-not $File) { return $null }
    return @($File.Accounts.psbase.Keys | Where-Object { $_ -eq $Name })[0]
}

# The settings Send-Mail uses: those of the account given, or of the default account of the file, or
# else the SMTP_* environment variables, as before accounts existed. Throws when the account does not
# exist or has no password.
function Resolve-MailConfiguration([string]$Account) {
    $file = Read-AccountFile
    if (-not $Account -and $file) { $Account = $file.Default }

    if (-not $Account) {
        $settings = Get-EnvironmentConfiguration
        $settings.Account = $null
        $settings.PasswordSource = 'SMTP_PASS'
        return $settings
    }

    if (-not $file) { throw "There is no account '$Account': the accounts file '$(Get-AccountFilePath)' does not exist." }
    $name = Find-AccountName $file $Account
    if (-not $name) { throw "There is no account '$Account' in '$($file.Path)'. Accounts: $($file.Accounts.psbase.Keys -join ', ')." }

    $password = Get-AccountPassword $name
    if (-not $password) { throw (Get-MissingPasswordMessage $name) }

    $accountSettings = $file.Accounts[$name]
    return @{
        Account        = $name
        Server         = $accountSettings.Server
        Port           = if ($accountSettings.Port) { $accountSettings.Port } else { $script:DefaultPort }
        User           = $accountSettings.User
        Password       = $password.Password
        PasswordSource = $password.Source
        From           = $accountSettings.From
        FromName       = $accountSettings.FromName
        To             = ConvertTo-AddressList $accountSettings.To
        Cc             = ConvertTo-AddressList $accountSettings.Cc
        Bcc            = ConvertTo-AddressList $accountSettings.Bcc
        ReplyTo        = ConvertTo-AddressList $accountSettings.ReplyTo
    }
}
