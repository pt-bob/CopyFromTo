<#
.SYNOPSIS
    Opens a desktop user interface for CopyFromTo.ps1.

.DESCRIPTION
    CopyFromTo-UI.ps1 is a WPF front end for the existing CopyFromTo.ps1 command-line
    tool. It collects options, launches the CLI script in a separate PowerShell process,
    and displays its output. All file selection, copying, logging, and verification
    remain in CopyFromTo.ps1.

.PARAMETER ValidateOnly
    Loads and validates the UI definition without opening a window or copying files.
    Intended for automated tests and deployment checks.

.PARAMETER Help
    Displays this help text and exits.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$ValidateOnly,
    [switch]$Help,

    # Internal recursion guard used by the public launcher. Keeping WPF in its own
    # process prevents a native UI/rendering failure from terminating the caller's shell.
    [Parameter(DontShow)]
    [switch]$UiHost
)

$ErrorActionPreference = 'Stop'
# Build-Executable.ps1 changes this exact assignment to $true only in its
# temporary compilation source. The checked-in script always remains in source mode.
$script:IsPackagedExecutable = $false
$script:EmbeddedEngineBase64 = '__COPYFROMTO_ENGINE_BASE64__'
$script:EmbeddedEngineSha256 = '__COPYFROMTO_ENGINE_SHA256__'
$script:RuntimeEngineFolder = $null
$script:ApplicationRoot = if ($script:IsPackagedExecutable) {
    [AppDomain]::CurrentDomain.BaseDirectory.TrimEnd([char[]]@('\', '/'))
}
else {
    $PSScriptRoot
}

if ($Help) {
    if ($PSCommandPath) {
        Get-Help -Detailed $PSCommandPath
    }
    else {
        Write-Output 'Use CopyFromTo.exe -? -detailed to display the packaged application help.'
    }
    exit 0
}

$script:EnginePath = if ($script:IsPackagedExecutable) {
    if ($script:EmbeddedEngineBase64 -eq '__COPYFROMTO_ENGINE_BASE64__') {
        Write-Error 'The executable does not contain its copy engine. Rebuild it with Build-Executable.ps1.'
        exit 2
    }

    $script:RuntimeEngineFolder = Join-Path ([IO.Path]::GetTempPath()) "PicnicTime.CopyFromTo\$PID-$([guid]::NewGuid().ToString('N'))"
    $runtimeEnginePath = Join-Path $script:RuntimeEngineFolder 'CopyFromTo.ps1'
    try {
        New-Item -ItemType Directory -Path $script:RuntimeEngineFolder -Force | Out-Null
        [IO.File]::WriteAllBytes(
            $runtimeEnginePath,
            [Convert]::FromBase64String($script:EmbeddedEngineBase64)
        )
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $runtimeEngineHash = [BitConverter]::ToString(
                $sha256.ComputeHash([IO.File]::ReadAllBytes($runtimeEnginePath))
            ).Replace('-', '')
        }
        finally {
            $sha256.Dispose()
        }
        if ($runtimeEngineHash -ne $script:EmbeddedEngineSha256) {
            throw 'The embedded copy engine failed its integrity check.'
        }
        $runtimeEnginePath
    }
    catch {
        if ($script:RuntimeEngineFolder -and (Test-Path -LiteralPath $script:RuntimeEngineFolder)) {
            Remove-Item -LiteralPath $script:RuntimeEngineFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Error "Could not prepare the embedded copy engine. $($_.Exception.Message)"
        exit 2
    }
}
else {
    Join-Path $script:ApplicationRoot 'CopyFromTo.ps1'
}
if (-not (Test-Path -LiteralPath $script:EnginePath -PathType Leaf)) {
    Write-Error "Copy engine not found: '$script:EnginePath'. Rebuild the executable or keep CopyFromTo-UI.ps1 beside CopyFromTo.ps1."
    exit 2
}

function Remove-RuntimeEngine {
    if ($script:RuntimeEngineFolder -and (Test-Path -LiteralPath $script:RuntimeEngineFolder)) {
        Remove-Item -LiteralPath $script:RuntimeEngineFolder -Recurse -Force -ErrorAction SilentlyContinue
        $script:RuntimeEngineFolder = $null
    }
}

# Always isolate the interactive UI from the terminal, even when the caller already
# happens to be STA. The child has no visible console; only the WPF window is shown.
if (-not $script:IsPackagedExecutable -and -not $ValidateOnly -and -not $UiHost) {
    try {
        $powerShellExe = (Get-Process -Id $PID).Path
        $quotedScriptPath = '"' + $PSCommandPath.Replace('"', '\"') + '"'
        Start-Process -FilePath $powerShellExe -WindowStyle Hidden -ArgumentList @(
            '-NoLogo', '-NoProfile', '-STA', '-File', $quotedScriptPath, '-UiHost'
        ) -ErrorAction Stop
        exit 0
    }
    catch {
        Write-Error "Could not start the isolated CopyFromTo UI process. $($_.Exception.Message)"
        exit 2
    }
}

# Layout validation creates an invisible real window and therefore also needs STA.
# Run it synchronously so its output and exit code remain available to callers/tests.
if (-not $script:IsPackagedExecutable -and $ValidateOnly -and [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $powerShellExe = (Get-Process -Id $PID).Path
    & $powerShellExe -NoLogo -NoProfile -STA -File $PSCommandPath -ValidateOnly -UiHost
    exit $LASTEXITCODE
}

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    # Win32 error 1816 can be raised while WPF allocates a hardware render target.
    # This utility does not need GPU acceleration; software rendering is more robust
    # across remote sessions, constrained desktops, and graphics-driver resets.
    [Windows.Media.RenderOptions]::ProcessRenderMode = [Windows.Interop.RenderMode]::SoftwareOnly
    if (-not ('CopyFromToUi.ProcessOutputCollector' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;

namespace CopyFromToUi
{
    public sealed class ProcessOutputCollector : IDisposable
    {
        private Process process;
        public ConcurrentQueue<string> Lines { get; private set; }

        public ProcessOutputCollector()
        {
            Lines = new ConcurrentQueue<string>();
        }

        public void Attach(Process target)
        {
            if (target == null) throw new ArgumentNullException("target");
            if (process != null) throw new InvalidOperationException("The collector is already attached.");
            process = target;
            process.OutputDataReceived += OnDataReceived;
            process.ErrorDataReceived += OnDataReceived;
        }

        private void OnDataReceived(object sender, DataReceivedEventArgs eventArgs)
        {
            if (eventArgs.Data != null) Lines.Enqueue(eventArgs.Data);
        }

        public void Dispose()
        {
            if (process != null)
            {
                process.OutputDataReceived -= OnDataReceived;
                process.ErrorDataReceived -= OnDataReceived;
                process = null;
            }
        }
    }
}
'@ -ErrorAction Stop
    }
}
catch {
    Write-Error "The CopyFromTo desktop UI requires Windows with WPF available. $($_.Exception.Message)"
    exit 2
}

# The isolated host is explicitly started with -STA. Fail with a controlled message if
# a host ignores that request rather than allowing WPF to fail unpredictably.
if (-not $ValidateOnly -and [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Write-Error 'The isolated CopyFromTo UI process did not start in STA mode.'
    exit 2
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="CopyFromTo (Picnic Time)" Width="1120" Height="780" MinWidth="940" MinHeight="650"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource AppBackgroundBrush}" FontFamily="Segoe UI"
        TextOptions.TextFormattingMode="Display">
    <Window.Resources>
        <SolidColorBrush x:Key="AccentBrush" Color="#2563EB" />
        <SolidColorBrush x:Key="AccentHoverBrush" Color="#1D4ED8" />
        <SolidColorBrush x:Key="BorderBrush" Color="#D7DCE2" />
        <SolidColorBrush x:Key="AppBackgroundBrush" Color="#F4F6F8" />
        <SolidColorBrush x:Key="SurfaceBrush" Color="#FFFFFF" />
        <SolidColorBrush x:Key="InputBackgroundBrush" Color="#FFFFFF" />
        <SolidColorBrush x:Key="TextBrush" Color="#26303D" />
        <SolidColorBrush x:Key="HeadingBrush" Color="#152033" />
        <SolidColorBrush x:Key="MutedTextBrush" Color="#637083" />
        <SolidColorBrush x:Key="OutputBackgroundBrush" Color="#FFFFFF" />
        <SolidColorBrush x:Key="OutputHeaderBrush" Color="#F8FAFC" />
        <SolidColorBrush x:Key="OutputTextBrush" Color="#26303D" />
        <SolidColorBrush x:Key="BadgeBackgroundBrush" Color="#E8F0FE" />
        <SolidColorBrush x:Key="BadgeTextBrush" Color="#1D4ED8" />
        <SolidColorBrush x:Key="SelectionBackgroundBrush" Color="#FFFFFF" />
        <SolidColorBrush x:Key="SelectionTextBrush" Color="#26303D" />
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="{DynamicResource TextBrush}" />
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="MinHeight" Value="34" />
            <Setter Property="Padding" Value="9,5" />
            <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}" />
            <Setter Property="Background" Value="{DynamicResource InputBackgroundBrush}" />
            <Setter Property="Foreground" Value="{DynamicResource TextBrush}" />
            <Setter Property="VerticalContentAlignment" Value="Center" />
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Height" Value="34" />
            <Setter Property="Padding" Value="7,4" />
            <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}" />
            <Setter Property="Background" Value="{DynamicResource SelectionBackgroundBrush}" />
            <Setter Property="Foreground" Value="{DynamicResource SelectionTextBrush}" />
        </Style>
        <Style TargetType="ComboBoxItem">
            <Setter Property="Background" Value="{DynamicResource SelectionBackgroundBrush}" />
            <Setter Property="Foreground" Value="{DynamicResource SelectionTextBrush}" />
        </Style>
        <Style TargetType="DatePicker">
            <Setter Property="Height" Value="34" />
            <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}" />
            <Setter Property="Background" Value="{DynamicResource InputBackgroundBrush}" />
            <Setter Property="Foreground" Value="{DynamicResource TextBrush}" />
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Margin" Value="0,5,16,5" />
            <Setter Property="Foreground" Value="{DynamicResource TextBrush}" />
        </Style>
        <Style x:Key="SecondaryButton" TargetType="Button">
            <Setter Property="Height" Value="36" />
            <Setter Property="Padding" Value="14,5" />
            <Setter Property="Background" Value="{DynamicResource SurfaceBrush}" />
            <Setter Property="Foreground" Value="{DynamicResource TextBrush}" />
            <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}" />
            <Setter Property="Cursor" Value="Hand" />
        </Style>
        <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource SecondaryButton}">
            <Setter Property="Background" Value="{StaticResource AccentBrush}" />
            <Setter Property="Foreground" Value="White" />
            <Setter Property="BorderBrush" Value="{StaticResource AccentBrush}" />
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="{StaticResource AccentHoverBrush}" />
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="FieldLabel" TargetType="TextBlock">
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Margin" Value="0,12,0,5" />
            <Setter Property="Foreground" Value="{DynamicResource TextBrush}" />
        </Style>
    </Window.Resources>

    <Grid Margin="22">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <Grid Grid.Row="0" Margin="2,0,2,18">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <StackPanel>
                <TextBlock Text="CopyFromTo" FontSize="28" FontWeight="SemiBold" Foreground="{DynamicResource HeadingBrush}" />
                <TextBlock Text="Copy files safely, then verify the result." FontSize="14" Foreground="{DynamicResource MutedTextBrush}" Margin="0,3,0,0" />
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="ThemeToggleButton" Content="Dark Mode" Style="{StaticResource SecondaryButton}" Margin="0,0,10,0" />
                <Border Background="{DynamicResource BadgeBackgroundBrush}" CornerRadius="12" Padding="12,6">
                    <TextBlock Text="Desktop UI" Foreground="{DynamicResource BadgeTextBrush}" FontWeight="SemiBold" />
                </Border>
            </StackPanel>
        </Grid>

        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="430" />
                <ColumnDefinition Width="18" />
                <ColumnDefinition Width="*" />
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="8">
                <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="20,14,20,20">
                    <StackPanel>
                        <TextBlock Text="Copy settings" FontSize="17" FontWeight="SemiBold" Margin="0,0,0,2" />

                        <TextBlock x:Name="SourceFolderLabel" Text="Source folder" Style="{StaticResource FieldLabel}" />
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <TextBox x:Name="SourceTextBox" ToolTip="Folder containing the files to copy" />
                            <Button x:Name="BrowseSourceButton" Grid.Column="1" Content="Browse…" Style="{StaticResource SecondaryButton}" Margin="8,0,0,0" />
                        </Grid>

                        <TextBlock Text="Destination folder" Style="{StaticResource FieldLabel}" />
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <TextBox x:Name="DestinationTextBox" ToolTip="Folder where matching files will be copied" />
                            <Button x:Name="BrowseDestinationButton" Grid.Column="1" Content="Browse…" Style="{StaticResource SecondaryButton}" Margin="8,0,0,0" />
                        </Grid>

                        <TextBlock Text="File names or patterns" Style="{StaticResource FieldLabel}" />
                        <TextBox x:Name="FileNameTextBox" Text="*" ToolTip="Comma-separated patterns, for example: *.pdf,Invoice*.xlsx" />
                        <TextBlock Text="Separate multiple patterns with commas." FontSize="11" Foreground="{DynamicResource MutedTextBrush}" Margin="1,4,0,0" />

                        <Grid Margin="0,6,0,0">
                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <StackPanel>
                                <CheckBox x:Name="UseStartDateCheckBox" Content="Start date" />
                                <DatePicker x:Name="StartDatePicker" IsEnabled="False" />
                            </StackPanel>
                            <StackPanel Grid.Column="2">
                                <CheckBox x:Name="UseEndDateCheckBox" Content="End date" />
                                <DatePicker x:Name="EndDatePicker" IsEnabled="False" />
                            </StackPanel>
                        </Grid>

                        <WrapPanel Margin="0,12,0,2">
                            <CheckBox x:Name="RecurseCheckBox" Content="Include subfolders" />
                            <CheckBox x:Name="FollowLinksCheckBox" Content="Follow junctions / links" />
                        </WrapPanel>

                        <TextBlock Text="Verification" Style="{StaticResource FieldLabel}" />
                        <ComboBox x:Name="VerificationComboBox" SelectedIndex="0">
                            <ComboBoxItem Content="Metadata (fast)" Tag="Metadata" />
                            <ComboBoxItem Content="SHA-256 hash (thorough)" Tag="Hash" />
                        </ComboBox>

                        <Expander x:Name="AdvancedExpander" Header="Advanced settings" Margin="0,16,0,0" Foreground="{DynamicResource TextBrush}">
                            <StackPanel Margin="0,8,0,0">
                                <Grid>
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                    <StackPanel>
                                        <TextBlock Text="Retries" Style="{StaticResource FieldLabel}" />
                                        <TextBox x:Name="RetryCountTextBox" Text="3" />
                                    </StackPanel>
                                    <StackPanel Grid.Column="2">
                                        <TextBlock Text="Wait (seconds)" Style="{StaticResource FieldLabel}" />
                                        <TextBox x:Name="RetryWaitTextBox" Text="5" />
                                    </StackPanel>
                                </Grid>
                                <Grid>
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                    <StackPanel>
                                        <TextBlock Text="Worker threads" Style="{StaticResource FieldLabel}" />
                                        <TextBox x:Name="ThreadsTextBox" Text="8" />
                                    </StackPanel>
                                    <StackPanel Grid.Column="2">
                                        <TextBlock Text="Timestamp tolerance" Style="{StaticResource FieldLabel}" />
                                        <TextBox x:Name="ToleranceTextBox" Text="2" ToolTip="Allowed timestamp difference in seconds" />
                                    </StackPanel>
                                </Grid>
                                <TextBlock Text="Preview limit (0 shows all)" Style="{StaticResource FieldLabel}" />
                                <TextBox x:Name="PreviewLimitTextBox" Text="100" />
                                <TextBlock Text="Log folder (optional)" Style="{StaticResource FieldLabel}" />
                                <Grid>
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                    <TextBox x:Name="LogFolderTextBox" />
                                    <Button x:Name="BrowseLogButton" Grid.Column="1" Content="Browse…" Style="{StaticResource SecondaryButton}" Margin="8,0,0,0" />
                                </Grid>
                            </StackPanel>
                        </Expander>
                    </StackPanel>
                </ScrollViewer>
            </Border>

            <Border Grid.Column="2" Background="{DynamicResource OutputHeaderBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="8">
                <Grid Margin="0">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid Grid.Row="0" Margin="16,12">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBlock Text="Operation output" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold" FontSize="15" />
                        <Button x:Name="ClearOutputButton" Grid.Column="1" Content="Clear" Foreground="{DynamicResource MutedTextBrush}" Background="Transparent" BorderThickness="0" Cursor="Hand" />
                    </Grid>
                    <TextBox x:Name="OutputTextBox" Grid.Row="1" IsReadOnly="True" AcceptsReturn="True"
                             VerticalAlignment="Stretch" HorizontalAlignment="Stretch"
                             VerticalContentAlignment="Top" HorizontalContentAlignment="Left"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                             TextWrapping="NoWrap" FontFamily="Consolas" FontSize="12" Background="{DynamicResource OutputBackgroundBrush}"
                             Foreground="{DynamicResource OutputTextBrush}" BorderThickness="0" Padding="14" />
                    <Border x:Name="OperationResultBorder" Grid.Row="2" Visibility="Collapsed"
                            Padding="14,11" CornerRadius="0,0,7,7">
                        <TextBlock x:Name="OperationResultTextBlock" Foreground="White" FontSize="18"
                                   FontWeight="Bold" TextAlignment="Center" />
                    </Border>
                </Grid>
            </Border>
        </Grid>

        <Grid Grid.Row="2" Margin="2,16,2,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <Ellipse x:Name="StatusIndicator" Width="9" Height="9" Fill="#22C55E" Margin="0,0,8,0" />
                <TextBlock x:Name="StatusTextBlock" Text="Ready" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center" />
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal">
                <Button x:Name="CancelButton" Content="Cancel" Style="{StaticResource SecondaryButton}" Width="82" Margin="0,0,8,0" IsEnabled="False" />
                <Button x:Name="PreviewButton" Content="Preview" Style="{StaticResource SecondaryButton}" Width="92" Margin="0,0,8,0" />
                <Button x:Name="CopyButton" Content="Copy files" Style="{StaticResource PrimaryButton}" Width="112" />
            </StackPanel>
        </Grid>
    </Grid>
