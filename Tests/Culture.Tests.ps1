# Account names checked and matched alike in every culture, as ElektoImapPosh does since its #14. In Turkish "I" is not
# the capital of "i", and -like, -match, -replace and -split ignore case as the culture of the session does: a name with
# a dotless i was taken in a session in Turkish, one with a dotted capital I in any session, and the file they went to
# was then refused in sessions in other cultures; and in Turkish, Get-MailAccount and Remove-MailAccount missed
# "WORK-INBOX" when given "work-inbox" (measured). Names are checked telling case apart and matched by Test-Wildcard, and
# the code of the module compares text in no other way that the culture changes.

# PSScriptAnalyzer does not see that Pester gives AfterAll and the tests the variables of BeforeAll
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables of BeforeAll are used by AfterAll and the tests')]
param ()

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestIsolation.ps1')
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'ElektoMailPosh.psd1') -Force
    $isolation = Enter-TestIsolation

    # Runs a script with the thread in the culture given, as a session in that culture runs, and puts the culture back
    function Invoke-InCulture([string]$Culture, [scriptblock]$Script) {
        $before = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = $Culture
            & $Script
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $before
        }
    }
}

AfterAll {
    Exit-TestIsolation $isolation
    Remove-Module ElektoMailPosh -ErrorAction SilentlyContinue
}

Describe 'Matching an account name with a pattern' {
    It 'ignores case alike in the Turkish culture, where -like does not' {
        $like, $matched = Invoke-InCulture 'tr-TR' {
            'WORK-INBOX' -like 'work-inbox'
            InModuleScope ElektoMailPosh {
                Test-Wildcard 'WORK-INBOX' 'work-inbox'
                Test-Wildcard 'billing' 'BILL*'
                Test-Wildcard 'billing' 'work*'
            }
        }

        $like | Should -BeFalse -Because 'that is what Test-Wildcard is for'
        $matched | Should -Be $true, $true, $false
    }

    It 'refuses a pattern that is not valid with the message of PowerShell, as -like did' {
        { InModuleScope ElektoMailPosh { Test-Wildcard 'work' 'work[' } } | Should -Throw -ExpectedMessage 'The specified wildcard character pattern is not valid: work`['
    }
}

