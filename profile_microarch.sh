#!/usr/bin/env bash
# ==============================================================================
# profile_microarch.sh - Microarchitectural Profiler for x86-64 & AArch64
# Based on Methodology Note.md
#
# Metrics Computed:
#   - IPC (Instructions Per Cycle) & CPI (Cycles Per Instruction)
#   - IPS (Instructions Per Second) [MIPS / GIPS]
#   - Branch Misprediction Rate (%)
#   - L1D Miss/Load Indicator (%)
#   - Memory Throughput (MB/s & GB/s via LLC Misses * CacheLineSize / Time)
#   - Energy Consumption (Joules & mJ) [via RAPL power/energy-pkg/]
#   - Average Package Power (Watts = Energy / Time)
#   - Wall-Clock Runtime (via hyperfine or perf duration_time)
# ==============================================================================

set -u

# --- Default Configurations ---
CPU_CORE=0
RUNS=10
WARMUP=3
OUT_DIR=""
USE_HYPERFINE=true
MEASURE_ENERGY=true
VERBOSE=false

# --- ANSI Color Codes ---
BOLD="\033[1m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
MAGENTA="\033[1;35m"
RED="\033[1;31m"
NC="\033[0m" # No Color

# --- Help / Usage ---
usage() {
  echo -e "${BOLD}Usage:${NC} $(basename "$0") [OPTIONS] -- <command_or_binary> [args...]

${BOLD}Options:${NC}
  -c, --core <NUM>        CPU core to pin execution with taskset (Default: 0)
  -r, --runs <NUM>        Number of repetitions for measurement (Default: 10)
  -w, --warmup <NUM>      Warmup iterations before benchmarking (Default: 3)
  -o, --out-dir <DIR>     Output directory for markdown/csv reports (Default: ./result/pmu)
      --no-hyperfine      Disable hyperfine benchmarking even if installed
      --no-energy         Skip RAPL energy and power measurement
  -v, --verbose           Print verbose debugging output
  -h, --help              Show this help message and exit

${BOLD}Examples:${NC}
  $(basename "$0") ./x86/bin/Fibo
  $(basename "$0") -c 0 -r 20 -w 5 ./x86/bin/Fibo
  sudo $(basename "$0") -c 0 -r 20 ./x86/bin/Fibo   # Run with sudo to enable RAPL energy profiling
  $(basename "$0") -c 0 -o ./custom_results -- ./my_benchmark arg1 arg2"
  exit 0
}

# --- Parse Command Line Arguments ---
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  -c | --core)
    CPU_CORE="$2"
    shift 2
    ;;
  -r | --runs)
    RUNS="$2"
    shift 2
    ;;
  -w | --warmup)
    WARMUP="$2"
    shift 2
    ;;
  -o | --out-dir)
    OUT_DIR="$2"
    shift 2
    ;;
  --no-hyperfine)
    USE_HYPERFINE=false
    shift 1
    ;;
  --no-energy)
    MEASURE_ENERGY=false
    shift 1
    ;;
  -v | --verbose)
    VERBOSE=true
    shift 1
    ;;
  -h | --help)
    usage
    ;;
  --)
    shift
    POSITIONAL_ARGS+=("$@")
    break
    ;;
  *)
    POSITIONAL_ARGS+=("$1")
    shift
    ;;
  esac
done

