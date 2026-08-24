#!/usr/bin/env bash
# ==============================================================================
# profile_emerald_rapids.sh - Profiler for Intel Emerald Rapids (x86_64)
# Based on: Notes/Emerald_Rapid_events.md
#
# Performance Events Tracked:
#   - cpu/event=0x3c,umask=0x00/ : CPU_CLK_UNHALTED.THREAD      (Core cycles when thread is not in halt)
#   - cpu/event=0xc0,umask=0x00/ : INST_RETIRED.ANY             (Retired X86 instructions)
#   - cpu/event=0xc4,umask=0x00/ : BR_INST_RETIRED.ALL_BRANCHES (All branch instructions retired)
#   - cpu/event=0xc5,umask=0x00/ : BR_MISP_RETIRED.ALL_BRANCHES (All mispredicted branch instructions)
#   - cpu/event=0xd1,umask=0x08/ : MEM_LOAD_RETIRED.L1_MISS     (Load instructions that missed L1 cache)
#   - cpu/event=0xd0,umask=0x81/ : MEM_INST_RETIRED.ALL_LOADS   (All retired load instructions)
#   - cpu/event=0x25,umask=0x1f/ : L2_LINES_IN.ALL              (L2 cache lines filling L2)
#   - cpu/event=0x26,umask=0x02/ : L2_LINES_OUT.NON_SILENT      (Modified cache lines evicted to L3)
#   - duration_time                                             (Execution duration)
#
# Metrics Computed (from Notes/Emerald_Rapid_events.md):
#   1. MIPS & IPS:
#        IPS  = INST_RETIRED.ANY / t_elapsed
#        MIPS = INST_RETIRED.ANY / (t_elapsed * 10^6)
#   2. IPC:
#        IPC  = INST_RETIRED.ANY / CPU_CLK_UNHALTED.THREAD
#   3. Branch Misprediction Rate (%):
#        Branch Misprediction Rate (%) = (BR_MISP_RETIRED.ALL_BRANCHES / BR_INST_RETIRED.ALL_BRANCHES) * 100%
#   4. L1 D-Cache Demand Load Miss Rate (%):
#        L1D Miss Rate (%) = (MEM_LOAD_RETIRED.L1_MISS / MEM_INST_RETIRED.ALL_LOADS) * 100%
#   5. L2 Cache Throughput & Bandwidth (64B per line):
#        L2 Total Throughput (MB/s) = ((L2_LINES_IN.ALL + L2_LINES_OUT.NON_SILENT) * 64 / 10^6) / t_elapsed
# ==============================================================================

set -u

# --- Default Configurations ---
CPU_CORE=0
USE_TASKSET=true
RUNS=10
WARMUP=3
OUT_DIR=""
USE_HYPERFINE=true
HYPERFINE_ONLY=false
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
  echo -e "${BOLD}Usage:${NC} $(basename "$0") [OPTIONS] -- <command_or_binary> [args...]"
  echo ""
  echo -e "${BOLD}Options:${NC}"
  echo "  -c, --core <NUM>        CPU core to pin execution with taskset (Default: 0)"
  echo "      --no-pin            Disable CPU core pinning (taskset)"
  echo "  -r, --runs <NUM>        Number of repetitions for measurement (Default: 10)"
  echo "  -w, --warmup <NUM>      Warmup iterations before benchmarking (Default: 3)"
  echo "  -o, --out-dir <DIR>     Output directory for markdown/csv reports (Default: ./result)"
  echo "      --no-hyperfine      Disable hyperfine benchmarking even if installed"
  echo "      --hyperfine-only    Run only hyperfine wall-clock benchmark (skip PMU profiling)"
  echo "  -v, --verbose           Print verbose debugging output"
  echo "  -h, --help              Show this help message and exit"
  echo ""
  echo -e "${BOLD}Examples:${NC}"
  echo "  $(basename "$0") ./bin/silent/matrix_multiply"
  echo "  $(basename "$0") -c 0 -r 20 -w 5 ./bin/silent/sha256"
  echo "  $(basename "$0") --no-pin -r 20 ./bin/silent/sha256"
  echo "  $(basename "$0") --hyperfine-only -r 50 ./bin/silent/sha256"
  echo "  $(basename "$0") -c 0 -o ./result -- ./bin/silent/array_sort"
  exit 0
}

