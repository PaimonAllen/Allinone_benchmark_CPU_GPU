#!/usr/bin/env bash
# Download the STREAM C benchmark source used by the Linux CPU bandwidth test.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

source_dir="$SCRIPT_DIR/stream-5.10"
source_url="https://www.cs.virginia.edu/stream/FTP/Code/stream.c"
fallback_url="https://raw.githubusercontent.com/jeffhammond/STREAM/master/stream.c"
log_dir="$SCRIPT_DIR/logs"
force=0
dry_run=0

usage() {
    cat <<'USAGE'
Usage: ./00_get_stream_source.sh [options]

Options:
  --source-dir PATH    Source directory. Default: ./stream-5.10
  --source-url URL     Primary stream.c URL. Default: official STREAM source URL
  --fallback-url URL   Fallback stream.c URL. Default: GitHub STREAM mirror
  --log-dir PATH       Log directory. Default: ./logs
  --force              Replace an existing stream.c
  --dry-run            Print actions without downloading
  -h, --help           Show this help
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
    if (( dry_run == 1 )); then
        return 0
    fi
    "$@"
}

validate_stream_source() {
    local path="$1"
    [[ -s "$path" ]] || return 1
    grep -q 'Program: STREAM' "$path" || return 1
    grep -q 'STREAM_ARRAY_SIZE' "$path" || return 1
    grep -q 'Best Rate MB/s' "$path" || return 1
}

download_to_file() {
    local url="$1"
    local output="$2"

    if have_command curl; then
        run_cmd curl -L --fail --retry 3 --connect-timeout 20 --output "$output" "$url"
        return
    fi
    if have_command wget; then
        run_cmd wget -O "$output" "$url"
        return
    fi
    die "curl or wget is required to download stream.c"
}

while (( $# > 0 )); do
    case "$1" in
        --source-dir) source_dir="${2:?Missing value for --source-dir}"; shift 2 ;;
        --source-dir=*) source_dir="${1#*=}"; shift ;;
        --source-url) source_url="${2:?Missing value for --source-url}"; shift 2 ;;
        --source-url=*) source_url="${1#*=}"; shift ;;
        --fallback-url) fallback_url="${2:?Missing value for --fallback-url}"; shift 2 ;;
        --fallback-url=*) fallback_url="${1#*=}"; shift ;;
        --log-dir) log_dir="${2:?Missing value for --log-dir}"; shift 2 ;;
        --log-dir=*) log_dir="${1#*=}"; shift ;;
        --force) force=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

mkdir -p "$log_dir"
timestamp="$(date +%Y%m%d_%H%M%S)"
log_file="$log_dir/get_stream_source_${timestamp}.log"
exec > >(tee -a "$log_file") 2>&1

source_dir="$(real_path_m "$source_dir")"
source_file="$source_dir/stream.c"
metadata_file="$source_dir/source_metadata.txt"

printf 'STREAM source dir : %s\n' "$source_dir"
printf 'Primary URL       : %s\n' "$source_url"
printf 'Fallback URL      : %s\n' "$fallback_url"
printf 'Log file          : %s\n' "$log_file"
if (( dry_run == 1 )); then
    printf 'Dry run           : enabled\n'
fi

if [[ -f "$source_file" && "$force" -eq 0 ]]; then
    validate_stream_source "$source_file" || die "Existing source is not a recognizable STREAM C source: $source_file"
    printf 'Existing STREAM source is ready: %s\n' "$source_file"
    exit 0
fi

if (( dry_run == 1 )); then
    printf 'Dry run complete. Would download stream.c to: %s\n' "$source_file"
    exit 0
fi

run_cmd mkdir -p "$source_dir"
tmp_file="$(mktemp "${TMPDIR:-/tmp}/stream.c.XXXXXX")"
trap 'rm -f "$tmp_file"' EXIT

downloaded_url=""
set +e
download_to_file "$source_url" "$tmp_file"
rc=$?
set -e
if (( rc == 0 )) && validate_stream_source "$tmp_file"; then
    downloaded_url="$source_url"
else
    printf 'Primary download failed or did not validate. Trying fallback.\n'
    set +e
    download_to_file "$fallback_url" "$tmp_file"
    rc=$?
    set -e
    (( rc == 0 )) || die "Could not download STREAM source from primary or fallback URL"
    validate_stream_source "$tmp_file" || die "Downloaded fallback source did not look like STREAM C source"
    downloaded_url="$fallback_url"
fi

if (( dry_run == 0 )); then
    mv "$tmp_file" "$source_file"
    trap - EXIT
    {
        printf 'STREAM C source\n'
        printf 'Downloaded: %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
        printf 'URL: %s\n' "$downloaded_url"
        printf 'Path: %s\n' "$source_file"
        if have_command sha256sum; then
            printf 'SHA256: %s\n' "$(sha256sum "$source_file" | awk '{print $1}')"
        fi
    } > "$metadata_file"
fi

printf 'STREAM source is ready: %s\n' "$source_file"
printf 'Log saved to: %s\n' "$log_file"