</Window>
'@

try {
    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
}
catch {
    Write-Error "The CopyFromTo UI definition is invalid. $($_.Exception.Message)"
    exit 2
}

$requiredControls = @(
    'SourceFolderLabel', 'SourceTextBox', 'DestinationTextBox', 'FileNameTextBox', 'UseStartDateCheckBox',
    'UseEndDateCheckBox', 'StartDatePicker', 'EndDatePicker', 'RecurseCheckBox',
    'FollowLinksCheckBox', 'VerificationComboBox', 'RetryCountTextBox',
    'RetryWaitTextBox', 'ThreadsTextBox', 'ToleranceTextBox', 'PreviewLimitTextBox',
    'LogFolderTextBox', 'BrowseSourceButton', 'BrowseDestinationButton', 'BrowseLogButton',
    'ThemeToggleButton',
    'PreviewButton', 'CopyButton', 'CancelButton', 'ClearOutputButton', 'OutputTextBox',
    'OperationResultBorder', 'OperationResultTextBlock',
    'StatusTextBlock', 'StatusIndicator'
)
foreach ($controlName in $requiredControls) {
    $control = $window.FindName($controlName)
    if ($null -eq $control) {
        Write-Error "Required UI control '$controlName' was not found."
        exit 2
    }
    Set-Variable -Name $controlName -Value $control
}

