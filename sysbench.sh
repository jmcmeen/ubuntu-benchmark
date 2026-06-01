#!/usr/bin/env bash
#
# sysbench.sh — a self-contained system benchmark for Ubuntu
#
# Benchmarks CPU, memory, disk I/O, and (optionally) the GPU. Each section
# prefers a "proper" tool (sysbench, fio, stress-ng) when installed and falls
# back to something that works on a bare system otherwise. Nothing here needs
# root, though disk tests are more accurate if you can drop caches (sudo).
#
# Usage:
#   ./sysbench.sh                 # run everything available
#   ./sysbench.sh --cpu --mem     # run only selected sections
#   ./sysbench.sh --no-gpu        # skip the GPU section
#   ./sysbench.sh --dir /data     # run disk test in a specific directory
#   ./sysbench.sh --json out.json # also write machine-readable results
#   ./sysbench.sh --help
#
set -uo pipefail

# ----------------------------------------------------------------------------
# Configuration & argument parsing
# ----------------------------------------------------------------------------
RUN_INFO=1 RUN_CPU=1 RUN_MEM=1 RUN_DISK=1 RUN_GPU=1
ONLY_SELECTED=0
DISK_DIR="."
JSON_OUT=""
DISK_SIZE_MB=1024          # size of the test file for disk I/O
CPU_DURATION=10            # seconds per CPU sub-test

usage() {
    sed -n '2,/^set /p' "$0" | sed 's/^#\s\?//; /^set /d'
    exit 0
}

# If any --<section> flag is passed, run *only* those sections.
for arg in "$@"; do
    case "$arg" in
        --cpu|--mem|--disk|--gpu|--info) ONLY_SELECTED=1 ;;
    esac
done
if (( ONLY_SELECTED )); then RUN_INFO=0 RUN_CPU=0 RUN_MEM=0 RUN_DISK=0 RUN_GPU=0; fi

while (( $# )); do
    case "$1" in
        --info)  RUN_INFO=1 ;;
        --cpu)   RUN_CPU=1 ;;
        --mem)   RUN_MEM=1 ;;
        --disk)  RUN_DISK=1 ;;
        --gpu)   RUN_GPU=1 ;;
        --no-gpu)  RUN_GPU=0 ;;
        --no-disk) RUN_DISK=0 ;;
        --dir)   DISK_DIR="${2:?--dir needs a path}"; shift ;;
        --size)  DISK_SIZE_MB="${2:?--size needs MB}"; shift ;;
        --json)  JSON_OUT="${2:?--json needs a file}"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

# ----------------------------------------------------------------------------
# Pretty output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; GRN=$'\e[32m'; CYN=$'\e[36m'; YLW=$'\e[33m'; RST=$'\e[0m'
else
    BOLD="" DIM="" GRN="" CYN="" YLW="" RST=""
fi

header() { printf '\n%s%s== %s ==%s\n' "$BOLD" "$CYN" "$1" "$RST"; }
row()    { printf '  %-26s %s\n' "$1" "${GRN}${2}${RST}"; }
note()   { printf '  %s%s%s\n' "$DIM" "$1" "$RST"; }
have()   { command -v "$1" >/dev/null 2>&1; }

# Collected results for optional JSON output: "key\tvalue" lines.
RESULTS=$(mktemp)
trap 'rm -f "$RESULTS" "${TESTFILE:-}"' EXIT
record() { printf '%s\t%s\n' "$1" "$2" >> "$RESULTS"; }

# ----------------------------------------------------------------------------
# System information
# ----------------------------------------------------------------------------
section_info() {
    header "System Information"
    local cpu_model cores threads mem_total
    cpu_model=$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2; exit}')
    cores=$(nproc --all 2>/dev/null || echo "?")
    threads=$(lscpu 2>/dev/null | awk -F: '/^CPU\(s\)/{gsub(/ /,"",$2); print $2; exit}')
    mem_total=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')

    row "Hostname"      "$(hostname)"
    row "Kernel"        "$(uname -r)"
    row "Distro"        "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
    row "CPU"           "${cpu_model:-unknown}"
    row "Logical CPUs"  "${threads:-$cores}"
    row "Total RAM"     "${mem_total:-unknown}"
    if have nvidia-smi; then
        row "GPU" "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | paste -sd', ')"
    fi
    record "cpu_model" "${cpu_model:-unknown}"
    record "logical_cpus" "${threads:-$cores}"
}

# ----------------------------------------------------------------------------
# CPU benchmark
# ----------------------------------------------------------------------------
# Pure-python prime sieve fallback: returns operations/sec as a rough score.
cpu_python_score() {
    local secs="$1"
    python3 - "$secs" <<'PY'
import sys, time
budget = float(sys.argv[1])
end = time.perf_counter() + budget
ops = 0
n = 3
# Count primes found within the time budget; "ops" = primes counted.
def is_prime(x):
    if x < 2: return False
    i = 2
    while i * i <= x:
        if x % i == 0: return False
        i += 1
    return True
while time.perf_counter() < end:
    if is_prime(n):
        ops += 1
    n += 1
print(f"{ops/budget:.0f}")
PY
}

