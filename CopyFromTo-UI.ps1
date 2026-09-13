<#
.SYNOPSIS
    Opens a desktop user interface for CopyFromTo.ps1.

.DESCRIPTION
    CopyFromTo-UI.ps1 is a WPF front end for the existing CopyFromTo.ps1 command-line
    tool. It collects options, including either a name/date filter or an explicit file
    list, launches the CLI script in a separate PowerShell process, and displays its
    output. All file selection, copying, logging, and verification remain in
    CopyFromTo.ps1.

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
$script:ApplicationVersion = '1.3.0.0'
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
            '-NoLogo', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
            '-File', $quotedScriptPath, '-UiHost'
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
    & $powerShellExe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath -ValidateOnly -UiHost
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
using System.Runtime.InteropServices;

namespace CopyFromToUi
{
    public static class FolderPicker
    {
        private const uint FOS_NOCHANGEDIR = 0x00000008;
        private const uint FOS_PICKFOLDERS = 0x00000020;
        private const uint FOS_FORCEFILESYSTEM = 0x00000040;
        private const uint FOS_PATHMUSTEXIST = 0x00000800;
        private const uint SIGDN_FILESYSPATH = 0x80058000;
        private const int HRESULT_CANCELLED = unchecked((int)0x800704C7);

        [ComImport]
        [Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
        private class FileOpenDialogRCW { }

        [ComImport]
        [Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellItem
        {
            void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
            void GetParent(out IShellItem ppsi);
            void GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
            void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
            void Compare(IShellItem psi, uint hint, out int piOrder);
        }

        [ComImport]
        [Guid("42F85136-DB7E-439C-85F1-E4075D135FC8")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IFileOpenDialog
        {
            [PreserveSig] int Show(IntPtr parent);
            void SetFileTypes();
            void SetFileTypeIndex();
            void GetFileTypeIndex();
            void Advise();
            void Unadvise();
            void SetOptions(uint fos);
            void GetOptions(out uint pfos);
            void SetDefaultFolder(IShellItem psi);
            void SetFolder(IShellItem psi);
            void GetFolder();
            void GetCurrentSelection();
            void SetFileName();
            void GetFileName();
            void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
            void SetOkButtonLabel();
            void SetFileNameLabel();
            void GetResult(out IShellItem ppsi);
            void AddPlace();
            void SetDefaultExtension();
            void Close();
            void SetClientGuid();
            void ClearClientData();
            void SetFilter();
            void GetResults();
            void GetSelectedItems();
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHCreateItemFromParsingName(
            [MarshalAs(UnmanagedType.LPWStr)] string pszPath,
            IntPtr pbc,
            [In] ref Guid riid,
            [MarshalAs(UnmanagedType.Interface)] out IShellItem ppv);

        public static string SelectFolder(string title, string initialPath, IntPtr owner)
        {
            IFileOpenDialog dialog = (IFileOpenDialog)new FileOpenDialogRCW();
            try
            {
                uint options;
                dialog.GetOptions(out options);
                dialog.SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR);
                if (!string.IsNullOrEmpty(title)) dialog.SetTitle(title);
                if (!string.IsNullOrEmpty(initialPath))
                {
                    try
                    {
                        Guid shellItemIid = typeof(IShellItem).GUID;
                        IShellItem folder;
                        SHCreateItemFromParsingName(initialPath, IntPtr.Zero, ref shellItemIid, out folder);
                        dialog.SetFolder(folder);
                    }
                    catch { }
                }

                int hr = dialog.Show(owner);
                if (hr == HRESULT_CANCELLED) return null;
                if (hr != 0) Marshal.ThrowExceptionForHR(hr);

                IShellItem result;
                dialog.GetResult(out result);
                string path;
                result.GetDisplayName(SIGDN_FILESYSPATH, out path);
                return path;
            }
            finally
            {
                Marshal.ReleaseComObject(dialog);
            }
        }
    }

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
        Title="CopyFromTo" Width="1120" Height="780" MinWidth="940" MinHeight="650"
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
                <Button x:Name="ThemeToggleButton" Content="Dark Mode" Style="{StaticResource SecondaryButton}" />
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

                        <TextBlock Text="What to copy" Style="{StaticResource FieldLabel}" />
                        <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
                            <RadioButton x:Name="FilterModeRadio" GroupName="CopySelectionMode" Content="Filter by name and date" IsChecked="True" Margin="0,0,16,0" />
                            <RadioButton x:Name="SpecificFilesModeRadio" GroupName="CopySelectionMode" Content="Choose specific files" />
                        </StackPanel>

                        <StackPanel x:Name="FilterModePanel">
                            <TextBlock Text="File names or patterns" Style="{StaticResource FieldLabel}" />
                            <TextBox x:Name="FileNameTextBox" ToolTip="Comma-separated patterns, for example: *.pdf,Invoice*.xlsx. Use * for all files." />
                            <TextBlock Text="Separate multiple patterns with commas. Use * for all files." FontSize="11" Foreground="{DynamicResource MutedTextBrush}" Margin="1,4,0,0" />

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
                        </StackPanel>

                        <StackPanel x:Name="SpecificFilesPanel" Visibility="Collapsed">
                            <TextBlock Text="Selected files" Style="{StaticResource FieldLabel}" />
                            <ListBox x:Name="SpecificFilesListBox" MinHeight="120" MaxHeight="180"
                                     SelectionMode="Extended"
                                     BorderBrush="{DynamicResource BorderBrush}"
                                     Background="{DynamicResource InputBackgroundBrush}"
                                     Foreground="{DynamicResource TextBrush}" />
                            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
                                <Button x:Name="AddFilesButton" Content="Add files…" Style="{StaticResource SecondaryButton}" Margin="0,0,8,0" />
                                <Button x:Name="RemoveFilesButton" Content="Remove" Style="{StaticResource SecondaryButton}" />
                            </StackPanel>
                            <TextBlock Text="Files must be inside the source folder. Subfolders are kept at the destination."
                                       FontSize="11" Foreground="{DynamicResource MutedTextBrush}" TextWrapping="Wrap" Margin="1,6,0,0" />
                        </StackPanel>

                        <WrapPanel x:Name="RecurseOptionsPanel" Margin="0,12,0,2">
                            <CheckBox x:Name="RecurseCheckBox" Content="Include subfolders" />
                            <CheckBox x:Name="FollowLinksCheckBox" Content="Follow junctions / links" />
                        </WrapPanel>

                        <TextBlock Text="Verification" Style="{StaticResource FieldLabel}" />
                        <ComboBox x:Name="VerificationComboBox" SelectedIndex="0">
                            <ComboBoxItem Content="Metadata (fast)" Tag="Metadata" />
                            <ComboBoxItem Content="SHA-256 hash (thorough)" Tag="Hash" />
                        </ComboBox>

                        <Border Margin="0,14,0,0" Padding="11,9" CornerRadius="6"
                                BorderBrush="#D97706" BorderThickness="1"
                                Background="{DynamicResource InputBackgroundBrush}">
                            <StackPanel>
                                <CheckBox x:Name="DeleteSourceCheckBox"
                                          Content="Delete source files after verified copy"
                                          FontWeight="SemiBold" />
                                <TextBlock Text="Optional and destructive. A current Preview and a separate confirmation are required. Only the exact copied files are eligible; folders are never removed."
                                           FontSize="11" Foreground="{DynamicResource MutedTextBrush}"
                                           TextWrapping="Wrap" Margin="21,5,0,0" />
                            </StackPanel>
                        </Border>

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
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid Grid.Row="0" Margin="16,12">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBlock Text="Operation output" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold" FontSize="15" />
                        <Button x:Name="ClearOutputButton" Grid.Column="1" Content="Clear" Foreground="{DynamicResource MutedTextBrush}" Background="Transparent" BorderThickness="0" Cursor="Hand" />
                    </Grid>
                    <Border x:Name="PreviewSummaryBorder" Grid.Row="1" Visibility="Collapsed"
                            Margin="12,0,12,12" Padding="16,13" CornerRadius="7"
                            Background="{DynamicResource BadgeBackgroundBrush}"
                            BorderBrush="{StaticResource AccentBrush}" BorderThickness="1">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*" />
                                <ColumnDefinition Width="Auto" />
                            </Grid.ColumnDefinitions>
                            <StackPanel>
                                <TextBlock Text="PREVIEW SUMMARY" Foreground="{DynamicResource BadgeTextBrush}"
                                           FontSize="11" FontWeight="Bold" />
                                <TextBlock x:Name="PreviewSummaryCountTextBlock" Text="0 files"
                                           Foreground="{DynamicResource HeadingBrush}" FontSize="21"
                                           FontWeight="Bold" Margin="0,2,0,0" />
                                <TextBlock x:Name="PreviewSummaryDetailTextBlock"
                                           Text="Exact match from the latest completed preview"
                                           Foreground="{DynamicResource MutedTextBrush}" FontSize="11" Margin="0,3,0,0" />
                            </StackPanel>
                            <TextBlock x:Name="PreviewSummarySizeTextBlock" Grid.Column="1" Text="0 bytes"
                                       Foreground="{DynamicResource BadgeTextBrush}" FontSize="21"
                                       FontWeight="Bold" VerticalAlignment="Center" Margin="18,0,0,0" />
                        </Grid>
                    </Border>
                    <TextBox x:Name="OutputTextBox" Grid.Row="2" IsReadOnly="True" AcceptsReturn="True"
                             VerticalAlignment="Stretch" HorizontalAlignment="Stretch"
                             VerticalContentAlignment="Top" HorizontalContentAlignment="Left"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                             TextWrapping="NoWrap" FontFamily="Consolas" FontSize="12" Background="{DynamicResource OutputBackgroundBrush}"
                             Foreground="{DynamicResource OutputTextBrush}" BorderThickness="0" Padding="14" />
                    <Border x:Name="OperationResultBorder" Grid.Row="3" Visibility="Collapsed"
                            Padding="14,11" CornerRadius="0,0,7,7">
                        <TextBlock x:Name="OperationResultTextBlock" Foreground="White" FontSize="18"
                                   FontWeight="Bold" TextAlignment="Center" />
                    </Border>
                </Grid>
            </Border>
        </Grid>

        <Grid Grid.Row="2" Margin="2,16,2,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel VerticalAlignment="Center">
                <StackPanel Orientation="Horizontal">
                    <Ellipse x:Name="StatusIndicator" Width="9" Height="9" Fill="#22C55E" Margin="0,0,8,0" />
                    <TextBlock x:Name="StatusTextBlock" Text="Ready" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center" />
                    <TextBlock x:Name="ElapsedTextBlock" Visibility="Collapsed" Foreground="{DynamicResource MutedTextBrush}"
                               FontWeight="SemiBold" Margin="12,0,0,0" VerticalAlignment="Center" />
                </StackPanel>
                <ProgressBar x:Name="ActivityProgressBar" Visibility="Collapsed" IsIndeterminate="True"
                             Width="400" Height="7" HorizontalAlignment="Left" Margin="0,7,0,0"
                             Foreground="#22C55E" Background="{DynamicResource BorderBrush}" BorderThickness="0" />
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal">
                <Button x:Name="CancelButton" Content="Cancel" Style="{StaticResource SecondaryButton}" Width="138" Margin="0,0,8,0" IsEnabled="False" />
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
    $parsedApplicationVersion = [version]$script:ApplicationVersion
    $window.Title = 'CopyFromTo v{0}.{1} (Picnic Time)' -f `
        $parsedApplicationVersion.Major, $parsedApplicationVersion.Minor
}
catch {
    Write-Error "The CopyFromTo UI definition is invalid. $($_.Exception.Message)"
    exit 2
}

$requiredControls = @(
    'SourceFolderLabel', 'SourceTextBox', 'DestinationTextBox', 'FileNameTextBox', 'UseStartDateCheckBox',
    'UseEndDateCheckBox', 'StartDatePicker', 'EndDatePicker', 'RecurseCheckBox',
    'FollowLinksCheckBox', 'VerificationComboBox', 'DeleteSourceCheckBox', 'RetryCountTextBox',
    'RetryWaitTextBox', 'ThreadsTextBox', 'ToleranceTextBox', 'PreviewLimitTextBox',
    'LogFolderTextBox', 'BrowseSourceButton', 'BrowseDestinationButton', 'BrowseLogButton',
    'ThemeToggleButton',
    'FilterModeRadio', 'SpecificFilesModeRadio', 'FilterModePanel', 'SpecificFilesPanel',
    'SpecificFilesListBox', 'AddFilesButton', 'RemoveFilesButton', 'RecurseOptionsPanel',
    'PreviewButton', 'CopyButton', 'CancelButton', 'ClearOutputButton', 'OutputTextBox',
    'PreviewSummaryBorder', 'PreviewSummaryCountTextBlock', 'PreviewSummarySizeTextBlock',
    'PreviewSummaryDetailTextBlock',
    'OperationResultBorder', 'OperationResultTextBlock',
    'StatusTextBlock', 'StatusIndicator', 'ElapsedTextBlock', 'ActivityProgressBar'
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
$script:OperationStopwatch = $null
$script:PendingExitCode = $null
$script:OperationElapsed = $null
$script:OutputCollector = $null
$script:PreviewSummaryPath = $null
$script:ActiveOperationIsPreview = $false
$script:ActiveOperationDeletesSource = $false
$script:FileListPath = $null
$script:SpecificFilePaths = [System.Collections.Generic.List[string]]::new()
$script:PinnedRelativePaths = $null
$script:PinnedMatchedCount = $null
$script:PinnedTotalBytes = $null
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

    # PowerShell unwraps WPF's Nullable[datetime] SelectedDate property into a plain
    # DateTime. Exercise the same access pattern used to build operation arguments so
    # Windows PowerShell 5.1 catches regressions such as calling a nonexistent .Value.
    $StartDatePicker.SelectedDate = [datetime]'2025-01-01'
    $EndDatePicker.SelectedDate = [datetime]'2025-06-30'
    if ($StartDatePicker.SelectedDate.ToString('yyyy-MM-dd') -ne '2025-01-01' -or
        $EndDatePicker.SelectedDate.ToString('yyyy-MM-dd') -ne '2025-06-30' -or
        $StartDatePicker.SelectedDate.Date -gt $EndDatePicker.SelectedDate.Date) {
        throw 'Date filter validation failed.'
    }
    $StartDatePicker.SelectedDate = $null
    $EndDatePicker.SelectedDate = $null

    if ($ActivityProgressBar.Visibility -ne 'Collapsed' -or
        -not $ActivityProgressBar.IsIndeterminate -or
        $ActivityProgressBar.Foreground.Color.ToString() -ne '#FF22C55E' -or
        $ElapsedTextBlock.Visibility -ne 'Collapsed') {
        throw 'Operation activity indicator validation failed.'
    }
    if ($PreviewSummaryBorder.Visibility -ne 'Collapsed' -or
        $PreviewSummaryCountTextBlock.Text -ne '0 files' -or
        $PreviewSummarySizeTextBlock.Text -ne '0 bytes') {
        throw 'Preview summary initial-state validation failed.'
    }
    if (-not $FilterModeRadio.IsChecked -or $SpecificFilesModeRadio.IsChecked -or
        $SpecificFilesPanel.Visibility -ne 'Collapsed' -or
        $FilterModePanel.Visibility -ne 'Visible' -or
        $SpecificFilesListBox.Items.Count -ne 0 -or
        -not [string]::IsNullOrWhiteSpace($FileNameTextBox.Text)) {
        throw 'Selection-mode initial-state validation failed.'
    }
    if ($DeleteSourceCheckBox.IsChecked) {
        throw 'Source-deletion option must be disabled by default.'
    }

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
    if (-not ('CopyFromToUi.FolderPicker' -as [type])) {
        throw 'Explorer-style folder picker type was not loaded.'
    }
    Write-Output "CopyFromTo UI validation passed. Title='$($window.Title)'; Themes=Light,Dark; DarkContrast=True; DateFilters=True; SelectionMode=True; ActivityIndicator=True; PreviewSummary=True; OutputLayout=True; RenderMode=$([Windows.Media.RenderOptions]::ProcessRenderMode); IsolatedHost=True; Packaged=$script:IsPackagedExecutable; OutputCapture=True; FolderPicker=True; Engine='$script:EnginePath'; Controls=$($requiredControls.Count)."
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

function Remove-PreviewSummaryFile {
    if ($script:PreviewSummaryPath -and
        (Test-Path -LiteralPath $script:PreviewSummaryPath -PathType Leaf)) {
        Remove-Item -LiteralPath $script:PreviewSummaryPath -Force -ErrorAction SilentlyContinue
    }
    $script:PreviewSummaryPath = $null
}

function Remove-FileListFile {
    if ($script:FileListPath -and
        (Test-Path -LiteralPath $script:FileListPath -PathType Leaf)) {
        Remove-Item -LiteralPath $script:FileListPath -Force -ErrorAction SilentlyContinue
    }
    $script:FileListPath = $null
}

function Clear-PreviewSummary {
    $PreviewSummaryBorder.Visibility = 'Collapsed'
    $PreviewSummaryCountTextBlock.Text = '0 files'
    $PreviewSummarySizeTextBlock.Text = '0 bytes'
    $PreviewSummaryDetailTextBlock.Text = 'Exact match from the latest completed preview'
    $script:PinnedRelativePaths = $null
    $script:PinnedMatchedCount = $null
    $script:PinnedTotalBytes = $null
}

function Format-PreviewByteSize {
    param([Parameter(Mandatory)] [long]$Bytes)

    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return '{0:N0} bytes' -f $Bytes
}

function Show-PreviewSummary {
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'The preview completed without producing its summary file.'
    }

    $summary = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $summary.MatchedFiles -or $null -eq $summary.TotalBytes) {
        throw 'The preview summary did not contain its required values.'
    }
    [long]$matchedFiles = $summary.MatchedFiles
    [long]$totalBytes = $summary.TotalBytes
    $schemaVersion = [int]$summary.SchemaVersion
    if ($schemaVersion -notin @(1, 2) -or $matchedFiles -lt 0 -or $totalBytes -lt 0) {
        throw 'The preview summary contained invalid values.'
    }

    $script:PinnedMatchedCount = $matchedFiles
    $script:PinnedTotalBytes = $totalBytes
    if ($schemaVersion -ge 2 -and $null -ne $summary.RelativePaths) {
        $script:PinnedRelativePaths = @($summary.RelativePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    else {
        $script:PinnedRelativePaths = $null
    }

    $fileLabel = if ($matchedFiles -eq 1) { 'file' } else { 'files' }
    $PreviewSummaryCountTextBlock.Text = '{0:N0} {1}' -f $matchedFiles, $fileLabel
    $PreviewSummarySizeTextBlock.Text = Format-PreviewByteSize -Bytes $totalBytes
    $PreviewSummaryDetailTextBlock.Text = '{0:N0} exact bytes from the latest completed preview' -f $totalBytes
    $PreviewSummaryBorder.Visibility = 'Visible'
}

function Write-ProcessOutputBatch {
    param([int]$MaximumLines = 200)

    if (-not $script:OutputCollector) { return 0 }
    $builder = [Text.StringBuilder]::new()
    $lineCount = 0
    [string]$line = $null
    while ($lineCount -lt $MaximumLines -and $script:OutputCollector.Lines.TryDequeue([ref]$line)) {
        $null = $builder.AppendLine($line)
        $lineCount++
        $line = $null
    }
    if ($lineCount -gt 0) {
        $OutputTextBox.AppendText($builder.ToString())
        $OutputTextBox.ScrollToEnd()
    }
    return $lineCount
}

function Get-OperationElapsedText {
    if (-not $script:OperationStopwatch) { return '00:00:00' }
    $elapsed = $script:OperationStopwatch.Elapsed
    $hours = [int][math]::Floor($elapsed.TotalHours)
    return '{0:00}:{1:00}:{2:00}' -f $hours, $elapsed.Minutes, $elapsed.Seconds
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
    $DeleteSourceCheckBox.IsEnabled = -not $Running
    $CancelButton.IsEnabled = $Running
    $CancelButton.Content = if ($Running) { 'Cancel operation' } else { 'Cancel' }
    $ActivityProgressBar.Visibility = if ($Running) { 'Visible' } else { 'Collapsed' }
    $ElapsedTextBlock.Visibility = if ($Running) { 'Visible' } else { 'Collapsed' }
    if (-not $Running) {
        $ElapsedTextBlock.Text = ''
    }
    $StatusIndicator.Fill = '#22C55E'
}

function Remove-ProcessOutputCollector {
    if ($script:OutputCollector) {
        $script:OutputCollector.Dispose()
        $script:OutputCollector = $null
    }
}

function Complete-CopyOperation {
    param(
        [Parameter(Mandatory)] [int]$ExitCode,
        [Parameter(Mandatory)] [string]$Elapsed
    )

    $wasCancelled = $script:CancelRequested
    $wasPreview = $script:ActiveOperationIsPreview
    $wasSourceDeletion = $script:ActiveOperationDeletesSource
    $previewSummaryPath = $script:PreviewSummaryPath
    Remove-ProcessOutputCollector
    $script:ActiveProcess.Dispose()
    $script:ActiveProcess = $null
    $script:OperationStopwatch = $null
    $script:PendingExitCode = $null
    $script:OperationElapsed = $null
    $script:ActiveOperationIsPreview = $false
    $script:ActiveOperationDeletesSource = $false
    Set-UiRunningState $false

    if ($wasCancelled) {
        Add-OutputLine
        Add-OutputLine "Operation cancelled after $Elapsed."
        $StatusTextBlock.Text = "Cancelled after $Elapsed"
        $StatusIndicator.Fill = '#EF4444'
        Set-OperationResult -Result Failed -Detail "Operation cancelled after $Elapsed."
    }
    elseif ($ExitCode -eq 0) {
        if ($wasPreview) {
            try {
                Show-PreviewSummary -Path $previewSummaryPath
            }
            catch {
                Clear-PreviewSummary
                Add-OutputLine
                Add-OutputLine "Preview summary unavailable: $($_.Exception.Message)"
            }
        }
        $StatusTextBlock.Text = "Completed successfully in $Elapsed"
        $StatusIndicator.Fill = '#22C55E'
        $successDetail = if ($wasPreview) {
            "Preview completed successfully in $Elapsed."
        }
        elseif ($wasSourceDeletion) {
            "Copy, verification, and exact source cleanup completed successfully in $Elapsed."
        }
        else {
            "Operation completed successfully in $Elapsed."
        }
        Set-OperationResult -Result Success -Detail $successDetail
    }
    else {
        Add-OutputLine
        $policyBlocked = $OutputTextBox.Text -match 'running scripts is disabled'
        if ($policyBlocked) {
            Add-OutputLine "PowerShell blocked the copy engine because script execution is disabled. Rebuild CopyFromTo.exe from this repository, or start the engine with -ExecutionPolicy Bypass."
        }
        else {
            Add-OutputLine "CopyFromTo exited with status $ExitCode after $Elapsed. Review the output above."
        }
        $StatusTextBlock.Text = "Finished with errors after $Elapsed (exit $ExitCode)"
        $StatusIndicator.Fill = '#EF4444'
        $failedDetail = if ($policyBlocked) {
            "PowerShell script execution is disabled on this computer (exit $ExitCode)."
        }
        else {
            "CopyFromTo exited with status $ExitCode after $Elapsed."
        }
        Set-OperationResult -Result Failed -Detail $failedDetail
    }
    if ($wasSourceDeletion) {
        # A destructive run necessarily makes its preview stale, even if cleanup was
        # cancelled or stopped partway through. Require a fresh preview before reuse.
        Clear-PreviewSummary
        $DeleteSourceCheckBox.IsChecked = $false
    }
    Remove-PreviewSummaryFile
    Remove-FileListFile
    $script:CancelRequested = $false
}

function Select-Folder {
    param(
        [string]$InitialPath,
        [string]$Description = 'Select a folder'
    )

    $startPath = $null
    if ($InitialPath -and (Test-Path -LiteralPath $InitialPath -PathType Container)) {
        $startPath = $InitialPath
    }

    $owner = [IntPtr]::Zero
    try {
        if ($window) {
            $owner = ([Windows.Interop.WindowInteropHelper]::new($window)).Handle
        }
    }
    catch { }

    if ('CopyFromToUi.FolderPicker' -as [type]) {
        try {
            return [CopyFromToUi.FolderPicker]::SelectFolder($Description, $startPath, $owner)
        }
        catch {
            # The Explorer-style dialog is best-effort; keep the classic picker working.
        }
    }

    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $true
    if ($startPath) { $dialog.SelectedPath = $startPath }
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

function Test-UiPathIsWithin {
    param(
        [Parameter(Mandatory)] [string]$Parent,
        [Parameter(Mandatory)] [string]$Child
    )
    $parentFull = [IO.Path]::GetFullPath($Parent)
    $childFull = [IO.Path]::GetFullPath($Child)
    $root = [IO.Path]::GetPathRoot($parentFull)
    if ($parentFull.Length -gt $root.Length) {
        $parentFull = $parentFull.TrimEnd([char[]]@('\', '/'))
    }
    $prefix = $parentFull
    if (-not $prefix.EndsWith('\')) { $prefix += '\' }
    return $childFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-SourceRelativePath {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$FullPath
    )
    if (-not (Test-UiPathIsWithin -Parent $Source -Child $FullPath)) {
        return $FullPath
    }
    $parentFull = [IO.Path]::GetFullPath($Source)
    $root = [IO.Path]::GetPathRoot($parentFull)
    if ($parentFull.Length -gt $root.Length) {
        $parentFull = $parentFull.TrimEnd([char[]]@('\', '/'))
    }
    return [IO.Path]::GetFullPath($FullPath).Substring($parentFull.Length).TrimStart([char[]]@('\', '/'))
}

function Get-EnteredSourcePath {
    $source = $SourceTextBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($source)) { return $null }
    try {
        $null = [IO.Path]::GetFullPath($source)
        return $source
    }
    catch {
        return $null
    }
}

function Sync-SpecificFilesListBox {
    $SpecificFilesListBox.Items.Clear()
    $source = Get-EnteredSourcePath
    foreach ($path in @($script:SpecificFilePaths)) {
        $display = if ($source) { Get-SourceRelativePath -Source $source -FullPath $path } else { $path }
        $null = $SpecificFilesListBox.Items.Add($display)
    }
}

function Set-SelectionMode {
    $specific = [bool]$SpecificFilesModeRadio.IsChecked
    $FilterModePanel.Visibility = if ($specific) { 'Collapsed' } else { 'Visible' }
    $SpecificFilesPanel.Visibility = if ($specific) { 'Visible' } else { 'Collapsed' }
    $RecurseCheckBox.IsEnabled = -not $specific
    $FollowLinksCheckBox.IsEnabled = -not $specific
    $AddFilesButton.IsEnabled = $specific
    $RemoveFilesButton.IsEnabled = $specific
    Clear-PreviewSummary
}

function Add-SpecificFilesFromDialog {
    $source = $SourceTextBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($source) -or -not (Test-Path -LiteralPath $source -PathType Container)) {
        [Windows.MessageBox]::Show(
            'Choose an existing source folder before adding files.',
            'Source folder required', 'OK', 'Warning'
        ) | Out-Null
        return
    }

    $dialog = [Windows.Forms.OpenFileDialog]::new()
    $dialog.Title = 'Select files to copy'
    $dialog.Multiselect = $true
    $dialog.CheckFileExists = $true
    $dialog.InitialDirectory = [IO.Path]::GetFullPath($source)
    try {
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
        $rejected = [System.Collections.Generic.List[string]]::new()
        $added = 0
        foreach ($filePath in @($dialog.FileNames)) {
            if (-not (Test-UiPathIsWithin -Parent $source -Child $filePath)) {
                $rejected.Add($filePath)
                continue
            }
            $already = $false
            foreach ($existing in $script:SpecificFilePaths) {
                if ($existing.Equals($filePath, [StringComparison]::OrdinalIgnoreCase)) {
                    $already = $true
                    break
                }
            }
            if ($already) { continue }
            $script:SpecificFilePaths.Add($filePath)
            $added++
        }
        if ($added -gt 0) {
            Sync-SpecificFilesListBox
            Clear-PreviewSummary
        }
        if ($rejected.Count -gt 0) {
            [Windows.MessageBox]::Show(
                "These files are outside the source folder and were not added:`n`n$($rejected -join "`n")",
                'Files outside source', 'OK', 'Warning'
            ) | Out-Null
        }
    }
    finally {
        $dialog.Dispose()
    }
}

