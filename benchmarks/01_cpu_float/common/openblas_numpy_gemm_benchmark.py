#!/usr/bin/env python3
"""CPU floating-point GEMM benchmark using NumPy and its linked BLAS backend."""

from __future__ import annotations

import argparse
import contextlib
import csv
import io
import json
import math
import os
import platform
import socket
import statistics
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PRECISION_ORDER = {
    "FP4": 10,
    "FP8_E4M3": 20,
    "FP8_E5M2": 21,
    "FP16": 30,
    "FP32": 40,
    "FP64": 50,
    "FP128": 60,
}


def parse_csv_ints(value: str, name: str) -> list[int]:
    items: list[int] = []
    for raw in value.split(","):
        raw = raw.strip()
        if not raw:
            continue
        try:
            item = int(raw)
        except ValueError as exc:
            raise argparse.ArgumentTypeError(f"{name} must contain integers: {value}") from exc
        if item <= 0:
            raise argparse.ArgumentTypeError(f"{name} values must be positive: {value}")
        items.append(item)
    if not items:
        raise argparse.ArgumentTypeError(f"{name} must not be empty")
    return items


def parse_precisions(value: str) -> list[str]:
    aliases = {
        "ALL": ["FP16", "FP32", "FP64", "FP128"],
        "ALL_CPU": ["FP16", "FP32", "FP64", "FP128"],
        "ALL_KNOWN": ["FP4", "FP8_E4M3", "FP8_E5M2", "FP16", "FP32", "FP64", "FP128"],
        "FP4": ["FP4"],
        "E2M1": ["FP4"],
        "FP8": ["FP8_E4M3", "FP8_E5M2"],
        "FP8_E4M3": ["FP8_E4M3"],
        "E4M3": ["FP8_E4M3"],
        "FP8_E5M2": ["FP8_E5M2"],
        "E5M2": ["FP8_E5M2"],
        "FLOAT16": ["FP16"],
        "HALF": ["FP16"],
        "FP16": ["FP16"],
        "FLOAT32": ["FP32"],
        "SINGLE": ["FP32"],
        "SGEMM": ["FP32"],
        "FP32": ["FP32"],
        "FLOAT64": ["FP64"],
        "DOUBLE": ["FP64"],
        "DGEMM": ["FP64"],
        "FP64": ["FP64"],
        "FLOAT128": ["FP128"],
        "LONGDOUBLE": ["FP128"],
        "QUAD": ["FP128"],
        "FP128": ["FP128"],
    }
    out: list[str] = []
    for raw in value.split(","):
        key = raw.strip().upper()
        if not key:
            continue
        if key not in aliases:
            raise argparse.ArgumentTypeError(f"unsupported precision: {raw}")
        for precision in aliases[key]:
            if precision not in out:
                out.append(precision)
    if not out:
        raise argparse.ArgumentTypeError("precisions must not be empty")
    return out


def json_default(value: Any) -> Any:
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, (set, tuple)):
        return list(value)
    return str(value)


def safe_threadpool_info(threadpool_info_func: Any) -> list[dict[str, Any]]:
    if threadpool_info_func is None:
        return []
    try:
        info = threadpool_info_func()
    except Exception as exc:  # pragma: no cover - diagnostic fallback
        return [{"error": str(exc)}]
    return info if isinstance(info, list) else []


def capture_numpy_config(np: Any) -> str:
    buffer = io.StringIO()
    try:
        with contextlib.redirect_stdout(buffer):
            np.__config__.show()
    except Exception as exc:  # pragma: no cover - diagnostic fallback
        return f"np.__config__.show() failed: {exc}"
    return buffer.getvalue().strip()


def backend_label(threadpool_info: list[dict[str, Any]], fallback: str = "numpy-blas") -> str:
    for item in threadpool_info:
        user_api = item.get("user_api")
        internal_api = item.get("internal_api")
        version = item.get("version")
        threading_layer = item.get("threading_layer")
        architecture = item.get("architecture")
        if user_api == "blas":
            parts = [str(internal_api or user_api or fallback)]
            if version:
                parts.append(str(version))
            if threading_layer:
                parts.append(str(threading_layer))
            if architecture:
                parts.append(str(architecture))
            return " ".join(parts)
    return fallback