Add-Type -AssemblyName System.Windows.Forms
$script:ActiveProcess = $null
$script:CancelRequested = $false
$script:OutputCollector = $null
$script:PowerShellExe = if ($script:IsPackagedExecutable) {
    Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}
else {
    (Get-Process -Id $PID).Path
}
if (-not (Test-Path -LiteralPath $script:PowerShellExe -PathType Leaf)) {
    Write-Error "PowerShell executable not found: '$script:PowerShellExe'."
    exit 2
}
$script:DarkMode = $false

function New-SolidColorBrush {
    param([Parameter(Mandatory)] [string]$Color)
    return [Windows.Media.SolidColorBrush]([Windows.Media.ColorConverter]::ConvertFromString($Color))
}

function Set-UiTheme {
    param([Parameter(Mandatory)] [ValidateSet('Light', 'Dark')] [string]$Theme)

    $palette = if ($Theme -eq 'Dark') {
        @{
            AppBackgroundBrush    = '#111827'
            SurfaceBrush          = '#1F2937'
            InputBackgroundBrush = '#111827'
            TextBrush             = '#F3F4F6'
            HeadingBrush          = '#FFFFFF'
            MutedTextBrush        = '#AAB4C3'
            BorderBrush           = '#465264'
            OutputBackgroundBrush = '#0B1220'
            OutputHeaderBrush     = '#172033'
            OutputTextBrush       = '#DCE3EC'
            BadgeBackgroundBrush  = '#1E3A5F'
            BadgeTextBrush        = '#93C5FD'
        }
    }
    else {
        @{
            AppBackgroundBrush    = '#F4F6F8'
            SurfaceBrush          = '#FFFFFF'
            InputBackgroundBrush = '#FFFFFF'
            TextBrush             = '#26303D'
            HeadingBrush          = '#152033'
            MutedTextBrush        = '#637083'
            BorderBrush           = '#D7DCE2'
            OutputBackgroundBrush = '#FFFFFF'
            OutputHeaderBrush     = '#F8FAFC'
            OutputTextBrush       = '#26303D'
            BadgeBackgroundBrush  = '#E8F0FE'
            BadgeTextBrush        = '#1D4ED8'
        }
    }

    foreach ($resourceName in $palette.Keys) {
        $window.Resources[$resourceName] = New-SolidColorBrush $palette[$resourceName]
    }
    $script:DarkMode = $Theme -eq 'Dark'
    $ThemeToggleButton.Content = if ($script:DarkMode) { 'Light Mode' } else { 'Dark Mode' }
}