function Remove-SelectedSpecificFiles {
    $selected = @($SpecificFilesListBox.SelectedItems)
    if ($selected.Count -eq 0) { return }
    $source = Get-EnteredSourcePath
    $remaining = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $script:SpecificFilePaths) {
        $display = if ($source) { Get-SourceRelativePath -Source $source -FullPath $path } else { $path }
        $keep = $true
        foreach ($item in $selected) {
            if ([string]$item -eq $display) { $keep = $false; break }
        }
        if ($keep) { $remaining.Add($path) }
    }
    $script:SpecificFilePaths = $remaining
    Sync-SpecificFilesListBox
    Clear-PreviewSummary
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
    $specificMode = [bool]$SpecificFilesModeRadio.IsChecked
    if ([string]::IsNullOrWhiteSpace($source)) { throw 'Choose a source folder.' }
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "The source folder does not exist: '$source'." }
    if ([string]::IsNullOrWhiteSpace($destination)) { throw 'Choose a destination folder.' }

    $retryCount = Get-ValidatedInteger $RetryCountTextBox 'Retries' 0 1000000
    $retryWait = Get-ValidatedInteger $RetryWaitTextBox 'Retry wait' 0 3600
    $threads = Get-ValidatedInteger $ThreadsTextBox 'Worker threads' 1 128
    $tolerance = Get-ValidatedInteger $ToleranceTextBox 'Timestamp tolerance' 0 300
    $previewLimit = Get-ValidatedInteger $PreviewLimitTextBox 'Preview limit' 0 1000000

    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.AddRange([string[]]@(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $script:EnginePath,
        '-Source', $source, '-Destination', $destination,
        '-VerificationMode', [string]$VerificationComboBox.SelectedItem.Tag,
        '-RetryCount', [string]$retryCount, '-RetryWait', [string]$retryWait,
        '-Threads', [string]$threads, '-TimestampToleranceSeconds', [string]$tolerance,
        '-PreviewLimit', [string]$previewLimit, '-Force'
    ))

    $fileListLines = $null
    $usePinnedFilterList = -not $Preview -and $null -ne $script:PinnedRelativePaths
    if ($usePinnedFilterList) {
        # A completed preview is the safest source of truth for a real operation in
        # either selection mode. In particular, source deletion must use this exact
        # pinned list rather than rebuilding a wildcard match later.
        $fileListLines = @($script:PinnedRelativePaths)
    }
    elseif ($specificMode) {
        if ($script:SpecificFilePaths.Count -eq 0) {
            throw 'Add at least one file to copy, or switch back to Filter by name and date.'
        }
        $validLines = [System.Collections.Generic.List[string]]::new()
        foreach ($filePath in $script:SpecificFilePaths) {
            if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                throw "A selected file no longer exists: '$filePath'."
            }
            if (-not (Test-UiPathIsWithin -Parent $source -Child $filePath)) {
                throw "A selected file is outside the source folder: '$filePath'."
            }
            $validLines.Add($filePath)
        }
        $fileListLines = $validLines.ToArray()
    }
    else {
        $patterns = $FileNameTextBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($patterns)) {
            throw 'Enter at least one file name or wildcard pattern. Use * for all files.'
        }
        $arguments.AddRange([string[]]@('-FileName', $patterns))
        if ($UseStartDateCheckBox.IsChecked) {
            if (-not $StartDatePicker.SelectedDate) { throw 'Choose a start date or clear the Start date checkbox.' }
            $arguments.AddRange([string[]]@('-StartDate', $StartDatePicker.SelectedDate.ToString('yyyy-MM-dd')))
        }
        if ($UseEndDateCheckBox.IsChecked) {
            if (-not $EndDatePicker.SelectedDate) { throw 'Choose an end date or clear the End date checkbox.' }
            $arguments.AddRange([string[]]@('-EndDate', $EndDatePicker.SelectedDate.ToString('yyyy-MM-dd')))
        }
        if ($UseStartDateCheckBox.IsChecked -and $UseEndDateCheckBox.IsChecked -and
            $StartDatePicker.SelectedDate.Date -gt $EndDatePicker.SelectedDate.Date) {
            throw 'Start date cannot be later than end date.'
        }
        if ($RecurseCheckBox.IsChecked) { $arguments.Add('-Recurse') }
        if ($FollowLinksCheckBox.IsChecked) { $arguments.Add('-FollowReparsePoint') }
    }

    if ($Preview) { $arguments.Add('-DryRun') }
    $logFolder = $LogFolderTextBox.Text.Trim()
    if ($logFolder) { $arguments.AddRange([string[]]@('-LogFolder', $logFolder)) }
    return [pscustomobject]@{
        Arguments    = $arguments.ToArray()
        FileListLines = $fileListLines
        Source       = $source
        Destination  = $destination
        SpecificMode = $specificMode
        DeleteSource = [bool]$DeleteSourceCheckBox.IsChecked
    }
}

