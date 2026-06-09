# 02_gpu_float

GPU floating-point throughput benchmarks.

Typical contents:

- CUTLASS profiler runs for FP16, BF16, TF32, FP8, FP4, FP32, or FP64 when
  supported by the installed GPU and toolkit.
- cuBLAS or cuBLASLt GEMM benchmarks.
- PyTorch, CuPy, or custom CUDA GEMM microbenchmarks.
- Notes distinguishing Tensor Core paths, CUDA Core paths, and software or
  fallback paths.
