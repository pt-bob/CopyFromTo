<#
.SYNOPSIS
    Copies files matching a name pattern and date range from one folder to another,
    optionally across a network share, and verifies the results.

.DESCRIPTION
    CopyFromTo.ps1 uses Robocopy as its copy engine (retry/wait logic for network
    shares, native timestamp preservation, multithreaded transfer) while PowerShell
    handles interactive prompting, a pre-copy preview, and a post-copy verification
    pass that compares file name, size, and last-write time (no binary/hash compare).

    If -FileName and/or -StartDate/-EndDate are not supplied, the script prompts for
    them interactively. Use -Force for unattended runs: prompts are skipped, missing
    filters default to "all files" / "no date limit", the destination folder is
    created automatically if missing, and the confirmation prompt is skipped.

.PARAMETER Source
    Folder to copy files from. Can be a local path or a UNC network path.

.PARAMETER Destination
    Folder to copy files to. Can be a local path or a UNC network path. Created
    automatically if missing (with confirmation, unless -Force).

.PARAMETER FileName
    One or more file names or wildcard patterns (e.g. "*.pdf", "Invoice*.xlsx"). For
    multiple patterns, separate them with a comma (e.g. "*.pdf,Invoice*.xlsx" or, from
    PowerShell code, an array). If omitted, you will be prompted. Leave blank at the
    prompt for all files.

.PARAMETER StartDate
    Only copy files last modified on or after this date. If omitted along with
    -EndDate, you will be prompted for a MM/yyyy range.

.PARAMETER EndDate
    Only copy files last modified on or before this date (end of that month if
    supplied via the prompt). If omitted along with -StartDate, you will be
    prompted for a MM/yyyy range.

.PARAMETER Recurse
    Include subfolders (mirrors non-empty subfolder structure at the destination).

.PARAMETER DryRun
    Show what would be copied without copying or creating the destination folder.

.PARAMETER Force
    Skip all interactive prompts (unspecified filters default to "all files" /
    "no date limit"), skip the confirmation prompt, and auto-create the
    destination folder if missing.

.PARAMETER LogFolder
    Folder to write log files to. Defaults to a "Logs" folder next to this script.

.PARAMETER Help
    Displays a description of every command-line parameter and exits without
    copying anything. Can be used on its own, with no other parameters.

.EXAMPLE
    .\CopyFromTo.ps1 -Help
    Displays all command-line parameters with a short explanation of each.

.EXAMPLE
    .\CopyFromTo.ps1 -Source 'C:\Data\Reports' -Destination '\\NAS\Archive\Reports'
    Prompts for file name pattern(s) and a date range, previews the matches, asks
    for confirmation, then copies and verifies.

.EXAMPLE
    .\CopyFromTo.ps1 -Source 'C:\Data' -Destination 'D:\Backup' -FileName '*.pdf' -StartDate '1/2024' -EndDate '6/2024' -DryRun
    Shows what *.pdf files modified between Jan and Jun 2024 would be copied,
    without copying anything.

.EXAMPLE
    .\CopyFromTo.ps1 -Source 'C:\Data' -Destination '\\NAS\Backup\Data' -Force
    Unattended run: copies all files, no date filter, no prompts.
#>

#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
    [Parameter(ParameterSetName = 'Default', Mandatory = $true, Position = 0)]
    [string]$Source,

    [Parameter(ParameterSetName = 'Default', Mandatory = $true, Position = 1)]
    [string]$Destination,

    [Parameter(ParameterSetName = 'Default')]
    [string[]]$FileName,

    [Parameter(ParameterSetName = 'Default')]
    [datetime]$StartDate,

    [Parameter(ParameterSetName = 'Default')]
    [datetime]$EndDate,

    [Parameter(ParameterSetName = 'Default')]
    [switch]$Recurse,

    [Parameter(ParameterSetName = 'Default')]
    [switch]$DryRun,

    [Parameter(ParameterSetName = 'Default')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Default')]
    [string]$LogFolder,

    # Its own parameter set (rather than just [switch]$Help in the Default set) so that
    # `-Help` alone works standalone - Source/Destination are Mandatory in 'Default', and
    # PowerShell prompts for missing mandatory parameters *before* any script code runs,
    # which would block a bare "-Help" invocation on a "Supply values for..." prompt.
    [Parameter(ParameterSetName = 'Help', Mandatory = $true)]
    [switch]$Help
)

