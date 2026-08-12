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
        $output | Should -Match "Title='CopyFromTo \(Picnic Time\)'"
        $output | Should -Match 'Themes=Light,Dark'
        $output | Should -Match 'DarkContrast=True'
        $output | Should -Match 'OutputLayout=True'
        $output | Should -Match 'RenderMode=SoftwareOnly'
        $output | Should -Match 'IsolatedHost=True'
        $output | Should -Match 'OutputCapture=True'
        $output | Should -Match 'Controls=28'
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
