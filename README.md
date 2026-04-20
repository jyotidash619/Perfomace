# PerfoMace v2

PerfoMace v2 is a macOS-based performance harness for the iHeart mobile app.

It is designed for app-side performance checks such as:
- cold launch
- warm resume
- login and logout
- search
- image loading
- radio / podcast / playlist play start
- app-side Instruments traces like CPU and memory when supported

It is not a backend load-testing tool. It runs one app on one device at a time. For true backend load testing, use tools like `k6`, `Locust`, or `JMeter`.

## What You Need

### On Mac

1. Xcode
2. Xcode Command Line Tools
3. Python 3
4. A trusted iPhone, or an available iOS Simulator

Install the basics:

```bash
xcode-select --install
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install python
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
```

### On iPhone

- Trust the Mac
- Enable Developer Mode
- Make sure the app build is installable from Xcode

## Quick Start

Clone the repo and go to the project root:

```bash
git clone https://github.com/jyotidash619/Perfomace.git
cd Perfomace
```

If you are cloning from Git and building in Xcode, read the `Bundle Identifier / Signing` note below before trying a real-device run.

## How To Share This Repo

Send teammates this link:

- [https://github.com/jyotidash619/Perfomace](https://github.com/jyotidash619/Perfomace)

If the repo is private, add them as a collaborator in GitHub first.

What they should run after opening the repo:

```bash
git clone https://github.com/jyotidash619/Perfomace.git
cd Perfomace
```

Then they can follow this README for setup, run the ready check, and launch PerfoMace.

Open the launcher app:

- `launcher/dist/PerfoMace Launcher v2.app`

If macOS blocks it:

```bash
xattr -dr com.apple.quarantine "launcher/dist/PerfoMace Launcher v2.app"
open "launcher/dist/PerfoMace Launcher v2.app"
```

## Ready Check

Before a first run, use the separate readiness check.

Terminal version:

```bash
bash ./PerfoMace_Ready_Check.sh
```

Double-click app:

- `launcher/dist/PerfoMace Ready Check.app`

If macOS blocks that app:

```bash
xattr -dr com.apple.quarantine "launcher/dist/PerfoMace Ready Check.app"
open "launcher/dist/PerfoMace Ready Check.app"
```

The ready check validates:
- `TMPDIR`
- Xcode developer directory
- `xcrun swiftc --version`
- `xcodebuild`
- `python3`
- at least one usable iOS target
- Apple Development signing identity readiness
- results folder readiness

The launcher now shows the same setup data in a `Setup Readiness` panel before each run.
The double-click Ready Check app also shows a guided summary dialog with blockers, warnings, and fix steps instead of only dropping you into Terminal.

Success output:

- `PerfoMace setup check complete. Ready to go.`

PerfoMace also validates that the selected QA or Legacy app is already installed on the chosen simulator or iPhone before starting the full run.
On a physical iPhone, if Xcode has no signed-in Apple account or no provisioning profile for the PerfoMace app / UI test runner, PerfoMace now stops after the build failure with a direct signing message and skips standalone Instruments noise by default.

## Bundle Identifier / Signing

If you are using the shared zip and just opening the packaged launcher app, you usually do not need to touch bundle identifiers.

If you are cloning from Git and building from Xcode, bundle identifiers matter for iPhone builds and UI tests.

What a bundle identifier is:
- it is the unique app id Xcode tries to register with Apple for signing
- examples in this project are:
  - `atlantis-proxyman.PerfoMace2`
  - `atlantis-proxyman.PerfoMaceTests2`
  - `atlantis-proxyman.PerfoMaceUITests2`
  - `atlantis-proxyman.PerfoMaceLauncherV2`

When to keep it as-is:
- keep it as-is only if your Apple development team already owns that identifier and Xcode signs successfully

When to change it:
- if Xcode says `Failed Registering Bundle Identifier`
- if it says the identifier `cannot be registered` or `is not available`
- if you are using your own `Personal Team` or a different Apple team from the original project owner

What to change:
- for iPhone runs, change the identifiers for these targets in `Signing & Capabilities` so they are unique for your team:
  - `PerfoMace`
  - `PerfoMaceTests`
  - `PerfoMaceUITests`

Safe example pattern:
- `com.yourname.PerfoMace`
- `com.yourname.PerfoMaceTests`
- `com.yourname.PerfoMaceUITests`

Important:
- each target needs its own unique identifier
- do not give the app target and UI test target the same identifier
- if one target changes, the others do not need to match exactly, they just need to stay unique

For the screenshot error you showed:
- `atlantis-proxyman.PerfoMaceUITests2` is not available for your team
- change only that target to something unique like `com.marksawyer.PerfoMaceUITests`
- if the app target later shows the same error, give `PerfoMace` its own unique id too

After changing the bundle ids:
- keep `Automatically manage signing` on
- choose your team
- press `Try Again`
- rerun the Ready Check or build again

## Running From Terminal

QA:

```bash
PERF_APP=qa ./codebase/run_perf.sh
```

Legacy:

```bash
PERF_APP=legacy ./codebase/run_perf.sh
```

## Running From The Launcher

1. Open `PerfoMace Launcher v2.app`
2. Choose the target:
   - `QA`
   - `Legacy QA`
   - `Custom`
   - `Combined`
   - `Compare`
3. Select scenarios if needed
4. Start the run

## Results

Each normal run creates its own timestamped results folder under `results/`.

Examples:
- `results/QA_PerfoMace_2026-04-07T21-34-44`
- `results/Legacy_PerfoMace_2026-04-07T21-34-44`

Typical files inside a run folder:
- `PerformanceReport.html`
- `PerformanceReport.csv`
- `PerformanceReport.json`
- `PerformanceReport.txt`
- `perf.log`

Other report folders:
- `results/combined_sessions`
- `results/compared_reports`

## Troubleshooting

### If the launcher will not open

```bash
xattr -dr com.apple.quarantine "launcher/dist/PerfoMace Launcher v2.app"
open "launcher/dist/PerfoMace Launcher v2.app"
```

### If the ready check or run mentions `couldNotFindTmpDir(...)`

```bash
echo "$TMPDIR"
ls -ld "$TMPDIR"
xcrun swiftc --version
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -runFirstLaunch
```

### If no USB device is found

- connect and unlock the iPhone
- tap `Trust` if prompted
- enable Developer Mode

### If a real-device run fails with `No Accounts` or missing profiles

- sign in under `Xcode > Settings > Accounts`
- choose a valid signing team/profile for both the app target and UI test runner
- let Xcode finish preparing the device
- rerun PerfoMace

### If Xcode says `Failed Registering Bundle Identifier`

- you are most likely using a different Apple team from the original project owner
- open `Signing & Capabilities`
- select the failing target
- change its bundle identifier to a unique value for your team
- keep `Automatically manage signing` on and press `Try Again`

Common real-device targets to update:
- `PerfoMace`
- `PerfoMaceUITests`
- `PerfoMaceTests`

### If no simulator destination is found

```bash
xcrun simctl list devices
open -a Simulator
```

Then boot an iPhone simulator and rerun.

## Notes

- `Allocations` and `Leaks` may fail on real devices if profiling privileges are unavailable
- `Time Profiler` can sometimes export incomplete summaries
- this tool is best for app-side performance comparison, not server-side capacity testing

For a more detailed handoff guide, see `README_FIRST.md`.
