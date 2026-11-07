#!/system/bin/sh
# DRAM 保真度判决：把 256MB 随机数据常驻 tmpfs（纯内存），加载下反复校验
# 只要有一次 md5 变了 => 数据在自己没被写过的情况下发生位翻转 => 板级硬件
T=/mnt/dramtest
[ -d "$T" ] || mkdir -p "$T"
RES=/data/local/tmp/crashwatch/dram-result.txt
PAT="$T/pat.bin"
rm -f "$PAT"
echo "== $(date) 生成 256MB 图案 ==" >> "$RES"
dd if=/dev/urandom of="$PAT" bs=1M count=256 2>/dev/null
M0=$(md5sum "$PAT" | cut -d" " -f1)
echo "baseline=$M0" >> "$RES"

# 4 核满载 + 加热，制造最坏电压/温度裕度
i=0
while [ $i -lt 4 ]; do
  ( while :; do :; done ) &
  i=$((i + 1))
done

BAD=0
PASS=0
r=0
while [ $r -lt 25 ]; do
  M=$(md5sum "$PAT" | cut -d" " -f1)
  if [ "$M" != "$M0" ]; then
    BAD=$((BAD + 1))
    echo "MISMATCH round=$r got=$M at $(date)" >> "$RES"
  else
    PASS=$((PASS + 1))
  fi
  echo "round=$r pass=$PASS bad=$BAD cpu=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) memT=$(cat /sys/class/thermal/thermal_zone2/temp)" >> "$RES"
  r=$((r + 1))
  sleep 4
done

kill $(jobs -p) 2>/dev/null
rm -rf "$T"
echo "VERDICT rounds=$r bad=$BAD (bad>0 即 DRAM 原地翻转，硬件级)" >> "$RES"
sync