function Start-CopyOperation {
    param([switch]$Preview)
    try {
        $operation = Get-OperationArguments -Preview:$Preview
    }
    catch {
        [Windows.MessageBox]::Show($_.Exception.Message, 'Check the settings', 'OK', 'Warning') | Out-Null
        return
    }

    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.AddRange([string[]]$operation.Arguments)
    $previewSummaryPath = $null
    $fileListPath = $null
    if ($Preview) {
        Clear-PreviewSummary
        $previewSummaryPath = Join-Path ([IO.Path]::GetTempPath()) `
            ("CopyFromTo-preview-{0}.json" -f [guid]::NewGuid().ToString('N'))
        $arguments.AddRange([string[]]@('-PreviewSummaryPath', $previewSummaryPath))
    }

    if ($operation.FileListLines) {
        $fileListPath = Join-Path ([IO.Path]::GetTempPath()) `
            ("CopyFromTo-files-{0}.txt" -f [guid]::NewGuid().ToString('N'))
        $utf8NoBom = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllLines($fileListPath, [string[]]$operation.FileListLines, $utf8NoBom)
        $arguments.AddRange([string[]]@('-FileListPath', $fileListPath))
    }

    $arguments = $arguments.ToArray()

    if (-not $Preview) {
        $source = $operation.Source
        $destination = $operation.Destination
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            [Windows.MessageBox]::Show(
                "The destination path is an existing file, not a folder:`n`n$destination",
                'Invalid destination', 'OK', 'Error'
            ) | Out-Null
            Remove-FileListFile
            if ($fileListPath -and (Test-Path -LiteralPath $fileListPath -PathType Leaf)) {
                Remove-Item -LiteralPath $fileListPath -Force -ErrorAction SilentlyContinue
            }
            return
        }

        $fileCount = $null
        $sizeText = $null
        if ($operation.SpecificMode) {
            $fileCount = $script:SpecificFilePaths.Count
        }
        elseif ($null -ne $script:PinnedMatchedCount) {
            $fileCount = [int]$script:PinnedMatchedCount
            if ($null -ne $script:PinnedTotalBytes) {
                $sizeText = Format-PreviewByteSize -Bytes ([long]$script:PinnedTotalBytes)
            }
        }
        if ($null -ne $fileCount -and $fileCount -eq 0) {
            [Windows.MessageBox]::Show(
                'Nothing to copy. Preview found no matching files, or no files are selected.',
                'Nothing to copy', 'OK', 'Information'
            ) | Out-Null
            if ($fileListPath -and (Test-Path -LiteralPath $fileListPath -PathType Leaf)) {
                Remove-Item -LiteralPath $fileListPath -Force -ErrorAction SilentlyContinue
            }
            return
        }

        if ($operation.DeleteSource -and
            ($null -eq $script:PinnedRelativePaths -or $null -eq $script:PinnedMatchedCount)) {
            [Windows.MessageBox]::Show(
                'Run Preview with the current settings before using source deletion. The completed Preview creates the exact, pinned file list that the safety checks require.',
                'Preview required before deletion', 'OK', 'Warning'
            ) | Out-Null
            if ($fileListPath -and (Test-Path -LiteralPath $fileListPath -PathType Leaf)) {
                Remove-Item -LiteralPath $fileListPath -Force -ErrorAction SilentlyContinue
            }
            return
        }

        $countPhrase = if ($null -eq $fileCount) {
            'matching files'
        }
        elseif ($fileCount -eq 1) {
            '1 file'
        }
        else {
            '{0:N0} files' -f $fileCount
        }
        if ($sizeText) { $countPhrase = "$countPhrase ($sizeText)" }

        $destinationExists = Test-Path -LiteralPath $destination -PathType Container
        if ($destinationExists) {
            $confirmation = [Windows.MessageBox]::Show(
                "Copy $countPhrase now?`n`nFrom: $source`nTo:   $destination",
                'Confirm copy', 'YesNo', 'Question'
            )
        }
        else {
            $confirmation = [Windows.MessageBox]::Show(
                "The destination folder does not exist:`n`n$destination`n`nCopyFromTo will create it before copying $countPhrase.`n`nCreate the folder and start copying?",
                'Create destination folder?', 'YesNo', 'Warning'
            )
        }
        if ($confirmation -ne 'Yes') {
            if ($fileListPath -and (Test-Path -LiteralPath $fileListPath -PathType Leaf)) {
                Remove-Item -LiteralPath $fileListPath -Force -ErrorAction SilentlyContinue
            }
            return
        }

        if ($operation.DeleteSource) {
            $deleteConfirmation = [Windows.MessageBox]::Show(
                "WARNING: This operation will permanently delete the source files after the entire copy set verifies successfully.`n`nExact scope: $countPhrase`nSource:      $source`nDestination: $destination`n`nBefore deletion, CopyFromTo will SHA-256 compare every source/destination pair and abort all deletion if any safety check fails. It will never delete folders or files outside this completed Preview.`n`nProceed with copy, verification, and source deletion?",
                'Confirm verified source deletion', 'YesNo', 'Warning'
            )
            if ($deleteConfirmation -ne 'Yes') {
                if ($fileListPath -and (Test-Path -LiteralPath $fileListPath -PathType Leaf)) {
                    Remove-Item -LiteralPath $fileListPath -Force -ErrorAction SilentlyContinue
                }
                return
            }
            $arguments = [Collections.Generic.List[string]]::new([string[]]$arguments)
            $arguments.Add('-DeleteSourceAfterVerification')
            $arguments.Add('-SourceDeletionConfirmed')
            $arguments = $arguments.ToArray()
        }
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
        $script:PreviewSummaryPath = $previewSummaryPath
        $script:FileListPath = $fileListPath
        $script:ActiveOperationIsPreview = [bool]$Preview
        $script:ActiveOperationDeletesSource = [bool](-not $Preview -and $operation.DeleteSource)
        $script:CancelRequested = $false
        $script:PendingExitCode = $null
        $script:OperationElapsed = $null
        $script:OperationStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
        Set-UiRunningState $true
        $ElapsedTextBlock.Text = 'Elapsed 00:00:00'
        $StatusTextBlock.Text = if ($Preview) {
            'Building preview…'
        }
        elseif ($operation.DeleteSource) {
            'Copying, verifying, then deleting exact source files…'
        }
        else {
            'Copy in progress…'
        }
    }
    catch {
        $collector.Dispose()
        $process.Dispose()
        if ($previewSummaryPath -and (Test-Path -LiteralPath $previewSummaryPath -PathType Leaf)) {
            Remove-Item -LiteralPath $previewSummaryPath -Force -ErrorAction SilentlyContinue
        }
        if ($fileListPath -and (Test-Path -LiteralPath $fileListPath -PathType Leaf)) {
            Remove-Item -LiteralPath $fileListPath -Force -ErrorAction SilentlyContinue
        }
        $script:PreviewSummaryPath = $null
        $script:FileListPath = $null
        $script:ActiveOperationIsPreview = $false
        $script:ActiveOperationDeletesSource = $false
        Set-OperationResult -Result Failed -Detail 'The copy process could not be started.'
        [Windows.MessageBox]::Show("Could not start CopyFromTo.ps1. $($_.Exception.Message)", 'Launch failed', 'OK', 'Error') | Out-Null
    }
}

