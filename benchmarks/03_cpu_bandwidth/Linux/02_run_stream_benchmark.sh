#!/usr/bin/env bash
# Run STREAM and generate Linux CPU bandwidth benchmark reports.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

build_dir="$SCRIPT_DIR/build"
binary_path=""
output_root="$SCRIPT_DIR/runs"
threads_csv=""
repeat_count=1
omp_proc_bind="close"
omp_places="cores"
use_omp_affinity=1
numactl_args_text=""
quiet=0
dry_run=0

usage() {
    cat <<'USAGE'
Usage: ./02_run_stream_benchmark.sh [options]

Options:
  --binary PATH          STREAM executable. Default: newest executable under ./build
  --build-dir PATH       Build directory for auto binary discovery. Default: ./build
  --output-root PATH     Run output root. Default: ./runs
  --threads CSV          OMP thread counts. Default: 1,8,<logical CPU count>
  --repeat-count N       External launch repeats per thread count. Default: 1
  --omp-proc-bind VALUE  OMP_PROC_BIND value. Default: close
  --omp-places VALUE     OMP_PLACES value. Default: cores
  --no-omp-affinity      Do not set OMP_PROC_BIND or OMP_PLACES
  --numactl-args TEXT    Prefix run with numactl TEXT, for example "--interleave=all"
  --interleave-all       Shortcut for --numactl-args "--interleave=all"
  --quiet                Keep raw STREAM stdout in log files only
  --dry-run              Generate metadata and command files without executing STREAM
  -h, --help             Show this help
USAGE
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

have_command() {
    command -v "$1" >/dev/null 2>&1
}

real_path_m() {
    realpath -m "$1"
}

quote_cmd() {
    local out=()
    local arg
    for arg in "$@"; do
        out+=("$(printf '%q' "$arg")")
    done
    printf '%s' "${out[*]}"
}

safe_name() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

cpu_count() {
    getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || printf '1\n'
}

default_thread_counts() {
    local logical="$1"
    local candidates=(1 8 "$logical")
    local seen=" "
    local out=()
    local item
    for item in "${candidates[@]}"; do
        [[ "$item" =~ ^[0-9]+$ && "$item" -gt 0 && "$item" -le "$logical" ]] || continue
        if [[ "$seen" != *" $item "* ]]; then
            out+=("$item")
            seen+="$item "
        fi
    done
    local IFS=,
    printf '%s\n' "${out[*]}"
}

split_csv_ints() {
    local text="$1"
    local -n output_ref="$2"
    local item
    output_ref=()
    text="${text//,/ }"
    for item in $text; do
        [[ "$item" =~ ^[0-9]+$ && "$item" -gt 0 ]] || die "Invalid positive integer in CSV: $item"
        output_ref+=("$item")
    done
    (( ${#output_ref[@]} > 0 )) || die "CSV must not be empty"
}

find_latest_stream_binary() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    find "$dir" -maxdepth 1 -type f -name 'stream_*' -perm -u+x -printf '%T@\t%p\n' 2>/dev/null |
        sort -nr |
        awk -F '\t' 'NR==1 {print $2}'
}

capture_optional_command() {
    local output_path="$1"
    shift
    {
        printf '# %s\n' "$(quote_cmd "$@")"
        printf 'Generated: %s\n\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
        if command -v "$1" >/dev/null 2>&1; then
            "$@"
            printf '\nExitCode: %s\n' "$?"
        else
            printf 'Command not found: %s\n' "$1"
        fi
    } > "$output_path" 2>&1 || true
}

while (( $# > 0 )); do
    case "$1" in
        --binary) binary_path="${2:?Missing value for --binary}"; shift 2 ;;
        --binary=*) binary_path="${1#*=}"; shift ;;
        --build-dir) build_dir="${2:?Missing value for --build-dir}"; shift 2 ;;
        --build-dir=*) build_dir="${1#*=}"; shift ;;
        --output-root) output_root="${2:?Missing value for --output-root}"; shift 2 ;;
        --output-root=*) output_root="${1#*=}"; shift ;;
        --threads) threads_csv="${2:?Missing value for --threads}"; shift 2 ;;
        --threads=*) threads_csv="${1#*=}"; shift ;;
        --repeat-count) repeat_count="${2:?Missing value for --repeat-count}"; shift 2 ;;
        --repeat-count=*) repeat_count="${1#*=}"; shift ;;
        --omp-proc-bind) omp_proc_bind="${2:?Missing value for --omp-proc-bind}"; shift 2 ;;
        --omp-proc-bind=*) omp_proc_bind="${1#*=}"; shift ;;
        --omp-places) omp_places="${2:?Missing value for --omp-places}"; shift 2 ;;
        --omp-places=*) omp_places="${1#*=}"; shift ;;
        --no-omp-affinity) use_omp_affinity=0; shift ;;
        --numactl-args) numactl_args_text="${2:?Missing value for --numactl-args}"; shift 2 ;;
        --numactl-args=*) numactl_args_text="${1#*=}"; shift ;;
        --interleave-all) numactl_args_text="--interleave=all"; shift ;;
        --quiet) quiet=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

