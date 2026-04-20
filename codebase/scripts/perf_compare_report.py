#!/usr/bin/env python3
import argparse
import csv
import json
import math
import os
import subprocess
from datetime import datetime


APP_LABELS = {
    "qa": "Re-Write",
    "legacy": "Legacy",
    "custom": "Custom",
}

TRACE_PRIORITY = [
    ("Activity Monitor", "% CPU"),
    ("Activity Monitor", "Memory"),
    ("Activity Monitor", "Real Mem"),
    ("Activity Monitor", "CPU Time"),
    ("Network", "Request Count"),
    ("Network", "Request Time (s)"),
    ("Network", "Request Time (ms)"),
    ("Network", "Response Bytes"),
    ("Network", "Request Bytes"),
    ("Time Profiler", "Sample Time"),
    ("Time Profiler", "Core"),
]

_XCDEVICE_CACHE = None


def _read_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def _read_csv_sections(path):
    scenarios = {}
    traces = {}
    section = None
    with open(path, "r", encoding="utf-8", newline="") as f:
        for row in csv.reader(f):
            if not row or not any((cell or "").strip() for cell in row):
                continue
            head = (row[0] or "").strip()
            if head == "Scenario Summary":
                section = "scenarios"
                continue
            if head == "Trace Summary":
                section = "traces"
                continue
            if section == "scenarios":
                if head == "Scenario":
                    continue
                label = head
                avg = _to_float(row[1] if len(row) > 1 else None)
                if label and avg is not None:
                    scenarios[label] = avg
            elif section == "traces":
                if head == "Trace":
                    continue
                trace_name = head
                metric_name = (row[1] or "").strip() if len(row) > 1 else ""
                avg = _to_float(row[2] if len(row) > 2 else None)
                if trace_name and metric_name and avg is not None:
                    traces[(trace_name, metric_name)] = avg
    return scenarios, traces


def _to_float(value):
    text = ("" if value is None else str(value)).strip()
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def _short_os_version(value):
    text = (value or "").strip()
    if not text:
        return ""
    return text.split(" (", 1)[0].strip()


def _target_identifier(run_context):
    destination = (run_context.get("destination") or "").strip()
    real_device_id = (run_context.get("real_device_id") or "").strip()
    simulator_udid = (run_context.get("simulator_udid") or "").strip()

    if real_device_id and real_device_id in destination:
        return real_device_id
    if simulator_udid and simulator_udid in destination:
        return simulator_udid
    if "platform=iOS Simulator" in destination and simulator_udid:
        return simulator_udid
    if "platform=iOS" in destination and real_device_id:
        return real_device_id
    return real_device_id or simulator_udid


