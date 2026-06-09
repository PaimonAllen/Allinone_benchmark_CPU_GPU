#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_PATH="$(cd "${SCRIPT_DIR}/../common" && pwd)/openblas_numpy_gemm_benchmark.py"

CONDA_ENV="${CONDA_ENV:-}"
PYTHON_EXE="${PYTHON_EXE:-}"
SIZES="${SIZES:-1024,2048,4096}"
PRECISIONS="${PRECISIONS:-FP32,FP64}"
THREADS="${THREADS:-1,2,4,8,16,24}"
REPEAT_COUNT="${REPEAT_COUNT:-3}"
WARMUP_ITERATIONS="${WARMUP_ITERATIONS:-1}"
PROFILING_ITERATIONS="${PROFILING_ITERATIONS:-3}"
SEED="${SEED:-1234}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${SCRIPT_DIR}/runs}"
NO_USER_SITE="${NO_USER_SITE:-0}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: ./01_run_openblas_numpy_benchmark.sh [options]

Options:
  --conda-env NAME              Run with: conda run -n NAME python
  --python PATH                 Python executable to use
  --sizes CSV                   Matrix sizes, default: 1024,2048,4096
  --precisions CSV              FP32,FP64, default: FP32,FP64
  --threads CSV                 BLAS thread counts, default: 1,2,4,8,16,24
  --repeat-count N              Measured repeats per case, default: 3
  --warmup-iterations N         Untimed matmul iterations, default: 1
  --profiling-iterations N      Timed matmul iterations per repeat, default: 3
  --seed N                      Random seed, default: 1234
  --output-root DIR             Output root, default: ./runs
  --no-user-site                Set PYTHONNOUSERSITE=1 for the child Python
  --dry-run                     Write metadata without GEMM work
  -h, --help                    Show this help

Environment variables with the same uppercase names can also be used.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --conda-env)
      CONDA_ENV="$2"
      shift 2
      ;;
    --python)
      PYTHON_EXE="$2"
      shift 2
      ;;
    --sizes)
      SIZES="$2"
      shift 2
      ;;
    --precisions)
      PRECISIONS="$2"
      shift 2
      ;;
    --threads)
      THREADS="$2"
      shift 2
      ;;
    --repeat-count)
      REPEAT_COUNT="$2"
      shift 2
      ;;
    --warmup-iterations)
      WARMUP_ITERATIONS="$2"
      shift 2
      ;;
    --profiling-iterations)
      PROFILING_ITERATIONS="$2"
      shift 2
      ;;
    --seed)
      SEED="$2"
      shift 2
      ;;
    --output-root)
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    --no-user-site)
      NO_USER_SITE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "${OUTPUT_ROOT}" "${SCRIPT_DIR}/logs"

HOST_NAME="$(hostname 2>/dev/null || echo unknown_host)"
SAFE_HOST_NAME="$(printf '%s' "${HOST_NAME}" | sed 's/[^A-Za-z0-9_.-]/_/g')"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RUN_NAME="${TIMESTAMP}_${SAFE_HOST_NAME}_linux"
RUN_DIR="${OUTPUT_ROOT}/${RUN_NAME}"
LOG_PATH="${SCRIPT_DIR}/logs/${RUN_NAME}.log"
mkdir -p "${RUN_DIR}"

exec > >(tee -a "${LOG_PATH}") 2>&1

PYTHON_CMD=()
if [[ -n "${PYTHON_EXE}" ]]; then
  PYTHON_CMD=("${PYTHON_EXE}")
elif [[ -n "${CONDA_ENV}" ]]; then
  if ! command -v conda >/dev/null 2>&1; then
    echo "CONDA_ENV was provided, but conda was not found on PATH." >&2
    exit 1
  fi
  PYTHON_CMD=(conda run -n "${CONDA_ENV}" python)
elif command -v python3 >/dev/null 2>&1; then
  PYTHON_CMD=(python3)
elif command -v python >/dev/null 2>&1; then
  PYTHON_CMD=(python)
else
  echo "Neither python3 nor python was found on PATH. Use --python or --conda-env." >&2
  exit 1
fi

RUNNER_ARGS=(
  "${RUNNER_PATH}"
  --output-dir "${RUN_DIR}"
  --sizes "${SIZES}"
  --precisions "${PRECISIONS}"
  --threads "${THREADS}"
  --repeat-count "${REPEAT_COUNT}"
  --warmup-iterations "${WARMUP_ITERATIONS}"
  --profiling-iterations "${PROFILING_ITERATIONS}"
  --seed "${SEED}"
)
if [[ "${DRY_RUN}" -eq 1 ]]; then
  RUNNER_ARGS+=(--dry-run)
fi

printf '# CPU OpenBLAS/NumPy GEMM benchmark command\n' > "${RUN_DIR}/command.sh"
printf '# Generated: %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)" >> "${RUN_DIR}/command.sh"
if [[ "${NO_USER_SITE}" == "1" ]]; then
  printf 'export PYTHONNOUSERSITE=1\n' >> "${RUN_DIR}/command.sh"
fi
printf '%q ' "${PYTHON_CMD[@]}" "${RUNNER_ARGS[@]}" >> "${RUN_DIR}/command.sh"
printf '\n' >> "${RUN_DIR}/command.sh"

echo "Run directory: ${RUN_DIR}"
echo "Log: ${LOG_PATH}"
echo "Command: ${PYTHON_CMD[*]} ${RUNNER_ARGS[*]}"

if [[ "${NO_USER_SITE}" == "1" ]]; then
  export PYTHONNOUSERSITE=1
  echo "PYTHONNOUSERSITE=1"
fi

"${PYTHON_CMD[@]}" "${RUNNER_ARGS[@]}"

echo "Completed. Report: ${RUN_DIR}/report.md"
