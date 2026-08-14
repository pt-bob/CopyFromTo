BeforeAll {
    $script:UiPath = (Resolve-Path (Join-Path $PSScriptRoot '..\CopyFromTo-UI.ps1')).Path
    $script:PowerShellExe = (Get-Process -Id $PID).Path
}

Describe 'CopyFromTo desktop UI' {
    It 'has valid PowerShell syntax' {
        $tokens = $null
        $parseErrors = $null
        [Management.Automation.Language.Parser]::ParseFile(
            $script:UiPath,
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null

        $parseErrors | Should -BeNullOrEmpty
    }

    It 'loads the WPF definition and finds every required control' {
        $output = & $script:PowerShellExe -NoProfile -NonInteractive -File $script:UiPath -ValidateOnly 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'UI validation passed'
        $output | Should -Match "Title='CopyFromTo v1\.1 \(Picnic Time\)'"
        $output | Should -Match 'Themes=Light,Dark'
        $output | Should -Match 'DarkContrast=True'
        $output | Should -Match 'DateFilters=True'
        $output | Should -Match 'ActivityIndicator=True'
        $output | Should -Match 'PreviewSummary=True'
        $output | Should -Match 'OutputLayout=True'
        $output | Should -Match 'RenderMode=SoftwareOnly'
        $output | Should -Match 'IsolatedHost=True'
        $output | Should -Match 'OutputCapture=True'
        $output | Should -Match 'Controls=36'
    }

    It 'shows a green SUCCESS or red FAILED banner after an operation' {
        $uiText = Get-Content -LiteralPath $script:UiPath -Raw

        $uiText | Should -Match 'OperationResultBorder'
        $uiText | Should -Match "'SUCCESS'"
        $uiText | Should -Match "'FAILED'"
        $uiText | Should -Match "'#15803D'"
        $uiText | Should -Match "'#B91C1C'"
    }

    It 'requires confirmation before copying to a missing destination folder' {
        $uiText = Get-Content -LiteralPath $script:UiPath -Raw

        $uiText | Should -Match 'Test-Path -LiteralPath \$destination -PathType Container'
        $uiText | Should -Match 'The destination folder does not exist:'
        $uiText | Should -Match 'Create the folder and start copying\?'
        $uiText | Should -Match "'Create destination folder\?', 'YesNo', 'Warning'"
        $uiText | Should -Match 'if \(\$confirmation -ne ''Yes''\) \{ return \}'
    }

    It 'uses PowerShell-compatible WPF date values when building arguments' {
        $uiText = Get-Content -LiteralPath $script:UiPath -Raw

        $uiText | Should -Not -Match 'SelectedDate\.Value'
        $uiText | Should -Match "SelectedDate\.ToString\('yyyy-MM-dd'\)"
        $uiText | Should -Match 'SelectedDate\.Date'
    }

    It 'keeps long operations visibly active and output rendering bounded' {
        $uiText = Get-Content -LiteralPath $script:UiPath -Raw

        $uiText | Should -Match 'ActivityProgressBar.+IsIndeterminate="True"'
        $uiText | Should -Match 'Foreground="#22C55E"'
        $uiText | Should -Match 'ElapsedTextBlock'
        $uiText | Should -Match 'Diagnostics\.Stopwatch\]::StartNew\(\)'
        $uiText | Should -Match 'function Write-ProcessOutputBatch'
        $uiText | Should -Match '\[int\]\$MaximumLines = 200'
        $uiText | Should -Match 'Write-ProcessOutputBatch -MaximumLines 400'
    }

    It 'displays the application version in the title bar' {
        $uiText = Get-Content -LiteralPath $script:UiPath -Raw

        $uiText | Should -Match "ApplicationVersion = '1\.1\.0\.0'"
        $uiText | Should -Match "CopyFromTo v\{0\}\.\{1\} \(Picnic Time\)"
        $uiText | Should -Match 'parsedApplicationVersion\.Major'
        $uiText | Should -Match 'parsedApplicationVersion\.Minor'
    }

    It 'shows an exact, prominent summary after a successful preview' {
        $uiText = Get-Content -LiteralPath $script:UiPath -Raw

        $uiText | Should -Match 'PreviewSummaryBorder'
        $uiText | Should -Match 'PREVIEW SUMMARY'
        $uiText | Should -Match 'PreviewSummaryCountTextBlock'
        $uiText | Should -Match 'PreviewSummarySizeTextBlock'
        $uiText | Should -Match "'-PreviewSummaryPath'"
        $uiText | Should -Match 'Show-PreviewSummary -Path \$previewSummaryPath'
        $uiText | Should -Match 'SchemaVersion.+-ne 1'
        $uiText | Should -Match 'Remove-PreviewSummaryFile'
    }

    It 'invalidates a preview summary when matching settings change' {
        $uiText = Get-Content -LiteralPath $script:UiPath -Raw

        $uiText | Should -Match '\$SourceTextBox\.Add_TextChanged\(\{ Clear-PreviewSummary \}\)'
        $uiText | Should -Match '\$FileNameTextBox\.Add_TextChanged\(\{ Clear-PreviewSummary \}\)'
        $uiText | Should -Match '\$StartDatePicker\.Add_SelectedDateChanged\(\{ Clear-PreviewSummary \}\)'
        $uiText | Should -Match '\$RecurseCheckBox\.Add_Checked\(\{ Clear-PreviewSummary \}\)'
    }

    It 'cancels the child process tree and restores the controls after completion' {
        $uiText = Get-Content -LiteralPath $script:UiPath -Raw

        $uiText | Should -Match 'x:Name="CancelButton".+Width="138"'
        $uiText | Should -Match 'taskkill\.exe /PID \$script:ActiveProcess\.Id /T /F'
        $uiText | Should -Match '\$CancelButton\.Content = ''Cancelling'
        $uiText | Should -Match 'Complete-CopyOperation'
        $uiText | Should -Match 'Set-UiRunningState \$false'
    }

    It 'provides command-line help without opening the window' {
        $output = & $script:PowerShellExe -NoProfile -NonInteractive -File $script:UiPath -Help 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'SYNOPSIS'
        $output | Should -Match 'ValidateOnly'
    }

    It 'validates under Windows PowerShell 5.1 when available' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        $output = & powershell.exe -NoProfile -NonInteractive -File $script:UiPath -ValidateOnly 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'UI validation passed'
    }
}