have_command python3 || die "python3 is required for report generation"
[[ "$repeat_count" =~ ^[0-9]+$ && "$repeat_count" -gt 0 ]] || die "--repeat-count must be a positive integer"

build_dir="$(real_path_m "$build_dir")"
if [[ -z "$binary_path" ]]; then
    binary_path="$(find_latest_stream_binary "$build_dir" || true)"
fi
[[ -n "$binary_path" ]] || die "No STREAM binary found. Run ./01_build_stream.sh first, or pass --binary."
binary_path="$(real_path_m "$binary_path")"
[[ -x "$binary_path" ]] || die "STREAM binary is not executable: $binary_path"

logical_cpus="$(cpu_count)"
if [[ -z "$threads_csv" ]]; then
    threads_csv="$(default_thread_counts "$logical_cpus")"
fi
threads=()
split_csv_ints "$threads_csv" threads

numactl_args=()
if [[ -n "$numactl_args_text" ]]; then
    have_command numactl || die "--numactl-args was provided, but numactl was not found"
    read -r -a numactl_args <<< "$numactl_args_text"
fi

mkdir -p "$output_root" "$SCRIPT_DIR/logs"
timestamp="$(date +%Y%m%d_%H%M%S)"
host_name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown_host\n')"
run_name="${timestamp}_$(safe_name "$host_name")_linux"
run_dir="$output_root/$run_name"
raw_dir="$run_dir/raw"
metadata_dir="$run_dir/metadata"
mkdir -p "$raw_dir" "$metadata_dir"

log_path="$SCRIPT_DIR/logs/${run_name}.log"
exec > >(tee -a "$log_path") 2>&1

commands_path="$run_dir/commands.sh"
summary_csv="$run_dir/summary_stream.csv"
grouped_csv="$run_dir/summary_stream_grouped.csv"
metadata_txt="$run_dir/metadata.txt"
metadata_json="$run_dir/metadata.json"
report_path="$run_dir/report.md"

{
    printf '#!/usr/bin/env bash\n'
    printf '# Commands for this STREAM benchmark run\n'
    printf '# Generated: %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
} > "$commands_path"

cpu_model="Unavailable"
if have_command lscpu; then
    cpu_model="$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -n 1)"
elif [[ -r /proc/cpuinfo ]]; then
    cpu_model="$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo | head -n 1)"
fi
[[ -n "$cpu_model" ]] || cpu_model="Unavailable"
os_kernel="$(uname -a 2>/dev/null || printf 'Unavailable\n')"
compiler_info="Unavailable"
if have_command gcc; then
    compiler_info="$(gcc --version 2>/dev/null | head -n 1 || true)"
fi

capture_optional_command "$metadata_dir/lscpu.txt" lscpu
capture_optional_command "$metadata_dir/free_h.txt" free -h
capture_optional_command "$metadata_dir/numactl_hardware.txt" numactl --hardware
capture_optional_command "$metadata_dir/uname.txt" uname -a
capture_optional_command "$metadata_dir/ldd_stream.txt" ldd "$binary_path"
if [[ -r /etc/os-release ]]; then
    cp /etc/os-release "$metadata_dir/os-release.txt"
fi

build_info_path=""
candidate_info="$(find "$(dirname "$binary_path")" -maxdepth 1 -type f -name "build_info_$(basename "$binary_path").json" -print -quit 2>/dev/null || true)"
if [[ -n "$candidate_info" ]]; then
    build_info_path="$candidate_info"
    cp "$candidate_info" "$run_dir/build_info.json"
fi

