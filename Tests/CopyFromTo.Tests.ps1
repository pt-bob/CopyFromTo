<#
    Integration tests for CopyFromTo.ps1.

    Run with:  Invoke-Pester -Path .\Tests -Output Detailed
    Requires Pester 5+. Windows PowerShell 5.1's inbox Pester (3.4.0) is too old for this
    syntax - run under pwsh (PowerShell 7), where Pester 5+ is installed.

    CopyFromTo.ps1 is invoked as a separate process for every test (via the same
    PowerShell executable that's running the tests), never dot-sourced. The script ends
    with `exit $exitStatus`, which would terminate the Pester host itself if the script
    ran in-process - a real hazard specific to testing scripts (rather than functions)
    that call `exit`. Because it's a real child process, `-NonInteractive` is used as a
    safety net: if a test forgets to supply enough filters to avoid a prompt, Read-Host
    fails fast instead of hanging the run.
#>

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\CopyFromTo.ps1')).Path
    $script:CompatibilityLauncherPath = (Resolve-Path (Join-Path $PSScriptRoot '..\CopyFromTo-CLAUDE.ps1')).Path
    $script:PwshExe = (Get-Process -Id $PID).Path
    $script:SuiteRoot = Join-Path ([System.IO.Path]::GetTempPath()) "CopyFromToTests_$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $script:SuiteRoot -Force | Out-Null

    function New-TestFile {
        param(
            [Parameter(Mandatory)] [string]$Path,
            [string]$Content = 'test content',
            [Parameter(Mandatory)] [datetime]$LastWriteTime
        )
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -LiteralPath $Path -Value $Content -NoNewline
        (Get-Item -LiteralPath $Path).LastWriteTime = $LastWriteTime
    }

    function Invoke-CopyFromTo {
        param(
            [string[]]$ScriptArgs,
            [string]$WorkingDirectory
        )
        $oldLocation = Get-Location
        try {
            if ($WorkingDirectory) { Set-Location -LiteralPath $WorkingDirectory }
            $output = & $script:PwshExe -NoProfile -NonInteractive -File $script:ScriptPath @ScriptArgs 2>&1 | Out-String
            [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output   = $output
            }
        }
        finally {
            Set-Location -LiteralPath $oldLocation
        }
    }

    # For driving the interactive prompts themselves (FileName / date range). Unlike
    # Invoke-CopyFromTo, this must NOT pass -NonInteractive - that makes Read-Host throw
    # immediately instead of reading the piped answers.
    function Invoke-CopyFromToInteractive {
        param(
            [string[]]$ScriptArgs,
            [string[]]$Answers,
            [string]$ExecutableScript = $script:ScriptPath
        )
        $output = $Answers | & $script:PwshExe -NoProfile -File $ExecutableScript @ScriptArgs 2>&1 | Out-String
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = $output
        }
    }
}

