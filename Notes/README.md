## PerfoMace

A small iOS performance testing harness that:

- runs a curated set of UI performance tests via `xcodebuild`
- saves an `.xcresult` bundle under `results/`
- generates a human-friendly HTML/JSON/TXT report
- (optionally) captures Instruments traces (Energy Log, Leaks, Network)

### Workspace layout

- `launcher/` - macOS SwiftUI GUI
- `codebase/` - test harness, scripts, config, and app/test sources
- `results/` - generated reports, xcresults, and traces
- `Notes/` - repo documentation
- `assets/` - logo and shared media

### Prerequisites (new machine checklist)

- **macOS + Xcode installed** (Xcode 16.4+ recommended)
- **Xcode command line tools selected**

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
```

- **Python 3** available as `python3` (macOS usually includes it; otherwise install via Xcode / Homebrew)
- **If you want hard timeouts** for `xcodebuild` / report generation:
  - macOS may not include `timeout`
  - install GNU coreutils to get `gtimeout`:

```bash
brew install coreutils
```

### Device prerequisites (for real iPhone runs)

- Connect iPhone via USB
- Unlock device
- Tap **Trust This Computer**
- Enable **Developer Mode** (iOS Settings → Privacy & Security → Developer Mode)
- Open Xcode once and let it finish **Preparing** the device:
  - Xcode → Window → Devices and Simulators → select device

### One-time project setup (signing)

The `codebase/run_perf.sh` command uses `-allowProvisioningUpdates`, but the very first run on a new machine may still require you to open Xcode once.

- Open `PerfoMace.xcodeproj` in Xcode
- Select the `PerfoMace` target → **Signing & Capabilities**
- Pick your **Team** and ensure the bundle id can be signed on your machine

### Run (recommended)

From the project root:

```bash
chmod +x codebase/run_perf.sh
./codebase/run_perf.sh
```

Artifacts end up in `results/` and should auto-open.

### GUI (PerfoMaceLauncher)

There is a macOS SwiftUI launcher inside the same Xcode project.

- Open `PerfoMace.xcodeproj`
- Select scheme `PerfoMaceLauncher` and Run
- In the launcher:
  - set the **PerfoMace codebase** once (the folder containing `run_perf.sh`)
  - choose **QA / Legacy QA**
  - click **Run**
  - the HTML report is shown inside the app (and you can open the results folder)

### Configure without editing code

#### Pick which app to test (QA vs Legacy)

Fastest options:

```bash
# choose one
export PERF_APP="qa"      # uses com.clearchannel.iheartradio.qa
export PERF_APP="legacy"  # uses com.clearchannel.iheartradio.legacy.qa
```

You can also set the bundle id directly:

```bash
export PERF_APP_BUNDLE_ID="com.clearchannel.iheartradio.legacy.qa"
```

Or edit `perfomace.config.json` (default app + bundle ids). You can override the config path:

```bash
export PERFOMACE_CONFIG="/path/to/perfomace.config.json"
```

#### Test credentials / behavior

The UI tests read these environment variables:

```bash
export PERF_EMAIL="you@example.com"
export PERF_PASSWORD="yourPassword"

# Ad handling:
# - bypass (default): if an ad blocks the flow, mark the step as passed
# - fail: fail the test if an ad is detected
export PERF_AD_BEHAVIOR="bypass"
```

Optional Instruments pass:

```bash
INSTRUMENTS=1 ./codebase/run_perf.sh
```

Optional simulator reset:

```bash
RESET_SIM=1 ./codebase/run_perf.sh
```

### Troubleshooting

- **Device not found**
  - unlock iPhone, re-plug USB, confirm Trust prompt
  - ensure Developer Mode is enabled
  - in Xcode Devices & Simulators, wait for “Preparing”
- **Signing / install failures**
  - open the project once in Xcode and set the Team for the `PerfoMace` target
- **Report missing**
  - check `results/perf.log`
  - re-run: `./codebase/show_results.sh`
