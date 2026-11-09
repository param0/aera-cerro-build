#!/bin/bash
# Диагностика Wi-Fi в AERA recovery (cerro).
# Запуск: bash ~/aera-wifi-diag.sh      (телефон должен быть в recovery с живым adb)

export PATH=/opt/android-sdk/platform-tools:$PATH
D="$HOME/aera/logs/wifi-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$D"

adb devices -l | tail -2
adb devices | grep -q 'recovery$' || { echo "!! телефон не в recovery или adb offline — переткни кабель"; exit 1; }

echo
echo "########## 1. Загрузка модулей (что сделал KernelModuleLoader)"
adb shell 'cat /tmp/recovery.log' > "$D/recovery.log" 2>&1
grep -iE 'module|insmod|vendor_dlkm|system_dlkm|wlan|cnss' "$D/recovery.log" | tail -40

echo
echo "########## 2. Что реально загружено в ядро"
adb shell 'cat /proc/modules 2>/dev/null | cut -d" " -f1 | sort' > "$D/modules.txt" 2>&1
echo "   всего модулей: $(wc -l < "$D/modules.txt")"
grep -iE 'cnss|wlan|qca|cfg80211|mac80211|rfkill' "$D/modules.txt" || echo "   !! ни одного wifi-модуля не загружено"

echo
echo "########## 3. Смонтированы ли разделы с модулями"
adb shell 'cat /proc/mounts' > "$D/mounts.txt" 2>&1
grep -E 'vendor_dlkm|system_dlkm|/vendor |/vendor$' "$D/mounts.txt" || echo "   !! vendor_dlkm/system_dlkm не смонтированы"
echo "   модули на разделах:"
adb shell 'ls /vendor_dlkm/lib/modules/ 2>/dev/null | head -5; ls /system_dlkm/lib/modules/ 2>/dev/null | head -5'

echo
echo "########## 4. Узел cnss2 и сетевой интерфейс"
adb shell 'ls -d /sys/bus/platform/drivers/cnss2/*/ 2>/dev/null; echo "--- fs_ready:"; ls /sys/bus/platform/drivers/cnss2/*/fs_ready 2>/dev/null; echo "--- net:"; ls /sys/class/net/ 2>/dev/null'

echo
echo "########## 5. Ядро про cnss/wlan"
adb shell dmesg > "$D/dmesg.log" 2>&1
grep -iE 'cnss|wlan|qca|cfg80211|icnss|firmware' "$D/dmesg.log" | tail -40

echo
echo "########## 6. wpa_supplicant и свойства"
adb shell 'ps -A | grep -iE "wpa|dhcp"' || echo "   wpa_supplicant не запущен"
adb shell 'getprop | grep -iE "wifi|wlan"'
echo "   конфиг:"
adb shell 'ls -l /vendor/etc/wifi/wpa_supplicant.conf 2>&1'

echo
echo "########## 7. Логи AERA про wlan"
adb shell 'logcat -d -v brief' > "$D/logcat.log" 2>&1
grep -iE 'wlan|wifi|wpa|cnss' "$D/logcat.log" | tail -25

echo
echo "== всё сохранено в $D =="