Describe 'CopyFromTo.ps1' {

    AfterAll {
        if (Test-Path -LiteralPath $script:SuiteRoot) {
            Remove-Item -LiteralPath $script:SuiteRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    BeforeEach {
        $script:CaseRoot = Join-Path $script:SuiteRoot ([guid]::NewGuid())
        $script:SourceDir = Join-Path $script:CaseRoot 'Source'
        $script:DestDir = Join-Path $script:CaseRoot 'Dest'
        $script:LogDir = Join-Path $script:CaseRoot 'Logs'
        New-Item -ItemType Directory -Path $script:SourceDir -Force | Out-Null
    }

    Context 'Name pattern and date range filtering' {

        It 'copies only files whose name matches the pattern and whose date falls in range' {
            New-TestFile "$SourceDir\Report1.txt" -LastWriteTime '2024-03-15'
            New-TestFile "$SourceDir\Report2.txt" -LastWriteTime '2024-06-30'
            New-TestFile "$SourceDir\OldFile.txt" -LastWriteTime '2023-01-01'
            New-TestFile "$SourceDir\NewFile.txt" -LastWriteTime '2025-01-01'
            New-TestFile "$SourceDir\Invoice1.csv" -LastWriteTime '2024-04-01'

            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-FileName', '*.txt', '-StartDate', '2024-03-01', '-EndDate', '2024-06-30',
                '-Force', '-LogFolder', $LogDir
            )

            $result.ExitCode | Should -Be 0
            (Get-ChildItem $DestDir -File).Name | Sort-Object | Should -Be @('Report1.txt', 'Report2.txt')

            $srcFile = Get-Item "$SourceDir\Report1.txt"
            $destFile = Get-Item "$DestDir\Report1.txt"
            $destFile.Length | Should -Be $srcFile.Length
            [math]::Abs(($destFile.LastWriteTime - $srcFile.LastWriteTime).TotalSeconds) | Should -BeLessOrEqual 2
        }

        It 'matches multiple comma-separated name patterns supplied to -FileName' {
            # A comma-joined single string is how a real CLI/Task Scheduler caller passes
            # multiple patterns, since plain argv can't produce a genuine PowerShell array
            # (see the note above -FileName's normalization step in CopyFromTo.ps1).
            New-TestFile "$SourceDir\Report1.txt" -LastWriteTime '2024-05-01'
            New-TestFile "$SourceDir\Invoice1.csv" -LastWriteTime '2024-05-01'
            New-TestFile "$SourceDir\Image1.png" -LastWriteTime '2024-05-01'

            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-FileName', '*.txt,*.csv', '-StartDate', '2024-01-01', '-EndDate', '2024-12-31',
                '-Force', '-LogFolder', $LogDir
            )

            $result.ExitCode | Should -Be 0
            (Get-ChildItem $DestDir -File).Name | Sort-Object | Should -Be @('Invoice1.csv', 'Report1.txt')
        }

        It 'treats an omitted date range as unbounded when -Force is used' {
            New-TestFile "$SourceDir\Ancient.txt" -LastWriteTime '2001-01-01'
            New-TestFile "$SourceDir\Future.txt" -LastWriteTime '2030-01-01'

            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-FileName', '*.txt', '-Force', '-LogFolder', $LogDir
            )

            $result.ExitCode | Should -Be 0
            (Get-ChildItem $DestDir -File).Name | Sort-Object | Should -Be @('Ancient.txt', 'Future.txt')
            $result.Output | Should -Match 'Matched:\s+2'
            $result.Output | Should -Match 'Verified:\s+2'
        }

        It 'honors one-sided date bounds without adding hidden limits' {
            New-TestFile "$SourceDir\Before1980.txt" -LastWriteTime '1970-01-01'
            New-TestFile "$SourceDir\Modern.txt" -LastWriteTime '2024-05-01'
            New-TestFile "$SourceDir\Future.txt" -LastWriteTime '2030-01-01'

            $startOnlyDest = Join-Path $script:CaseRoot 'StartOnly'
            $startResult = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $startOnlyDest,
                '-FileName', '*.txt', '-StartDate', '2024-01-01', '-Force', '-LogFolder', $LogDir
            )
            $startResult.ExitCode | Should -Be 0
            (Get-ChildItem $startOnlyDest -File).Name | Sort-Object | Should -Be @('Future.txt', 'Modern.txt')

            $endOnlyDest = Join-Path $script:CaseRoot 'EndOnly'
            $endResult = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $endOnlyDest,
                '-FileName', '*.txt', '-EndDate', '2024-12-31', '-Force', '-LogFolder', $LogDir
            )
            $endResult.ExitCode | Should -Be 0
            (Get-ChildItem $endOnlyDest -File).Name | Sort-Object | Should -Be @('Before1980.txt', 'Modern.txt')
        }

        It 'treats a command-line month EndDate as the end of that month' {
            New-TestFile "$SourceDir\June30.txt" -LastWriteTime '2024-06-30'

            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-FileName', '*.txt', '-EndDate', '6/2024', '-Force', '-LogFolder', $LogDir
            )

            $result.ExitCode | Should -Be 0
            Test-Path -LiteralPath "$DestDir\June30.txt" | Should -BeTrue
        }

        It 'copies only the exact previewed set rather than every wildcard match' {
            New-TestFile "$SourceDir\InRange.txt" -LastWriteTime '2024-05-01'
            New-TestFile "$SourceDir\OutOfRange.txt" -LastWriteTime '2030-01-01'

            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-FileName', '*.txt', '-EndDate', '2024-12-31', '-Force', '-LogFolder', $LogDir
            )

            $result.ExitCode | Should -Be 0
            (Get-ChildItem $DestDir -File).Name | Should -Be 'InRange.txt'
            Test-Path -LiteralPath "$DestDir\OutOfRange.txt" | Should -BeFalse
        }

        It 'uses the default wildcard to include extensionless files' {
            New-TestFile "$SourceDir\LICENSE" -LastWriteTime '2024-05-01'

            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-Force', '-LogFolder', $LogDir
            )

            $result.ExitCode | Should -Be 0
            Test-Path -LiteralPath "$DestDir\LICENSE" | Should -BeTrue
        }
    }

    Context 'Interactive prompts' {

        It 'prompts for missing paths without PowerShell mandatory-parameter banner noise' {
            New-TestFile "$SourceDir\File1.txt" -LastWriteTime '2024-05-01'

            $result = Invoke-CopyFromToInteractive -Answers @($SourceDir, $DestDir) -ScriptArgs @(
                '-FileName', '*.txt', '-Force', '-LogFolder', $LogDir
            )

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Not -Match 'cmdlet .* at command pipeline position'
            Test-Path -LiteralPath "$DestDir\File1.txt" | Should -BeTrue
            $result.Output | Should -Match 'finished with exit status 0\.\r?\n(?:\r?\n)+$'
        }

        It 'supports the historical CopyFromTo-CLAUDE.ps1 launch name without banner noise' {
            New-TestFile "$SourceDir\File1.txt" -LastWriteTime '2024-05-01'

            $result = Invoke-CopyFromToInteractive -ExecutableScript $script:CompatibilityLauncherPath `
                -Answers @($SourceDir, $DestDir) -ScriptArgs @(
                    '-FileName', '*.txt', '-Force', '-LogFolder', $LogDir
                )

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Not -Match 'cmdlet .* at command pipeline position'
            Test-Path -LiteralPath "$DestDir\File1.txt" | Should -BeTrue
        }

        It 'parses a MM/yyyy date typed at the date-range prompt' {
            # Regression test: an earlier version threw "Cannot find an overload for
            # TryParseExact" here under Windows PowerShell 5.1, because the [ref] target
            # started as untyped $null instead of [datetime]::MinValue, and separately
            # because an uncast @(...) format-array literal (Object[], not string[])
            # made TryParseExact silently return $false instead of throwing. Both bugs
            # only showed up on the interactive path, which every other test bypasses via
            # -Force / explicit -StartDate -EndDate - hence a dedicated prompt-driving
            # test rather than relying on coverage from the other contexts.
            # -Force is deliberately NOT passed - it would skip the very prompts this
            # test needs to exercise. The destination is pre-created so the "create
            # destination?" prompt doesn't consume an answer meant for a later prompt.
            New-TestFile "$SourceDir\Photo1.jpg" -LastWriteTime '2024-05-15'
            New-Item -ItemType Directory -Path $DestDir -Force | Out-Null

            # Answers, one per Read-Host call: file pattern, start month/year,
            # end month/year (blank = unbounded), then "y" to confirm the copy.
            $result = Invoke-CopyFromToInteractive -Answers @('*.jpg', '05/2024', '', 'y') -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir, '-LogFolder', $LogDir
            )

            $result.ExitCode | Should -Be 0
            Test-Path -LiteralPath "$DestDir\Photo1.jpg" | Should -BeTrue
        }

        It 'logs exit status 3 when the user cancels' {
            New-TestFile "$SourceDir\File1.txt" -LastWriteTime '2024-05-01'
            New-Item -ItemType Directory -Path $DestDir -Force | Out-Null

            $result = Invoke-CopyFromToInteractive -Answers @('*.txt', '', '', 'n') -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir, '-LogFolder', $LogDir
            )

            $result.ExitCode | Should -Be 3
            $scriptLog = Get-ChildItem -LiteralPath $LogDir -Filter 'CopyFromTo_*.log' | Where-Object Name -NotLike '*_robocopy.log'
            (Get-Content -LiteralPath $scriptLog.FullName -Raw) | Should -Match 'finished with exit status 3'
        }
    }

    Context 'Dry run' {

        It 'does not copy anything and does not create a missing destination folder' {
            New-TestFile "$SourceDir\File1.txt" -LastWriteTime '2024-05-01'

            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-FileName', '*.txt', '-StartDate', '2024-01-01', '-EndDate', '2024-12-31',
                '-DryRun', '-Force', '-LogFolder', $LogDir
            )

            $result.ExitCode | Should -Be 0
            Test-Path -LiteralPath $DestDir | Should -BeFalse
        }

        It 'supports the standard -WhatIf common parameter without changing the destination' {
            New-TestFile "$SourceDir\File1.txt" -LastWriteTime '2024-05-01'

            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-FileName', '*.txt', '-Force', '-WhatIf', '-LogFolder', $LogDir
            )

            $result.ExitCode | Should -Be 0
            Test-Path -LiteralPath $DestDir | Should -BeFalse
            $result.Output | Should -Match 'WHATIF'
        }
    }

    Context 'No matches' {

        It 'exits 0 and copies nothing when no files match the filters' {
            New-TestFile "$SourceDir\Report1.txt" -LastWriteTime '2024-05-01'

            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-FileName', '*.pdf', '-Force', '-LogFolder', $LogDir
            )

            $result.ExitCode | Should -Be 0
            if (Test-Path -LiteralPath $DestDir) {
                (Get-ChildItem $DestDir -File).Count | Should -Be 0
            }
        }
    }

    Context 'Error handling' {

        It 'exits 2 when the source folder does not exist' {
            $missingSource = Join-Path $script:CaseRoot 'DoesNotExist'

            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $missingSource, '-Destination', $DestDir,
                '-FileName', '*.*', '-Force', '-LogFolder', $LogDir
            )

            $result.ExitCode | Should -Be 2
        }

        It 'rejects a start date later than the end date' {
            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-FileName', '*', '-StartDate', '2025-01-01', '-EndDate', '2024-01-01',
                '-Force', '-LogFolder', $LogDir
            )
            $result.ExitCode | Should -Be 2
            $result.Output | Should -Match 'cannot be later'
        }

        It 'rejects a normalized empty file-pattern list' {
            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-FileName', ',,', '-Force', '-LogFolder', $LogDir
            )
            $result.ExitCode | Should -Be 2
            $result.Output | Should -Match 'non-empty file name'
        }

        It 'flags a real copy failure when a destination file is locked by another process' -Tag 'Slow' {
            # Robocopy retries a locked file 3 times with a 5s wait (see /R:3 /W:5 in
            # CopyFromTo.ps1), so this test takes roughly 15-20 seconds.
            New-TestFile "$SourceDir\Locked.txt" -Content 'source version' -LastWriteTime '2024-05-01'
            New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
            $destFile = Join-Path $DestDir 'Locked.txt'
            Set-Content -LiteralPath $destFile -Value 'stale destination version' -NoNewline
            (Get-Item -LiteralPath $destFile).LastWriteTime = '2020-01-01'

            $lockStream = [System.IO.File]::Open($destFile, 'Open', 'ReadWrite', 'None')
            try {
                $result = Invoke-CopyFromTo -ScriptArgs @(
                    '-Source', $SourceDir, '-Destination', $DestDir,
                    '-FileName', '*.txt', '-Force', '-LogFolder', $LogDir
                )
            }
            finally {
                $lockStream.Dispose()
            }

            $result.ExitCode | Should -Be 2
        }
    }

    Context 'Destination handling' {

        It 'auto-creates a missing destination folder when -Force is used' {
            New-TestFile "$SourceDir\File1.txt" -LastWriteTime '2024-05-01'
            Test-Path -LiteralPath $DestDir | Should -BeFalse

            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-FileName', '*.txt', '-Force', '-LogFolder', $LogDir
            )

            $result.ExitCode | Should -Be 0
            Test-Path -LiteralPath "$DestDir\File1.txt" | Should -BeTrue
        }

        It 'supports relative source and destination paths' {
            New-TestFile "$SourceDir\File1.txt" -LastWriteTime '2024-05-01'
            $relativeSource = [System.IO.Path]::GetFileName($SourceDir)
            $relativeDestination = 'RelativeDest'
            $relativeLogs = 'RelativeLogs'

            $result = Invoke-CopyFromTo -WorkingDirectory $script:CaseRoot -ScriptArgs @(
                '-Source', $relativeSource, '-Destination', $relativeDestination,
                '-FileName', '*.txt', '-Force', '-LogFolder', $relativeLogs
            )

            $result.ExitCode | Should -Be 0
            Test-Path -LiteralPath (Join-Path $script:CaseRoot 'RelativeDest\File1.txt') | Should -BeTrue
        }

        It 'rejects identical source and destination paths' {
            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $SourceDir,
                '-FileName', '*', '-Force', '-LogFolder', $LogDir
            )
            $result.ExitCode | Should -Be 2
            $result.Output | Should -Match 'must be different'
        }

        It 'rejects a destination nested inside the source tree' {
            $nestedDestination = Join-Path $SourceDir 'Backup'
            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $nestedDestination,
                '-FileName', '*', '-Recurse', '-Force', '-LogFolder', $LogDir
            )
            $result.ExitCode | Should -Be 2
            $result.Output | Should -Match 'cannot be inside source'
        }
    }

    Context 'Recurse' {

        It 'copies only top-level files when -Recurse is omitted' {
            New-TestFile "$SourceDir\Top.txt" -LastWriteTime '2024-05-01'
            New-TestFile "$SourceDir\Sub\Nested.txt" -LastWriteTime '2024-05-01'

            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-FileName', '*.txt', '-Force', '-LogFolder', $LogDir
            )

            $result.ExitCode | Should -Be 0
            Test-Path -LiteralPath "$DestDir\Top.txt" | Should -BeTrue
            Test-Path -LiteralPath "$DestDir\Sub\Nested.txt" | Should -BeFalse
        }

        It 'copies files from subfolders, preserving relative path, when -Recurse is used' {
            New-TestFile "$SourceDir\Top.txt" -LastWriteTime '2024-05-01'
            New-TestFile "$SourceDir\Sub\Nested.txt" -LastWriteTime '2024-05-01'

            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-FileName', '*.txt', '-Recurse', '-Force', '-LogFolder', $LogDir
            )

            $result.ExitCode | Should -Be 0
            Test-Path -LiteralPath "$DestDir\Top.txt" | Should -BeTrue
            Test-Path -LiteralPath "$DestDir\Sub\Nested.txt" | Should -BeTrue
        }

        It 'skips directory reparse points by default' {
            New-TestFile "$SourceDir\Top.txt" -LastWriteTime '2024-05-01'
            $externalDir = Join-Path $script:CaseRoot 'External'
            New-TestFile "$externalDir\Linked.txt" -LastWriteTime '2024-05-01'
            $junction = Join-Path $SourceDir 'Linked'
            New-Item -ItemType Junction -Path $junction -Target $externalDir | Out-Null

            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-FileName', '*.txt', '-Recurse', '-Force', '-LogFolder', $LogDir
            )

            $result.ExitCode | Should -Be 0
            Test-Path -LiteralPath "$DestDir\Top.txt" | Should -BeTrue
            Test-Path -LiteralPath "$DestDir\Linked\Linked.txt" | Should -BeFalse
            $result.Output | Should -Match 'Skipping reparse-point directory'
        }
    }

    Context 'Logging' {

        It 'writes a script log and a robocopy log for each run' {
            New-TestFile "$SourceDir\File1.txt" -LastWriteTime '2024-05-01'

            $null = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-FileName', '*.txt', '-Force', '-LogFolder', $LogDir
            )

            $logs = Get-ChildItem -LiteralPath $LogDir -Filter 'CopyFromTo_*.log'
            ($logs | Where-Object Name -NotLike '*_robocopy.log').Count | Should -Be 1
            ($logs | Where-Object Name -Like '*_robocopy.log').Count | Should -Be 1
        }

        It 'records a verification success line in the script log after a clean copy' {
            New-TestFile "$SourceDir\File1.txt" -LastWriteTime '2024-05-01'

            $null = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-FileName', '*.txt', '-Force', '-LogFolder', $LogDir
            )

            $scriptLog = Get-ChildItem -LiteralPath $LogDir -Filter 'CopyFromTo_*.log' | Where-Object Name -NotLike '*_robocopy.log'
            (Get-Content -LiteralPath $scriptLog.FullName -Raw) | Should -Match 'Verification passed'
        }

        It 'uses collision-resistant log names for rapid consecutive runs' {
            New-TestFile "$SourceDir\File1.txt" -LastWriteTime '2024-05-01'
            1..2 | ForEach-Object {
                $null = Invoke-CopyFromTo -ScriptArgs @(
                    '-Source', $SourceDir, '-Destination', $DestDir,
                    '-FileName', '*.txt', '-Force', '-LogFolder', $LogDir
                )
            }
            (Get-ChildItem -LiteralPath $LogDir -Filter 'CopyFromTo_*.log').Count | Should -Be 4
        }

        It 'removes expired logs only when retention is explicitly enabled' {
            New-TestFile "$SourceDir\File1.txt" -LastWriteTime '2024-05-01'
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
            $oldLog = Join-Path $LogDir 'CopyFromTo_20000101_000000.log'
            Set-Content -LiteralPath $oldLog -Value 'old'
            (Get-Item $oldLog).LastWriteTime = (Get-Date).AddDays(-30)

            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-FileName', '*.txt', '-Force', '-LogFolder', $LogDir, '-LogRetentionDays', '7'
            )
            $result.ExitCode | Should -Be 0
            Test-Path -LiteralPath $oldLog | Should -BeFalse
        }
    }

    Context 'Verification and transfer controls' {

        It 'supports SHA-256 hash verification and structured pass-through output' {
            New-TestFile "$SourceDir\File1.txt" -Content 'hash me' -LastWriteTime '2024-05-01'
            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-FileName', '*.txt', '-Force', '-VerificationMode', 'Hash', '-PassThru',
                '-LogFolder', $LogDir
            )
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'VerificationMode.*Hash'
        }

        It 'honors configurable retry, wait, and thread settings' {
            New-TestFile "$SourceDir\File1.txt" -LastWriteTime '2024-05-01'
            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-FileName', '*.txt', '-Force', '-RetryCount', '1', '-RetryWait', '1', '-Threads', '2',
                '-LogFolder', $LogDir
            )
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '/R:1'
            $result.Output | Should -Match '/W:1'
            $result.Output | Should -Match '/MT:2'
        }

        It 'limits the console preview without limiting the actual transfer' {
            1..3 | ForEach-Object { New-TestFile "$SourceDir\File$_.txt" -LastWriteTime '2024-05-01' }
            $result = Invoke-CopyFromTo -ScriptArgs @(
                '-Source', $SourceDir, '-Destination', $DestDir,
                '-FileName', '*.txt', '-Force', '-PreviewLimit', '1', '-LogFolder', $LogDir
            )
            $result.ExitCode | Should -Be 0
            (Get-ChildItem $DestDir -File).Count | Should -Be 3
            $result.Output | Should -Match '2 additional match'
        }
    }

    Context 'Script metadata' {

        It 'exposes comment-based help with a synopsis' {
            $help = Get-Help $script:ScriptPath
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }

        It '-Help prints parameter descriptions and exits 0 without prompting for Source/Destination' {
            # -Help lives in its own parameter set so help stays isolated from operational
            # parameters and cannot trigger interactive path prompts.
            $result = Invoke-CopyFromTo -ScriptArgs @('-Help')

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'SYNOPSIS'
            $result.Output | Should -Match '-Source'
            $result.Output | Should -Match '-Destination'
            $result.Output | Should -Match '-FileName'
            $result.Output | Should -Match '-VerificationMode'
        }

        It 'parses and displays help under Windows PowerShell 5.1 when available' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
            $output = & powershell.exe -NoProfile -NonInteractive -File $script:ScriptPath -Help 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $output | Should -Match 'SYNOPSIS'
            $output | Should -Match '-VerificationMode'
        }

        It 'completes a functional copy under Windows PowerShell 5.1 when available' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
            New-TestFile "$SourceDir\WinPS.txt" -LastWriteTime '2024-05-01'
            $output = & powershell.exe -NoProfile -NonInteractive -File $script:ScriptPath `
                -Source $SourceDir -Destination $DestDir -FileName '*.txt' -Force -LogFolder $LogDir 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            Test-Path -LiteralPath "$DestDir\WinPS.txt" | Should -BeTrue
            $output | Should -Match 'Verification passed'
        }
    }
}
