<#
.SYNOPSIS
    Compatibility launcher for CopyFromTo.ps1.

.DESCRIPTION
    Preserves the historical CopyFromTo-CLAUDE.ps1 launch name while delegating all
    behavior, parameters, help, logging, and exit codes to the maintained script.
#>

#Requires -Version 5.1

& (Join-Path $PSScriptRoot 'CopyFromTo.ps1') @args
exit $LASTEXITCODE
