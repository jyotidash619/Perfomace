## PerfoMace Launcher (macOS GUI)

You asked for a simple GUI so you can click and run without living in Terminal.

### Design (recommended)

- **UI**: a small macOS SwiftUI app with:
  - dropdown: **QA** vs **Legacy QA**
  - text fields: email/password (optional; can leave blank to use defaults)
  - toggles:
    - Instruments: Energy / Leaks / Network
    - Reset simulator
    - Strict ads (fail instead of bypass)
  - button: **Run**
  - live log view
  - button: **Open Results**

- **Execution**: the app runs `codebase/run_perf.sh` via `Process()` and passes env vars:
  - `PERF_APP=qa|legacy`
  - `PERF_EMAIL`, `PERF_PASSWORD`
  - `PERF_AD_BEHAVIOR`
  - `INSTRUMENTS=1`, `INSTRUMENTS_NETWORK=1`, `RESET_SIM=1`, etc.

- **Output**: on completion it opens:
  - `results/Performance.xcresult` (Xcode)
  - `results/PerformanceReport.html` (browser)

### Why this is “no command-line dependency”

You still need Xcode installed (because `xcodebuild`, `xcresulttool`, `xctrace` are Xcode tools), but you won’t need to manually run commands—just click **Run**.

### Next step

The GUI source now lives under `launcher/PerfoMaceLauncher/` inside the shared `PerfoMace.xcodeproj`.