$UseStartDateCheckBox.Add_Checked({
    $StartDatePicker.IsEnabled = $true
    Clear-PreviewSummary
})
$UseStartDateCheckBox.Add_Unchecked({
    $StartDatePicker.IsEnabled = $false
    Clear-PreviewSummary
})
$UseEndDateCheckBox.Add_Checked({
    $EndDatePicker.IsEnabled = $true
    Clear-PreviewSummary
})
$UseEndDateCheckBox.Add_Unchecked({
    $EndDatePicker.IsEnabled = $false
    Clear-PreviewSummary
})
$StartDatePicker.Add_SelectedDateChanged({ Clear-PreviewSummary })
$EndDatePicker.Add_SelectedDateChanged({ Clear-PreviewSummary })
$SourceTextBox.Add_TextChanged({
    Clear-PreviewSummary
    $source = Get-EnteredSourcePath
    if ($source -and $script:SpecificFilePaths.Count -gt 0) {
        $kept = [System.Collections.Generic.List[string]]::new()
        foreach ($path in $script:SpecificFilePaths) {
            if (Test-UiPathIsWithin -Parent $source -Child $path) { $kept.Add($path) }
        }
        if ($kept.Count -ne $script:SpecificFilePaths.Count) {
            $script:SpecificFilePaths = $kept
        }
    }
    Sync-SpecificFilesListBox
})
$FileNameTextBox.Add_TextChanged({ Clear-PreviewSummary })
$RecurseCheckBox.Add_Checked({ Clear-PreviewSummary })
$RecurseCheckBox.Add_Unchecked({ Clear-PreviewSummary })
$FollowLinksCheckBox.Add_Checked({
    if (-not $RecurseCheckBox.IsChecked) { $RecurseCheckBox.IsChecked = $true }
    Clear-PreviewSummary
})
$FollowLinksCheckBox.Add_Unchecked({ Clear-PreviewSummary })
$FilterModeRadio.Add_Checked({ Set-SelectionMode })
$SpecificFilesModeRadio.Add_Checked({ Set-SelectionMode })
$AddFilesButton.Add_Click({ Add-SpecificFilesFromDialog })
$RemoveFilesButton.Add_Click({ Remove-SelectedSpecificFiles })
Set-SelectionMode
$BrowseSourceButton.Add_Click({
    $selected = Select-Folder -InitialPath $SourceTextBox.Text.Trim() -Description 'Select the source folder'
    if ($selected) { $SourceTextBox.Text = $selected }
})
$BrowseDestinationButton.Add_Click({
    $selected = Select-Folder -InitialPath $DestinationTextBox.Text.Trim() -Description 'Select the destination folder'
    if ($selected) { $DestinationTextBox.Text = $selected }
})
$BrowseLogButton.Add_Click({
    $selected = Select-Folder -InitialPath $LogFolderTextBox.Text.Trim() -Description 'Select the log folder'
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
        $CancelButton.Content = 'Cancelling…'
        $CancelButton.IsEnabled = $false
        Add-OutputLine
        Add-OutputLine 'Cancellation requested…'
        try {
            & taskkill.exe /PID $script:ActiveProcess.Id /T /F 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0 -and -not $script:ActiveProcess.HasExited) {
                $script:ActiveProcess.Kill()
            }
        }
        catch {
            try { $script:ActiveProcess.Kill() } catch { }
        }
    }
})