if ($ValidateOnly) {
    # Exercise both palettes so validation covers runtime resource replacement as well
    # as XAML loading, without displaying the window. Exercise the native output
    # collector too; unlike PowerShell event jobs, it continues receiving data while
    # WPF owns the UI runspace.
    Set-UiTheme 'Dark'
    if ($ThemeToggleButton.Content -ne 'Light Mode') { throw 'Dark theme validation failed.' }
    if ($SourceFolderLabel.Foreground.Color.ToString() -ne '#FFF3F4F6') {
        throw "Dark field-label contrast validation failed: $($SourceFolderLabel.Foreground.Color)."
    }
    if ($VerificationComboBox.Foreground.Color.ToString() -ne '#FF26303D') {
        throw "Dark selection contrast validation failed: $($VerificationComboBox.Foreground.Color)."
    }
    Set-UiTheme 'Light'
    if ($ThemeToggleButton.Content -ne 'Dark Mode') { throw 'Light theme validation failed.' }

    $OutputTextBox.Text = 'output-visibility-probe'
    $window.ShowActivated = $false
    $window.ShowInTaskbar = $false
    $window.Opacity = 0
    try {
        $window.Show()
        $window.UpdateLayout()
        $validatedOutputHeight = $OutputTextBox.ActualHeight
    }
    finally {
        $window.Close()
    }
    if ($validatedOutputHeight -lt 300 -or $OutputTextBox.Text -ne 'output-visibility-probe') {
        throw "Output layout validation failed: height=$validatedOutputHeight, text='$($OutputTextBox.Text)'."
    }
    $OutputTextBox.Clear()

    $captureProcess = [Diagnostics.Process]::new()
    $captureProcess.StartInfo = [Diagnostics.ProcessStartInfo]::new()
    $captureProcess.StartInfo.FileName = $env:ComSpec
    $captureProcess.StartInfo.Arguments = '/d /c "echo collector-stdout & echo collector-stderr 1>&2"'
    $captureProcess.StartInfo.UseShellExecute = $false
    $captureProcess.StartInfo.CreateNoWindow = $true
    $captureProcess.StartInfo.RedirectStandardOutput = $true
    $captureProcess.StartInfo.RedirectStandardError = $true
    $captureCollector = [CopyFromToUi.ProcessOutputCollector]::new()
    try {
        $captureCollector.Attach($captureProcess)
        if (-not $captureProcess.Start()) { throw 'Output collector test process did not start.' }
        $captureProcess.BeginOutputReadLine()
        $captureProcess.BeginErrorReadLine()
        $captureProcess.WaitForExit()
        $capturedLines = [Collections.Generic.List[string]]::new()
        [string]$capturedLine = $null
        while ($captureCollector.Lines.TryDequeue([ref]$capturedLine)) {
            $capturedLines.Add($capturedLine)
            $capturedLine = $null
        }
        $normalizedCapturedLines = @($capturedLines | ForEach-Object { $_.Trim() })
        if ('collector-stdout' -notin $normalizedCapturedLines -or 'collector-stderr' -notin $normalizedCapturedLines) {
            throw "Output collector validation failed. Captured: $($capturedLines -join ', ')"
        }
    }
    finally {
        $captureCollector.Dispose()
        $captureProcess.Dispose()
    }
    Write-Output "CopyFromTo UI validation passed. Title='$($window.Title)'; Themes=Light,Dark; DarkContrast=True; OutputLayout=True; RenderMode=$([Windows.Media.RenderOptions]::ProcessRenderMode); IsolatedHost=True; Packaged=$script:IsPackagedExecutable; OutputCapture=True; Engine='$script:EnginePath'; Controls=$($requiredControls.Count)."
    Remove-RuntimeEngine
    exit 0
}