{
    printf 'STREAM Linux CPU bandwidth benchmark run\n'
    printf 'Generated: %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
    printf 'Host name: %s\n' "$host_name"
    printf 'CPU model: %s\n' "$cpu_model"
    printf 'OS/kernel: %s\n' "$os_kernel"
    printf 'Binary: %s\n' "$binary_path"
    printf 'Build info: %s\n' "${build_info_path:-Unavailable}"
    printf 'Compiler: %s\n' "$compiler_info"
    printf 'Thread counts: %s\n' "$(IFS=,; printf '%s' "${threads[*]}")"
    printf 'Repeat count: %s\n' "$repeat_count"
    printf 'OMP affinity: %s\n' "$use_omp_affinity"
    printf 'OMP_PROC_BIND: %s\n' "$omp_proc_bind"
    printf 'OMP_PLACES: %s\n' "$omp_places"
    printf 'numactl args: %s\n' "${numactl_args_text:-none}"
    printf 'Raw output path: %s\n' "$raw_dir"
    printf 'Summary CSV: %s\n' "$summary_csv"
} > "$metadata_txt"

python3 - "$metadata_json" "$metadata_txt" "$binary_path" "$build_info_path" "$logical_cpus" "$dry_run" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

output, metadata_txt, binary, build_info_path, logical_cpus, dry_run = sys.argv[1:]
payload = {
    "schema_version": 1,
    "generated_at": datetime.now(timezone.utc).astimezone().isoformat(),
    "metadata_txt": metadata_txt,
    "binary": binary,
    "logical_cpus": int(logical_cpus),
    "dry_run": bool(int(dry_run)),
}
if build_info_path:
    try:
        payload["build_info"] = json.loads(Path(build_info_path).read_text(encoding="utf-8"))
    except Exception as exc:
        payload["build_info_error"] = str(exc)
Path(output).write_text(json.dumps(payload, indent=2), encoding="utf-8")
PY

printf 'STREAM binary : %s\n' "$binary_path"
printf 'Thread sweep  : %s\n' "$(IFS=,; printf '%s' "${threads[*]}")"
printf 'Repeat count  : %s\n' "$repeat_count"
printf 'Run directory : %s\n' "$run_dir"
printf 'Log           : %s\n' "$log_path"
if [[ -n "$numactl_args_text" ]]; then
    printf 'numactl args  : %s\n' "$numactl_args_text"
fi

