# 02_gpu_float

GPU floating-point throughput benchmarks.

Typical contents:

- CUTLASS profiler runs for FP16, BF16, TF32, FP8, FP4, FP32, or FP64 when
  supported by the installed GPU and toolkit.
- cuBLAS or cuBLASLt GEMM benchmarks.
- PyTorch, CuPy, or custom CUDA GEMM microbenchmarks.
- Notes distinguishing Tensor Core paths, CUDA Core paths, and software or
  fallback paths.

Current Windows implementation:

- `Windows/build_cutlass_3_8_0.ps1` builds the local CUTLASS 3.8.0 profiler
  for the FP32/TF32 GEMM subset.
- `Windows/run_cutlass_3_8_0_benchmark.ps1` runs that profiler and saves raw
  logs, CSV results, environment metadata, command lines, and a short Markdown
  report.