$script:UiErrorLog = Join-Path ([IO.Path]::GetTempPath()) 'CopyFromTo-UI-error.log'
function Write-UiFailureLog {
    param([Parameter(Mandatory)] [Exception]$Exception)
    try {
        $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $($Exception.ToString())"
        Add-Content -LiteralPath $script:UiErrorLog -Value $entry -ErrorAction SilentlyContinue
    }
    catch { }
}

# Handle exceptions raised by controls or the WPF dispatcher so they close only the
# isolated UI host. Native process-corruption failures still cannot affect the terminal.
$window.Dispatcher.Add_UnhandledException({
    param($sender, $eventArgs)
    Write-UiFailureLog $eventArgs.Exception
    $eventArgs.Handled = $true
    try {
        [Windows.MessageBox]::Show(
            "The desktop interface encountered an error and will close.`n`nDetails were written to:`n$script:UiErrorLog",
            'CopyFromTo UI error', 'OK', 'Error'
        ) | Out-Null
    }
    catch { }
    try { $window.Close() } catch { }
})

function Add-OutputLine {
    param([string]$Text = '')
    $OutputTextBox.AppendText($Text + [Environment]::NewLine)
    $OutputTextBox.ScrollToEnd()
}

function Clear-OperationResult {
    $OperationResultTextBlock.Text = ''
    $OperationResultBorder.Visibility = 'Collapsed'
}

