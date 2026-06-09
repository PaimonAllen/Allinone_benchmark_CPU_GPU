# Windows CPU Float Benchmark

This directory contains the Windows entry points for CPU floating-point GEMM
benchmarking. The default conda environment is `cudadev`. The prepare step
verifies that this environment uses OpenBLAS for NumPy BLAS calls, so the
benchmark does not accidentally run against MKL or user-site packages. It never
creates or modifies conda environments.

## Script order

| order | script | purpose |
|---:|---|---|
| 01 | `01_prepare_openblas_numpy_env.ps1` | Select and verify an existing conda OpenBLAS + NumPy environment. |
| 02 | `02_run_openblas_numpy_benchmark.ps1` | Run CPU floating-point GEMM and require the detected BLAS backend to be OpenBLAS. |

## Prepare

Verify the default OpenBLAS environment:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\01_prepare_openblas_numpy_env.ps1
```

If `cudadev` does not exist, the script lists the local conda environments and
prompts for an existing environment name. If the default does not exist, enter
one of the listed environment names.

Useful prepare options:

```powershell
.\01_prepare_openblas_numpy_env.ps1 -VerifyOnly
.\01_prepare_openblas_numpy_env.ps1 -EnvName cudadev
.\01_prepare_openblas_numpy_env.ps1 -DryRun
```

The prepare script verifies that `threadpoolctl` reports `internal_api:
openblas` with `PYTHONNOUSERSITE=1`. It does not install packages. If the
selected environment is not OpenBLAS-backed, prepare that environment manually
or rerun the script with another existing environment name.

After a successful verification, the selected environment is saved to
`selected_env.json` in this directory. This file is local machine state and is
ignored by git.

## Run

Run the default Windows CPU float benchmark:

```powershell
.\02_run_openblas_numpy_benchmark.ps1
```

When `-CondaEnv` is not provided, the run script first reads
`selected_env.json`. If that file is missing or invalid, it falls back to
`cudadev`. Passing `-CondaEnv <name>` overrides the JSON.

Quick smoke test:

```powershell
.\02_run_openblas_numpy_benchmark.ps1 -Sizes 128 -Threads 1,2 -RepeatCount 1 -WarmupIterations 0 -ProfilingIterations 1
```

Useful options:

```powershell
.\02_run_openblas_numpy_benchmark.ps1 -Sizes 1024,2048,4096
.\02_run_openblas_numpy_benchmark.ps1 -FallbackSizes 256,512
.\02_run_openblas_numpy_benchmark.ps1 -Precisions ALL_KNOWN
.\02_run_openblas_numpy_benchmark.ps1 -Precisions ALL
.\02_run_openblas_numpy_benchmark.ps1 -Precisions FP32
.\02_run_openblas_numpy_benchmark.ps1 -Precisions FP64
.\02_run_openblas_numpy_benchmark.ps1 -Threads 1,8,32
.\02_run_openblas_numpy_benchmark.ps1 -RepeatCount 5 -WarmupIterations 2 -ProfilingIterations 3
.\02_run_openblas_numpy_benchmark.ps1 -CondaEnv cudadev
.\02_run_openblas_numpy_benchmark.ps1 -DryRun
```

Default run settings:

- conda environment: `cudadev`;
- precisions: `ALL_KNOWN`, which records FP4/FP8 as unsupported on the standard
  NumPy/OpenBLAS CPU path and benchmarks FP16/FP32/FP64/FP128 when available;
- BLAS sizes for FP32/FP64: `1024,2048,4096`;
- fallback sizes for FP16/FP128: `256,512`;
- thread sweep: `1,8,<full logical processors>`;
- repeats: `5`, with `2` warmup iterations and `3` timed profiling iterations
  per repeat.

By default, a conda run uses `PYTHONNOUSERSITE=1`. Use `-AllowUserSite` only
when intentionally testing user-site packages.

To benchmark a different BLAS backend such as MKL, explicitly disable the
OpenBLAS requirement:

```powershell
.\02_run_openblas_numpy_benchmark.ps1 -CondaEnv base -AllowAnyBlas
```

Results are written to `runs/<timestamp>_<host>_windows/`:

- `summary_openblas_numpy_gemm.csv`: required raw rows with backend, precision,
  matrix size, threads, runtime, and GFLOPS;
- `summary_openblas_numpy_gemm_grouped.csv`: average and best rows grouped by
  backend, precision, size, and thread count;
- `unsupported_cases.csv`: precision cases that the current CPU/NumPy/BLAS path
  cannot execute;
- `metadata.json`: host, Python, NumPy, BLAS, and thread environment metadata;
- `report.md`: short Markdown report.
- `selected_env.json`: environment selection state used by this run.
- `windows_cpu_info.json` and `windows_os_info.json`: Windows CIM metadata.

Console output is also saved under `logs/`.
