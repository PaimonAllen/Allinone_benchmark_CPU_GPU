# Linux CPU Float Benchmark

This directory contains the Linux entry points for CPU floating-point GEMM
benchmarking through NumPy and the BLAS backend linked to the selected Python or
conda environment. The default conda environment is `cudadev`.

## Script Order

| order | script | purpose |
|---:|---|---|
| 01 | `01_prepare_openblas_numpy_env.sh` | Verify that an existing conda environment exists and that NumPy reports OpenBLAS. |
| 02 | `02_run_openblas_numpy_benchmark.sh` | Run the full precision/thread/size benchmark sweep. |

## Prepare

```bash
chmod +x ./01_prepare_openblas_numpy_env.sh ./02_run_openblas_numpy_benchmark.sh
./01_prepare_openblas_numpy_env.sh
```

Useful options:

```bash
./01_prepare_openblas_numpy_env.sh --env-name cudadev
./01_prepare_openblas_numpy_env.sh --verify-only
./01_prepare_openblas_numpy_env.sh --no-preload-openblas
./01_prepare_openblas_numpy_env.sh --dry-run
```

The prepare script writes `selected_env.json` after a successful OpenBLAS
verification. The run script uses that environment by default unless
`--conda-env` or `--python` is passed.

On Linux, some conda environments expose NumPy through the generic `libblas`
ABI even when `libopenblas` is installed in the same environment. If direct
verification does not report OpenBLAS, the prepare script automatically retries
with that environment's `libopenblas` through `LD_PRELOAD` and records the path
in `selected_env.json`. The run script reuses that setting for the benchmark.

## Run

Default full run:

```bash
./02_run_openblas_numpy_benchmark.sh
```

The default run uses:

- conda environment: `cudadev`;
- precision request: `ALL_KNOWN`;
- BLAS sizes for FP32/FP64: `1024,2048,4096`;
- fallback sizes for FP16/FP128: `256,512`;
- thread sweep: `1,8,<logical CPU count>`;
- repeats/warmup/profile iterations: `5/2/3`;
- OpenBLAS required unless `--allow-any-blas` is set.

Quick smoke test:

```bash
./02_run_openblas_numpy_benchmark.sh --sizes 128 --fallback-sizes 64 --threads 1 --repeat-count 1 --warmup-iterations 0 --profiling-iterations 1
```

Useful options:

```bash
./02_run_openblas_numpy_benchmark.sh --conda-env cudadev
./02_run_openblas_numpy_benchmark.sh --python /opt/conda/bin/python
./02_run_openblas_numpy_benchmark.sh --precisions FP32,FP64
./02_run_openblas_numpy_benchmark.sh --precisions ALL_KNOWN
./02_run_openblas_numpy_benchmark.sh --threads 1,8,36
./02_run_openblas_numpy_benchmark.sh --allow-any-blas
./02_run_openblas_numpy_benchmark.sh --allow-user-site
./02_run_openblas_numpy_benchmark.sh --dry-run
```

Results are written to `runs/<timestamp>_<host>_linux/`:

- `summary_openblas_numpy_gemm.csv`: raw per-repeat benchmark rows;
- `summary_openblas_numpy_gemm_grouped.csv`: average and best rows grouped by
  backend, precision, size, and thread count;
- `unsupported_cases.csv`: FP4/FP8 and other unsupported or skipped precision
  cases;
- `metadata.json`: host, Python, NumPy, BLAS, and thread environment metadata;
- `linux_cpu_info.txt`, `linux_uname.txt`, and optional NUMA metadata;
- `selected_env.json`: environment state used for the run;
- `command.sh`: exact command line;
- `report.md`: Markdown report.

Console output is also saved under `logs/`.