function Set-OperationResult {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Success', 'Failed')]
        [string]$Result,

        [Parameter(Mandatory)]
        [string]$Detail
    )

    $succeeded = $Result -eq 'Success'
    $OperationResultTextBlock.Text = "$(if ($succeeded) { 'SUCCESS' } else { 'FAILED' }) - $Detail"
    $OperationResultBorder.Background = if ($succeeded) { '#15803D' } else { '#B91C1C' }
    $OperationResultBorder.Visibility = 'Visible'
}

function Set-UiRunningState {
    param([bool]$Running)
    $PreviewButton.IsEnabled = -not $Running
    $CopyButton.IsEnabled = -not $Running
    $CancelButton.IsEnabled = $Running
    $StatusIndicator.Fill = if ($Running) { '#F59E0B' } else { '#22C55E' }
}

function Remove-ProcessOutputCollector {
    if ($script:OutputCollector) {
        $script:OutputCollector.Dispose()
        $script:OutputCollector = $null
    }
}

function Select-Folder {
    param([string]$InitialPath)
    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = 'Select a folder'
    $dialog.ShowNewFolderButton = $true
    if ($InitialPath -and (Test-Path -LiteralPath $InitialPath -PathType Container)) {
        $dialog.SelectedPath = $InitialPath
    }
    try {
        if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
            return $dialog.SelectedPath
        }
    }
    finally {
        $dialog.Dispose()
    }
    return $null
}

