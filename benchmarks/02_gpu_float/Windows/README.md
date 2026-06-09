# Windows CUTLASS Builds

This directory contains Windows-specific helper scripts for GPU floating-point
benchmarks.

## CUTLASS 3.8.0

Build the CUTLASS profiler for the local RTX 4070 Ti class GPU:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\build_cutlass_3_8_0.ps1
```

The default source directory is `.\cutlass-3.8.0`, the default build directory is
`C:\cutlass_build\cutlass_3_8_0`, and the default CUDA architecture is `89`.

The build script defaults to `-Operations gemm`, `-Kernels sgemm,tf32gemm`,
`-Parallel 23`, and `-TempDir C:\cutlass_tmp`. This is intentional: the default
build covers the local FP32/TF32 GEMM benchmark path and avoids the Conv2d/Conv3d
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
.\build_cutlass_3_8_0.ps1 -Clean
.\build_cutlass_3_8_0.ps1 -ConfigureOnly
.\build_cutlass_3_8_0.ps1 -Generator Ninja -BuildDir .\cutlass-3.8.0\build-ninja
.\build_cutlass_3_8_0.ps1 -CudaArchs 89 -Target cutlass_profiler -Parallel 8
.\build_cutlass_3_8_0.ps1 -Clean -Parallel 23 -TempDir C:\cutlass_tmp
.\build_cutlass_3_8_0.ps1 -Parallel 1
.\build_cutlass_3_8_0.ps1 -KeepTempDir
.\build_cutlass_3_8_0.ps1 -Kernels ""
.\build_cutlass_3_8_0.ps1 -Operations all -Kernels ""
```

Logs are written to `logs/`.

## Run the local CUTLASS GEMM benchmark

After the profiler is built, run:

```powershell
.\run_cutlass_3_8_0_benchmark.ps1
```

The run script records:

- raw profiler stdout logs under `runs\<timestamp>_<host>_windows\raw\`;
- machine-readable CUTLASS CSV files under `runs\<timestamp>_<host>_windows\csv\`;
- merged GEMM results in `summary_cutlass_gemm.csv`;
- a short benchmark report in `report.md`;
- `nvidia-smi`, topology probe notes when `nvidia-smi topo` is unsupported on
  Windows, `nvcc --version`, CUTLASS device-info, metadata, and exact command
  lines.

The default benchmark cases match the default build: FP32 SGEMM on CUDA cores
and TF32 GEMM on Tensor Cores for square sizes `1024`, `2048`, and `4096`.
Each case runs `3` repeats, with `10` warmup iterations and `50` profiling
iterations per profiler kernel.

`report.md` summarizes the metadata required by the benchmark plan and reports,
for each precision and matrix size, the average and maximum of the fastest
kernel found in each repeat.

Useful options:

```powershell
.\run_cutlass_3_8_0_benchmark.ps1 -DryRun -Sizes 128 -ProfilingIterations 1 -WarmupIterations 0
.\run_cutlass_3_8_0_benchmark.ps1 -BuildDir C:\cutlass_build\cutlass_3_8_0_p23
.\run_cutlass_3_8_0_benchmark.ps1 -Sizes 1024,2048,4096,8192
.\run_cutlass_3_8_0_benchmark.ps1 -RepeatCount 5 -ProfilingIterations 100
.\run_cutlass_3_8_0_benchmark.ps1 -Precisions FP32
.\run_cutlass_3_8_0_benchmark.ps1 -Precisions TF32
.\run_cutlass_3_8_0_benchmark.ps1 -Quiet
```

This is the CUTLASS profiler part of the GPU floating-point plan. cuBLAS,
cuBLASLt, PyTorch/CuPy, and additional precisions should be added as separate
benchmark scripts so their dependencies and result formats stay isolated.
