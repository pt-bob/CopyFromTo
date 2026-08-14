<#
.SYNOPSIS
Calculates the total size of files whose date falls within an inclusive range.

.DESCRIPTION
Scans a folder and reports the number and combined size of matching files. By
default, the script examines LastWriteTime because it normally represents the
date of the file's content more reliably than CreationTime after a copy or restore.

Dates must use the unambiguous yyyy-MM-dd format. The entire end date is included.
Use -Recurse to include subfolders, -Force to include hidden files, and
-DateProperty CreationTime when creation date is specifically required. If the
folder or either date is omitted, the script prompts for it.

.PARAMETER FolderPath
Folder to scan. Local paths and UNC paths are supported.

.PARAMETER StartDate
First date to include, in yyyy-MM-dd format.

.PARAMETER EndDate
Last date to include, in yyyy-MM-dd format.

.PARAMETER DateProperty
File timestamp to filter on. The default is LastWriteTime.

.PARAMETER Recurse
Includes files in all subfolders.

.PARAMETER Force
Includes hidden files. This does not suppress access errors.

.PARAMETER PassThru
Returns a structured object instead of the formatted summary text.

.EXAMPLE
.\TotalFileSize-of-DateRange.ps1 -FolderPath 'C:\Data' `
    -StartDate '2026-01-01' -EndDate '2026-01-31'

.EXAMPLE
.\TotalFileSize-of-DateRange.ps1 -FolderPath '\\Server\Share\Archive' `
    -StartDate '2026-01-01' -EndDate '2026-12-31' -Recurse -PassThru
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [Alias('Path')]
    [string]$FolderPath,

    [Parameter(Position = 1)]
    [string]$StartDate,

    [Parameter(Position = 2)]
    [string]$EndDate,

    [ValidateSet('LastWriteTime', 'CreationTime')]
    [string]$DateProperty = 'LastWriteTime',

    [switch]$Recurse,

    [switch]$Force,

    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$showOutputSpacing = -not $PassThru
$activityLineOpen = $false

if ($showOutputSpacing) {
    Write-Host
}

function Read-ColoredInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    # Write the prompt before changing the console color so application text keeps
    # the user's normal foreground color and only the echoed input appears yellow.
    Write-Host "${Prompt}: " -NoNewline

    $rawUi = $null
    $originalForeground = $null
    $foregroundChanged = $false

    try {
        $rawUi = $Host.UI.RawUI
        $originalForeground = $rawUi.ForegroundColor
        $rawUi.ForegroundColor = [ConsoleColor]::Yellow
        $foregroundChanged = $true
    }
    catch {
        # Some non-console hosts do not expose writable RawUI colors. Input still
        # works normally in those hosts, only without the optional yellow echo.
    }

    try {
        return Read-Host
    }
    finally {
        if ($foregroundChanged) {
            $rawUi.ForegroundColor = $originalForeground
        }
    }
}

function Read-RequiredValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = Read-ColoredInput -Prompt $Prompt
    }

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name cannot be empty."
    }

    return $Value.Trim()
}

function ConvertFrom-IsoDate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$Name
    )

    [datetime]$parsedDate = [datetime]::MinValue
    $parsed = [datetime]::TryParseExact(
        $Value,
        'yyyy-MM-dd',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref]$parsedDate
    )

    if (-not $parsed) {
        throw "$Name must be a valid date in yyyy-MM-dd format."
    }

    return $parsedDate.Date
}

try {
    $FolderPath = Read-RequiredValue -Value $FolderPath `
        -Prompt 'Enter the path of the folder to scan' -Name 'Folder path'

    if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
        throw "The directory '$FolderPath' does not exist or is not accessible."
    }

    $resolvedFolder = (Resolve-Path -LiteralPath $FolderPath).ProviderPath

    $StartDate = Read-RequiredValue -Value $StartDate `
        -Prompt 'Enter the BEGINNING date (YYYY-MM-DD)' -Name 'Beginning date'
    $EndDate = Read-RequiredValue -Value $EndDate `
        -Prompt 'Enter the END date (YYYY-MM-DD)' -Name 'End date'

    $rangeStart = ConvertFrom-IsoDate -Value $StartDate -Name 'Beginning date'
    $rangeEnd = ConvertFrom-IsoDate -Value $EndDate -Name 'End date'

    if ($rangeStart -gt $rangeEnd) {
        throw 'Beginning date cannot be later than end date.'
    }

    $childItemParameters = @{
        LiteralPath = $resolvedFolder
        File        = $true
        ErrorAction = 'Stop'
    }

    if ($Recurse) { $childItemParameters.Recurse = $true }
    if ($Force) { $childItemParameters.Force = $true }

    [long]$fileCount = 0
    [long]$totalBytes = 0
    [long]$filesScanned = 0

    if ($showOutputSpacing) {
        Write-Host 'Scanning...' -NoNewline
        $activityLineOpen = $true
        $lastActivityUpdate = [datetime]::UtcNow
        $activityDotCount = 0
    }

    Get-ChildItem @childItemParameters | ForEach-Object {
        $file = $_
        $filesScanned++

        if ($showOutputSpacing -and
            ([datetime]::UtcNow - $lastActivityUpdate).TotalSeconds -ge 1) {
            Write-Host '.' -NoNewline
            $lastActivityUpdate = [datetime]::UtcNow
            $activityDotCount++

            # Keep very long scans readable instead of producing one unbounded line.
            if ($activityDotCount -ge 60) {
                Write-Host
                Write-Host 'Scanning...' -NoNewline
                $activityDotCount = 0
            }
        }

        $fileDate = [datetime]$file.$DateProperty
        # Comparing the date portion includes the entire final day and also avoids
        # overflowing when the caller uses 9999-12-31 as an open-ended maximum.
        if ($fileDate -ge $rangeStart -and $fileDate.Date -le $rangeEnd) {
            $fileCount++
            $totalBytes += [long]$file.Length
        }
    }

    if ($showOutputSpacing) {
        Write-Host " done ($filesScanned files checked)."
        $activityLineOpen = $false
    }

    $result = [pscustomobject][ordered]@{
        FolderPath  = $resolvedFolder
        StartDate   = $rangeStart
        EndDate     = $rangeEnd
        DateProperty = $DateProperty
        Recursive   = [bool]$Recurse
        FileCount   = $fileCount
        TotalBytes  = $totalBytes
        TotalMB     = [math]::Round($totalBytes / 1MB, 2)
        TotalGB     = [math]::Round($totalBytes / 1GB, 2)
    }

    if ($PassThru) {
        Write-Output $result
    }
    else {
        Write-Host ('SUCCESS: Files: {0:N0} | Size: {1:N0} bytes | {2:N2} MB | {3:N2} GB' -f `
                $result.FileCount, $result.TotalBytes, ($result.TotalBytes / 1MB), `
                ($result.TotalBytes / 1GB)) -ForegroundColor Green
        Write-Host
    }
}
catch {
    if ($showOutputSpacing) {
        if ($activityLineOpen) {
            Write-Host
        }
        Write-Host "FAILED: Unable to calculate file sizes: $($_.Exception.Message)" `
            -ForegroundColor Red
        Write-Host
    }
    else {
        Write-Error "Unable to calculate file sizes: $($_.Exception.Message)" `
            -ErrorAction Continue
    }
    exit 1
}
