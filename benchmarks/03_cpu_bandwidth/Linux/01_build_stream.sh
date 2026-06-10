#!/usr/bin/env bash
# Compile the STREAM C benchmark for Linux CPU memory bandwidth measurements.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

source_dir="$SCRIPT_DIR/stream-5.10"
build_dir="$SCRIPT_DIR/build"
cc="${CC:-}"
array_size="100000000"
ntimes="20"
offset="0"
stream_type="double"
openmp=1
dry_run=0
log_dir="$SCRIPT_DIR/logs"
extra_cflags=()
extra_ldflags=()

usage() {
    cat <<'USAGE'
Usage: ./01_build_stream.sh [options]

Options:
  --source-dir PATH       STREAM source directory. Default: ./stream-5.10
  --build-dir PATH        Build output directory. Default: ./build
  --cc PATH               C compiler. Default: CC, gcc, then clang
  --array-size N          STREAM_ARRAY_SIZE elements per array. Default: 100000000
  --ntimes N              STREAM NTIMES. Default: 20
  --offset N              STREAM OFFSET. Default: 0
  --stream-type TYPE      STREAM_TYPE. Default: double
  --no-openmp             Compile without OpenMP
  --cflag FLAG            Extra compiler flag. May be repeated
  --ldflag FLAG           Extra linker flag. May be repeated
  --log-dir PATH          Log directory. Default: ./logs
  --dry-run               Print commands without compiling
  -h, --help              Show this help
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

sanitize() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

resolve_compiler() {
    if [[ -n "$cc" ]]; then
        command -v "$cc" 2>/dev/null || printf '%s\n' "$cc"
        return
    fi
    if have_command gcc; then
        command -v gcc
        return
    fi
    if have_command clang; then
        command -v clang
        return
    fi
    die "No C compiler found. Install gcc or clang, or pass --cc."
}

run_logged() {
    local title="$1"
    shift
    local cmd_text
    cmd_text="$(quote_cmd "$@")"
    {
        printf '\n==> %s\n' "$title"
        printf '%s\n' "$cmd_text"
    } | tee -a "$log_file"
    if (( dry_run == 1 )); then
        return 0
    fi
    set +e
    "$@" 2>&1 | tee -a "$log_file"
    local rc=${PIPESTATUS[0]}
    set -e
    (( rc == 0 )) || die "Command failed with exit code $rc: $cmd_text"
}

while (( $# > 0 )); do
    case "$1" in
        --source-dir) source_dir="${2:?Missing value for --source-dir}"; shift 2 ;;
        --source-dir=*) source_dir="${1#*=}"; shift ;;
        --build-dir) build_dir="${2:?Missing value for --build-dir}"; shift 2 ;;
        --build-dir=*) build_dir="${1#*=}"; shift ;;
        --cc) cc="${2:?Missing value for --cc}"; shift 2 ;;
        --cc=*) cc="${1#*=}"; shift ;;
        --array-size) array_size="${2:?Missing value for --array-size}"; shift 2 ;;
        --array-size=*) array_size="${1#*=}"; shift ;;
        --ntimes) ntimes="${2:?Missing value for --ntimes}"; shift 2 ;;
        --ntimes=*) ntimes="${1#*=}"; shift ;;
        --offset) offset="${2:?Missing value for --offset}"; shift 2 ;;
        --offset=*) offset="${1#*=}"; shift ;;
        --stream-type) stream_type="${2:?Missing value for --stream-type}"; shift 2 ;;
        --stream-type=*) stream_type="${1#*=}"; shift ;;
        --no-openmp) openmp=0; shift ;;
        --cflag) extra_cflags+=("${2:?Missing value for --cflag}"); shift 2 ;;
        --cflag=*) extra_cflags+=("${1#*=}"); shift ;;
        --ldflag) extra_ldflags+=("${2:?Missing value for --ldflag}"); shift 2 ;;
        --ldflag=*) extra_ldflags+=("${1#*=}"); shift ;;
        --log-dir) log_dir="${2:?Missing value for --log-dir}"; shift 2 ;;
        --log-dir=*) log_dir="${1#*=}"; shift ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ "$array_size" =~ ^[0-9]+$ && "$array_size" -gt 0 ]] || die "--array-size must be a positive integer"
