<#
.SYNOPSIS
    Copies files matching a name pattern and date range from one folder to another,
    optionally across a network share, and verifies the results.

.DESCRIPTION
    CopyFromTo.ps1 uses Robocopy as its copy engine (retry/wait logic for network
    shares, native timestamp preservation, multithreaded transfer) while PowerShell
    handles interactive prompting, a pre-copy preview, and a post-copy verification
    pass that compares file name, size, and last-write time. Optional SHA-256 verification
    is available with -VerificationMode Hash.

    If -FileName and/or -StartDate/-EndDate are not supplied, the script prompts for
    them interactively. Use -Force for unattended runs: prompts are skipped, missing
    filters default to "all files" / "no date limit", the destination folder is
    created automatically if missing, and the confirmation prompt is skipped.

    The previewed file list is the exact transfer list. Robocopy is invoked once per
    source directory (and in command-line-sized batches) with exact file names, so it
    cannot copy additional files merely because they match a broad wildcard.

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
    Only copy files last modified on or after this date. Accepted forms are yyyy-MM-dd,
    M/d/yyyy, and M/yyyy. A month/year value means the first day of that month. If
    omitted along with -EndDate, you will be prompted for a MM/yyyy range.

.PARAMETER EndDate
    Only copy files last modified on or before this date. Accepted forms are yyyy-MM-dd,
    M/d/yyyy, and M/yyyy. A month/year value means the last day of that month.

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

.PARAMETER VerificationMode
    Metadata compares file size and last-write time. Hash additionally compares SHA-256
    hashes and is slower, but provides content-integrity verification.

.PARAMETER TimestampToleranceSeconds
    Maximum permitted source/destination timestamp difference during metadata
    verification. Defaults to 2 seconds for filesystems with coarse timestamp precision.

.PARAMETER RetryCount
    Number of Robocopy retries per failed file. Defaults to 3.

.PARAMETER RetryWait
    Seconds Robocopy waits between retries. Defaults to 5.

.PARAMETER Threads
    Number of Robocopy worker threads. Defaults to 8.

.PARAMETER PreviewLimit
    Maximum matched files shown in the console preview. Defaults to 100. Specify 0 to
    show every match. Every match is still written to the script log.

.PARAMETER LogRetentionDays
    When greater than zero, removes CopyFromTo log files in LogFolder older than this
    many days. Defaults to 0, which disables automatic cleanup.

.PARAMETER FollowReparsePoint
    Allow recursive enumeration through directory junctions and symbolic links. By
    default, reparse-point directories are skipped to avoid loops and copying data
    outside the apparent source tree.

