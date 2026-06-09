# 01_cpu_float

CPU floating-point throughput benchmarks.

Typical contents:

- FP32 and FP64 GEMM benchmarks with OpenBLAS, oneMKL, BLIS, or similar BLAS
  backends.
- FP64 HPL or LINPACK runs.
- FP128 software floating-point benchmarks using `__float128`, `libquadmath`,
  or MPFR.
- Notes on thread count, BLAS backend, compiler flags, and NUMA policy.