# --- Parse Command Line Arguments ---
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  -c | --core)
    if [[ "$2" == "none" || "$2" == "off" || "$2" == "-1" || "$2" == "false" ]]; then
      USE_TASKSET=false
    else
      CPU_CORE="$2"
      USE_TASKSET=true
    fi
    shift 2
    ;;
  --no-pin | --no-taskset | --disable-taskset)
    USE_TASKSET=false
    shift 1
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
  --hyperfine-only | --only-hyperfine)
    HYPERFINE_ONLY=true
    USE_HYPERFINE=true
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

if [[ "$HYPERFINE_ONLY" == "true" && "$USE_HYPERFINE" == "false" ]]; then
  echo -e "${RED}Error: Conflicting options --hyperfine-only and --no-hyperfine specified.${NC}"
  exit 1
fi

TARGET_CMD="${POSITIONAL_ARGS[*]}"
TARGET_BIN="${POSITIONAL_ARGS[0]}"

# --- Dependency Verification ---
REQUIRED_CMDS=("awk" "bc")
if [[ "$HYPERFINE_ONLY" == "true" ]]; then
  REQUIRED_CMDS+=("hyperfine")
else
  REQUIRED_CMDS+=("perf")
fi
if [[ "$USE_TASKSET" == "true" ]]; then
  REQUIRED_CMDS+=("taskset")
fi
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}Error: Required command '$cmd' is not installed or not in PATH.${NC}"
    exit 1
  fi
done

# --- System & Topology Discovery ---
ARCH=$(uname -m)
CPU_MODEL=$(lscpu 2>/dev/null | grep -E "Model name" | head -n1 | sed -e 's/^[^:]*:[ \t]*//')
[[ -z "$CPU_MODEL" ]] && CPU_MODEL="Intel Xeon (Emerald Rapids) ($ARCH)"

# Cache line size (64 Bytes)
if [[ "$USE_TASKSET" == "true" ]]; then
  CACHE_LINE_SIZE_FILE="/sys/devices/system/cpu/cpu${CPU_CORE}/cache/index0/coherency_line_size"
else
  CACHE_LINE_SIZE_FILE="/sys/devices/system/cpu/cpu0/cache/index0/coherency_line_size"
fi
if [[ -f "$CACHE_LINE_SIZE_FILE" ]]; then
  CACHE_LINE_SIZE=$(cat "$CACHE_LINE_SIZE_FILE" 2>/dev/null || echo 64)
else
  CACHE_LINE_SIZE=64
fi

# CPU frequency
CPU_FREQ_MHZ=$(lscpu 2>/dev/null | grep "CPU MHz" | head -n1 | sed -e 's/^[^:]*:[ \t]*//')
CPU_FREQ_FILE="/sys/devices/system/cpu/cpu${CPU_CORE}/cpufreq/scaling_cur_freq"
[[ "$USE_TASKSET" != "true" ]] && CPU_FREQ_FILE="/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
if [[ -z "$CPU_FREQ_MHZ" && -f "$CPU_FREQ_FILE" ]]; then
  CUR_FREQ_KHZ=$(cat "$CPU_FREQ_FILE" 2>/dev/null || echo 0)
  CPU_FREQ_MHZ=$(echo "scale=2; $CUR_FREQ_KHZ / 1000" | bc 2>/dev/null || echo "N/A")
fi
[[ -z "$CPU_FREQ_MHZ" ]] && CPU_FREQ_MHZ="N/A"

# Output Directory
if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="./result"
fi
mkdir -p "$OUT_DIR"

TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
BIN_NAME=$(basename "$TARGET_BIN")
REPORT_MD="${OUT_DIR}/profile_emerald_rapids_${BIN_NAME}_${TIMESTAMP}.md"
REPORT_CSV="${OUT_DIR}/profile_emerald_rapids_${BIN_NAME}_${TIMESTAMP}.csv"
REPORT_HF_JSON="${OUT_DIR}/profile_emerald_rapids_${BIN_NAME}_${TIMESTAMP}_hyperfine.json"
PERF_RAW_CSV="${OUT_DIR}/.perf_raw_${BIN_NAME}_${TIMESTAMP}.csv"

# --- Explicitly Specify All Intel Emerald Rapids PMU Events for perf stat ---
EMR_EVENTS="\
cpu/event=0x3c,umask=0x00,name=CPU_CLK_UNHALTED.THREAD/,\
cpu/event=0xc0,umask=0x00,name=INST_RETIRED.ANY/,\
cpu/event=0xc4,umask=0x00,name=BR_INST_RETIRED.ALL_BRANCHES/,\
cpu/event=0xc5,umask=0x00,name=BR_MISP_RETIRED.ALL_BRANCHES/,\
cpu/event=0xd1,umask=0x08,name=MEM_LOAD_RETIRED.L1_MISS/,\
cpu/event=0xd0,umask=0x81,name=MEM_INST_RETIRED.ALL_LOADS/,\
cpu/event=0x25,umask=0x1f,name=L2_LINES_IN.ALL/,\
cpu/event=0x26,umask=0x02,name=L2_LINES_OUT.NON_SILENT/,\
duration_time"

