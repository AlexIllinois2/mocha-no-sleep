#!/system/bin/sh
# 由 Magisk App 安装本包时执行；TWRP 路径走同目录下的 update-binary，两路互不干扰。
ui_print "- Mi Pad 1 崩溃修复 (mocha_no_sleep v4.0)"
ui_print "  闸门 1：不再有深睡；闸门 2：CPU/EMC 稳定档位。待机耗电会上升。"
ui_print "  在 Magisk 里关闭本模块即可恢复。"

# v4.0：稳定档位已并入本模块，移除上一版的独立 freq_cap 模块，避免两处写同一批 sysfs
if [ -d /data/adb/modules/freq_cap ]; then
  rm -rf /data/adb/modules/freq_cap
  ui_print "  已移除旧模块 freq_cap（设置已并入本包）"
fi

set_perm "$MODPATH/post-fs-data.sh" 0 0 0750
set_perm "$MODPATH/service.sh" 0 0 0750
set_perm "$MODPATH/crashwatch.sh" 0 0 0750
set_perm "$MODPATH/report.sh" 0 0 0750
set_perm "$MODPATH/module.prop" 0 0 0644
set_perm "$MODPATH/README.md" 0 0 0644
