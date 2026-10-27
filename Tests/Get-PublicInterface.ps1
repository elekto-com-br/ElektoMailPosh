<#
.SYNOPSIS
Writes the public interface of the module, as PublicInterface.txt records it.

.DESCRIPTION
For each exported command and each of its parameter sets, one line per parameter: its type, position
(none when it takes a name only), whether it is mandatory or comes from the pipeline, its validation
and its default value. The common parameters are left out; -WhatIf and -Confirm stay, as the sign
of SupportsShouldProcess.

PublicInterface.Tests.ps1 fails when the module differs from PublicInterface.txt. After a change to
the interface made on purpose, regenerate the file and commit it with the change, so that the review
shows what callers will see.

.EXAMPLE
./Tests/Get-PublicInterface.ps1 | Set-Content ./Tests/PublicInterface.txt
#>
param (
    [string]$ModulePath = (Join-Path (Split-Path $PSScriptRoot) 'ElektoMailPosh.psd1')
)

$module = Import-Module $ModulePath -Force -PassThru
$commonParameters = [System.Management.Automation.Cmdlet]::CommonParameters

# Validation and other attributes, by name (and arguments, for those that have them)
function Format-ParameterAttribute($Attribute) {
    switch ($Attribute) {
        { $_ -is [System.Management.Automation.ValidateSetAttribute] } { return "ValidateSet($($_.ValidValues -join ', '))" }
        { $_ -is [System.Management.Automation.ValidatePatternAttribute] } { return "ValidatePattern('$($_.RegexPattern)')" }
        { $_ -is [System.Management.Automation.ValidateRangeAttribute] } { return "ValidateRange($($_.MinRange), $($_.MaxRange))" }
        default { return $_.GetType().Name -replace 'Attribute$' }
    }
}

'# The public interface of ElektoMailPosh, written by Tests/Get-PublicInterface.ps1. Tests/PublicInterface.Tests.ps1'
'# fails when the module differs from it: regenerate it only for a change made on purpose.'
foreach ($command in Get-Command -Module $module.Name | Sort-Object Name) {
    $defaults = @{}
    foreach ($parameterAst in $command.ScriptBlock.Ast.Body.ParamBlock.Parameters) {
        if ($parameterAst.DefaultValue) { $defaults[$parameterAst.Name.VariablePath.UserPath] = $parameterAst.DefaultValue.Extent.Text }
    }

    ''
    $command.Name
    foreach ($parameterSet in $command.ParameterSets | Sort-Object { -not $_.IsDefault }, Name) {
        '  ' + $parameterSet.Name + $(if ($parameterSet.IsDefault) { ' (default)' })
        $parameters = $parameterSet.Parameters | Where-Object Name -notin $commonParameters
        $positional = $parameters | Where-Object Position -ge 0 | Sort-Object Position
        $named = $parameters | Where-Object Position -lt 0 | Sort-Object Name
        foreach ($parameter in @($positional) + @($named)) {
            $traits = @($parameter.ParameterType.Name)
            if ($parameter.Position -ge 0) { $traits += "position $($parameter.Position)" }
            if ($parameter.IsMandatory) { $traits += 'mandatory' }
            if ($parameter.ValueFromPipeline) { $traits += 'from the pipeline' }
            if ($parameter.ValueFromPipelineByPropertyName) { $traits += 'from the pipeline by property name' }
            if ($parameter.ValueFromRemainingArguments) { $traits += 'remaining arguments' }
            if ($parameter.Aliases.Count -gt 0) { $traits += "alias $($parameter.Aliases -join ', ')" }
            $traits += $parameter.Attributes |
                Where-Object { $_ -isnot [System.Management.Automation.ParameterAttribute] -and $_ -isnot [System.Management.Automation.AliasAttribute] -and $_.GetType().Name -ne 'ArgumentTypeConverterAttribute' } |
                ForEach-Object { Format-ParameterAttribute $_ } | Sort-Object
            if ($defaults.ContainsKey($parameter.Name)) { $traits += "default $($defaults[$parameter.Name])" }
            '    -' + $parameter.Name + ' ' + ($traits -join ', ')
        }
    }
}
