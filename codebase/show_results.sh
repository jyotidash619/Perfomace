#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="$PROJECT_ROOT/results"
HTML="$RESULTS_DIR/PerformanceReport.html"
XCRESULT="$RESULTS_DIR/Performance.xcresult"

echo "📂 Results dir: $RESULTS_DIR"

if [ -f "$HTML" ]; then
  echo "✅ Found HTML report: $HTML"
  open "$HTML" >/dev/null 2>&1 &
else
  echo "❌ HTML report not found: $HTML"
  if [ -f "$RESULTS_DIR/perf.log" ]; then
    echo "🛠️ Generating report from perf.log..."
    python3 "$SCRIPT_DIR/scripts/perf_report.py" \
      --xcresult "$XCRESULT" \
      --log "$RESULTS_DIR/perf.log" \
      --out "$HTML" \
      --json "$RESULTS_DIR/PerformanceReport.json" \
      --csv "$RESULTS_DIR/PerformanceReport.csv" \
      --txt "$RESULTS_DIR/PerformanceReport.txt" >/dev/null 2>&1 || true
  fi
  if [ -f "$HTML" ]; then
    echo "✅ Generated HTML report: $HTML"
    open "$HTML" >/dev/null 2>&1 &
  fi
fi

if [ -d "$XCRESULT" ]; then
  echo "✅ Found xcresult bundle: $XCRESULT"
  open -a Xcode "$XCRESULT" >/dev/null 2>&1 || open "$XCRESULT" >/dev/null 2>&1 &
else
  echo "❌ xcresult bundle not found: $XCRESULT"
fi

# Always open results folder as a fallback
open "$RESULTS_DIR" >/dev/null 2>&1 &
echo "If nothing opened, run:"
echo "  open \"$HTML\""
echo "  open \"$XCRESULT\""
