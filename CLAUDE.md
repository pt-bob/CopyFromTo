# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Windows PowerShell copy engine, `CopyFromTo.ps1`, that copies files matching a name
pattern and a last-modified date range from one folder to another (source/destination
can be local or a UNC network share), then verifies the copy. `CopyFromTo-UI.ps1` is a
separate WPF front end that launches the engine as a child process; never duplicate copy
logic in the UI or make the engine depend on WPF. There is no module manifest or build
step. Pester integration tests live under `Tests\`.

## Running it

```powershell
# Desktop UI
.\CopyFromTo-UI.ps1

# Validate the UI/XAML without opening a window
.\CopyFromTo-UI.ps1 -ValidateOnly

# Interactive: prompts for file name pattern(s) and MM/yyyy date range
.\CopyFromTo.ps1 -Source 'C:\Data\Reports' -Destination '\\NAS\Archive\Reports'

# Non-interactive, with filters given up front
.\CopyFromTo.ps1 -Source 'C:\Data' -Destination 'D:\Backup' -FileName '*.pdf' -StartDate '1/2024' -EndDate '6/2024'

# Preview only, no copying
.\CopyFromTo.ps1 -Source 'C:\Data' -Destination 'D:\Backup' -DryRun

# Fully unattended (e.g. Task Scheduler): skips every prompt, auto-creates the
# destination, defaults unspecified filters to "all files" / "no date limit"
.\CopyFromTo.ps1 -Source 'C:\Data' -Destination '\\NAS\Backup\Data' -Force

