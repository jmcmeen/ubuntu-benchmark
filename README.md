# ubuntu-benchmark

A single, self-contained shell script that benchmarks the major subsystems of an
Ubuntu (or any Linux) machine — **CPU, memory, disk I/O, and an optional NVIDIA
GPU** — and prints a tidy, color-coded summary. No dependencies are *required*:
each section uses a proper benchmarking tool when one is installed and falls back
to a built-in approximation otherwise.

## Quick start

```bash
./sysbench.sh
```

That runs every section that applies to your machine. No root needed (though disk
reads are more accurate if the script can drop caches — see [Notes](#notes)).

## Getting high-fidelity numbers

The script works out of the box, but for real, comparable numbers you want the
dedicated tools installed:

```bash
sudo apt install sysbench fio
```

- **`sysbench`** drives the CPU and memory tests.
- **`fio`** drives the disk test (4 KiB random read/write, direct I/O).
- **`stress-ng`** is used for CPU if `sysbench` is absent.
- **PyTorch** (`torch`), if importable with CUDA, adds an FP16 matmul throughput
  number to the GPU section.

> [!IMPORTANT]
> **The Python fallbacks are a smoke test, not a benchmark.** When the real tools
> aren't installed, the CPU and memory sections fall back to pure-Python loops.
> These are deliberately crude — single-threaded and GIL-bound — so they tell you
> "something is alive and roughly this fast," nothing more. **Do not compare those
> numbers against other systems.** The real, comparable figures come from
> sysbench / fio / torch.

## Usage

```bash
./sysbench.sh                 # run everything available
./sysbench.sh --cpu --mem     # run only the selected sections
./sysbench.sh --no-gpu        # run everything except the GPU section
./sysbench.sh --dir /data     # run the disk test in a specific directory
./sysbench.sh --size 4096     # disk test file size in MB (default 1024)
./sysbench.sh --json out.json # also write machine-readable results
./sysbench.sh --help
```

Passing any `--<section>` flag switches to "only these" mode — e.g. `--cpu`
alone runs *just* the CPU section. The `--no-<section>` flags subtract from the
full run instead.

### Flags

| Flag             | Effect                                                        |
| ---------------- | ------------------------------------------------------------- |
| `--info`         | System info section (host, kernel, distro, CPU, RAM, GPU)     |
| `--cpu`          | CPU benchmark                                                 |
| `--mem`          | Memory throughput benchmark                                   |
| `--disk`         | Disk I/O benchmark                                            |
| `--gpu`          | GPU section (NVIDIA only)                                     |
| `--no-gpu`       | Skip the GPU section                                          |
| `--no-disk`      | Skip the disk section                                         |
| `--dir PATH`     | Directory for the disk test file (default: current dir)       |
| `--size MB`      | Size of the disk test file in MB (default: 1024)              |
| `--json FILE`    | Also write results as JSON to `FILE`                          |
| `-h`, `--help`   | Show usage                                                    |

## What each section measures

| Section    | Preferred tool        | Fallback                          | Reported                                  |
| ---------- | --------------------- | --------------------------------- | ----------------------------------------- |
| **CPU**    | `sysbench` (1 + N thr)| `stress-ng`, then Python primes   | events/s (or bogo-ops/s, or primes/s)     |
| **Memory** | `sysbench`            | Python `memcpy` loop              | throughput / bandwidth                    |
| **Disk**   | `fio` (4K randrw)     | `dd` (sequential)                 | random R/W MB/s (or sequential R/W)       |
| **GPU**    | `nvidia-smi` + PyTorch| — (NVIDIA-only, skipped otherwise)| name, VRAM, driver, temp/util, FP16 TFLOP/s |

## JSON output

With `--json out.json`, results are also written as a flat JSON object with a
timestamp — handy for logging runs or feeding a dashboard:

```json
{
  "timestamp": "2026-06-01T18:58:00-04:00",
  "cpu_model": "...",
  "cpu_single_eps": "...",
  "disk_rand_read_kbps": "...",
  "gpu_fp16_tflops": "..."
}
```

## Notes

- **Disk reads & caches.** The `dd` fallback tries to drop page caches before the
  read test (`sysctl vm.drop_caches=3`). Without root it can't, so the read figure
  may be cache-inflated — run with `sudo` for an honest number. The `fio` path
  uses direct I/O and isn't affected.
- **GPU section is NVIDIA-only.** It keys off `nvidia-smi`; AMD/Intel GPUs are
  skipped.
- **Single-run noise.** Disk and memory numbers vary run-to-run. Treat a single
  run as indicative, not definitive.
