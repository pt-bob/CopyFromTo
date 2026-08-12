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
- live operation output, completion status, and cancellation.
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