function ConvertTo-CommandLineArgument {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }

    $builder = [Text.StringBuilder]::new()
    $null = $builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            $null = $builder.Append(('\' * (($backslashes * 2) + 1)) + '"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            $null = $builder.Append('\' * $backslashes)
            $backslashes = 0
        }
        $null = $builder.Append($character)
    }
    if ($backslashes -gt 0) { $null = $builder.Append('\' * ($backslashes * 2)) }
    $null = $builder.Append('"')
    return $builder.ToString()
}

function Get-ValidatedInteger {
    param(
        [Windows.Controls.TextBox]$TextBox,
        [string]$Label,
        [int]$Minimum,
        [int]$Maximum
    )
    [int]$value = 0
    if (-not [int]::TryParse($TextBox.Text.Trim(), [ref]$value) -or $value -lt $Minimum -or $value -gt $Maximum) {
        throw "$Label must be a whole number from $Minimum through $Maximum."
    }
    return $value
}

function Get-OperationArguments {
    param([switch]$Preview)

    $source = $SourceTextBox.Text.Trim()
    $destination = $DestinationTextBox.Text.Trim()
    $patterns = $FileNameTextBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($source)) { throw 'Choose a source folder.' }
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "The source folder does not exist: '$source'." }
    if ([string]::IsNullOrWhiteSpace($destination)) { throw 'Choose a destination folder.' }
    if ([string]::IsNullOrWhiteSpace($patterns)) { throw 'Enter at least one file name or wildcard pattern.' }

    $retryCount = Get-ValidatedInteger $RetryCountTextBox 'Retries' 0 1000000
    $retryWait = Get-ValidatedInteger $RetryWaitTextBox 'Retry wait' 0 3600
    $threads = Get-ValidatedInteger $ThreadsTextBox 'Worker threads' 1 128
    $tolerance = Get-ValidatedInteger $ToleranceTextBox 'Timestamp tolerance' 0 300
    $previewLimit = Get-ValidatedInteger $PreviewLimitTextBox 'Preview limit' 0 1000000

    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.AddRange([string[]]@(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:EnginePath,
        '-Source', $source, '-Destination', $destination, '-FileName', $patterns,
        '-VerificationMode', [string]$VerificationComboBox.SelectedItem.Tag,
        '-RetryCount', [string]$retryCount, '-RetryWait', [string]$retryWait,
        '-Threads', [string]$threads, '-TimestampToleranceSeconds', [string]$tolerance,
        '-PreviewLimit', [string]$previewLimit, '-Force'
    ))
    if ($UseStartDateCheckBox.IsChecked) {
        if (-not $StartDatePicker.SelectedDate) { throw 'Choose a start date or clear the Start date checkbox.' }
        $arguments.AddRange([string[]]@('-StartDate', $StartDatePicker.SelectedDate.Value.ToString('yyyy-MM-dd')))
    }
    if ($UseEndDateCheckBox.IsChecked) {
        if (-not $EndDatePicker.SelectedDate) { throw 'Choose an end date or clear the End date checkbox.' }
        $arguments.AddRange([string[]]@('-EndDate', $EndDatePicker.SelectedDate.Value.ToString('yyyy-MM-dd')))
    }
    if ($UseStartDateCheckBox.IsChecked -and $UseEndDateCheckBox.IsChecked -and
        $StartDatePicker.SelectedDate.Value.Date -gt $EndDatePicker.SelectedDate.Value.Date) {
        throw 'Start date cannot be later than end date.'
    }
    if ($RecurseCheckBox.IsChecked) { $arguments.Add('-Recurse') }
    if ($FollowLinksCheckBox.IsChecked) { $arguments.Add('-FollowReparsePoint') }
    if ($Preview) { $arguments.Add('-DryRun') }
    $logFolder = $LogFolderTextBox.Text.Trim()
    if ($logFolder) { $arguments.AddRange([string[]]@('-LogFolder', $logFolder)) }
    return $arguments.ToArray()
}