# Check sudo / perf permissions
PERF_PREFIX=""
if [[ $EUID -ne 0 ]]; then
  if sudo -n true 2>/dev/null; then
    PERF_PREFIX="sudo"
  fi
fi

# Taskset execution prefix
TASKSET_PREFIX=""
if [[ "$USE_TASKSET" == "true" ]]; then
  TASKSET_PREFIX="taskset -c $CPU_CORE"
  PINNING_INFO="Core $CPU_CORE (taskset -c $CPU_CORE)"
  PINNING_MD="Core $CPU_CORE (\`taskset -c $CPU_CORE\`)"
  PINNING_CSV="$CPU_CORE"
else
  PINNING_INFO="Disabled"
  PINNING_MD="Disabled (No core pinning)"
  PINNING_CSV="None"
fi

# --- Banner Display ---
echo -e "${CYAN}======================================================================${NC}"
if [[ "$HYPERFINE_ONLY" == "true" ]]; then
  echo -e "${BOLD}         INTEL EMERALD RAPIDS BENCHMARK (HYPERFINE ONLY)              ${NC}"
else
  echo -e "${BOLD}         INTEL EMERALD RAPIDS HARDWARE PROFILER                       ${NC}"
fi
echo -e "${CYAN}======================================================================${NC}"
echo -e " ${BOLD}Target Command:${NC}   $TARGET_CMD"
echo -e " ${BOLD}Architecture:${NC}     $ARCH"
echo -e " ${BOLD}CPU Model:${NC}        $CPU_MODEL"
echo -e " ${BOLD}Core Pinning:${NC}     $PINNING_INFO"
echo -e " ${BOLD}Cache Line Size:${NC}  $CACHE_LINE_SIZE Bytes"
echo -e " ${BOLD}CPU Frequency:${NC}    $CPU_FREQ_MHZ MHz"
echo -e " ${BOLD}Repetitions:${NC}      $RUNS (Warmup: $WARMUP)"
if [[ "$HYPERFINE_ONLY" != "true" ]]; then
  echo -e " ${BOLD}PMU Events:${NC}       CPU_CLK_UNHALTED.THREAD (0x3c,0x00), INST_RETIRED.ANY (0xc0,0x00),"
  echo -e "                     BR_INST_RETIRED.ALL_BRANCHES (0xc4,0x00),"
  echo -e "                     BR_MISP_RETIRED.ALL_BRANCHES (0xc5,0x00),"
  echo -e "                     MEM_LOAD_RETIRED.L1_MISS (0xd1,0x08),"
  echo -e "                     MEM_INST_RETIRED.ALL_LOADS (0xd0,0x81),"
  echo -e "                     L2_LINES_IN.ALL (0x25,0x1f),"
  echo -e "                     L2_LINES_OUT.NON_SILENT (0x26,0x02)"
fi
echo -e "${CYAN}----------------------------------------------------------------------${NC}"

