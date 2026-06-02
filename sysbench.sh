#!/usr/bin/env bash
#
# sysbench.sh — a self-contained system benchmark for Linux
#
# Benchmarks CPU, memory, disk I/O, and (optionally) the GPU. Each section
# prefers a "proper" tool (sysbench, fio, stress-ng) when installed and falls
# back to something that works on a bare system otherwise. Nothing here needs
# root, though disk tests are more accurate if you can drop caches (sudo).
#
# Usage:
#   ./sysbench.sh                    # run everything available
#   ./sysbench.sh --cpu --mem        # run only selected sections
#   ./sysbench.sh --no-gpu           # skip the GPU section
#   ./sysbench.sh --dir /data        # run disk test in a specific directory
#   ./sysbench.sh --runs 5           # repeat each test, report mean ± stddev
#   ./sysbench.sh --iperf-host HOST  # network test against an 'iperf3 -s' server
#   ./sysbench.sh --json out.json    # also write machine-readable results
#   ./sysbench.sh --deps             # print the package-install command and exit
#   ./sysbench.sh --help
#
set -uo pipefail

# ----------------------------------------------------------------------------
# Configuration & argument parsing
# ----------------------------------------------------------------------------
RUN_INFO=1 RUN_CPU=1 RUN_MEM=1 RUN_DISK=1 RUN_GPU=1
RUN_NET=0                  # network test is opt-in (it needs a remote target)
ONLY_SELECTED=0
DISK_DIR="."
JSON_OUT=""
DISK_SIZE_MB=1024          # size of the test file for disk I/O
CPU_DURATION=10            # seconds per CPU sub-test
NET_DURATION=10            # seconds per iperf3 direction
RUNS=1                     # repeat each measurement this many times
IPERF_HOST=""              # remote 'iperf3 -s' server for the network test

usage() {
    sed -n '2,/^set /p' "$0" | sed 's/^#\s\?//; /^set /d'
    exit 0
}

# have: is a command available? (defined early — used by --deps below as well as
# the section functions further down).
have() { command -v "$1" >/dev/null 2>&1; }

# detect_install_cmd: print the package-install command for the detected package
# manager, for the package list given as args. Package names are identical across
# distros, so only the install verb differs. Falls back to a generic hint.
detect_install_cmd() {
    local pkgs="$*"
    if   have apt-get; then echo "sudo apt install $pkgs"
    elif have dnf;     then echo "sudo dnf install $pkgs"
    elif have pacman;  then echo "sudo pacman -S $pkgs"
    elif have zypper;  then echo "sudo zypper install $pkgs"
    elif have apk;     then echo "sudo apk add $pkgs"
    else echo "install these with your package manager: $pkgs"
    fi
}

# If any --<section> flag is passed, run *only* those sections.
for arg in "$@"; do
    case "$arg" in
        --cpu|--mem|--disk|--gpu|--info|--net|--iperf-host) ONLY_SELECTED=1 ;;
    esac
done
if (( ONLY_SELECTED )); then RUN_INFO=0 RUN_CPU=0 RUN_MEM=0 RUN_DISK=0 RUN_GPU=0 RUN_NET=0; fi

while (( $# )); do
    case "$1" in
        --info)  RUN_INFO=1 ;;
        --cpu)   RUN_CPU=1 ;;
        --mem)   RUN_MEM=1 ;;
        --disk)  RUN_DISK=1 ;;
        --gpu)   RUN_GPU=1 ;;
        --net)   RUN_NET=1 ;;
        --no-gpu)  RUN_GPU=0 ;;
        --no-disk) RUN_DISK=0 ;;
        --dir)   DISK_DIR="${2:?--dir needs a path}"; shift ;;
        --size)  DISK_SIZE_MB="${2:?--size needs MB}"; shift ;;
        --runs)  RUNS="${2:?--runs needs a count}"; shift ;;
        --iperf-host) IPERF_HOST="${2:?--iperf-host needs a host}"; RUN_NET=1; shift ;;
        --json)  JSON_OUT="${2:?--json needs a file}"; shift ;;
        --deps)  detect_install_cmd sysbench fio iperf3; exit 0 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

# Validate --runs: must be a positive integer.
if ! [[ "$RUNS" =~ ^[1-9][0-9]*$ ]]; then
    echo "--runs must be a positive integer (got '$RUNS')" >&2; exit 2
fi

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

# Collected results for optional JSON output: "key\tvalue" lines.
RESULTS=$(mktemp)
trap 'rm -f "$RESULTS" "${TESTFILE:-}"' EXIT
record() { printf '%s\t%s\n' "$1" "$2" >> "$RESULTS"; }