def _xcdevice_records():
    global _XCDEVICE_CACHE
    if _XCDEVICE_CACHE is not None:
        return _XCDEVICE_CACHE
    try:
        result = subprocess.run(
            ["xcrun", "xcdevice", "list"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15,
        )
        _XCDEVICE_CACHE = json.loads(result.stdout)
    except Exception:
        _XCDEVICE_CACHE = []
    return _XCDEVICE_CACHE


def _compose_device_label(model_name, device_name, os_version, is_simulator):
    primary = (model_name or "").strip() or (device_name or "").strip()
    os_version = _short_os_version(os_version)
    if is_simulator and primary and "simulator" not in primary.lower():
        primary = f"{primary} Simulator"
    if primary and os_version:
        return f"{primary} • iOS {os_version}"
    return primary or ""


def _resolve_device_label(run_context):
    display_name = (run_context.get("device_display_name") or "").strip()
    if display_name:
        return display_name

    model_name = (run_context.get("device_model") or "").strip()
    device_name = (run_context.get("device_name") or "").strip()
    os_version = _short_os_version(run_context.get("device_os_version") or run_context.get("device_os_build"))
    kind = (run_context.get("device_kind") or "").strip()
    if model_name or device_name or os_version:
        return _compose_device_label(model_name, device_name, os_version, kind == "simulator")

    target_id = _target_identifier(run_context)
    if target_id:
        for device in _xcdevice_records():
            if str(device.get("identifier") or "").strip() != target_id:
                continue
            return _compose_device_label(
                str(device.get("modelName") or "").strip(),
                str(device.get("name") or "").strip(),
                device.get("operatingSystemVersion"),
                bool(device.get("simulator")),
            )

    destination = (run_context.get("destination") or "").strip()
    return destination or target_id or ""


def _mean(values):
    nums = [float(v) for v in values if v is not None]
    if not nums:
        return None
    return sum(nums) / len(nums)


def _escape(value):
    s = "" if value is None else str(value)
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def _slug(value):
    return "".join(ch.lower() if ch.isalnum() else "-" for ch in str(value)).strip("-")


def _collect_scenarios(payload):
    cards = payload.get("scenario_cards") or []
    if cards:
        values = {}
        for card in cards:
            timing = card.get("timing") or {}
            label = (card.get("label") or "").strip()
            if label:
                values[label] = timing.get("mean")
        return values
    summary = payload.get("custom_timings_summary") or {}
    return {name: stats.get("mean") for name, stats in summary.items()}


def _collect_trace_metrics(payload):
    traces = payload.get("trace_summaries") or {}
    values = {}
    for trace_name, info in traces.items():
        summary = info.get("summary") or {}
        for metric_name, stats in summary.items():
            values[(trace_name, metric_name)] = stats.get("avg")
    return values


def _collect_csv_overrides(session_dir, step):
    csv_name = (step.get("csvFile") or "").strip()
    if not csv_name:
        return None, None
    csv_path = os.path.join(session_dir, csv_name)
    if not os.path.exists(csv_path):
        return None, None
    return _read_csv_sections(csv_path)


def _preferred_trace_order(metric_keys):
    ordered = []
    seen = set()
    for preferred in TRACE_PRIORITY:
        if preferred in metric_keys and preferred not in seen:
            ordered.append(preferred)
            seen.add(preferred)
    for key in sorted(metric_keys):
        if key not in seen:
            ordered.append(key)
            seen.add(key)
    return ordered


def _format_number(value, digits=2):
    if value is None:
        return "n/a"
    return f"{float(value):,.{digits}f}"


def _format_percent(value):
    if value is None:
        return "n/a"
    return f"{value:+.1f}%"


def _bytes_to_human(value):
    num = float(value)
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if abs(num) < 1024.0 or unit == "TB":
            return f"{num:,.1f} {unit}"
        num /= 1024.0
    return f"{num:,.1f} TB"


def _format_metric_value(name, value):
    if value is None:
        return "n/a"
    metric = (name or "").lower()
    value = float(value)
    if "memory" in metric or " mem" in metric or "bytes" in metric or "disk " in metric:
        return _bytes_to_human(value)
    if metric in {"sample time", "cpu time"}:
        if abs(value) >= 1_000_000:
            return f"{value / 1_000_000_000:.2f} s"
        return f"{value:.2f} s"
    if "request time (ms)" in metric:
        return f"{value:.1f} ms"
    if "request time (s)" in metric:
        return f"{value:.2f} s"
    if metric == "% cpu":
        return f"{value:.1f}%"
    if metric in {"thread", "process", "core", "weight", "request count", "http error count"}:
        return _format_number(value, 0)
    return _format_number(value, 2)


def _chart_numeric_value(name, value):
    if value is None:
        return None
    metric = (name or "").lower()
    value = float(value)
    if "memory" in metric or " mem" in metric or "bytes" in metric or "disk " in metric:
        return value / (1024.0 * 1024.0)
    if metric in {"sample time", "cpu time"} and abs(value) >= 1_000_000:
        return value / 1_000_000_000.0
    return value


def _percent_diff(qa_value, legacy_value):
    if legacy_value in (None, 0) or qa_value is None:
        return None
    return ((float(legacy_value) - float(qa_value)) / float(legacy_value)) * 100.0


def _build_grouped_bar_rows(metrics, qa_values, legacy_values, formatter, row_height=30):
    if not metrics:
        return "<div class='muted'>No scenario bars available for this comparison.</div>"
    max_value = max(
        [v for v in list(qa_values.values()) + list(legacy_values.values()) if v is not None] or [1.0]
    )
    width = 1020
    left = 250
    chart_width = 700
    bar_gap = 5
    bar_height = 9
    rows = []
    for index, name in enumerate(metrics):
        qa = qa_values.get(name)
        legacy = legacy_values.get(name)
        y = 28 + index * row_height
        qa_width = 0 if qa is None else max(2, (float(qa) / max_value) * chart_width)
        legacy_width = 0 if legacy is None else max(2, (float(legacy) / max_value) * chart_width)
        rows.append(
            f"<text x='0' y='{y + 8}' class='axis-label'>{_escape(name)}</text>"
            f"<rect x='{left}' y='{y - 4}' width='{chart_width}' height='11' rx='6' class='track'/>"
            f"<rect x='{left}' y='{y - 4}' width='{qa_width}' height='{bar_height}' rx='6' class='qa-bar'/>"
            f"<rect x='{left}' y='{y + bar_gap + 1}' width='{legacy_width}' height='{bar_height}' rx='6' class='legacy-bar'/>"
            f"<text x='{left + chart_width + 14}' y='{y + 4}' class='value-label'>{_escape(formatter(qa))}</text>"
            f"<text x='{left + chart_width + 14}' y='{y + 18}' class='value-label'>{_escape(formatter(legacy))}</text>"
        )
    height = 44 + len(metrics) * row_height
    return f"<svg viewBox='0 0 {width} {height}' class='chart grouped-chart'>{''.join(rows)}</svg>"


def _build_vertical_grouped_chart(metrics, qa_values, legacy_values, formatter, chart_id, qa_label="Re-Write", legacy_label="Legacy"):
    if not metrics:
        return "<div class='muted'>No bars available for this comparison.</div>"
    width = max(720, 120 + (len(metrics) * 110))
    height = 330
    left = 54
    right = 22
    top = 16
    bottom = 108
    chart_height = height - top - bottom
    chart_width = width - left - right
    max_value = max(
        [v for v in list(qa_values.values()) + list(legacy_values.values()) if v is not None] or [1.0]
    )
    column_width = chart_width / max(len(metrics), 1)
    bar_width = min(30, (column_width - 18) / 2)
    rows = [
        f"<line x1='{left}' y1='{top + chart_height}' x2='{left + chart_width}' y2='{top + chart_height}' class='baseline'/>"
    ]
    for index, name in enumerate(metrics):
        group_left = left + (index * column_width)
        qa_value = qa_values.get(name)
        legacy_value = legacy_values.get(name)
        qa_height = 0 if qa_value is None else (float(qa_value) / max_value) * chart_height
        legacy_height = 0 if legacy_value is None else (float(legacy_value) / max_value) * chart_height
        qa_x = group_left + 16
        legacy_x = qa_x + bar_width + 8
        qa_y = top + chart_height - qa_height
        legacy_y = top + chart_height - legacy_height
        rows.append(f"<rect x='{qa_x:.1f}' y='{qa_y:.1f}' width='{bar_width:.1f}' height='{max(qa_height, 2):.1f}' rx='8' class='bar-qa'/>")
        rows.append(f"<rect x='{legacy_x:.1f}' y='{legacy_y:.1f}' width='{bar_width:.1f}' height='{max(legacy_height, 2):.1f}' rx='8' class='bar-legacy'/>")
        rows.append(f"<text x='{qa_x + (bar_width / 2):.1f}' y='{max(14, qa_y - 6):.1f}' text-anchor='middle' class='bar-value'>{_escape(formatter(qa_value))}</text>")
        rows.append(f"<text x='{legacy_x + (bar_width / 2):.1f}' y='{max(14, legacy_y - 6):.1f}' text-anchor='middle' class='bar-value'>{_escape(formatter(legacy_value))}</text>")
        label_x = group_left + (column_width / 2)
        label_y = top + chart_height + 16
        rows.append(
            f"<text x='{label_x:.1f}' y='{label_y:.1f}' transform='rotate(-38 {label_x:.1f} {label_y:.1f})' text-anchor='end' class='bar-label'>{_escape(name)}</text>"
        )
    rows.append(
        "<g>"
        f"<rect x='{left}' y='{height - 32}' width='14' height='10' rx='5' class='bar-legacy'/>"
        f"<text x='{left + 20}' y='{height - 23}' class='legend-text'>{_escape(legacy_label)}</text>"
        f"<rect x='{left + 110}' y='{height - 32}' width='14' height='10' rx='5' class='bar-qa'/>"
        f"<text x='{left + 130}' y='{height - 23}' class='legend-text'>{_escape(qa_label)}</text>"
        "</g>"
    )
    return f"<svg id='{_escape(chart_id)}' viewBox='0 0 {width} {height}' class='chart vertical-chart'>{''.join(rows)}</svg>"


def _pick_trace_dashboard_metrics(trace_metrics, qa_trace, legacy_trace, limit=6):
    preferred_names = [
        "CPU Time",
        "Disk Reads",
        "Disk Writes",
        "Memory",
        "Real Mem",
        "Sample Time",
        "% CPU",
        "Request Count",
        "Response Bytes",
        "Request Bytes",
    ]
    chosen = []
    seen = set()
    for preferred_name in preferred_names:
        for trace_name, metric_name in trace_metrics:
            if metric_name != preferred_name:
                continue
            if trace_name != "Activity Monitor" and metric_name not in {"Sample Time"}:
                continue
            if qa_trace.get((trace_name, metric_name)) is None or legacy_trace.get((trace_name, metric_name)) is None:
                continue
            key = (trace_name, metric_name)
            if key in seen:
                continue
            seen.add(key)
            chosen.append(key)
            break
        if len(chosen) >= limit:
            return chosen
    for key in trace_metrics:
        if key in seen:
            continue
        if qa_trace.get(key) is None or legacy_trace.get(key) is None:
            continue
        chosen.append(key)
        if len(chosen) >= limit:
            break
    return chosen


def _dashboard_metric_label(trace_name, metric_name):
    if trace_name == "Activity Monitor":
        return metric_name
    return f"{trace_name}: {metric_name}"


def _build_dashboard_table(rows, headers, kind):
    if not rows:
        return "<div class='muted'>No comparison rows available for this panel.</div>"
    table_rows = ["<div class='dashboard-table-wrap'><table class='dashboard-table'>"]
    table_rows.append("<tr>" + "".join(f"<th>{_escape(header)}</th>" for header in headers) + "</tr>")
    for row in rows:
        delta = row.get("delta")
        delta_class = "delta-flat"
        if delta is not None:
            delta_class = "delta-good" if delta >= 0 else "delta-bad"
        value_suffix = "s" if kind == "scenario" else ""
        metric_name = row["name"]
        rewrite_value = row["qa"]
        legacy_value = row["legacy"]
        if kind == "trace":
            rewrite_text = _format_metric_value(metric_name, rewrite_value)
            legacy_text = _format_metric_value(metric_name, legacy_value)
        else:
            rewrite_text = f"{_format_number(rewrite_value, 3)} {value_suffix}".strip()
            legacy_text = f"{_format_number(legacy_value, 3)} {value_suffix}".strip()
        delta_text = _format_percent(delta)
        table_rows.append(
            "<tr>"
            f"<td class='name'>{_escape(metric_name)}</td>"
            f"<td>{_escape(legacy_text)}</td>"
            f"<td>{_escape(rewrite_text)}</td>"
            f"<td class='{delta_class}'>{_escape(delta_text)}</td>"
            "</tr>"
        )
    table_rows.append("</table></div>")
    return "".join(table_rows)


def _build_delta_chart(metrics, qa_values, legacy_values):
    if not metrics:
        return "<div class='muted'>No scenario deltas available for this comparison.</div>"
    width = 1020
    left = 250
    chart_width = 700
    center = left + chart_width / 2
    max_delta = max(abs(_percent_diff(qa_values.get(name), legacy_values.get(name)) or 0) for name in metrics) or 1.0
    rows = []
    for index, name in enumerate(metrics):
        delta = _percent_diff(qa_values.get(name), legacy_values.get(name))
        y = 30 + index * 34
        rows.append(f"<text x='0' y='{y + 4}' class='axis-label'>{_escape(name)}</text>")
        rows.append(f"<line x1='{left}' y1='{y}' x2='{left + chart_width}' y2='{y}' class='delta-track'/>")
        rows.append(f"<line x1='{center}' y1='{y - 12}' x2='{center}' y2='{y + 12}' class='delta-center'/>")
        if delta is not None:
            delta_width = (abs(delta) / max_delta) * (chart_width / 2)
            if delta >= 0:
                x = center
                klass = "delta-better"
            else:
                x = center - delta_width
                klass = "delta-worse"
            rows.append(f"<rect x='{x}' y='{y - 8}' width='{max(delta_width, 2)}' height='16' rx='8' class='{klass}'/>")
            rows.append(f"<text x='{left + chart_width + 14}' y='{y + 4}' class='value-label'>{_escape(_format_percent(delta))}</text>")
        else:
            rows.append(f"<text x='{left + chart_width + 14}' y='{y + 4}' class='value-label'>n/a</text>")
    height = 40 + len(metrics) * 34
    return f"<svg viewBox='0 0 {width} {height}' class='chart delta-chart'>{''.join(rows)}</svg>"


def _build_heatmap(metrics, step_runs, scenario_matrix):
    if not metrics or not step_runs:
        return "<div class='muted'>No per-pass heatmap available for this comparison.</div>"
    table = ["<div class='heatmap-wrap'><table class='heatmap'><tr><th>Scenario</th>"]
    for step in step_runs:
        table.append(f"<th>{_escape(step['title'])}</th>")
    table.append("</tr>")
    for metric in metrics:
        values = [scenario_matrix.get(metric, {}).get(step["title"]) for step in step_runs]
        numeric = [float(v) for v in values if v is not None]
        max_v = max(numeric) if numeric else 1.0
        min_v = min(numeric) if numeric else 0.0
        span = max(max_v - min_v, 1e-9)
        table.append(f"<tr><td>{_escape(metric)}</td>")
        for value in values:
            if value is None:
                table.append("<td class='heatmap-empty'>n/a</td>")
                continue
            ratio = (float(value) - min_v) / span if span else 0.0
            opacity = 0.22 + (ratio * 0.62)
            table.append(
                f"<td style='background:rgba(18,82,196,{opacity:.3f})'>{_escape(_format_number(value, 2))}</td>"
            )
        table.append("</tr>")
    table.append("</table></div>")
    return "".join(table)


def _build_sparkline_card(name, values, titles):
    width = 280
    height = 90
    points = []
    filtered = [float(v) for v in values if v is not None]
    min_v = min(filtered) if filtered else 0.0
    max_v = max(filtered) if filtered else 1.0
    span = max(max_v - min_v, 1e-9)
    for index, value in enumerate(values):
        x = 16 + (index * ((width - 32) / max(len(values) - 1, 1)))
        if value is None:
            y = height - 24
        else:
            y = 18 + ((max_v - float(value)) / span) * (height - 40)
        points.append((x, y, value))
    polyline = " ".join(f"{x:.1f},{y:.1f}" for x, y, _ in points)
    circles = []
    labels = []
    for index, (x, y, value) in enumerate(points):
        klass = "qa-point" if "Re-Write" in titles[index] else "legacy-point"
        circles.append(f"<circle cx='{x:.1f}' cy='{y:.1f}' r='4.5' class='{klass}'/>")
        labels.append(f"<text x='{x:.1f}' y='{height - 6}' class='spark-x'>{_escape(titles[index])}</text>")
        if value is not None:
            circles.append(
                f"<text x='{x:.1f}' y='{max(12, y - 8):.1f}' text-anchor='middle' class='spark-y'>{_escape(_format_number(value, 2))}</text>"
            )
    return (
        "<div class='spark-card'>"
        f"<div class='spark-title'>{_escape(name)}</div>"
        f"<svg viewBox='0 0 {width} {height}' class='sparkline'>"
        f"<polyline points='{polyline}' class='spark-path'/>"
        f"{''.join(circles)}{''.join(labels)}</svg></div>"
    )


def _build_trace_cards(trace_metrics, qa_trace, legacy_trace):
    cards = []
    for trace_name, metric_name in trace_metrics:
        qa_value = qa_trace.get((trace_name, metric_name))
        legacy_value = legacy_trace.get((trace_name, metric_name))
        max_value = max([float(v) for v in [qa_value, legacy_value] if v is not None] or [0.0])
        scale = max_value if max_value > 0 else 1.0
        qa_pct = 0 if qa_value is None else (float(qa_value) / scale) * 100
        legacy_pct = 0 if legacy_value is None else (float(legacy_value) / scale) * 100
        delta = _percent_diff(qa_value, legacy_value)
        cards.append(
            "<div class='trace-card'>"
            f"<div class='trace-kicker'>{_escape(trace_name)}</div>"
            f"<div class='trace-title'>{_escape(metric_name)}</div>"
            "<div class='trace-row'><span>Re-Write</span>"
            f"<div class='mini-track'><div class='qa-bar' style='width:{qa_pct:.1f}%'></div></div>"
            f"<strong>{_escape(_format_metric_value(metric_name, qa_value))}</strong></div>"
            "<div class='trace-row'><span>Legacy</span>"
            f"<div class='mini-track'><div class='legacy-bar' style='width:{legacy_pct:.1f}%'></div></div>"
            f"<strong>{_escape(_format_metric_value(metric_name, legacy_value))}</strong></div>"
            f"<div class='trace-delta'>{_escape(_format_percent(delta))} improvement vs Legacy baseline</div>"
            "</div>"
        )
    return "".join(cards)


def _build_grouped_chart_legend():
    return (
        "<div class='chart-legend' aria-label='Grouped bar legend'>"
        "<div class='legend-item'><span class='legend-swatch legend-qa'></span><span>Re-Write</span></div>"
        "<div class='legend-item'><span class='legend-swatch legend-legacy'></span><span>Legacy</span></div>"
        "</div>"
    )


def _write_csv(path, scenario_names, step_runs, qa_agg, legacy_agg, trace_metrics, qa_trace, legacy_trace):
    with open(path, "w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["Scenario Comparison"])
        writer.writerow(["Scenario", "Re-Write Average", "Legacy Average", "Improvement vs Legacy %"])
        for name in scenario_names:
            writer.writerow([
                name,
                qa_agg.get(name),
                legacy_agg.get(name),
                _percent_diff(qa_agg.get(name), legacy_agg.get(name)),
            ])
        writer.writerow([])
        writer.writerow(["Pass Sequence"])
        writer.writerow(["Scenario"] + [step["title"] for step in step_runs])
        for name in scenario_names:
            row = [name]
            for step in step_runs:
                row.append(step["scenarios"].get(name))
            writer.writerow(row)
        writer.writerow([])
        writer.writerow(["Trace Comparison"])
        writer.writerow(["Trace", "Metric", "Re-Write Average", "Legacy Average", "Improvement vs Legacy %"])
        for trace_name, metric_name in trace_metrics:
            writer.writerow([
                trace_name,
                metric_name,
                qa_trace.get((trace_name, metric_name)),
                legacy_trace.get((trace_name, metric_name)),
                _percent_diff(qa_trace.get((trace_name, metric_name)), legacy_trace.get((trace_name, metric_name))),
            ])


def _build_html(payload):
    scenario_names = payload["scenario_names"]
    ordered_scenarios = payload["ordered_scenarios"]
    qa_agg = payload["aggregated"]["qa"]["scenarios"]
    legacy_agg = payload["aggregated"]["legacy"]["scenarios"]
    qa_trace = payload["aggregated"]["qa"]["traces"]
    legacy_trace = payload["aggregated"]["legacy"]["traces"]
    step_runs = payload["step_runs"]
    trace_metrics = payload["trace_metrics"]
    scenario_matrix = payload["scenario_matrix"]

    logo_path = payload.get("logo_path")
    device_label = payload.get("device_label") or ""
    sequence_label = payload.get("sequence_label") or "Re-Write -> Legacy"
    report_mode = payload.get("report_mode") or "combined"
    pass_count = len(step_runs)
    pass_label = "pass" if pass_count == 1 else "passes"
    hero_title = "Compared Report" if report_mode == "manual" else "Combined App Comparison"
    hero_copy = (
        "Two saved report snapshots were selected in the launcher and compared instantly. This page turns those picked Re-Write and Legacy results into grouped bars, deltas, heatmaps, and trace cards."
        if report_mode == "manual"
        else "Re-Write and Legacy were run back-to-back in a fixed Re-Write -> Legacy sequence. This page combines the two snapshots into multiple chart views so differences are visible at a glance."
    )
    cards = []
    total_delta_values = [_percent_diff(qa_agg.get(name), legacy_agg.get(name)) for name in scenario_names]
    cards.append(("Scenario Set", str(len(scenario_names)), "Compared across both apps"))
    cards.append(("Sequence", sequence_label, f"{pass_count} back-to-back {pass_label}"))
    if device_label:
        cards.append(("Device", device_label, "Shared hardware across captured passes"))
    cards.append(("Largest Shift", _format_percent(max(total_delta_values, key=lambda v: abs(v) if v is not None else -1, default=None)), "Largest scenario movement vs Legacy"))

    dashboard_scenarios = [
        name for name in ordered_scenarios
        if qa_agg.get(name) is not None and legacy_agg.get(name) is not None
    ][:8]
    if not dashboard_scenarios:
        dashboard_scenarios = ordered_scenarios[:8]
    dashboard_scenario_rows = [
        {
            "name": name,
            "qa": qa_agg.get(name),
            "legacy": legacy_agg.get(name),
            "delta": _percent_diff(qa_agg.get(name), legacy_agg.get(name)),
        }
        for name in dashboard_scenarios
    ]
    dashboard_trace_metrics = _pick_trace_dashboard_metrics(trace_metrics, qa_trace, legacy_trace, limit=6)
    dashboard_trace_rows = [
        {
            "name": _dashboard_metric_label(trace_name, metric_name),
            "qa": qa_trace.get((trace_name, metric_name)),
            "legacy": legacy_trace.get((trace_name, metric_name)),
            "delta": _percent_diff(qa_trace.get((trace_name, metric_name)), legacy_trace.get((trace_name, metric_name))),
        }
        for trace_name, metric_name in dashboard_trace_metrics
    ]
    technical_chart_metrics = [row["name"] for row in dashboard_trace_rows]
    technical_chart_qa = {row["name"]: _chart_numeric_value(row["name"], row["qa"]) for row in dashboard_trace_rows}
    technical_chart_legacy = {row["name"]: _chart_numeric_value(row["name"], row["legacy"]) for row in dashboard_trace_rows}
    scenario_dashboard_table = _build_dashboard_table(
        dashboard_scenario_rows,
        ["Scenario", "Legacy", "Re-Write", "Improvement"],
        "scenario",
    )
    trace_dashboard_table = _build_dashboard_table(
        dashboard_trace_rows,
        ["Technical Metric", "Legacy", "Re-Write", "Efficiency Gain"],
        "trace",
    )
    scenario_overview_chart = _build_vertical_grouped_chart(
        dashboard_scenarios,
        qa_agg,
        legacy_agg,
        lambda value: _format_number(value, 2) if value is not None else "n/a",
        "scenario-overview-chart",
    )
    if dashboard_trace_rows:
        trace_overview_chart = _build_vertical_grouped_chart(
            technical_chart_metrics,
            technical_chart_qa,
            technical_chart_legacy,
            lambda value: _format_number(value, 1) if value is not None else "n/a",
            "technical-overview-chart",
        )
    else:
        trace_overview_chart = "<div class='muted'>No technical trace metrics were captured in these selected passes.</div>"

    grouped_chart = _build_grouped_bar_rows(ordered_scenarios, qa_agg, legacy_agg, lambda v: _format_metric_value("scenario", v))
    grouped_chart_legend = _build_grouped_chart_legend()
    delta_chart = _build_delta_chart(ordered_scenarios, qa_agg, legacy_agg)
    heatmap = _build_heatmap(ordered_scenarios, step_runs, scenario_matrix)
    spark_cards = "".join(
        _build_sparkline_card(
            name,
            [step["scenarios"].get(name) for step in step_runs],
            [step["short_title"] for step in step_runs],
        )
        for name in ordered_scenarios
    )
    trace_cards = _build_trace_cards(trace_metrics, qa_trace, legacy_trace)

    rows = []
    for name in ordered_scenarios:
        qa_value = qa_agg.get(name)
        legacy_value = legacy_agg.get(name)
        rows.append(
            "<tr>"
            f"<td>{_escape(name)}</td>"
            f"<td>{_escape(_format_number(qa_value, 2))} s</td>"
            f"<td>{_escape(_format_number(legacy_value, 2))} s</td>"
            f"<td>{_escape(_format_percent(_percent_diff(qa_value, legacy_value)))}</td>"
            "</tr>"
        )

    pass_rows = []
    for step in step_runs:
        for name in ordered_scenarios:
            value = step["scenarios"].get(name)
            pass_rows.append(
                "<tr>"
                f"<td>{_escape(step['title'])}</td>"
                f"<td>{_escape(name)}</td>"
                f"<td>{_escape(_format_number(value, 2))} s</td>"
                "</tr>"
            )

    trace_rows = []
    for trace_name, metric_name in trace_metrics:
        qa_value = qa_trace.get((trace_name, metric_name))
        legacy_value = legacy_trace.get((trace_name, metric_name))
        trace_rows.append(
            "<tr>"
            f"<td>{_escape(trace_name)}</td>"
            f"<td>{_escape(metric_name)}</td>"
            f"<td>{_escape(_format_metric_value(metric_name, qa_value))}</td>"
            f"<td>{_escape(_format_metric_value(metric_name, legacy_value))}</td>"
            f"<td>{_escape(_format_percent(_percent_diff(qa_value, legacy_value)))}</td>"
            "</tr>"
        )

    html = [
        "<!doctype html>",
        "<html><head><meta charset='utf-8'>",
        "<title>PerfoMace Combined Comparison</title>",
        "<style>",
        ":root{--ink:#131722;--muted:#677287;--line:#d7dde7;--panel:#ffffff;--surface:#f6f8fc;--qa:#67b8ee;--legacy:#7c8699;--accent:#0f172a;--good:#1f9d63;--bad:#ca3d3d}",
        "body{margin:0;font-family:'Avenir Next','Helvetica Neue',sans-serif;color:var(--ink);background:linear-gradient(180deg,#f5f8ff 0%,#fffaf4 100%)}",
        ".wrap{max-width:1580px;margin:0 auto;padding:28px 28px 40px}",
        ".hero{padding:28px;border-radius:24px;background:linear-gradient(135deg,#0f172a 0%,#1f2f55 55%,#0d5ef7 100%);color:#fff;box-shadow:0 22px 55px rgba(17,24,39,.18)}",
        ".hero-top{display:flex;justify-content:space-between;gap:18px;align-items:flex-start}",
        ".hero h1{margin:0;font-size:34px;line-height:1.05}",
        ".hero p{margin:10px 0 0;color:rgba(255,255,255,.78);max-width:760px;font-size:14px;line-height:1.6}",
        ".hero-meta{margin-top:16px;color:rgba(255,255,255,.72);font-size:13px}",
        ".logo{max-width:300px;width:34%;min-width:180px;height:auto}",
        ".card-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:14px;margin-top:18px}",
        ".metric-card{background:rgba(255,255,255,.12);border:1px solid rgba(255,255,255,.18);border-radius:18px;padding:14px 16px;backdrop-filter:blur(8px)}",
        ".metric-card .kicker{text-transform:uppercase;letter-spacing:.08em;font-size:11px;color:rgba(255,255,255,.62)}",
        ".metric-card .value{margin-top:6px;font-size:26px;font-weight:700}",
        ".metric-card .sub{margin-top:4px;font-size:12px;color:rgba(255,255,255,.72)}",
        ".dashboard-grid{display:grid;grid-template-columns:minmax(420px,0.95fr) minmax(560px,1.25fr);gap:20px;margin-top:22px}",
        ".dashboard-stack{display:grid;gap:18px}",
        ".dashboard-card{background:#fff;border:1px solid var(--line);border-radius:22px;padding:18px 20px;box-shadow:0 10px 30px rgba(15,23,42,.06)}",
        ".dashboard-card h3{margin:0;font-size:18px}",
        ".dashboard-card .sub{margin-top:6px;color:var(--muted);font-size:13px;line-height:1.5}",
        ".dashboard-table-wrap{margin-top:14px;overflow:auto}",
        ".dashboard-table{width:100%;border-collapse:collapse;min-width:560px}",
        ".dashboard-table th,.dashboard-table td{padding:10px 12px;border-bottom:1px solid var(--line);font-size:13px;text-align:left}",
        ".dashboard-table th{background:#111827;color:#fff;font-size:11px;text-transform:uppercase;letter-spacing:.06em;position:sticky;top:0}",
        ".dashboard-table tr:nth-child(even) td{background:#f7f9fc}",
        ".dashboard-table td.name{font-weight:700;color:var(--ink)}",
        ".delta-good{color:var(--good);font-weight:800}",
        ".delta-bad{color:var(--bad);font-weight:800}",
        ".delta-flat{color:var(--muted);font-weight:700}",
        ".muted{color:var(--muted);font-size:13px;line-height:1.6}",
        ".section{margin-top:22px;background:var(--panel);border:1px solid var(--line);border-radius:22px;padding:20px 22px;box-shadow:0 10px 30px rgba(15,23,42,.06)}",
        ".section h2{margin:0;font-size:20px}",
        ".section .sub{margin-top:6px;color:var(--muted);font-size:13px}",
        ".split{display:grid;grid-template-columns:1.2fr .95fr;gap:18px;margin-top:16px}",
        ".split.equal{grid-template-columns:1fr 1fr}",
        ".chart-shell{background:var(--surface);border:1px solid var(--line);border-radius:18px;padding:16px}",
        ".chart-title{font-size:13px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin-bottom:10px}",
        ".chart{width:100%;height:auto;display:block}",
        ".vertical-chart .baseline{stroke:#cfd7e6;stroke-width:2}",
        ".vertical-chart .bar-qa{fill:var(--qa)}",
        ".vertical-chart .bar-legacy{fill:var(--legacy)}",
        ".vertical-chart .bar-label{font-size:11px;fill:var(--ink);font-weight:700}",
        ".vertical-chart .bar-value{font-size:10px;fill:#44506a}",
        ".vertical-chart .legend-text{font-size:12px;fill:var(--muted);font-weight:700}",
        ".chart-legend{display:flex;gap:18px;flex-wrap:wrap;align-items:center;justify-content:center;margin-top:14px;padding-top:12px;border-top:1px solid var(--line)}",
        ".legend-item{display:inline-flex;align-items:center;gap:8px;color:var(--muted);font-size:12px;font-weight:600}",
        ".legend-swatch{display:inline-block;width:18px;height:10px;border-radius:999px}",
        ".legend-qa{background:var(--qa)}",
        ".legend-legacy{background:var(--legacy)}",
        ".grouped-chart .track{fill:#e7ecf6}",
        ".grouped-chart .qa-bar,.mini-track .qa-bar{fill:var(--qa)}",
        ".grouped-chart .legacy-bar,.mini-track .legacy-bar{fill:var(--legacy)}",
        ".axis-label{font-size:12px;fill:var(--ink);font-weight:600}",
        ".value-label{font-size:11px;fill:var(--muted)}",
        ".delta-track{stroke:#dae1ee;stroke-width:2}",
        ".delta-center{stroke:#8ea1c7;stroke-width:1.5;stroke-dasharray:3 4}",
        ".delta-better{fill:var(--good)}",
        ".delta-worse{fill:var(--bad)}",
        ".spark-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:14px;margin-top:16px}",
        ".spark-card{padding:14px;border-radius:18px;background:linear-gradient(180deg,#ffffff 0%,#f7f9fd 100%);border:1px solid var(--line)}",
        ".spark-title{font-size:13px;font-weight:700;margin-bottom:8px}",
        ".sparkline{width:100%;height:auto;display:block}",
        ".spark-path{fill:none;stroke:#7d8cab;stroke-width:2.4}",
        ".qa-point{fill:var(--qa)}",
        ".legacy-point{fill:var(--legacy)}",
        ".spark-x{font-size:10px;fill:var(--muted);text-anchor:middle}",
        ".spark-y{font-size:9px;fill:#50607f}",
        ".heatmap-wrap{overflow:auto;margin-top:16px}",
        ".heatmap{border-collapse:collapse;width:100%;min-width:760px}",
        ".heatmap th,.heatmap td{padding:10px 12px;border-bottom:1px solid var(--line);font-size:12px;text-align:left;color:#fff}",
        ".heatmap th:first-child,.heatmap td:first-child{color:var(--ink);background:#fff;position:sticky;left:0}",
        ".heatmap th{background:#edf2fb;color:var(--ink);text-transform:uppercase;letter-spacing:.08em;font-size:10px}",
        ".heatmap-empty{background:#f3f5f9 !important;color:var(--muted) !important}",
        ".trace-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:14px;margin-top:16px}",
        ".trace-card{border-radius:18px;border:1px solid var(--line);padding:16px;background:linear-gradient(180deg,#fff 0%,#f8f9fc 100%)}",
        ".trace-kicker{text-transform:uppercase;letter-spacing:.08em;color:var(--muted);font-size:10px}",
        ".trace-title{margin-top:6px;font-size:16px;font-weight:700}",
        ".trace-row{display:grid;grid-template-columns:58px 1fr auto;gap:10px;align-items:center;margin-top:12px;font-size:12px}",
        ".mini-track{height:10px;background:#e8edf7;border-radius:999px;overflow:hidden}",
        ".trace-delta{margin-top:12px;color:var(--muted);font-size:12px}",
        ".table-wrap{overflow:auto;margin-top:16px}",
        "table.basic{border-collapse:collapse;width:100%;min-width:720px}",
        "table.basic th,table.basic td{padding:10px 12px;border-bottom:1px solid var(--line);font-size:12px;text-align:left}",
        "table.basic th{text-transform:uppercase;letter-spacing:.08em;color:var(--muted);font-size:10px}",
        ".watermark{position:fixed;right:18px;bottom:14px;padding:7px 12px;border-radius:999px;border:1px solid rgba(148,163,184,.30);background:rgba(255,255,255,.82);backdrop-filter:blur(8px);color:#334155;font-size:11px;font-weight:700;letter-spacing:.02em;box-shadow:0 8px 20px rgba(15,23,42,.08)}",
        "@media (max-width:1200px){.dashboard-grid,.split,.split.equal{grid-template-columns:1fr}.hero-top{flex-direction:column}.logo{width:52%}}",
        "</style></head><body><div class='wrap'>",
        "<div class='hero'>",
        "<div class='hero-top'>",
        "<div>",
        f"<h1>{_escape(hero_title)}</h1>",
        f"<p>{_escape(hero_copy)}</p>",
        f"<div class='hero-meta'>Generated {payload['generated_at']} · Session folder {_escape(payload['session_dir'])}</div>",
        "</div>",
    ]
    if logo_path:
        html.append(f"<img class='logo' src='{_escape(logo_path)}' alt='PerfoMace'/>")
    html.extend(["</div>", "<div class='card-grid'>"])
    for title, value, sub in cards:
        html.append(
            "<div class='metric-card'>"
            f"<div class='kicker'>{_escape(title)}</div>"
            f"<div class='value'>{_escape(value)}</div>"
            f"<div class='sub'>{_escape(sub)}</div>"
            "</div>"
        )
    html.extend(["</div>", "</div>"])

    html.extend([
        "<div class='dashboard-grid'>",
        "<div class='dashboard-stack'>",
        "<div class='dashboard-card'>",
        "<h3>Performance Analysis</h3>",
        "<div class='sub'>Legacy and Re-Write are shown side by side with improvement percentages based on the Legacy baseline, so positive values mean the Re-Write got faster.</div>",
        scenario_dashboard_table,
        "</div>",
        "<div class='dashboard-card'>",
        "<h3>Technical Metrics</h3>",
        "<div class='sub'>System metrics stay in a separate panel so CPU, memory, and disk changes do not get mixed into the scenario timing scale.</div>",
        trace_dashboard_table,
        "</div>",
        "</div>",
        "<div class='dashboard-stack'>",
        "<div class='dashboard-card'>",
        "<h3>Scenario Comparison</h3>",
        "<div class='sub'>Grouped bars show the captured Legacy and Re-Write scenario timings in the compact dashboard view.</div>",
        scenario_overview_chart,
        "</div>",
        "<div class='dashboard-card'>",
        "<h3>Extended Trace Analysis</h3>",
        "<div class='sub'>When technical traces are available, this view highlights system resource differences separately from the user-facing flow timings.</div>",
        trace_overview_chart,
        "</div>",
        "</div>",
        "</div>",
    ])

    html.extend([
        "<div class='section'>",
        "<h2>Scenario Comparison</h2>",
        "<div class='sub'>Grouped bars compare the captured Re-Write pass against the captured Legacy pass for each user-facing scenario.</div>",
        "<div class='chart-shell' style='margin-top:16px'>",
        "<div class='chart-title'>Grouped Bars</div>",
        grouped_chart,
        grouped_chart_legend,
        "</div>",
        "<div class='split' style='margin-top:16px'>",
        "<div class='chart-shell'><div class='chart-title'>Improvement vs Legacy Baseline</div>",
        delta_chart,
        "</div>",
        "<div class='chart-shell'><div class='chart-title'>Heatmap By Pass</div>",
        heatmap,
        "</div></div></div>",
        "<div class='section'>",
        "<h2>Sequence Drift</h2>",
        "<div class='sub'>Each sparkline preserves the Re-Write -> Legacy order so you can see whether the second app was helped or hurt by session conditions.</div>",
        f"<div class='spark-grid'>{spark_cards}</div>",
        "</div>",
        "<div class='section'>",
        "<h2>Trace Metric Cards</h2>",
        "<div class='sub'>Trace metrics are shown separately from scenario timings so CPU, memory, and network differences stay readable instead of getting mixed into one scale.</div>",
        f"<div class='trace-grid'>{trace_cards}</div>",
        "</div>",
        "<div class='section'>",
        "<h2>Scenario Table</h2>",
        "<div class='sub'>Raw values and deltas for the Re-Write and Legacy passes captured in this comparison session.</div>",
        "<div class='table-wrap'><table class='basic'><tr><th>Scenario</th><th>Re-Write Average</th><th>Legacy Average</th><th>Improvement vs Legacy</th></tr>",
        "".join(rows),
        "</table></div></div>",
        "<div class='section'>",
        "<h2>Pass Detail</h2>",
        "<div class='sub'>Every captured pass is listed here so the comparison can be audited back to the original sequence.</div>",
        "<div class='table-wrap'><table class='basic'><tr><th>Pass</th><th>Scenario</th><th>Value</th></tr>",
        "".join(pass_rows),
        "</table></div></div>",
        "<div class='section'>",
        "<h2>Trace Table</h2>",
        "<div class='sub'>Trace metrics captured for the Re-Write and Legacy passes in this comparison session.</div>",
        "<div class='table-wrap'><table class='basic'><tr><th>Trace</th><th>Metric</th><th>Re-Write Average</th><th>Legacy Average</th><th>Improvement vs Legacy</th></tr>",
        "".join(trace_rows),
        "</table></div></div>",
        "<div class='watermark'>JD with iHeart</div>",
        "</div></body></html>",
    ])
    return "\n".join(html)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--session-dir", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--json")
    parser.add_argument("--csv", required=True)
    parser.add_argument("--project-root", required=True)
    args = parser.parse_args()

    manifest = _read_json(args.manifest)
    steps = manifest.get("steps") or []
    if not steps:
        raise SystemExit("No combined steps found in manifest.")

    step_runs = []
    app_groups = {"qa": [], "legacy": []}
    device_labels = []
    for step in steps:
        payload = _read_json(os.path.join(args.session_dir, step["jsonFile"]))
        app_choice = (step.get("appChoice") or "").strip().lower()
        csv_scenarios, csv_traces = _collect_csv_overrides(args.session_dir, step)
        scenarios = csv_scenarios or _collect_scenarios(payload)
        traces = csv_traces or _collect_trace_metrics(payload)
        device_label = _resolve_device_label(payload.get("run_context") or {})
        if device_label:
            device_labels.append(device_label)
        short_title = f"{APP_LABELS.get(app_choice, app_choice.title())} {step['order']}"
        step_runs.append(
            {
                "order": step["order"],
                "appChoice": app_choice,
                "title": step.get("title") or short_title,
                "short_title": short_title,
                "scenarios": scenarios,
                "traces": traces,
            }
        )
        if app_choice in app_groups:
            app_groups[app_choice].append({"scenarios": scenarios, "traces": traces})

    scenario_names = sorted({name for step in step_runs for name in step["scenarios"].keys()})
    aggregated = {}
    for app_choice in ["qa", "legacy"]:
        scenario_values = {}
        trace_values = {}
        for name in scenario_names:
            scenario_values[name] = _mean([entry["scenarios"].get(name) for entry in app_groups[app_choice]])
        all_trace_keys = {
            key
            for entry in app_groups[app_choice]
            for key in entry["traces"].keys()
        }
        for key in all_trace_keys:
            trace_values[key] = _mean([entry["traces"].get(key) for entry in app_groups[app_choice]])
        aggregated[app_choice] = {
            "scenarios": scenario_values,
            "traces": trace_values,
        }

    ordered_scenarios = sorted(
        scenario_names,
        key=lambda name: abs(_percent_diff(aggregated["qa"]["scenarios"].get(name), aggregated["legacy"]["scenarios"].get(name)) or 0),
        reverse=True,
    )

    scenario_matrix = {
        name: {step["title"]: step["scenarios"].get(name) for step in step_runs}
        for name in scenario_names
    }
    trace_metric_keys = set(aggregated["qa"]["traces"].keys()) | set(aggregated["legacy"]["traces"].keys())
    trace_metrics = _preferred_trace_order(trace_metric_keys)
    unique_device_labels = sorted(set(device_labels))
    common_device_label = unique_device_labels[0] if len(unique_device_labels) == 1 else ""

    logo_path = None
    logo_png = os.path.join(args.project_root, "assets", "performace_logo.png")
    logo_svg = os.path.join(args.project_root, "assets", "performace_logo.svg")
    out_dir = os.path.dirname(args.out)
    if os.path.exists(logo_png):
        logo_path = os.path.relpath(logo_png, out_dir)
    elif os.path.exists(logo_svg):
        logo_path = os.path.relpath(logo_svg, out_dir)

    payload = {
        "generated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "sequence_label": manifest.get("sequenceLabel") or "Re-Write -> Legacy",
        "report_mode": manifest.get("reportMode") or "combined",
        "session_dir": args.session_dir,
        "step_runs": step_runs,
        "scenario_names": scenario_names,
        "ordered_scenarios": ordered_scenarios,
        "scenario_matrix": scenario_matrix,
        "aggregated": {
            "qa": {
                "label": "Re-Write",
                "scenarios": aggregated["qa"]["scenarios"],
                "traces": {f"{trace}::{metric}": value for (trace, metric), value in aggregated["qa"]["traces"].items()},
            },
            "legacy": {
                "label": "Legacy",
                "scenarios": aggregated["legacy"]["scenarios"],
                "traces": {f"{trace}::{metric}": value for (trace, metric), value in aggregated["legacy"]["traces"].items()},
            },
        },
        "trace_metrics": trace_metrics,
        "logo_path": logo_path,
        "device_label": common_device_label,
    }

    json_payload = {
        **payload,
        "aggregated": {
            "qa": {
                "label": "Re-Write",
                "scenarios": aggregated["qa"]["scenarios"],
                "traces": {f"{trace}::{metric}": value for (trace, metric), value in aggregated["qa"]["traces"].items()},
            },
            "legacy": {
                "label": "Legacy",
                "scenarios": aggregated["legacy"]["scenarios"],
                "traces": {f"{trace}::{metric}": value for (trace, metric), value in aggregated["legacy"]["traces"].items()},
            },
        },
        "step_runs": [
            {
                **step,
                "traces": {f"{trace}::{metric}": value for (trace, metric), value in step["traces"].items()},
            }
            for step in step_runs
        ],
        "trace_metrics": [f"{trace}::{metric}" for trace, metric in trace_metrics],
    }

    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(json_payload, f, indent=2, sort_keys=True)

    _write_csv(
        args.csv,
        ordered_scenarios,
        step_runs,
        aggregated["qa"]["scenarios"],
        aggregated["legacy"]["scenarios"],
        trace_metrics,
        aggregated["qa"]["traces"],
        aggregated["legacy"]["traces"],
    )

    html_payload = {
        **payload,
        "aggregated": {
            "qa": {
                "label": "Re-Write",
                "scenarios": aggregated["qa"]["scenarios"],
                "traces": aggregated["qa"]["traces"],
            },
            "legacy": {
                "label": "Legacy",
                "scenarios": aggregated["legacy"]["scenarios"],
                "traces": aggregated["legacy"]["traces"],
            },
        },
    }
    html = _build_html(html_payload)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(html)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
