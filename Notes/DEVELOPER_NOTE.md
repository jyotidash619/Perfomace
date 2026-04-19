# PerfoMace v2 Developer Note

This note is for engineers who need to understand how `PerfoMace v2` runs, what it measures, and where the outputs come from.

## Goal

`PerfoMace v2` is a launcher-driven performance harness for iHeart app validation across QA / Legacy QA / Custom bundle IDs.

It is designed to give the team:

- repeatable UI performance timings
- shareable HTML / JSON / CSV / TXT reports
- required Instruments coverage for:
  - CPU
  - memory
  - network

## High-Level Flow

1. The macOS launcher collects configuration from the UI.
2. The launcher starts [`codebase/run_perf.sh`](/Users/jyotidash/Desktop/PerfoMace%20v2/codebase/run_perf.sh).
3. `codebase/run_perf.sh` runs the XCTest / XCUITest performance suite.
4. After the test pass, `codebase/run_perf.sh` runs a dedicated Instruments pass.
5. [`codebase/scripts/perf_report.py`](/Users/jyotidash/Desktop/PerfoMace%20v2/codebase/scripts/perf_report.py) builds:
   - `PerformanceReport.html`
   - `PerformanceReport.json`
   - `PerformanceReport.csv`
   - `PerformanceReport.txt`
6. Timestamped share copies are also written into `results/`.

## Why Instruments Runs After UI Tests

Some scenarios background the app or reopen it, and that can interfere with attached tracing.

Because of that, the design is modular:

- XCTest timings measure the functional scenarios.
- Instruments runs as a separate capture phase after the main test pass.

This keeps the trace capture more stable and avoids mixing UI test control flow with trace attachment behavior.

## Current Instruments Strategy

The current required trace set is:

- `Activity Monitor`
  - used for CPU and memory
  - attached to the app process
- `Network`
  - attached to the app process
  - exported as HAR for request-level reporting

Optional:

- `Leaks`
  - best-effort only
  - not part of the required path

### Why We Use This Approach

Older approaches using `Allocations` or `Energy Log` were less reliable in unattended CLI runs:

- `Allocations` does not behave well with `--all-processes`
- `Network` can pause on a privacy prompt if `--no-prompt` is not used
- `Time Profiler` is useful for deep analysis, but its exported data shape is harder to turn into simple report numbers

`Activity Monitor + Network` gives us the best operational balance for team reporting.

## What the Report Measures

### Scenario timings

Scenario `Time` values come from the UI tests and represent how long a user-visible flow takes.

Examples:

- `Cold Launch`
  - terminated app -> app becomes interactive
- `Warm Resume`
  - app backgrounded -> reopened -> interactive
- `Search`
  - open search -> enter query -> open result -> playback UI reaches started state
- `Radio / Podcast / Playlist Play Start`
  - open content -> select playable item -> wait for playback-start indicators

### Important note on playback start

Playback start is currently measured from UI state, not from audio waveform analysis.

That means the timer ends when the app exposes playback-start indicators such as:

- Now Playing UI
- stop / pause controls
- mini-player / playback state controls

This is intentional because it is stable in automated UI testing and maps to what a user sees.

## Report Outputs

Stable outputs:

- `results/PerformanceReport.html`
- `results/PerformanceReport.json`
- `results/PerformanceReport.csv`
- `results/PerformanceReport.txt`

Timestamped share copies:

- `results/Perf Report YYYY-MM-DD HH-MM-SS.html`
- `results/Perf Report YYYY-MM-DD HH-MM-SS.json`
- `results/Perf Report YYYY-MM-DD HH-MM-SS.csv`
- `results/Perf Report YYYY-MM-DD HH-MM-SS.txt`

Important:

- `PerformanceReport.csv` is overwritten every run.
- The timestamped `Perf Report ...csv` files are the ones to keep if you want historical run snapshots.

## Why a Teammate Might “Only Get the CSV Once”

The most common reasons are:

1. They only looked at `PerformanceReport.csv`
   - that file is the latest run only
   - it gets overwritten

2. Later runs failed before report generation completed
   - in that case there may be no new timestamped copy

3. `python3` is missing
   - config resolution and report generation depend on Python 3
   - the script now fails fast with a clear message if `python3` is unavailable

## Dependencies

Required on teammate machines:

- Xcode
- Xcode Command Line Tools
- `python3`

`python3` is used for:

- config parsing
- scheme mutation
- report generation
- CSV generation

## Relevant Files

- Launcher app:
  - [launcher/PerfoMaceLauncher/Runner.swift](/Users/jyotidash/Desktop/PerfoMace%20v2/launcher/PerfoMaceLauncher/Runner.swift)
  - [launcher/PerfoMaceLauncher/ContentView.swift](/Users/jyotidash/Desktop/PerfoMace%20v2/launcher/PerfoMaceLauncher/ContentView.swift)
- Test runner:
  - [codebase/run_perf.sh](/Users/jyotidash/Desktop/PerfoMace%20v2/codebase/run_perf.sh)
- Reporting:
  - [codebase/scripts/perf_report.py](/Users/jyotidash/Desktop/PerfoMace%20v2/codebase/scripts/perf_report.py)
- UI tests:
  - [codebase/PerfoMaceUITests/iHeartPerfTests.swift](/Users/jyotidash/Desktop/PerfoMace%20v2/codebase/PerfoMaceUITests/iHeartPerfTests.swift)
  - [codebase/PerfoMaceUITests/iHeartLaunchPerfTests.swift](/Users/jyotidash/Desktop/PerfoMace%20v2/codebase/PerfoMaceUITests/iHeartLaunchPerfTests.swift)

## Known Limits

- Instruments attribution on scenario cards is still best-effort mapping unless the trace is captured exactly per scenario.
- Playback start is UI-based, not audio-signal based.
- Real-device trust / signing issues can still block the test runner before performance capture starts.

## Practical Team Guidance

- Use the timestamped CSVs when sharing results with product / QA / leadership.
- Use the HTML report for readable summaries.
- Use `.xcresult` for XCTest debugging.
- Use `.trace` bundles when you need to inspect CPU / memory / network details in Instruments directly.
