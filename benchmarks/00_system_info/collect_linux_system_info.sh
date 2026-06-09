#!/usr/bin/env bash
# Collect Linux system information before CPU/GPU benchmark runs.

set -u
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_ROOT="${OUTPUT_ROOT:-"$SCRIPT_DIR/runs"}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
HOST_NAME="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)"
RUN_DIR="$OUTPUT_ROOT/${TIMESTAMP}_${HOST_NAME}_linux"
mkdir -p "$RUN_DIR"

write_header() {
    local path="$1"
    local title="$2"

    {
        echo "# $title"
        echo "Generated: $(date --iso-8601=seconds 2>/dev/null || date)"
        echo "Host: $HOST_NAME"
        echo "Run directory: $RUN_DIR"
        echo
    } > "$path"
}

capture_cmd() {
    local file_name="$1"
    local title="$2"
    shift 2

    local path="$RUN_DIR/$file_name"
    write_header "$path" "$title"

    if ! command -v "$1" >/dev/null 2>&1; then
        echo "SKIP: command not found: $1" >> "$path"
        return 0
    fi

    {
        printf 'Command:'
        printf ' %q' "$@"
        echo
        echo
        "$@"
        local rc=$?
        echo
        echo "ExitCode: $rc"
    } >> "$path" 2>&1
}

capture_shell() {
    local file_name="$1"
    local title="$2"
    local command_text="$3"

    local path="$RUN_DIR/$file_name"
    write_header "$path" "$title"

    {
        echo "Command: $command_text"
        echo
        bash -lc "$command_text"
        local rc=$?
        echo
        echo "ExitCode: $rc"
    } >> "$path" 2>&1
}

