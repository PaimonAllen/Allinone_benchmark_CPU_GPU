# 03_cpu_bandwidth

CPU memory and cache bandwidth benchmarks.

## Current Coverage

| order | area | Linux | Windows | output |
|---:|---|---|---|---|
| 03 | CPU memory bandwidth through STREAM | `Linux/00_get_stream_source.sh`, `Linux/01_build_stream.sh`, `Linux/02_run_stream_benchmark.sh` | `Windows/00_get_stream_source.ps1`, `Windows/01_build_stream.ps1`, `Windows/02_run_stream_benchmark.ps1` | `function, threads, MB/s, GB/s, time_s` |

The Linux and Windows implementations use the STREAM C benchmark to measure
main-memory Copy, Scale, Add, and Triad bandwidth with 64-bit `double` data by
default.

## Run

```bash
cd benchmarks/03_cpu_bandwidth/Linux
./00_get_stream_source.sh
./01_build_stream.sh
./02_run_stream_benchmark.sh
```

```powershell
cd benchmarks\03_cpu_bandwidth\Windows
Set-ExecutionPolicy -Scope Process Bypass
.\00_get_stream_source.ps1
.\01_build_stream.ps1
.\02_run_stream_benchmark.ps1
```

Each run writes a timestamped directory containing raw STREAM stdout logs,
parsed CSV files, system metadata, exact command lines, and `report.md`.

## Planned additions

- LIKWID-bench or equivalent cache and memory hierarchy bandwidth tests.
- Optional NUMA-local and NUMA-interleaved comparison presets.
