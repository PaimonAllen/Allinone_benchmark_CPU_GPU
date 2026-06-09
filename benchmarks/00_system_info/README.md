# 00_system_info

Hardware and software environment snapshots.

This stage follows the first execution stage in
`Docs/cpu_gpu_benchmark_tool_plan.md`: collect CPU, memory, NUMA, GPU, CUDA,
PCIe, compiler, and runtime environment information before running benchmarks.

## Scripts

Windows:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\collect_windows_system_info.ps1
```

Linux or WSL:

```bash
bash ./collect_linux_system_info.sh
```

Both scripts create a timestamped run directory under `runs/` by default. To
write elsewhere:

```powershell
.\collect_windows_system_info.ps1 -OutputRoot E:\benchmark_runs\system_info
```

```bash
OUTPUT_ROOT=/tmp/benchmark_runs/system_info bash ./collect_linux_system_info.sh
```

## Typical Contents

- CPU, memory, NUMA, OS, and compiler information.
- GPU, driver, CUDA runtime, CUDA toolkit, and PCIe information.
- Raw outputs from commands such as `lscpu`, `nvidia-smi`, `nvcc --version`,
  `deviceQuery`, and platform-specific equivalents.