# --- Hyperfine Only Execution Branch ---
if [[ "$HYPERFINE_ONLY" == "true" ]]; then
  echo -e "${BLUE}[1/1] Running high-precision wall-clock benchmarking via hyperfine...${NC}"
  HF_CMD="$TARGET_CMD"
  [[ "$USE_TASKSET" == "true" ]] && HF_CMD="taskset -c $CPU_CORE $TARGET_CMD"
  HF_OUTPUT=$(hyperfine --warmup "$WARMUP" --runs "$RUNS" --export-json "$REPORT_HF_JSON" "$HF_CMD" 2>&1)
  echo "$HF_OUTPUT"

  HF_MEAN_LINE=$(echo "$HF_OUTPUT" | grep "Time (mean ± σ):" | head -n1)
  HYPERFINE_MEAN="N/A"
  if [[ -n "$HF_MEAN_LINE" ]]; then
    HYPERFINE_MEAN=$(echo "$HF_MEAN_LINE" | sed -e 's/.*Time (mean ± σ):[ \t]*//' -e 's/\[User:.*//' | sed -e 's/[ \t]*$//')
  fi
  HF_RANGE_LINE=$(echo "$HF_OUTPUT" | grep "Range (min … max):" | head -n1)
  HYPERFINE_MIN="N/A"
  HYPERFINE_MAX="N/A"
  if [[ -n "$HF_RANGE_LINE" ]]; then
    HYPERFINE_RANGE=$(echo "$HF_RANGE_LINE" | sed -e 's/.*Range (min … max):[ \t]*//' -e 's/[0-9][0-9]* runs.*//' | sed -e 's/[ \t]*$//')
    HYPERFINE_MIN=$(echo "$HYPERFINE_RANGE" | awk -F '…' '{print $1}' | sed -e 's/[ \t]*$//')
    HYPERFINE_MAX=$(echo "$HYPERFINE_RANGE" | awk -F '…' '{print $2}' | sed -e 's/^[ \t]*//')
  fi

  # Terminal Output Dashboard
  echo -e "\n${CYAN}======================================================================${NC}"
  echo -e "${BOLD}                     HYPERFINE BENCHMARK RESULTS                      ${NC}"
  echo -e "${CYAN}======================================================================${NC}"
  printf " ${BOLD}%-34s${NC} : ${BLUE}%s${NC}\n" "Wall-Clock Time (mean ± σ)" "$HYPERFINE_MEAN"
  if [[ "$HYPERFINE_MIN" != "N/A" && "$HYPERFINE_MAX" != "N/A" ]]; then
    printf " ${BOLD}%-34s${NC} : %s … %s\n" "Range (min … max)" "$HYPERFINE_MIN" "$HYPERFINE_MAX"
  fi
  printf " ${BOLD}%-34s${NC} : %s (Warmup: %s)\n" "Repetitions" "$RUNS" "$WARMUP"
  echo -e "${CYAN}======================================================================${NC}"

  # Export Markdown Report
  cat <<EOF >"$REPORT_MD"
# Intel Emerald Rapids Benchmark Report: \`$BIN_NAME\` (Hyperfine)

