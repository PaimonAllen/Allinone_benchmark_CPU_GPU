# Linux CPU Float Benchmark

This directory contains the Linux entry point for CPU FP32/FP64 GEMM
benchmarking. It supports ordinary Python and conda environments.

## Script order

| order | script | purpose |
|---:|---|---|
| 01 | `01_run_openblas_numpy_benchmark.sh` | Run NumPy GEMM through the BLAS backend linked to the selected Python/conda environment. |

## Run

Use the current Python:

```bash
bash ./01_run_openblas_numpy_benchmark.sh
```

Use a named conda environment:

```bash
bash ./01_run_openblas_numpy_benchmark.sh --conda-env base
```

Quick smoke test:

```bash
bash ./01_run_openblas_numpy_benchmark.sh --sizes 128 --threads 1,2 --repeat-count 1 --warmup-iterations 0 --profiling-iterations 1
```

Useful options:

```bash
bash ./01_run_openblas_numpy_benchmark.sh --sizes 1024,2048,4096
bash ./01_run_openblas_numpy_benchmark.sh --precisions FP32
bash ./01_run_openblas_numpy_benchmark.sh --precisions FP64
bash ./01_run_openblas_numpy_benchmark.sh --threads 1,2,4,8,16,24
bash ./01_run_openblas_numpy_benchmark.sh --repeat-count 5 --profiling-iterations 5
bash ./01_run_openblas_numpy_benchmark.sh --python /opt/conda/bin/python
bash ./01_run_openblas_numpy_benchmark.sh --conda-env base --no-user-site
bash ./01_run_openblas_numpy_benchmark.sh --dry-run
```

The same settings can be supplied by environment variables:

```bash
CONDA_ENV=base SIZES=2048,4096 THREADS=1,8,16 bash ./01_run_openblas_numpy_benchmark.sh
```

Use `--no-user-site` or `NO_USER_SITE=1` when you want to prevent user-site
packages from shadowing the selected conda environment.

To create a dedicated conda OpenBLAS environment:

```bash
conda create -n cpu-openblas -c conda-forge python=3.12 numpy threadpoolctl "libblas=*=*openblas"
bash ./01_run_openblas_numpy_benchmark.sh --conda-env cpu-openblas --no-user-site
```

Results are written to `runs/<timestamp>_<host>_linux/`:

- `summary_openblas_numpy_gemm.csv`: required raw rows with backend, precision,
  matrix size, threads, runtime, and GFLOPS;
- `summary_openblas_numpy_gemm_grouped.csv`: average and best rows grouped by
  backend, precision, size, and thread count;
- `metadata.json`: host, Python, NumPy, BLAS, and thread environment metadata;
- `report.md`: short Markdown report.

Console output is also saved under `logs/`.
