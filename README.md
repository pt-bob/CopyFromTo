# CopyFromTo

CopyFromTo copies an exact, previewed set of files between local folders or Windows
network shares, then verifies the result. You can use either the original command-line
script or the optional desktop interface; both use the same copy engine.

## Desktop interface

Run:

```powershell
.\CopyFromTo-UI.ps1
```

The desktop interface provides:

- folder browsers for the source, destination, and optional log folder;
- comma-separated file names and wildcard patterns;
- optional start and end dates;
- recursive copying and explicit junction/symbolic-link following;
- fast metadata or thorough SHA-256 verification;
- advanced Robocopy retry, wait, thread, timestamp, and preview settings;
- a safe preview that makes no destination changes;
- a prominent preview summary with the exact matched file count and total size;
- live operation output and clear completion status;
- a green activity bar with elapsed time during long previews and copies;
- responsive, bounded output rendering for very large file groups;
- cancellation that stops the background process tree and returns to the main UI;
- coordinated light and dark color modes, including the operation output panel.

The UI asks for confirmation before a real copy. It then starts `CopyFromTo.ps1` in a
separate non-interactive PowerShell process, so the window stays responsive and the
existing CLI engine remains the single source of truth for filtering, copying, logging,
exit codes, and verification.

The UI requires Windows PowerShell 5.1 or PowerShell 7 on Windows with WPF. If it is
started from a terminal, it launches the WPF window in a separate hidden STA PowerShell
host. This prevents a native WPF failure from terminating the calling terminal. The UI
also uses software rendering for reliable operation in remote sessions and constrained
desktop environments. To validate a deployment without opening the window, run:

```powershell
.\CopyFromTo-UI.ps1 -ValidateOnly
```

## Command line

The command-line script remains fully supported and unchanged in how it is invoked:

```powershell
# Interactive filters and confirmation
.\CopyFromTo.ps1 -Source 'C:\Data\Reports' -Destination '\\NAS\Archive\Reports'

# Unattended copy
.\CopyFromTo.ps1 -Source 'C:\Data' -Destination 'D:\Backup' `
    -FileName '*.pdf,Invoice*.xlsx' -StartDate '2026-01-01' `
    -EndDate '2026-06-30' -Recurse -Force

# Preview only
.\CopyFromTo.ps1 -Source 'C:\Data' -Destination 'D:\Backup' `
    -FileName '*.pdf' -Recurse -DryRun -Force

# Full parameter help
.\CopyFromTo.ps1 -Help
```

## Safety model

- PowerShell computes the exact match list used for preview, copy, and verification.
- Robocopy receives exact file names rather than broad transfer wildcards.
- Destination paths are checked physically to prevent source/destination aliasing
  through junctions or symbolic links.
- Reparse points are skipped by default, with cycle detection when following is enabled.
- Copies are verified by size and timestamp, with optional SHA-256 verification.
- Script-level and Robocopy logs are written separately under `Logs` by default.

## Tests

Run the full PowerShell 7 integration suite with Pester 5 or later:

```powershell
Invoke-Pester -Path .\Tests -Output Detailed
```

The suite invokes the copy engine and UI validation as child processes and includes
Windows PowerShell 5.1 compatibility coverage when available.

## File-size report by date range

`TotalFileSize-of-DateRange.ps1` is a separate reporting utility that totals files by
date without copying them. It uses each file's last-modified date by default, includes
the complete ending day, and supports local folders and UNC paths:

```powershell
.\TotalFileSize-of-DateRange.ps1 `
    -FolderPath '\\Server\Share\Archive' `
    -StartDate '2026-01-01' -EndDate '2026-06-30' -Recurse
```

Use `-DateProperty CreationTime` when creation date is specifically needed, `-Force`
to include hidden files, or `-PassThru` to return a structured object for another
PowerShell command. Recursive scans stop with an error if a folder cannot be read, so
the script never silently reports an incomplete total.

## Build a Windows executable

`Build-Executable.ps1` creates a standalone 64-bit Windows GUI executable using PS2EXE:

```text
CopyFromTo.exe
```

The build reads the unchanged `CopyFromTo.ps1` engine, verifies its SHA-256 hash, and
injects it into the compiled UI. At runtime, the EXE writes that embedded engine to a
unique folder beneath `%TEMP%`, verifies it before use, and removes the folder when the
UI closes. No PowerShell script or other application file needs to accompany the EXE.

### Prerequisite and build

From PowerShell 7 or Windows PowerShell 5.1 in the repository folder:

```powershell
# Install the pinned build dependency and build dist\CopyFromTo.exe
.\Build-Executable.ps1 -InstallDependency
```

The script pins PS2EXE 1.0.18 by default. It does not install anything unless
`-InstallDependency` is explicitly supplied. Subsequent builds can use:

```powershell
.\Build-Executable.ps1
```

Optional metadata and icon:

```powershell
.\Build-Executable.ps1 `
    -Version '1.2.0.0' `
    -IconPath '.\Assets\CopyFromTo.ico'
```

Create a ready-to-distribute `CopyFromTo-1.2.0.0.zip` as well:

```powershell
.\Build-Executable.ps1 -Version '1.2.0.0' -CreateZip
```

`IconPath` must be a genuine Windows `.ico` file. Build output is ignored by Git under
`dist\`. PS2EXE generates a .NET Framework Windows executable and requires the input
script to remain compatible with Windows PowerShell 5.1. See the
[PS2EXE project documentation](https://github.com/MScholtes/PS2EXE) for compiler
details and options.

### Test the artifact

Run the resulting application directly:

```powershell
.\dist\CopyFromTo.exe
```

Copy the EXE to another folder without any `.ps1` files, launch it, then preview a small
folder before using Copy files. The target computer needs Windows PowerShell 5.1 and
Robocopy, both included with supported Windows installations.

### Sign before wider distribution

An unsigned internal executable can trigger Windows reputation or publisher warnings.
For wider distribution, sign it with a trusted code-signing certificate after building.
For example, from a Windows SDK Developer PowerShell prompt:

```powershell
signtool sign /fd SHA256 /td SHA256 /tr '<your RFC 3161 timestamp URL>' `
    /a '.\dist\CopyFromTo.exe'

signtool verify /pa /v '.\dist\CopyFromTo.exe'
```

Protect private keys and never commit a PFX file or its password. Microsoft documents
[SignTool and its signing/verification options](https://learn.microsoft.com/windows/win32/seccrypto/signtool).

PS2EXE packages PowerShell source; it does not make source code or embedded content
confidential. Do not put credentials, tokens, or passwords in either script.