for threads_value in "${threads[@]}"; do
    for (( repeat=1; repeat<=repeat_count; repeat++ )); do
        repeat_id="$(printf '%02d' "$repeat")"
        raw_log="$raw_dir/stream_threads${threads_value}_r${repeat_id}.txt"
        env_args=("OMP_NUM_THREADS=$threads_value")
        if (( use_omp_affinity == 1 )); then
            env_args+=("OMP_PROC_BIND=$omp_proc_bind" "OMP_PLACES=$omp_places")
        fi
        command=(env "${env_args[@]}")
        if (( ${#numactl_args[@]} > 0 )); then
            command+=(numactl "${numactl_args[@]}")
        fi
        command+=("$binary_path")

        {
            printf '\n# STREAM threads=%s repeat=%s\n' "$threads_value" "$repeat"
            printf '%s\n' "$(quote_cmd "${command[@]}")"
        } >> "$commands_path"

        printf '\n==> STREAM threads=%s repeat=%s/%s\n%s\n' "$threads_value" "$repeat" "$repeat_count" "$(quote_cmd "${command[@]}")"
        {
            printf '# STREAM threads=%s repeat=%s\n' "$threads_value" "$repeat"
            printf 'Generated: %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
            printf 'Command: %s\n\n' "$(quote_cmd "${command[@]}")"
        } > "$raw_log"

        if (( dry_run == 1 )); then
            printf 'Dry run: command not executed.\n' >> "$raw_log"
            continue
        fi

        set +e
        if (( quiet == 1 )); then
            "${command[@]}" >> "$raw_log" 2>&1
            rc=$?
        else
            "${command[@]}" 2>&1 | tee -a "$raw_log"
            rc=${PIPESTATUS[0]}
        fi
        set -e
        printf '\nExitCode: %s\n' "$rc" >> "$raw_log"
        (( rc == 0 )) || die "STREAM failed with exit code $rc for threads=$threads_value repeat=$repeat"
    done
done

chmod +x "$commands_path" 2>/dev/null || true

python3 - "$run_dir" "$summary_csv" "$grouped_csv" "$report_path" <<'PY'
import csv
import json
import math
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

run_dir = Path(sys.argv[1])
summary_csv = Path(sys.argv[2])
grouped_csv = Path(sys.argv[3])
report_path = Path(sys.argv[4])
raw_dir = run_dir / "raw"

function_order = {"Copy": 0, "Scale": 1, "Add": 2, "Triad": 3}
row_re = re.compile(r"^(Copy|Scale|Add|Triad):\s+([0-9.]+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)")

metadata = {}
metadata_path = run_dir / "metadata.txt"
if metadata_path.exists():
    for line in metadata_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            metadata[key.strip()] = value.strip()

build_info = {}
build_info_path = run_dir / "build_info.json"
if build_info_path.exists():
    try:
        build_info = json.loads(build_info_path.read_text(encoding="utf-8"))
    except Exception:
        build_info = {}

def meta(key, default="Unavailable"):
    value = metadata.get(key, "").strip()
    return value if value else default

def parse_int_from(pattern, text):
    m = re.search(pattern, text)
    return int(m.group(1)) if m else ""

rows = []
for raw_path in sorted(raw_dir.glob("stream_threads*_r*.txt")):
    text = raw_path.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"stream_threads([0-9]+)_r([0-9]+)\.txt$", raw_path.name)
    threads = int(m.group(1)) if m else ""
    repeat = int(m.group(2)) if m else ""
    exit_match = re.search(r"ExitCode:\s*([0-9]+)", text)
    exit_code = int(exit_match.group(1)) if exit_match else ""
    validation = "valid" if "Solution Validates" in text else "unknown"
    array_size = parse_int_from(r"Array size\s*=\s*([0-9]+)", text)
    bytes_per_word = parse_int_from(r"This system uses\s*([0-9]+)\s*bytes per array element", text)
    total_memory_mib = ""
    mm = re.search(r"Total memory required\s*=\s*([0-9.]+)\s*MiB", text)
    if mm:
        total_memory_mib = float(mm.group(1))
    for line in text.splitlines():
        match = row_re.match(line.strip())
        if not match:
            continue
        function, mb_s, avg_time, min_time, max_time = match.groups()
        mb_s_f = float(mb_s)
        rows.append({
            "threads": threads,
            "repeat": repeat,
            "function": function,
            "best_rate_MB_s": f"{mb_s_f:.4f}",
            "best_rate_GB_s": f"{mb_s_f / 1000.0:.4f}",
            "avg_time_s": avg_time,
            "min_time_s": min_time,
            "max_time_s": max_time,
            "validation": validation,
            "exit_code": exit_code,
            "array_size": array_size,
            "bytes_per_word": bytes_per_word,
            "total_memory_MiB": total_memory_mib,
            "raw_log": str(raw_path),
        })

summary_fields = [
    "threads",
    "repeat",
    "function",
    "best_rate_MB_s",
    "best_rate_GB_s",
    "avg_time_s",
    "min_time_s",
    "max_time_s",
    "validation",
    "exit_code",
    "array_size",
    "bytes_per_word",
    "total_memory_MiB",
    "raw_log",
]
with summary_csv.open("w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=summary_fields)
    writer.writeheader()
    writer.writerows(rows)

groups = defaultdict(list)
for row in rows:
    groups[(row["threads"], row["function"])].append(row)

grouped_rows = []
for (threads, function), group in sorted(groups.items(), key=lambda item: (int(item[0][0]), function_order.get(item[0][1], 99))):
    rates = [float(row["best_rate_MB_s"]) for row in group]
    min_times = [float(row["min_time_s"]) for row in group]
    best = max(group, key=lambda row: float(row["best_rate_MB_s"]))
    grouped_rows.append({
        "threads": threads,
        "function": function,
        "launches": len(group),
        "avg_best_rate_MB_s": f"{statistics.fmean(rates):.4f}",
        "best_rate_MB_s": f"{max(rates):.4f}",
        "avg_best_rate_GB_s": f"{statistics.fmean(rates) / 1000.0:.4f}",
        "best_rate_GB_s": f"{max(rates) / 1000.0:.4f}",
        "best_min_time_s": f"{min(min_times):.6f}",
        "validation": best["validation"],
        "array_size": best["array_size"],
        "bytes_per_word": best["bytes_per_word"],
        "total_memory_MiB": best["total_memory_MiB"],
        "best_raw_log": best["raw_log"],
    })

grouped_fields = [
    "threads",
    "function",
    "launches",
    "avg_best_rate_MB_s",
    "best_rate_MB_s",
    "avg_best_rate_GB_s",
    "best_rate_GB_s",
    "best_min_time_s",
    "validation",
    "array_size",
    "bytes_per_word",
    "total_memory_MiB",
    "best_raw_log",
]
with grouped_csv.open("w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=grouped_fields)
    writer.writeheader()
    writer.writerows(grouped_rows)

def table(headers, table_rows):
    lines = ["| " + " | ".join(headers) + " |", "| " + " | ".join(["---"] * len(headers)) + " |"]
    for row in table_rows:
        escaped = [str(cell).replace("|", "/").replace("\n", "<br>") for cell in row]
        lines.append("| " + " | ".join(escaped) + " |")
    return lines

best_by_function = {}
for row in grouped_rows:
    function = row["function"]
    if function not in best_by_function or float(row["best_rate_MB_s"]) > float(best_by_function[function]["best_rate_MB_s"]):
        best_by_function[function] = row

lines = [
    "# STREAM CPU Bandwidth Benchmark Report",
    "",
    f"Generated: {meta('Generated')}",
    f"Host: {meta('Host name')}",
    f"Run directory: {run_dir}",
    "",
    "## Metadata",
    "",
]
lines.extend(table(["field", "value"], [
    ["CPU model", meta("CPU model")],
    ["OS/kernel", meta("OS/kernel")],
    ["Binary", meta("Binary")],
    ["Compiler", build_info.get("compiler", meta("Compiler"))],
    ["STREAM_ARRAY_SIZE", build_info.get("stream_array_size", "Unavailable")],
    ["NTIMES", build_info.get("ntimes", "Unavailable")],
    ["STREAM_TYPE", build_info.get("stream_type", "Unavailable")],
    ["Build info", meta("Build info")],
    ["Thread counts", meta("Thread counts")],
    ["Repeat count", meta("Repeat count")],
    ["OMP affinity", meta("OMP affinity")],
    ["OMP_PROC_BIND", meta("OMP_PROC_BIND")],
    ["OMP_PLACES", meta("OMP_PLACES")],
    ["numactl args", meta("numactl args")],
    ["Raw output path", meta("Raw output path")],
    ["Summary CSV", summary_csv],
]))
lines.append("")

if grouped_rows:
    lines.extend([
        "## Result Summary",
        "",
    ])
    lines.extend(table(
        ["threads", "function", "launches", "avg GB/s", "best GB/s", "best MB/s", "best min time s", "validation"],
        [
            [
                row["threads"],
                row["function"],
                row["launches"],
                row["avg_best_rate_GB_s"],
                row["best_rate_GB_s"],
                row["best_rate_MB_s"],
                row["best_min_time_s"],
                row["validation"],
            ]
            for row in grouped_rows
        ],
    ))
    lines.append("")
    lines.extend([
        "## Best By Function",
        "",
    ])
    lines.extend(table(
        ["function", "threads", "best GB/s", "best MB/s", "array size", "memory MiB"],
        [
            [
                best_by_function[function]["function"],
                best_by_function[function]["threads"],
                best_by_function[function]["best_rate_GB_s"],
                best_by_function[function]["best_rate_MB_s"],
                best_by_function[function]["array_size"],
                best_by_function[function]["total_memory_MiB"],
            ]
            for function in sorted(best_by_function, key=lambda name: function_order.get(name, 99))
        ],
    ))
else:
    lines.extend(["## Result Summary", "", "No STREAM result rows were generated. This is expected in dry-run mode."])
lines.append("")

lines.extend([
    "## Output Files",
    "",
])
output_rows = [
    ["summary_stream.csv", "raw parsed rows for each STREAM launch and kernel"],
    ["summary_stream_grouped.csv", "grouped average/best rows by thread count and STREAM function"],
    ["metadata.txt", "human-readable run metadata"],
    ["metadata.json", "machine-readable run metadata"],
    ["commands.sh", "exact commands used for this run"],
    ["raw/", "raw STREAM stdout logs"],
    ["metadata/", "Linux system metadata from lscpu, free, numactl, uname, ldd"],
]
if (run_dir / "build_info.json").exists():
    output_rows.append(["build_info.json", "copied build configuration for the STREAM binary"])
lines.extend(table(["file", "description"], output_rows))
lines.append("")
lines.extend([
    "Notes:",
    "",
    "- STREAM reports bandwidth in MB/s using the STREAM byte-counting convention.",
    "- GB/s in this report is decimal MB/s divided by 1000.",
    "- Copy and Scale count two arrays of traffic; Add and Triad count three arrays of traffic.",
])

report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(report_path)
PY

printf '\nDone.\n'
printf 'Run directory : %s\n' "$run_dir"
printf 'Summary CSV   : %s\n' "$summary_csv"
printf 'Grouped CSV   : %s\n' "$grouped_csv"
printf 'Report        : %s\n' "$report_path"
