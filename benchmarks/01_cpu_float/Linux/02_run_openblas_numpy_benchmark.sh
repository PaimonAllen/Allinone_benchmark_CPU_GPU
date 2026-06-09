#!/usr/bin/env bash
# Run the Linux CPU OpenBLAS/NumPy GEMM benchmark.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_PATH="$(cd -- "$SCRIPT_DIR/../common" && pwd)/openblas_numpy_gemm_benchmark.py"

CONDA_ENV="cudadev"
CONDA_ENV_PROVIDED=0
PYTHON_EXE=""
SIZES="1024,2048,4096"
FALLBACK_SIZES="256,512"
PRECISIONS="ALL_KNOWN"
THREADS=""
REPEAT_COUNT=5
WARMUP_ITERATIONS=2
PROFILING_ITERATIONS=3
SEED=1234
OUTPUT_ROOT="$SCRIPT_DIR/runs"
ALLOW_ANY_BLAS=0
ALLOW_USER_SITE=0
NO_USER_SITE=0
DRY_RUN=0

usage() {
    cat <<'USAGE'
Usage: ./02_run_openblas_numpy_benchmark.sh [options]

Options:
  --conda-env NAME              Run with: conda run -n NAME python. Default: cudadev
  --python PATH                 Python executable to use instead of conda
  --sizes CSV                   BLAS FP32/FP64 matrix sizes. Default: 1024,2048,4096
  --fallback-sizes CSV          NumPy fallback sizes for FP16/FP128. Default: 256,512
  --precisions CSV              Precision sweep. Default: ALL_KNOWN
  --threads CSV                 BLAS thread counts. Default: 1,8,<logical CPU count>
  --repeat-count N              Measured repeats per case. Default: 5
  --warmup-iterations N         Untimed matmul iterations. Default: 2
  --profiling-iterations N      Timed matmul iterations per repeat. Default: 3
  --seed N                      Random seed. Default: 1234
  --output-root DIR             Output root. Default: ./runs
  --allow-any-blas              Do not require OpenBLAS
  --allow-user-site             Do not set PYTHONNOUSERSITE for conda runs
  --no-user-site                Force PYTHONNOUSERSITE=1
  --dry-run                     Write metadata without GEMM work
  -h, --help                    Show this help
USAGE
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

have_command() {
    command -v "$1" >/dev/null 2>&1
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

python_for_host_tools() {
    if have_command python3; then
        command -v python3
    elif have_command python; then
        command -v python
    else
        die "python3 or python is required for parsing JSON"
    fi
}

read_json_field() {
    local path="$1"
    local field="$2"
    local host_python="$3"
    [[ -f "$path" ]] || return 0
    "$host_python" - "$path" "$field" <<'PY'
import json
import sys
from pathlib import Path

path, field = sys.argv[1:]
try:
    payload = json.loads(Path(path).read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)
value = payload.get(field, "")
if value is None:
    value = ""
print(value)
PY
}

json_field_if_state_env_matches() {
    local path="$1"
    local env_name="$2"
    local field="$3"
    local host_python="$4"
    [[ -f "$path" ]] || return 0
    "$host_python" - "$path" "$env_name" "$field" <<'PY'
import json
import sys
from pathlib import Path

path, env_name, field = sys.argv[1:]
try:
    payload = json.loads(Path(path).read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)

selected_env = str(payload.get("selected_env", ""))
if selected_env.lower() != env_name.lower():
    raise SystemExit(0)

value = payload.get(field, "")
if value is None:
    value = ""
print(value)
PY
}

conda_env_exists() {
    local conda_path="$1"
    local env_name="$2"
    local host_python="$3"
    local env_json
    env_json="$("$conda_path" env list --json)"
    CONDA_ENV_JSON="$env_json" "$host_python" - "$env_name" <<'PY'
import json
import os
import sys

payload = json.loads(os.environ["CONDA_ENV_JSON"])
target = sys.argv[1].lower()
for env_path in payload.get("envs", []):
    if env_path.rstrip("/").split("/")[-1].lower() == target:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

write_optional_command_output() {
    local output_path="$1"
    shift
    if command -v "$1" >/dev/null 2>&1; then
        "$@" > "$output_path" 2>&1 || true
    else
        printf 'Command not found: %s\n' "$1" > "$output_path"
    fi
}

while (( $# > 0 )); do
    case "$1" in
        --conda-env) CONDA_ENV="${2:?Missing value for --conda-env}"; CONDA_ENV_PROVIDED=1; shift 2 ;;
        --conda-env=*) CONDA_ENV="${1#*=}"; CONDA_ENV_PROVIDED=1; shift ;;
        --python) PYTHON_EXE="${2:?Missing value for --python}"; shift 2 ;;
        --python=*) PYTHON_EXE="${1#*=}"; shift ;;
        --sizes) SIZES="${2:?Missing value for --sizes}"; shift 2 ;;
        --sizes=*) SIZES="${1#*=}"; shift ;;
        --fallback-sizes) FALLBACK_SIZES="${2:?Missing value for --fallback-sizes}"; shift 2 ;;
        --fallback-sizes=*) FALLBACK_SIZES="${1#*=}"; shift ;;
        --precisions) PRECISIONS="${2:?Missing value for --precisions}"; shift 2 ;;
        --precisions=*) PRECISIONS="${1#*=}"; shift ;;
        --threads) THREADS="${2:?Missing value for --threads}"; shift 2 ;;
        --threads=*) THREADS="${1#*=}"; shift ;;
        --repeat-count) REPEAT_COUNT="${2:?Missing value for --repeat-count}"; shift 2 ;;
        --repeat-count=*) REPEAT_COUNT="${1#*=}"; shift ;;
        --warmup-iterations) WARMUP_ITERATIONS="${2:?Missing value for --warmup-iterations}"; shift 2 ;;
        --warmup-iterations=*) WARMUP_ITERATIONS="${1#*=}"; shift ;;
        --profiling-iterations) PROFILING_ITERATIONS="${2:?Missing value for --profiling-iterations}"; shift 2 ;;
        --profiling-iterations=*) PROFILING_ITERATIONS="${1#*=}"; shift ;;
        --seed) SEED="${2:?Missing value for --seed}"; shift 2 ;;
        --seed=*) SEED="${1#*=}"; shift ;;
        --output-root) OUTPUT_ROOT="${2:?Missing value for --output-root}"; shift 2 ;;
        --output-root=*) OUTPUT_ROOT="${1#*=}"; shift ;;
        --allow-any-blas) ALLOW_ANY_BLAS=1; shift ;;
        --allow-user-site) ALLOW_USER_SITE=1; shift ;;
        --no-user-site) NO_USER_SITE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -f "$RUNNER_PATH" ]] || die "Benchmark runner not found: $RUNNER_PATH"
