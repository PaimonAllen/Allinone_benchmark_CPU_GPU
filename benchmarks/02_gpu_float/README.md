# 02_gpu_float

GPU floating-point throughput benchmarks.

Typical contents:

- CUTLASS profiler runs for FP16, BF16, TF32, FP8, FP4, FP32, or FP64 when
  supported by the installed GPU and toolkit.
- cuBLAS or cuBLASLt GEMM benchmarks.
- PyTorch, CuPy, or custom CUDA GEMM microbenchmarks.
- Notes distinguishing Tensor Core paths, CUDA Core paths, and software or
  fallback paths.

Current implementations:

- `Windows/00_git_clone_cutlass_3_8_0.ps1` clones or updates the external
  CUTLASS 3.8.0 source tree.
- `Windows/01_build_cutlass_3_8_0.ps1` builds the local CUTLASS 3.8.0 profiler
  for the FP4/FP8/FP16/FP32/TF32/FP64 GEMM subset supported by the current
  build and GPU.
- `Windows/02_run_cutlass_3_8_0_benchmark.ps1` runs that profiler and saves raw
  logs, CSV results, environment metadata, command lines, unsupported-case
  details, and a short Markdown report.
- `Linux/00_git_clone_cutlass_4_5_1.sh` clones or updates the external CUTLASS
  4.5.1 source tree.
- `Linux/01_build_cutlass_4_5_1.sh` builds the local CUTLASS 4.5.1 profiler for
  Linux with CUDA architecture and supported FP16/FP32/FP64/TF32/FP8/FP4 kernel
  defaults inferred from `nvidia-smi` when available.
- `Linux/02_run_cutlass_4_5_1_benchmark.sh` runs that profiler and saves raw logs,
  CSV results, environment metadata, command lines, and a short Markdown report.
