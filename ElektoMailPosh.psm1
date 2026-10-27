foreach ($folder in 'Private', 'Public') {
    Get-ChildItem -Path (Join-Path $PSScriptRoot $folder) -Filter "*.ps1" | ForEach-Object { . $_.FullName }
}

# Tab completion of account names
$accountCompleter = {
    # Of the arguments a completer gets (command, parameter, word, ...), only the word matters here
    $wordToComplete = $args[2]
    $file = try { Read-AccountFile } catch { $null }
    if ($file) { $file.Accounts.psbase.Keys | Where-Object { $_ -like "$wordToComplete*" } }
}
Register-ArgumentCompleter -CommandName Send-Mail -ParameterName Account -ScriptBlock $accountCompleter
Register-ArgumentCompleter -CommandName Get-MailAccount, Set-MailAccount, Remove-MailAccount -ParameterName Name -ScriptBlock $accountCompleter
