# PerfoMace Team Run Guide

This guide lets anyone on the team run performance tests with a connected iPhone and automatically open the report.

## Requirements
- macOS with Xcode installed (16.4+ recommended)
- `python3` available
- iPhone connected via USB (trusted) if running on a real device

## First-time setup (new machine)
- Select Xcode command line tools and accept license:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
```

- If you want real timeouts for `xcodebuild` on macOS, install coreutils (optional):

```bash
brew install coreutils
```

- If running on a real iPhone:
  - unlock phone, tap **Trust This Computer**
  - enable **Developer Mode**
  - open Xcode once: Window → Devices and Simulators → wait for “Preparing”

- If app install/signing fails:
  - open `PerfoMace.xcodeproj` once in Xcode and set Signing (Team) for the `PerfoMace` target

## Steps (Quick)
1. Open Terminal in the project root
2. Run:

```bash
chmod +x codebase/run_perf.sh
./codebase/run_perf.sh
```

## Optional configuration (recommended)
You can pick QA vs Legacy QA without editing code:

```bash
export PERF_APP="qa"      # com.clearchannel.iheartradio.qa
# or
export PERF_APP="legacy"  # com.clearchannel.iheartradio.legacy.qa
```

Or set the bundle id explicitly:

```bash
export PERF_APP_BUNDLE_ID="com.clearchannel.iheartradio.legacy.qa"
```

Override login creds if needed:

```bash
export PERF_EMAIL="you@example.com"
export PERF_PASSWORD="yourPassword"

# Ad behavior in UI tests:
# - bypass (default): if an ad blocks the flow, mark the step as passed
# - fail: fail the test if an ad is detected
export PERF_AD_BEHAVIOR="bypass"
```

Optional Instruments run:

```bash
INSTRUMENTS=1 ./codebase/run_perf.sh
```

## What happens
- Automatically selects a connected iPhone (falls back to simulator if none)
- Runs the performance UI tests
- Generates results in `results/`
- Opens the `.xcresult` and the HTML report in the browser

## Output files
- `results/Performance.xcresult`
- `results/PerformanceReport.html`
- `results/PerformanceReport.json`
- `results/PerformanceReport.csv`
- `results/PerformanceReport.txt`
- `results/Perf Report YYYY-MM-DD HH-MM-SS.csv`
- `results/Report_YYYY-MM-DD.zip`

## Troubleshooting
- If the app fails to install, open Xcode once and let it manage signing
- If the device is not detected, check USB cable and trust prompt on iPhone
- If the script never times out, install coreutils (so `gtimeout` is available): `brew install coreutils`
- If you see permission issues, re-run `chmod +x codebase/run_perf.sh`
- If `python3` is missing, the run will now stop immediately with a clear error because config resolution and report generation depend on it
- `PerformanceReport.csv` is the latest stable file and is overwritten every run; use the timestamped `Perf Report ...csv` copies when you want to keep multiple runs