function Start-CopyOperation {
    param([switch]$Preview)
    try {
        $arguments = Get-OperationArguments -Preview:$Preview
    }
    catch {
        [Windows.MessageBox]::Show($_.Exception.Message, 'Check the settings', 'OK', 'Warning') | Out-Null
        return
    }

    if (-not $Preview) {
        $confirmation = [Windows.MessageBox]::Show(
            "Copy matching files now?`n`nFrom: $($SourceTextBox.Text.Trim())`nTo:   $($DestinationTextBox.Text.Trim())",
            'Confirm copy', 'YesNo', 'Question'
        )
        if ($confirmation -ne 'Yes') { return }
    }

    $OutputTextBox.Clear()
    Clear-OperationResult
    Add-OutputLine ('> ' + (Split-Path -Leaf $script:PowerShellExe) + ' ' + (($arguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '))
    Add-OutputLine

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $script:PowerShellExe
    $startInfo.Arguments = ($arguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $collector = [CopyFromToUi.ProcessOutputCollector]::new()

    try {
        $collector.Attach($process)
        if (-not $process.Start()) { throw 'PowerShell did not start the copy process.' }
        $script:ActiveProcess = $process
        $script:OutputCollector = $collector
        $script:CancelRequested = $false
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
        Set-UiRunningState $true
        $StatusTextBlock.Text = if ($Preview) { 'Building preview…' } else { 'Copy in progress…' }
    }
    catch {
        $collector.Dispose()
        $process.Dispose()
        Set-OperationResult -Result Failed -Detail 'The copy process could not be started.'
        [Windows.MessageBox]::Show("Could not start CopyFromTo.ps1. $($_.Exception.Message)", 'Launch failed', 'OK', 'Error') | Out-Null
    }
}

$UseStartDateCheckBox.Add_Checked({ $StartDatePicker.IsEnabled = $true })
$UseStartDateCheckBox.Add_Unchecked({ $StartDatePicker.IsEnabled = $false })
$UseEndDateCheckBox.Add_Checked({ $EndDatePicker.IsEnabled = $true })
$UseEndDateCheckBox.Add_Unchecked({ $EndDatePicker.IsEnabled = $false })
$FollowLinksCheckBox.Add_Checked({
    if (-not $RecurseCheckBox.IsChecked) { $RecurseCheckBox.IsChecked = $true }
})
$BrowseSourceButton.Add_Click({
    $selected = Select-Folder $SourceTextBox.Text.Trim()
    if ($selected) { $SourceTextBox.Text = $selected }
})
$BrowseDestinationButton.Add_Click({
    $selected = Select-Folder $DestinationTextBox.Text.Trim()
    if ($selected) { $DestinationTextBox.Text = $selected }
})
$BrowseLogButton.Add_Click({
    $selected = Select-Folder $LogFolderTextBox.Text.Trim()
    if ($selected) { $LogFolderTextBox.Text = $selected }
})
$ThemeToggleButton.Add_Click({
    Set-UiTheme $(if ($script:DarkMode) { 'Light' } else { 'Dark' })
})
$ClearOutputButton.Add_Click({
    $OutputTextBox.Clear()
    Clear-OperationResult
})
$PreviewButton.Add_Click({ Start-CopyOperation -Preview })
$CopyButton.Add_Click({ Start-CopyOperation })
$CancelButton.Add_Click({
    if ($script:ActiveProcess -and -not $script:ActiveProcess.HasExited) {
        $script:CancelRequested = $true
        $StatusTextBlock.Text = 'Cancelling…'
        try {
            & taskkill.exe /PID $script:ActiveProcess.Id /T /F 2>$null | Out-Null
        }
        catch {
            try { $script:ActiveProcess.Kill() } catch { }
        }
    }
})

$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(120)
$timer.Add_Tick({
    [string]$line = $null
    while ($script:OutputCollector -and $script:OutputCollector.Lines.TryDequeue([ref]$line)) {
        Add-OutputLine $line
        $line = $null
    }
    if ($script:ActiveProcess -and $script:ActiveProcess.HasExited) {
        $script:ActiveProcess.WaitForExit()
        while ($script:OutputCollector -and $script:OutputCollector.Lines.TryDequeue([ref]$line)) {
            Add-OutputLine $line
            $line = $null
        }
        $exitCode = $script:ActiveProcess.ExitCode
        Remove-ProcessOutputCollector
        $script:ActiveProcess.Dispose()
        $script:ActiveProcess = $null
        Set-UiRunningState $false
        if ($script:CancelRequested) {
            Add-OutputLine
            Add-OutputLine 'Operation cancelled.'
            $StatusTextBlock.Text = 'Cancelled'
            $StatusIndicator.Fill = '#EF4444'
            Set-OperationResult -Result Failed -Detail 'Operation cancelled.'
        }
        elseif ($exitCode -eq 0) {
            $StatusTextBlock.Text = 'Completed successfully'
            $StatusIndicator.Fill = '#22C55E'
            Set-OperationResult -Result Success -Detail 'Operation completed successfully.'
        }
        else {
            Add-OutputLine
            Add-OutputLine "CopyFromTo exited with status $exitCode. Review the output above."
            $StatusTextBlock.Text = "Finished with errors (exit $exitCode)"
            $StatusIndicator.Fill = '#EF4444'
            Set-OperationResult -Result Failed -Detail "CopyFromTo exited with status $exitCode."
        }
    }
})
$timer.Start()
Set-UiTheme 'Light'

$window.Add_Closing({
    param($sender, $eventArgs)
    if ($script:ActiveProcess -and -not $script:ActiveProcess.HasExited) {
        $choice = [Windows.MessageBox]::Show('A copy operation is still running. Cancel it and close?', 'Copy in progress', 'YesNo', 'Warning')
        if ($choice -ne 'Yes') {
            $eventArgs.Cancel = $true
            return
        }
        try { & taskkill.exe /PID $script:ActiveProcess.Id /T /F 2>$null | Out-Null } catch { }
    }
    Remove-ProcessOutputCollector
    $timer.Stop()
})

try {
    $null = $window.ShowDialog()
}
catch {
    Write-UiFailureLog $_.Exception
    try {
        [Windows.MessageBox]::Show(
            "The desktop interface could not continue.`n`nDetails were written to:`n$script:UiErrorLog",
            'CopyFromTo UI error', 'OK', 'Error'
        ) | Out-Null
    }
    catch { }
    exit 2
}
finally {
    Remove-RuntimeEngine
}