section_cpu() {
    header "CPU"
    if have sysbench; then
        local nthreads; nthreads=$(nproc)
        note "tool: sysbench  (single-thread, then ${nthreads}-thread)"
        local single multi
        single=$(sysbench cpu --cpu-max-prime=20000 --threads=1 --time="$CPU_DURATION" run 2>/dev/null \
                 | awk '/events per second/{print $NF}')
        multi=$(sysbench cpu --cpu-max-prime=20000 --threads="$nthreads" --time="$CPU_DURATION" run 2>/dev/null \
                 | awk '/events per second/{print $NF}')
        row "Single-thread (events/s)" "${single:-n/a}"
        row "Multi-thread (events/s)"  "${multi:-n/a}"
        record "cpu_single_eps" "${single:-}"
        record "cpu_multi_eps" "${multi:-}"
    elif have stress-ng; then
        local nthreads; nthreads=$(nproc)
        note "tool: stress-ng  (bogo-ops over ${CPU_DURATION}s)"
        local bogo
        bogo=$(stress-ng --cpu "$nthreads" --cpu-method all --metrics-brief \
                 --timeout "${CPU_DURATION}s" 2>&1 | awk '/cpu /{print $5; exit}')
        row "Throughput (bogo-ops/s)" "${bogo:-n/a}"
        record "cpu_bogo_ops" "${bogo:-}"
    elif have python3; then
        note "tool: python fallback  (install 'sysbench' for a real CPU score)"
        local single
        single=$(cpu_python_score "$CPU_DURATION")
        row "Single-thread (primes/s)" "${single:-n/a}"
        record "cpu_python_primes" "${single:-}"
    else
        note "no CPU benchmark tool available (install sysbench or stress-ng)"
    fi
}

# ----------------------------------------------------------------------------
# Memory benchmark
# ----------------------------------------------------------------------------
section_mem() {
    header "Memory"
    if have sysbench; then
        note "tool: sysbench  (sequential write, 1 KiB blocks)"
        local bw
        bw=$(sysbench memory --memory-block-size=1K --memory-total-size=10G \
               --memory-oper=write run 2>/dev/null \
               | awk '/transferred/{gsub(/[()]/,""); print $(NF-1), $NF}')
        row "Throughput" "${bw:-n/a}"
        record "mem_throughput" "${bw:-}"
    else
        note "tool: python fallback  (install 'sysbench' for a real memory score)"
        local bw
        bw=$(python3 - <<'PY'
import time
size = 256 * 1024 * 1024          # 256 MiB buffer
src = bytearray(size)
reps = 8
start = time.perf_counter()
dst = bytearray(size)
for _ in range(reps):
    dst[:] = src                  # large memcpy
elapsed = time.perf_counter() - start
gbps = (size * reps) / elapsed / (1024**3)
print(f"{gbps:.2f} GiB/s")
PY
)
        row "memcpy bandwidth" "${bw:-n/a}"
        record "mem_memcpy" "${bw:-}"
    fi
}

# ----------------------------------------------------------------------------
# Disk I/O benchmark
# ----------------------------------------------------------------------------
section_disk() {
    header "Disk I/O  ${DIM}(${DISK_DIR})${RST}"
    if [[ ! -d "$DISK_DIR" || ! -w "$DISK_DIR" ]]; then
        note "directory '$DISK_DIR' is not writable — skipping"
        return
    fi

    if have fio; then
        note "tool: fio  (4 KiB random read/write, direct I/O)"
        local tmp; tmp=$(mktemp -p "$DISK_DIR" fio.XXXXXX)
        local out
        out=$(fio --name=rw --filename="$tmp" --size="${DISK_SIZE_MB}M" \
                  --bs=4k --rw=randrw --rwmixread=70 --direct=1 \
                  --ioengine=libaio --iodepth=16 --runtime=10 --time_based \
                  --group_reporting --minimal 2>/dev/null)
        rm -f "$tmp"
        # minimal format: read BW is field 7 (KB/s), write BW field 48.
        local rkb wkb
        rkb=$(echo "$out" | awk -F';' '{print $7}')
        wkb=$(echo "$out" | awk -F';' '{print $48}')
        row "Random read"  "$(awk "BEGIN{printf \"%.1f MB/s\", ${rkb:-0}/1024}")"
        row "Random write" "$(awk "BEGIN{printf \"%.1f MB/s\", ${wkb:-0}/1024}")"
        record "disk_rand_read_kbps" "${rkb:-}"
        record "disk_rand_write_kbps" "${wkb:-}"
    else
        note "tool: dd fallback  (sequential, install 'fio' for random IOPS)"
        TESTFILE="$DISK_DIR/.sysbench_dd_$$"
        # Sequential write.
        local w_line w_speed
        w_line=$(dd if=/dev/zero of="$TESTFILE" bs=1M count="$DISK_SIZE_MB" \
                    oflag=direct 2>&1 || \
                 dd if=/dev/zero of="$TESTFILE" bs=1M count="$DISK_SIZE_MB" \
                    conv=fdatasync 2>&1)
        w_speed=$(echo "$w_line" | awk -F, 'END{gsub(/^ +/,"",$NF); print $NF}')
        row "Sequential write" "${w_speed:-n/a}"
        # Drop caches if possible, then sequential read.
        sync
        sysctl -w vm.drop_caches=3 >/dev/null 2>&1 || \
            echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || \
            note "(couldn't drop caches; read figure may be cache-inflated — try sudo)"
        local r_line r_speed
        r_line=$(dd if="$TESTFILE" of=/dev/null bs=1M 2>&1)
        r_speed=$(echo "$r_line" | awk -F, 'END{gsub(/^ +/,"",$NF); print $NF}')
        row "Sequential read"  "${r_speed:-n/a}"
        rm -f "$TESTFILE"; TESTFILE=""
        record "disk_seq_write" "${w_speed:-}"
        record "disk_seq_read" "${r_speed:-}"
    fi
}

