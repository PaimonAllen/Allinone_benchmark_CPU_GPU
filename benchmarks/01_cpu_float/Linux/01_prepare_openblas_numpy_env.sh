#!/usr/bin/env bash
# Verify an existing conda environment for the Linux CPU OpenBLAS/NumPy benchmark.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

ENV_NAME="cudadev"
VERIFY_ONLY=0
AUTO_PRELOAD_OPENBLAS=1
DRY_RUN=0

usage() {
    cat <<'USAGE'
Usage: ./01_prepare_openblas_numpy_env.sh [options]

Options:
  --env-name NAME       Existing conda environment to verify. Default: cudadev
  --verify-only         Alias for the default behavior; no environment is modified
  --no-preload-openblas Do not retry verification with LD_PRELOAD
  --dry-run             Print commands without running verification
  -h, --help            Show this help

This script verifies that the selected conda environment exists and that NumPy
uses OpenBLAS. On Linux, if NumPy reports only the generic BLAS ABI but the
environment contains libopenblas, the script retries verification with
LD_PRELOAD and records that run setting. It does not create, remove, or modify
conda environments.
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

python_for_host_tools() {
    if have_command python3; then
        command -v python3
    elif have_command python; then
        command -v python
    else
        die "python3 or python is required for parsing conda JSON"
    fi
}

run_logged() {
    local title="$1"
    shift
    printf '\n==> %s\n%s\n' "$title" "$(quote_cmd "$@")"
    if (( DRY_RUN == 1 )); then
        return 0
    fi
    "$@"
}

capture_logged() {
    local title="$1"
    shift
    printf '\n==> %s\n%s\n' "$title" "$(quote_cmd "$@")" >&2
    if (( DRY_RUN == 1 )); then
        return 0
    fi
    "$@"
}

find_openblas_preload() {
    local env_path="$1"
    local candidate
    for candidate in \
        "$env_path"/lib/libopenblas.so \
        "$env_path"/lib/libopenblas.so.0 \
        "$env_path"/lib/libopenblasp-*.so; do
        if [[ -r "$candidate" ]]; then
            readlink -f "$candidate" 2>/dev/null || printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

verify_has_openblas() {
    local raw_path="$1"
    "$host_python" - "$raw_path" <<'PY'
import json
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
json_start = text.find("{")
json_end = text.rfind("}")
if json_start < 0 or json_end < json_start:
    raise SystemExit(1)

payload = json.loads(text[json_start : json_end + 1])
for item in payload.get("threadpool_info", []):
    if item.get("user_api") == "blas" and item.get("internal_api") == "openblas":
        raise SystemExit(0)
raise SystemExit(1)
PY
}

while (( $# > 0 )); do
    case "$1" in
        --env-name) ENV_NAME="${2:?Missing value for --env-name}"; shift 2 ;;
        --env-name=*) ENV_NAME="${1#*=}"; shift ;;
        --verify-only) VERIFY_ONLY=1; shift ;;
        --no-preload-openblas) AUTO_PRELOAD_OPENBLAS=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

log_root="$SCRIPT_DIR/logs"
selected_env_path="$SCRIPT_DIR/selected_env.json"
mkdir -p "$log_root"

timestamp="$(date +%Y%m%d_%H%M%S_%3N)"
safe_env="${ENV_NAME//[^A-Za-z0-9_.-]/_}"
log_path="$log_root/${timestamp}_prepare_${safe_env}.log"
verify_path="$log_root/${timestamp}_prepare_${safe_env}_verify.json"
verify_script_path="$log_root/${timestamp}_prepare_${safe_env}_verify.py"
verify_raw_direct_path="$log_root/${timestamp}_prepare_${safe_env}_verify_raw_direct.txt"
verify_raw_preload_path="$log_root/${timestamp}_prepare_${safe_env}_verify_raw_preload.txt"

exec > >(tee -a "$log_path") 2>&1

conda_path="$(command -v conda || true)"
[[ -n "$conda_path" ]] || die "conda was not found on PATH"
host_python="$(python_for_host_tools)"

printf 'Conda: %s\n' "$conda_path"
printf 'Default CPU float conda environment: %s\n' "$ENV_NAME"
printf 'This script verifies an existing OpenBLAS NumPy environment for the Linux CPU benchmark.\n'
printf 'It does not create, remove, or modify conda environments.\n'
(( VERIFY_ONLY == 1 )) && printf 'Verify-only mode selected.\n'

run_logged "conda --version" "$conda_path" --version

env_json="$("$conda_path" env list --json)"
env_path="$(CONDA_ENV_JSON="$env_json" "$host_python" - "$ENV_NAME" <<'PY'
import json
import os
import sys

payload = json.loads(os.environ["CONDA_ENV_JSON"])
target = sys.argv[1].lower()
for env_path in payload.get("envs", []):
    name = env_path.rstrip("/").split("/")[-1]
    if name.lower() == target:
        print(env_path)
        break
PY
)"

if [[ -z "$env_path" ]]; then
    printf "Conda environment '%s' was not found. Available environments:\n" "$ENV_NAME" >&2
    CONDA_ENV_JSON="$env_json" "$host_python" - <<'PY' >&2
import json
import os

payload = json.loads(os.environ["CONDA_ENV_JSON"])
for env_path in payload.get("envs", []):
    name = env_path.rstrip("/").split("/")[-1]
    print(f"  {name}  {env_path}")
PY
    die "Please pass --env-name with an existing environment"
fi

printf "Conda environment '%s' exists at: %s\n" "$ENV_NAME" "$env_path"

