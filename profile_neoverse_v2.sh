#!/usr/bin/env bash
# ==============================================================================
# profile_neoverse_v2.sh - Profiler for ARM Neoverse-V2
# Based on: Notes/ARM Neoverse V2's Note.md
#
# PMU Events Tracked:
#   - 0x08 (r8)  : INST_RETIRED          (Architecturally executed instructions)
#   - 0x11 (r11) : CPU_CYCLES            (CPU clock cycles)
#   - 0x21 (r21) : BR_RETIRED            (Architecturally executed branches)
#   - 0x22 (r22) : BR_MIS_PRED_RETIRED   (Mispredicted branches)
#   - 0x04 (r4)  : L1D_CACHE             (L1 data cache accesses)
#   - 0x03 (r3)  : L1D_CACHE_REFILL      (L1 data cache refills / misses)
#   - 0x17 (r17) : L2D_CACHE_REFILL      (L2 cache refills)
#   - 0x18 (r18) : L2D_CACHE_WB          (L2 cache write-backs)
#   - duration_time                      (Execution duration)
#
# Metrics Computed (from Notes/ARM Neoverse V2's Note.md - Section IV):
#   1. Architecturally executed Instructions Per Cycle (IPC):
#        IPC = INST_RETIRED / CPU_CYCLES
#   2. L1 D-cache miss rate (%):
#        L1D Miss Rate (%) = (L1D_CACHE_REFILL / L1D_CACHE) * 100%
#   3. L2 throughput (MB/s):
#        L2 Throughput = ((L2D_CACHE_WB + L2D_CACHE_REFILL) * CACHE_LINE_SIZE) / t_elapsed
#   4. Branch misprediction rate (%):
#        Branch Misprediction Rate (%) = (BR_MIS_PRED_RETIRED / BR_RETIRED) * 100%
#   5. MIPS:
#        MIPS = INST_RETIRED / (t_elapsed * 10^6)
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
CPU_MODEL=$(lscpu 2>/dev/null | grep -E "Model name|CPU part" | head -n1 | sed -e 's/^[^:]*:[ \t]*//')
[[ -z "$CPU_MODEL" ]] && CPU_MODEL="ARM Neoverse-V2 ($ARCH)"

# Cache line size (64 Bytes on Neoverse-V2)
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
REPORT_MD="${OUT_DIR}/profile_neoverse_v2_${BIN_NAME}_${TIMESTAMP}.md"
REPORT_CSV="${OUT_DIR}/profile_neoverse_v2_${BIN_NAME}_${TIMESTAMP}.csv"
REPORT_HF_JSON="${OUT_DIR}/profile_neoverse_v2_${BIN_NAME}_${TIMESTAMP}_hyperfine.json"
PERF_RAW_CSV="${OUT_DIR}/.perf_raw_${BIN_NAME}_${TIMESTAMP}.csv"

# --- Explicitly Specify All ARM Neoverse-V2 PMU Events for perf stat ---
NEOVERSE_V2_EVENTS="\
r8/name=INST_RETIRED/,\
r11/name=CPU_CYCLES/,\
r21/name=BR_RETIRED/,\
r22/name=BR_MIS_PRED_RETIRED/,\
r4/name=L1D_CACHE/,\
r3/name=L1D_CACHE_REFILL/,\
r17/name=L2D_CACHE_REFILL/,\
r18/name=L2D_CACHE_WB/,\
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
  echo -e "${BOLD}         ARM NEOVERSE-V2 BENCHMARK (HYPERFINE ONLY)                   ${NC}"
else
  echo -e "${BOLD}         ARM NEOVERSE-V2 HARDWARE PROFILER                            ${NC}"
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
  echo -e " ${BOLD}PMU Events:${NC}       INST_RETIRED (0x08), CPU_CYCLES (0x11), BR_RETIRED (0x21),"
  echo -e "                     BR_MIS_PRED_RETIRED (0x22), L1D_CACHE (0x04),"
  echo -e "                     L1D_CACHE_REFILL (0x03), L2D_CACHE_REFILL (0x17),"
  echo -e "                     L2D_CACHE_WB (0x18)"
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
# ARM Neoverse-V2 Benchmark Report: \`$BIN_NAME\` (Hyperfine)

