<#
.SYNOPSIS
    Builds CopyFromTo.exe from the WPF front end and copy engine.

.DESCRIPTION
    Uses the PS2EXE module to compile CopyFromTo-UI.ps1 as a 64-bit, STA, no-console
    Windows executable. The unchanged CopyFromTo.ps1 engine is Base64-encoded and
    injected into a temporary build input, then compiled into the EXE. At runtime the
    application verifies and materializes a private temporary engine copy, so the final
    executable has no companion-file dependency.

.PARAMETER OutputPath
    Destination EXE path. Defaults to .\dist\CopyFromTo.exe.

.PARAMETER IconPath
    Optional .ico file to embed as the application icon.

.PARAMETER Version
    Four-part Windows file version. Defaults to 1.1.0.0. The executable title bar
    displays its major and minor components.

.PARAMETER InstallDependency
    Installs the required PS2EXE version from PowerShell Gallery for the current user if
    it is not already installed. Without this switch, a missing dependency is reported
    without changing the machine.

.PARAMETER Ps2ExeVersion
    Exact PS2EXE module version used for the build. Defaults to 1.0.18.

.PARAMETER CreateZip
    Creates CopyFromTo-<Version>.zip beside the deployment folder.

.EXAMPLE
    .\Build-Executable.ps1 -InstallDependency

.EXAMPLE
    .\Build-Executable.ps1 -IconPath .\Assets\CopyFromTo.ico -Version 1.2.0.0
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'dist\CopyFromTo.exe'),
    [string]$IconPath,

    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string]$Version = '1.1.0.0',

    [switch]$InstallDependency,

    [ValidatePattern('^\d+\.\d+\.\d+(?:\.\d+)?$')]
    [string]$Ps2ExeVersion = '1.0.18',

    [switch]$CreateZip
)

$ErrorActionPreference = 'Stop'
$uiPath = Join-Path $PSScriptRoot 'CopyFromTo-UI.ps1'
$enginePath = Join-Path $PSScriptRoot 'CopyFromTo.ps1'

foreach ($requiredFile in @($uiPath, $enginePath)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required build input not found: '$requiredFile'."
    }
}

$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if ($IconPath) {
    $IconPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($IconPath)
    if (-not (Test-Path -LiteralPath $IconPath -PathType Leaf)) {
        throw "Icon file not found: '$IconPath'."
    }
    if ([IO.Path]::GetExtension($IconPath) -ne '.ico') {
        throw "IconPath must reference a Windows .ico file: '$IconPath'."
    }
}

$module = Get-Module -ListAvailable -Name ps2exe |
    Where-Object { $_.Version -eq [version]$Ps2ExeVersion } |
    Select-Object -First 1