openblas_preload_path=""
if (( AUTO_PRELOAD_OPENBLAS == 1 )); then
    openblas_preload_path="$(find_openblas_preload "$env_path" || true)"
    if [[ -n "$openblas_preload_path" ]]; then
        printf 'OpenBLAS preload candidate: %s\n' "$openblas_preload_path"
    else
        printf 'OpenBLAS preload candidate: not found in %s/lib\n' "$env_path"
    fi
else
    printf 'OpenBLAS LD_PRELOAD retry disabled.\n'
fi

cat > "$verify_script_path" <<'PY'
import contextlib
import io
import json
import os
import sys

import numpy as np
from threadpoolctl import threadpool_info

_a = np.ones((8, 8), dtype=np.float32)
_b = np.ones((8, 8), dtype=np.float32)
_ = _a @ _b

config_buffer = io.StringIO()
with contextlib.redirect_stdout(config_buffer):
    np.__config__.show()

payload = {
    "python_executable": sys.executable,
    "python_version": sys.version.replace("\n", " "),
    "numpy_version": np.__version__,
    "numpy_path": np.__file__,
    "ld_preload": os.environ.get("LD_PRELOAD", ""),
    "numpy_config": config_buffer.getvalue().strip(),
    "threadpool_info": threadpool_info(),
}
print(json.dumps(payload, indent=2))
PY

printf 'Verify script: %s\n' "$verify_script_path"

if (( DRY_RUN == 1 )); then
    printf 'Dry run completed. No verification was executed.\n'
    exit 0
fi

capture_logged \
    "verify NumPy/OpenBLAS" \
    env PYTHONNOUSERSITE=1 "$conda_path" run -n "$ENV_NAME" python "$verify_script_path" | tee "$verify_raw_direct_path"

selected_verify_raw_path="$verify_raw_direct_path"
ld_preload_for_benchmark=""
blas_detection_mode="direct"
if verify_has_openblas "$verify_raw_direct_path"; then
    printf 'Direct NumPy/OpenBLAS verification succeeded.\n'
elif [[ -n "$openblas_preload_path" ]]; then
    printf 'Direct verification did not report OpenBLAS; retrying with LD_PRELOAD.\n'
    capture_logged \
        "verify NumPy/OpenBLAS with LD_PRELOAD" \
        env LD_PRELOAD="$openblas_preload_path" PYTHONNOUSERSITE=1 "$conda_path" run -n "$ENV_NAME" python "$verify_script_path" | tee "$verify_raw_preload_path"
    selected_verify_raw_path="$verify_raw_preload_path"
    ld_preload_for_benchmark="$openblas_preload_path"
    blas_detection_mode="ld_preload"
fi

"$host_python" - \
    "$selected_verify_raw_path" \
    "$verify_path" \
    "$selected_env_path" \
    "$ENV_NAME" \
    "$env_path" \
    "$conda_path" \
    "$verify_script_path" \
    "$ld_preload_for_benchmark" \
    "$blas_detection_mode" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    raw_path,
    verify_path,
    selected_env_path,
    env_name,
    env_path,
    conda_path,
    verify_script_path,
    ld_preload,
    blas_detection_mode,
) = sys.argv[1:]
text = Path(raw_path).read_text(encoding="utf-8", errors="replace")
json_start = text.find("{")
json_end = text.rfind("}")
if json_start < 0 or json_end < json_start:
    raise SystemExit(f"Could not parse verification JSON from {raw_path}")

verify_text = text[json_start : json_end + 1]
payload = json.loads(verify_text)
Path(verify_path).write_text(json.dumps(payload, indent=2), encoding="utf-8")

blas_info = None
for item in payload.get("threadpool_info", []):
    if item.get("user_api") == "blas" and item.get("internal_api") == "openblas":
        blas_info = item
        break

if blas_info is None:
    raise SystemExit(
        f"Environment '{env_name}' did not report OpenBLAS. See {verify_path}. "
        "Choose an environment whose NumPy uses OpenBLAS, keep a usable libopenblas in the conda env "
        "for LD_PRELOAD retry, or run the benchmark with --allow-any-blas."
    )

state = {
    "schema_version": 1,
    "selected_env": env_name,
    "env_path": env_path,
    "conda_executable": conda_path,
    "verified_at": datetime.now(timezone.utc).astimezone().isoformat(),
    "verification_json": verify_path,
    "verification_script": verify_script_path,
    "verification_raw": raw_path,
    "blas_detection_mode": blas_detection_mode,
    "ld_preload": ld_preload,
    "python_executable": payload.get("python_executable", ""),
    "python_version": payload.get("python_version", ""),
    "numpy_version": payload.get("numpy_version", ""),
    "numpy_path": payload.get("numpy_path", ""),
    "blas_backend": " ".join(
        str(part)
        for part in [
            blas_info.get("internal_api", ""),
            blas_info.get("version", ""),
            blas_info.get("threading_layer", ""),
            blas_info.get("architecture", ""),
        ]
        if part
    ),
    "blas_library": blas_info.get("filepath", ""),
    "blas_num_threads": blas_info.get("num_threads", ""),
    "threadpool_info": payload.get("threadpool_info", []),
}
Path(selected_env_path).write_text(json.dumps(state, indent=2), encoding="utf-8")
PY

printf 'OpenBLAS conda environment verified: %s\n' "$ENV_NAME"
printf 'Verification: %s\n' "$verify_path"
printf 'Selected environment state: %s\n' "$selected_env_path"
printf 'Next: ./02_run_openblas_numpy_benchmark.sh\n'
