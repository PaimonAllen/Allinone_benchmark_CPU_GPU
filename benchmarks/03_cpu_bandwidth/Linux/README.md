# Linux STREAM CPU Bandwidth Benchmark

This directory contains the Linux STREAM benchmark flow for CPU memory
bandwidth. STREAM measures sustained bandwidth for the standard Copy, Scale,
Add, and Triad vector kernels.

## Script Order

| order | script | purpose |
|---:|---|---|
| 00 | `00_get_stream_source.sh` | Download `stream.c`. |
| 01 | `01_build_stream.sh` | Compile STREAM with OpenMP. |
| 02 | `02_run_stream_benchmark.sh` | Run STREAM and write CSV/Markdown reports. |

## Source

```bash
chmod +x ./00_get_stream_source.sh ./01_build_stream.sh ./02_run_stream_benchmark.sh
./00_get_stream_source.sh
```

The script tries the official STREAM source URL first and then the public
GitHub STREAM mirror. Downloaded source is stored under `./stream-5.10/` and is
ignored by git.

## Build

Default build:

```bash
./01_build_stream.sh
```

Defaults:

- `STREAM_ARRAY_SIZE=100000000`;
- `NTIMES=20`;
- `OFFSET=0`;
- `STREAM_TYPE=double`;
- OpenMP enabled with `-O3 -fopenmp`;
- `-mcmodel=medium` on x86_64 for large static arrays.

Useful options:

```bash
./01_build_stream.sh --array-size 50000000 --ntimes 20
./01_build_stream.sh --cc clang --cflag -march=native
./01_build_stream.sh --no-openmp
./01_build_stream.sh --dry-run
```

## Run

Default run:

```bash
./02_run_stream_benchmark.sh
```

Defaults:

- thread sweep: `1,8,<logical CPU count>`;
- external launch repeats: `1`;
- `OMP_PROC_BIND=close`;
- `OMP_PLACES=cores`;
- no NUMA binding unless requested.

Useful options:

```bash
max_threads="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc)"
./02_run_stream_benchmark.sh --threads "1,8,$max_threads"
./02_run_stream_benchmark.sh --repeat-count 3
./02_run_stream_benchmark.sh --interleave-all
./02_run_stream_benchmark.sh --numactl-args "--cpunodebind=0 --membind=0"
./02_run_stream_benchmark.sh --binary ./build/stream_double_n100000000_t20_omp
./02_run_stream_benchmark.sh --quiet
```

Results are written to `runs/<timestamp>_<host>_linux/`:

- `summary_stream.csv`: parsed per-launch STREAM rows;
- `summary_stream_grouped.csv`: grouped average/best rows by thread count and
  STREAM function;
- `report.md`: Markdown report;
- `metadata.txt` and `metadata.json`: run metadata;
- `commands.sh`: exact commands used for this run;
- `raw/`: raw STREAM stdout logs;
- `metadata/`: `lscpu`, `free`, `numactl`, `uname`, `ldd`, and OS metadata.

STREAM reports MB/s using its own byte-counting convention. This report also
shows decimal GB/s as `MB/s / 1000`.