if [[ ${#POSITIONAL_ARGS[@]} -eq 0 ]]; then
  echo -e "${RED}Error: No benchmark binary or command specified.${NC}"
  echo "Run '$(basename "$0") --help' for usage."
  exit 1
fi

TARGET_CMD="${POSITIONAL_ARGS[*]}"
TARGET_BIN="${POSITIONAL_ARGS[0]}"

# --- Dependency Verification ---
for cmd in perf taskset awk bc; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}Error: Required command '$cmd' is not installed or not in PATH.${NC}"
    exit 1
  fi
done

# --- System & Topology Discovery ---
ARCH=$(uname -m)
CPU_MODEL=$(lscpu 2>/dev/null | grep -E "Model name|CPU part" | head -n1 | sed -e 's/^[^:]*:[ \t]*//')
[[ -z "$CPU_MODEL" ]] && CPU_MODEL="Unknown CPU ($ARCH)"

# Read cache line size from sysfs (default 64)
CACHE_LINE_SIZE_FILE="/sys/devices/system/cpu/cpu${CPU_CORE}/cache/index0/coherency_line_size"
if [[ -f "$CACHE_LINE_SIZE_FILE" ]]; then
  CACHE_LINE_SIZE=$(cat "$CACHE_LINE_SIZE_FILE" 2>/dev/null || echo 64)
else
  CACHE_LINE_SIZE=64
fi

# Read CPU clock rate
CPU_FREQ_MHZ=$(lscpu 2>/dev/null | grep "CPU MHz" | head -n1 | sed -e 's/^[^:]*:[ \t]*//')
if [[ -z "$CPU_FREQ_MHZ" && -f "/sys/devices/system/cpu/cpu${CPU_CORE}/cpufreq/scaling_cur_freq" ]]; then
  CUR_FREQ_KHZ=$(cat "/sys/devices/system/cpu/cpu${CPU_CORE}/cpufreq/scaling_cur_freq" 2>/dev/null || echo 0)
  CPU_FREQ_MHZ=$(echo "scale=2; $CUR_FREQ_KHZ / 1000" | bc 2>/dev/null || echo "N/A")
fi
[[ -z "$CPU_FREQ_MHZ" ]] && CPU_FREQ_MHZ="N/A"

# Determine Output Directory
if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="./result"
fi
mkdir -p "$OUT_DIR"

TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
BIN_NAME=$(basename "$TARGET_BIN")
REPORT_MD="${OUT_DIR}/profile_${BIN_NAME}_${TIMESTAMP}.md"
REPORT_CSV="${OUT_DIR}/profile_${BIN_NAME}_${TIMESTAMP}.csv"
REPORT_HF_JSON="${OUT_DIR}/profile_${BIN_NAME}_${TIMESTAMP}_hyperfine.json"
PERF_RAW_CSV="${OUT_DIR}/.perf_raw_${BIN_NAME}_${TIMESTAMP}.csv"
PERF_ENERGY_RAW_CSV="${OUT_DIR}/.perf_energy_raw_${BIN_NAME}_${TIMESTAMP}.csv"

# --- Determine Supported PMU Events ---
BASE_EVENTS="instructions,cycles,branches,branch-misses,L1-dcache-loads,L1-dcache-load-misses,LLC-load-misses,LLC-store-misses,duration_time"

# Check permissions for perf
PERF_PREFIX=""
IS_ROOT=false
if [[ $EUID -eq 0 ]]; then
  IS_ROOT=true
else
  PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 2)
  if sudo -n true 2>/dev/null; then
    PERF_PREFIX="sudo"
    IS_ROOT=true
  fi
fi

# --- Banner Display ---
echo -e "${CYAN}======================================================================${NC}"
echo -e "${BOLD}         MICROARCHITECTURAL PROFILER (x86 / ARM)                      ${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo -e " ${BOLD}Target Command:${NC}   $TARGET_CMD"
echo -e " ${BOLD}Architecture:${NC}     $ARCH"
echo -e " ${BOLD}CPU Model:${NC}        $CPU_MODEL"
echo -e " ${BOLD}Core Pinning:${NC}     Core $CPU_CORE (taskset -c $CPU_CORE)"
echo -e " ${BOLD}Cache Line Size:${NC}  $CACHE_LINE_SIZE Bytes"
echo -e " ${BOLD}CPU Frequency:${NC}    $CPU_FREQ_MHZ MHz"
echo -e " ${BOLD}Repetitions:${NC}      $RUNS (Warmup: $WARMUP)"
echo -e "${CYAN}----------------------------------------------------------------------${NC}"

# --- Warmup Execution ---
if [[ "$WARMUP" -gt 0 ]]; then
  echo -e "${YELLOW}[1/4] Running $WARMUP warmup iteration(s)...${NC}"
  for ((i = 1; i <= WARMUP; i++)); do
    taskset -c "$CPU_CORE" $TARGET_CMD >/dev/null 2>&1 || true
  done
fi

# --- Step 1: PMU Counter Profiling via perf stat ---
echo -e "${GREEN}[2/4] Collecting PMU hardware counters over $RUNS run(s)...${NC}"

$PERF_PREFIX perf stat -x, -r "$RUNS" -e "$BASE_EVENTS" taskset -c "$CPU_CORE" $TARGET_CMD >/dev/null 2>"$PERF_RAW_CSV" || {
  echo -e "${RED}Warning: Generic PMU counter collection encountered errors.${NC}"
}

# --- Step 2: Energy & Power Measurement (RAPL power/energy-pkg/) ---
ENERGY_JOULES="N/A"
ENERGY_MJ="N/A"
AVG_POWER_WATTS="N/A"
ENERGY_STATUS_NOTE="N/A"

if [[ "$MEASURE_ENERGY" == "true" ]]; then
  if [[ -f "/sys/bus/event_source/devices/power/events/energy-pkg" ]]; then
    echo -e "${GREEN}[3/4] Measuring Energy Consumption via RAPL (power/energy-pkg/)...${NC}"

    # RAPL uncore counters require root privileges
    $PERF_PREFIX perf stat -x, -r "$RUNS" -e "power/energy-pkg/,duration_time" taskset -c "$CPU_CORE" $TARGET_CMD >/dev/null 2>"$PERF_ENERGY_RAW_CSV" || true

    if [[ -f "$PERF_ENERGY_RAW_CSV" ]]; then
      RAW_E_VAL=$(grep -E ",power/energy-pkg/" "$PERF_ENERGY_RAW_CSV" | head -n1 | cut -d',' -f1 | tr -d ' ' || echo "")
      # Validate strictly as a positive float number
      if [[ "$RAW_E_VAL" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ $(echo "$RAW_E_VAL > 0" | bc -l 2>/dev/null || echo 0) -eq 1 ]]; then
        ENERGY_JOULES=$(awk -v e="$RAW_E_VAL" 'BEGIN { printf "%.4f", e }')
        ENERGY_MJ=$(awk -v e="$RAW_E_VAL" 'BEGIN { printf "%.2f", e * 1000 }')
        ENERGY_STATUS_NOTE="Measured via RAPL (power/energy-pkg/)"
      else
        ENERGY_JOULES="N/A"
        ENERGY_MJ="N/A"
        ENERGY_STATUS_NOTE="N/A (Requires sudo for RAPL power/energy-pkg/)"
      fi
    fi
  else
    echo -e "${BLUE}[3/4] Energy measurement: RAPL not supported on this platform ($ARCH / VM).${NC}"
    ENERGY_STATUS_NOTE="Not supported on $ARCH architecture / Virtual Machine"
  fi
else
  echo -e "${BLUE}[3/4] Energy measurement: Skipped by user (--no-energy).${NC}"
  ENERGY_STATUS_NOTE="Skipped by user flag"
fi

# --- Step 3: Parse PMU Values ---
parse_perf_val() {
  local event_name="$1"
  local file="${2:-$PERF_RAW_CSV}"
  local val
  val=$(grep -E ",${event_name}(:.*)?," "$file" | head -n1 | cut -d',' -f1 | tr -d ' ' || echo 0)
  if [[ -z "$val" || "$val" == "<not" || "$val" == "<not supported>" || "$val" == "<not counted>" ]]; then
    echo "0"
  else
    echo "$val"
  fi
}

# Parse duration time (nanoseconds) from perf stat output
DURATION_NS=$(parse_perf_val "duration_time")
if [[ "$DURATION_NS" != "0" && -n "$DURATION_NS" ]]; then
  ELAPSED_SEC=$(awk -v ns="$DURATION_NS" 'BEGIN { printf "%.6f", ns / 1000000000 }')
else
  # Fallback to general time field
  ELAPSED_SEC=$(grep -E ",seconds,time elapsed|task-clock" "$PERF_RAW_CSV" | head -n1 | cut -d',' -f1 | tr -d ' ' || echo "0.001")
  ELAPSED_SEC=$(awk -v t="$ELAPSED_SEC" 'BEGIN { printf "%.6f", t }')
fi
[[ "$ELAPSED_SEC" == "0.000000" || -z "$ELAPSED_SEC" ]] && ELAPSED_SEC="0.001"

INST_COUNT=$(parse_perf_val "instructions")
CYCLE_COUNT=$(parse_perf_val "cycles")
BRANCH_COUNT=$(parse_perf_val "branches")
BRANCH_MISS=$(parse_perf_val "branch-misses")
L1D_LOADS=$(parse_perf_val "L1-dcache-loads")
L1D_MISSES=$(parse_perf_val "L1-dcache-load-misses")
LLC_LOAD_MISS=$(parse_perf_val "LLC-load-misses")
LLC_STORE_MISS=$(parse_perf_val "LLC-store-misses")

# --- Step 4: Compute Derived Metrics ---
IPC=$(awk -v inst="$INST_COUNT" -v cyc="$CYCLE_COUNT" 'BEGIN { if (cyc > 0) printf "%.4f", inst / cyc; else print "0.0000" }')
CPI=$(awk -v inst="$INST_COUNT" -v cyc="$CYCLE_COUNT" 'BEGIN { if (inst > 0) printf "%.4f", cyc / inst; else print "0.0000" }')

MIPS=$(awk -v inst="$INST_COUNT" -v sec="$ELAPSED_SEC" 'BEGIN { if (sec > 0) printf "%.2f", (inst / sec) / 1000000; else print "0.00" }')
GIPS=$(awk -v inst="$INST_COUNT" -v sec="$ELAPSED_SEC" 'BEGIN { if (sec > 0) printf "%.4f", (inst / sec) / 1000000000; else print "0.0000" }')

BRANCH_MISS_RATE=$(awk -v miss="$BRANCH_MISS" -v total="$BRANCH_COUNT" 'BEGIN { if (total > 0) printf "%.4f", (miss * 100.0) / total; else print "0.0000" }')
L1D_MISS_RATE=$(awk -v miss="$L1D_MISSES" -v total="$L1D_LOADS" 'BEGIN { if (total > 0) printf "%.4f", (miss * 100.0) / total; else print "0.0000" }')

# Memory Throughput calculation:
# Total LLC Misses = LLC-load-misses + LLC-store-misses
# Memory Traffic = Total LLC Misses * CacheLineSize Bytes
TOTAL_LLC_MISSES=$(awk -v l="$LLC_LOAD_MISS" -v s="$LLC_STORE_MISS" 'BEGIN { printf "%.0f", l + s }')
MEM_TRAFFIC_BYTES=$(awk -v m="$TOTAL_LLC_MISSES" -v cls="$CACHE_LINE_SIZE" 'BEGIN { printf "%.0f", m * cls }')
MEM_TRAFFIC_MB=$(awk -v b="$MEM_TRAFFIC_BYTES" 'BEGIN { printf "%.6f", b / (1024 * 1024) }')

MEM_THROUGHPUT_MBS=$(awk -v mb="$MEM_TRAFFIC_MB" -v sec="$ELAPSED_SEC" 'BEGIN { if (sec > 0) printf "%.3f", mb / sec; else print "0.000" }')
MEM_THROUGHPUT_GBS=$(awk -v mbs="$MEM_THROUGHPUT_MBS" 'BEGIN { printf "%.4f", mbs / 1024 }')

# Calculate Average Power if Energy is measured
if [[ "$ENERGY_JOULES" != "N/A" ]]; then
  AVG_POWER_WATTS=$(awk -v j="$ENERGY_JOULES" -v sec="$ELAPSED_SEC" 'BEGIN { if (sec > 0) printf "%.3f", j / sec; else print "N/A" }')
fi

# --- Step 5: Hyperfine Benchmarking (Optional / Wall-Clock) ---
HYPERFINE_MEAN="N/A"
HYPERFINE_MIN="N/A"
HYPERFINE_MAX="N/A"

if [[ "$USE_HYPERFINE" == "true" ]] && command -v hyperfine &>/dev/null; then
  echo -e "${BLUE}[4/4] Running high-precision wall-clock benchmarking via hyperfine...${NC}"
  HF_OUTPUT=$(hyperfine --warmup "$WARMUP" --runs "$RUNS" --export-json "$REPORT_HF_JSON" "taskset -c $CPU_CORE $TARGET_CMD" 2>&1)

  # Extract Mean, Min, Max from hyperfine output
  HF_LINE=$(echo "$HF_OUTPUT" | grep "Time (mean ± σ):" | head -n1)
  if [[ -n "$HF_LINE" ]]; then
    HYPERFINE_MEAN=$(echo "$HF_LINE" | sed -e 's/.*Time (mean ± σ):[ \t]*//' | awk '{print $1, $2, $3, $4}')
  fi
  HF_RANGE=$(echo "$HF_OUTPUT" | grep "Range (min … max):" | head -n1)
  if [[ -n "$HF_RANGE" ]]; then
    HYPERFINE_MIN=$(echo "$HF_RANGE" | awk '{print $4, $5}')
    HYPERFINE_MAX=$(echo "$HF_RANGE" | awk '{print $6, $7}')
  fi
else
  echo -e "${BLUE}[4/4] Hyperfine skipped (using perf elapsed time: ${ELAPSED_SEC} s).${NC}"
fi

# --- Format Numbers with Commas ---
format_num() {
  local val="$1"
  if [[ "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    printf "%'d" "${val%.*}" 2>/dev/null || echo "$val"
  else
    echo "$val"
  fi
}

# --- Step 6: Display Terminal Summary Dashboard ---
echo -e "\n${CYAN}======================================================================${NC}"
echo -e "${BOLD}                     MICROARCHITECTURAL METRICS                       ${NC}"
echo -e "${CYAN}======================================================================${NC}"

printf " ${BOLD}%-34s${NC} : ${GREEN}%s${NC}\n" "Instructions Per Cycle (IPC)" "$IPC"
printf " ${BOLD}%-34s${NC} : ${GREEN}%s${NC}\n" "Cycles Per Instruction (CPI)" "$CPI"
printf " ${BOLD}%-34s${NC} : ${CYAN}%s MIPS (%s GIPS)${NC}\n" "Instructions Per Second (IPS)" "$MIPS" "$GIPS"
printf " ${BOLD}%-34s${NC} : ${YELLOW}%s %%${NC}\n" "Branch Misprediction Rate" "$BRANCH_MISS_RATE"
printf " ${BOLD}%-34s${NC} : ${YELLOW}%s %%${NC}\n" "L1D Load Miss Rate" "$L1D_MISS_RATE"
printf " ${BOLD}%-34s${NC} : ${MAGENTA}%s MB/s (%s GB/s)${NC}\n" "Memory Throughput (LLC Misses)" "$MEM_THROUGHPUT_MBS" "$MEM_THROUGHPUT_GBS"

# Always display Energy & Power rows
if [[ "$ENERGY_JOULES" != "N/A" ]]; then
  printf " ${BOLD}%-34s${NC} : ${GREEN}%s J (%s mJ)${NC}\n" "Energy Consumption (Package)" "$ENERGY_JOULES" "$ENERGY_MJ"
  printf " ${BOLD}%-34s${NC} : ${GREEN}%s W${NC}\n" "Average Package Power" "$AVG_POWER_WATTS"
else
  printf " ${BOLD}%-34s${NC} : ${YELLOW}%s${NC}\n" "Energy Consumption (Package)" "$ENERGY_STATUS_NOTE"
  printf " ${BOLD}%-34s${NC} : ${YELLOW}N/A${NC}\n" "Average Package Power"
fi

if [[ "$HYPERFINE_MEAN" != "N/A" ]]; then
  printf " ${BOLD}%-34s${NC} : ${BLUE}%s${NC}\n" "Wall-Clock Time (hyperfine)" "$HYPERFINE_MEAN"
else
  printf " ${BOLD}%-34s${NC} : ${BLUE}%s s${NC}\n" "Wall-Clock Time (perf stat)" "$ELAPSED_SEC"
fi

echo -e "${CYAN}----------------------------------------------------------------------${NC}"
echo -e "${BOLD}Raw Hardware Event Counts (Averaged over $RUNS runs):${NC}"
printf "  • %-28s : %s\n" "Retired Instructions" "$(format_num "$INST_COUNT")"
printf "  • %-28s : %s\n" "CPU Cycles" "$(format_num "$CYCLE_COUNT")"
printf "  • %-28s : %s\n" "Total Branches" "$(format_num "$BRANCH_COUNT")"
printf "  • %-28s : %s\n" "Branch Mispredictions" "$(format_num "$BRANCH_MISS")"
printf "  • %-28s : %s\n" "L1 D-Cache Loads" "$(format_num "$L1D_LOADS")"
printf "  • %-28s : %s\n" "L1 D-Cache Load Misses" "$(format_num "$L1D_MISSES")"
printf "  • %-28s : %s\n" "LLC Load Misses" "$(format_num "$LLC_LOAD_MISS")"
printf "  • %-28s : %s\n" "LLC Store Misses" "$(format_num "$LLC_STORE_MISS")"
printf "  • %-28s : %s Bytes\n" "Estimated DRAM Traffic" "$(format_num "$MEM_TRAFFIC_BYTES")"
printf "  • %-28s : %s s\n" "Execution Time" "$ELAPSED_SEC"
echo -e "${CYAN}======================================================================${NC}"

# --- Step 7: Export Markdown Report ---
cat <<EOF >"$REPORT_MD"
# Microarchitectural Profile Report: \`$BIN_NAME\`

- **Target Command:** \`$TARGET_CMD\`
- **Date & Time:** $(date "+%Y-%m-%d %H:%M:%S %Z")
- **Architecture:** \`$ARCH\`
- **CPU Model:** $CPU_MODEL
- **Core Pinning:** CPU Core $CPU_CORE (\`taskset -c $CPU_CORE\`)
- **Cache Line Size:** $CACHE_LINE_SIZE Bytes
- **Runs / Warmup:** $RUNS runs (Warmup: $WARMUP)

---

## 1. Primary Derived Metrics

| Metric Category | Metric Name | Value | Unit / Formula |
| :--- | :--- | :--- | :--- |
| **Instruction Execution** | **IPC** | **$IPC** | Instructions / Cycle |
| | **CPI** | **$CPI** | Cycles / Instruction |
| | **IPS** | **$MIPS MIPS** ($GIPS GIPS) | Instructions / Second |
| **Branch Predictor** | **Branch Misprediction Rate** | **$BRANCH_MISS_RATE %** | \`(branch-misses / branches) * 100\` |
| **L1 Data Cache** | **L1D Load Miss Rate** | **$L1D_MISS_RATE %** | \`(L1-dcache-load-misses / L1-dcache-loads) * 100\` |
| **Memory Subsystem** | **Memory Throughput** | **$MEM_THROUGHPUT_MBS MB/s** | ($MEM_THROUGHPUT_GBS GB/s) |
| | **Estimated DRAM Traffic** | **$MEM_TRAFFIC_MB MB** | \`LLC_Misses * $CACHE_LINE_SIZE Bytes\` |
| **Energy & Power** | **Energy Consumption** | **$([ "$ENERGY_JOULES" != "N/A" ] && echo "$ENERGY_JOULES J ($ENERGY_MJ mJ)" || echo "$ENERGY_STATUS_NOTE")** | RAPL package energy |
| | **Average Package Power** | **$([ "$AVG_POWER_WATTS" != "N/A" ] && echo "$AVG_POWER_WATTS W" || echo "N/A")** | \`Energy / Time\` |
| **Runtime** | **Wall-Clock Time** | **$([ "$HYPERFINE_MEAN" != "N/A" ] && echo "$HYPERFINE_MEAN" || echo "$ELAPSED_SEC s")** | Measured via $([ "$HYPERFINE_MEAN" != "N/A" ] && echo "hyperfine" || echo "perf") |

---

## 2. Raw Hardware Performance Counters

| Event Name | Event Value (Avg over $RUNS runs) | Description |
| :--- | :--- | :--- |
| \`instructions\` | $(format_num "$INST_COUNT") | Total retired instructions |
| \`cycles\` | $(format_num "$CYCLE_COUNT") | Total core unhalted CPU cycles |
| \`branches\` | $(format_num "$BRANCH_COUNT") | Total conditional & unconditional branches |
| \`branch-misses\` | $(format_num "$BRANCH_MISS") | Speculative branch mispredictions |
| \`L1-dcache-loads\` | $(format_num "$L1D_LOADS") | L1 Data Cache load requests |
| \`L1-dcache-load-misses\` | $(format_num "$L1D_MISSES") | L1 Data Cache load misses |
| \`LLC-load-misses\` | $(format_num "$LLC_LOAD_MISS") | Last Level Cache read misses |
| \`LLC-store-misses\` | $(format_num "$LLC_STORE_MISS") | Last Level Cache write misses |
| \`duration_time\` | ${ELAPSED_SEC} s | Total benchmark execution time |

EOF

# --- Step 8: Export CSV Report ---
cat <<EOF >"$REPORT_CSV"
Metric,Value,Unit
Command,"$TARGET_CMD",command
Architecture,"$ARCH",arch
CPU_Model,"$CPU_MODEL",cpu
Core_Pinned,$CPU_CORE,core
Cache_Line_Size,$CACHE_LINE_SIZE,bytes
Runs,$RUNS,count
Warmup,$WARMUP,count
IPC,$IPC,inst_per_cycle
CPI,$CPI,cycles_per_inst
IPS_MIPS,$MIPS,MIPS
IPS_GIPS,$GIPS,GIPS
Branch_Miss_Rate_pct,$BRANCH_MISS_RATE,percentage
L1D_Miss_Rate_pct,$L1D_MISS_RATE,percentage
Memory_Throughput_MBs,$MEM_THROUGHPUT_MBS,MB_per_sec
Memory_Throughput_GBs,$MEM_THROUGHPUT_GBS,GB_per_sec
DRAM_Traffic_MB,$MEM_TRAFFIC_MB,MB
Energy_Joules,$ENERGY_JOULES,joules
Energy_mJ,$ENERGY_MJ,mJ
Average_Power_Watts,$AVG_POWER_WATTS,watts
Elapsed_Time_Sec,$ELAPSED_SEC,seconds
Instructions,$INST_COUNT,count
Cycles,$CYCLE_COUNT,count
Branches,$BRANCH_COUNT,count
Branch_Misses,$BRANCH_MISS,count
L1D_Loads,$L1D_LOADS,count
L1D_Misses,$L1D_MISSES,count
LLC_Load_Misses,$LLC_LOAD_MISS,count
LLC_Store_Misses,$LLC_STORE_MISS,count
EOF

# Clean up raw perf temp files if not verbose
if [[ "$VERBOSE" != "true" ]]; then
  rm -f "$PERF_RAW_CSV" "$PERF_ENERGY_RAW_CSV"
fi

echo -e "${GREEN}✔ Reports successfully generated:${NC}"
echo -e "  • Markdown Report : ${REPORT_MD}"
echo -e "  • CSV Data Report : ${REPORT_CSV}"
if [[ "$USE_HYPERFINE" == "true" && -f "$REPORT_HF_JSON" ]]; then
  echo -e "  • Hyperfine JSON  : ${REPORT_HF_JSON}"
fi
echo ""
