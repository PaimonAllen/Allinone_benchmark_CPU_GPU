#!/usr/bin/env bash
# Run local CUTLASS 4.5.1 GEMM benchmarks on Linux.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SOURCE_DIR="$SCRIPT_DIR/cutlass-4.5.1"
DEFAULT_BUILD_DIR="$DEFAULT_SOURCE_DIR/build"

profiler_exe=""
source_dir="$DEFAULT_SOURCE_DIR"
build_dir=""
config="Release"
output_root="$SCRIPT_DIR/runs"
sizes_csv="1024,2048,4096"
repeat_count=3
profiling_iterations=50
warmup_iterations=10
precisions_csv="auto"
dry_run=0
allow_failures=0
quiet=0
extra_profiler_args=()

usage() {
    cat <<'USAGE'
Usage: ./02_run_cutlass_4_5_1_benchmark.sh [options]

Options:
  --profiler-exe PATH         Explicit cutlass_profiler executable
  --source-dir PATH           CUTLASS source directory. Default: ./cutlass-4.5.1
  --build-dir PATH            CMake build directory. Default: ./cutlass-4.5.1/build
  --config NAME               Multi-config build config fallback. Default: Release
  --output-root PATH          Run output root. Default: ./runs
  --sizes LIST                Comma-separated square GEMM sizes. Default: 1024,2048,4096
  --repeat-count N            Repeats per case. Default: 3
  --profiling-iterations N    CUTLASS profiling iterations. Default: 50
  --warmup-iterations N       CUTLASS warmup iterations. Default: 10
  --precisions LIST           auto, all, fp4, fp8, fp16, fp32, tf32, fp64,
                              or comma-separated list. Default: auto
  --dry-run                   Use CUTLASS --mode=dry_run
  --allow-failures            Continue when a profiler command fails
  --quiet                     Keep profiler stdout in log files only
  --extra-profiler-arg ARG    Extra cutlass_profiler argument. May be repeated
  -h, --help                  Show this help

Any arguments after -- are passed through to cutlass_profiler.
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

split_csv() {
    local text="$1"
    local -n output_ref="$2"
    local item
    output_ref=()
    text="${text//,/ }"
    for item in $text; do
        [[ -n "$item" ]] && output_ref+=("$item")
    done
}

to_upper() {
    local value="$1"
    printf '%s\n' "${value^^}"
}

detect_first_compute_cap() {
    local cap
    if have_command nvidia-smi; then
        cap="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits 2>/dev/null | head -n 1 || true)"
        cap="${cap//[[:space:]]/}"
        [[ -n "$cap" ]] && printf '%s\n' "$cap" && return
    fi
    printf '\n'
}

compute_cap_supports_tf32() {
    local cap="$1"
    local major="${cap%%.*}"
    major="${major//[^0-9]/}"
    [[ -n "$major" ]] && (( major >= 8 ))
}

compute_cap_number() {
    local cap="$1"
    cap="${cap//[[:space:]]/}"

    if [[ "$cap" =~ ^([0-9]+)\.([0-9]+) ]]; then
        printf '%s\n' "$((10#${BASH_REMATCH[1]} * 10 + 10#${BASH_REMATCH[2]}))"
        return
    fi

    if [[ "$cap" =~ ([0-9]{2,3}) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf '0\n'
    fi
}

compute_cap_at_least() {
    local cap_number
    cap_number="$(compute_cap_number "$1")"
    [[ "$cap_number" =~ ^[0-9]+$ ]] && (( cap_number >= "$2" ))
}

resolve_precisions() {
    local requested="$1"
    local requested_upper
    requested_upper="$(to_upper "$requested")"

    local requested_items=()
    if [[ "$requested_upper" == "AUTO" || "$requested_upper" == "ALL" ]]; then
        requested_items=(FP4 FP8 FP16 FP32 TF32 FP64)
    else
        split_csv "$requested" requested_items
    fi

    local item item_upper precision
    local seen=()
    for item in "${requested_items[@]}"; do
        item_upper="$(to_upper "$item")"
        case "$item_upper" in
            FP4|F4) precision="FP4" ;;
            FP8|F8) precision="FP8" ;;
            FP16|F16|HALF) precision="FP16" ;;
            FP32|F32|SINGLE) precision="FP32" ;;
            TF32) precision="TF32" ;;
            FP64|F64|DOUBLE) precision="FP64" ;;
            *) die "Unsupported precision: $item" ;;
        esac

        if [[ " ${seen[*]} " != *" $precision "* ]]; then
            printf '%s\n' "$precision"
            seen+=("$precision")
        fi
    done
}

