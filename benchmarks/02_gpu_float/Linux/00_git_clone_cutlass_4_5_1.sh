#!/usr/bin/env bash
# Clone or update the local CUTLASS 4.5.1 source tree on Linux.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

repo_url="${REPO_URL:-https://github.com/NVIDIA/cutlass.git}"
tag="${TAG:-v4.5.1}"
source_dir="${SOURCE_DIR:-$SCRIPT_DIR/cutlass-4.5.1}"
log_dir="${LOG_DIR:-$SCRIPT_DIR/logs}"
update=0
force=0
dry_run=0

usage() {
    cat <<'USAGE'
Usage: ./00_git_clone_cutlass_4_5_1.sh [options]

Options:
  --repo-url URL      CUTLASS git URL. Default: https://github.com/NVIDIA/cutlass.git
  --tag TAG           CUTLASS tag or branch. Default: v4.5.1
  --source-dir PATH   Source directory. Default: ./cutlass-4.5.1
  --log-dir PATH      Log directory. Default: ./logs
  --update            Fetch tags, check out --tag again, and update submodules
  --force             Replace an invalid non-empty source directory
  --dry-run           Print commands without executing git changes
  -h, --help          Show this help
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

run_cmd() {
    printf '+ %s\n' "$(quote_cmd "$@")"
    if (( dry_run )); then
        return 0
    fi

    "$@"
}

is_git_checkout() {
    [[ -e "$1/.git" ]]
}

is_cutlass_source() {
    [[ -f "$1/CMakeLists.txt" && -f "$1/tools/profiler/CMakeLists.txt" ]]
}

is_empty_dir() {
    [[ -d "$1" ]] || return 1
    [[ -z "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit)" ]]
}

assert_safe_source_dir() {
    local full root base
    full="$(real_path_m "$1")"
    root="$(real_path_m "$SCRIPT_DIR")"
    base="$(basename "$full")"

    [[ "$base" == cutlass-* ]] || die "refusing to remove directory whose leaf name is not cutlass-*: $full"
    case "$full" in
        "$root"/*) ;;
        *) die "refusing to remove source directory outside this script directory: $full" ;;
    esac

    printf '%s\n' "$full"
}

remove_source_dir() {
    local full
    full="$(assert_safe_source_dir "$1")"
    printf 'Removing invalid source directory: %s\n' "$full"
    run_cmd rm -rf -- "$full"
}

clone_cutlass() {
    local destination parent
    destination="$(real_path_m "$1")"
    parent="$(dirname "$destination")"
    [[ -d "$parent" ]] || run_cmd mkdir -p -- "$parent"

    run_cmd git clone --branch "$tag" --depth 1 --recurse-submodules "$repo_url" "$destination"
    run_cmd git -C "$destination" submodule sync --recursive
    run_cmd git -C "$destination" submodule update --init --recursive --depth 1
}

update_cutlass() {
    local path
    path="$(real_path_m "$1")"
    run_cmd git -C "$path" fetch --tags --force origin
    run_cmd git -C "$path" checkout --detach "$tag"
    run_cmd git -C "$path" submodule sync --recursive
    run_cmd git -C "$path" submodule update --init --recursive --depth 1
}

while (($#)); do
    case "$1" in
        --repo-url)
            (($# >= 2)) || die "--repo-url requires a value"
            repo_url="$2"
            shift 2
            ;;
        --tag)
            (($# >= 2)) || die "--tag requires a value"
            tag="$2"
            shift 2
            ;;
        --source-dir)
            (($# >= 2)) || die "--source-dir requires a value"
            source_dir="$2"
            shift 2
            ;;
        --log-dir)
            (($# >= 2)) || die "--log-dir requires a value"
            log_dir="$2"
            shift 2
            ;;
        --update)
            update=1
            shift
            ;;
        --force)
            force=1
            shift
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

[[ -n "$repo_url" ]] || die "--repo-url cannot be empty"
[[ -n "$tag" ]] || die "--tag cannot be empty"
[[ -n "$source_dir" ]] || die "--source-dir cannot be empty"
[[ -n "$log_dir" ]] || die "--log-dir cannot be empty"

mkdir -p -- "$log_dir"
timestamp="$(date +%Y%m%d_%H%M%S)"
log_file="$log_dir/git_clone_cutlass_4_5_1_${timestamp}.log"
exec > >(tee -a "$log_file") 2>&1

have_command git || die "required command not found in PATH: git"

source_full_path="$(real_path_m "$source_dir")"

printf 'CUTLASS repo   : %s\n' "$repo_url"
printf 'CUTLASS tag    : %s\n' "$tag"
printf 'Source dir     : %s\n' "$source_full_path"
printf 'Git executable : %s\n' "$(command -v git)"
printf 'Log file       : %s\n' "$log_file"
if (( dry_run )); then
    printf 'Dry run        : enabled\n'
fi

if [[ ! -e "$source_full_path" ]]; then
    printf 'Source directory does not exist. Cloning CUTLASS.\n'
    clone_cutlass "$source_full_path"
elif is_git_checkout "$source_full_path"; then
    current="$(git -C "$source_full_path" describe --tags --always --dirty 2>/dev/null || git -C "$source_full_path" rev-parse --short HEAD 2>/dev/null || true)"
    printf 'Existing git source found. Current revision: %s\n' "${current:-unknown}"

    if (( update )); then
        update_cutlass "$source_full_path"
    else
        printf 'Use --update to fetch and check out %s again.\n' "$tag"
    fi
elif is_cutlass_source "$source_full_path"; then
    printf 'Existing non-git CUTLASS source tree found. Leaving it untouched.\n'
    printf 'Use --force only if you want to replace this directory with a fresh clone.\n'
elif is_empty_dir "$source_full_path"; then
    printf 'Existing source directory is empty. Cloning CUTLASS into it.\n'
    clone_cutlass "$source_full_path"
elif (( force )); then
    remove_source_dir "$source_full_path"
    clone_cutlass "$source_full_path"
else
    die "source directory exists but is not a valid CUTLASS tree: $source_full_path. Remove/fix it or rerun with --force."
fi

if (( dry_run )); then
    printf 'Dry run complete. Source directory was not modified.\n'
else
    if ! is_cutlass_source "$source_full_path"; then
        die "CUTLASS source verification failed. Missing CMakeLists.txt or tools/profiler/CMakeLists.txt in $source_full_path"
    fi

    printf 'CUTLASS source is ready: %s\n' "$source_full_path"
fi

printf 'Log saved to: %s\n' "$log_file"