Describe 'The code of the module' {
    BeforeAll {
        # The places of a script that compare text as the culture of the session does, each as "<name>:<line> <what>":
        # -like in every form (a pattern without wildcards is compared by the culture even telling case apart), and the
        # forms of -match, -replace and -split that ignore case; switch -Wildcard or -Regex, Where-Object -Like or
        # -Match, Select-String, Sort-Object -Unique and Group-Object, without -CaseSensitive; ToLower and ToUpper; a
        # name or a string that starts with CurrentCulture; options that ignore case without CultureInvariant; and
        # ValidatePattern without Options, which then ignores case as the culture does. As in ElektoImapPosh.
        function Find-CultureDependentText([string]$Name, [string]$Script) {
            $tokens = $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($Script, [ref]$tokens, [ref]$errors)
            $errors | Should -BeNullOrEmpty -Because "$Name should parse"
            foreach ($token in $tokens) {
                if ("$($token.Kind)" -in 'Ilike', 'Inotlike', 'Clike', 'Cnotlike', 'Imatch', 'Inotmatch', 'Ireplace', 'Isplit') { "${Name}:$($token.Extent.StartLineNumber) $($token.Text)" }
            }
            foreach ($node in $ast.FindAll({ $true }, $true)) {
                $what = $null
                if ($node -is [System.Management.Automation.Language.SwitchStatementAst]) {
                    $flags = $node.Flags
                    if (($flags -band [System.Management.Automation.Language.SwitchFlags]'Wildcard, Regex') -and -not ($flags -band [System.Management.Automation.Language.SwitchFlags]::CaseSensitive)) { $what = "switch -$flags" }
                } elseif ($node -is [System.Management.Automation.Language.CommandAst]) {
                    $command = $node.GetCommandName()
                    $parameters = @($node.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object ParameterName)
                    $caseSensitive = $parameters -contains 'CaseSensitive'
                    if ($command -in 'Where-Object', 'where', '?') {
                        $by = @($parameters | Where-Object { $_ -in 'Like', 'NotLike', 'ILike', 'INotLike', 'CLike', 'CNotLike', 'Match', 'NotMatch', 'IMatch', 'INotMatch' })
                        if ($by) { $what = "$command -$($by[0])" }
                    } elseif ($command -in 'Select-String', 'Group-Object' -and -not $caseSensitive) { $what = $command }
                    elseif ($command -eq 'Sort-Object' -and $parameters -contains 'Unique' -and -not $caseSensitive) { $what = 'Sort-Object -Unique' }
                } elseif ($node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                    if ("$($node.Member)" -in 'ToLower', 'ToUpper' -and -not $node.Arguments) { $what = "$($node.Member)()" }
                } elseif ($node -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    # Strings, and the names of members (CurrentCultureIgnoreCase) and of options
                    $value = $node.Value
                    if ($value -cmatch '(?<![A-Za-z])IgnoreCase(?![A-Za-z])' -and $value -cnotmatch 'CultureInvariant') { $what = $value }
                    elseif ($value.StartsWith('CurrentCulture', [StringComparison]::Ordinal)) { $what = $value }
                } elseif ($node -is [System.Management.Automation.Language.AttributeAst] -and $node.TypeName.Name -in 'ValidatePattern', 'ValidatePatternAttribute') {
                    $options = @($node.NamedArguments | Where-Object ArgumentName -EQ 'Options')
                    $text = if ($options) { "$($options[0].Argument)" } else { 'IgnoreCase' }
                    if ($text -cmatch 'IgnoreCase' -and $text -cnotmatch 'CultureInvariant') { $what = 'ValidatePattern ignoring case' }
                }
                if ($what) { "${Name}:$($node.Extent.StartLineNumber) $what" }
            }
        }
    }

    # A form the search missed, or one it took for another, would let the test of the module pass without finding anything
    It 'finds each form that compares text as the culture does, and none of those that do not' {
        $culture = @'
$a -like 'x*'
$a -notlike 'x*'
$a -ilike 'x*'
$a -clike 'x*'
$a -match 'x'
$a -inotmatch 'x'
$a -replace 'x'
$a -split 'x'
switch -Wildcard ($a) { 'x*' { } }
switch -Regex ($a) { 'x' { } }
$a | Where-Object Name -Like 'x*'
$a | Where-Object Name -Match 'x'
$a | Select-String 'x'
$a | Sort-Object -Unique
$a | Group-Object
$a.ToLower()
$a.ToUpper()
[string]::Equals($a, $b, [StringComparison]::CurrentCultureIgnoreCase)
[regex]::IsMatch($a, 'x', 'IgnoreCase')
function f { param([ValidatePattern('^x$')]$y) }
'@
        $alike = @'
$a -cmatch 'x'
$a -cnotmatch 'x'
$a -creplace 'x'
$a -csplit 'x'
$a -eq 'x'
$a -in 'x', 'y'
switch ($a) { 'x' { } }
switch -Regex -CaseSensitive ($a) { 'x' { } }
$a | Where-Object Name -CMatch 'x'
$a | Select-String 'x' -CaseSensitive
$a | Sort-Object -Unique -CaseSensitive
$a | Sort-Object
$a | Group-Object -CaseSensitive
$a.ToLowerInvariant()
[regex]::IsMatch($a, 'x', 'IgnoreCase, CultureInvariant')
[StringComparer]::OrdinalIgnoreCase
[string]::Equals($a, $b, [StringComparison]::InvariantCultureIgnoreCase)
function f { param([ValidatePattern('^x$', Options = 'None')]$y) }
'@

        $found = @(Find-CultureDependentText 'culture' $culture)
        $found | ForEach-Object { [int]($_ -creplace '^culture:(\d+) .*$', '$1') } | Should -Be (1..20) -Because "each line has one such form: $($found -join '; ')"
        Find-CultureDependentText 'alike' $alike | Should -BeNullOrEmpty
    }

    It 'compares text alike in every culture' {
        $root = Split-Path $PSScriptRoot
        $files = @(Get-ChildItem -LiteralPath (Join-Path $root 'Private'), (Join-Path $root 'Public') -Filter '*.ps1') + (Get-Item -LiteralPath (Join-Path $root 'ElektoMailPosh.psm1'))
        $files.Count | Should -BeGreaterThan 5

        $found = foreach ($file in $files) { Find-CultureDependentText "$($file.Directory.Name)/$($file.Name)" ([IO.File]::ReadAllText($file.FullName)) }

        $found | Should -BeNullOrEmpty -Because 'Test-Wildcard, which ignores case alike in every culture, is the way to match a pattern'
    }
}