fp16_kernel_filter() {
    local cap_number="$1"
    if (( cap_number >= 70 && cap_number < 75 )); then
        printf 'h884gemm\n'
        return
    fi
    printf 'h1688gemm\n'
}

operation_csv_suffix() {
    local operation="$1"
    case "$operation" in
        Gemm|gemm) printf 'gemm\n' ;;
        block_scaled_gemm|blockScaledGemm|BlockScaledGemm) printf 'block_scaled_gemm\n' ;;
        blockwise_gemm|blockwiseGemm|BlockwiseGemm) printf 'blockwise_gemm\n' ;;
        *) printf '%s\n' "${operation,,}" ;;
    esac
}

add_case() {
    cases_name+=("$1")
    cases_precision+=("$2")
    cases_path+=("$3")
    cases_operation+=("$4")
    cases_kernel+=("$5")
    cases_a+=("$6")
    cases_b+=("$7")
    cases_c+=("$8")
    cases_d+=("$9")
    cases_accumulator+=("${10}")
    cases_runtime_a+=("${11:-}")
    cases_runtime_b+=("${12:-}")
}

add_skip() {
    skipped_precision+=("$1")
    skipped_path+=("$2")
    skipped_reason+=("$3")
}

build_benchmark_cases() {
    local cap="$1"
    local cap_number precision
    cap_number="$(compute_cap_number "$cap")"

    for precision in "${precisions[@]}"; do
        case "$precision" in
            FP4)
                if (( cap_number >= 100 )); then
                    add_case "fp4_tensorop" "FP4" "TensorCore" "block_scaled_gemm" "f4,e2m1,ue4m3xf4" \
                        "f4:column" "f4:column" "f32:column" "f32:column" "f32" "e2m1" "e2m1"
                else
                    add_skip "FP4" "TensorCore" "requires Blackwell SM100+ block-scaled Tensor Core support; detected SM${cap_number}"
                fi
                ;;
            FP8)
                if (( cap_number >= 89 )); then
                    add_case "fp8_tensorop" "FP8" "TensorCore" "Gemm" "f8,e4m3,e5m2" \
                        "fe4m3:column" "fe4m3:column" "f32:column" "f32:column" "f32"
                else
                    add_skip "FP8" "TensorCore" "requires Ada/Hopper-class SM89+ FP8 Tensor Core support; detected SM${cap_number}"
                fi
                ;;
            FP16)
                if (( cap_number >= 70 )); then
                    add_case "fp16_tensorop" "FP16" "TensorCore" "Gemm" "$(fp16_kernel_filter "$cap_number")" \
                        "f16:column" "f16:column" "f16:column" "f16:column" "f16"
                else
                    add_skip "FP16" "TensorCore" "requires SM70+ Tensor Core support; detected SM${cap_number}"
                fi
                ;;
            FP32)
                add_case "fp32_sgemm" "FP32" "CUDACore" "Gemm" "sgemm" \
                    "f32:column" "f32:column" "f32:column" "f32:column" "f32"
                ;;
            TF32)
                if compute_cap_at_least "$cap" 80; then
                    add_case "tf32_tensorop" "TF32" "TensorCore" "Gemm" "tf32gemm" \
                        "f32:column" "f32:column" "f32:column" "f32:column" "f32"
                else
                    add_skip "TF32" "TensorCore" "requires Ampere SM80+ TF32 Tensor Core support; detected SM${cap_number}"
                fi
                ;;
            FP64)
                add_case "fp64_dgemm" "FP64" "CUDACore" "Gemm" "dgemm" \
                    "f64:column" "f64:column" "f64:column" "f64:column" "f64"
                if compute_cap_at_least "$cap" 80; then
                    add_case "fp64_tensorop" "FP64" "TensorCore" "Gemm" "d884gemm" \
                        "f64:column" "f64:column" "f64:column" "f64:column" "f64"
                else
                    add_skip "FP64" "TensorCore" "requires SM80+ FP64 Tensor Core support; detected SM${cap_number}"
                fi
                ;;
            *)
                die "Unsupported precision: $precision"
                ;;
        esac
    done
}

