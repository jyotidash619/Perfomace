#!/usr/bin/env python3
import argparse
import csv
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime
from xml.etree import ElementTree as ET


_XCDEVICE_CACHE = None


def _unwrap(value):
    if isinstance(value, dict) and "_value" in value:
        return value["_value"]
    return value


def _load_run_context(results_dir):
    path = os.path.join(results_dir, "run_context.json")
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f) or {}
    except Exception:
        return {}


def _load_xcresult(path):
    attempts = [
        ["xcrun", "xcresulttool", "get", "object", "--legacy", "--path", path, "--format", "json"],
        ["xcrun", "xcresulttool", "get", "object", "--path", path, "--format", "json"],
        ["xcrun", "xcresulttool", "get", "--legacy", "--path", path, "--format", "json"],
    ]
    for attempt in attempts:
        try:
            result = subprocess.run(
                attempt,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            return json.loads(result.stdout), None
        except Exception as exc:
            last_err = exc
    return None, f"xcresulttool failed: {last_err}"


def _run_command_capture_files(cmd, timeout=60):
    stdout_file = tempfile.NamedTemporaryFile(delete=False, dir="/tmp")
    stderr_file = tempfile.NamedTemporaryFile(delete=False, dir="/tmp")
    stdout_path = stdout_file.name
    stderr_path = stderr_file.name
    stdout_file.close()
    stderr_file.close()
    try:
        with open(stdout_path, "w", encoding="utf-8") as stdout_f, open(stderr_path, "w", encoding="utf-8") as stderr_f:
            result = subprocess.run(
                cmd,
                check=True,
                stdout=stdout_f,
                stderr=stderr_f,
                text=True,
                timeout=timeout,
            )
        with open(stdout_path, "r", encoding="utf-8", errors="ignore") as f:
            stdout_text = f.read()
        with open(stderr_path, "r", encoding="utf-8", errors="ignore") as f:
            stderr_text = f.read()
        return stdout_text, stderr_text, None
    except subprocess.TimeoutExpired:
        return None, None, "timeout"
    except subprocess.CalledProcessError as exc:
        with open(stdout_path, "r", encoding="utf-8", errors="ignore") as f:
            stdout_text = f.read()
        with open(stderr_path, "r", encoding="utf-8", errors="ignore") as f:
            stderr_text = f.read()
        return stdout_text, stderr_text, exc.returncode
    finally:
        try:
            os.unlink(stdout_path)
        except OSError:
            pass
        try:
            os.unlink(stderr_path)
        except OSError:
            pass


def _xctrace_timeout_seconds():
    raw = os.environ.get("PERF_XCTRACE_EXPORT_TIMEOUT", "60")
    try:
        return max(1, int(raw))
    except Exception:
        return 60


def _export_trace_toc(trace_path):
    timeout = _xctrace_timeout_seconds()
    stdout_text, stderr_text, err = _run_command_capture_files(
        ["xcrun", "xctrace", "export", "--input", trace_path, "--toc"],
        timeout=timeout,
    )
    if err == "timeout":
        return None, f"xctrace export toc timed out after {timeout}s"
    if err is not None:
        stderr = (stderr_text or "").strip()
        stdout = (stdout_text or "").strip()
        detail = stderr or stdout or f"exit status {err}"
        return None, f"xctrace export toc failed: {detail}"
    return stdout_text, None


def _export_trace_table(trace_path, schema):
    xpath = f"/trace-toc/run[@number='1']/data/table[@schema='{schema}']"
    timeout = _xctrace_timeout_seconds()
    stdout_text, stderr_text, err = _run_command_capture_files(
        ["xcrun", "xctrace", "export", "--input", trace_path, "--xpath", xpath],
        timeout=timeout,
    )
    if err == "timeout":
        return None, f"xctrace export table timed out after {timeout}s"
    if err is not None:
        stderr = (stderr_text or "").strip()
        stdout = (stdout_text or "").strip()
        detail = stderr or stdout or f"exit status {err}"
        return None, f"xctrace export table failed: {detail}"
    return stdout_text, None


def _export_trace_har(trace_path):
    temp_dir = tempfile.mkdtemp(prefix="perf_har_", dir="/tmp")
    try:
        timeout = _xctrace_timeout_seconds()
        _, stderr_text, err = _run_command_capture_files(
            ["xcrun", "xctrace", "export", "--input", trace_path, "--har", "--output", temp_dir],
            timeout=timeout,
        )
        if err == "timeout":
            return None, f"xctrace export har timed out after {timeout}s"
        if err is not None:
            detail = (stderr_text or "").strip() or f"exit status {err}"
            return None, f"xctrace export har failed: {detail}"
        har_files = []
        for root_dir, _, files in os.walk(temp_dir):
            for name in files:
                if name.endswith(".har"):
                    har_files.append(os.path.join(root_dir, name))
        if not har_files:
            return None, "xctrace export har produced no file"
        with open(sorted(har_files)[0], "r", encoding="utf-8", errors="ignore") as f:
            return json.load(f), None
    except Exception as exc:
        return None, f"xctrace export har failed: {exc}"
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


def _find_candidate_schema(toc_xml, keywords, preferred_schemas=None):
    if not toc_xml:
        return None
    try:
        root = ET.fromstring(toc_xml)
    except Exception:
        return None
    tables = root.findall(".//table")
    if preferred_schemas:
        table_schemas = {table.attrib.get("schema", "") or "": table for table in tables}
        for preferred_schema in preferred_schemas:
            if preferred_schema in table_schemas:
                return preferred_schema
    for table in tables:
        schema = table.attrib.get("schema", "") or ""
        name = table.attrib.get("name", "") or ""
        combined = f"{schema} {name}".lower()
        if any(k in combined for k in keywords):
            return schema
    return tables[0].attrib.get("schema") if tables else None


def _find_candidate_schemas(toc_xml, keywords, preferred_schemas=None):
    if not toc_xml:
        return []
    try:
        root = ET.fromstring(toc_xml)
    except Exception:
        return []
    tables = root.findall(".//table")
    ordered = []
    seen = set()
    table_schemas = [table.attrib.get("schema", "") or "" for table in tables]
    if preferred_schemas:
        for preferred_schema in preferred_schemas:
            if preferred_schema in table_schemas and preferred_schema not in seen:
                ordered.append(preferred_schema)
                seen.add(preferred_schema)
    for table in tables:
        schema = table.attrib.get("schema", "") or ""
        name = table.attrib.get("name", "") or ""
        combined = f"{schema} {name}".lower()
        if any(k in combined for k in keywords) and schema not in seen:
            ordered.append(schema)
            seen.add(schema)
    if not ordered and tables:
        fallback = tables[0].attrib.get("schema")
        if fallback:
            ordered.append(fallback)
    return ordered


def _parse_numeric_value(text):
    if text is None:
        return None
    cleaned = str(text).strip().replace(",", "")
    if not cleaned:
        return None
    try:
        return float(cleaned)
    except Exception:
        pass
    match = re.search(r"[-+]?\d*\.?\d+", cleaned)
    if not match:
        return None
    try:
        return float(match.group(0))
    except Exception:
        return None


def _process_matches_target(process_text, process_name=None, bundle_id=None):
    value = (process_text or "").strip().lower()
    if not value:
        return False

    target_tokens = [
        "iheart",
        "iheartradio",
        "com.clearchannel.iheartradio",
    ]
    for candidate in (process_name, bundle_id):
        if not candidate:
            continue
        candidate_l = str(candidate).strip().lower()
        if candidate_l:
            target_tokens.append(candidate_l)
            target_tokens.append(re.sub(r"[^a-z0-9]+", "", candidate_l))

    for token in target_tokens:
        token = (token or "").strip().lower()
        if not token:
            continue
        if token in value:
            return True
    return False


def _build_element_lookup(root):
    lookup = {}
    for elem in root.iter():
        elem_id = elem.attrib.get("id")
        if elem_id:
            lookup[elem_id] = {
                "text": (elem.text or "").strip(),
                "fmt": (elem.attrib.get("fmt") or "").strip(),
            }
    return lookup


def _table_has_rows(table_xml):
    if not table_xml:
        return False
    try:
        root = ET.fromstring(table_xml)
    except Exception:
        return False
    return bool(root.findall(".//row"))


def _trace_table_schema_name(table_xml):
    if not table_xml:
        return None
    try:
        root = ET.fromstring(table_xml)
    except Exception:
        return None
    schema = root.find(".//schema")
    if schema is None:
        return None
    return (schema.attrib.get("name") or "").strip() or None


def _resolve_element_value(elem, lookup):
    resolved = {
        "text": (elem.text or "").strip(),
        "fmt": (elem.attrib.get("fmt") or "").strip(),
    }
    ref = elem.attrib.get("ref")
    if ref and ref in lookup:
        referenced = lookup[ref]
        if not resolved["text"]:
            resolved["text"] = referenced.get("text", "")
        if not resolved["fmt"]:
            resolved["fmt"] = referenced.get("fmt", "")
    return resolved


def _resolve_row_process_text(row, lookup, process_columns=None):
    process_columns = process_columns or {"Process", "Process Name"}
    cols = row.findall("col")
    if not cols:
        cols = [child for child in list(row) if isinstance(child.tag, str)]

    for idx, col in enumerate(cols):
        name = col.attrib.get("name") or f"col{idx}"
        if name in process_columns:
            resolved = _resolve_element_value(col, lookup)
            value = (resolved.get("fmt") or resolved.get("text") or "").strip()
            if value:
                return value

    for candidate_tag in ("process", "thread"):
        candidate = row.find(candidate_tag)
        if candidate is not None:
            resolved = _resolve_element_value(candidate, lookup)
            value = (resolved.get("fmt") or resolved.get("text") or "").strip()
            if value:
                return value
    return ""


def _extract_numeric_summary(table_xml, process_name=None, process_bundle_id=None, process_columns=None):
    if not table_xml:
        return {}
    try:
        root = ET.fromstring(table_xml)
    except Exception:
        return {}
    lookup = _build_element_lookup(root)
    rows = root.findall(".//row")
    if not rows:
        return {}
    # Collect numeric values by column name
    col_names = []
    header = root.find(".//columns")
    if header is not None:
        col_names = [c.attrib.get("name", f"col{idx}") for idx, c in enumerate(header.findall("column"))]
    else:
        schema = root.find(".//schema")
        if schema is not None:
            col_names = [
                (col.findtext("name") or col.findtext("mnemonic") or f"col{idx}").strip()
                for idx, col in enumerate(schema.findall("col"))
            ]
    process_columns = process_columns or {"Process", "Process Name"}
    values = {name: [] for name in col_names}
    for row in rows:
        cols = row.findall("col")
        if not cols:
            cols = [child for child in list(row) if isinstance(child.tag, str)]
        row_process = ""
        resolved_cols = []
        for idx, col in enumerate(cols):
            name = col_names[idx] if idx < len(col_names) else f"col{idx}"
            resolved = _resolve_element_value(col, lookup)
            resolved_cols.append((name, resolved))
            if process_name and name in process_columns:
                row_process = (resolved.get("fmt") or resolved.get("text") or "").strip()
        if process_name and not row_process:
            row_process = _resolve_row_process_text(row, lookup, process_columns=process_columns)
        if process_name and not _process_matches_target(row_process, process_name=process_name, bundle_id=process_bundle_id):
            continue
        for name, resolved in resolved_cols:
            raw_value = resolved.get("text") or resolved.get("fmt") or ""
            num = _parse_numeric_value(raw_value)
            if num is None:
                continue
            values.setdefault(name, []).append(num)
    summary = {}
    for name, nums in values.items():
        if not nums:
            continue
        summary[name] = {
            "avg": sum(nums) / len(nums),
            "max": max(nums),
            "min": min(nums),
            "count": len(nums),
        }
    return summary


def _scalar_stats(value):
    numeric = float(value)
    return {"avg": numeric, "max": numeric, "min": numeric, "count": 1}


def _summarize_time_sample_table(table_xml, process_name=None, process_bundle_id=None):
    if not table_xml:
        return {}
    try:
        root = ET.fromstring(table_xml)
    except Exception:
        return {}

    lookup = _build_element_lookup(root)
    rows = root.findall(".//row")
    if not rows:
        return {}

    sample_count = 0
    timestamps = []
    thread_ids = set()
    state_counts = {}
    type_counts = {}

    for row in rows:
        row_process = _resolve_row_process_text(row, lookup)
        if process_name and not _process_matches_target(row_process, process_name=process_name, bundle_id=process_bundle_id):
            continue

        sample_count += 1

        sample_time = row.find("sample-time")
        if sample_time is not None:
            resolved = _resolve_element_value(sample_time, lookup)
            value = _parse_numeric_value(resolved.get("text") or resolved.get("fmt"))
            if value is not None:
                timestamps.append(value)

        tid = row.find(".//tid")
        if tid is not None:
            resolved = _resolve_element_value(tid, lookup)
            thread_id = (resolved.get("fmt") or resolved.get("text") or "").strip()
            if thread_id:
                thread_ids.add(thread_id)

        thread_state = row.find("thread-state")
        if thread_state is not None:
            resolved = _resolve_element_value(thread_state, lookup)
            state = (resolved.get("fmt") or resolved.get("text") or "").strip()
            if state:
                state_counts[state] = state_counts.get(state, 0) + 1

        sample_kind = row.find("time-sample-kind")
        if sample_kind is not None:
            resolved = _resolve_element_value(sample_kind, lookup)
            kind = (resolved.get("fmt") or resolved.get("text") or "").strip()
            if kind:
                type_counts[kind] = type_counts.get(kind, 0) + 1

    if sample_count == 0:
        return {}

    summary = {
        "Sample Count": _scalar_stats(sample_count),
        "Unique Threads": _scalar_stats(len(thread_ids)),
    }

    if len(timestamps) >= 2:
        capture_duration_s = max(0.0, (max(timestamps) - min(timestamps)) / 1_000_000_000.0)
        summary["Capture Duration (s)"] = _scalar_stats(capture_duration_s)
        if capture_duration_s > 0:
            summary["Samples / s"] = _scalar_stats(sample_count / capture_duration_s)

    for state_name in ("Running", "Blocked", "Waiting", "Suspended"):
        count = state_counts.get(state_name)
        if count:
            summary[f"{state_name} Samples"] = _scalar_stats(count)

    for kind_name in ("Timer Fired", "Stackshot"):
        count = type_counts.get(kind_name)
        if count:
            summary[f"{kind_name} Samples"] = _scalar_stats(count)

    return summary


def _summarize_network_table(table_xml, process_name=None, process_bundle_id=None):
    summary = _extract_numeric_summary(
        table_xml,
        process_name=process_name,
        process_bundle_id=process_bundle_id,
        process_columns={"Process", "Process Name"},
    )
    duration_stats = summary.get("Duration")
    if not duration_stats:
        return {}
    request_count = int(duration_stats.get("count") or 0)
    return {
        "Request Count": {
            "avg": float(request_count),
            "max": float(request_count),
            "min": float(request_count),
            "count": 1,
        },
        "Request Time (s)": {
            "avg": duration_stats.get("avg"),
            "max": duration_stats.get("max"),
            "min": duration_stats.get("min"),
            "count": duration_stats.get("count"),
        },
    }


def _curate_activity_summary(summary):
    def _scaled(stats, divisor):
        if not stats:
            return None
        return {
            "avg": (stats.get("avg") or 0) / divisor,
            "max": (stats.get("max") or 0) / divisor,
            "min": (stats.get("min") or 0) / divisor,
            "count": stats.get("count"),
        }

    def _pick(*names):
        for name in names:
            if name in summary:
                return summary[name]
        return None

    def _sum_stats(left, right):
        if not left or not right:
            return None
        return {
            "avg": (left.get("avg") or 0) + (right.get("avg") or 0),
            "max": (left.get("max") or 0) + (right.get("max") or 0),
            "min": (left.get("min") or 0) + (right.get("min") or 0),
            "count": min(left.get("count") or 0, right.get("count") or 0) or left.get("count") or right.get("count"),
        }

    alias_groups = {
        "% CPU": ["% CPU", "CPU", "CPU Usage", "CPU Usage (%)"],
        "Memory": ["Memory", "Memory (B)", "Physical Memory", "Physical Memory (B)"],
        "Real Mem": ["Real Mem", "Real Memory", "Real Memory (B)", "Real Memory (MB)"],
        "CPU Time": ["CPU Time"],
        "Disk Writes": ["Disk Writes", "Disk Writes (B)", "Bytes Written"],
        "Disk Reads": ["Disk Reads", "Disk Reads (B)", "Bytes Read"],
    }
    preferred = ["% CPU", "Memory", "Real Mem", "CPU Time", "Disk Writes", "Disk Reads"]
    curated = {}
    for canonical in preferred:
        for alias in alias_groups.get(canonical, [canonical]):
            if alias in summary:
                curated[canonical] = summary[alias]
                break

    if "Real Mem" not in curated:
        resident = _pick("Resident Size")
        if resident:
            curated["Real Mem"] = resident
        else:
            real_combined = _sum_stats(_pick("Real Private Mem"), _pick("Real Shared Mem"))
            if real_combined:
                curated["Real Mem"] = real_combined

    if "CPU Time" not in curated:
        cpu_total = _sum_stats(_pick("System Time"), _pick("User Time"))
        if cpu_total:
            curated["CPU Time"] = _scaled(cpu_total, 1_000_000_000)

    return curated or summary


def _summarize_har(har_payload):
    log = (har_payload or {}).get("log") or {}
    entries = log.get("entries") or []
    durations = []
    request_bytes = []
    response_bytes = []
    error_count = 0

    for entry in entries:
        time_ms = _parse_numeric_value(entry.get("time"))
        if time_ms is not None:
            durations.append(time_ms)

        request = entry.get("request") or {}
        request_total = 0
        request_found = False
        for candidate in (request.get("bodySize"), request.get("headersSize")):
            value = _parse_numeric_value(candidate)
            if value is not None and value >= 0:
                request_total += value
                request_found = True
        if request_found:
            request_bytes.append(request_total)

        response = entry.get("response") or {}
        response_total = 0
        response_found = False
        for candidate in (
            response.get("bodySize"),
            response.get("headersSize"),
            ((response.get("content") or {}).get("size")),
        ):
            value = _parse_numeric_value(candidate)
            if value is not None and value >= 0:
                response_total += value
                response_found = True
        if response_found:
            response_bytes.append(response_total)

        status = _parse_numeric_value(response.get("status"))
        if status is not None and status >= 400:
            error_count += 1

    summary = {
        "Request Count": {
            "avg": float(len(entries)),
            "max": float(len(entries)),
            "min": float(len(entries)),
            "count": 1,
        }
    }
    if durations:
        summary["Request Time (ms)"] = {
            "avg": sum(durations) / len(durations),
            "max": max(durations),
            "min": min(durations),
            "count": len(durations),
        }
    if request_bytes:
        summary["Request Bytes"] = {
            "avg": sum(request_bytes) / len(request_bytes),
            "max": max(request_bytes),
            "min": min(request_bytes),
            "count": len(request_bytes),
        }
    if response_bytes:
        summary["Response Bytes"] = {
            "avg": sum(response_bytes) / len(response_bytes),
            "max": max(response_bytes),
            "min": min(response_bytes),
            "count": len(response_bytes),
        }
    if entries:
        summary["HTTP Error Count"] = {
            "avg": float(error_count),
            "max": float(error_count),
            "min": float(error_count),
            "count": 1,
        }
    return summary


def _default_no_data_error(kind):
    if kind == "cpu":
        return "no time profiler sample rows exported"
    if kind == "network":
        return "no network transaction rows exported"
    return "no numeric summary extracted"


def _curate_network_summary(summary):
    preferred = [
        "Request Time (s)",
        "Request Time (ms)",
        "Request Count",
        "Response Bytes",
        "Request Bytes",
        "HTTP Error Count",
        "Detection Time",
    ]
    curated = {}
    for name in preferred:
        if name in summary:
            curated[name] = summary[name]
    if curated:
        return curated
    filtered = {
        name: stats
        for name, stats in summary.items()
        if "interface" not in (name or "").lower()
    }
    return filtered or summary


def _read_text_if_exists(path):
    if not os.path.exists(path):
        return ""
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return f.read()
    except Exception:
        return ""


def _authoritative_preexport_error(kind, traces_dir, had_sidecar):
    if not had_sidecar:
        return None
    log_paths = []
    if kind == "activity":
        log_paths.extend(
            [
                os.path.join(traces_dir, "ActivityMonitor.export.log"),
                os.path.join(traces_dir, "Activity_Monitor.log"),
            ]
        )
    elif kind == "cpu":
        log_paths.extend(
            [
                os.path.join(traces_dir, "TimeProfiler.export.log"),
                os.path.join(traces_dir, "Time_Profiler.log"),
            ]
        )
    elif kind == "memory":
        log_paths.extend(
            [
                os.path.join(traces_dir, "Allocations.export.log"),
                os.path.join(traces_dir, "Allocations.log"),
            ]
        )
    elif kind == "leaks":
        log_paths.extend(
            [
                os.path.join(traces_dir, "Leaks.export.log"),
                os.path.join(traces_dir, "Leaks.log"),
            ]
        )
    elif kind == "network":
        log_paths.extend(
            [
                os.path.join(traces_dir, "Network.export.log"),
                os.path.join(traces_dir, "Network.log"),
            ]
        )

    log_exists = any(os.path.exists(path) for path in log_paths)
    if not had_sidecar and not log_exists:
        return None
    combined = "\n".join(_read_text_if_exists(path) for path in log_paths)
    lowered = combined.lower()
    if "permission to debug" in lowered or "get-task-allow" in lowered:
        return "app is not debuggable for this Instruments template (missing get-task-allow)"
    if "unable to acquire required task port" in lowered:
        return "unable to acquire required task port"
    if "could not acquire the necessary privileges" in lowered:
        return "instruments could not acquire profiling privileges"
    if "failed to attach to target process" in lowered:
        return "failed to attach to target process"
    if kind == "network":
        if "segmentation fault" in lowered:
            return "network HAR export crashed"
        return _default_no_data_error(kind)
    return _default_no_data_error(kind)


def _preexported_trace_summary(trace_path, kind, health, process_name=None, process_bundle_id=None):
    traces_dir = os.path.dirname(trace_path)
    had_sidecar = False
    sidecar_schema = None
    if kind == "activity":
        exported_xml = os.path.join(traces_dir, "ActivityMonitor.sysmon-process.xml")
        if os.path.exists(exported_xml):
            had_sidecar = True
            sidecar_schema = "sysmon-process"
            try:
                with open(exported_xml, "r", encoding="utf-8", errors="ignore") as f:
                    summary = _curate_activity_summary(
                        _extract_numeric_summary(
                            f.read(),
                            process_name=process_name,
                            process_bundle_id=process_bundle_id,
                        )
                    )
                if summary:
                    return {
                        "schema": "sysmon-process",
                        "summary": summary,
                        "health": health,
                    }
            except Exception:
                pass
    if kind == "cpu":
        exported_xml = os.path.join(traces_dir, "TimeProfiler.table.xml")
        if os.path.exists(exported_xml):
            had_sidecar = True
            sidecar_schema = "time-profile"
            try:
                with open(exported_xml, "r", encoding="utf-8", errors="ignore") as f:
                    table_xml = f.read()
                    schema_name = _trace_table_schema_name(table_xml) or sidecar_schema
                    sidecar_schema = schema_name
                    if schema_name == "time-sample":
                        summary = _summarize_time_sample_table(
                            table_xml,
                            process_name=process_name,
                            process_bundle_id=process_bundle_id,
                        )
                    else:
                        summary = _extract_numeric_summary(
                            table_xml,
                            process_name=process_name,
                            process_bundle_id=process_bundle_id,
                        )
                if summary:
                    return {
                        "schema": sidecar_schema,
                        "summary": summary,
                        "health": health,
                    }
            except Exception:
                pass
    if kind == "memory":
        exported_xml = os.path.join(traces_dir, "Allocations.table.xml")
        if os.path.exists(exported_xml):
            had_sidecar = True
            sidecar_schema = "allocations"
            try:
                with open(exported_xml, "r", encoding="utf-8", errors="ignore") as f:
                    summary = _extract_numeric_summary(
                        f.read(),
                        process_name=process_name,
                        process_bundle_id=process_bundle_id,
                    )
                if summary:
                    return {
                        "schema": "allocations",
                        "summary": summary,
                        "health": health,
                    }
            except Exception:
                pass
    if kind == "leaks":
        exported_xml = os.path.join(traces_dir, "Leaks.table.xml")
        if os.path.exists(exported_xml):
            had_sidecar = True
            sidecar_schema = "leaks"
            try:
                with open(exported_xml, "r", encoding="utf-8", errors="ignore") as f:
                    summary = _extract_numeric_summary(
                        f.read(),
                        process_name=process_name,
                        process_bundle_id=process_bundle_id,
                    )
                if summary:
                    return {
                        "schema": "leaks",
                        "summary": summary,
                        "health": health,
                    }
            except Exception:
                pass
    if kind == "network":
        exported_har = os.path.join(traces_dir, "Network.har")
        if os.path.exists(exported_har):
            had_sidecar = True
            sidecar_schema = "har"
            try:
                with open(exported_har, "r", encoding="utf-8", errors="ignore") as f:
                    har_summary = _curate_network_summary(_summarize_har(json.load(f)))
                    request_count = (
                        (((har_summary.get("Request Count") or {}).get("avg")))
                        if isinstance(har_summary, dict)
                        else None
                    )
                    if request_count and request_count > 0:
                        return {
                            "schema": "har",
                            "summary": har_summary,
                            "health": health,
                        }
            except Exception:
                pass
        exported_table = os.path.join(traces_dir, "Network.task-intervals.xml")
        if os.path.exists(exported_table):
            had_sidecar = True
            sidecar_schema = "com-apple-cfnetwork-task-intervals"
            try:
                with open(exported_table, "r", encoding="utf-8", errors="ignore") as f:
                    table_xml = f.read()
                    sidecar_schema = _trace_table_schema_name(table_xml) or sidecar_schema
                    summary = _curate_network_summary(
                        _summarize_network_table(
                            table_xml,
                            process_name=process_name,
                            process_bundle_id=process_bundle_id,
                        )
                    )
                if summary:
                        return {
                            "schema": "com-apple-cfnetwork-task-intervals",
                            "summary": summary,
                            "health": health,
                        }
            except Exception:
                pass
    authoritative_error = _authoritative_preexport_error(kind, traces_dir, had_sidecar)
    if authoritative_error:
        if kind in {"cpu", "network"} and authoritative_error in {
            _default_no_data_error(kind),
            "network HAR export crashed",
        }:
            return None
        payload = {"error": authoritative_error, "health": health}
        if sidecar_schema:
            payload["schema"] = sidecar_schema
        return payload
    return None


def _trace_summary(trace_path, kind, process_name=None, process_bundle_id=None):
    health = _inspect_trace_bundle(trace_path)
    preexported = _preexported_trace_summary(
        trace_path,
        kind,
        health,
        process_name=process_name,
        process_bundle_id=process_bundle_id,
    )
    if preexported:
        return preexported
    if health.get("status") == "broken":
        return {"error": health.get("message"), "health": health}
    preferred = []
    if kind == "energy":
        keywords = ["energy", "power", "battery", "cpu", "thermal"]
        preferred = [
            "energy",
            "energy-log",
            "com.apple.xray.instrument-type.energy",
            "com.apple.xray.energy-log",
            "com.apple.xray.energy",
            "com.apple.xray.energy.log",
        ]
    elif kind == "leaks":
        keywords = ["leak", "malloc", "allocation"]
        preferred = [
            "leaks",
            "com.apple.xray.instrument-type.leaks",
            "com.apple.xray.leaks",
        ]
    elif kind == "cpu":
        keywords = ["cpu", "time profiler", "profile", "sample", "running time"]
        preferred = [
            "time-sample",
            "time-profile",
            "com.apple.xray.instrument-type.time-profiler",
            "com.apple.xray.time-profiler",
            "com.apple.xray.cpu-profile",
        ]
    elif kind == "activity":
        keywords = ["activity monitor", "cpu", "memory", "process", "ledger"]
        preferred = [
            "activity-monitor-process-live",
            "sysmon-process",
            "activity-monitor-process-ledger",
        ]
    elif kind == "memory":
        keywords = ["allocation", "memory", "heap", "malloc", "bytes"]
        preferred = [
            "allocations",
            "com.apple.xray.instrument-type.allocations",
            "com.apple.xray.allocations",
            "com.apple.xray.instrument-type.oa",
        ]
    else:
        keywords = ["network", "connection", "http", "tcp", "bytes", "requests", "duration", "latency", "response"]
        preferred = [
            "com-apple-cfnetwork-transaction-intervals-full-info",
            "com-apple-cfnetwork-task-intervals",
            "com.apple.xray.instrument-type.network",
            "com.apple.xray.network",
        ]

    last_error = None
    for schema in preferred:
        table_xml, err = _export_trace_table(trace_path, schema)
        if err:
            last_error = err
            continue
        if kind == "network":
            summary = _curate_network_summary(
                _summarize_network_table(
                    table_xml,
                    process_name=process_name,
                    process_bundle_id=process_bundle_id,
                )
            )
        elif kind == "cpu" and schema == "time-sample":
            summary = _summarize_time_sample_table(
                table_xml,
                process_name=process_name,
                process_bundle_id=process_bundle_id,
            )
        else:
            summary = _extract_numeric_summary(
                table_xml,
                process_name=process_name,
                process_bundle_id=process_bundle_id,
            )
            if kind == "activity":
                summary = _curate_activity_summary(summary)
            elif kind == "network":
                summary = _curate_network_summary(summary)
        if summary:
            return {"schema": schema, "summary": summary, "health": health}
        last_error = _default_no_data_error(kind)

    if kind == "network":
        har_payload, har_err = _export_trace_har(trace_path)
        if har_err is None:
            har_summary = _curate_network_summary(_summarize_har(har_payload))
            request_count = (
                (((har_summary.get("Request Count") or {}).get("avg")))
                if isinstance(har_summary, dict)
                else None
            )
            if request_count and request_count > 0:
                return {
                    "schema": "har",
                    "summary": har_summary,
                    "health": health,
                }

    toc_xml = None
    toc_err = None
    try:
        toc_xml, toc_err = _export_trace_toc(trace_path)
    except Exception as exc:
        toc_err = str(exc)
    if toc_err:
        return {"error": toc_err, "health": health}
    candidate_schemas = _find_candidate_schemas(toc_xml, keywords, preferred_schemas=preferred)
    if not candidate_schemas:
        return {"error": last_error or "no table schema found", "health": health}
    for schema in candidate_schemas:
        table_xml, err = _export_trace_table(trace_path, schema)
        if err:
            last_error = err
            continue
        if kind == "network":
            summary = _summarize_network_table(
                table_xml,
                process_name=process_name,
                process_bundle_id=process_bundle_id,
            )
        elif kind == "cpu" and schema == "time-sample":
            summary = _summarize_time_sample_table(
                table_xml,
                process_name=process_name,
                process_bundle_id=process_bundle_id,
            )
        else:
            summary = _extract_numeric_summary(
                table_xml,
                process_name=process_name,
                process_bundle_id=process_bundle_id,
            )
        if kind == "activity":
            summary = _curate_activity_summary(summary)
        elif kind == "network":
            summary = _curate_network_summary(summary)
        if summary:
            return {"schema": schema, "summary": summary, "health": health}
        last_error = _default_no_data_error(kind)
    if kind == "network" and last_error and "ReportMemoryException" in last_error:
        last_error = "network export hit ReportMemoryException"
    return {
        "error": last_error or _default_no_data_error(kind),
        "schema": candidate_schemas[0],
        "health": health,
    }


def _dir_size(path):
    total = 0
    for root, _, files in os.walk(path):
        for name in files:
            full = os.path.join(root, name)
            try:
                total += os.path.getsize(full)
            except OSError:
                continue
    return total


def _read_template_type(trace_path):
    template_path = os.path.join(trace_path, "form.template")
    if not os.path.exists(template_path):
        return None
    try:
        with open(template_path, "rb") as f:
            data = plistlib.load(f)
        top = data.get("$top") or {}
        objects = data.get("$objects") or []
        type_ref = top.get("$1")
        if hasattr(type_ref, "data") or "UID" in str(type(type_ref)):
            idx = int(getattr(type_ref, "data", type_ref))
            value = objects[idx]
            if isinstance(value, str):
                return value
    except Exception:
        return None
    return None


def _inspect_trace_bundle(trace_path):
    if not os.path.exists(trace_path):
        return {"status": "missing", "message": "trace bundle missing"}
    if not os.path.isdir(trace_path):
        return {"status": "broken", "message": "trace path is not a directory"}
    files = []
    dir_count = 0
    for _, dirs, file_names in os.walk(trace_path):
        dir_count += len(dirs)
        files.extend(file_names)
    file_count = len(files)
    size_bytes = _dir_size(trace_path)
    has_form_template = os.path.exists(os.path.join(trace_path, "form.template"))
    has_trace_run = os.path.exists(os.path.join(trace_path, "Trace1.run"))
    has_shared_run = os.path.exists(os.path.join(trace_path, "shared_data", "1.run"))
    template_type = _read_template_type(trace_path)
    if file_count == 0 and dir_count == 0:
        return {
            "status": "broken",
            "message": "trace bundle is empty",
            "size_bytes": size_bytes,
            "file_count": file_count,
            "template_type": template_type,
        }
    if not has_form_template and not has_trace_run and not has_shared_run:
        return {
            "status": "broken",
            "message": "trace bundle is missing expected run/template files",
            "size_bytes": size_bytes,
            "file_count": file_count,
            "template_type": template_type,
        }
    return {
        "status": "ok",
        "message": "trace bundle looks structurally valid",
        "size_bytes": size_bytes,
        "file_count": file_count,
        "has_form_template": has_form_template,
        "has_trace_run": has_trace_run,
        "has_shared_run": has_shared_run,
        "template_type": template_type,
    }


def _parse_perf_lines(log_path):
    timings = []
    if not log_path or not os.path.exists(log_path):
        return timings
    structured_re = re.compile(r"^PERF\s+iteration=(\d+)/(\d+)\s+metric=(.+?)\s+value=([0-9.]+)s$")
    legacy_re = re.compile(r"^PERF\s+(.+?):\s+([0-9.]+)s$")
    with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            stripped = line.strip()
            structured = structured_re.search(stripped)
            if structured:
                timings.append(
                    {
                        "iteration": int(structured.group(1)),
                        "total_iterations": int(structured.group(2)),
                        "metric": structured.group(3),
                        "value": float(structured.group(4)),
                    }
                )
                continue

            legacy = legacy_re.search(stripped)
            if legacy:
                timings.append(
                    {
                        "iteration": None,
                        "total_iterations": None,
                        "metric": legacy.group(1),
                        "value": float(legacy.group(2)),
                    }
                )
    return timings


TEST_NAME_TO_SCENARIO = {
    "testColdLaunchTime": "ColdLaunch",
    "testWarmResumeTime": "WarmResume",
    "testLoginSpeed": "Login",
    "testTabSwitchJourney": "TabSwitchJourney",
    "testSearchSpeed": "Search",
    "testImageLoading": "ImageLoading",
    "testRadioPlayStart": "RadioPlayStart",
    "testRadioScrollPerformance": "RadioScroll",
    "testPodcastTabLoad": "PodcastPlayStart",
    "testPlaylistLoad": "PlaylistPlayStart",
    "testLogoutSpeed": "Logout",
}


def _detect_tested_app(log_path):
    if not log_path or not os.path.exists(log_path):
        return {"key": "", "bundle_id": "", "label": "App tested"}
    app_key = ""
    bundle_id = ""
    pattern = re.compile(r"PERF_APP=([^\s]+)\s+PERF_APP_BUNDLE_ID=([^\s]+)")
    with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            match = pattern.search(line)
            if match:
                app_key = (match.group(1) or "").strip()
                bundle_id = (match.group(2) or "").strip()
    key_l = app_key.lower()
    if key_l == "qa":
        label = "Re-Write tested"
    elif key_l == "legacy":
        label = "Legacy tested"
    elif key_l == "custom":
        label = "Custom app tested"
    elif app_key:
        label = f"{app_key.upper()} tested"
    else:
        label = "App tested"
    return {"key": app_key, "bundle_id": bundle_id, "label": label}


def _summarize_perf_entries(entries):
    grouped = {}
    for entry in entries:
        metric = entry["metric"]
        grouped.setdefault(metric, []).append(entry)

    summary = {}
    for metric, runs in grouped.items():
        values = [item["value"] for item in runs]
        summary[metric] = {
            "mean": sum(values) / len(values),
            "min": min(values),
            "max": max(values),
            "count": len(values),
            "values": values,
            "iterations": [item.get("iteration") for item in runs],
        }
    return summary


def _scenario_key_for_name(name):
    value = (name or "").strip()
    if not value:
        return None
    if value in TEST_NAME_TO_SCENARIO:
        return TEST_NAME_TO_SCENARIO[value]

    lowered = value.lower()
    compact = re.sub(r"[^a-z0-9]+", "", lowered)
    for scenario in SCENARIO_DEFS:
        if lowered == scenario["key"].lower():
            return scenario["key"]
        if compact == re.sub(r"[^a-z0-9]+", "", scenario["label"].lower()):
            return scenario["key"]
        for token in scenario.get("match", []):
            token_compact = re.sub(r"[^a-z0-9]+", "", str(token).lower())
            if compact == token_compact:
                return scenario["key"]
    return None


def _parse_scenario_statuses(log_path):
    statuses = {}
    if not log_path or not os.path.exists(log_path):
        return statuses

    status_re = re.compile(r"^PERF_STATUS\s+iteration=(\d+)/(\d+)\s+metric=(.+?)\s+state=(started|finished)$")
    skip_re = re.compile(r"^PERF_SKIP\s+iteration=(\d+)/(\d+)\s+metric=(.+?)\s+reason=(.+)$")
    failed_test_re = re.compile(r"^Test Case '-\[[^\]]+\s+(test[A-Za-z0-9_]+)\]' failed")

    def ensure_entry(key):
        return statuses.setdefault(key, {"status": "started", "reason": ""})

    with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            stripped = line.strip()

            match = status_re.search(stripped)
            if match:
                key = _scenario_key_for_name(match.group(3))
                if key:
                    entry = ensure_entry(key)
                    state = match.group(4)
                    if state == "finished" and entry.get("status") not in {"failed", "skipped"}:
                        entry["status"] = "finished"
                continue

            match = skip_re.search(stripped)
            if match:
                key = _scenario_key_for_name(match.group(3))
                if key:
                    entry = ensure_entry(key)
                    entry["status"] = "skipped"
                    entry["reason"] = match.group(4)
                continue

            match = failed_test_re.search(stripped)
            if match:
                key = _scenario_key_for_name(match.group(1))
                if key:
                    entry = ensure_entry(key)
                    entry["status"] = "failed"
                    if not entry.get("reason"):
                        entry["reason"] = "test_failed"

    return statuses


def _parse_selected_scenarios(log_path):
    if not log_path or not os.path.exists(log_path):
        return []

    selected_re = re.compile(r"^PERF_SELECTED_SCENARIOS\s+(.+)$")
    selected = []
    with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            match = selected_re.search(line.strip())
            if not match:
                continue
            selected = [
                key
                for key in (_scenario_key_for_name(part.strip()) for part in match.group(1).split(","))
                if key
            ]

    seen = set()
    deduped = []
    for key in selected:
        if key in seen:
            continue
        seen.add(key)
        deduped.append(key)
    return deduped


def _discover_xcresults(root_path):
    if not root_path or not os.path.isdir(root_path):
        return []

    discovered = []
    for name in sorted(os.listdir(root_path)):
        if name.endswith(".xcresult"):
            discovered.append(os.path.join(root_path, name))
    try:
        discovered.sort(key=lambda path: (os.path.getmtime(path), path))
    except OSError:
        pass
    return discovered


def _parse_failures_from_log(log_path):
    failures = []
    if not log_path or not os.path.exists(log_path):
        return failures
    failure_re = re.compile(r"^(.+?):\s+error:\s+(.+)$")
    with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            m = failure_re.search(line.strip())
            if m:
                failures.append({"message": m.group(2), "file": m.group(1), "line": None})
    return failures


def _collect_metrics(obj, collected):
    if isinstance(obj, dict):
        test_name = _unwrap(obj.get("testName"))
        perf_metrics = obj.get("performanceMetrics")
        if test_name and isinstance(perf_metrics, list):
            for metric in perf_metrics:
                display = _unwrap(metric.get("displayName")) or _unwrap(metric.get("identifier"))
                value = _unwrap(metric.get("value"))
                unit = _unwrap(metric.get("unitOfMeasurement"))
                collected.setdefault(test_name, []).append(
                    {"name": display, "value": value, "unit": unit}
                )
        for v in obj.values():
            _collect_metrics(v, collected)
    elif isinstance(obj, list):
        for item in obj:
            _collect_metrics(item, collected)


def _extract_launch_metrics(metrics):
    launch = []
    for test, entries in metrics.items():
        name_l = test.lower()
        if "coldlaunch" in name_l or "warmresume" in name_l or "launch" in name_l or "resume" in name_l:
            for e in entries:
                launch.append(
                    {
                        "test": test,
                        "name": e.get("name"),
                        "value": e.get("value"),
                        "unit": e.get("unit"),
                    }
                )
    return launch


def _find_tests_ref_id(obj):
    if isinstance(obj, dict):
        if "testsRef" in obj and isinstance(obj["testsRef"], dict):
            ref = obj["testsRef"]
            ref_id = _unwrap(ref.get("id"))
            if ref_id:
                return ref_id
        for v in obj.values():
            found = _find_tests_ref_id(v)
            if found:
                return found
    elif isinstance(obj, list):
        for item in obj:
            found = _find_tests_ref_id(item)
            if found:
                return found
    return None


def _load_tests_ref(path, ref_id):
    if not ref_id:
        return None, "testsRef id not found"
    attempts = [
        ["xcrun", "xcresulttool", "get", "object", "--legacy", "--path", path, "--id", ref_id, "--format", "json"],
        ["xcrun", "xcresulttool", "get", "object", "--path", path, "--id", ref_id, "--format", "json"],
        ["xcrun", "xcresulttool", "get", "--legacy", "--path", path, "--id", ref_id, "--format", "json"],
    ]
    try:
        last_err = None
        for attempt in attempts:
            try:
                result = subprocess.run(
                    attempt,
                    check=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                return json.loads(result.stdout), None
            except Exception as exc:
                last_err = exc
        return None, f"xcresulttool testsRef failed: {last_err}"
    except Exception as exc:
        return None, f"xcresulttool testsRef failed: {exc}"


def _collect_test_durations(obj, durations):
    if isinstance(obj, dict):
        name = _unwrap(obj.get("testName")) or _unwrap(obj.get("identifier")) or _unwrap(obj.get("name"))
        duration = _unwrap(obj.get("duration"))
        if name and duration is not None:
            try:
                durations[name] = float(duration)
            except Exception:
                pass
        for v in obj.values():
            _collect_test_durations(v, durations)
    elif isinstance(obj, list):
        for item in obj:
            _collect_test_durations(item, durations)


def _extract_launch_durations(durations):
    launch = []
    for name, value in durations.items():
        name_l = name.lower()
        if "coldlaunch" in name_l or "warmresume" in name_l or "launch" in name_l or "resume" in name_l:
            launch.append(
                {
                    "test": name,
                    "name": "duration",
                    "value": value,
                    "unit": "s",
                }
            )
    return launch


def _launch_label(name):
    name_l = name.lower()
    if "coldlaunch" in name_l:
        return "ColdLaunch"
    if "warmresume" in name_l or ("warm" in name_l and "resume" in name_l):
        return "WarmResume"
    if "launch" in name_l:
        return "Launch"
    if "resume" in name_l:
        return "Resume"
    return None


def _collect_failures(obj, failures):
    if isinstance(obj, dict):
        if "failureSummaries" in obj and isinstance(obj["failureSummaries"], list):
            for item in obj["failureSummaries"]:
                failures.append(_parse_failure(item))
        if "testFailureSummaries" in obj and isinstance(obj["testFailureSummaries"], list):
            for item in obj["testFailureSummaries"]:
                failures.append(_parse_failure(item))
        for v in obj.values():
            _collect_failures(v, failures)
    elif isinstance(obj, list):
        for item in obj:
            _collect_failures(item, failures)


def _parse_failure(item):
    if not isinstance(item, dict):
        return {"message": str(item)}
    return {
        "message": _unwrap(item.get("message")) or _unwrap(item.get("failureDescription")),
        "file": _unwrap(item.get("fileName")),
        "line": _unwrap(item.get("lineNumber")),
    }


SCENARIO_DEFS = [
    {
        "key": "ColdLaunch",
        "label": "Cold Launch",
        "match": ["coldlaunch"],
        "description": "Measures time from launching a terminated app until the app becomes interactive on its first visible screen.",
        "thresholds": {"pass": 5.0, "warn": 8.0},
    },
    {
        "key": "WarmResume",
        "label": "Warm Resume",
        "match": ["warmresume", "warm resume"],
        "description": "Measures time from sending the app to background with Home and activating it again until it is interactive.",
        "thresholds": {"pass": 2.0, "warn": 4.0},
    },
    {
        "key": "Login",
        "label": "Login",
        "match": ["login"],
        "description": "Measures login processing from submitting pre-filled credentials to reaching the signed-in app state.",
        "thresholds": {"pass": 8.0, "warn": 12.0},
    },
    {
        "key": "TabSwitchJourney",
        "label": "Tab Switch Journey",
        "match": ["tabswitchjourney", "tab switch", "tabswitch"],
        "description": "Measures moving across the main tabs: Home, Radio, Podcasts, Playlists, Search, and back to Home.",
        "thresholds": {"pass": 4.0, "warn": 6.5},
    },
    {
        "key": "Logout",
        "label": "Logout",
        "match": ["logout"],
        "description": "Measures the logout flow from opening settings/account controls through returning to the logged-out state.",
        "thresholds": {"pass": 5.0, "warn": 8.0},
    },
    {
        "key": "Search",
        "label": "Search",
        "match": ["search"],
        "description": "Measures search response from submitting a pre-filled Taylor Swift query until results are visible.",
        "thresholds": {"pass": 4.0, "warn": 7.0},
    },
    {
        "key": "ImageLoading",
        "label": "Image Loading",
        "match": ["imageloading", "image loading", "artwork first paint", "album artwork"],
        "description": "Measures time from opening a media result until artwork becomes visible on screen.",
        "thresholds": {"pass": 3.5, "warn": 6.0},
    },
    {
        "key": "RadioPlayStart",
        "label": "Radio Play Start",
        "match": ["radioplaystart", "radio play"],
        "description": "Measures opening Radio content, selecting a station, and reaching active playback indicators.",
        "thresholds": {"pass": 5.0, "warn": 8.0},
    },
    {
        "key": "RadioScroll",
        "label": "Radio Scroll",
        "match": ["radioscroll", "radio scroll"],
        "description": "Measures browsing performance while swiping through scrollable Radio tab content.",
        "thresholds": {"pass": 3.0, "warn": 5.0},
    },
    {
        "key": "PodcastPlayStart",
        "label": "Podcast Play Start",
        "match": ["podcastplaystart", "podcasttab", "podcast"],
        "description": "Measures opening podcast content, selecting a playable item, and reaching playback started.",
        "thresholds": {"pass": 4.0, "warn": 6.5},
    },
    {
        "key": "PlaylistPlayStart",
        "label": "Playlist Play Start",
        "match": ["playlistplaystart", "playlist"],
        "description": "Measures opening playlist content, starting a track, and reaching playback started.",
        "thresholds": {"pass": 4.0, "warn": 6.5},
    },
]


TRACE_SCENARIO_HINTS = {
    "Activity Monitor": ["cpu", "memory", "mem"],
    "Time Profiler": ["cpu", "running time", "sample", "weight", "time"],
    "Allocations": ["bytes", "persistent", "malloc", "allocation", "memory", "heap"],
    "Energy Log": ["cpu", "cpu time", "energy", "power", "wakeups", "thermal"],
    "Leaks": ["leaks", "bytes", "persistent", "malloc", "allocation"],
    "Network": ["bytes", "request", "response", "connection", "http", "tcp", "duration", "latency", "time", "transfer"],
}


def _scenario_def_for_metric(metric_name):
    metric_l = (metric_name or "").strip().lower()
    for scenario in SCENARIO_DEFS:
        for token in scenario["match"]:
            if token in metric_l:
                return scenario
    return None


def _scenario_description(metric_name):
    scenario = _scenario_def_for_metric(metric_name)
    if not scenario:
        return ""
    return scenario.get("description", "")


def _evaluate_threshold(value, thresholds):
    if value is None or not thresholds:
        return {"status": "unknown", "thresholds": thresholds or {}}
    pass_limit = thresholds.get("pass")
    warn_limit = thresholds.get("warn")
    if pass_limit is not None and value <= pass_limit:
        status = "pass"
    elif warn_limit is not None and value <= warn_limit:
        status = "warn"
    else:
        status = "fail"
    return {"status": status, "thresholds": thresholds}


def _fmt_thresholds(thresholds):
    if not thresholds:
        return ""
    parts = []
    if thresholds.get("pass") is not None:
        parts.append(f"pass <= {thresholds['pass']:.1f}s")
    if thresholds.get("warn") is not None:
        parts.append(f"warn <= {thresholds['warn']:.1f}s")
    return " | ".join(parts)


def _select_trace_metrics(summary, hints):
    if not summary:
        return []
    scored = []
    for metric_name, stats in summary.items():
        name_l = (metric_name or "").lower()
        score = sum(1 for hint in hints if hint in name_l)
        if score > 0:
            scored.append((score, metric_name, stats))
    scored.sort(key=lambda item: (-item[0], item[1]))
    return [{"name": metric_name, "stats": stats} for _, metric_name, stats in scored[:3]]


def _build_scenario_cards(custom_summary, trace_summaries, scenario_statuses=None, selected_scenarios=None):
    cards = []
    scenario_statuses = scenario_statuses or {}
    selected_scenarios = set(selected_scenarios or [])
    for scenario in SCENARIO_DEFS:
        stats = custom_summary.get(scenario["key"])
        status_info = scenario_statuses.get(scenario["key"]) or {}
        was_selected = scenario["key"] in selected_scenarios
        if not stats and not status_info and not was_selected:
            continue
        instruments = []
        for trace_name, info in (trace_summaries or {}).items():
            trace_metrics = _select_trace_metrics(info.get("summary") or {}, TRACE_SCENARIO_HINTS.get(trace_name, []))
            if trace_metrics:
                instruments.append(
                    {
                        "trace": trace_name,
                        "attribution": "best-effort global trace mapping",
                        "metrics": trace_metrics,
                        "error": info.get("error"),
                    }
                )
        timing = stats or {
            "mean": 0.0,
            "min": 0.0,
            "max": 0.0,
            "count": 0,
            "values": [],
            "iterations": [],
        }
        scenario_status = status_info.get("status") or ("finished" if stats else ("not_run" if was_selected else "unknown"))
        scenario_reason = status_info.get("reason") or ("no metric emitted" if was_selected and not stats else "")
        cards.append(
            {
                "key": scenario["key"],
                "label": scenario["label"],
                "description": scenario.get("description", ""),
                "timing": timing,
                "instruments": instruments,
                "status": scenario_status,
                "status_reason": scenario_reason,
            }
        )
    return cards


def _fmt_num(value):
    if value is None or value == "" or str(value).upper() == "NA":
        return "0.000"
    try:
        return f"{float(value):.3f}"
    except Exception:
        return str(value)


def _load_trace_manifest(traces_dir):
    manifest_path = os.path.join(traces_dir, "trace_manifest.txt")
    if not os.path.exists(manifest_path):
        return set()
    entries = []
    with open(manifest_path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            item = line.strip()
            if item:
                entries.append(item)
    return set(entries)


def _discover_trace_bundles(traces_dir):
    if not os.path.isdir(traces_dir):
        return set()
    bundles = set()
    for name in os.listdir(traces_dir):
        if name.endswith(".trace") and os.path.isdir(os.path.join(traces_dir, name)):
            bundles.add(name)
    return bundles


def _trace_sidecar_exists(traces_dir, trace_name):
    candidates = {
        "ActivityMonitor": [
            "ActivityMonitor.log",
            "ActivityMonitor.export.log",
            "ActivityMonitor.sysmon-process.xml",
        ],
        "TimeProfiler": [
            "Time_Profiler.log",
            "TimeProfiler.export.log",
            "TimeProfiler.table.xml",
        ],
        "Allocations": [
            "Allocations.log",
            "Allocations.preflight.log",
            "Allocations.export.log",
            "Allocations.table.xml",
        ],
        "Leaks": [
            "Leaks.log",
            "Leaks.preflight.log",
            "Leaks.export.log",
            "Leaks.table.xml",
        ],
        "Network": [
            "Network.log",
            "Network.export.log",
            "Network.task-intervals.xml",
            "Network.har",
        ],
    }
    for name in candidates.get(trace_name, []):
        if os.path.exists(os.path.join(traces_dir, name)):
            return True
    return False


def _write_json(path, payload):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, sort_keys=True)


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


def _compose_device_display_name(model_name, device_name, os_version, is_simulator):
    primary = (model_name or "").strip() or (device_name or "").strip()
    os_version = _short_os_version(os_version)
    if is_simulator and primary and "simulator" not in primary.lower():
        primary = f"{primary} Simulator"
    if primary and os_version:
        return f"{primary} • iOS {os_version}"
    return primary or ""


def _resolve_device_metadata(run_context):
    display_name = (run_context.get("device_display_name") or "").strip()
    if display_name:
        return {
            "display_name": display_name,
            "model_name": (run_context.get("device_model") or "").strip(),
            "device_name": (run_context.get("device_name") or "").strip(),
            "os_version": _short_os_version(run_context.get("device_os_version") or run_context.get("device_os_build")),
            "kind": (run_context.get("device_kind") or "").strip(),
        }

    model_name = (run_context.get("device_model") or "").strip()
    device_name = (run_context.get("device_name") or "").strip()
    os_version = _short_os_version(run_context.get("device_os_version") or run_context.get("device_os_build"))
    kind = (run_context.get("device_kind") or "").strip()
    if model_name or device_name or os_version:
        return {
            "display_name": _compose_device_display_name(model_name, device_name, os_version, kind == "simulator"),
            "model_name": model_name,
            "device_name": device_name,
            "os_version": os_version,
            "kind": kind,
        }

    target_id = _target_identifier(run_context)
    if target_id:
        for device in _xcdevice_records():
            if str(device.get("identifier") or "").strip() != target_id:
                continue
            model_name = str(device.get("modelName") or "").strip()
            device_name = str(device.get("name") or "").strip()
            os_version = _short_os_version(device.get("operatingSystemVersion"))
            is_simulator = bool(device.get("simulator"))
            return {
                "display_name": _compose_device_display_name(model_name, device_name, os_version, is_simulator),
                "model_name": model_name,
                "device_name": device_name,
                "os_version": os_version,
                "kind": "simulator" if is_simulator else "real_device",
            }

    destination = (run_context.get("destination") or "").strip()
    if destination:
        return {"display_name": destination}
    if target_id:
        return {"display_name": target_id}
    return {}


def _device_info(payload):
    run_context = payload.get("run_context") or {}
    return (_resolve_device_metadata(run_context).get("display_name") or "").strip()


def _write_text(path, payload):
    lines = []
    lines.append("PerfoMace")
    lines.append(f"Generated: {payload.get('generated_at')}")
    tested_app = payload.get("tested_app") or {}
    if tested_app.get("label"):
        lines.append(f"Target: {tested_app.get('label')}")
    if tested_app.get("bundle_id"):
        lines.append(f"Bundle ID: {tested_app.get('bundle_id')}")
    device_info = _device_info(payload)
    if device_info:
        lines.append(f"Device: {device_info}")
    lines.append("")
    lines.append("Scenario Cards")
    scenario_cards = payload.get("scenario_cards", [])
    if not scenario_cards:
        lines.append("- (no scenario cards available)")
    else:
        for card in scenario_cards:
            timing = card.get("timing") or {}
            mean = timing.get("mean")
            min_v = timing.get("min")
            max_v = timing.get("max")
            try:
                timing_line = f"time={float(mean):.3f}s min={float(min_v):.3f}s max={float(max_v):.3f}s"
            except Exception:
                timing_line = f"time={mean} min={min_v} max={max_v}"
            lines.append(f"- {card.get('label')}: {timing_line}")
            if card.get("description"):
                lines.append(f"  Measures: {card.get('description')}")
            instruments = card.get("instruments") or []
            if not instruments:
                lines.append("  Instruments: (none)")
            else:
                for instrument in instruments:
                    lines.append(f"  {instrument.get('trace')} ({instrument.get('attribution')}):")
                    for metric in instrument.get("metrics") or []:
                        stat = metric.get("stats") or {}
                        lines.append(
                            f"    {metric.get('name')}: avg={_fmt_num(stat.get('avg'))} max={_fmt_num(stat.get('max'))} min={_fmt_num(stat.get('min'))}"
                        )
                    if instrument.get("error"):
                        lines.append(f"    error: {instrument.get('error')}")
    lines.append("")
    lines.append("Iteration Summary")
    summary = payload.get("custom_timings_summary", {})
    if not summary:
        lines.append("- (no PERF timings found)")
    else:
        for metric, stats in summary.items():
            values = ", ".join(f"{value:.3f}s" for value in stats.get("values", []))
            lines.append(
                f"- {metric}: mean={stats['mean']:.3f}s min={stats['min']:.3f}s max={stats['max']:.3f}s runs=[{values}]"
            )
    lines.append("")
    lines.append("Per-Iteration Timings")
    entries = payload.get("custom_timing_runs", [])
    if not entries:
        lines.append("- (no iteration runs found)")
    else:
        for entry in entries:
            label = f"iteration {entry['iteration']}" if entry.get("iteration") is not None else "iteration n/a"
            lines.append(f"- {label}: {entry['metric']} = {entry['value']:.3f}s")
    lines.append("")
    lines.append("XCTest Metrics")
    metrics = payload.get("xc_metrics", {})
    if not metrics:
        lines.append("- (no XCTest metrics found)")
    else:
        for test, entries in metrics.items():
            lines.append(f"- {test}")
            for e in entries:
                name = e.get("name")
                value = e.get("value")
                unit = e.get("unit") or ""
                lines.append(f"  {name}: {value} {unit}".rstrip())
    lines.append("")
    lines.append("Launch Metrics (XCTest)")
    launch_metrics = payload.get("launch_metrics", [])
    if not launch_metrics:
        lines.append("- (no launch metrics found)")
    else:
        for e in launch_metrics:
            unit = e.get("unit") or ""
            lines.append(f"- {e.get('test')}: {e.get('name')} = {e.get('value')} {unit}".rstrip())
    lines.append("")
    lines.append("Failures")
    failures = payload.get("failures", [])
    if not failures:
        lines.append("- (none)")
    else:
        for f in failures:
            loc = ""
            if f.get("file") and f.get("line"):
                loc = f" ({f['file']}:{f['line']})"
            lines.append(f"- {f.get('message')}{loc}")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def _trace_snapshot(card, trace_names, preferred_names=None, hints=None):
    if isinstance(trace_names, str):
        trace_names = [trace_names]
    preferred_names = preferred_names or []
    hints = [hint.lower() for hint in (hints or [])]

    def _pick_metric(metrics):
        if not metrics:
            return {}
        metric_by_name = {metric.get("name"): metric for metric in metrics if metric.get("name")}
        for name in preferred_names:
            if name in metric_by_name:
                return metric_by_name[name]
        if hints:
            scored = []
            for metric in metrics:
                name_l = (metric.get("name") or "").lower()
                score = sum(1 for hint in hints if hint in name_l)
                if score > 0:
                    scored.append((score, metric))
            if scored:
                scored.sort(key=lambda item: (-item[0], item[1].get("name", "")))
                return scored[0][1]
        return metrics[0]

    for trace_name in trace_names:
        for instrument in card.get("instruments") or []:
            if instrument.get("trace") != trace_name:
                continue
            metric = _pick_metric(instrument.get("metrics") or [])
            stats = (metric or {}).get("stats") or {}
            return {
                "metric": (metric or {}).get("name", ""),
                "avg": stats.get("avg"),
                "max": stats.get("max"),
                "min": stats.get("min"),
                "error": instrument.get("error", ""),
            }

    for trace_name in trace_names:
        for instrument in card.get("instruments") or []:
            if instrument.get("trace") == trace_name:
                return {"metric": "", "avg": "", "max": "", "min": "", "error": instrument.get("error", "")}
    return {"metric": "", "avg": "", "max": "", "min": "", "error": ""}


def _write_csv(path, payload):
    scenario_cards = payload.get("scenario_cards") or []
    summary = payload.get("custom_timings_summary") or {}
    generated_at = payload.get("generated_at", "")
    tested_app = payload.get("tested_app") or {}
    device_info = _device_info(payload)

    with open(path, "w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["Generated At", generated_at])
        writer.writerow(["Tested App", tested_app.get("label", "")])
        writer.writerow(["Bundle ID", tested_app.get("bundle_id", "")])
        if device_info:
            writer.writerow(["Device", device_info])
        writer.writerow([])
        writer.writerow(["Scenario Summary"])
        writer.writerow(["Scenario", "Average (s)", "Min (s)", "Max (s)", "Runs"])
        if scenario_cards:
            for card in scenario_cards:
                timing = card.get("timing") or {}
                mean = _fmt_num(timing.get("mean"))
                min_value = _fmt_num(timing.get("min"))
                max_value = _fmt_num(timing.get("max"))
                runs = timing.get("count", 0)
                writer.writerow([
                    card.get("label", ""),
                    mean,
                    min_value,
                    max_value,
                    runs,
                ])
        else:
            for metric, stats in summary.items():
                writer.writerow([
                    metric,
                    _fmt_num(stats.get("mean")),
                    _fmt_num(stats.get("min")),
                    _fmt_num(stats.get("max")),
                    stats.get("count", 0),
                ])

        trace_summaries = payload.get("trace_summaries") or {}
        writer.writerow([])
        writer.writerow(["Trace Summary"])
        writer.writerow([
            "Trace",
            "Metric",
            "Avg",
            "Min",
            "Max",
            "Count",
            "Status",
            "Error",
        ])
        if trace_summaries:
            for trace_name, info in trace_summaries.items():
                summary_map = info.get("summary") or {}
                health = info.get("health") or {}
                status = health.get("status") or ("ok" if not info.get("error") else "error")
                error = info.get("error") or ""
                if not summary_map:
                    writer.writerow([trace_name, "Unavailable", "0.000", "0.000", "0.000", "0", status, error or "No trace metrics exported"])
                    continue
                for metric_name, stat in summary_map.items():
                    writer.writerow([
                        trace_name,
                        metric_name,
                        _fmt_num(stat.get("avg")),
                        _fmt_num(stat.get("min")),
                        _fmt_num(stat.get("max")),
                        stat.get("count", 0),
                        status,
                        error,
                    ])


def _write_html(path, payload):
    custom_summary = payload.get("custom_timings_summary", {})
    custom_runs = payload.get("custom_timing_runs", [])
    metrics = payload.get("xc_metrics", {})
    launch_metrics = payload.get("launch_metrics", [])
    failures = payload.get("failures", [])
    generated = payload.get("generated_at", "")
    tested_app = payload.get("tested_app") or {}
    device_info = _device_info(payload)
    traces = payload.get("traces", {})
    trace_summaries = payload.get("trace_summaries", {})
    logo_path = payload.get("logo_path")
    scenario_cards = payload.get("scenario_cards", [])

    def _fmt(v):
        if v is None or v == "" or str(v).upper() == "NA":
            return "0.000"
        try:
            return f"{float(v):.3f}"
        except Exception:
            return str(v)

    def _fmt_time(v):
        if v is None or v == "" or str(v).upper() == "NA":
            return "0.000s"
        try:
            return f"{float(v):.3f}s"
        except Exception:
            return str(v)

    def _html_escape(value):
        s = "" if value is None else str(value)
        return (
            s.replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace('"', "&quot;")
        )

    html = []
    html.append("<!doctype html>")
    html.append("<html><head><meta charset='utf-8'>")
    html.append(f"<title>PerfoMace · {_html_escape(tested_app.get('label') or 'App tested')}</title>")
    html.append("<style>")
    html.append(":root{--ink:#0f172a;--muted:#6b7280;--card:#ffffff;--line:#e5e7eb;--accent:#d97706;--accent2:#0f52ba;--pass-bg:#dcfce7;--pass-ink:#166534;--warn-bg:#fef3c7;--warn-ink:#92400e;--fail-bg:#fee2e2;--fail-ink:#b91c1c;--unknown-bg:#e2e8f0;--unknown-ink:#334155}")
    html.append("body{font-family:'Avenir Next','Helvetica Neue',sans-serif;margin:0;color:var(--ink);background:radial-gradient(1200px 600px at 20% -10%, #fff4d6 0%, #ffffff 45%, #e8f1ff 100%)}")
    html.append(".wrap{max-width:1520px;margin:0 auto;padding:32px}")
    html.append(".hero{background:linear-gradient(135deg,#fffdf8 0%,#eef4ff 100%);border:1px solid var(--line);border-radius:18px;padding:28px;box-shadow:0 10px 30px rgba(15,23,42,.08)}")
    html.append(".logo{font-size:36px;letter-spacing:1px;font-weight:700;text-align:center}")
    html.append(".subtitle{color:var(--muted);text-align:center;margin-top:6px}")
    html.append(".meta{color:var(--muted);text-align:center;margin-top:10px;font-size:13px}")
    html.append(".grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(520px,1fr));gap:16px;margin-top:24px;align-items:start}")
    html.append(".card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px;box-shadow:0 6px 16px rgba(15,23,42,.06);overflow:hidden}")
    html.append(".scenario-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:16px;margin-top:24px}")
    html.append(".scenario-card{background:linear-gradient(180deg,#ffffff 0%,#f8fafc 100%);border:1px solid var(--line);border-radius:16px;padding:18px;box-shadow:0 8px 20px rgba(15,23,42,.08)}")
    html.append(".scenario-time{font-size:30px;font-weight:700;line-height:1.1;margin-top:10px}")
    html.append(".scenario-desc{color:#475569;font-size:13px;line-height:1.5;margin-top:10px}")
    html.append(".kv{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-top:14px}")
    html.append(".kv-box{background:#f8fafc;border:1px solid var(--line);border-radius:12px;padding:10px}")
    html.append(".kv-label{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.04em}")
    html.append(".kv-value{font-size:16px;font-weight:600;margin-top:4px}")
    html.append(".metric-list{margin-top:14px;border-top:1px solid var(--line);padding-top:12px}")
    html.append(".metric-group{margin-top:10px}")
    html.append(".metric-group h3{font-size:13px;margin:0 0 6px 0}")
    html.append(".metric-group ul{margin:0;padding-left:18px;color:var(--muted);font-size:12px}")
    html.append(".error-box{margin-top:8px;padding:10px 12px;border-radius:12px;background:#fff1f2;border:1px solid #fecdd3;color:#9f1239;font-size:12px;white-space:normal;word-break:break-word}")
    html.append("h2{margin:0 0 10px 0;font-size:18px}")
    html.append("table{border-collapse:collapse;width:100%}")
    html.append("th,td{border-bottom:1px solid var(--line);padding:8px 6px;text-align:left;font-size:13px}")
    html.append("th{color:var(--muted);font-weight:600;text-transform:uppercase;letter-spacing:.04em;font-size:11px}")
    html.append(".table-scroll{overflow-x:auto;overflow-y:hidden;padding-bottom:2px}")
    html.append(".table-scroll table{min-width:100%}")
    html.append(".pill{display:inline-block;padding:4px 10px;border-radius:999px;background:#fee2e2;color:#b91c1c;font-size:12px}")
    html.append(".muted{color:var(--muted)}")
    html.append(".footer{color:var(--muted);margin-top:24px;text-align:center}")
    html.append(".watermark{position:fixed;right:18px;bottom:14px;padding:7px 12px;border-radius:999px;border:1px solid rgba(148,163,184,.35);background:rgba(255,255,255,.82);backdrop-filter:blur(8px);color:#334155;font-size:11px;font-weight:700;letter-spacing:.02em;box-shadow:0 8px 20px rgba(15,23,42,.08)}")
    html.append(".bar{height:8px;background:linear-gradient(90deg,var(--accent),var(--accent2));border-radius:999px}")
    html.append(".bar-wrap{background:#f1f5f9;border-radius:999px}")
    html.append(".tabs{display:flex;gap:8px;flex-wrap:wrap;margin:8px 0 12px}")
    html.append(".tab-btn{border:1px solid var(--line);background:#fff;border-radius:999px;padding:6px 12px;font-size:12px;cursor:pointer}")
    html.append(".tab-btn.active{background:var(--accent);color:#fff;border-color:var(--accent)}")
    html.append(".tc-table tr[data-tag] td{vertical-align:middle}")
    html.append("</style></head><body><div class='wrap'>")
    html.append("<div class='hero'>")
    if logo_path:
        html.append(f"<div style='text-align:center;'><img src='{logo_path}' alt='PerfoMace' style='max-width:420px;width:60%;height:auto;'/></div>")
    else:
        html.append("<div class='logo'>PerfoMace</div>")
    html.append(f"<div class='subtitle'>{_html_escape(tested_app.get('label') or 'App tested')}</div>")
    html.append(f"<div class='meta'>Generated: {generated}</div>")
    if tested_app.get("bundle_id"):
        html.append(f"<div class='meta'>Bundle ID: {_html_escape(tested_app.get('bundle_id'))}</div>")
    if device_info:
        html.append(f"<div class='meta'>Device: {_html_escape(device_info)}</div>")
    html.append("</div>")

    if scenario_cards:
        html.append("<div class='scenario-grid'>")
        for card in scenario_cards:
            timing = card.get("timing") or {}
            instruments = card.get("instruments") or []
            html.append("<div class='scenario-card'>")
            html.append(f"<h2>{card.get('label')}</h2>")
            if card.get("description"):
                html.append(f"<div class='scenario-desc'>{_html_escape(card.get('description'))}</div>")
            html.append(f"<div class='scenario-time'>{_html_escape(_fmt_time(timing.get('mean')))}</div>")
            if card.get("status") in {"failed", "skipped"}:
                status_reason = card.get("status_reason") or card.get("status")
                html.append(f"<div class='error-box'>Scenario reported as {_html_escape(card.get('status'))}. {_html_escape(status_reason)}</div>")
            html.append("<div class='kv'>")
            html.append(f"<div class='kv-box'><div class='kv-label'>Runs</div><div class='kv-value'>{timing.get('count', 0)}</div></div>")
            html.append(f"<div class='kv-box'><div class='kv-label'>Min</div><div class='kv-value'>{_html_escape(_fmt_time(timing.get('min')))}</div></div>")
            html.append(f"<div class='kv-box'><div class='kv-label'>Max</div><div class='kv-value'>{_html_escape(_fmt_time(timing.get('max')))}</div></div>")
            html.append("</div>")
            html.append("<div class='metric-list'>")
            if instruments:
                for instrument in instruments:
                    html.append("<div class='metric-group'>")
                    html.append(f"<h3>{instrument.get('trace')} <span class='muted'>({instrument.get('attribution')})</span></h3>")
                    if instrument.get("metrics"):
                        html.append("<ul>")
                        for metric in instrument.get("metrics") or []:
                            stat = metric.get("stats") or {}
                            html.append(
                                f"<li>{metric.get('name')}: avg={_fmt(stat.get('avg'))} max={_fmt(stat.get('max'))} min={_fmt(stat.get('min'))}</li>"
                            )
                        html.append("</ul>")
                    if instrument.get("error"):
                        html.append(f"<div class='error-box'>Instruments export error: {_html_escape(instrument.get('error'))}</div>")
                    html.append("</div>")
            else:
                html.append("<div class='muted'>No Instruments attribution available for this scenario.</div>")
            html.append("</div>")
            html.append("</div>")
        html.append("</div>")

    html.append("<div class='grid'>")
    html.append("<div class='card'>")
    html.append("<h2>Iteration Summary</h2>")
    if custom_summary:
        tag_map = {
            "login": "Auth",
            "logout": "Auth",
            "auth": "Auth",
            "tab": "Navigation",
            "navigation": "Navigation",
            "search": "Search",
            "image": "Images",
            "artwork": "Images",
            "album": "Images",
            "radio": "Playback",
            "podcast": "Podcast",
            "playlist": "Playlist",
            "launch": "Launch",
            "resume": "Launch",
        }

        def _tag_for(name):
            n = name.lower()
            for key, tag in tag_map.items():
                if key in n:
                    return tag
            return "Other"

        tags = ["All", "Auth", "Navigation", "Search", "Album", "Playback", "Podcast", "Playlist", "Launch", "Other"]
        html.append("<div class='tabs'>")
        for tag in tags:
            html.append(f"<button class='tab-btn' data-tag='{tag}'>{tag}</button>")
        html.append("</div>")

        html.append("<div class='table-scroll'><table class='tc-table'><tr><th>Metric</th><th>Runs</th><th>Average (s)</th><th>Min</th><th>Max</th><th>Description</th><th>Tag</th></tr>")
        for metric, stats in custom_summary.items():
            tag = _tag_for(metric)
            runs = ", ".join(_fmt(value) for value in stats.get("values", []))
            description = _html_escape(_scenario_description(metric))
            html.append(
                f"<tr data-tag='{tag}'><td>{metric}</td><td>{runs}</td><td>{_fmt(stats.get('mean'))}</td><td>{_fmt(stats.get('min'))}</td><td>{_fmt(stats.get('max'))}</td><td>{description}</td><td><span class='pill'>{tag}</span></td></tr>"
            )
        html.append("</table></div>")
        html.append("<script>")
        html.append("""
        (function(){
          const buttons = document.querySelectorAll('.tab-btn');
          const rows = document.querySelectorAll('.tc-table tr[data-tag]');
          function activate(tag){
            buttons.forEach(b=>b.classList.toggle('active', b.dataset.tag===tag));
            rows.forEach(r=>{
              const show = (tag==='All') || (r.dataset.tag===tag);
              r.style.display = show ? '' : 'none';
            });
          }
          buttons.forEach(b=>b.addEventListener('click', ()=>activate(b.dataset.tag)));
          activate('All');
        })();
        """)
        html.append("</script>")
    else:
        html.append("<div class='muted'>(no PERF timings found)</div>")
    html.append("</div>")

    html.append("<div class='card'>")
    html.append("<h2>Per-Iteration Runs</h2>")
    if custom_runs:
        max_v = max(item["value"] for item in custom_runs) if custom_runs else 1.0
        html.append("<div class='table-scroll'><table><tr><th>Iteration</th><th>Metric</th><th>Description</th><th>Time (s)</th><th>Chart</th></tr>")
        for item in custom_runs:
            pct = 0 if max_v == 0 else int((item["value"] / max_v) * 100)
            iteration = item.get("iteration")
            label = f"{iteration}/{item.get('total_iterations')}" if iteration is not None and item.get("total_iterations") else "n/a"
            description = _html_escape(_scenario_description(item["metric"]))
            html.append(f"<tr><td>{label}</td><td>{item['metric']}</td><td>{description}</td><td>{_fmt(item['value'])}</td><td><div class='bar-wrap'><div class='bar' style='width:{pct}%'></div></div></td></tr>")
        html.append("</table></div>")
    else:
        html.append("<div class='muted'>(no iteration runs found)</div>")
    html.append("</div>")

    html.append("<div class='card'>")
    html.append("<h2>Launch Metrics (XCTest)</h2>")
    if launch_metrics:
        html.append("<div class='table-scroll'><table><tr><th>Test</th><th>Metric</th><th>Value</th></tr>")
        for e in launch_metrics:
            unit = e.get("unit") or ""
            html.append(f"<tr><td>{e.get('test')}</td><td>{e.get('name')}</td><td>{e.get('value')} {unit}</td></tr>")
        html.append("</table></div>")
    else:
        html.append("<div class='muted'>(no launch metrics found)</div>")
    html.append("</div>")

    html.append("<div class='card'>")
    html.append("<h2>XCTest Metrics</h2>")
    if metrics:
        # Flatten numeric values for chart scaling
        numeric_values = []
        for test, entries in metrics.items():
            for e in entries:
                try:
                    numeric_values.append(float(e.get("value")))
                except Exception:
                    continue
        max_metric = max(numeric_values) if numeric_values else 1.0
        html.append("<div class='table-scroll'><table><tr><th>Test</th><th>Metric</th><th>Value</th><th>Chart</th></tr>")
        for test, entries in metrics.items():
            for e in entries:
                name = e.get("name")
                value = e.get("value")
                unit = e.get("unit") or ""
                try:
                    val_f = float(value)
                    pct = 0 if max_metric == 0 else int((val_f / max_metric) * 100)
                    chart = f"<div class='bar-wrap'><div class='bar' style='width:{pct}%'></div></div>"
                except Exception:
                    chart = ""
                html.append(f"<tr><td>{test}</td><td>{name}</td><td>{value} {unit}</td><td>{chart}</td></tr>")
        html.append("</table></div>")
    else:
        if payload.get("xcresult_error"):
            html.append(f"<div class='muted'>(xcresult unavailable: {payload.get('xcresult_error')})</div>")
        else:
            html.append("<div class='muted'>(no XCTest metrics found)</div>")
    html.append("</div>")

    html.append("<div class='card'>")
    html.append("<h2>Failures</h2>")
    if failures:
        html.append("<div class='table-scroll'><table><tr><th>Message</th><th>Location</th></tr>")
        for f in failures:
            loc = ""
            if f.get("file") and f.get("line"):
                loc = f"{f['file']}:{f['line']}"
            html.append(f"<tr><td>{f.get('message')}</td><td>{loc}</td></tr>")
        html.append("</table></div>")
    else:
        html.append("<div class='muted'>(none)</div>")
    html.append("</div>")

    html.append("<div class='card'>")
    html.append("<h2>Instruments Traces</h2>")
    if traces:
        html.append("<div class='table-scroll'><table><tr><th>Trace</th><th>Path</th><th>Status</th><th>Schema</th></tr>")
        for name, path_value in traces.items():
            info = trace_summaries.get(name) or {}
            schema = info.get("schema", "")
            health = info.get("health") or {}
            status = health.get("status") or ("ok" if not info.get("error") else "error")
            html.append(f"<tr><td>{name}</td><td>{path_value}</td><td>{status}</td><td>{schema}</td></tr>")
        html.append("</table></div>")
    else:
        html.append("<div class='muted'>(no traces were captured in this run)</div>")
    html.append("</div>")

    html.append("<div class='card'>")
    html.append("<h2>Instruments Summary</h2>")
    if trace_summaries:
        html.append("<div class='table-scroll'><table><tr><th>Trace</th><th>Metric</th><th>Avg</th><th>Max</th><th>Min</th></tr>")
        for trace_name, info in trace_summaries.items():
            summary = info.get("summary") or {}
            error = info.get("error")
            if not summary:
                message = "No numeric summary extracted"
                if error:
                    message = f"Export failed: {_html_escape(error)}"
                html.append(f"<tr><td>{trace_name}</td><td colspan='4'>{message}</td></tr>")
                continue
            for metric_name, stat in summary.items():
                html.append(f"<tr><td>{trace_name}</td><td>{metric_name}</td><td>{_fmt(stat.get('avg'))}</td><td>{_fmt(stat.get('max'))}</td><td>{_fmt(stat.get('min'))}</td></tr>")
        html.append("</table></div>")
        for trace_name, info in trace_summaries.items():
            health = info.get("health") or {}
            if not health:
                continue
            html.append(f"<div class='scenario-sub' style='margin-top:8px'><strong>{trace_name}</strong>: {_html_escape(health.get('message'))}")
            extras = []
            if health.get("template_type"):
                extras.append(f"template={health.get('template_type')}")
            if health.get("size_bytes") is not None:
                extras.append(f"size={health.get('size_bytes')} bytes")
            if health.get("file_count") is not None:
                extras.append(f"files={health.get('file_count')}")
            if extras:
                html.append(f" ({_html_escape(', '.join(extras))})")
            html.append("</div>")
    else:
        html.append("<div class='muted'>(no Instruments summary available for this run)</div>")
    html.append("</div>")
    html.append("</div>")

    html.append("<div class='footer'>JD with iHeart</div>")
    html.append("<div class='watermark'>JD with iHeart</div>")
    html.append("</div></body></html>")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(html))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--xcresult", required=True)
    parser.add_argument("--xcresult-dir", default="")
    parser.add_argument("--log", default="")
    parser.add_argument("--out", required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--csv", required=True)
    parser.add_argument("--txt", required=True)
    parser.add_argument("--skip-traces", action="store_true")
    args = parser.parse_args()

    payload = {
        "generated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "tested_app": _detect_tested_app(args.log),
        "custom_timing_runs": _parse_perf_lines(args.log),
        "custom_timings_summary": {},
        "custom_timings": {},
        "scenario_statuses": _parse_scenario_statuses(args.log),
        "selected_scenarios": _parse_selected_scenarios(args.log),
        "xc_metrics": {},
        "launch_metrics": [],
        "failures": [],
        "traces": {},
        "trace_summaries": {},
        "scenario_cards": [],
        "logo_path": None,
        "xcresults": _discover_xcresults(args.xcresult_dir),
    }
    payload["custom_timings_summary"] = _summarize_perf_entries(payload["custom_timing_runs"])
    payload["custom_timings"] = {
        metric: stats["mean"] for metric, stats in payload["custom_timings_summary"].items()
    }

    xcresult_path = args.xcresult
    if (not xcresult_path or not os.path.exists(xcresult_path)) and payload["xcresults"]:
        xcresult_path = payload["xcresults"][-1]
    payload["xcresult_path"] = xcresult_path

    xc, err = _load_xcresult(xcresult_path)
    if xc is None:
        payload["xcresult_error"] = err
        payload["failures"] = _parse_failures_from_log(args.log)
    else:
        metrics = {}
        _collect_metrics(xc, metrics)
        payload["xc_metrics"] = metrics
        payload["launch_metrics"] = _extract_launch_metrics(metrics)
        failures = []
        _collect_failures(xc, failures)
        payload["failures"] = [f for f in failures if f.get("message")]
        if not payload["launch_metrics"]:
            ref_id = _find_tests_ref_id(xc)
            tests_ref, ref_err = _load_tests_ref(xcresult_path, ref_id)
            if tests_ref and not ref_err:
                durations = {}
                _collect_test_durations(tests_ref, durations)
                payload["launch_metrics"] = _extract_launch_durations(durations)
                for entry in payload["launch_metrics"]:
                    label = _launch_label(entry.get("test", ""))
                    if label and label not in payload["custom_timings"]:
                        try:
                            payload["custom_timings"][label] = float(entry.get("value") or 0)
                            payload["custom_timings_summary"][label] = {
                                "mean": float(entry.get("value") or 0),
                                "min": float(entry.get("value") or 0),
                                "max": float(entry.get("value") or 0),
                                "count": 1,
                                "values": [float(entry.get("value") or 0)],
                                "iterations": [None],
                            }
                        except Exception:
                            pass

    # Add trace paths if present
    out_dir = os.path.dirname(args.out)
    run_context = _load_run_context(out_dir)
    payload["run_context"] = run_context
    process_name = (run_context.get("process_name") or "").strip() or None
    process_bundle_id = (run_context.get("bundle_id") or "").strip() or None
    if not args.skip_traces:
        traces_dir = os.path.join(out_dir, "traces")
        trace_manifest = _load_trace_manifest(traces_dir)
        discovered_traces = _discover_trace_bundles(traces_dir)

        def _trace_recorded_this_run(filename):
            return filename in trace_manifest or filename in discovered_traces

        activity_monitor_trace = os.path.join(traces_dir, "ActivityMonitor.trace")
        time_profiler_trace = os.path.join(traces_dir, "TimeProfiler.trace")
        allocations_trace = os.path.join(traces_dir, "Allocations.trace")
        energy_trace = os.path.join(traces_dir, "Energy.trace")
        leaks_trace = os.path.join(traces_dir, "Leaks.trace")
        network_trace = os.path.join(traces_dir, "Network.trace")
        if (os.path.exists(activity_monitor_trace) or _trace_sidecar_exists(traces_dir, "ActivityMonitor")) and (
            _trace_recorded_this_run("ActivityMonitor.trace") or _trace_sidecar_exists(traces_dir, "ActivityMonitor")
        ):
            activity_summary = _trace_summary(
                activity_monitor_trace,
                "activity",
                process_name=process_name,
                process_bundle_id=process_bundle_id,
            )
            if activity_summary:
                payload["traces"]["Activity Monitor"] = activity_monitor_trace
                payload["trace_summaries"]["Activity Monitor"] = activity_summary
        if (os.path.exists(time_profiler_trace) or _trace_sidecar_exists(traces_dir, "TimeProfiler")) and (
            _trace_recorded_this_run("TimeProfiler.trace") or _trace_sidecar_exists(traces_dir, "TimeProfiler")
        ):
            cpu_summary = _trace_summary(
                time_profiler_trace,
                "cpu",
                process_name=process_name,
                process_bundle_id=process_bundle_id,
            )
            if cpu_summary:
                payload["traces"]["Time Profiler"] = time_profiler_trace
                payload["trace_summaries"]["Time Profiler"] = cpu_summary
        if (os.path.exists(allocations_trace) or _trace_sidecar_exists(traces_dir, "Allocations")) and (
            _trace_recorded_this_run("Allocations.trace") or _trace_sidecar_exists(traces_dir, "Allocations")
        ):
            memory_summary = _trace_summary(
                allocations_trace,
                "memory",
                process_name=process_name,
                process_bundle_id=process_bundle_id,
            )
            if memory_summary:
                payload["traces"]["Allocations"] = allocations_trace
                payload["trace_summaries"]["Allocations"] = memory_summary
        if os.path.exists(energy_trace) and _trace_recorded_this_run("Energy.trace"):
            energy_summary = _trace_summary(
                energy_trace,
                "energy",
                process_name=process_name,
                process_bundle_id=process_bundle_id,
            )
            if energy_summary:
                payload["traces"]["Energy Log"] = energy_trace
                payload["trace_summaries"]["Energy Log"] = energy_summary
        if (os.path.exists(leaks_trace) or _trace_sidecar_exists(traces_dir, "Leaks")) and (
            _trace_recorded_this_run("Leaks.trace") or _trace_sidecar_exists(traces_dir, "Leaks")
        ):
            leaks_summary = _trace_summary(
                leaks_trace,
                "leaks",
                process_name=process_name,
                process_bundle_id=process_bundle_id,
            )
            if leaks_summary:
                payload["traces"]["Leaks"] = leaks_trace
                payload["trace_summaries"]["Leaks"] = leaks_summary
        if (os.path.exists(network_trace) or _trace_sidecar_exists(traces_dir, "Network")) and (
            _trace_recorded_this_run("Network.trace") or _trace_sidecar_exists(traces_dir, "Network")
        ):
            network_summary = _trace_summary(
                network_trace,
                "network",
                process_name=process_name,
                process_bundle_id=process_bundle_id,
            )
            if network_summary:
                payload["traces"]["Network"] = network_trace
                payload["trace_summaries"]["Network"] = network_summary

    payload["scenario_cards"] = _build_scenario_cards(
        payload["custom_timings_summary"],
        payload["trace_summaries"],
        payload.get("scenario_statuses"),
        payload.get("selected_scenarios"),
    )

    # Logo path (place logo at ../assets/performace_logo.png or .svg)
    project_root = os.path.dirname(out_dir)
    logo_png = os.path.join(project_root, "assets", "performace_logo.png")
    logo_svg = os.path.join(project_root, "assets", "performace_logo.svg")
    if os.path.exists(logo_png):
        payload["logo_path"] = "../assets/performace_logo.png"
    elif os.path.exists(logo_svg):
        payload["logo_path"] = "../assets/performace_logo.svg"

    _write_json(args.json, payload)
    _write_csv(args.csv, payload)
    _write_text(args.txt, payload)
    _write_html(args.out, payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
