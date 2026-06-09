#!/usr/bin/env bash
# Configure and build the CUTLASS 4.5.1 profiler on Linux.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SOURCE_DIR="$SCRIPT_DIR/cutlass-4.5.1"
DEFAULT_BUILD_DIR="$DEFAULT_SOURCE_DIR/build"

source_dir="$DEFAULT_SOURCE_DIR"
build_dir="$DEFAULT_BUILD_DIR"
generator="${CUTLASS_CMAKE_GENERATOR:-}"
config="Release"
cuda_archs="auto"
target="cutlass_profiler"
operations="gemm"
kernels="auto"
parallel="${CMAKE_BUILD_PARALLEL_LEVEL:-}"
clean=0
configure_only=0
skip_configure=0
dry_run=0
log_dir="$SCRIPT_DIR/logs"
temp_dir=""
keep_temp_dir=0
extra_cmake_args=()

usage() {
    cat <<'USAGE'
Usage: ./01_build_cutlass_4_5_1.sh [options]

Options:
  --source-dir PATH       CUTLASS source directory. Default: ./cutlass-4.5.1
  --build-dir PATH        CMake build directory. Default: ./cutlass-4.5.1/build
  --generator NAME        CMake generator. Default: Ninja when available, else Unix Makefiles
  --config NAME           CMAKE_BUILD_TYPE. Default: Release
  --cuda-archs LIST       CUTLASS_NVCC_ARCHS value, or auto. Default: auto
  --target NAME           Build target. Default: cutlass_profiler
  --operations LIST       CUTLASS_LIBRARY_OPERATIONS. Default: gemm
  --kernels LIST          CUTLASS_LIBRARY_KERNELS, empty string, or auto. Default: auto
                          auto builds FP32/FP64 plus supported Tensor Core kernels
  --parallel N            Parallel build jobs. Default: CMAKE_BUILD_PARALLEL_LEVEL or CPU count
  --clean                 Remove the build directory before configuring
  --configure-only        Configure but do not build
  --skip-configure        Build using an existing CMake configuration
  --dry-run               Print commands without executing CMake
  --log-dir PATH          Log directory. Default: ./logs
  --temp-dir PATH         Set TMPDIR during the build and clean it afterwards
  --keep-temp-dir         Keep --temp-dir contents after the build
  --extra-cmake-arg ARG   Extra CMake configure argument. May be repeated
  -h, --help              Show this help

Any arguments after -- are passed through to CMake configure.
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

cpu_count() {
    getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || printf '1\n'
}

arch_to_number() {
    local token="$1"
    token="${token//[[:space:]]/}"

    if [[ "$token" =~ ^([0-9]+)\.([0-9]+) ]]; then
        printf '%s\n' "$((10#${BASH_REMATCH[1]} * 10 + 10#${BASH_REMATCH[2]}))"
        return
    fi

    if [[ "$token" =~ ([0-9]{2,3}) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf '0\n'
    fi
}

max_arch_number() {
    local list="${1//,/;}"
    local token value max=0
    local tokens=()
    IFS=';' read -r -a tokens <<< "$list"

    for token in "${tokens[@]}"; do
        value="$(arch_to_number "$token")"
        if [[ "$value" =~ ^[0-9]+$ ]] && (( value > max )); then
            max="$value"
        fi
    done

    printf '%s\n' "$max"
}

arch_at_least() {
    local arch
    arch="$(max_arch_number "$1")"
    [[ "$arch" =~ ^[0-9]+$ ]] && (( arch >= "$2" ))
}

detect_cuda_archs() {
    local caps=()
    local cap arch

    if have_command nvidia-smi; then
        while IFS= read -r cap; do
            cap="${cap//[[:space:]]/}"
            [[ -z "$cap" ]] && continue
            arch="${cap/./}"
            arch="${arch//[^0-9a-zA-Z]/}"
            [[ -n "$arch" ]] && caps+=("$arch")
        done < <(nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits 2>/dev/null | sort -u || true)
    fi

    if (( ${#caps[@]} == 0 )); then
        printf '89\n'
        return
    fi

    local IFS=';'
    printf '%s\n' "${caps[*]}"
}

resolve_kernels() {
    local resolved_archs="$1"
    local arch filters=()

    if [[ "$kernels" != "auto" ]]; then
        printf '%s\n' "$kernels"
        return
    fi

    arch="$(max_arch_number "$resolved_archs")"
    filters+=(sgemm dgemm)

    if (( arch >= 70 )); then
        if (( arch < 75 )); then
            filters+=(h884gemm_[0-9])
        else
            filters+=(h1688gemm_[0-9])
        fi
    fi

    if arch_at_least "$resolved_archs" 80; then
        filters+=(tf32gemm s1688gemm_tf32 d884gemm)
    fi

    if arch_at_least "$resolved_archs" 89; then
        filters+=(gemm_f8 gemm_e4m3 gemm_e5m2)
    fi

    if arch_at_least "$resolved_archs" 100; then
        filters+=(bstensorop ue8m0xe2m1 ue4m3xf4)
    fi

    local IFS=,
    printf '%s\n' "${filters[*]}"
}

cleanup_temp_dir() {
    [[ -z "$temp_dir" || "$dry_run" -eq 1 || "$keep_temp_dir" -eq 1 ]] && return

    local temp_path temp_leaf
    temp_path="$(real_path_m "$temp_dir")"
    temp_leaf="$(basename "$temp_path")"

    if [[ "$temp_path" == "/" || ! "$temp_leaf" =~ [Cc][Uu][Tt][Ll][Aa][Ss][Ss] ]]; then
        printf 'Skipping temp cleanup for non-dedicated temp directory: %s\n' "$temp_path" >&2
        return
    fi

    if [[ -d "$temp_path" ]]; then
        rm -rf -- "$temp_path"
    fi
}

safe_clean_build_dir() {
    local build_path="$1"
    local source_path="$2"
    local script_path tmp_cutlass
    script_path="$(real_path_m "$SCRIPT_DIR")"
    tmp_cutlass="$(real_path_m "${TMPDIR:-/tmp}/cutlass_build")"

    case "$build_path" in
        "$source_path"/*|"$script_path"/*|"$tmp_cutlass"/*)
            ;;
        *)
            die "Refusing to clean build directory outside known safe roots: $build_path"
            ;;
    esac

    [[ "$build_path" != "/" ]] || die "Refusing to clean filesystem root"
    [[ "$build_path" != "$source_path" ]] || die "Refusing to clean source directory as build directory"

    printf '\n==> Cleaning build directory\n%s\n' "$build_path" | tee -a "$LOG_FILE"
    if (( dry_run == 0 )); then
        rm -rf -- "$build_path"
    fi
}

run_logged() {
    local title="$1"
    shift
    local cmd_text
    cmd_text="$(quote_cmd "$@")"

    {
        printf '\n==> %s\n' "$title"
        printf '%s\n' "$cmd_text"
    } | tee -a "$LOG_FILE"

    if (( dry_run == 1 )); then
        return 0
    fi

    set +e
    "$@" 2>&1 | tee -a "$LOG_FILE"
    local rc=${PIPESTATUS[0]}
    set -e

    if (( rc != 0 )); then
        die "Command failed with exit code $rc: $cmd_text"
    fi
}

while (( $# > 0 )); do
    case "$1" in
        --source-dir) source_dir="${2:?Missing value for --source-dir}"; shift 2 ;;
        --source-dir=*) source_dir="${1#*=}"; shift ;;
        --build-dir) build_dir="${2:?Missing value for --build-dir}"; shift 2 ;;
        --build-dir=*) build_dir="${1#*=}"; shift ;;
        --generator) generator="${2:?Missing value for --generator}"; shift 2 ;;
        --generator=*) generator="${1#*=}"; shift ;;
        --config) config="${2:?Missing value for --config}"; shift 2 ;;
        --config=*) config="${1#*=}"; shift ;;
        --cuda-archs) cuda_archs="${2:?Missing value for --cuda-archs}"; shift 2 ;;
        --cuda-archs=*) cuda_archs="${1#*=}"; shift ;;
        --target) target="${2:?Missing value for --target}"; shift 2 ;;
        --target=*) target="${1#*=}"; shift ;;
        --operations) operations="${2:?Missing value for --operations}"; shift 2 ;;
        --operations=*) operations="${1#*=}"; shift ;;
        --kernels) kernels="${2-}"; shift 2 ;;
        --kernels=*) kernels="${1#*=}"; shift ;;
        --parallel) parallel="${2:?Missing value for --parallel}"; shift 2 ;;
        --parallel=*) parallel="${1#*=}"; shift ;;
        --clean) clean=1; shift ;;
        --configure-only) configure_only=1; shift ;;
        --skip-configure) skip_configure=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        --log-dir) log_dir="${2:?Missing value for --log-dir}"; shift 2 ;;
        --log-dir=*) log_dir="${1#*=}"; shift ;;
        --temp-dir) temp_dir="${2:?Missing value for --temp-dir}"; shift 2 ;;
        --temp-dir=*) temp_dir="${1#*=}"; shift ;;
        --keep-temp-dir) keep_temp_dir=1; shift ;;
        --extra-cmake-arg) extra_cmake_args+=("${2:?Missing value for --extra-cmake-arg}"); shift 2 ;;
        --extra-cmake-arg=*) extra_cmake_args+=("${1#*=}"); shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; extra_cmake_args+=("$@"); break ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ "$operations" =~ ^(gemm|all|conv2d|conv3d|rank_k|rank_2k|trmm|symm)$ ]] ||
    die "Unsupported --operations value: $operations"

if [[ -z "$parallel" ]]; then
    parallel="$(cpu_count)"
fi
[[ "$parallel" =~ ^[0-9]+$ && "$parallel" -gt 0 ]] ||
    die "--parallel must be a positive integer: $parallel"

if [[ -z "$generator" ]]; then
    if have_command ninja; then
        generator="Ninja"
    else
        generator="Unix Makefiles"
    fi
fi

[[ -d "$source_dir" ]] || die "CUTLASS source directory not found: $source_dir"
source_path="$(real_path_m "$source_dir")"
build_path="$(real_path_m "$build_dir")"
[[ -f "$source_path/CMakeLists.txt" ]] || die "CUTLASS CMakeLists.txt not found: $source_path/CMakeLists.txt"
[[ -f "$source_path/tools/profiler/CMakeLists.txt" ]] || die "CUTLASS profiler CMakeLists.txt not found: $source_path/tools/profiler/CMakeLists.txt"

cmake_path="$(command -v cmake || true)"
[[ -n "$cmake_path" ]] || die "Required command not found in PATH: cmake"
nvcc_path="$(command -v nvcc || true)"
[[ -n "$nvcc_path" ]] || die "Required command not found in PATH: nvcc"
if [[ "$generator" == "Ninja" ]]; then
    have_command ninja || die "Generator Ninja selected but ninja is not in PATH"
fi

if [[ "$cuda_archs" == "auto" ]]; then
    resolved_cuda_archs="$(detect_cuda_archs)"
else
    resolved_cuda_archs="$cuda_archs"
fi
resolved_kernels="$(resolve_kernels "$resolved_cuda_archs")"

mkdir -p "$log_dir"
timestamp="$(date +%Y%m%d_%H%M%S)"
safe_generator="${generator//[^A-Za-z0-9]/_}"
LOG_FILE="$log_dir/cutlass_4_5_1_${safe_generator}_${timestamp}.log"

{
    printf 'CUTLASS 4.5.1 Linux build log\n'
    printf 'Generated: %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
    printf 'Source: %s\n' "$source_path"
    printf 'Build: %s\n' "$build_path"
    printf 'Generator: %s\n' "$generator"
    printf 'Config: %s\n' "$config"
    printf 'CUDA archs: %s\n' "$resolved_cuda_archs"
    printf 'Operations: %s\n' "$operations"
    printf 'Kernels: %s\n' "$resolved_kernels"
    printf 'Target: %s\n' "$target"
    printf 'Parallel: %s\n' "$parallel"
    printf 'Temp dir: %s\n' "${temp_dir:-none}"
    printf 'CMake: %s\n' "$cmake_path"
    printf 'NVCC: %s\n' "$nvcc_path"
} > "$LOG_FILE"

printf 'CUTLASS source : %s\n' "$source_path"
printf 'Build dir      : %s\n' "$build_path"
printf 'Generator      : %s\n' "$generator"
printf 'Config         : %s\n' "$config"
printf 'CUDA archs     : %s\n' "$resolved_cuda_archs"
printf 'Operations     : %s\n' "$operations"
printf 'Kernels        : %s\n' "$resolved_kernels"
printf 'Target         : %s\n' "$target"
printf 'Parallel       : %s\n' "$parallel"
printf 'Temp dir       : %s\n' "${temp_dir:-none}"
printf 'CMake          : %s\n' "$cmake_path"
printf 'NVCC           : %s\n' "$nvcc_path"
printf 'Log            : %s\n' "$LOG_FILE"

trap cleanup_temp_dir EXIT

if [[ -n "$temp_dir" ]]; then
    if (( dry_run == 0 )); then
        mkdir -p "$temp_dir"
    fi
    export TMPDIR="$temp_dir"
fi

if (( clean == 1 )) && [[ -d "$build_path" ]]; then
    safe_clean_build_dir "$build_path" "$source_path"
fi

if (( dry_run == 0 )); then
    mkdir -p "$build_path"
fi

if (( skip_configure == 0 )); then
    configure_args=(
        "$cmake_path"
        -S "$source_path"
        -B "$build_path"
        -G "$generator"
        "-DCMAKE_BUILD_TYPE=$config"
        "-DCUTLASS_NVCC_ARCHS=$resolved_cuda_archs"
        -DCUTLASS_ENABLE_TESTS=OFF
        -DCUTLASS_ENABLE_GTEST_UNIT_TESTS=OFF
        -DCUTLASS_ENABLE_PROFILER_UNIT_TESTS=OFF
        -DCUTLASS_ENABLE_EXAMPLES=OFF
        -DCUTLASS_ENABLE_TOOLS=ON
        -DCUTLASS_ENABLE_LIBRARY=ON
        -DCUTLASS_ENABLE_PROFILER=ON
        -DCUTLASS_ENABLE_PERFORMANCE=ON
        -DCUTLASS_ENABLE_CUBLAS=OFF
        -DCUTLASS_ENABLE_CUDNN=OFF
        "-DCUTLASS_LIBRARY_OPERATIONS=$operations"
    )

    if [[ -n "$resolved_kernels" ]]; then
        configure_args+=("-DCUTLASS_LIBRARY_KERNELS=$resolved_kernels")
    fi

    if [[ -n "${CUDA_HOME:-}" ]]; then
        configure_args+=("-DCUDAToolkit_ROOT=$CUDA_HOME")
    elif [[ -n "${CUDA_PATH:-}" ]]; then
        configure_args+=("-DCUDAToolkit_ROOT=$CUDA_PATH")
    fi

    configure_args+=("${extra_cmake_args[@]}")
    run_logged "Configure CUTLASS" "${configure_args[@]}"
fi

if (( configure_only == 0 )); then
    build_args=(
        "$cmake_path"
        --build "$build_path"
        --target "$target"
        --parallel "$parallel"
    )
    run_logged "Build $target" "${build_args[@]}"

    expected_profiler="$build_path/tools/profiler/cutlass_profiler"
    if [[ -x "$expected_profiler" ]]; then
        printf '\nBuilt profiler: %s\n' "$expected_profiler" | tee -a "$LOG_FILE"
    else
        found_profiler="$(find "$build_path" -type f -name cutlass_profiler -perm -u+x 2>/dev/null | head -n 1 || true)"
        if [[ -n "$found_profiler" ]]; then
            printf '\nBuilt profiler: %s\n' "$found_profiler" | tee -a "$LOG_FILE"
        else
            {
                printf '\nBuild completed, but expected profiler path was not found:\n'
                printf '%s\n' "$expected_profiler"
                printf 'Search the build directory for cutlass_profiler if the generator used a different output path.\n'
            } | tee -a "$LOG_FILE"
        fi
    fi
fi

printf '\nDone. Log: %s\n' "$LOG_FILE"