find_upward_file() {
    local start="$1"
    local marker="$2"
    local dir
    dir="$(real_path_m "$start")"
    while [[ "$dir" != "/" ]]; do
        if [[ -e "$dir/$marker" ]]; then
            printf '%s\n' "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

find_profiler_in_build() {
    local candidate_build_dir="$1"
    local candidate
    candidate_build_dir="$(real_path_m "$candidate_build_dir")"

    for candidate in \
        "$candidate_build_dir/tools/profiler/cutlass_profiler" \
        "$candidate_build_dir/tools/profiler/$config/cutlass_profiler" \
        "$candidate_build_dir/bin/cutlass_profiler"
    do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    if [[ -d "$candidate_build_dir" ]]; then
        candidate="$(find "$candidate_build_dir" -type f -name cutlass_profiler -perm -u+x 2>/dev/null | head -n 1 || true)"
        if [[ -n "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi

    return 1
}

resolve_cutlass_profiler() {
    local candidates=()
    local checked=()
    local exe build_root candidate

    if [[ -n "$profiler_exe" ]]; then
        [[ -x "$profiler_exe" ]] || die "cutlass_profiler is not executable: $profiler_exe"
        exe="$(real_path_m "$profiler_exe")"
        build_root="$(find_upward_file "$(dirname "$exe")" CMakeCache.txt || true)"
        [[ -n "$build_root" ]] || build_root="$(dirname "$(dirname "$(dirname "$exe")")")"
        printf '%s\t%s\n' "$exe" "$build_root"
        return
    fi

    if [[ -n "$build_dir" ]]; then
        candidates+=("$build_dir")
    else
        if [[ "$(real_path_m "$source_dir")" != "$(real_path_m "$DEFAULT_SOURCE_DIR")" ]]; then
            candidates+=("$source_dir/build")
        fi
        candidates+=("$DEFAULT_BUILD_DIR")
        candidates+=("${TMPDIR:-/tmp}/cutlass_build/cutlass_4_5_1")
        candidates+=("$SCRIPT_DIR/build")
    fi

    for candidate in "${candidates[@]}"; do
        candidate="$(real_path_m "$candidate")"
        checked+=("$candidate/tools/profiler/cutlass_profiler")
        checked+=("$candidate/tools/profiler/$config/cutlass_profiler")
        checked+=("$candidate/bin/cutlass_profiler")
        if exe="$(find_profiler_in_build "$candidate")"; then
            printf '%s\t%s\n' "$(real_path_m "$exe")" "$candidate"
            return
        fi
    done

    printf 'Checked:\n' >&2
    printf '  %s\n' "${checked[@]}" >&2
    die "cutlass_profiler not found. Build first with ./01_build_cutlass_4_5_1.sh, or pass --build-dir / --profiler-exe."
}

invoke_captured_command() {
    local title="$1"
    local exe="$2"
    local working_dir="$3"
    local log_file="$4"
    local allow_failure="$5"
    shift 5
    local args=("$@")
    local cmd_text rc
    cmd_text="$(quote_cmd "$exe" "${args[@]}")"

    {
        printf '# %s\n' "$title"
        printf 'Generated: %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
        printf 'WorkingDirectory: %s\n' "$working_dir"
        printf 'Command: %s\n\n' "$cmd_text"
    } > "$log_file"
    printf '%s\n' "$cmd_text" >> "$COMMANDS_FILE"

    printf '\n==> %s\n%s\n' "$title" "$cmd_text"

    pushd "$working_dir" >/dev/null
    set +e
    if (( quiet == 1 )); then
        "$exe" "${args[@]}" >> "$log_file" 2>&1
        rc=$?
    else
        "$exe" "${args[@]}" 2>&1 | tee -a "$log_file"
        rc=${PIPESTATUS[0]}
    fi
    set -e
    popd >/dev/null

    printf '\nExitCode: %s\n' "$rc" >> "$log_file"
    if (( rc != 0 && allow_failure == 0 )); then
        die "Command failed with exit code $rc: $cmd_text"
    fi
}

save_optional_command() {
    local name="$1"
    local file_name="$2"
    shift 2
    local log_file="$metadata_dir/$file_name"
    local command_path
    command_path="$(command -v "$name" 2>/dev/null || true)"

    if [[ -z "$command_path" ]]; then
        printf 'Command not found: %s\n' "$name" > "$log_file"
        return
    fi

    invoke_captured_command "$name $*" "$command_path" "$run_dir" "$log_file" 1 "$@"
}

save_nvidia_smi_query() {
    local log_file="$metadata_dir/nvidia-smi_query.csv"
    local command_path
    command_path="$(command -v nvidia-smi 2>/dev/null || true)"
    if [[ -z "$command_path" ]]; then
        printf 'Command not found: nvidia-smi\n' > "$log_file"
        return
    fi
    invoke_captured_command \
        "nvidia-smi query" \
        "$command_path" \
        "$run_dir" \
        "$log_file" \
        1 \
        --query-gpu=name,driver_version,memory.total,compute_cap,pci.bus_id,pcie.link.gen.current,pcie.link.width.current,power.limit \
        --format=csv
}

append_csv_to_summary() {
    local csv_path="$1"
    local summary_path="$2"
    [[ -s "$csv_path" ]] || return

    if [[ ! -e "$summary_path" ]]; then
        head -n 1 "$csv_path" > "$summary_path"
    fi

    tail -n +2 "$csv_path" >> "$summary_path"
}

generate_report() {
    local run_directory="$1"
    local summary_path="$2"
    python3 - "$run_directory" "$summary_path" <<'PY'
import csv
import math
import re
import sys
from collections import defaultdict
from pathlib import Path

run_dir = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
report_path = run_dir / "report.md"
skipped_path = run_dir / "unsupported_cases.tsv"

metadata = {}
metadata_path = run_dir / "metadata.txt"
if metadata_path.exists():
    for line in metadata_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            metadata[key.strip()] = value.strip()

def meta(key, default="Unavailable"):
    value = metadata.get(key, "").strip()
    return value if value else default

gpu_name = "Unavailable"
driver_version = "Unavailable"
cuda_driver_version = "Unavailable"
query_path = run_dir / "metadata" / "nvidia-smi_query.csv"
if query_path.exists():
    try:
        with query_path.open(newline="", encoding="utf-8", errors="replace") as f:
            lines = [line for line in f if not line.startswith("#") and not line.startswith("Generated:") and not line.startswith("WorkingDirectory:") and not line.startswith("Command:") and not line.startswith("ExitCode:") and line.strip()]
        rows = list(csv.DictReader(lines))
        if rows:
            row = rows[0]
            gpu_name = row.get("name", gpu_name).strip() or gpu_name
            driver_version = row.get("driver_version", driver_version).strip() or driver_version
    except Exception:
        pass

nvidia_smi_path = run_dir / "metadata" / "nvidia-smi.txt"
if nvidia_smi_path.exists():
    text = nvidia_smi_path.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"Driver Version:\s*([^\s|]+)\s+CUDA Version:\s*([^\s|]+)", text)
    if m:
        driver_version = m.group(1)
        cuda_driver_version = m.group(2)

device_info_path = run_dir / "metadata" / "cutlass_device_info.txt"
if gpu_name == "Unavailable" and device_info_path.exists():
    for line in device_info_path.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if stripped.startswith("NVIDIA"):
            gpu_name = stripped.split(",", 1)[0].strip()
            break

cuda_toolkit_version = "Unavailable"
nvcc_path = run_dir / "metadata" / "nvcc_version.txt"
if nvcc_path.exists():
    text = nvcc_path.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"release\s+([^,\s]+)", text)
    if m:
        cuda_toolkit_version = m.group(1)

skipped_rows = []
if skipped_path.exists():
    try:
        with skipped_path.open(newline="", encoding="utf-8", errors="replace") as f:
            skipped_rows = list(csv.DictReader(f, delimiter="\t"))
    except Exception:
        skipped_rows = []

lines = [
    "# CUTLASS 4.5.1 GPU Float Benchmark Report",
    "",
    f"Generated: {meta('Generated')}",
    "",
    "## Metadata",
    "",
    "| field | value |",
    "|---|---|",
    f"| Host name | {meta('Host name')} |",
    f"| CPU model | {meta('CPU model')} |",
    f"| GPU model | {gpu_name} |",
    f"| Driver version | {driver_version} |",
    f"| CUDA driver version | {cuda_driver_version} |",
    f"| CUDA toolkit version | {cuda_toolkit_version} |",
    f"| OS/kernel | {meta('OS/kernel')} |",
    f"| Compiler | nvcc {cuda_toolkit_version} |",
    f"| Mode | {meta('Mode')} |",
    f"| Matrix sizes | {meta('Sizes')} |",
    f"| Repeat count | {meta('Repeat count')} |",
    f"| Warmup iterations | {meta('Warmup iterations')} |",
    f"| Profiling iterations | {meta('Profiling iterations')} |",
    f"| Raw output path | {run_dir} |",
    f"| Summary CSV | {summary_path} |",
    f"| Command lines | {run_dir / 'commands.sh'} |",
    "",
]

if skipped_rows:
    lines.extend([
        "## Skipped / Unsupported",
        "",
        "| precision | path | reason |",
        "|---|---|---|",
    ])
    for row in skipped_rows:
        precision = (row.get("precision") or "").replace("|", "/")
        compute_path = (row.get("path") or "").replace("|", "/")
        reason = (row.get("reason") or "").replace("|", "/")
        lines.append(f"| {precision} | {compute_path} | {reason} |")
    lines.append("")

lines.extend([
    "## Results",
    "",
])

if not summary_path.exists():
    lines.append("No summary CSV was generated.")
    report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(report_path)
    sys.exit(0)

def as_float(value):
    try:
        if value is None or str(value).strip() == "":
            return None
        number = float(value)
        if math.isnan(number):
            return None
        return number
    except ValueError:
        return None

valid_rows = []
with summary_path.open(newline="", encoding="utf-8", errors="replace") as f:
    for row in csv.DictReader(f):
        status = (row.get("Status") or "").strip().lower()
        gflops = as_float(row.get("GFLOPs"))
        runtime_ms = as_float(row.get("Runtime"))
        if status == "success" and gflops is not None and gflops > 0 and runtime_ms is not None:
            precision = row.get("precision") or "unknown"
            compute_path = row.get("path") or "unknown"
            m = row.get("m") or row.get("problem-size::m") or "0"
            n = row.get("n") or row.get("problem-size::n") or "0"
            k = row.get("k") or row.get("problem-size::k") or "0"
            repeat = row.get("repeat") or "1"
            valid_rows.append({
                "precision": precision,
                "path": compute_path,
                "m": m,
                "n": n,
                "k": k,
                "repeat": repeat,
                "operation": row.get("Operation") or "",
                "runtime": runtime_ms,
                "gflops": gflops,
            })

if not valid_rows:
    lines.append("No profiled rows with non-zero GFLOPs were found. This is expected in dry-run mode.")
    report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(report_path)
    sys.exit(0)

per_repeat = {}
for row in valid_rows:
    key = (row["precision"], row["path"], row["m"], row["n"], row["k"], row["repeat"])
    if key not in per_repeat or row["gflops"] > per_repeat[key]["gflops"]:
        per_repeat[key] = row

groups = defaultdict(list)
for row in per_repeat.values():
    key = (row["precision"], row["path"], row["m"], row["n"], row["k"])
    groups[key].append(row)

lines.append("| precision | path | M | N | K | repeats | avg best GFLOPs | best GFLOPs | best runtime ms | best kernel |")
lines.append("|---|---|---:|---:|---:|---:|---:|---:|---:|---|")

def sort_key(item):
    precision, path, m, n, k = item[0]
    def int_or_text(value):
        try:
            return int(value)
        except ValueError:
            return value
    return (precision, path, int_or_text(m), int_or_text(n), int_or_text(k))

for key, rows in sorted(groups.items(), key=sort_key):
    best = max(rows, key=lambda r: r["gflops"])
    avg = sum(r["gflops"] for r in rows) / len(rows)
    repeats = len({r["repeat"] for r in rows})
    operation = best["operation"].replace("|", "/")
    precision, compute_path, m, n, k = key
    lines.append(
        f"| {precision} | {compute_path} | {m} | {n} | {k} | {repeats} | "
        f"{avg:.2f} | {best['gflops']:.2f} | {best['runtime']:.4f} | `{operation}` |"
    )

lines.extend([
    "",
    "Notes:",
    "",
    "- Each row first picks the fastest kernel within each repeat, then reports the average and maximum of those repeat-best values.",
    "- Runtime is the CUTLASS profiler `Runtime` column, reported here as milliseconds.",
    "- Verification is disabled for throughput measurement; raw logs and CSV files are kept next to this report.",
])

report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(report_path)
PY
}

while (( $# > 0 )); do
    case "$1" in
        --profiler-exe) profiler_exe="${2:?Missing value for --profiler-exe}"; shift 2 ;;
        --profiler-exe=*) profiler_exe="${1#*=}"; shift ;;
        --source-dir) source_dir="${2:?Missing value for --source-dir}"; shift 2 ;;
        --source-dir=*) source_dir="${1#*=}"; shift ;;
        --build-dir) build_dir="${2:?Missing value for --build-dir}"; shift 2 ;;
        --build-dir=*) build_dir="${1#*=}"; shift ;;
        --config) config="${2:?Missing value for --config}"; shift 2 ;;
        --config=*) config="${1#*=}"; shift ;;
        --output-root) output_root="${2:?Missing value for --output-root}"; shift 2 ;;
        --output-root=*) output_root="${1#*=}"; shift ;;
        --sizes) sizes_csv="${2:?Missing value for --sizes}"; shift 2 ;;
        --sizes=*) sizes_csv="${1#*=}"; shift ;;
        --repeat-count) repeat_count="${2:?Missing value for --repeat-count}"; shift 2 ;;
        --repeat-count=*) repeat_count="${1#*=}"; shift ;;
        --profiling-iterations) profiling_iterations="${2:?Missing value for --profiling-iterations}"; shift 2 ;;
        --profiling-iterations=*) profiling_iterations="${1#*=}"; shift ;;
        --warmup-iterations) warmup_iterations="${2:?Missing value for --warmup-iterations}"; shift 2 ;;
        --warmup-iterations=*) warmup_iterations="${1#*=}"; shift ;;
        --precisions) precisions_csv="${2:?Missing value for --precisions}"; shift 2 ;;
        --precisions=*) precisions_csv="${1#*=}"; shift ;;
        --dry-run) dry_run=1; shift ;;
        --allow-failures) allow_failures=1; shift ;;
        --quiet) quiet=1; shift ;;
        --extra-profiler-arg) extra_profiler_args+=("${2:?Missing value for --extra-profiler-arg}"); shift 2 ;;
        --extra-profiler-arg=*) extra_profiler_args+=("${1#*=}"); shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; extra_profiler_args+=("$@"); break ;;
        *) die "Unknown argument: $1" ;;
    esac