find_device_query() {
    local candidates=()

    if command -v deviceQuery >/dev/null 2>&1; then
        candidates+=("$(command -v deviceQuery)")
    fi
    if [ -n "${CUDA_HOME:-}" ]; then
        candidates+=("$CUDA_HOME/extras/demo_suite/deviceQuery")
    fi
    if [ -n "${CUDA_PATH:-}" ]; then
        candidates+=("$CUDA_PATH/extras/demo_suite/deviceQuery")
    fi
    candidates+=("/usr/local/cuda/extras/demo_suite/deviceQuery")

    local candidate
    for candidate in "${candidates[@]}"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

{
    echo "# System summary"
    echo "Generated: $(date --iso-8601=seconds 2>/dev/null || date)"
    echo "Host name: $HOST_NAME"
    echo "Run directory: $RUN_DIR"
    echo

    echo "OS/kernel:"
    uname -a 2>&1 || true
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        echo "${PRETTY_NAME:-unknown}"
    fi
    echo

    echo "CPU model:"
    if command -v lscpu >/dev/null 2>&1; then
        lscpu | sed -n 's/^Model name:[[:space:]]*/CPU model: /p; s/^CPU(s):[[:space:]]*/Logical CPUs: /p; s/^Core(s) per socket:[[:space:]]*/Cores per socket: /p; s/^Socket(s):[[:space:]]*/Sockets: /p'
    else
        grep -m1 'model name' /proc/cpuinfo 2>/dev/null || echo "SKIP: lscpu not found"
    fi
    echo

    echo "Memory:"
    if command -v free >/dev/null 2>&1; then
        free -h
    else
        grep -E 'MemTotal|MemAvailable' /proc/meminfo 2>/dev/null || echo "SKIP: free not found"
    fi
    echo

    echo "NVIDIA GPUs:"
    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap,pci.bus_id,pcie.link.gen.current,pcie.link.width.current,power.limit --format=csv 2>&1
    else
        echo "SKIP: nvidia-smi not found"
    fi
    echo

    echo "CUDA toolkit:"
    if command -v nvcc >/dev/null 2>&1; then
        nvcc --version
    else
        echo "SKIP: nvcc not found"
    fi
} > "$RUN_DIR/00_summary.txt" 2>&1

capture_cmd "01_lscpu.txt" "lscpu" lscpu
capture_cmd "02_memory_free.txt" "free -h" free -h
capture_shell "03_numactl_hardware.txt" "numactl --hardware" 'if command -v numactl >/dev/null 2>&1; then numactl --hardware; else echo "SKIP: command not found: numactl"; fi'
capture_cmd "04_nvidia_smi.txt" "nvidia-smi" nvidia-smi
capture_cmd "05_nvidia_smi_topo.txt" "nvidia-smi topo -m" nvidia-smi topo -m
capture_cmd "06_nvcc_version.txt" "nvcc --version" nvcc --version
capture_shell "07_lspci_gpu.txt" "lspci GPU devices" "if command -v lspci >/dev/null 2>&1; then lspci | grep -Ei 'vga|3d|display|nvidia'; else echo 'SKIP: command not found: lspci'; fi"

device_query_path="$(find_device_query || true)"
if [ -n "$device_query_path" ]; then
    capture_cmd "08_cuda_device_query.txt" "CUDA deviceQuery" "$device_query_path"
else
    path="$RUN_DIR/08_cuda_device_query.txt"
    write_header "$path" "CUDA deviceQuery"
    echo "SKIP: deviceQuery not found under PATH, CUDA_HOME, CUDA_PATH, or /usr/local/cuda." >> "$path"
fi

capture_shell "09_compilers_and_tools.txt" "Compilers and tools" '
tools="nvidia-smi nvcc cmake ninja make gcc g++ clang clang++ python3 python pip3 pip conda ncu nv-nsight-cu-cli cutlass_profiler bandwidthTest nvbandwidth perf likwid-bench likwid-perfctr numactl lspci"
for tool in $tools; do
    if command -v "$tool" >/dev/null 2>&1; then
        printf "FOUND\t%s\t%s\n" "$tool" "$(command -v "$tool")"
    else
        printf "MISSING\t%s\n" "$tool"
    fi
done

echo
echo "Version checks:"
for tool in nvcc cmake ninja make gcc g++ clang clang++ python3 python ncu nv-nsight-cu-cli; do
    if command -v "$tool" >/dev/null 2>&1; then
        echo
        echo "## $tool"
        case "$tool" in
            nvcc|cmake|gcc|g++|clang|clang++|python3|python|ncu|nv-nsight-cu-cli)
                "$tool" --version 2>&1 | head -n 8
                ;;
            ninja)
                "$tool" --version 2>&1
                ;;
            make)
                "$tool" --version 2>&1 | head -n 4
                ;;
        esac
    fi
done
'

capture_shell "10_python_conda.txt" "Python and Conda environments" '
for py in python3 python; do
    if command -v "$py" >/dev/null 2>&1; then
        echo "## $py"
        "$py" --version 2>&1
        "$py" -c "import sys; print(sys.executable)" 2>&1 || true
        "$py" -m pip list --format=freeze 2>/dev/null | grep -Ei "^(numpy|scipy|torch|torchvision|torchaudio|cupy|tensorflow|jax|jaxlib|numba|pycuda|triton|mkl|mkl-service|intel-openmp|openblas|nvidia-|cuda-python|cutlass)==" || true
        echo
    fi
done

if command -v conda >/dev/null 2>&1; then
    echo "## conda env list"
    conda env list 2>&1
else
    echo "SKIP: conda not found"
fi
'

capture_shell "11_cuda_environment.txt" "CUDA-related environment" '
env | sort | grep -E "^(CUDA|NVIDIA|LD_LIBRARY_PATH|PATH)=" || true
echo
for root in "${CUDA_HOME:-}" "${CUDA_PATH:-}" /usr/local/cuda; do
    if [ -n "$root" ] && [ -d "$root" ]; then
        echo "CUDA root: $root"
        for header in cuda_runtime.h cublas_v2.h cuda_fp8.h cuda_fp4.h; do
            if [ -e "$root/include/$header" ]; then
                echo "FOUND $root/include/$header"
            else
                echo "MISSING $root/include/$header"
            fi
        done
        echo
    fi
done
'

echo "System information written to: $RUN_DIR"
