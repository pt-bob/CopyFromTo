BeforeAll {
    $script:SizeScriptPath = (Resolve-Path (
            Join-Path $PSScriptRoot '..\TotalFileSize-of-DateRange.ps1'
        )).Path
    $script:PowerShellExe = (Get-Process -Id $PID).Path

    function Invoke-SizeScript {
        param([hashtable]$Parameters)

        & $script:SizeScriptPath @Parameters -PassThru
    }
}

Describe 'TotalFileSize-of-DateRange' {
    BeforeEach {
        $testFolder = Join-Path $TestDrive 'Files'
        $nestedFolder = Join-Path $testFolder 'Nested'
        New-Item -ItemType Directory -Path $nestedFolder -Force | Out-Null

        $inRange = Join-Path $testFolder 'InRange.bin'
        $outOfRange = Join-Path $testFolder 'OutOfRange.bin'
        $nested = Join-Path $nestedFolder 'Nested.bin'
        [IO.File]::WriteAllBytes($inRange, [byte[]](1..10))
        [IO.File]::WriteAllBytes($outOfRange, [byte[]](1..20))
        [IO.File]::WriteAllBytes($nested, [byte[]](1..30))
        (Get-Item -LiteralPath $inRange).LastWriteTime = '2026-01-15 12:00:00'
        (Get-Item -LiteralPath $outOfRange).LastWriteTime = '2025-12-31 23:59:59'
        (Get-Item -LiteralPath $nested).LastWriteTime = '2026-01-31 23:59:59'
    }

    It 'has valid PowerShell syntax' {
        $tokens = $null
        $parseErrors = $null
        [Management.Automation.Language.Parser]::ParseFile(
            $script:SizeScriptPath,
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null

        $parseErrors | Should -BeNullOrEmpty
    }

    It 'uses LastWriteTime and scans only the selected folder by default' {
        $result = Invoke-SizeScript @{
            FolderPath = $testFolder
            StartDate  = '2026-01-01'
            EndDate    = '2026-01-31'
        }

        $result.DateProperty | Should -Be 'LastWriteTime'
        $result.FileCount | Should -Be 1
        $result.TotalBytes | Should -Be 10
        $result.Recursive | Should -BeFalse
    }

    It 'includes subfolders and the entire end date when Recurse is selected' {
        $result = Invoke-SizeScript @{
            FolderPath = $testFolder
            StartDate  = '2026-01-01'
            EndDate    = '2026-01-31'
            Recurse    = $true
        }

        $result.FileCount | Should -Be 2
        $result.TotalBytes | Should -Be 40
        $result.Recursive | Should -BeTrue
    }

    It 'reports zero files and zero bytes when nothing matches' {
        $result = Invoke-SizeScript @{
            FolderPath = $testFolder
            StartDate  = '2024-01-01'
            EndDate    = '2024-01-31'
        }

        $result.FileCount | Should -Be 0
        $result.TotalBytes | Should -Be 0
    }

    It 'adds visual spacing around human-readable output without polluting PassThru' {
        $displayOutput = & $script:PowerShellExe -NoProfile -NonInteractive -File `
            $script:SizeScriptPath -FolderPath $testFolder `
            -StartDate '2026-01-01' -EndDate '2026-01-31' 6>&1
        $structuredOutput = Invoke-SizeScript @{
            FolderPath = $testFolder
            StartDate  = '2026-01-01'
            EndDate    = '2026-01-31'
        }

        $LASTEXITCODE | Should -Be 0
        $displayOutput.Count | Should -BeGreaterOrEqual 3
        $displayOutput[0] | Should -BeNullOrEmpty
        $displayOutput[-1] | Should -BeNullOrEmpty
        ($displayOutput -join "`n") | Should -Match 'Scanning\.\.\. done \(2 files checked\)\.'
        ($displayOutput -join "`n") | Should -Match 'SUCCESS: Files: 1'
        $structuredOutput.Count | Should -Be 1
        $structuredOutput[0].PSTypeNames | Should -Contain 'System.Management.Automation.PSCustomObject'
    }

    It 'uses green success and red failure status lines' {
        $scriptText = Get-Content -LiteralPath $script:SizeScriptPath -Raw
        $missingFolder = Join-Path $TestDrive 'MissingForColorTest'
        $failureOutput = & $script:PowerShellExe -NoProfile -NonInteractive -File `
            $script:SizeScriptPath -FolderPath $missingFolder `
            -StartDate '2026-01-01' -EndDate '2026-01-31' 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $scriptText | Should -Match "(?s)'SUCCESS:.+?-ForegroundColor Green"
        $scriptText | Should -Match 'FAILED:.+Exception\.Message'
        $scriptText | Should -Match 'ForegroundColor Red'
        $failureOutput | Should -Match 'FAILED:'
    }

    It 'colors only interactive user input yellow and restores the host color' {
        $scriptText = Get-Content -LiteralPath $script:SizeScriptPath -Raw

        $scriptText | Should -Match 'function Read-ColoredInput'
        $scriptText | Should -Match 'Write-Host "\$\{Prompt\}: " -NoNewline'
        $scriptText | Should -Match 'ForegroundColor = \[ConsoleColor\]::Yellow'
        $scriptText | Should -Match 'ForegroundColor = \$originalForeground'
        $scriptText | Should -Match 'Read-ColoredInput -Prompt \$Prompt'
    }

    It 'accepts the maximum supported end date without overflowing' {
        $result = Invoke-SizeScript @{
            FolderPath = $testFolder
            StartDate  = '2026-01-01'
            EndDate    = '9999-12-31'
        }

        $result.FileCount | Should -Be 1
        $result.TotalBytes | Should -Be 10
    }

    It 'rejects an invalid ISO date' {
        $output = & $script:PowerShellExe -NoProfile -NonInteractive -File `
            $script:SizeScriptPath -FolderPath $testFolder `
            -StartDate '01/01/2026' -EndDate '2026-01-31' 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'yyyy-MM-dd'
    }

    It 'rejects a reversed date range' {
        $output = & $script:PowerShellExe -NoProfile -NonInteractive -File `
            $script:SizeScriptPath -FolderPath $testFolder `
            -StartDate '2026-02-01' -EndDate '2026-01-31' 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'Beginning date cannot be later'
    }

    It 'rejects a missing folder' {
        $missingFolder = Join-Path $TestDrive 'Missing'
        $output = & $script:PowerShellExe -NoProfile -NonInteractive -File `
            $script:SizeScriptPath -FolderPath $missingFolder `
            -StartDate '2026-01-01' -EndDate '2026-01-31' 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'not accessible'
    }
}
