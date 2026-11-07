#!/system/bin/sh
# 崩溃取证 + 档位自动轮转守护
# 每次开机：轮转一档（单因子 A/B，跨重启交替），现读回生效值，归档上一世 last_kmsg
D=/data/local/tmp/crashwatch
mkdir -p "$D"
chmod 700 "$D"
BOOT="$D/boot.csv"
HB="$D/heartbeat.csv"
[ -f "$BOOT" ] || echo "epoch,uptime_s,arm,cpu_max_khz,emc_floor_hz,gov,kernel,bootreason,arm_index" > "$BOOT"
[ -f "$HB" ] || echo "epoch,uptime_s,arm,cpu0_khz,cpu_therm_mC,mem_therm_mC,batt_uV,batt_uA,free_kb,mmc_io_err_total" > "$HB"

# 档位表：标签:CPU顶频kHz:EMC地板Hz  （每档只动一个因子；A3 动两个）
ARMS="A0-asis:2218500:924000000 A1-emc408:2218500:408000000 A2-cpu1836:1836000:924000000 A3-both:1836000:408000000"

IDX=0
[ -f "$D/armidx" ] && IDX=$(cat "$D/armidx" 2>/dev/null)
[ -n "$IDX" ] || IDX=0
NARM=4
SLOT=$((IDX % NARM))

i=0
for spec in $ARMS; do
  if [ "$i" -eq "$SLOT" ]; then
    LABEL=$(echo "$spec" | cut -d: -f1)
    CPU_MAX=$(echo "$spec" | cut -d: -f2)
    EMC_FLOOR=$(echo "$spec" | cut -d: -f3)
  fi
  i=$((i + 1))
done
[ -n "$LABEL" ] || { LABEL="A0-asis"; CPU_MAX=2218500; EMC_FLOOR=924000000; }

echo $((IDX + 1)) > "$D/armidx"

# --- 施加档位 ---
for c in 0 1 2 3; do
  echo "$CPU_MAX" > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_max_freq 2>/dev/null
done
echo "$EMC_FLOOR" > /sys/kernel/tegra_emc/emc_floor_rate 2>/dev/null

# --- 归档上一世内核日志（/proc/last_kmsg 属上一次启动）---
if [ -s /proc/last_kmsg ]; then
  cp /proc/last_kmsg "$D/prev_kmsg-$(date +%s).log" 2>/dev/null
fi

# 现读回真正生效的值：档位没落地必须被账面发现
CUR_MAX=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null)
CUR_EMC=$(cat /sys/kernel/tegra_emc/emc_floor_rate 2>/dev/null)
CUR_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
echo "$(date +%s),$(cut -d. -f1 /proc/uptime),$LABEL,$CUR_MAX,$CUR_EMC,$CUR_GOV,$(uname -r),$(getprop ro.boot.bootreason),$IDX" >> "$BOOT"
sync

# --- 心跳循环 ---
PREV_ERR=0
N=0
while true; do
  UP=$(cut -d. -f1 /proc/uptime 2>/dev/null)
  F0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
  CT=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
  MT=$(cat /sys/class/thermal/thermal_zone2/temp 2>/dev/null)
  BV=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null)
  BI=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)
  FR=$(awk "/MemFree/ {print \$2}" /proc/meminfo 2>/dev/null)
  ERR=$(dmesg 2>/dev/null | grep -c "I/O error")
  echo "$(date +%s),$UP,$LABEL,$F0,$CT,$MT,$BV,$BI,$FR,$ERR" >> "$HB"
  if [ "$ERR" -gt "$PREV_ERR" ] 2>/dev/null; then
    dmesg > "$D/dmesg-err-$(date +%s).log" 2>/dev/null
    PREV_ERR=$ERR
  fi
  N=$((N + 1))
  if [ $((N % 5)) -eq 0 ]; then
    sync
  fi
  if [ "$(wc -c < "$HB" 2>/dev/null)" -gt 2000000 ] 2>/dev/null; then
    tail -4000 "$HB" > "$HB.rot" 2>/dev/null
    mv "$HB.rot" "$HB" 2>/dev/null
  fi
  sleep 20
done