if (-not $module -and $InstallDependency) {
    Write-Host "Installing PS2EXE $Ps2ExeVersion for the current user..." -ForegroundColor Cyan
    Install-Module -Name ps2exe -RequiredVersion $Ps2ExeVersion -Scope CurrentUser `
        -Repository PSGallery -ErrorAction Stop
    $module = Get-Module -ListAvailable -Name ps2exe |
        Where-Object { $_.Version -eq [version]$Ps2ExeVersion } |
        Select-Object -First 1
}
if (-not $module) {
    throw "PS2EXE $Ps2ExeVersion is required. Run '.\Build-Executable.ps1 -InstallDependency' or install it with 'Install-Module ps2exe -RequiredVersion $Ps2ExeVersion -Scope CurrentUser'."
}

Import-Module $module.Path -Force -ErrorAction Stop
$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
$staleConfigPath = "$OutputPath.config"
if (Test-Path -LiteralPath $staleConfigPath -PathType Leaf) {
    Remove-Item -LiteralPath $staleConfigPath -Force
}

$engineBytes = [IO.File]::ReadAllBytes($enginePath)
$engineBase64 = [Convert]::ToBase64String($engineBytes)
$engineSha256 = (Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash
$uiSource = [IO.File]::ReadAllText($uiPath)
$packagedModeTokenLine = '$script:IsPackagedExecutable = $false'
$applicationVersionTokenLine = '$script:ApplicationVersion = ''1.1.0.0'''
$base64TokenLine = '$script:EmbeddedEngineBase64 = ''__COPYFROMTO_ENGINE_BASE64__'''
$hashTokenLine = '$script:EmbeddedEngineSha256 = ''__COPYFROMTO_ENGINE_SHA256__'''
if (($uiSource.Split([string[]]@($packagedModeTokenLine), [StringSplitOptions]::None).Count - 1) -ne 1 -or
    ($uiSource.Split([string[]]@($applicationVersionTokenLine), [StringSplitOptions]::None).Count - 1) -ne 1 -or
    ($uiSource.Split([string[]]@($base64TokenLine), [StringSplitOptions]::None).Count - 1) -ne 1 -or
    ($uiSource.Split([string[]]@($hashTokenLine), [StringSplitOptions]::None).Count - 1) -ne 1) {
    throw 'The UI packaging markers are missing or duplicated.'
}
$packagedUiSource = $uiSource.Replace(
    $packagedModeTokenLine,
    '$script:IsPackagedExecutable = $true'
).Replace(
    $applicationVersionTokenLine,
    "`$script:ApplicationVersion = '$Version'"
).Replace(
    $base64TokenLine,
    "`$script:EmbeddedEngineBase64 = '$engineBase64'"
).Replace(
    $hashTokenLine,
    "`$script:EmbeddedEngineSha256 = '$engineSha256'"
)

$stagingDirectory = Join-Path ([IO.Path]::GetTempPath()) "CopyFromTo.Build.$([guid]::NewGuid().ToString('N'))"
$stagedUiPath = Join-Path $stagingDirectory 'CopyFromTo-UI.Standalone.ps1'
New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null
[IO.File]::WriteAllText($stagedUiPath, $packagedUiSource, [Text.UTF8Encoding]::new($false))

$parsedBuildVersion = [version]$Version
$displayVersion = '{0}.{1}' -f $parsedBuildVersion.Major, $parsedBuildVersion.Minor
$compileParameters = @{
    InputFile   = $stagedUiPath
    OutputFile  = $OutputPath
    X64         = $true
    STA         = $true
    NoConsole   = $true
    NoConfigFile = $true
    DPIAware    = $true
    SupportOS   = $true
    Title       = "CopyFromTo v$displayVersion (Picnic Time)"
    Description = 'Desktop interface for safe, verified file copying'
    Company     = 'Picnic Time'
    Product     = 'CopyFromTo'
    Copyright   = "Copyright (c) $((Get-Date).Year) Picnic Time"
    Version     = $Version
}
if ($IconPath) { $compileParameters.IconFile = $IconPath }

Write-Host "Building '$OutputPath' with PS2EXE $Ps2ExeVersion..." -ForegroundColor Cyan
try {
    Invoke-ps2exe @compileParameters
}
finally {
    if (Test-Path -LiteralPath $stagingDirectory) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
    throw "PS2EXE completed without creating '$OutputPath'."
}

$obsoleteCompanionPath = Join-Path $outputDirectory 'CopyFromTo.ps1'
if (Test-Path -LiteralPath $obsoleteCompanionPath -PathType Leaf) {
    Remove-Item -LiteralPath $obsoleteCompanionPath -Force
}

if ($CreateZip) {
    $zipPath = Join-Path (Split-Path -Parent $outputDirectory) "CopyFromTo-$Version.zip"
    if (Test-Path -LiteralPath $zipPath -PathType Leaf) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -LiteralPath $OutputPath -DestinationPath $zipPath `
        -CompressionLevel Optimal
    Write-Host "ZIP package: $zipPath" -ForegroundColor Green
}

$artifact = Get-Item -LiteralPath $OutputPath
Write-Host "Build complete: $($artifact.FullName) ($($artifact.Length) bytes)" -ForegroundColor Green
Write-Host "Embedded engine SHA-256: $engineSha256" -ForegroundColor Green
Write-Output $artifact