def active_blas_threads(threadpool_info: list[dict[str, Any]]) -> str:
    for item in threadpool_info:
        if item.get("user_api") == "blas":
            num_threads = item.get("num_threads")
            if num_threads is not None:
                return str(num_threads)
    return ""


def random_matrix(np: Any, rng: Any, size: int, dtype: Any) -> Any:
    try:
        return rng.random((size, size), dtype=dtype)
    except TypeError:
        return rng.random((size, size)).astype(dtype, copy=False)


def precision_config(np: Any, precision: str) -> dict[str, Any]:
    if precision == "FP16":
        return {
            "precision": precision,
            "supported": True,
            "dtype": np.float16,
            "dtype_name": "float16",
            "dtype_bits": 16,
            "provider": "numpy-matmul-fallback",
            "note": "OpenBLAS does not provide standard FP16 GEMM; NumPy matmul fallback is used.",
        }
    if precision == "FP32":
        return {
            "precision": precision,
            "supported": True,
            "dtype": np.float32,
            "dtype_name": "float32",
            "dtype_bits": 32,
            "provider": "blas",
            "note": "BLAS SGEMM path.",
        }
    if precision == "FP64":
        return {
            "precision": precision,
            "supported": True,
            "dtype": np.float64,
            "dtype_name": "float64",
            "dtype_bits": 64,
            "provider": "blas",
            "note": "BLAS DGEMM path.",
        }
    if precision == "FP128":
        longdouble_info = np.finfo(np.longdouble)
        bits = int(longdouble_info.bits)
        if bits <= 64:
            return {
                "precision": precision,
                "supported": False,
                "dtype": None,
                "dtype_name": "longdouble",
                "dtype_bits": bits,
                "provider": "numpy-longdouble",
                "reason": f"np.longdouble is only {bits} bits on this platform, so FP128 is not available.",
            }
        return {
            "precision": precision,
            "supported": True,
            "dtype": np.longdouble,
            "dtype_name": "longdouble",
            "dtype_bits": bits,
            "provider": "numpy-longdouble-fallback",
            "note": "Platform long double matmul; not a hardware FP128 BLAS path.",
        }
    if precision in {"FP4", "FP8_E4M3", "FP8_E5M2"}:
        return {
            "precision": precision,
            "supported": False,
            "dtype": None,
            "dtype_name": "",
            "dtype_bits": "",
            "provider": "unsupported",
            "reason": "NumPy/OpenBLAS CPU GEMM has no standard dtype or BLAS path for this precision.",
        }
    return {
        "precision": precision,
        "supported": False,
        "dtype": None,
        "dtype_name": "",
        "dtype_bits": "",
        "provider": "unsupported",
        "reason": f"Unsupported precision token: {precision}",
    }


def gflops_for_gemm(size: int, runtime_seconds: float) -> float:
    if runtime_seconds <= 0:
        return math.nan
    return (2.0 * size * size * size) / runtime_seconds / 1.0e9


def summarize_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[tuple[str, str, str, int, int], list[dict[str, Any]]] = {}
    for row in rows:
        key = (
            str(row["backend"]),
            str(row["provider"]),
            str(row["precision"]),
            int(row["matrix_size"]),
            int(row["threads"]),
        )
        groups.setdefault(key, []).append(row)

    summary: list[dict[str, Any]] = []
    for (backend, provider, precision, matrix_size, threads), group in sorted(
        groups.items(), key=lambda x: (PRECISION_ORDER.get(x[0][2], 999), x[0][3], x[0][4], x[0][0], x[0][1])
    ):
        runtimes = [float(row["runtime_ms"]) for row in group]
        gflops = [float(row["GFLOPS"]) for row in group]
        summary.append(
            {
                "backend": backend,
                "provider": provider,
                "precision": precision,
                "matrix_size": matrix_size,
                "threads": threads,
                "repeats": len(group),
                "avg_runtime_ms": statistics.fmean(runtimes),
                "best_runtime_ms": min(runtimes),
                "avg_GFLOPS": statistics.fmean(gflops),
                "best_GFLOPS": max(gflops),
            }
        )
    return summary


