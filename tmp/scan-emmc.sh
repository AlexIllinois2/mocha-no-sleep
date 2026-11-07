#!/system/bin/sh
# eMMC 全片只读扫描：定位读失败的 LBA 区段（只读，不写任何字节）
OUT=/data/local/tmp/crashwatch/emmc-scan.txt
rm -f "$OUT"
SZ=$(cat /sys/block/mmcblk0/size 2>/dev/null)
CHUNK=16384
TOTAL=$((SZ / CHUNK))
echo "== scan start $(date) sectors=$SZ chunks=$TOTAL (每块 8MB) ==" >> "$OUT"
FAIL=0
i=0
while [ $i -lt $TOTAL ]; do
  if ! dd if=/dev/block/mmcblk0 of=/dev/null bs=512 skip=$((i * CHUNK)) count=$CHUNK 2>/dev/null; then
    S0=$((i * CHUNK))
    S1=$((S0 + CHUNK))
    echo "FAIL chunk=$i sector=$S0..$S1 at $(date)" >> "$OUT"
    FAIL=$((FAIL + 1))
  fi
  i=$((i + 1))
done
echo "== scan done $(date) chunks=$TOTAL fail_chunks=$FAIL ==" >> "$OUT"
sync
