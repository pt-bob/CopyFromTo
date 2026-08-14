BeforeAll {
    $script:BuildPath = (Resolve-Path (Join-Path $PSScriptRoot '..\Build-Executable.ps1')).Path
    $script:UiPath = (Resolve-Path (Join-Path $PSScriptRoot '..\CopyFromTo-UI.ps1')).Path
}

Describe 'CopyFromTo executable build support' {
    It 'has valid PowerShell syntax' {
        foreach ($path in @($script:BuildPath, $script:UiPath)) {
            $tokens = $null
            $parseErrors = $null
            [Management.Automation.Language.Parser]::ParseFile(
                $path,
                [ref]$tokens,
                [ref]$parseErrors
            ) | Out-Null
            $parseErrors | Should -BeNullOrEmpty
        }
    }

    It 'pins the compiler and injects the unchanged copy engine into staged source' {
        $buildText = Get-Content -LiteralPath $script:BuildPath -Raw

        $buildText | Should -Match "Ps2ExeVersion = '1\.0\.18'"
        $buildText | Should -Match "Version = '1\.1\.0\.0'"
        $buildText | Should -Match 'applicationVersionTokenLine'
        $buildText | Should -Match 'CopyFromTo v\$displayVersion \(Picnic Time\)'
        $buildText | Should -Match 'ToBase64String\(\$engineBytes\)'
        $buildText | Should -Match 'IsPackagedExecutable = \$true'
        $buildText | Should -Match 'EmbeddedEngineBase64'
        $buildText | Should -Match 'EmbeddedEngineSha256'
        $buildText | Should -Match 'CopyFromTo-UI\.Standalone\.ps1'
        $buildText | Should -Match 'NoConsole\s+= \$true'
        $buildText | Should -Match 'STA\s+= \$true'
        $buildText | Should -Match 'NoConfigFile\s+= \$true'
    }

    It 'contains packaged-runtime fallbacks for the application root and PowerShell host' {
        $uiText = Get-Content -LiteralPath $script:UiPath -Raw

        $uiText | Should -Match 'IsPackagedExecutable'
        $uiText | Should -Match 'CurrentDomain\.BaseDirectory'
        $uiText | Should -Match 'WindowsPowerShell\\v1\.0\\powershell\.exe'
        $uiText | Should -Match 'FromBase64String\(\$script:EmbeddedEngineBase64\)'
        $uiText | Should -Match 'Security\.Cryptography\.SHA256'
        $uiText | Should -Match 'ComputeHash\(\[IO\.File\]::ReadAllBytes\(\$runtimeEnginePath\)\)'
        $uiText | Should -Match 'Remove-RuntimeEngine'
    }
}