# PowerShell keeps the regexes it built, with the culture they were built in: a session set to another culture once it
# runs would check names with those of its start, so each of these starts in its culture, in a process of its own
Describe 'Account names in a session that starts in another culture' {
    It 'refuses a name with a letter outside A to Z in <Culture>, as a parameter and in the file, and finds the others in any case' -TestCases @(
        @{ Culture = 'tr-TR' }
        @{ Culture = 'en-US' }
    ) {
        # The accounts of each culture in a folder of its own, in the test drive; the result comes back as JSON
        $result = Invoke-AsUserScript -Config (Join-Path $TestDrive $Culture) -Culture $Culture {
            # A name taken is written; one refused throws, as a parameter or read from the file
            function Test-Taken([scriptblock]$Script) { try { $null = & $Script; $true } catch { $false } }
            $account = @{ Server = 'smtp.example.com'; User = 'me@example.com'; WarningAction = 'SilentlyContinue' }
            $file = Join-Path $env:SMTP_CONFIG_DIR 'accounts.json'
            $dotless = 'k' + [char]0x131 + 'y' + [char]0x131
            $dotted = 'K' + [char]0x130 + 'Y' + [char]0x130
            [pscustomobject]@{
                Culture       = [cultureinfo]::CurrentCulture.Name
                Plain         = Test-Taken { Set-MailAccount -Name 'WORK-INBOX' @account }
                Dotless       = Test-Taken { Set-MailAccount -Name $dotless @account }
                Dotted        = Test-Taken { Set-MailAccount -Name $dotted @account }
                Found         = (Get-MailAccount -Name 'work-inbox' -ErrorAction SilentlyContinue).Name
                Removed       = Test-Taken { Remove-MailAccount -Name 'Work-Inbox' -Confirm:$false -ErrorAction Stop; if (Get-MailAccount 'WORK-INBOX' -ErrorAction SilentlyContinue) { throw 'still there' } }
                DotlessInFile = Test-Taken { Set-Content -LiteralPath $file -Value ('{ "Accounts": { "' + $dotless + '": { "Server": "s", "User": "u" } } }'); Get-MailAccount -ErrorAction Stop }
                DottedInFile  = Test-Taken { Set-Content -LiteralPath $file -Value ('{ "Accounts": { "' + $dotted + '": { "Server": "s", "User": "u" } } }'); Get-MailAccount -ErrorAction Stop }
            } | ConvertTo-Json -Compress
        } | ConvertFrom-Json

        $result.Culture | Should -Be $Culture
        $result.Plain | Should -BeTrue
        $result.Dotless | Should -BeFalse -Because 'a dotless i is no letter from A to Z'
        $result.Dotted | Should -BeFalse -Because 'a dotted capital I is no letter from A to Z'
        $result.Found | Should -Be 'WORK-INBOX'
        $result.Removed | Should -BeTrue
        $result.DotlessInFile | Should -BeFalse
        $result.DottedInFile | Should -BeFalse
    }
}
