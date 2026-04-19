# PerfoMace v2

PerfoMace v2 is a macOS launcher for running app-side performance checks on the iHeart mobile app.

What it is good for:
- launch timing
- login/logout timing
- search timing
- image loading timing
- play-start timing for radio, podcast, and playlist flows
- app-side CPU and memory traces when supported by Instruments

What it is not:
- it is not true backend load testing
- it drives one app on one device at a time
- it does not simulate hundreds or thousands of concurrent users
- it does not pressure-test backend services, databases, autoscaling, or queue depth

If you need real load testing, use backend/API tools such as:
- `k6`
- `Locust`
- `JMeter`

## What You Need On Mac

1. Xcode
   Install Xcode from the Mac App Store.

2. Xcode Command Line Tools

```bash
xcode-select --install
```

3. Homebrew

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

4. Python 3

```bash
brew install python
python3 --version
```

5. Accept Xcode first-run setup

```bash
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
```

## What You Need On iPhone

- the device must be trusted by the Mac
- Developer Mode should be enabled on the phone
- the app build should be installable from Xcode
- for deeper Instruments traces, the build may need profiling-friendly signing / entitlements from the dev team

## Easiest Way To Start

Open the packaged launcher app:

- `launcher/dist/PerfoMace Launcher v2.app`

If macOS blocks the app the first time:

```bash
xattr -dr com.apple.quarantine "launcher/dist/PerfoMace Launcher v2.app"
open "launcher/dist/PerfoMace Launcher v2.app"
```

## If You Want To Build The Launcher Yourself

```bash
cd "/path/to/PerfoMace v2"
xcodebuild -project "PerfoMace.xcodeproj" -scheme PerfoMaceLauncher -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO build
```

## If You Want To Build The iPhone Test Harness Yourself

```bash
cd "/path/to/PerfoMace v2"
xcodebuild -project "PerfoMace.xcodeproj" -scheme PerfoMace -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build-for-testing
```

## If You Want To Run From Terminal Instead Of The Launcher

QA:

```bash
cd "/path/to/PerfoMace v2"
PERF_APP=qa ./codebase/run_perf.sh
```

Legacy:

```bash
cd "/path/to/PerfoMace v2"
PERF_APP=legacy ./codebase/run_perf.sh
```

## Setup Check / Self-Heal

PerfoMace includes a separate ready-check script so teammates can validate the Mac before starting a run.

Run this from the project root:

```bash
cd "/path/to/PerfoMace v2"
bash ./PerfoMace_Ready_Check.sh
```

It will try to self-heal common local issues such as:
- broken `TMPDIR`
- missing writable temp folder
- bad current Xcode developer directory for this shell session

When everything is healthy, it will print:

- `PerfoMace setup check complete. Ready to go.`

If the Mac still needs manual help, it will stop early and tell you exactly what to run next.

## How To Run

1. Open the launcher.
2. Choose the target app:
   - `QA`
   - `Legacy QA`
   - `Custom`
   - `Combined`
   - `Compare`
3. If needed, tick only the scenarios you want to run.
4. Start the run.

## Where Results Go

Every normal run creates its own timestamped folder inside:

- `results/`

Examples:
- `results/QA_PerfoMace_2026-04-07T21-34-44`
- `results/Legacy_PerfoMace_2026-04-07T21-34-44`

Inside each run folder you should see files like:
- `PerformanceReport.html`
- `PerformanceReport.csv`
- `PerformanceReport.json`
- `PerformanceReport.txt`
- `perf.log`

Combined and manual compare outputs are stored in their own timestamped folders under:
- `results/combined_sessions`
- `results/compared_reports`

## Important Notes

- `Allocations` and `Leaks` may fail on real devices if profiling privileges are not available.
- `Time Profiler` can sometimes export incomplete numeric summaries.
- This tool is best for app-side performance comparison, not server-side capacity testing.

## Quick Troubleshooting

If Python is missing:

```bash
brew install python
```

If Xcode cannot see the iPhone:

```bash
xcrun xctrace list devices
```

If the script says `bad substitution`:

- that usually means the Mac is using Apple Bash 3.2
- this package now includes a compatible script, so ask the teammate to use the latest shared zip

If the script says `No USB device found`:

- connect and unlock the iPhone
- tap `Trust` if prompted
- make sure Developer Mode is enabled on the phone

If the script says `No available simulator destination could be resolved`:

```bash
xcrun simctl list devices
open -a Simulator
```

Then boot one available iPhone simulator from Xcode or the Simulator app and rerun.

If the script says `Swift CLI health check failed` or mentions `couldNotFindTmpDir(...)`:

```bash
echo "$TMPDIR"
ls -ld "$TMPDIR"
xcrun swiftc --version
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -runFirstLaunch
```

If you want to confirm Xcode can build before running:

```bash
cd "/path/to/PerfoMace v2"
xcodebuild -project "PerfoMace.xcodeproj" -scheme PerfoMaceLauncher -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO build
xcodebuild -project "PerfoMace.xcodeproj" -scheme PerfoMace -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build-for-testing
```

If the launcher app will not open:

```bash
xattr -dr com.apple.quarantine "launcher/dist/PerfoMace Launcher v2.app"
open "launcher/dist/PerfoMace Launcher v2.app"
```