# stats: read one number per line on stdin and print a raw "mean stddev n"
# triple (space-separated). Empty output if there were no samples. The values
# are kept full-precision here; fmt_stat handles human-facing rounding.
stats() {
    awk '
        NF { x[++c]=$1; s+=$1 }
        END {
            if (c==0) { exit }
            m = s/c
            if (c==1) { printf "%.10g 0 1", m; exit }
            for (i=1; i<=c; i++) { d=x[i]-m; ss+=d*d }
            printf "%.10g %.10g %d", m, sqrt(ss/(c-1)), c
        }'
}

# fmt_stat: format a "mean stddev n" triple for display.
#   $1 = printf format for one number (e.g. "%.1f"), $2 = the triple.
# One sample → just the value; several → "mean ± stddev (n=N)".
fmt_stat() {
    local fmt="$1" m s n
    read -r m s n <<<"$2"
    if [[ -z "$m" ]]; then echo "n/a"; return; fi
    if (( n <= 1 )); then printf "$fmt" "$m"
    else printf "$fmt ± $fmt (n=%d)" "$m" "$s" "$n"; fi
}

# record_stat: persist a "mean stddev n" triple as machine-readable JSON fields.
# One sample → a single numeric "<key>"; several → "<key>_mean/_stddev/_n".
record_stat() {
    local key="$1" m s n
    read -r m s n <<<"$2"
    [[ -z "$m" ]] && return
    if (( n <= 1 )); then
        record "$key" "$m"
    else
        record "${key}_mean"   "$m"
        record "${key}_stddev" "$s"
        record "${key}_n"      "$n"
    fi
}

# aggregate: run a measurement command $RUNS times and reduce to a stats triple.
#   args = command that prints a single number per run.
aggregate() {
    local vals="" v
    for ((r=0; r<RUNS; r++)); do
        v=$("$@")
        [[ -n "$v" ]] && vals+="$v"$'\n'
    done
    printf '%s' "$vals" | stats
}

# Show a "(averaged over N runs)" note once per section when --runs > 1.
runs_note() { (( RUNS > 1 )) && note "averaging over $RUNS runs"; }

# ----------------------------------------------------------------------------
# System information
# ----------------------------------------------------------------------------
section_info() {
    header "System Information"
    local cpu_model cores threads mem_total
    cpu_model=$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2; exit}')
    cores=$(nproc --all 2>/dev/null || echo "?")
    threads=$(lscpu 2>/dev/null | awk -F: '/^CPU\(s\)/{gsub(/ /,"",$2); print $2; exit}')
    if [[ -r /proc/meminfo ]]; then
        mem_total=$(awk '/^MemTotal:/{printf "%.1f GiB", $2/1024/1024}' /proc/meminfo)
    else
        mem_total=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}' \
                    || free 2>/dev/null | awk '/^Mem:/{print $2" kB"}')
    fi

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

NTHREADS=$(nproc 2>/dev/null || echo 1)

m_cpu_single() {
    sysbench cpu --cpu-max-prime=20000 --threads=1 --time="$CPU_DURATION" run 2>/dev/null \
        | awk '/events per second/{print $NF}'
}
m_cpu_multi() {
    sysbench cpu --cpu-max-prime=20000 --threads="$NTHREADS" --time="$CPU_DURATION" run 2>/dev/null \
        | awk '/events per second/{print $NF}'
}
m_cpu_bogo() {
    stress-ng --cpu "$NTHREADS" --cpu-method all --metrics-brief \
        --timeout "${CPU_DURATION}s" 2>&1 | awk '/cpu /{print $5; exit}'
}

section_cpu() {
    header "CPU"
    if have sysbench; then
        note "tool: sysbench  (single-thread, then ${NTHREADS}-thread)"
        runs_note
        local single multi
        single=$(aggregate m_cpu_single)
        multi=$(aggregate m_cpu_multi)
        row "Single-thread (events/s)" "$(fmt_stat '%.1f' "$single")"
        row "Multi-thread (events/s)"  "$(fmt_stat '%.1f' "$multi")"
        record_stat "cpu_single_eps" "$single"
        record_stat "cpu_multi_eps" "$multi"
    elif have stress-ng; then
        note "tool: stress-ng  (bogo-ops over ${CPU_DURATION}s)"
        runs_note
        local bogo
        bogo=$(aggregate m_cpu_bogo)
        row "Throughput (bogo-ops/s)" "$(fmt_stat '%.1f' "$bogo")"
        record_stat "cpu_bogo_ops" "$bogo"
    elif have python3; then
        note "tool: python fallback  (install 'sysbench' for a real CPU score)"
        runs_note
        local single
        single=$(aggregate cpu_python_score "$CPU_DURATION")
        row "Single-thread (primes/s)" "$(fmt_stat '%.0f' "$single")"
        record_stat "cpu_python_primes" "$single"
    else
        note "no CPU benchmark tool available (install sysbench or stress-ng)"
    fi
}