done

have_command python3 || die "Required command not found in PATH: python3"

sizes=()
split_csv "$sizes_csv" sizes
(( ${#sizes[@]} > 0 )) || die "At least one matrix size is required"
for size in "${sizes[@]}"; do
    [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]] || die "Matrix sizes must be positive integers. Invalid size: $size"
done
[[ "$repeat_count" =~ ^[0-9]+$ && "$repeat_count" -gt 0 ]] || die "--repeat-count must be a positive integer: $repeat_count"
[[ "$profiling_iterations" =~ ^[0-9]+$ ]] || die "--profiling-iterations must be zero or positive: $profiling_iterations"
[[ "$warmup_iterations" =~ ^[0-9]+$ ]] || die "--warmup-iterations must be zero or positive: $warmup_iterations"

mapfile -t precisions < <(resolve_precisions "$precisions_csv")
(( ${#precisions[@]} > 0 )) || die "No precision tokens selected"

cases_name=()
cases_precision=()
cases_path=()
cases_kernel=()
cases_operation=()
cases_a=()
cases_b=()
cases_c=()
cases_d=()
cases_accumulator=()
cases_runtime_a=()
cases_runtime_b=()
skipped_precision=()
skipped_path=()
skipped_reason=()

detected_compute_cap="$(detect_first_compute_cap)"
if [[ -z "$detected_compute_cap" ]]; then
    detected_compute_cap="0"
fi
build_benchmark_cases "$detected_compute_cap"

if (( ${#cases_name[@]} == 0 && ${#skipped_precision[@]} == 0 )); then
    die "No benchmark cases selected"
fi

resolved_profiler="$(resolve_cutlass_profiler)"
profiler_path="${resolved_profiler%%$'\t'*}"
profiler_build_dir="${resolved_profiler#*$'\t'}"
profiler_dir="$(dirname "$profiler_path")"

library_dir="$profiler_build_dir/tools/library"
if [[ -d "$library_dir" ]]; then
    export LD_LIBRARY_PATH="$profiler_dir:$library_dir:${LD_LIBRARY_PATH:-}"
else
    export LD_LIBRARY_PATH="$profiler_dir:${LD_LIBRARY_PATH:-}"
fi

timestamp="$(date +%Y%m%d_%H%M%S)"
host_name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown_host\n')"
safe_host_name="${host_name//[^A-Za-z0-9_.-]/_}"
run_dir="$output_root/${timestamp}_${safe_host_name}_linux"
raw_dir="$run_dir/raw"
csv_dir="$run_dir/csv"
metadata_dir="$run_dir/metadata"
mkdir -p "$raw_dir" "$csv_dir" "$metadata_dir"

COMMANDS_FILE="$run_dir/commands.sh"
{
    printf '#!/usr/bin/env bash\n'
    printf '# Commands for this CUTLASS benchmark run\n'
} > "$COMMANDS_FILE"

mode="profile"
if (( dry_run == 1 )); then
    mode="dry_run"
fi
summary_csv="$run_dir/summary_cutlass_gemm.csv"
skipped_cases_tsv="$run_dir/unsupported_cases.tsv"

case_labels=()
for case_index in "${!cases_name[@]}"; do
    case_labels+=("${cases_name[$case_index]}:${cases_precision[$case_index]}/${cases_path[$case_index]}")
done

cpu_model="Unavailable"
if have_command lscpu; then
    cpu_model="$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -n 1)"
elif [[ -r /proc/cpuinfo ]]; then
    cpu_model="$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo | head -n 1)"
fi
[[ -n "$cpu_model" ]] || cpu_model="Unavailable"
os_kernel="$(uname -a 2>/dev/null || printf 'Unavailable\n')"

{
    printf 'CUTLASS 4.5.1 Linux GEMM benchmark run\n'
    printf 'Generated: %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
    printf 'Host name: %s\n' "$host_name"
    printf 'CPU model: %s\n' "$cpu_model"
    printf 'OS/kernel: %s\n' "$os_kernel"
    printf 'Shell: %s\n' "${SHELL:-unknown}"
    printf 'Profiler: %s\n' "$profiler_path"
    printf 'Build dir: %s\n' "$profiler_build_dir"
    printf 'Config: %s\n' "$config"
    printf 'Detected compute capability: %s\n' "$detected_compute_cap"
    printf 'Mode: %s\n' "$mode"
    printf 'Precisions: %s\n' "$(IFS=,; printf '%s' "${precisions[*]}")"
    printf 'Runnable cases: %s\n' "$(IFS=,; printf '%s' "${case_labels[*]}")"
    printf 'Unsupported cases: %s\n' "$skipped_cases_tsv"
    printf 'Sizes: %s\n' "$(IFS=,; printf '%s' "${sizes[*]}")"
    printf 'Repeat count: %s\n' "$repeat_count"
    printf 'Profiling iterations: %s\n' "$profiling_iterations"
    printf 'Warmup iterations: %s\n' "$warmup_iterations"
    printf 'Raw output path: %s\n' "$run_dir"
} > "$run_dir/metadata.txt"

{
    printf 'precision\tpath\treason\n'
    for skip_index in "${!skipped_precision[@]}"; do
        printf '%s\t%s\t%s\n' \
            "${skipped_precision[$skip_index]}" \
            "${skipped_path[$skip_index]}" \
            "${skipped_reason[$skip_index]}"
    done
} > "$skipped_cases_tsv"

save_optional_command nvidia-smi nvidia-smi.txt
save_nvidia_smi_query
save_optional_command nvidia-smi nvidia-smi_topology.txt topo -m
save_optional_command nvcc nvcc_version.txt --version
save_optional_command lscpu lscpu.txt
invoke_captured_command \
    "cutlass_profiler device-info" \
    "$profiler_path" \
    "$profiler_dir" \
    "$metadata_dir/cutlass_device_info.txt" \
    1 \
    --device-info

for size in "${sizes[@]}"; do
    for case_index in "${!cases_name[@]}"; do
        for (( repeat=1; repeat<=repeat_count; repeat++ )); do
            repeat_id="$(printf '%02d' "$repeat")"
            case_id="${cases_name[$case_index]}_m${size}_n${size}_k${size}_r${repeat_id}"
            output_prefix="$csv_dir/$case_id"
            stdout_log="$raw_dir/$case_id.txt"
            case_operation="${cases_operation[$case_index]}"
            csv_path="${output_prefix}.$(operation_csv_suffix "$case_operation").csv"

            profiler_args=(
                "--mode=$mode"
                "--operation=$case_operation"
                "--m=$size"
                "--n=$size"
                "--k=$size"
                "--A=${cases_a[$case_index]}"
                "--B=${cases_b[$case_index]}"
                "--C=${cases_c[$case_index]}"
                "--D=${cases_d[$case_index]}"
                "--accumulator-type=${cases_accumulator[$case_index]}"
                --providers=cutlass
                --verification-enabled=false
                "--profiling-iterations=$profiling_iterations"
                "--warmup-iterations=$warmup_iterations"
                "--kernels=${cases_kernel[$case_index]}"
                "--tags=precision:${cases_precision[$case_index]},path:${cases_path[$case_index]},benchmark:cutlass_4_5_1,repeat:$repeat_id"
                "--output=$output_prefix"
            )
            if [[ -n "${cases_runtime_a[$case_index]}" ]]; then
                profiler_args+=("--runtime-input-datatype::a=${cases_runtime_a[$case_index]}")
            fi
            if [[ -n "${cases_runtime_b[$case_index]}" ]]; then
                profiler_args+=("--runtime-input-datatype::b=${cases_runtime_b[$case_index]}")
            fi
            profiler_args+=("${extra_profiler_args[@]}")

            invoke_captured_command \
                "CUTLASS ${cases_precision[$case_index]} ${cases_path[$case_index]} GEMM $size x $size x $size repeat $repeat_id" \
                "$profiler_path" \
                "$profiler_dir" \
                "$stdout_log" \
                "$allow_failures" \
                "${profiler_args[@]}"

            append_csv_to_summary "$csv_path" "$summary_csv"
        done
    done
done

report_path="$(generate_report "$run_dir" "$summary_csv")"
chmod +x "$COMMANDS_FILE" 2>/dev/null || true

printf '\nDone.\n'
printf 'Run directory : %s\n' "$run_dir"
printf 'Summary CSV   : %s\n' "$summary_csv"
printf 'Report        : %s\n' "$report_path"
