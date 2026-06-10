# Windows STREAM CPU Bandwidth Benchmark

This directory contains the Windows STREAM benchmark flow for CPU memory
bandwidth. STREAM measures sustained bandwidth for the standard Copy, Scale,
Add, and Triad vector kernels.

## Script Order

| order | script | purpose |
|---:|---|---|
| 00 | `00_get_stream_source.ps1` | Download `stream.c`. |
| 01 | `01_build_stream.ps1` | Compile STREAM with MSVC and OpenMP. |
| 02 | `02_run_stream_benchmark.ps1` | Run STREAM and write CSV/Markdown reports. |

## Source

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\00_get_stream_source.ps1
```

The script tries the official STREAM source URL first and then the public
GitHub STREAM mirror. Downloaded source is stored under `.\stream-5.10\` and is
ignored by git.

## Build

Default build:

```powershell
.\01_build_stream.ps1
```

Defaults:

- `STREAM_ARRAY_SIZE=100000000`;
- `NTIMES=20`;
- `OFFSET=0`;
- `STREAM_TYPE=double`;
- OpenMP enabled with MSVC `/O2 /openmp`;
- allocation mode is `dynamic`, which builds a patched copy under `.\build\`
  and allocates STREAM arrays from the heap. This avoids the Windows linker
  `LNK1248` image-size limit for the default 100M-element arrays;
- local `unistd.h` and `sys/time.h` compatibility headers are generated under
  `.\build\compat` so the original STREAM source can compile with MSVC.

Useful options:

```powershell
.\01_build_stream.ps1 -ArraySize 50000000 -NTimes 20
.\01_build_stream.ps1 -AllocationMode static -ArraySize 1000000
.\01_build_stream.ps1 -NoOpenMP
.\01_build_stream.ps1 -DryRun
```

## Run

Default run:

```powershell
.\02_run_stream_benchmark.ps1
```

Defaults:

- thread sweep: `1,8,<logical CPU count>`;
- external launch repeats: `1`;
- `OMP_PROC_BIND=close`;
- `OMP_PLACES=cores`.

Useful options:

```powershell
.\02_run_stream_benchmark.ps1 -Threads 1,8,32
.\02_run_stream_benchmark.ps1 -RepeatCount 3
.\02_run_stream_benchmark.ps1 -Binary .\build\stream_double_n100000000_t20_omp.exe
.\02_run_stream_benchmark.ps1 -Quiet
.\02_run_stream_benchmark.ps1 -DryRun
```

Results are written to `runs\<timestamp>_<host>_windows\`:

- `summary_stream.csv`: parsed per-launch STREAM rows;
- `summary_stream_grouped.csv`: grouped average/best rows by thread count and
  STREAM function;
- `report.md`: Markdown report;
- `metadata.txt` and `metadata.json`: run metadata;
- `commands.ps1`: exact commands used for this run;
- `raw\`: raw STREAM stdout logs;
- `metadata\`: Windows CPU, OS, memory, and compiler metadata.

STREAM reports MB/s using its own byte-counting convention. This report also
shows decimal GB/s as `MB/s / 1000`.