host_python="$(python_for_host_tools)"
logical_cpus="$(cpu_count)"
if [[ -z "$THREADS" ]]; then
    THREADS="$(default_thread_counts "$logical_cpus")"
fi

selected_env_state_path="$SCRIPT_DIR/selected_env.json"
conda_env_source="default"
selected_env_state=""
if (( CONDA_ENV_PROVIDED == 0 )) && [[ -z "$PYTHON_EXE" && -f "$selected_env_state_path" ]]; then
    selected_env_state="$(read_json_field "$selected_env_state_path" "selected_env" "$host_python")"
    if [[ -n "$selected_env_state" ]]; then
        CONDA_ENV="$selected_env_state"
        conda_env_source="selected_env.json"
    fi
elif (( CONDA_ENV_PROVIDED == 1 )); then
    conda_env_source="parameter"
elif [[ -n "$PYTHON_EXE" ]]; then
    conda_env_source="python_exe"
fi

if [[ -n "$PYTHON_EXE" ]]; then
    if (( CONDA_ENV_PROVIDED == 1 )) && [[ -n "$CONDA_ENV" ]]; then
        printf "WARNING: --python is set, so --conda-env '%s' will be ignored.\n" "$CONDA_ENV" >&2
        conda_env_source="ignored_by_python"
    fi
    CONDA_ENV=""
fi

ld_preload_extra=""
if [[ -z "$PYTHON_EXE" && -n "$CONDA_ENV" && -f "$selected_env_state_path" ]]; then
    ld_preload_extra="$(json_field_if_state_env_matches "$selected_env_state_path" "$CONDA_ENV" "ld_preload" "$host_python")"
fi

mkdir -p "$OUTPUT_ROOT" "$SCRIPT_DIR/logs"

host_name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown_host\n')"
timestamp="$(date +%Y%m%d_%H%M%S)"
run_name="${timestamp}_$(safe_name "$host_name")_linux"
run_dir="$OUTPUT_ROOT/$run_name"
log_path="$SCRIPT_DIR/logs/${run_name}.log"
mkdir -p "$run_dir"

exec > >(tee -a "$log_path") 2>&1

python_cmd=()
if [[ -n "$PYTHON_EXE" ]]; then
    [[ -x "$PYTHON_EXE" ]] || die "Python executable is not executable: $PYTHON_EXE"
    python_cmd=("$PYTHON_EXE")
elif [[ -n "$CONDA_ENV" ]]; then
    conda_path="$(command -v conda || true)"
    [[ -n "$conda_path" ]] || die "CondaEnv was provided, but conda was not found on PATH"
    if ! conda_env_exists "$conda_path" "$CONDA_ENV" "$host_python"; then
        die "Conda environment '$CONDA_ENV' was not found. Run ./01_prepare_openblas_numpy_env.sh first, or pass --conda-env with an existing environment."
    fi
    python_cmd=("$conda_path" run -n "$CONDA_ENV" python)
else
    if have_command python3; then
        python_cmd=("$(command -v python3)")
    elif have_command python; then
        python_cmd=("$(command -v python)")
    else
        die "Neither python3 nor python was found on PATH. Use --python or --conda-env."
    fi
fi