# ----------------------------------------------------------------------------
# Memory benchmark
# ----------------------------------------------------------------------------
# sysbench memory: print just the numeric MiB/sec throughput.
m_mem_sysbench() {
    sysbench memory --memory-block-size=1K --memory-total-size=10G \
        --memory-oper=write run 2>/dev/null \
        | awk '/transferred/{gsub(/[()]/,""); print $(NF-1)}'
}
# Pure-python memcpy fallback: print bandwidth in GiB/s as a bare number.
m_mem_python() {
    python3 - <<'PY'
import time
size = 256 * 1024 * 1024          # 256 MiB buffer
src = bytearray(size)
reps = 8
start = time.perf_counter()
dst = bytearray(size)
for _ in range(reps):
    dst[:] = src                  # large memcpy
elapsed = time.perf_counter() - start
print(f"{(size * reps) / elapsed / (1024**3):.2f}")
PY
}

section_mem() {
    header "Memory"
    if have sysbench; then
        note "tool: sysbench  (sequential write, 1 KiB blocks)"
        runs_note
        local bw
        bw=$(aggregate m_mem_sysbench)
        row "Throughput (MiB/s)" "$(fmt_stat '%.1f' "$bw")"
        record_stat "mem_throughput_mibps" "$bw"
    else
        note "tool: python fallback  (install 'sysbench' for a real memory score)"
        runs_note
        local bw
        bw=$(aggregate m_mem_python)
        row "memcpy bandwidth (GiB/s)" "$(fmt_stat '%.2f' "$bw")"
        record_stat "mem_memcpy_gibps" "$bw"
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
        runs_note
        local reads="" writes="" tmp out rkb wkb
        for ((r=0; r<RUNS; r++)); do
            tmp=$(mktemp -p "$DISK_DIR" fio.XXXXXX)
            out=$(fio --name=rw --filename="$tmp" --size="${DISK_SIZE_MB}M" \
                      --bs=4k --rw=randrw --rwmixread=70 --direct=1 \
                      --ioengine=libaio --iodepth=16 --runtime=10 --time_based \
                      --group_reporting --minimal 2>/dev/null)
            rm -f "$tmp"
            # minimal format: read BW is field 7 (KB/s), write BW field 48.
            rkb=$(echo "$out" | awk -F';' '{print $7}')
            wkb=$(echo "$out" | awk -F';' '{print $48}')
            [[ -n "$rkb" ]] && reads+="$(awk "BEGIN{print ${rkb:-0}/1024}")"$'\n'
            [[ -n "$wkb" ]] && writes+="$(awk "BEGIN{print ${wkb:-0}/1024}")"$'\n'
        done
        local rd wr
        rd=$(printf '%s' "$reads"  | stats)
        wr=$(printf '%s' "$writes" | stats)
        row "Random read (MB/s)"  "$(fmt_stat '%.1f' "$rd")"
        row "Random write (MB/s)" "$(fmt_stat '%.1f' "$wr")"
        record_stat "disk_rand_read_mbps" "$rd"
        record_stat "disk_rand_write_mbps" "$wr"
    else
        note "tool: dd fallback  (sequential, install 'fio' for random IOPS)"
        (( RUNS > 1 )) && note "(--runs averaging needs fio; running the dd fallback once)"
        TESTFILE="$DISK_DIR/.sysbench_dd_$$"
        # Sequential write.
        local w_line w_speed
        w_line=$(dd if=/dev/zero of="$TESTFILE" bs=1M count="$DISK_SIZE_MB" \
                    oflag=direct 2>&1 || \
                 dd if=/dev/zero of="$TESTFILE" bs=1M count="$DISK_SIZE_MB" \
                    conv=fdatasync 2>&1 || \
                 dd if=/dev/zero of="$TESTFILE" bs=1M count="$DISK_SIZE_MB" 2>&1)
        w_speed=$(echo "$w_line" | awk -F, '/copied|bytes|B\/s/{gsub(/^ +/,"",$NF); print $NF}')
        row "Sequential write" "${w_speed:-n/a}"
        # Drop caches if possible, then sequential read.
        sync
        sysctl -w vm.drop_caches=3 >/dev/null 2>&1 || \
            echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || \
            note "(couldn't drop caches; read figure may be cache-inflated — try sudo)"
        local r_line r_speed
        r_line=$(dd if="$TESTFILE" of=/dev/null bs=1M 2>&1)
        r_speed=$(echo "$r_line" | awk -F, '/copied|bytes|B\/s/{gsub(/^ +/,"",$NF); print $NF}')
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
        runs_note
        local first vals
        first=$(m_gpu_fp16)
        if [[ "$first" == "cuda-unavailable" ]]; then
            note "PyTorch present but CUDA not available to it"
        else
            vals="$first"$'\n'
            local r
            for ((r=1; r<RUNS; r++)); do vals+="$(m_gpu_fp16)"$'\n'; done
            local tflops
            tflops=$(printf '%s' "$vals" | stats)
            row "FP16 matmul (TFLOP/s)" "$(fmt_stat '%.1f' "$tflops")"
            record_stat "gpu_fp16_tflops" "$tflops"
        fi
    else
        note "install PyTorch (torch) for a compute throughput number"
    fi
}