if ($PSCmdlet.ParameterSetName -eq 'Help') {
    # Get-Help's default formatter pads each .EXAMPLE block with several trailing
    # "blank" lines that actually contain indentation whitespace, not true empty lines
    # (not something controllable from comment-based help source) - collapse any run of
    # 2+ such lines down to a single blank line before printing.
    $helpText = (Get-Help -Detailed $PSCommandPath | Out-String) -replace '(?:[ \t]*\r?\n){2,}', "`n`n"
    Write-Host $helpText.TrimEnd()
    Write-Host ''
    exit 0
}

# Avoid PS 7.3+ turning Robocopy's non-zero (but non-error) exit codes into terminating errors.
if (Test-Path Variable:\PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$ErrorActionPreference = 'Stop'
$script:StartTime = Get-Date

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

$logDir = if ($LogFolder) { $LogFolder } else { Join-Path $PSScriptRoot 'Logs' }
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$runStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:LogFile = Join-Path $logDir "CopyFromTo_$runStamp.log"
$script:RobocopyLogFile = Join-Path $logDir "CopyFromTo_${runStamp}_robocopy.log"

function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')] [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    Add-Content -LiteralPath $script:LogFile -Value $line
    $color = switch ($Level) {
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        'SUCCESS' { 'Green' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# Interactive prompts
# ---------------------------------------------------------------------------

function Read-FileNamePatterns {
    Write-Host ''
    $raw = Read-Host 'Enter file name(s) or wildcard pattern(s) to copy, comma-separated (e.g. *.pdf, Invoice*.xlsx). Press Enter for all files (*.*)'
    if ([string]::IsNullOrWhiteSpace($raw)) { return @('*.*') }
    return @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function ConvertTo-MonthYearDate {
    param(
        [string]$PromptText,
        [switch]$EndOfMonth
    )
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $raw = Read-Host $PromptText
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        # $parsed must start as a real typed DateTime, not $null - Windows PowerShell 5.1
        # can't resolve the TryParseExact overload when the [ref] target is untyped/null.
        # The format list must be explicitly [string[]]-cast - an uncast @(...) literal
        # resolves to Object[], which silently makes TryParseExact return $false instead
        # of throwing, so this fails quietly rather than with an obvious error.
        $parsed = [datetime]::MinValue
        $formats = [string[]]@('MM/yyyy', 'M/yyyy')
        if ([datetime]::TryParseExact($raw.Trim(), $formats, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            $firstOfMonth = Get-Date -Year $parsed.Year -Month $parsed.Month -Day 1
            if ($EndOfMonth) { return $firstOfMonth.AddMonths(1).AddDays(-1) }
            return $firstOfMonth
        }
        Write-Host "  Could not parse '$raw' as MM/yyyy (e.g. 03/2024). Try again." -ForegroundColor Yellow
    }
    throw "Failed to read a valid month/year after 3 attempts."
}

function Read-DateRange {
    Write-Host ''
    Write-Host 'Specify the date range of files to copy, based on last-modified date.' -ForegroundColor Cyan
    Write-Host 'Enter dates as MM/yyyy. Press Enter on either prompt to leave that side unbounded.' -ForegroundColor Cyan
    $start = ConvertTo-MonthYearDate -PromptText '  Start month/year (e.g. 03/2024)'
    $end = ConvertTo-MonthYearDate -PromptText '  End month/year (e.g. 09/2024)' -EndOfMonth
    [pscustomobject]@{ StartDate = $start; EndDate = $end }
}

# ---------------------------------------------------------------------------
# Robocopy exit code interpretation
# https://learn.microsoft.com/windows-server/administration/windows-commands/robocopy
# ---------------------------------------------------------------------------

function Get-RobocopyResultDescription {
    param([int]$ExitCode)
    $flags = @()
    if ($ExitCode -band 1) { $flags += 'Files were copied successfully.' }
    if ($ExitCode -band 2) { $flags += 'Extra files or folders exist at the destination (not present in source).' }
    if ($ExitCode -band 4) { $flags += 'Mismatched files or folders were detected.' }
    if ($ExitCode -band 8) { $flags += 'ERROR: Some files or folders could not be copied.' }
    if ($ExitCode -band 16) { $flags += 'FATAL ERROR: Robocopy did not copy any files - check the command line and permissions.' }
    if ($ExitCode -eq 0) { $flags += 'No files needed copying; source and destination already match (or nothing matched the filters).' }
    [pscustomobject]@{
        ExitCode = $ExitCode
        Success  = $ExitCode -lt 8
        Details  = $flags
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$exitStatus = 0

try {
    Write-Log "CopyFromTo starting. Source='$Source' Destination='$Destination' DryRun=$($DryRun.IsPresent) Recurse=$($Recurse.IsPresent) Force=$($Force.IsPresent)"

    if (-not (Get-Command robocopy.exe -ErrorAction SilentlyContinue)) {
        throw "robocopy.exe was not found. It ships with Windows; check your PATH."
    }

    $Source = $Source.TrimEnd('\')
    $Destination = $Destination.TrimEnd('\')

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Source folder '$Source' does not exist or is not accessible. If this is a network share, confirm connectivity and permissions."
    }

    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        if ($DryRun) {
            Write-Log "Destination folder '$Destination' does not exist. (Dry run - it would be created.)" 'WARN'
        }
        elseif ($Force) {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            Write-Log "Destination folder '$Destination' did not exist and was created (-Force)." 'WARN'
        }
        else {
            $answer = Read-Host "Destination folder '$Destination' does not exist. Create it? (Y/N)"
            if ($answer -match '^[Yy]') {
                New-Item -ItemType Directory -Path $Destination -Force | Out-Null
                Write-Log "Destination folder '$Destination' created." 'INFO'
            }
            else {
                Write-Log 'Operation cancelled: destination folder does not exist.' 'WARN'
                exit 3
            }
        }
    }

    # --- File name pattern(s) ---
    if (-not $FileName -or $FileName.Count -eq 0) {
        $FileName = if ($Force) { @('*.*') } else { Read-FileNamePatterns }
    }
    # Normalizes both calling styles: a real array (only reachable via PowerShell-native
    # splatting, since a plain external-process argv can't produce one) and the
    # comma-joined single string a CLI/Task Scheduler caller would actually pass
    # (e.g. -FileName '*.txt,*.csv'), matching the comma convention used at the prompt.
    $FileName = @($FileName | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    Write-Log "File name pattern(s): $($FileName -join ', ')"

    # --- Date range ---
    # [datetime] parameters can't be $null, so detect "was it actually passed on the
    # command line" via $PSBoundParameters instead of checking the variable's value.
    $startProvided = $PSBoundParameters.ContainsKey('StartDate')
    $endProvided = $PSBoundParameters.ContainsKey('EndDate')

    if (-not $startProvided -and -not $endProvided -and -not $Force) {
        $range = Read-DateRange
        $rangeStart = $range.StartDate
        $rangeEnd = $range.EndDate
    }
    else {
        $rangeStart = if ($startProvided) { $StartDate.Date } else { $null }
        $rangeEnd = if ($endProvided) { $EndDate.Date } else { $null }
    }
    $effectiveStart = if ($rangeStart) { $rangeStart } else { Get-Date '1980-01-01' }
    $effectiveEnd = if ($rangeEnd) { $rangeEnd } else { (Get-Date).Date }
    $useDateFilter = [bool]($rangeStart -or $rangeEnd)
    if ($useDateFilter) {
        Write-Log "Date range: $($effectiveStart.ToString('yyyy-MM-dd')) to $($effectiveEnd.ToString('yyyy-MM-dd')) (last-write time)"
    }
    else {
        Write-Log 'Date range: none (all dates included)'
    }

    # --- Compute the matching file set in PowerShell for preview/verification ---
    $gciParams = @{ LiteralPath = $Source; File = $true }
    if ($Recurse) { $gciParams['Recurse'] = $true }
    $matchedFiles = @(Get-ChildItem @gciParams | Where-Object {
        $file = $_
        $nameMatch = $false
        foreach ($pattern in $FileName) {
            if ($file.Name -like $pattern) { $nameMatch = $true; break }
        }
        $nameMatch -and $file.LastWriteTime.Date -ge $effectiveStart -and $file.LastWriteTime.Date -le $effectiveEnd
    })

    Write-Log "$($matchedFiles.Count) file(s) matched the name pattern(s) and date range."

    if ($matchedFiles.Count -eq 0) {
        Write-Log 'Nothing to copy.' 'WARN'
        exit 0
    }

    $totalBytes = ($matchedFiles | Measure-Object -Property Length -Sum).Sum
    Write-Host ''
    Write-Host "Matched files (total $([math]::Round($totalBytes / 1MB, 2)) MB):" -ForegroundColor Cyan
    $matchedFiles | Select-Object Name, LastWriteTime, Length | Format-Table -AutoSize | Out-Host

    foreach ($f in $matchedFiles) {
        Write-Log "  MATCH: $($f.FullName) | $($f.LastWriteTime) | $($f.Length) bytes"
    }

    if ($DryRun) {
        Write-Log "DRY RUN: no files were copied and no destination changes were made." 'WARN'
        exit 0
    }

    if (-not $Force) {
        $answer = Read-Host "Proceed with copying $($matchedFiles.Count) file(s) from '$Source' to '$Destination'? (Y/N)"
        if ($answer -notmatch '^[Yy]') {
            Write-Log 'Operation cancelled by user.' 'WARN'
            exit 3
        }
    }

    # --- Build and run Robocopy ---
    $roboArgs = [System.Collections.Generic.List[string]]::new()
    $roboArgs.Add($Source)
    $roboArgs.Add($Destination)
    foreach ($pattern in $FileName) { $roboArgs.Add($pattern) }
    if ($Recurse) { $roboArgs.Add('/S') }
    if ($useDateFilter) {
        $roboArgs.Add("/MAXAGE:$($effectiveStart.ToString('yyyyMMdd'))")
        $roboArgs.Add("/MINAGE:$($effectiveEnd.ToString('yyyyMMdd'))")
    }
    $roboArgs.AddRange([string[]]@(
        '/R:3'          # retry each failed file 3 times (default is ~1,000,000 - would hang on network hiccups)
        '/W:5'          # wait 5 seconds between retries
        '/MT:8'         # multithreaded copy
        '/NP'           # no per-file percentage progress spam in the log
        '/TEE'          # echo Robocopy's own output to the console as well as its log
        "/LOG:$script:RobocopyLogFile"
    ))

    Write-Log "Running: robocopy $($roboArgs -join ' ')"
    & robocopy.exe @roboArgs | Out-Null
    $roboExitCode = $LASTEXITCODE
    $result = Get-RobocopyResultDescription -ExitCode $roboExitCode
    foreach ($detail in $result.Details) {
        Write-Log "Robocopy: $detail" $(if ($result.Success) { 'INFO' } else { 'ERROR' })
    }
    Write-Log "Robocopy exit code: $roboExitCode (full per-file log: $script:RobocopyLogFile)"

    if (-not $result.Success) {
        Write-Log 'Copy completed with errors - see the Robocopy log for details.' 'ERROR'
        $exitStatus = 2
    }

    # --- Post-copy verification: name, size, and last-write time (no binary compare) ---
    Write-Log 'Verifying copied files (name, size, last-write time)...'
    $verified = 0
    $missing = @()
    $mismatched = @()

    foreach ($f in $matchedFiles) {
        $relativePath = $f.FullName.Substring($Source.Length).TrimStart('\')
        $destPath = Join-Path $Destination $relativePath
        if (-not (Test-Path -LiteralPath $destPath -PathType Leaf)) {
            $missing += $relativePath
            Write-Log "  MISSING at destination: $relativePath" 'ERROR'
            continue
        }
        $destFile = Get-Item -LiteralPath $destPath
        $sizeMatch = $destFile.Length -eq $f.Length
        $dateMatch = [math]::Abs(($destFile.LastWriteTime - $f.LastWriteTime).TotalSeconds) -le 2
        if ($sizeMatch -and $dateMatch) {
            $verified++
        }
        else {
            $mismatched += $relativePath
            Write-Log "  MISMATCH: $relativePath (source: $($f.Length) bytes / $($f.LastWriteTime); destination: $($destFile.Length) bytes / $($destFile.LastWriteTime))" 'ERROR'
        }
    }

    if ($missing.Count -eq 0 -and $mismatched.Count -eq 0) {
        Write-Log "Verification passed: all $verified file(s) confirmed at destination." 'SUCCESS'
    }
    else {
        Write-Log "Verification found issues: $verified verified, $($missing.Count) missing, $($mismatched.Count) mismatched." 'ERROR'
        if ($exitStatus -eq 0) { $exitStatus = 1 }
    }

    $elapsed = (Get-Date) - $script:StartTime
    Write-Host ''
    Write-Host '=== Summary ===' -ForegroundColor Cyan
    Write-Host "Matched:    $($matchedFiles.Count)"
    Write-Host "Verified:   $verified"
    Write-Host "Missing:    $($missing.Count)"
    Write-Host "Mismatched: $($mismatched.Count)"
    Write-Host "Elapsed:    $($elapsed.ToString('hh\:mm\:ss'))"
    Write-Host "Script log:   $script:LogFile"
    Write-Host "Robocopy log: $script:RobocopyLogFile"

    [pscustomobject]@{
        Matched         = $matchedFiles.Count
        Verified        = $verified
        Missing         = $missing
        Mismatched      = $mismatched
        RobocopyExit    = $roboExitCode
        LogFile         = $script:LogFile
        RobocopyLogFile = $script:RobocopyLogFile
        ElapsedSeconds  = [math]::Round($elapsed.TotalSeconds, 1)
    }
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
    $exitStatus = 2
}
finally {
    Write-Log "CopyFromTo finished with exit status $exitStatus."
}

exit $exitStatus