# List every parameter with a short description, then exit
.\CopyFromTo.ps1 -Help
```

There is no linter configured. See "Testing changes" below for how to run the test
suite — the exit codes and Robocopy interaction are easy to get subtly wrong from a
read-through alone.

## Architecture

Single script, three phases, run top to bottom in the `try` block at the bottom of the
file:

1. **Resolve filters (PowerShell).** If `-FileName` / `-StartDate` / `-EndDate` weren't
   passed as parameters, prompt for them interactively (`Read-FileNamePatterns`,
   `Read-DateRange`) — unless `-Force` is set, in which case unspecified filters default
   to "all files" / "no date limit" instead of prompting. `Get-ChildItem` then computes
   the *exact* matching file set in-process (name pattern via `-like`, date via
   `LastWriteTime.Date`). This computed list drives the preview table, the confirmation
   prompt, copy, and verification pass — it is the source of truth for what gets copied.
   Recursive enumeration is explicit so directory reparse points can be skipped by
   default rather than accidentally following a junction loop.
2. **Copy (Robocopy).** Matches are grouped by their actual source directory and passed
   to `robocopy.exe` as exact file names in command-line-sized batches. This is deliberate:
   passing the original wildcard/date filters allowed Robocopy to copy files that were
   never previewed or verified. Robocopy still provides retry/wait logic, multithreading,
   and native timestamp preservation. `/R`, `/W`, and `/MT` are configurable through
   `-RetryCount`, `-RetryWait`, and `-Threads`. `-DryRun` and standard `-WhatIf` stop
   before destination creation or Robocopy execution.
3. **Verify (PowerShell).** For every file in the PowerShell-computed match list, checks
   the destination has the same name, size, and last-write time (within a 2-second
   tolerance for filesystem timestamp resolution differences). `-VerificationMode Hash`
   additionally compares SHA-256 hashes; metadata mode remains the faster default.

### Key design decisions worth knowing before changing this script

- **Exact transfer set.** Never replace the per-directory exact-name batching with broad
  Robocopy wildcard/date arguments without also solving the preview/copy race. The old
  design could copy a future-dated or newly created file that was absent from the preview,
  then verification would ignore it. `Split-FileNameBatches` keeps exact-name commands
  below a conservative Windows command-line-size budget.
- **Optional date bounds are genuinely optional.** There are no sentinel dates such as
  1980 or today. A missing start or end is tested independently. Command-line values use
  invariant explicit formats (`yyyy-MM-dd`, `M/d/yyyy`, or `M/yyyy`); month-only end dates
  expand to the last day of that month. Presence is still detected through
  `$PSBoundParameters` rather than `Nullable[datetime]`, which PowerShell unwraps during
  binding.
- **`TryParseExact` compatibility.** The `[ref]$parsed` target must begin as a typed
  `[datetime]::MinValue`, and format arrays must be explicitly cast to `[string[]]` for
  Windows PowerShell 5.1 overload resolution.
- **Canonical path safety.** Source, destination, and log paths are resolved to physical
  filesystem paths (including junction/symlink targets) without stripping a drive root
  (`C:\` must never become `C:`). For paths that do not exist yet, the nearest existing
  ancestor is resolved before the remaining segments are appended. The script rejects
  identical paths and destinations nested under the source even when aliases are used.
  Relative-path verification assumes this canonicalization has already occurred.
- **`$PSNativeCommandUseErrorActionPreference` guard at the top.** On PowerShell 7.3+,
  if that preference variable is `$true`, a native command (Robocopy) returning a
  non-zero exit code becomes a terminating error — but Robocopy's exit codes are a
  bitmask where 1–7 mean *success* (see `Get-RobocopyResultDescription`). The script
  force-disables that preference (guarded by a `Test-Path Variable:` check for PS 5.1
  compatibility) so exit-code handling stays consistent across PowerShell versions.
- **`-Force` has two roles**: skip the confirmation and interactive filter prompts
  (defaulting missing filters to "all/unbounded") and auto-create a missing destination
  folder. Source and destination must still be supplied; omitting either under `-Force`
  produces a controlled fatal error instead of invoking `Read-Host`. It was deliberately
  not split into separate switches to keep the parameter surface small.
- **Script exit codes**: `0` success/nothing-to-do, `1` verification found
  missing/mismatched files, `2` runtime fatal error or Robocopy copy error, `3` user
  cancelled (declined confirmation or declined destination creation). PowerShell errors
  that occur before script code starts, such as parameter type/`ValidateRange` binding
  failures, use PowerShell's own exit code (normally `1`) and cannot be normalized inside
  the script. Preserve these semantics if you touch the exit paths.
- **Logging**: two collision-resistant log files per run under `Logs\` (next to the
  script by default, or `-LogFolder`), timestamped with milliseconds and PID:
  `CopyFromTo_<runStamp>.log` (script-level narrative, via
  `Write-Log`) and `CopyFromTo_<runStamp>_robocopy.log` (Robocopy's own per-file log,
  via `/LOG:`/`/LOG+:` + `/TEE`). `-LogRetentionDays` opts into cleanup of old matching
  logs. Keep script and Robocopy logs separate. The two active run-log paths are excluded
  from source enumeration so a `LogFolder` beneath a recursive source cannot copy and
  subsequently fail verification against its own changing log.
- **`-FileName` accepts comma-separated patterns, not space-separated array elements.**
  `[string[]]$FileName` looks like it should accept multiple argv tokens
  (`-FileName *.txt *.csv`), but when the script runs as a real external process (the
  normal CLI/Task Scheduler case), Windows argv has no concept of a PowerShell array —
  only genuine in-process splatting (`-FileName @('*.txt','*.csv')` from PowerShell
  code) produces one. A bare multi-token invocation actually fails with "A positional
  parameter cannot be found." The fix: right after resolving `$FileName`, every element
  is re-split on commas (`$_ -split ','`), so both a comma-joined single string
  (`-FileName '*.txt,*.csv'`, the realistic CLI form — same convention as the
  interactive prompt) and a true array (the in-process form) normalize to the same
  result. The all-files default is `*`, not `*.*`, so extensionless files are included.
  Empty normalized lists and path separators in patterns are rejected.
- **Reparse points.** Recursive traversal skips junctions and symlink directories by
  default. `-FollowReparsePoint` is an explicit opt-in for callers who understand that
  linked data can lie outside the apparent source tree. Followed directories are tracked
  by physical target so junction cycles and duplicate aliases are skipped.
- **Output and automation.** Exit codes remain the primary process contract. `-PassThru`
  adds a structured summary object, while default output stays human-oriented. Standard
  `-WhatIf` is supported alongside `-DryRun`; explicit `-Confirm` uses `ShouldProcess`.
- **Interactive path prompts are manual.** `Source` and `Destination` intentionally are
  not marked `Mandatory`: PowerShell's automatic mandatory-parameter prompt prints a
  noisy `cmdlet ... at command pipeline position 1` banner before script code can run.
  The script prompts for missing paths itself, producing the same interaction without
  the banner. `-Help` remains isolated in its own parameter set and exits before prompts.
- **Final console spacing.** The main `finally` block writes a blank line after the final
  status log so the next shell prompt is visually separated.

## Testing changes

Pester integration suite: `Tests\CopyFromTo.Tests.ps1`. It invokes `CopyFromTo.ps1` as a
genuine child process for every test (via the same PowerShell executable running the
tests, never dot-sourced) — the script ends with `exit $exitStatus`, which would kill
the Pester host itself if it ran in-process. Every invocation passes enough of
`-FileName`/`-StartDate`/`-EndDate`/`-Force` to avoid the interactive prompts, since
`-NonInteractive` makes a stray `Read-Host` fail fast rather than hang the run.

Requires Pester 5+ (`Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser`).
Windows PowerShell 5.1's inbox Pester (3.4.0) is too old for this syntax — run tests
under `pwsh` (PowerShell 7), where a modern Pester is installed. Note: on this machine,
`powershell.exe` (5.1) picks up PowerShell 7's incompatible `PowerShellGet` module
because `$env:PSModulePath` lists `...\PowerShell\7\Modules` ahead of the 5.1 inbox
module path — `Install-Module` under `powershell.exe` fails with "module could not be
loaded" for this reason. Always install/run Pester via `pwsh`, not `powershell.exe`.

```powershell
# Full suite (includes one ~15-20s test that deliberately locks a destination file
# to verify Robocopy failure handling)
Invoke-Pester -Path .\Tests -Output Detailed

# Fast subset only, skipping that slow test
$cfg = New-PesterConfiguration
$cfg.Run.Path = '.\Tests'
$cfg.Filter.ExcludeTag = 'Slow'
Invoke-Pester -Configuration $cfg
```

Tests create their own throwaway source/dest/log folders under the system temp
directory (cleaned up in `AfterAll`) — they never write into the repo itself. If you add
a test, follow that pattern rather than writing into `Logs\` or elsewhere in the repo.