runner_args=(
    "$RUNNER_PATH"
    --output-dir "$run_dir"
    --sizes "$SIZES"
    --fallback-sizes "$FALLBACK_SIZES"
    --precisions "${PRECISIONS^^}"
    --threads "$THREADS"
    --repeat-count "$REPEAT_COUNT"
    --warmup-iterations "$WARMUP_ITERATIONS"
    --profiling-iterations "$PROFILING_ITERATIONS"
    --seed "$SEED"
)
if (( ALLOW_ANY_BLAS == 0 )); then
    runner_args+=(--require-backend openblas)
fi
if (( DRY_RUN == 1 )); then
    runner_args+=(--dry-run)
fi

write_optional_command_output "$run_dir/linux_cpu_info.txt" lscpu
write_optional_command_output "$run_dir/linux_uname.txt" uname -a
if [[ -r /etc/os-release ]]; then
    cp /etc/os-release "$run_dir/linux_os_release.txt"
fi
if have_command numactl; then
    numactl --hardware > "$run_dir/linux_numactl_hardware.txt" 2>&1 || true
fi

run_selected_env_path="$run_dir/selected_env.json"
"$host_python" - \
    "$run_selected_env_path" \
    "$CONDA_ENV" \
    "$conda_env_source" \
    "$PYTHON_EXE" \
    "$selected_env_state_path" \
    "$ld_preload_extra" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

output_path, conda_env, conda_env_source, python_exe, selected_env_state_path, ld_preload = sys.argv[1:]
prepare_state = None
state_path = Path(selected_env_state_path)
if state_path.exists():
    try:
        prepare_state = json.loads(state_path.read_text(encoding="utf-8"))
    except Exception as exc:
        prepare_state = {"error": str(exc)}

payload = {
    "schema_version": 1,
    "generated_at": datetime.now(timezone.utc).astimezone().isoformat(),
    "conda_env": conda_env,
    "conda_env_source": conda_env_source,
    "python_exe": python_exe,
    "ld_preload": ld_preload,
    "selected_env_state_file": selected_env_state_path,
    "prepare_state": prepare_state,
}
Path(output_path).write_text(json.dumps(payload, indent=2), encoding="utf-8")
PY

use_no_user_site=0
if (( NO_USER_SITE == 1 )) || { (( ALLOW_USER_SITE == 0 )) && [[ -n "$CONDA_ENV" ]]; }; then
    use_no_user_site=1
fi

command_path="$run_dir/command.sh"
command_ld_preload=""
if [[ -n "$ld_preload_extra" ]]; then
    command_ld_preload="$ld_preload_extra"
    if [[ -n "${LD_PRELOAD:-}" ]]; then
        command_ld_preload="$command_ld_preload:${LD_PRELOAD}"
    fi
fi
{
    printf '#!/usr/bin/env bash\n'
    printf '# CPU OpenBLAS/NumPy GEMM benchmark command\n'
    printf '# Generated: %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
    if [[ -n "$command_ld_preload" ]]; then
        printf 'export LD_PRELOAD=%q\n' "$command_ld_preload"
    fi
    if (( use_no_user_site == 1 )); then
        printf 'export PYTHONNOUSERSITE=1\n'
    fi
    printf '%q ' "${python_cmd[@]}" "${runner_args[@]}"
    printf '\n'
} > "$command_path"
chmod +x "$command_path" 2>/dev/null || true

printf 'Conda environment: %s\n' "${CONDA_ENV:-none}"
printf 'Conda environment source: %s\n' "$conda_env_source"
printf 'CPU precision sweep: %s\n' "${PRECISIONS^^}"
printf 'BLAS sizes: %s\n' "$SIZES"
printf 'Fallback sizes: %s\n' "$FALLBACK_SIZES"
printf 'Thread sweep: %s\n' "$THREADS"
printf 'RepeatCount=%s WarmupIterations=%s ProfilingIterations=%s\n' "$REPEAT_COUNT" "$WARMUP_ITERATIONS" "$PROFILING_ITERATIONS"
if [[ -n "$ld_preload_extra" ]]; then
    printf 'OpenBLAS LD_PRELOAD: %s\n' "$ld_preload_extra"
fi
printf 'Run directory: %s\n' "$run_dir"
printf 'Log: %s\n' "$log_path"
printf 'Command: %s\n' "$(quote_cmd "${python_cmd[@]}" "${runner_args[@]}")"

if [[ -n "$ld_preload_extra" ]]; then
    if [[ -n "${LD_PRELOAD:-}" ]]; then
        export LD_PRELOAD="$ld_preload_extra:${LD_PRELOAD}"
    else
        export LD_PRELOAD="$ld_preload_extra"
    fi
    printf 'LD_PRELOAD=%s\n' "$LD_PRELOAD"
fi
if (( use_no_user_site == 1 )); then
    export PYTHONNOUSERSITE=1
    printf 'PYTHONNOUSERSITE=1\n'
fi

"${python_cmd[@]}" "${runner_args[@]}"

printf 'Completed. Report: %s\n' "$run_dir/report.md"