# ----------------------------------------------------------------------------
# GPU benchmark (NVIDIA)
# ----------------------------------------------------------------------------
section_gpu() {
    header "GPU"
    if ! have nvidia-smi; then
        note "no nvidia-smi found — skipping (this section is NVIDIA-only)"
        return
    fi
    # Static info.
    nvidia-smi --query-gpu=name,memory.total,driver_version,temperature.gpu,utilization.gpu \
               --format=csv,noheader 2>/dev/null | while IFS=',' read -r name mem drv temp util; do
        row "Name"        "$(echo "$name" | xargs)"
        row "VRAM"        "$(echo "$mem"  | xargs)"
        row "Driver"      "$(echo "$drv"  | xargs)"
        row "Temp / Util" "$(echo "$temp" | xargs) / $(echo "$util" | xargs)"
    done

    # Compute throughput via PyTorch if present (great proxy on Blackwell cards).
    if python3 -c 'import torch' 2>/dev/null; then
        note "running a quick FP16 matmul throughput test via PyTorch…"
        local tflops
        tflops=$(python3 - <<'PY'
import torch, time
if not torch.cuda.is_available():
    print("cuda-unavailable"); raise SystemExit
dev = torch.device('cuda')
n = 8192
a = torch.randn(n, n, device=dev, dtype=torch.float16)
b = torch.randn(n, n, device=dev, dtype=torch.float16)
for _ in range(3):                      # warm up
    torch.mm(a, b)
torch.cuda.synchronize()
iters = 50
t0 = time.perf_counter()
for _ in range(iters):
    torch.mm(a, b)
torch.cuda.synchronize()
dt = time.perf_counter() - t0
flops = 2 * n**3 * iters
print(f"{flops/dt/1e12:.1f}")
PY
)
        if [[ "$tflops" == "cuda-unavailable" ]]; then
            note "PyTorch present but CUDA not available to it"
        else
            row "FP16 matmul" "${tflops:-n/a} TFLOP/s"
            record "gpu_fp16_tflops" "${tflops:-}"
        fi
    else
        note "install PyTorch (torch) for a compute throughput number"
    fi
}

# ----------------------------------------------------------------------------
# JSON output
# ----------------------------------------------------------------------------
write_json() {
    [[ -z "$JSON_OUT" ]] && return
    {
        echo "{"
        echo "  \"timestamp\": \"$(date -Is)\","
        local first=1
        while IFS=$'\t' read -r k v; do
            [[ -z "$k" ]] && continue
            (( first )) || echo ","
            first=0
            v=${v//\"/\\\"}
            printf '  "%s": "%s"' "$k" "$v"
        done < "$RESULTS"
        echo ""
        echo "}"
    } > "$JSON_OUT"
    note "JSON written to $JSON_OUT"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
printf '%s%sUbuntu System Benchmark%s  %s%s%s\n' \
    "$BOLD" "$YLW" "$RST" "$DIM" "$(date '+%Y-%m-%d %H:%M:%S')" "$RST"

(( RUN_INFO )) && section_info
(( RUN_CPU  )) && section_cpu
(( RUN_MEM  )) && section_mem
(( RUN_DISK )) && section_disk
(( RUN_GPU  )) && section_gpu

write_json
header "Done"
note "Tip: install 'sysbench fio' for higher-fidelity CPU/memory/disk numbers:"
note "     sudo apt install sysbench fio"