def write_csv(path: Path, fieldnames: list[str], rows: list[dict[str, Any]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def markdown_table(headers: list[str], rows: list[list[Any]]) -> list[str]:
    def cell(value: Any) -> str:
        text = str(value).replace("\\", "\\\\").replace("|", "\\|").replace("\n", "<br>")
        return text

    lines = [
        "| " + " | ".join(cell(header) for header in headers) + " |",
        "| " + " | ".join(["---"] * len(headers)) + " |",
    ]
    for row in rows:
        lines.append("| " + " | ".join(cell(item) for item in row) + " |")
    return lines


def write_report(
    path: Path,
    metadata: dict[str, Any],
    summary_rows: list[dict[str, Any]],
    raw_csv: Path,
    summary_csv: Path,
    unsupported_csv: Path,
) -> None:
    lines: list[str] = []
    lines.append("# CPU Floating-Point GEMM Benchmark Report")
    lines.append("")
    lines.append(f"Generated: {metadata['generated_at']}")
    lines.append(f"Host: {metadata['host']}")
    lines.append(f"Run directory: {metadata['run_directory']}")
    lines.append("")
    lines.append("## Environment")
    lines.extend(
        markdown_table(
            ["key", "value"],
            [
                ["platform", metadata["platform"]],
                ["python", metadata["python_executable"]],
                ["python_version", metadata["python_version"]],
                ["numpy_version", metadata["numpy_version"]],
                ["numpy_path", metadata["numpy_path"]],
                ["cpu_count", metadata["cpu_count"]],
                ["processor", metadata["processor"] or "unknown"],
                ["blas_backend", metadata["blas_backend"]],
                ["blas_sizes", ",".join(str(item) for item in metadata["requested_sizes"])],
                ["fallback_sizes", ",".join(str(item) for item in metadata["requested_fallback_sizes"])],
                ["precisions", ",".join(metadata["requested_precisions"])],
                ["threads", ",".join(str(item) for item in metadata["effective_threads"])],
                ["repeat_count", metadata["repeat_count"]],
                ["profiling_iterations", metadata["profiling_iterations"]],
            ],
        )
    )
    lines.append("")

    env_rows = [[key, metadata["environment"].get(key) or ""] for key in sorted(metadata["environment"])]
    lines.append("## Thread Environment")
    lines.extend(markdown_table(["variable", "value"], env_rows))
    lines.append("")

    blas_rows: list[list[Any]] = []
    for item in metadata.get("final_threadpool_info", []):
        if item.get("user_api") != "blas":
            continue
        blas_rows.append(
            [
                item.get("internal_api") or item.get("user_api") or "",
                item.get("version") or "",
                item.get("threading_layer") or "",
                item.get("num_threads") or "",
                item.get("architecture") or "",
                item.get("filepath") or "",
            ]
        )
    if blas_rows:
        lines.append("## BLAS Libraries")
        lines.extend(markdown_table(["api", "version", "threading", "threads", "arch", "path"], blas_rows))
        lines.append("")

    lines.append("## Result Summary")
    if summary_rows:
        table_rows = []
        for row in summary_rows:
            table_rows.append(
                [
                    row["backend"],
                    row["provider"],
                    row["precision"],
                    row["matrix_size"],
                    row["threads"],
                    row["repeats"],
                    f"{row['avg_GFLOPS']:.2f}",
                    f"{row['best_GFLOPS']:.2f}",
                    f"{row['avg_runtime_ms']:.3f}",
                    f"{row['best_runtime_ms']:.3f}",
                ]
            )
        lines.extend(
            markdown_table(
                [
                    "backend",
                    "provider",
                    "precision",
                    "matrix_size",
                    "threads",
                    "repeats",
                    "avg_GFLOPS",
                    "best_GFLOPS",
                    "avg_runtime_ms",
                    "best_runtime_ms",
                ],
                table_rows,
            )
        )
    else:
        lines.append("No benchmark rows were generated.")
    lines.append("")

    unsupported_rows = metadata.get("unsupported_cases", [])
    if unsupported_rows:
        lines.append("## Unsupported / Skipped Cases")
        lines.extend(
            markdown_table(
                ["precision", "matrix_size", "threads", "provider", "reason"],
                [
                    [
                        row.get("precision", ""),
                        row.get("matrix_size", ""),
                        row.get("threads", ""),
                        row.get("provider", ""),
                        row.get("reason", ""),
                    ]
                    for row in unsupported_rows
                ],
            )
        )
        lines.append("")

    lines.append("## Output Files")
    output_rows = [
        [raw_csv.name, "raw per-repeat benchmark rows"],
        [summary_csv.name, "grouped average/best rows"],
        [unsupported_csv.name, "unsupported or skipped precision cases"],
        ["metadata.json", "host, Python, NumPy, BLAS, and environment metadata"],
    ]
    optional_outputs = {
        "command.ps1": "PowerShell command used for this run",
        "command.sh": "shell command used for this run",
        "selected_env.json": "selected conda environment state used for this run",
        "windows_cpu_info.json": "Windows CPU metadata from CIM",
        "windows_os_info.json": "Windows OS metadata from CIM",
    }
    for filename, description in optional_outputs.items():
        if (path.parent / filename).exists():
            output_rows.append([filename, description])
    lines.extend(
        markdown_table(
            ["file", "description"],
            output_rows,
        )
    )
    lines.append("")

    path.write_text("\n".join(lines), encoding="utf-8")


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, help="Directory where result files are written.")
    parser.add_argument("--sizes", default="1024,2048,4096", help="Comma-separated square GEMM sizes for BLAS FP32/FP64.")
    parser.add_argument(
        "--fallback-sizes",
        default="256,512",
        help="Comma-separated square GEMM sizes for NumPy fallback precisions such as FP16/FP128.",
    )
    parser.add_argument(
        "--precisions",
        default="FP32,FP64",
        help="Comma-separated precisions. Aliases: ALL=FP16,FP32,FP64,FP128; ALL_KNOWN also records FP4/FP8 unsupported cases.",
    )
    parser.add_argument("--threads", default="1,2,4,8,16,24", help="Comma-separated BLAS thread counts.")
    parser.add_argument("--repeat-count", type=int, default=3, help="Measured repeats per case.")
    parser.add_argument("--warmup-iterations", type=int, default=1, help="Untimed matmul iterations before each repeat.")
    parser.add_argument("--profiling-iterations", type=int, default=3, help="Timed matmul iterations per repeat.")
    parser.add_argument("--seed", type=int, default=1234, help="Random seed.")
    parser.add_argument("--require-backend", default="", help="Require the detected BLAS backend label to contain this token.")
    parser.add_argument("--dry-run", action="store_true", help="Write metadata and command files without GEMM work.")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    sizes = parse_csv_ints(args.sizes, "sizes")
    fallback_sizes = parse_csv_ints(args.fallback_sizes, "fallback-sizes")
    precisions = parse_precisions(args.precisions)
    requested_threads = parse_csv_ints(args.threads, "threads")
    if args.repeat_count <= 0:
        raise SystemExit("--repeat-count must be positive")
    if args.warmup_iterations < 0:
        raise SystemExit("--warmup-iterations must be non-negative")
    if args.profiling_iterations <= 0:
        raise SystemExit("--profiling-iterations must be positive")

    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    raw_csv = output_dir / "summary_openblas_numpy_gemm.csv"
    summary_csv = output_dir / "summary_openblas_numpy_gemm_grouped.csv"
    unsupported_csv = output_dir / "unsupported_cases.csv"
    metadata_path = output_dir / "metadata.json"
    report_path = output_dir / "report.md"

    raw_fieldnames = [
        "backend",
        "provider",
        "precision",
        "dtype",
        "dtype_bits",
        "matrix_size",
        "threads",
        "actual_blas_threads",
        "repeat",
        "warmup_iterations",
        "profiling_iterations",
        "GFLOPS",
        "runtime_ms",
        "checksum",
    ]
    summary_fieldnames = [
        "backend",
        "provider",
        "precision",
        "matrix_size",
        "threads",
        "repeats",
        "avg_GFLOPS",
        "best_GFLOPS",
        "avg_runtime_ms",
        "best_runtime_ms",
    ]
    unsupported_fieldnames = [
        "precision",
        "matrix_size",
        "threads",
        "provider",
        "dtype",
        "dtype_bits",
        "reason",
    ]

    try:
        from threadpoolctl import threadpool_info, threadpool_limits
    except Exception:
        threadpool_info = None
        threadpool_limits = None

    import numpy as np

    cpu_count = os.cpu_count() or 1
    threads = [thread for thread in requested_threads if thread <= cpu_count]
    skipped_threads = [thread for thread in requested_threads if thread > cpu_count]
    if not threads:
        threads = [cpu_count]

    if threadpool_limits is None and len(set(threads)) > 1:
        raise SystemExit(
            "threadpoolctl is required when benchmarking multiple thread counts. "
            "Install it in the selected Python/conda environment or pass a single thread count."
        )

    env_keys = [
        "OPENBLAS_NUM_THREADS",
        "OMP_NUM_THREADS",
        "MKL_NUM_THREADS",
        "NUMEXPR_NUM_THREADS",
        "VECLIB_MAXIMUM_THREADS",
        "BLIS_NUM_THREADS",
    ]
    metadata: dict[str, Any] = {
        "generated_at": datetime.now(timezone.utc).astimezone().isoformat(),
        "host": socket.gethostname(),
        "run_directory": str(output_dir),
        "platform": platform.platform(),
        "processor": platform.processor(),
        "machine": platform.machine(),
        "cpu_count": cpu_count,
        "requested_sizes": sizes,
        "requested_fallback_sizes": fallback_sizes,
        "requested_precisions": precisions,
        "requested_threads": requested_threads,
        "effective_threads": threads,
        "skipped_threads": skipped_threads,
        "repeat_count": args.repeat_count,
        "warmup_iterations": args.warmup_iterations,
        "profiling_iterations": args.profiling_iterations,
        "seed": args.seed,
        "python_executable": sys.executable,
        "python_version": sys.version.replace("\n", " "),
        "numpy_version": np.__version__,
        "numpy_path": str(Path(np.__file__).resolve()),
        "numpy_config": capture_numpy_config(np),
        "threadpoolctl_available": threadpool_limits is not None,
        "initial_threadpool_info": safe_threadpool_info(threadpool_info),
        "environment": {key: os.environ.get(key, "") for key in env_keys},
        "required_backend": args.require_backend,
        "dry_run": args.dry_run,
    }
    metadata["blas_backend"] = backend_label(metadata["initial_threadpool_info"])

    if args.require_backend:
        required_backend = args.require_backend.lower()
        detected_backend = str(metadata["blas_backend"]).lower()
        if required_backend not in detected_backend:
            metadata["backend_requirement_error"] = (
                f"Required backend token '{args.require_backend}' was not found in detected backend "
                f"'{metadata['blas_backend']}'."
            )
            metadata["final_threadpool_info"] = safe_threadpool_info(threadpool_info)
            metadata["unsupported_cases"] = []
            write_csv(raw_csv, raw_fieldnames, [])
            write_csv(summary_csv, summary_fieldnames, [])
            write_csv(unsupported_csv, unsupported_fieldnames, [])
            metadata_path.write_text(json.dumps(metadata, indent=2, default=json_default), encoding="utf-8")
            write_report(report_path, metadata, [], raw_csv, summary_csv, unsupported_csv)
            raise SystemExit(metadata["backend_requirement_error"])

    rows: list[dict[str, Any]] = []
    unsupported_cases: list[dict[str, Any]] = []
    if args.dry_run:
        print("Dry run requested; skipping GEMM work.")
    else:
        rng = np.random.default_rng(args.seed)
        for precision in precisions:
            config = precision_config(np, precision)
            selected_sizes = sizes if config["provider"] == "blas" else fallback_sizes
            if not config["supported"]:
                unsupported_cases.append(
                    {
                        "precision": precision,
                        "matrix_size": "",
                        "threads": "",
                        "provider": config["provider"],
                        "dtype": config["dtype_name"],
                        "dtype_bits": config["dtype_bits"],
                        "reason": config.get("reason", "unsupported precision"),
                    }
                )
                print(f"Skipping {precision}: {config.get('reason', 'unsupported precision')}", flush=True)
                continue

            dtype = config["dtype"]
            for size in selected_sizes:
                print(f"Preparing {precision} matrices for size {size}x{size}...", flush=True)
                try:
                    a = random_matrix(np, rng, size, dtype)
                    b = random_matrix(np, rng, size, dtype)
                except Exception as exc:
                    unsupported_cases.append(
                        {
                            "precision": precision,
                            "matrix_size": size,
                            "threads": "",
                            "provider": config["provider"],
                            "dtype": config["dtype_name"],
                            "dtype_bits": config["dtype_bits"],
                            "reason": f"matrix allocation failed: {exc}",
                        }
                    )
                    print(f"Skipping {precision} size={size}: allocation failed: {exc}", flush=True)
                    continue
                for threads_value in threads:
                    limit_context = (
                        threadpool_limits(limits=threads_value, user_api="blas")
                        if threadpool_limits is not None
                        else contextlib.nullcontext()
                    )
                    with limit_context:
                        current_threadpool_info = safe_threadpool_info(threadpool_info)
                        current_backend = backend_label(current_threadpool_info)
                        current_blas_threads = active_blas_threads(current_threadpool_info)
                        for repeat in range(1, args.repeat_count + 1):
                            print(
                                f"Running {precision} size={size} threads={threads_value} repeat={repeat}/{args.repeat_count}...",
                                flush=True,
                            )
                            try:
                                c = None
                                for _ in range(args.warmup_iterations):
                                    c = a @ b
                                start = time.perf_counter()
                                for _ in range(args.profiling_iterations):
                                    c = a @ b
                                elapsed = time.perf_counter() - start
                                runtime_ms = elapsed * 1000.0 / args.profiling_iterations
                                gflops = gflops_for_gemm(size, elapsed / args.profiling_iterations)
                                checksum = float(np.sum(c[: min(8, size), : min(8, size)], dtype=np.float64))
                            except Exception as exc:
                                unsupported_cases.append(
                                    {
                                        "precision": precision,
                                        "matrix_size": size,
                                        "threads": threads_value,
                                        "provider": config["provider"],
                                        "dtype": config["dtype_name"],
                                        "dtype_bits": config["dtype_bits"],
                                        "reason": f"matmul failed: {exc}",
                                    }
                                )
                                print(f"Skipping {precision} size={size} threads={threads_value}: matmul failed: {exc}", flush=True)
                                break
                            rows.append(
                                {
                                    "backend": current_backend,
                                    "provider": config["provider"],
                                    "precision": precision,
                                    "dtype": config["dtype_name"],
                                    "dtype_bits": config["dtype_bits"],
                                    "matrix_size": size,
                                    "threads": threads_value,
                                    "actual_blas_threads": current_blas_threads,
                                    "repeat": repeat,
                                    "warmup_iterations": args.warmup_iterations,
                                    "profiling_iterations": args.profiling_iterations,
                                    "runtime_ms": f"{runtime_ms:.6f}",
                                    "GFLOPS": f"{gflops:.6f}",
                                    "checksum": f"{checksum:.12e}",
                                }
                            )
                del a
                del b

    metadata["final_threadpool_info"] = safe_threadpool_info(threadpool_info)
    metadata["blas_backend"] = backend_label(metadata["final_threadpool_info"])
    metadata["unsupported_cases"] = unsupported_cases

    write_csv(raw_csv, raw_fieldnames, rows)

    summary_rows = summarize_rows(rows)
    write_csv(summary_csv, summary_fieldnames, summary_rows)
    write_csv(unsupported_csv, unsupported_fieldnames, unsupported_cases)
    metadata_path.write_text(json.dumps(metadata, indent=2, default=json_default), encoding="utf-8")
    write_report(report_path, metadata, summary_rows, raw_csv, summary_csv, unsupported_csv)

    print(f"Raw CSV: {raw_csv}")
    print(f"Grouped CSV: {summary_csv}")
    print(f"Unsupported cases: {unsupported_csv}")
    print(f"Metadata: {metadata_path}")
    print(f"Report: {report_path}")
    if skipped_threads:
        print(f"Skipped thread counts above os.cpu_count()={cpu_count}: {skipped_threads}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
