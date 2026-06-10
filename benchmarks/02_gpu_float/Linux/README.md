# Linux CUTLASS Builds

This directory contains Linux-specific helper scripts for GPU floating-point
benchmarks.

## Script order

| order | script | purpose |
|---:|---|---|
| 00 | `00_git_clone_cutlass_4_5_1.sh` | Clone or update the external CUTLASS 4.5.1 source tree. |
| 01 | `01_build_cutlass_4_5_1.sh` | Configure and build CUTLASS 4.5.1. |
| 02 | `02_run_cutlass_4_5_1_benchmark.sh` | Run the CUTLASS GEMM benchmark and write reports. |

## CUTLASS 4.5.1

Build the local CUTLASS profiler:

```bash
chmod +x ./00_git_clone_cutlass_4_5_1.sh ./01_build_cutlass_4_5_1.sh ./02_run_cutlass_4_5_1_benchmark.sh
./00_git_clone_cutlass_4_5_1.sh
./01_build_cutlass_4_5_1.sh
```

The default source directory is `./cutlass-4.5.1`, the default build directory
is `./cutlass-4.5.1/build`, and the default CUDA architecture is detected from
`nvidia-smi`. If detection is unavailable, the script falls back to `89`.

The clone script is safe to run repeatedly. It clones
`https://github.com/NVIDIA/cutlass.git` at tag `v4.5.1` only when the source
directory is missing or empty. Use `--update` to fetch and check out the tag
again, `--force` to replace an invalid non-empty source directory, and
`--dry-run` to preview git commands.

The build script defaults to `--operations gemm`, `--kernels auto`, and a
parallelism level from `CMAKE_BUILD_PARALLEL_LEVEL` or the local CPU count.
`--kernels auto` builds the CUDA-core FP32/FP64 kernels plus Tensor Core kernels
supported by the detected architecture: FP16 on SM70+, TF32 and FP64 Tensor Core
on SM80+, FP8 on SM89+, and FP4 block-scaled kernels on SM100+.

Useful options:

```bash
./01_build_cutlass_4_5_1.sh --clean
./01_build_cutlass_4_5_1.sh --configure-only
./01_build_cutlass_4_5_1.sh --generator "Unix Makefiles" --build-dir /tmp/cutlass_build/cutlass_4_5_1
./01_build_cutlass_4_5_1.sh --cuda-archs 70 --kernels 'sgemm,dgemm,h884gemm_[0-9]' --parallel 8
./01_build_cutlass_4_5_1.sh --cuda-archs 89 --kernels 'sgemm,dgemm,h1688gemm_[0-9],tf32gemm,gemm_f8'
./01_build_cutlass_4_5_1.sh --operations all --kernels ""
./01_build_cutlass_4_5_1.sh --dry-run
```

Logs are written to `logs/`.

## Run the local CUTLASS GEMM benchmark

After the profiler is built, run:

```bash
./02_run_cutlass_4_5_1_benchmark.sh
```

The run script records:

- raw profiler stdout logs under `runs/<timestamp>_<host>_linux/raw/`;
- machine-readable CUTLASS CSV files under `runs/<timestamp>_<host>_linux/csv/`;
- merged GEMM results in `summary_cutlass_gemm.csv`;
- a short benchmark report in `report.md`;
- `nvidia-smi`, `nvidia-smi topo -m`, `nvcc --version`, `lscpu`,
  CUTLASS device info, metadata, and exact command lines.

The default benchmark precision set is `auto`, which requests FP4, FP8, FP16,
FP32, TF32, and FP64. The run script executes the cases supported by the
detected GPU and records unsupported cases in `unsupported_cases.tsv` and
`report.md`.

Support matrix:

| precision request | benchmark path | minimum architecture |
|---|---|---|
| FP4 | block-scaled Tensor Core GEMM | SM100+ |
| FP8 | Tensor Core GEMM | SM89+ |
| FP16 | Tensor Core GEMM | SM70+ |
| FP32 | CUDA-core SGEMM | any CUDA GPU with CUTLASS support |
| TF32 | Tensor Core GEMM for FP32 inputs | SM80+ |
| FP64 | CUDA-core DGEMM | any CUDA GPU with FP64 support |
| FP64 | Tensor Core DGEMM | SM80+ |

On Tesla V100 / SM70, the default run executes FP16 Tensor Core, FP32 CUDA core,
and FP64 CUDA core cases. TF32, FP8, FP4, and FP64 Tensor Core are marked as
unsupported for that GPU. Default square sizes are `1024`, `2048`, and `4096`.
Each case runs `3` repeats, with `10` warmup iterations and `50` profiling
iterations per profiler kernel.

Useful options:

```bash
./02_run_cutlass_4_5_1_benchmark.sh --dry-run --sizes 128 --profiling-iterations 1 --warmup-iterations 0
./02_run_cutlass_4_5_1_benchmark.sh --build-dir /tmp/cutlass_build/cutlass_4_5_1
./02_run_cutlass_4_5_1_benchmark.sh --sizes 1024,2048,4096,8192
./02_run_cutlass_4_5_1_benchmark.sh --repeat-count 5 --profiling-iterations 100
./02_run_cutlass_4_5_1_benchmark.sh --precisions fp32
./02_run_cutlass_4_5_1_benchmark.sh --precisions fp16,fp32,fp64
./02_run_cutlass_4_5_1_benchmark.sh --precisions fp4,fp8,fp16,fp32,tf32,fp64
./02_run_cutlass_4_5_1_benchmark.sh --quiet
```

This is the CUTLASS profiler part of the GPU floating-point plan. cuBLAS,
cuBLASLt, PyTorch/CuPy, and framework-level benchmarks should be added as
separate benchmark scripts so their dependencies and result formats stay
isolated.