$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(120)
$timer.Add_Tick({
    $null = Write-ProcessOutputBatch
    if (-not $script:ActiveProcess) { return }

    if ($null -eq $script:PendingExitCode -and $script:ActiveProcess.HasExited) {
        # WaitForExit after HasExited returns promptly and guarantees asynchronous
        # stdout/stderr callbacks have finished enqueueing their final lines.
        $script:ActiveProcess.WaitForExit()
        $script:PendingExitCode = $script:ActiveProcess.ExitCode
        if ($script:OperationStopwatch) { $script:OperationStopwatch.Stop() }
        $script:OperationElapsed = Get-OperationElapsedText
        $StatusTextBlock.Text = 'Finalizing output…'
        $CancelButton.Content = 'Finishing…'
        $CancelButton.IsEnabled = $false
    }

    if ($null -ne $script:PendingExitCode) {
        $null = Write-ProcessOutputBatch -MaximumLines 400
        $outputDrained = -not $script:OutputCollector -or $script:OutputCollector.Lines.IsEmpty
        if ($outputDrained) {
            Complete-CopyOperation -ExitCode $script:PendingExitCode -Elapsed $script:OperationElapsed
        }
        return
    }

    $ElapsedTextBlock.Text = "Elapsed $(Get-OperationElapsedText)"
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
    Remove-PreviewSummaryFile
    Remove-FileListFile
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