[[ "$ntimes" =~ ^[0-9]+$ && "$ntimes" -gt 1 ]] || die "--ntimes must be an integer greater than 1"
[[ "$offset" =~ ^[0-9]+$ ]] || die "--offset must be a non-negative integer"
[[ -n "$stream_type" ]] || die "--stream-type cannot be empty"

source_dir="$(real_path_m "$source_dir")"
build_dir="$(real_path_m "$build_dir")"
source_file="$source_dir/stream.c"
[[ -f "$source_file" ]] || die "STREAM source not found: $source_file. Run ./00_get_stream_source.sh first."

mkdir -p "$log_dir" "$build_dir"
timestamp="$(date +%Y%m%d_%H%M%S)"
log_file="$log_dir/build_stream_${timestamp}.log"
exec > >(tee -a "$log_file") 2>&1

compiler="$(resolve_compiler)"
compiler_id="$(basename "$compiler")"
binary_name="stream_$(sanitize "$stream_type")_n${array_size}_t${ntimes}"
if (( openmp == 1 )); then
    binary_name+="_omp"
else
    binary_name+="_serial"
fi
binary_path="$build_dir/$binary_name"

compile_args=(
    "$compiler"
    -O3
    "-DSTREAM_ARRAY_SIZE=$array_size"
    "-DNTIMES=$ntimes"
    "-DOFFSET=$offset"
    "-DSTREAM_TYPE=$stream_type"
)
if (( openmp == 1 )); then
    compile_args+=(-fopenmp)
fi
if [[ "$(uname -m 2>/dev/null || true)" == "x86_64" && "$array_size" -ge 50000000 ]]; then
    compile_args+=(-mcmodel=medium)
fi
compile_args+=("${extra_cflags[@]}" "$source_file" -o "$binary_path" -lm "${extra_ldflags[@]}")

printf 'STREAM source      : %s\n' "$source_file"
printf 'Build directory    : %s\n' "$build_dir"
printf 'Compiler           : %s\n' "$compiler"
printf 'STREAM_ARRAY_SIZE  : %s\n' "$array_size"
printf 'NTIMES             : %s\n' "$ntimes"
printf 'OFFSET             : %s\n' "$offset"
printf 'STREAM_TYPE        : %s\n' "$stream_type"
printf 'OpenMP             : %s\n' "$openmp"
printf 'Output binary      : %s\n' "$binary_path"
printf 'Log file           : %s\n' "$log_file"

run_logged "compile STREAM" "${compile_args[@]}"

command_path="$build_dir/command_${binary_name}.sh"
build_info_path="$build_dir/build_info_${binary_name}.json"
if (( dry_run == 1 )); then
    printf 'Dry run complete. STREAM binary was not built.\n'
    exit 0
fi

chmod +x "$binary_path"
{
    printf '#!/usr/bin/env bash\n'
    printf '# STREAM compile command\n'
    printf '# Generated: %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
    printf '%q ' "${compile_args[@]}"
    printf '\n'
} > "$command_path"
chmod +x "$command_path" 2>/dev/null || true

python3 - "$build_info_path" "$source_file" "$binary_path" "$compiler" "$compiler_id" "$array_size" "$ntimes" "$offset" "$stream_type" "$openmp" "$(quote_cmd "${compile_args[@]}")" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    output,
    source_file,
    binary_path,
    compiler,
    compiler_id,
    array_size,
    ntimes,
    offset,
    stream_type,
    openmp,
    command,
) = sys.argv[1:]
payload = {
    "schema_version": 1,
    "generated_at": datetime.now(timezone.utc).astimezone().isoformat(),
    "source_file": source_file,
    "binary_path": binary_path,
    "compiler": compiler,
    "compiler_id": compiler_id,
    "stream_array_size": int(array_size),
    "ntimes": int(ntimes),
    "offset": int(offset),
    "stream_type": stream_type,
    "openmp": bool(int(openmp)),
    "bytes_per_word": 8 if stream_type == "double" else "",
    "estimated_total_bytes": int(array_size) * (8 if stream_type == "double" else 0) * 3,
    "compile_command": command,
}
Path(output).write_text(json.dumps(payload, indent=2), encoding="utf-8")
PY

printf 'STREAM binary is ready: %s\n' "$binary_path"
printf 'Build info: %s\n' "$build_info_path"
printf 'Log saved to: %s\n' "$log_file"