- **Target Command:** \`$TARGET_CMD\`
- **Date & Time:** $(date "+%Y-%m-%d %H:%M:%S %Z")
- **Architecture:** \`$ARCH\` (ARM Neoverse-V2)
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
echo -e "${GREEN}[2/3] Collecting ARM Neoverse-V2 PMU counters over $RUNS run(s)...${NC}"
$PERF_PREFIX perf stat -x, -r "$RUNS" -e "$NEOVERSE_V2_EVENTS" $TASKSET_PREFIX $TARGET_CMD >/dev/null 2>"$PERF_RAW_CSV" || {
  echo -e "${YELLOW}Notice: Retrying with raw hex event codes...${NC}"
  $PERF_PREFIX perf stat -x, -r "$RUNS" -e "r8,r11,r21,r22,r4,r3,r17,r18,duration_time" $TASKSET_PREFIX $TARGET_CMD >/dev/null 2>"$PERF_RAW_CSV" || true
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

INST_RETIRED=$(parse_pmu_val "INST_RETIRED|r8")
CPU_CYCLES=$(parse_pmu_val "CPU_CYCLES|r11")
BR_RETIRED=$(parse_pmu_val "BR_RETIRED|r21")
BR_MIS_PRED_RETIRED=$(parse_pmu_val "BR_MIS_PRED_RETIRED|r22")
L1D_CACHE=$(parse_pmu_val "L1D_CACHE|r4")
L1D_CACHE_REFILL=$(parse_pmu_val "L1D_CACHE_REFILL|r3")
L2D_CACHE_REFILL=$(parse_pmu_val "L2D_CACHE_REFILL|r17")
L2D_CACHE_WB=$(parse_pmu_val "L2D_CACHE_WB|r18")

# --- Step 3: Compute Derived Metrics (from Notes/ARM Neoverse V2's Note.md) ---
# Metric 1: Architecturally executed Instructions Per Cycle (IPC) = INST_RETIRED / CPU_CYCLES
IPC=$(awk -v inst="$INST_RETIRED" -v cyc="$CPU_CYCLES" 'BEGIN { if (cyc > 0) printf "%.4f", inst / cyc; else print "0.0000" }')

# Metric 2: L1 D-cache miss rate = (L1D_CACHE_REFILL / L1D_CACHE) * 100%
L1D_MISS_RATE=$(awk -v refill="$L1D_CACHE_REFILL" -v access="$L1D_CACHE" 'BEGIN { if (access > 0) printf "%.4f", (refill * 100.0) / access; else print "0.0000" }')

# Metric 3: L2 throughput = ((L2D_CACHE_WB + L2D_CACHE_REFILL) * CACHE_LINE_SIZE) / t_elapsed
L2_THROUGHPUT_BS=$(awk -v wb="$L2D_CACHE_WB" -v refill="$L2D_CACHE_REFILL" -v cls="$CACHE_LINE_SIZE" -v sec="$ELAPSED_SEC" 'BEGIN { if (sec > 0) printf "%.2f", ((wb + refill) * cls) / sec; else print "0.00" }')
L2_THROUGHPUT_MBS=$(awk -v bs="$L2_THROUGHPUT_BS" 'BEGIN { printf "%.3f", bs / 1000000 }')

# Metric 4: Branch misprediction rate = (BR_MIS_PRED_RETIRED / BR_RETIRED) * 100%
BRANCH_MIS_PRED_RATE=$(awk -v misp="$BR_MIS_PRED_RETIRED" -v br="$BR_RETIRED" 'BEGIN { if (br > 0) printf "%.4f", (misp * 100.0) / br; else print "0.0000" }')

# Metric 5: MIPS = INST_RETIRED / (t_elapsed * 10^6)
MIPS=$(awk -v inst="$INST_RETIRED" -v sec="$ELAPSED_SEC" 'BEGIN { if (sec > 0) printf "%.2f", inst / (sec * 1000000); else print "0.00" }')

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
echo -e "${BOLD}              ARM NEOVERSE-V2 MICROARCHITECTURAL METRICS              ${NC}"
echo -e "${CYAN}======================================================================${NC}"
printf " ${BOLD}%-42s${NC} : ${GREEN}%s${NC}\n" "Instructions Per Cycle (IPC)" "$IPC"
printf " ${BOLD}%-42s${NC} : ${CYAN}%s MIPS${NC}\n" "Million Instructions Per Second (MIPS)" "$MIPS"
printf " ${BOLD}%-42s${NC} : ${YELLOW}%s %%${NC}\n" "Branch Misprediction Rate" "$BRANCH_MIS_PRED_RATE"
printf " ${BOLD}%-42s${NC} : ${YELLOW}%s %%${NC}\n" "L1 D-Cache Miss Rate" "$L1D_MISS_RATE"
printf " ${BOLD}%-42s${NC} : ${MAGENTA}%s MB/s${NC}\n" "L2 Throughput" "$L2_THROUGHPUT_MBS"

if [[ "$HYPERFINE_MEAN" != "N/A" ]]; then
  printf " ${BOLD}%-42s${NC} : ${BLUE}%s${NC}\n" "Wall-Clock Time (hyperfine)" "$HYPERFINE_MEAN"
else
  printf " ${BOLD}%-42s${NC} : ${BLUE}%s s${NC}\n" "Wall-Clock Time (perf stat)" "$ELAPSED_SEC"
fi

echo -e "${CYAN}----------------------------------------------------------------------${NC}"
echo -e "${BOLD}Raw ARM Neoverse-V2 PMU Counters (Avg over $RUNS runs):${NC}"
printf "  • 0x08 (r8)  %-26s : %s\n" "INST_RETIRED" "$(format_num "$INST_RETIRED")"
printf "  • 0x11 (r11) %-26s : %s\n" "CPU_CYCLES" "$(format_num "$CPU_CYCLES")"
printf "  • 0x21 (r21) %-26s : %s\n" "BR_RETIRED" "$(format_num "$BR_RETIRED")"
printf "  • 0x22 (r22) %-26s : %s\n" "BR_MIS_PRED_RETIRED" "$(format_num "$BR_MIS_PRED_RETIRED")"
printf "  • 0x04 (r4)  %-26s : %s\n" "L1D_CACHE" "$(format_num "$L1D_CACHE")"
printf "  • 0x03 (r3)  %-26s : %s\n" "L1D_CACHE_REFILL" "$(format_num "$L1D_CACHE_REFILL")"
printf "  • 0x17 (r17) %-26s : %s\n" "L2D_CACHE_REFILL" "$(format_num "$L2D_CACHE_REFILL")"
printf "  • 0x18 (r18) %-26s : %s\n" "L2D_CACHE_WB" "$(format_num "$L2D_CACHE_WB")"
printf "  • Duration   %-26s : %s s\n" "Execution Time" "$ELAPSED_SEC"
echo -e "${CYAN}======================================================================${NC}"

# --- Step 6: Export Reports ---
cat <<EOF >"$REPORT_MD"
# ARM Neoverse-V2 Profile Report: \`$BIN_NAME\`

- **Target Command:** \`$TARGET_CMD\`
- **Date & Time:** $(date "+%Y-%m-%d %H:%M:%S %Z")
- **Architecture:** \`$ARCH\` (ARM Neoverse-V2)
- **CPU Model:** $CPU_MODEL
- **Core Pinning:** $PINNING_MD
- **Cache Line Size:** $CACHE_LINE_SIZE Bytes
- **Runs / Warmup:** $RUNS runs (Warmup: $WARMUP)

---

## 1. Derived Performance Metrics (Section IV. Metrics)

| Metric | Value | Formula |
| :--- | :--- | :--- |
| **Architecturally executed Instructions Per Cycle (IPC)** | **$IPC** | \`INST_RETIRED / CPU_CYCLES\` |
| **L1 D-cache miss rate** | **$L1D_MISS_RATE %** | \`(L1D_CACHE_REFILL / L1D_CACHE) * 100%\` |
| **L2 throughput** | **$L2_THROUGHPUT_MBS MB/s** | \`((L2D_CACHE_WB + L2D_CACHE_REFILL) * CACHE_LINE_SIZE) / t_elapsed\` |
| **Branch misprediction rate** | **$BRANCH_MIS_PRED_RATE %** | \`(BR_MIS_PRED_RETIRED / BR_RETIRED) * 100%\` |
| **MIPS** | **$MIPS MIPS** | \`INST_RETIRED / (t_elapsed * 10^6)\` |
| **Wall-Clock Time** | **$([ "$HYPERFINE_MEAN" != "N/A" ] && echo "$HYPERFINE_MEAN" || echo "$ELAPSED_SEC s")** | Measured via $([ "$HYPERFINE_MEAN" != "N/A" ] && echo "hyperfine" || echo "perf stat") |

---

## 2. Raw Hardware PMU Counters

| Event Code | Event Name | Event Value (Avg over $RUNS runs) | Description |
| :---: | :--- | :--- | :--- |
| \`0x08\` (\`r8\`) | \`INST_RETIRED\` | $(format_num "$INST_RETIRED") | Instruction architecturally executed |
| \`0x11\` (\`r11\`) | \`CPU_CYCLES\` | $(format_num "$CPU_CYCLES") | CPU clock cycles |
| \`0x21\` (\`r21\`) | \`BR_RETIRED\` | $(format_num "$BR_RETIRED") | Branch instruction architecturally executed |
| \`0x22\` (\`r22\`) | \`BR_MIS_PRED_RETIRED\` | $(format_num "$BR_MIS_PRED_RETIRED") | Mispredicted branch instruction architecturally executed |
| \`0x04\` (\`r4\`) | \`L1D_CACHE\` | $(format_num "$L1D_CACHE") | L1 data cache access |
| \`0x03\` (\`r3\`) | \`L1D_CACHE_REFILL\` | $(format_num "$L1D_CACHE_REFILL") | L1 data cache refill |
| \`0x17\` (\`r17\`) | \`L2D_CACHE_REFILL\` | $(format_num "$L2D_CACHE_REFILL") | L2 cache refill |
| \`0x18\` (\`r18\`) | \`L2D_CACHE_WB\` | $(format_num "$L2D_CACHE_WB") | L2 cache write-back |
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
IPC,$IPC,inst_per_cycle
L1D_Miss_Rate_pct,$L1D_MISS_RATE,percentage
L2_Throughput_MBs,$L2_THROUGHPUT_MBS,MB_per_sec
Branch_Misprediction_Rate_pct,$BRANCH_MIS_PRED_RATE,percentage
MIPS,$MIPS,MIPS
Elapsed_Time_Sec,$ELAPSED_SEC,seconds
INST_RETIRED,$INST_RETIRED,count
CPU_CYCLES,$CPU_CYCLES,count
BR_RETIRED,$BR_RETIRED,count
BR_MIS_PRED_RETIRED,$BR_MIS_PRED_RETIRED,count
L1D_CACHE,$L1D_CACHE,count
L1D_CACHE_REFILL,$L1D_CACHE_REFILL,count
L2D_CACHE_REFILL,$L2D_CACHE_REFILL,count
L2D_CACHE_WB,$L2D_CACHE_WB,count
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