# One FP16 matmul throughput sample in TFLOP/s (or the sentinel "cuda-unavailable").
m_gpu_fp16() {
    python3 - <<'PY'
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
}

# ----------------------------------------------------------------------------
# Network benchmark (iperf3)
# ----------------------------------------------------------------------------
# One iperf3 run; $1 = extra flags ("" for uplink, "-R" for downlink). Prints
# the receiver-side throughput in Mbit/s as a bare number.
m_net() {
    iperf3 -c "$IPERF_HOST" -t "$NET_DURATION" -f m $1 2>/dev/null \
        | awk '/receiver/{ for(i=1;i<=NF;i++) if($i=="Mbits/sec") print $(i-1) }'
}

section_net() {
    header "Network"
    if ! have iperf3; then
        note "iperf3 not installed ($(detect_install_cmd iperf3)) — skipping"
        return
    fi
    if [[ -z "$IPERF_HOST" ]]; then
        note "no target given — pass --iperf-host HOST (with 'iperf3 -s' running there)"
        return
    fi
    note "tool: iperf3  (TCP throughput to ${IPERF_HOST})"
    runs_note
    local up down
    up=$(aggregate m_net "")
    down=$(aggregate m_net "-R")
    row "Uplink (send) Mbit/s"    "$(fmt_stat '%.1f' "$up")"
    row "Downlink (recv) Mbit/s"  "$(fmt_stat '%.1f' "$down")"
    record_stat "net_up_mbps" "$up"
    record_stat "net_down_mbps" "$down"
}

# ----------------------------------------------------------------------------
# JSON output
# ----------------------------------------------------------------------------
# iso_now: ISO-8601 timestamp, portable across GNU and BusyBox/Alpine date.
iso_now() {
    date -Is 2>/dev/null \
        || date -u +%Y-%m-%dT%H:%M:%S%z 2>/dev/null \
        || date +%Y-%m-%dT%H:%M:%S
}

write_json() {
    [[ -z "$JSON_OUT" ]] && return
    {
        echo "{"
        echo "  \"timestamp\": \"$(iso_now)\","
        local first=1
        while IFS=$'\t' read -r k v; do
            [[ -z "$k" ]] && continue
            (( first )) || echo ","
            first=0
            # Emit plain numbers unquoted; everything else as a JSON string.
            if [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                printf '  "%s": %s' "$k" "$v"
            else
                v=${v//\"/\\\"}
                printf '  "%s": "%s"' "$k" "$v"
            fi
        done < "$RESULTS"
        echo ""
        echo "}"
    } > "$JSON_OUT"
    note "JSON written to $JSON_OUT"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
printf '%s%sLinux System Benchmark%s  %s%s%s\n' \
    "$BOLD" "$YLW" "$RST" "$DIM" "$(date '+%Y-%m-%d %H:%M:%S')" "$RST"

(( RUN_INFO )) && section_info
(( RUN_CPU  )) && section_cpu
(( RUN_MEM  )) && section_mem
(( RUN_DISK )) && section_disk
(( RUN_GPU  )) && section_gpu
(( RUN_NET  )) && section_net

write_json
header "Done"
note "Tip: install 'sysbench fio' for higher-fidelity CPU/memory/disk numbers:"
note "     $(detect_install_cmd sysbench fio)"
