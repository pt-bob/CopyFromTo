# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single self-contained Windows PowerShell script, `CopyFromTo.ps1`, that copies files
matching a name pattern and a last-modified date range from one folder to another
(source/destination can be local or a UNC network share), then verifies the copy.
There is no module manifest and no build step. A Pester integration suite lives in
`Tests\CopyFromTo.Tests.ps1`.

## Running it

```powershell
# Interactive: prompts for file name pattern(s) and MM/yyyy date range
.\CopyFromTo.ps1 -Source 'C:\Data\Reports' -Destination '\\NAS\Archive\Reports'

# Non-interactive, with filters given up front
.\CopyFromTo.ps1 -Source 'C:\Data' -Destination 'D:\Backup' -FileName '*.pdf' -StartDate '1/2024' -EndDate '6/2024'

# Preview only, no copying
.\CopyFromTo.ps1 -Source 'C:\Data' -Destination 'D:\Backup' -DryRun

# Fully unattended (e.g. Task Scheduler): skips every prompt, auto-creates the
# destination, defaults unspecified filters to "all files" / "no date limit"
.\CopyFromTo.ps1 -Source 'C:\Data' -Destination '\\NAS\Backup\Data' -Force
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
   prompt, and later the verification pass — it is the source of truth for "what should
   get copied," independent of what Robocopy itself decides to touch.
2. **Copy (Robocopy).** The same name pattern(s) are passed to `robocopy.exe` as
   file-spec arguments, with the date range translated to `/MAXAGE:yyyyMMdd` /
   `/MINAGE:yyyyMMdd`. Robocopy is used deliberately over `Copy-Item` for its retry/wait
   logic on flaky network shares, multithreading, and native timestamp preservation —
   see the inline comment above the `$roboArgs` block for the specific switches and why
   (in particular `/R:3 /W:5`, overriding Robocopy's default retry count of ~1,000,000
   which will otherwise hang a script indefinitely on a permission error). `-DryRun`
   maps to Robocopy's `/L` (list-only) and skips the destination-creation and
   verification steps entirely.
3. **Verify (PowerShell).** For every file in the PowerShell-computed match list, checks
   the destination has the same name, size, and last-write time (within a 2-second
   tolerance for filesystem timestamp resolution differences). This is intentionally
   *not* a hash/binary comparison — the spec calls for fast name+date verification, not
   correctness-grade integrity checking.

### Key design decisions worth knowing before changing this script

- **Dual filtering (PowerShell computes, Robocopy executes).** Robocopy's own
  `/MAXAGE`/`/MINAGE` are day-granularity and were judged unreliable as the sole source
  of "what got copied" for reporting purposes. PowerShell's `Get-ChildItem` pass is the
  authoritative match list; Robocopy is just the transfer engine. If you change the date
  or name filtering logic, update both the `Get-ChildItem`/`Where-Object` block and the
  `$roboArgs` construction so they stay in agreement.
- **`[datetime]` params, not `[Nullable[datetime]]`.** An earlier version used
  `[Nullable[datetime]]$StartDate` to distinguish "not supplied" from "supplied." That
  broke: PowerShell silently unwraps `Nullable[datetime]` to a plain `DateTime` on
  parameter bind, so `.Value` doesn't exist and returns `$null`, and a later `.ToString()`
  call throws "You cannot call a method on a null-valued expression." Presence is now
  detected via `$PSBoundParameters.ContainsKey('StartDate'|'EndDate')` instead. Don't
  reintroduce `Nullable[datetime]` for the same reason.
- **`ConvertTo-MonthYearDate`'s `[datetime]::TryParseExact` call needs two specific
  workarounds**, both only reachable via the interactive date prompt (every other test
  bypasses it with `-Force`/explicit `-StartDate`/`-EndDate`, which is why this shipped
  once already): (1) the `[ref]$parsed` target must start as `[datetime]::MinValue`, not
  `$null` — Windows PowerShell 5.1 can't resolve the overload when the ref target is
  untyped/null and throws "Cannot find an overload for TryParseExact." (2) the format
  list must be explicitly cast `[string[]]@('MM/yyyy', 'M/yyyy')` — an uncast `@(...)`
  literal resolves to `Object[]`, which doesn't throw but makes `TryParseExact` silently
  return `$false` for every input, so valid dates like "04/2026" get rejected with no
  clue why. The `Tests\CopyFromTo.Tests.ps1` "Interactive prompts" context pipes answers
  into the real prompt specifically to keep this path under test.
- **`$PSNativeCommandUseErrorActionPreference` guard at the top.** On PowerShell 7.3+,
  if that preference variable is `$true`, a native command (Robocopy) returning a
  non-zero exit code becomes a terminating error — but Robocopy's exit codes are a
  bitmask where 1–7 mean *success* (see `Get-RobocopyResultDescription`). The script
  force-disables that preference (guarded by a `Test-Path Variable:` check for PS 5.1
  compatibility) so exit-code handling stays consistent across PowerShell versions.
- **`-Force` has two roles**: skip the confirmation prompt *and* skip the interactive
  filter prompts (defaulting missing filters to "all/unbounded") *and* auto-create a
  missing destination folder. It was deliberately not split into separate switches to
  keep the parameter surface small — this is what makes the script usable unattended
  (e.g. Task Scheduler).
- **Script exit codes**: `0` success/nothing-to-do, `1` verification found
  missing/mismatched files, `2` fatal error or Robocopy copy error, `3` user cancelled
  (declined confirmation or declined destination creation). Preserve these if you touch
  the exit paths — they're meant to be automation-friendly.
- **Logging**: two log files per run under `Logs\` (next to the script by default, or
  `-LogFolder`), timestamped `CopyFromTo_<runStamp>.log` (script-level narrative, via
  `Write-Log`) and `CopyFromTo_<runStamp>_robocopy.log` (Robocopy's own per-file log,
  via `/LOG:` + `/TEE`). Keep these separate rather than merging — Robocopy's log format
  doesn't mix cleanly with the script's own log lines.
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
  result. If you touch this parameter, keep both call shapes working.

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