- **Target Command:** \`$TARGET_CMD\`
- **Date & Time:** $(date "+%Y-%m-%d %H:%M:%S %Z")
- **Architecture:** \`$ARCH\` (Intel Emerald Rapids)
- **CPU Model:** $CPU_MODEL
- **Core Pinning:** $PINNING_MD
- **Cache Line Size:** $CACHE_LINE_SIZE Bytes
- **Runs / Warmup:** $RUNS runs (Warmup: $WARMUP)

---

## Hyperfine Wall-Clock Benchmark Results

| Metric | Value | Description |
| :--- | :--- | :--- |
| **Wall-Clock Time (mean ± σ)** | **$HYPERFINE_MEAN** | Measured via hyperfine |
$([ "$HYPERFINE_MIN" != "N/A" ] && echo "| **Min … Max Range** | $HYPERFINE_MIN … $HYPERFINE_MAX | Execution time bounds |")
| **Repetitions** | $RUNS runs (Warmup: $WARMUP) | Measurement samples |
EOF

  # Export CSV Report
  cat <<EOF >"$REPORT_CSV"
Metric,Value,Unit
Command,"$TARGET_CMD",command
Architecture,"$ARCH",arch
CPU_Model,"$CPU_MODEL",cpu
Core_Pinned,$PINNING_CSV,core
Cache_Line_Size,$CACHE_LINE_SIZE,bytes
Runs,$RUNS,count
Warmup,$WARMUP,count
Hyperfine_Mean,"$HYPERFINE_MEAN",time_str
Hyperfine_Min,"$HYPERFINE_MIN",time_str
Hyperfine_Max,"$HYPERFINE_MAX",time_str
EOF

  echo -e "${GREEN}✔ Reports successfully generated:${NC}"
  echo -e "  • Markdown Report : ${REPORT_MD}"
  echo -e "  • CSV Data Report : ${REPORT_CSV}"
  if [[ -f "$REPORT_HF_JSON" ]]; then
    echo -e "  • Hyperfine JSON  : ${REPORT_HF_JSON}"
  fi
  echo ""
  exit 0
fi

# --- Warmup Execution ---
if [[ "$WARMUP" -gt 0 ]]; then
  echo -e "${YELLOW}[1/3] Running $WARMUP warmup iteration(s)...${NC}"
  for ((i = 1; i <= WARMUP; i++)); do
    $TASKSET_PREFIX $TARGET_CMD >/dev/null 2>&1 || true
  done
fi

# --- Step 1: Collect Hardware Counters via perf stat ---
echo -e "${GREEN}[2/3] Collecting Intel Emerald Rapids PMU counters over $RUNS run(s)...${NC}"
$PERF_PREFIX perf stat -x, -r "$RUNS" -e "$EMR_EVENTS" $TASKSET_PREFIX $TARGET_CMD >/dev/null 2>"$PERF_RAW_CSV" || {
  echo -e "${YELLOW}Notice: Retrying with standard hardware event aliases...${NC}"
  $PERF_PREFIX perf stat -x, -r "$RUNS" -e "cycles,instructions,branches,branch-misses,L1-dcache-load-misses,L1-dcache-loads,duration_time" $TASKSET_PREFIX $TARGET_CMD >/dev/null 2>"$PERF_RAW_CSV" || true
}

# --- Step 2: Parse PMU Values ---
parse_pmu_val() {
  local event_name="$1"
  local file="${2:-$PERF_RAW_CSV}"
  local val
  val=$(grep -i -E ",.*${event_name}.*," "$file" | head -n1 | cut -d',' -f1 | tr -d ' ' || echo 0)
  if [[ -z "$val" || "$val" == "<not" || "$val" == "<not supported>" || "$val" == "<not counted>" ]]; then
    echo "0"
  else
    echo "$val"
  fi
}

DURATION_NS=$(parse_pmu_val "duration_time")
if [[ "$DURATION_NS" != "0" && -n "$DURATION_NS" ]]; then
  ELAPSED_SEC=$(awk -v ns="$DURATION_NS" 'BEGIN { printf "%.6f", ns / 1000000000 }')
else
  ELAPSED_SEC=$(grep -E ",seconds,time elapsed|task-clock" "$PERF_RAW_CSV" | head -n1 | cut -d',' -f1 | tr -d ' ' || echo "0.001")
  ELAPSED_SEC=$(awk -v t="$ELAPSED_SEC" 'BEGIN { printf "%.6f", t }')
fi
[[ "$ELAPSED_SEC" == "0.000000" || -z "$ELAPSED_SEC" ]] && ELAPSED_SEC="0.001"

CPU_CLK_UNHALTED_THREAD=$(parse_pmu_val "CPU_CLK_UNHALTED|cycles")
INST_RETIRED_ANY=$(parse_pmu_val "INST_RETIRED|instructions")
BR_INST_RETIRED_ALL_BRANCHES=$(parse_pmu_val "BR_INST_RETIRED|branches")
BR_MISP_RETIRED_ALL_BRANCHES=$(parse_pmu_val "BR_MISP_RETIRED|branch-misses")
MEM_LOAD_RETIRED_L1_MISS=$(parse_pmu_val "MEM_LOAD_RETIRED|L1-dcache-load-misses")
MEM_INST_RETIRED_ALL_LOADS=$(parse_pmu_val "MEM_INST_RETIRED|L1-dcache-loads")
L2_LINES_IN_ALL=$(parse_pmu_val "L2_LINES_IN")
L2_LINES_OUT_NON_SILENT=$(parse_pmu_val "L2_LINES_OUT")

# --- Step 3: Compute Derived Metrics (from Notes/Emerald_Rapid_events.md) ---

# Metric 1: MIPS & IPS
IPS=$(awk -v inst="$INST_RETIRED_ANY" -v sec="$ELAPSED_SEC" 'BEGIN { if (sec > 0) printf "%.2f", inst / sec; else print "0.00" }')
MIPS=$(awk -v inst="$INST_RETIRED_ANY" -v sec="$ELAPSED_SEC" 'BEGIN { if (sec > 0) printf "%.2f", inst / (sec * 1000000); else print "0.00" }')

# Metric 2: IPC = INST_RETIRED.ANY / CPU_CLK_UNHALTED.THREAD
IPC=$(awk -v inst="$INST_RETIRED_ANY" -v cyc="$CPU_CLK_UNHALTED_THREAD" 'BEGIN { if (cyc > 0) printf "%.4f", inst / cyc; else print "0.0000" }')

# Metric 3: Branch Misprediction Rate (%) = (BR_MISP_RETIRED.ALL_BRANCHES / BR_INST_RETIRED.ALL_BRANCHES) * 100%
BRANCH_MISP_RATE=$(awk -v misp="$BR_MISP_RETIRED_ALL_BRANCHES" -v br="$BR_INST_RETIRED_ALL_BRANCHES" 'BEGIN { if (br > 0) printf "%.4f", (misp * 100.0) / br; else print "0.0000" }')

# Metric 4: L1 D-Cache Demand Load Miss Rate (%) = (MEM_LOAD_RETIRED.L1_MISS / MEM_INST_RETIRED.ALL_LOADS) * 100%
L1D_MISS_RATE=$(awk -v miss="$MEM_LOAD_RETIRED_L1_MISS" -v loads="$MEM_INST_RETIRED_ALL_LOADS" 'BEGIN { if (loads > 0) printf "%.4f", (miss * 100.0) / loads; else print "0.0000" }')

# Metric 5: L2 Cache Throughput & Bandwidth (64B per line)
L2_READ_TRAFFIC_BYTES=$(awk -v in_l="$L2_LINES_IN_ALL" 'BEGIN { printf "%.0f", in_l * 64 }')
L2_WB_TRAFFIC_BYTES=$(awk -v out_l="$L2_LINES_OUT_NON_SILENT" 'BEGIN { printf "%.0f", out_l * 64 }')
L2_TOTAL_THROUGHPUT_MBS=$(awk -v in_l="$L2_LINES_IN_ALL" -v out_l="$L2_LINES_OUT_NON_SILENT" -v sec="$ELAPSED_SEC" 'BEGIN { if (sec > 0) printf "%.3f", (((in_l + out_l) * 64) / 1000000) / sec; else print "0.000" }')

# --- Step 4: Hyperfine Benchmarking ---
HYPERFINE_MEAN="N/A"
HYPERFINE_RANGE="N/A"
HYPERFINE_MIN="N/A"
HYPERFINE_MAX="N/A"
if [[ "$USE_HYPERFINE" == "true" ]] && command -v hyperfine &>/dev/null; then
  echo -e "${BLUE}[3/3] Running high-precision wall-clock benchmarking via hyperfine...${NC}"
  HF_CMD="$TARGET_CMD"
  [[ "$USE_TASKSET" == "true" ]] && HF_CMD="taskset -c $CPU_CORE $TARGET_CMD"
  HF_OUTPUT=$(hyperfine --warmup "$WARMUP" --runs "$RUNS" --export-json "$REPORT_HF_JSON" "$HF_CMD" 2>&1)
  HF_MEAN_LINE=$(echo "$HF_OUTPUT" | grep "Time (mean ± σ):" | head -n1)
  if [[ -n "$HF_MEAN_LINE" ]]; then
    HYPERFINE_MEAN=$(echo "$HF_MEAN_LINE" | sed -e 's/.*Time (mean ± σ):[ \t]*//' -e 's/\[User:.*//' | sed -e 's/[ \t]*$//')
  fi
  HF_RANGE_LINE=$(echo "$HF_OUTPUT" | grep "Range (min … max):" | head -n1)
  if [[ -n "$HF_RANGE_LINE" ]]; then
    HYPERFINE_RANGE=$(echo "$HF_RANGE_LINE" | sed -e 's/.*Range (min … max):[ \t]*//' -e 's/[0-9][0-9]* runs.*//' | sed -e 's/[ \t]*$//')
    HYPERFINE_MIN=$(echo "$HYPERFINE_RANGE" | awk -F '…' '{print $1}' | sed -e 's/[ \t]*$//')
    HYPERFINE_MAX=$(echo "$HYPERFINE_RANGE" | awk -F '…' '{print $2}' | sed -e 's/^[ \t]*//')
  fi
else
  echo -e "${BLUE}[3/3] Hyperfine skipped (using perf elapsed time: ${ELAPSED_SEC} s).${NC}"
fi

# Format numbers with commas
format_num() {
  local val="$1"
  if [[ "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    printf "%'d" "${val%.*}" 2>/dev/null || echo "$val"
  else
    echo "$val"
  fi
}

# --- Step 5: Terminal Output Dashboard ---
echo -e "\n${CYAN}======================================================================${NC}"
echo -e "${BOLD}             INTEL EMERALD RAPIDS MICROARCHITECTURAL METRICS          ${NC}"
echo -e "${CYAN}======================================================================${NC}"
printf " ${BOLD}%-42s${NC} : ${CYAN}%s MIPS (%s IPS)${NC}\n" "Million Instructions Per Second (MIPS)" "$MIPS" "$IPS"
printf " ${BOLD}%-42s${NC} : ${GREEN}%s${NC}\n" "Instructions Per Cycle (IPC)" "$IPC"
printf " ${BOLD}%-42s${NC} : ${YELLOW}%s %%${NC}\n" "Branch Misprediction Rate" "$BRANCH_MISP_RATE"
printf " ${BOLD}%-42s${NC} : ${YELLOW}%s %%${NC}\n" "L1 D-Cache Demand Load Miss Rate" "$L1D_MISS_RATE"
printf " ${BOLD}%-42s${NC} : ${MAGENTA}%s MB/s${NC}\n" "L2 Total Throughput" "$L2_TOTAL_THROUGHPUT_MBS"
printf " ${BOLD}%-42s${NC} : %s Bytes (Read: %s, WB: %s)\n" "L2 Cache Traffic" "$(format_num "$(awk -v r="$L2_READ_TRAFFIC_BYTES" -v w="$L2_WB_TRAFFIC_BYTES" 'BEGIN { print r + w }')")" "$(format_num "$L2_READ_TRAFFIC_BYTES")" "$(format_num "$L2_WB_TRAFFIC_BYTES")"

if [[ "$HYPERFINE_MEAN" != "N/A" ]]; then
  printf " ${BOLD}%-42s${NC} : ${BLUE}%s${NC}\n" "Wall-Clock Time (hyperfine)" "$HYPERFINE_MEAN"
else
  printf " ${BOLD}%-42s${NC} : ${BLUE}%s s${NC}\n" "Wall-Clock Time (perf stat)" "$ELAPSED_SEC"
fi

echo -e "${CYAN}----------------------------------------------------------------------${NC}"
echo -e "${BOLD}Raw Intel Emerald Rapids PMU Counters (Avg over $RUNS runs):${NC}"
printf "  • 0x3c,0x00  %-30s : %s\n" "CPU_CLK_UNHALTED.THREAD" "$(format_num "$CPU_CLK_UNHALTED_THREAD")"
printf "  • 0xc0,0x00  %-30s : %s\n" "INST_RETIRED.ANY" "$(format_num "$INST_RETIRED_ANY")"
printf "  • 0xc4,0x00  %-30s : %s\n" "BR_INST_RETIRED.ALL_BRANCHES" "$(format_num "$BR_INST_RETIRED_ALL_BRANCHES")"
printf "  • 0xc5,0x00  %-30s : %s\n" "BR_MISP_RETIRED.ALL_BRANCHES" "$(format_num "$BR_MISP_RETIRED_ALL_BRANCHES")"
printf "  • 0xd1,0x08  %-30s : %s\n" "MEM_LOAD_RETIRED.L1_MISS" "$(format_num "$MEM_LOAD_RETIRED_L1_MISS")"
printf "  • 0xd0,0x81  %-30s : %s\n" "MEM_INST_RETIRED.ALL_LOADS" "$(format_num "$MEM_INST_RETIRED_ALL_LOADS")"
printf "  • 0x25,0x1f  %-30s : %s\n" "L2_LINES_IN.ALL" "$(format_num "$L2_LINES_IN_ALL")"
printf "  • 0x26,0x02  %-30s : %s\n" "L2_LINES_OUT.NON_SILENT" "$(format_num "$L2_LINES_OUT_NON_SILENT")"
printf "  • Duration   %-30s : %s s\n" "Execution Time" "$ELAPSED_SEC"
echo -e "${CYAN}======================================================================${NC}"

# --- Step 6: Export Reports ---
cat <<EOF >"$REPORT_MD"
# Intel Emerald Rapids Profile Report: \`$BIN_NAME\`

- **Target Command:** \`$TARGET_CMD\`
- **Date & Time:** $(date "+%Y-%m-%d %H:%M:%S %Z")
- **Architecture:** \`$ARCH\` (Intel Emerald Rapids)
- **CPU Model:** $CPU_MODEL
- **Core Pinning:** $PINNING_MD
- **Cache Line Size:** $CACHE_LINE_SIZE Bytes
- **Runs / Warmup:** $RUNS runs (Warmup: $WARMUP)

---

## 1. Derived Performance Metrics (Derived Metrics Mapping)

| Metric | Value | Formula |
| :--- | :--- | :--- |
| **MIPS & IPS** | **$MIPS MIPS** ($IPS IPS) | \`INST_RETIRED.ANY / (t_elapsed * 10^6)\` |
| **IPC (Instructions Per Cycle)** | **$IPC** | \`INST_RETIRED.ANY / CPU_CLK_UNHALTED.THREAD\` |
| **Branch Misprediction Rate (%)** | **$BRANCH_MISP_RATE %** | \`(BR_MISP_RETIRED.ALL_BRANCHES / BR_INST_RETIRED.ALL_BRANCHES) * 100%\` |
| **L1 D-Cache Demand Load Miss Rate (%)** | **$L1D_MISS_RATE %** | \`(MEM_LOAD_RETIRED.L1_MISS / MEM_INST_RETIRED.ALL_LOADS) * 100%\` |
| **L2 Total Throughput** | **$L2_TOTAL_THROUGHPUT_MBS MB/s** | \`((L2_LINES_IN.ALL + L2_LINES_OUT.NON_SILENT) * 64 / 10^6) / t_elapsed\` |
| **Wall-Clock Time** | **$([ "$HYPERFINE_MEAN" != "N/A" ] && echo "$HYPERFINE_MEAN" || echo "$ELAPSED_SEC s")** | Measured via $([ "$HYPERFINE_MEAN" != "N/A" ] && echo "hyperfine" || echo "perf stat") |

---

## 2. Raw Hardware PMU Counters

| Event Code | Event Name | Event Value (Avg over $RUNS runs) | Description |
| :---: | :--- | :--- | :--- |
| \`0x3c, 0x00\` | \`CPU_CLK_UNHALTED.THREAD\` | $(format_num "$CPU_CLK_UNHALTED_THREAD") | Counts the number of core cycles while the thread is not in a halt state |
| \`0xc0, 0x00\` | \`INST_RETIRED.ANY\` | $(format_num "$INST_RETIRED_ANY") | Counts the number of X86 instructions retired |
| \`0xc4, 0x00\` | \`BR_INST_RETIRED.ALL_BRANCHES\` | $(format_num "$BR_INST_RETIRED_ALL_BRANCHES") | Counts all branch instructions retired |
| \`0xc5, 0x00\` | \`BR_MISP_RETIRED.ALL_BRANCHES\` | $(format_num "$BR_MISP_RETIRED_ALL_BRANCHES") | Counts all the retired branch instructions that were mispredicted |
| \`0xd1, 0x08\` | \`MEM_LOAD_RETIRED.L1_MISS\` | $(format_num "$MEM_LOAD_RETIRED_L1_MISS") | Counts retired load instructions with at least one uop that missed in the L1 cache |
| \`0xd0, 0x81\` | \`MEM_INST_RETIRED.ALL_LOADS\` | $(format_num "$MEM_INST_RETIRED_ALL_LOADS") | Counts all retired load instructions |
| \`0x25, 0x1f\` | \`L2_LINES_IN.ALL\` | $(format_num "$L2_LINES_IN_ALL") | Counts the number of L2 cache lines filling the L2 |
| \`0x26, 0x02\` | \`L2_LINES_OUT.NON_SILENT\` | $(format_num "$L2_LINES_OUT_NON_SILENT") | Counts modified lines evicted by L2 cache written back to L3 |
| - | \`duration_time\` | ${ELAPSED_SEC} s | Total execution duration |
EOF

cat <<EOF >"$REPORT_CSV"
Metric,Value,Unit
Command,"$TARGET_CMD",command
Architecture,"$ARCH",arch
CPU_Model,"$CPU_MODEL",cpu
Core_Pinned,$PINNING_CSV,core
Cache_Line_Size,$CACHE_LINE_SIZE,bytes
Runs,$RUNS,count
Warmup,$WARMUP,count
MIPS,$MIPS,MIPS
IPS,$IPS,IPS
IPC,$IPC,inst_per_cycle
Branch_Misprediction_Rate_pct,$BRANCH_MISP_RATE,percentage
L1D_Miss_Rate_pct,$L1D_MISS_RATE,percentage
L2_Total_Throughput_MBs,$L2_TOTAL_THROUGHPUT_MBS,MB_per_sec
Elapsed_Time_Sec,$ELAPSED_SEC,seconds
CPU_CLK_UNHALTED_THREAD,$CPU_CLK_UNHALTED_THREAD,count
INST_RETIRED_ANY,$INST_RETIRED_ANY,count
BR_INST_RETIRED_ALL_BRANCHES,$BR_INST_RETIRED_ALL_BRANCHES,count
BR_MISP_RETIRED_ALL_BRANCHES,$BR_MISP_RETIRED_ALL_BRANCHES,count
MEM_LOAD_RETIRED_L1_MISS,$MEM_LOAD_RETIRED_L1_MISS,count
MEM_INST_RETIRED_ALL_LOADS,$MEM_INST_RETIRED_ALL_LOADS,count
L2_LINES_IN_ALL,$L2_LINES_IN_ALL,count
L2_LINES_OUT_NON_SILENT,$L2_LINES_OUT_NON_SILENT,count
EOF

if [[ "$VERBOSE" != "true" ]]; then
  rm -f "$PERF_RAW_CSV"
fi

echo -e "${GREEN}✔ Reports successfully generated:${NC}"
echo -e "  • Markdown Report : ${REPORT_MD}"
echo -e "  • CSV Data Report : ${REPORT_CSV}"
if [[ "$USE_HYPERFINE" == "true" && -f "$REPORT_HF_JSON" ]]; then
  echo -e "  • Hyperfine JSON  : ${REPORT_HF_JSON}"
fi
echo ""