.PARAMETER PassThru
    Emit a structured result object after a completed copy. By default, results are
    displayed and logged without adding an object to the success output stream.

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
[CmdletBinding(DefaultParameterSetName = 'Default', SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(ParameterSetName = 'Default', Position = 0)]
    [string]$Source,

    [Parameter(ParameterSetName = 'Default', Position = 1)]
    [string]$Destination,

    [Parameter(ParameterSetName = 'Default')]
    [string[]]$FileName,

    [Parameter(ParameterSetName = 'Default')]
    [object]$StartDate,

    [Parameter(ParameterSetName = 'Default')]
    [object]$EndDate,

    [Parameter(ParameterSetName = 'Default')]
    [switch]$Recurse,

    [Parameter(ParameterSetName = 'Default')]
    [switch]$DryRun,

    [Parameter(ParameterSetName = 'Default')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Default')]
    [string]$LogFolder,

    [Parameter(ParameterSetName = 'Default')]
    [ValidateSet('Metadata', 'Hash')]
    [string]$VerificationMode = 'Metadata',

    [Parameter(ParameterSetName = 'Default')]
    [ValidateRange(0, 300)]
    [int]$TimestampToleranceSeconds = 2,

    [Parameter(ParameterSetName = 'Default')]
    [ValidateRange(0, 1000000)]
    [int]$RetryCount = 3,

    [Parameter(ParameterSetName = 'Default')]
    [ValidateRange(0, 3600)]
    [int]$RetryWait = 5,

    [Parameter(ParameterSetName = 'Default')]
    [ValidateRange(1, 128)]
    [int]$Threads = 8,

    [Parameter(ParameterSetName = 'Default')]
    [ValidateRange(0, 1000000)]
    [int]$PreviewLimit = 100,

    [Parameter(ParameterSetName = 'Default')]
    [ValidateRange(0, 3650)]
    [int]$LogRetentionDays = 0,

    [Parameter(ParameterSetName = 'Default')]
    [switch]$FollowReparsePoint,

    [Parameter(ParameterSetName = 'Default')]
    [switch]$PassThru,

    # Keep help isolated from operational parameters so `-Help` is always a standalone,
    # side-effect-free invocation.
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

# PowerShell's built-in mandatory-parameter prompting prints an unavoidable
# "cmdlet <name> at command pipeline position 1" banner before asking for values.
# Prompt manually instead so interactive startup stays clean while parameters remain
# fully usable for unattended and positional invocations.
if ([string]::IsNullOrWhiteSpace($Source)) {
    Write-Host ''
    $Source = Read-Host 'Source folder'
}
if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Read-Host 'Destination folder'
}

# Avoid PS 7.3+ turning Robocopy's non-zero (but non-error) exit codes into terminating errors.
if (Test-Path Variable:\PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$ErrorActionPreference = 'Stop'
$script:StartTime = Get-Date
$script:LogFile = $null
$script:RobocopyLogFile = $null
$script:LogWriteFailureReported = $false

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')] [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    if ($script:LogFile) {
        try {
            Add-Content -LiteralPath $script:LogFile -Value $line -ErrorAction Stop
        }
        catch {
            if (-not $script:LogWriteFailureReported) {
                $script:LogWriteFailureReported = $true
                Write-Warning "Unable to write to the script log '$script:LogFile': $($_.Exception.Message)"
            }
        }
    }
    $color = switch ($Level) {
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        'SUCCESS' { 'Green' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Resolve-FullFileSystemPath {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [switch]$MustExist
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'A path cannot be empty or whitespace.'
    }

    if ($MustExist) {
        $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
        if ($resolved.Provider.Name -ne 'FileSystem') {
            throw "Path '$Path' is not a filesystem path."
        }
        $fullPath = $resolved.ProviderPath
    }
    else {
        $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    }

    $fullPath = [System.IO.Path]::GetFullPath($fullPath)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -gt $root.Length) {
        $fullPath = $fullPath.TrimEnd([char[]]@('\', '/'))
    }
    return $fullPath
}

function Test-PathIsWithin {
    param(
        [Parameter(Mandatory)] [string]$Parent,
        [Parameter(Mandatory)] [string]$Child
    )
    $prefix = $Parent
    if (-not $prefix.EndsWith('\')) { $prefix += '\' }
    return $Child.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RelativeFilePath {
    param(
        [Parameter(Mandatory)] [string]$BasePath,
        [Parameter(Mandatory)] [string]$FullPath
    )
    if (-not (Test-PathIsWithin -Parent $BasePath -Child $FullPath)) {
        throw "Path '$FullPath' is outside source '$BasePath'."
    }
    return $FullPath.Substring($BasePath.Length).TrimStart([char[]]@('\', '/'))
}

function Initialize-Logging {
    param(
        [Parameter(Mandatory)] [string]$Folder,
        [int]$RetentionDays
    )

    if (-not (Test-Path -LiteralPath $Folder)) {
        New-Item -ItemType Directory -Path $Folder -Force -ErrorAction Stop | Out-Null
    }
    elseif (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
        throw "Log folder '$Folder' is not a directory."
    }

    if ($RetentionDays -gt 0) {
        $cutoff = (Get-Date).AddDays(-$RetentionDays)
        Get-ChildItem -LiteralPath $Folder -File -Filter 'CopyFromTo_*.log' -ErrorAction Stop |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction Stop
    }

    $runStamp = "$(Get-Date -Format 'yyyyMMdd_HHmmss_fff')_$PID"
    $script:LogFile = Join-Path $Folder "CopyFromTo_$runStamp.log"
    $script:RobocopyLogFile = Join-Path $Folder "CopyFromTo_${runStamp}_robocopy.log"
}

# ---------------------------------------------------------------------------
# Interactive prompts
# ---------------------------------------------------------------------------

function Read-FileNamePatterns {
    Write-Host ''
    $raw = Read-Host 'Enter file name(s) or wildcard pattern(s) to copy, comma-separated (e.g. *.pdf, Invoice*.xlsx). Press Enter for all files (*)'
    if ([string]::IsNullOrWhiteSpace($raw)) { return @('*') }
    return @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function ConvertTo-DateBound {
    param(
        [Parameter(Mandatory)] [object]$Value,
        [switch]$EndOfMonth
    )

    if ($Value -is [datetime]) { return ([datetime]$Value).Date }
    $raw = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    $parsed = [datetime]::MinValue
    $monthFormats = [string[]]@('MM/yyyy', 'M/yyyy')
    if ([datetime]::TryParseExact($raw, $monthFormats, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        $firstOfMonth = [datetime]::new($parsed.Year, $parsed.Month, 1)
        if ($EndOfMonth) { return $firstOfMonth.AddMonths(1).AddDays(-1) }
        return $firstOfMonth
    }

    $parsed = [datetime]::MinValue
    $dateFormats = [string[]]@('yyyy-MM-dd', 'yyyy-M-d', 'MM/dd/yyyy', 'M/d/yyyy', 'yyyyMMdd')
    if ([datetime]::TryParseExact($raw, $dateFormats, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed.Date
    }
    throw "Could not parse '$raw' as a date. Use yyyy-MM-dd, M/d/yyyy, or M/yyyy."
}

function Read-MonthYearDate {
    param(
        [string]$PromptText,
        [switch]$EndOfMonth
    )
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $raw = Read-Host $PromptText
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        try {
            return ConvertTo-DateBound -Value $raw -EndOfMonth:$EndOfMonth
        }
        catch {
            Write-Host "  Could not parse '$raw' as MM/yyyy (e.g. 03/2024). Try again." -ForegroundColor Yellow
        }
    }
    throw "Failed to read a valid month/year after 3 attempts."
}

function Read-DateRange {
    Write-Host ''
    Write-Host 'Specify the date range of files to copy, based on last-modified date.' -ForegroundColor Cyan
    Write-Host 'Enter dates as MM/yyyy. Press Enter on either prompt to leave that side unbounded.' -ForegroundColor Cyan
    $start = Read-MonthYearDate -PromptText '  Start month/year (e.g. 03/2024)'
    $end = Read-MonthYearDate -PromptText '  End month/year (e.g. 09/2024)' -EndOfMonth
    [pscustomobject]@{ StartDate = $start; EndDate = $end }
}

function Get-SourceFiles {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [switch]$Recursive,
        [switch]$FollowLinks
    )

    if (-not $Recursive) {
        return @(Get-ChildItem -LiteralPath $Root -File -ErrorAction Stop |
            Where-Object { $FollowLinks -or -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) })
    }

    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($Root)
    while ($queue.Count -gt 0) {
        $folder = $queue.Dequeue()
        foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -ErrorAction Stop)) {
            if ($FollowLinks -or -not ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                $files.Add($file)
            }
        }
        foreach ($directory in @(Get-ChildItem -LiteralPath $folder -Directory -ErrorAction Stop)) {
            if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and -not $FollowLinks) {
                Write-Log "Skipping reparse-point directory: $($directory.FullName)" 'WARN'
                continue
            }
            $queue.Enqueue($directory.FullName)
        }
    }
    return $files.ToArray()
}

function Split-FileNameBatches {
    param(
        [Parameter(Mandatory)] [string[]]$Names,
        [int]$CharacterBudget = 24000
    )
    $batch = [System.Collections.Generic.List[string]]::new()
    $length = 0
    foreach ($name in $Names) {
        $cost = $name.Length + 3
        if ($batch.Count -gt 0 -and ($length + $cost) -gt $CharacterBudget) {
            [pscustomobject]@{ Names = $batch.ToArray() }
            $batch = [System.Collections.Generic.List[string]]::new()
            $length = 0
        }
        $batch.Add($name)
        $length += $cost
    }
    if ($batch.Count -gt 0) { [pscustomobject]@{ Names = $batch.ToArray() } }
}

function Test-DestinationFreeSpace {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [long]$RequiredBytes
    )
    $root = [System.IO.Path]::GetPathRoot($Path)
    if ($root -match '^[A-Za-z]:\\$') {
        $drive = Get-PSDrive -Name $root.Substring(0, 1) -ErrorAction SilentlyContinue
        if ($drive -and $null -ne $drive.Free -and $drive.Free -lt $RequiredBytes) {
            Write-Log "Destination drive reports $($drive.Free) free bytes, less than the conservative $RequiredBytes-byte transfer estimate." 'WARN'
            return $false
        }
    }
    return $true
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
$matchedFiles = @()
$verified = 0
$missing = [System.Collections.Generic.List[string]]::new()
$mismatched = [System.Collections.Generic.List[string]]::new()
$sourceMissing = [System.Collections.Generic.List[string]]::new()
$aggregateRobocopyExit = 0
$robocopyInvocationCount = 0

try {
    $logDirInput = if ($LogFolder) { $LogFolder } else { Join-Path $PSScriptRoot 'Logs' }
    $logDir = Resolve-FullFileSystemPath -Path $logDirInput
    $previewOnly = [bool]($DryRun -or $WhatIfPreference)
    Initialize-Logging -Folder $logDir -RetentionDays $(if ($previewOnly) { 0 } else { $LogRetentionDays })

    if (-not (Get-Command robocopy.exe -ErrorAction SilentlyContinue)) {
        throw "robocopy.exe was not found. It ships with Windows; check your PATH."
    }

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Source folder '$Source' does not exist or is not accessible. If this is a network share, confirm connectivity and permissions."
    }
    $Source = Resolve-FullFileSystemPath -Path $Source -MustExist
    $Destination = Resolve-FullFileSystemPath -Path $Destination

    Write-Log "CopyFromTo starting. Source='$Source' Destination='$Destination' DryRun=$($DryRun.IsPresent) WhatIf=$WhatIfPreference Recurse=$($Recurse.IsPresent) Force=$($Force.IsPresent) VerificationMode=$VerificationMode"

    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        throw "Destination '$Destination' exists and is a file, not a directory."
    }
    if ($Source.Equals($Destination, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Source and destination must be different directories.'
    }
    if (Test-PathIsWithin -Parent $Source -Child $Destination) {
        throw "Destination '$Destination' cannot be inside source '$Source'. Choose a destination outside the source tree."
    }

    # --- File name pattern(s) ---
    if (-not $FileName -or $FileName.Count -eq 0) {
        $FileName = if ($Force) { @('*') } else { Read-FileNamePatterns }
    }
    # Normalizes both calling styles: a real array (only reachable via PowerShell-native
    # splatting, since a plain external-process argv can't produce one) and the
    # comma-joined single string a CLI/Task Scheduler caller would actually pass
    # (e.g. -FileName '*.txt,*.csv'), matching the comma convention used at the prompt.
    $FileName = @($FileName | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($FileName.Count -eq 0) {
        throw 'At least one non-empty file name or wildcard pattern is required.'
    }
    foreach ($pattern in $FileName) {
        if ($pattern.IndexOfAny([char[]]@('\', '/')) -ge 0) {
            throw "File pattern '$pattern' contains a path separator. Patterns must match file names only."
        }
    }
    Write-Log "File name pattern(s): $($FileName -join ', ')"

    # --- Date range ---
    $startProvided = $PSBoundParameters.ContainsKey('StartDate')
    $endProvided = $PSBoundParameters.ContainsKey('EndDate')

    if (-not $startProvided -and -not $endProvided -and -not $Force) {
        $range = Read-DateRange
        $rangeStart = $range.StartDate
        $rangeEnd = $range.EndDate
    }
    else {
        $rangeStart = if ($startProvided) { ConvertTo-DateBound -Value $StartDate } else { $null }
        $rangeEnd = if ($endProvided) { ConvertTo-DateBound -Value $EndDate -EndOfMonth } else { $null }
    }
    if ($rangeStart -and $rangeEnd -and $rangeStart -gt $rangeEnd) {
        throw "StartDate '$($rangeStart.ToString('yyyy-MM-dd'))' cannot be later than EndDate '$($rangeEnd.ToString('yyyy-MM-dd'))'."
    }
    if ($rangeStart -or $rangeEnd) {
        $startText = if ($rangeStart) { $rangeStart.ToString('yyyy-MM-dd') } else { 'unbounded' }
        $endText = if ($rangeEnd) { $rangeEnd.ToString('yyyy-MM-dd') } else { 'unbounded' }
        Write-Log "Date range: $startText to $endText (last-write time)"
    }
    else {
        Write-Log 'Date range: none (all dates included)'
    }

    # --- Compute the matching file set in PowerShell for preview/verification ---
    $candidateFiles = @(Get-SourceFiles -Root $Source -Recursive:$Recurse -FollowLinks:$FollowReparsePoint)
    $matchedFiles = @($candidateFiles | Where-Object {
        $file = $_
        $nameMatch = $false
        foreach ($pattern in $FileName) {
            if ($file.Name -like $pattern) { $nameMatch = $true; break }
        }
        if (-not $nameMatch) { return $false }
        if ($rangeStart -and $file.LastWriteTime.Date -lt $rangeStart) { return $false }
        if ($rangeEnd -and $file.LastWriteTime.Date -gt $rangeEnd) { return $false }
        return $true
    })

    Write-Log "$($matchedFiles.Count) file(s) matched the name pattern(s) and date range."

    if ($matchedFiles.Count -eq 0) {
        Write-Log 'Nothing to copy.' 'WARN'
        exit 0
    }

    $totalBytes = ($matchedFiles | Measure-Object -Property Length -Sum).Sum
    Write-Host ''
    Write-Host "Matched files (total $([math]::Round($totalBytes / 1MB, 2)) MB):" -ForegroundColor Cyan
    $previewFiles = if ($PreviewLimit -gt 0) { @($matchedFiles | Select-Object -First $PreviewLimit) } else { $matchedFiles }
    $previewFiles | ForEach-Object {
        [pscustomobject]@{
            RelativePath  = Get-RelativeFilePath -BasePath $Source -FullPath $_.FullName
            LastWriteTime = $_.LastWriteTime
            Length        = $_.Length
        }
    } | Format-Table -AutoSize | Out-Host
    if ($PreviewLimit -gt 0 -and $matchedFiles.Count -gt $PreviewLimit) {
        Write-Host "... $($matchedFiles.Count - $PreviewLimit) additional match(es) omitted from console preview; all are in the script log." -ForegroundColor Yellow
    }

    foreach ($f in $matchedFiles) {
        Write-Log "  MATCH: $($f.FullName) | $($f.LastWriteTime) | $($f.Length) bytes"
    }

    if ($previewOnly) {
        $mode = if ($WhatIfPreference) { 'WHATIF' } else { 'DRY RUN' }
        Write-Log "$mode`: no files were copied and no destination changes were made." 'WARN'
        exit 0
    }

    if (-not $Force -and -not $PSBoundParameters.ContainsKey('Confirm')) {
        $answer = Read-Host "Proceed with copying $($matchedFiles.Count) file(s) from '$Source' to '$Destination'? (Y/N)"
        if ($answer -notmatch '^[Yy]') {
            Write-Log 'Operation cancelled by user.' 'WARN'
            $exitStatus = 3
            exit 3
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Destination, "Copy $($matchedFiles.Count) exact file(s) from '$Source'")) {
        Write-Log 'Operation cancelled by ShouldProcess confirmation.' 'WARN'
        $exitStatus = 3
        exit 3
    }

    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        New-Item -ItemType Directory -Path $Destination -Force -ErrorAction Stop | Out-Null
        Write-Log "Destination folder '$Destination' was created." 'INFO'
    }

    $null = Test-DestinationFreeSpace -Path $Destination -RequiredBytes ([long]$totalBytes)

    # --- Copy the exact previewed set, grouped by source directory ---
    $firstRobocopyLog = $true
    foreach ($group in @($matchedFiles | Group-Object -Property DirectoryName)) {
        $sourceDirectory = [string]$group.Name
        $relativeDirectory = if ($sourceDirectory.Equals($Source, [System.StringComparison]::OrdinalIgnoreCase)) {
            ''
        }
        else {
            Get-RelativeFilePath -BasePath $Source -FullPath $sourceDirectory
        }
        $destinationDirectory = if ($relativeDirectory) { Join-Path $Destination $relativeDirectory } else { $Destination }
        $names = [string[]]@($group.Group | ForEach-Object Name | Sort-Object -Unique)

        foreach ($batch in @(Split-FileNameBatches -Names $names)) {
            $roboArgs = [System.Collections.Generic.List[string]]::new()
            $roboArgs.Add($sourceDirectory)
            $roboArgs.Add($destinationDirectory)
            foreach ($name in $batch.Names) { $roboArgs.Add($name) }
            $roboArgs.AddRange([string[]]@(
                "/R:$RetryCount"
                "/W:$RetryWait"
                "/MT:$Threads"
                '/COPY:DAT'
                '/DCOPY:T'
                '/XJ'
                '/NP'
                '/TEE'
                $(if ($firstRobocopyLog) { "/LOG:$script:RobocopyLogFile" } else { "/LOG+:$script:RobocopyLogFile" })
            ))
            $firstRobocopyLog = $false
            $robocopyInvocationCount++

            $displayArgs = $roboArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
            Write-Log "Running: robocopy $($displayArgs -join ' ')"
            & robocopy.exe @roboArgs | Out-Host
            $batchExitCode = $LASTEXITCODE
            $aggregateRobocopyExit = $aggregateRobocopyExit -bor $batchExitCode
            $result = Get-RobocopyResultDescription -ExitCode $batchExitCode
            foreach ($detail in $result.Details) {
                Write-Log "Robocopy batch $robocopyInvocationCount`: $detail" $(if ($result.Success) { 'INFO' } else { 'ERROR' })
            }
            if (-not $result.Success) { $exitStatus = 2 }
        }
    }
    Write-Log "Robocopy aggregate exit code: $aggregateRobocopyExit across $robocopyInvocationCount invocation(s) (full per-file log: $script:RobocopyLogFile)"

    # --- Post-copy verification ---
    Write-Log "Verifying copied files (mode: $VerificationMode)..."

    foreach ($f in $matchedFiles) {
        $relativePath = Get-RelativeFilePath -BasePath $Source -FullPath $f.FullName
        $destPath = Join-Path $Destination $relativePath
        if (-not (Test-Path -LiteralPath $f.FullName -PathType Leaf)) {
            $sourceMissing.Add($relativePath)
            Write-Log "  SOURCE DISAPPEARED before verification: $relativePath" 'ERROR'
            continue
        }
        if (-not (Test-Path -LiteralPath $destPath -PathType Leaf)) {
            $missing.Add($relativePath)
            Write-Log "  MISSING at destination: $relativePath" 'ERROR'
            continue
        }
        $sourceFile = Get-Item -LiteralPath $f.FullName -ErrorAction Stop
        $destFile = Get-Item -LiteralPath $destPath
        $sizeMatch = $destFile.Length -eq $sourceFile.Length
        $dateMatch = [math]::Abs(($destFile.LastWriteTimeUtc - $sourceFile.LastWriteTimeUtc).TotalSeconds) -le $TimestampToleranceSeconds
        $hashMatch = $true
        if ($VerificationMode -eq 'Hash') {
            $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash
            $destinationHash = (Get-FileHash -LiteralPath $destFile.FullName -Algorithm SHA256).Hash
            $hashMatch = $sourceHash -eq $destinationHash
        }
        if ($sizeMatch -and $dateMatch -and $hashMatch) {
            $verified++
        }
        else {
            $mismatched.Add($relativePath)
            Write-Log "  MISMATCH: $relativePath (sizeMatch=$sizeMatch dateMatch=$dateMatch hashMatch=$hashMatch; source: $($sourceFile.Length) bytes / $($sourceFile.LastWriteTimeUtc.ToString('o')); destination: $($destFile.Length) bytes / $($destFile.LastWriteTimeUtc.ToString('o')))" 'ERROR'
        }
    }

    if ($sourceMissing.Count -eq 0 -and $missing.Count -eq 0 -and $mismatched.Count -eq 0) {
        Write-Log "Verification passed: all $verified file(s) confirmed at destination." 'SUCCESS'
    }
    else {
        Write-Log "Verification found issues: $verified verified, $($sourceMissing.Count) missing at source, $($missing.Count) missing at destination, $($mismatched.Count) mismatched." 'ERROR'
        if ($sourceMissing.Count -gt 0) { $exitStatus = 2 }
        if ($exitStatus -eq 0) { $exitStatus = 1 }
    }

    $elapsed = (Get-Date) - $script:StartTime
    Write-Host ''
    Write-Host '=== Summary ===' -ForegroundColor Cyan
    Write-Host "Matched:    $($matchedFiles.Count)"
    Write-Host "Verified:   $verified"
    Write-Host "Source gone: $($sourceMissing.Count)"
    Write-Host "Missing:    $($missing.Count)"
    Write-Host "Mismatched: $($mismatched.Count)"
    Write-Host "Robocopy runs: $robocopyInvocationCount"
    Write-Host "Elapsed:    $($elapsed.ToString('hh\:mm\:ss'))"
    Write-Host "Script log:   $script:LogFile"
    Write-Host "Robocopy log: $script:RobocopyLogFile"

    $summary = [pscustomobject]@{
        Matched         = $matchedFiles.Count
        Verified        = $verified
        SourceMissing   = $sourceMissing.ToArray()
        Missing         = $missing.ToArray()
        Mismatched      = $mismatched.ToArray()
        RobocopyExit    = $aggregateRobocopyExit
        RobocopyRuns    = $robocopyInvocationCount
        VerificationMode = $VerificationMode
        LogFile         = $script:LogFile
        RobocopyLogFile = $script:RobocopyLogFile
        ElapsedSeconds  = [math]::Round($elapsed.TotalSeconds, 1)
    }
    if ($PassThru) { Write-Output $summary }
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
    $exitStatus = 2
}
finally {
    Write-Log "CopyFromTo finished with exit status $exitStatus."
    Write-Host ''
}

exit $exitStatus
