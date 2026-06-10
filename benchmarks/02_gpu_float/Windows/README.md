# Windows CUTLASS Builds

This directory contains Windows-specific helper scripts for GPU floating-point
benchmarks.

## Script order

| order | script | purpose |
|---:|---|---|
| 01 | `01_build_cutlass_3_8_0.ps1` | Configure and build CUTLASS 3.8.0. |
| 02 | `02_run_cutlass_3_8_0_benchmark.ps1` | Run the CUTLASS GEMM benchmark and write reports. |

## CUTLASS 3.8.0

Build the CUTLASS profiler for the local RTX 4070 Ti class GPU:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\01_build_cutlass_3_8_0.ps1
```

The default source directory is `.\cutlass-3.8.0`, the default build directory is
`C:\cutlass_build\cutlass_3_8_0`, and the default CUDA architecture is `89`.

The build script defaults to `-Operations gemm`,
`-Kernels sgemm,tf32gemm,16816,dgemm,e4m3,e5m2,e2m1`, `-Parallel 23`, and
`-TempDir C:\cutlass_tmp`. This is intentional: the default build covers the
local FP32, TF32, FP16, FP8, and FP64 GEMM benchmark paths, includes the FP4
kernel filter for architectures that support it, and avoids the Conv2d/Conv3d
targets whose generated Visual Studio paths can exceed what the CUDA/MSBuild
toolchain handles reliably.

After a successful build, the script copies generated CUTLASS runtime DLLs next
to `cutlass_profiler.exe` so the profiler can run directly from its output
directory.

The dedicated temp directory is cleaned when `-Clean` is used and again when the
script exits. Use `-KeepTempDir` if you need to preserve NVCC intermediate files
for compiler debugging.

Useful options:

```powershell
.\01_build_cutlass_3_8_0.ps1 -Clean
.\01_build_cutlass_3_8_0.ps1 -ConfigureOnly
.\01_build_cutlass_3_8_0.ps1 -Generator Ninja -BuildDir .\cutlass-3.8.0\build-ninja
.\01_build_cutlass_3_8_0.ps1 -CudaArchs 89 -Target cutlass_profiler -Parallel 8
.\01_build_cutlass_3_8_0.ps1 -Clean -Parallel 23 -TempDir C:\cutlass_tmp
.\01_build_cutlass_3_8_0.ps1 -Parallel 1
.\01_build_cutlass_3_8_0.ps1 -KeepTempDir
.\01_build_cutlass_3_8_0.ps1 -Kernels ""
.\01_build_cutlass_3_8_0.ps1 -Operations all -Kernels ""
```

Logs are written to `logs/`.
If the build fails, the script prints the original failure, the log path, and the
last 80 log lines. Check the newest `logs/cutlass_3_8_0_*.log` file for the
underlying CMake, MSBuild, NVCC, or Visual Studio error.

## Run the local CUTLASS GEMM benchmark

After the profiler is built, run:

```powershell
.\02_run_cutlass_3_8_0_benchmark.ps1
```

The run script records:

- raw profiler stdout logs under `runs\<timestamp>_<host>_windows\raw\`;
- machine-readable CUTLASS CSV files under `runs\<timestamp>_<host>_windows\csv\`;
- merged GEMM results in `summary_cutlass_gemm.csv`;
- skipped or unsupported precision cases in `unsupported_cases.csv`;
- a short benchmark report in `report.md`;
- `nvidia-smi`, topology probe notes when `nvidia-smi topo` is unsupported on
  Windows, `nvcc --version`, CUTLASS device-info, metadata, and exact command
  lines.

The default benchmark cases match the default build: FP4 Tensor Core, FP8 E4M3
Tensor Core, FP8 E5M2 Tensor Core, FP16 Tensor Core, TF32 Tensor Core, FP32
CUDA-core SGEMM, and FP64 CUDA-core DGEMM for square sizes `1024`, `2048`, and
`4096`. Each case runs `3` repeats, with `10` warmup iterations and `50`
profiling iterations per profiler kernel. Unsupported cases are skipped after a
dry-run probe and recorded in both `unsupported_cases.csv` and `report.md`.
For the local RTX 4070 Ti (SM 89), FP4 is expected to be skipped because the
CUTLASS 3.8.0 FP4 GEMM path is SM100+.

`report.md` summarizes the metadata required by the benchmark plan and reports,
for each precision and matrix size, the average and maximum of the fastest
kernel found in each repeat.

Useful options:

```powershell
.\02_run_cutlass_3_8_0_benchmark.ps1 -DryRun -Sizes 128 -ProfilingIterations 1 -WarmupIterations 0
.\02_run_cutlass_3_8_0_benchmark.ps1 -BuildDir C:\cutlass_build\cutlass_3_8_0_p23
.\02_run_cutlass_3_8_0_benchmark.ps1 -Sizes 1024,2048,4096,8192
.\02_run_cutlass_3_8_0_benchmark.ps1 -RepeatCount 5 -ProfilingIterations 100
.\02_run_cutlass_3_8_0_benchmark.ps1 -Precisions FP32
.\02_run_cutlass_3_8_0_benchmark.ps1 -Precisions TF32
.\02_run_cutlass_3_8_0_benchmark.ps1 -Precisions FP8
.\02_run_cutlass_3_8_0_benchmark.ps1 -Precisions FP4,FP8,FP16,FP64
.\02_run_cutlass_3_8_0_benchmark.ps1 -Quiet
```

This is the CUTLASS profiler part of the GPU floating-point plan. cuBLAS,
cuBLASLt, PyTorch/CuPy, and other providers should be added as separate
benchmark scripts so their dependencies and result formats stay isolated.

