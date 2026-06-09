# 01_cpu_float

CPU floating-point throughput benchmarks.

## Current coverage

| order | area | Windows | Linux | output |
|---:|---|---|---|---|
| 01 | CPU floating-point GEMM through NumPy/OpenBLAS | `Windows/01_prepare_openblas_numpy_env.ps1`, `Windows/02_run_openblas_numpy_benchmark.ps1` | `Linux/01_run_openblas_numpy_benchmark.sh` | `backend, precision, matrix_size, threads, GFLOPS, runtime_ms` |

The first benchmark uses NumPy matrix multiplication and records the BLAS backend
actually linked to the selected Python or conda environment. Windows defaults to
the `cudadev` conda environment and requires OpenBLAS unless `-AllowAnyBlas` is
specified.

## Directory layout

```text
01_cpu_float/
  common/
    openblas_numpy_gemm_benchmark.py
  Windows/
    01_prepare_openblas_numpy_env.ps1
    02_run_openblas_numpy_benchmark.ps1
    logs/
    runs/
  Linux/
    01_run_openblas_numpy_benchmark.sh
    logs/
    runs/
```

## Run

Windows:

```powershell
cd benchmarks\01_cpu_float\Windows
Set-ExecutionPolicy -Scope Process Bypass
.\01_prepare_openblas_numpy_env.ps1
.\02_run_openblas_numpy_benchmark.ps1
```

Linux:

```bash
cd benchmarks/01_cpu_float/Linux
bash ./01_run_openblas_numpy_benchmark.sh
```

The Windows run script defaults to the existing `cudadev` conda environment,
checks FP4/FP8 unsupported cases, and benchmarks FP16/FP32/FP64/FP128 where the
CPU/NumPy path supports them. Linux also accepts an explicit conda environment:

After `Windows/01_prepare_openblas_numpy_env.ps1` verifies an environment, it
writes `Windows/selected_env.json`; `Windows/02_run_openblas_numpy_benchmark.ps1`
uses that environment by default unless `-CondaEnv` is provided.

```bash
bash ./01_run_openblas_numpy_benchmark.sh --conda-env base
```

Use `--no-user-site` on Linux when you need to make sure user-site Python
packages do not shadow the selected conda environment. Windows uses
`PYTHONNOUSERSITE=1` by default for conda runs.

Each run writes a timestamped directory containing raw CSV, grouped CSV,
`metadata.json`, `report.md`, and the exact command line.

## Planned additions

- FP64 HPL or LINPACK runs.
- FP128 software floating-point benchmarks using `__float128`, `libquadmath`, or
  MPFR.
- Optional native OpenBLAS/oneMKL/BLIS C or C++ benchmark binaries for comparing
  against NumPy dispatch overhead.
