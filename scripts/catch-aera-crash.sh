#!/bin/bash
# Ловушка падения UI AERA recovery (cerro).
#
# Крэш UI уносит с собой adbd (телефон остаётся в adb как "offline"), поэтому
# логи нужно стримить ЗАРАНЕЕ, а не собирать после. Этот скрипт:
#   1) забирает tombstone'ы прошлого падения из /data (они persistent),
#   2) снимает текущие /tmp/recovery.log и dmesg,
#   3) включает живой стрим logcat + dmesg в файлы,
#   4) ждёт, пока ты воспроизведёшь падение, и по Ctrl-C всё закрывает.
#
# Запуск:  bash ~/catch-aera-crash.sh

export PATH=/opt/android-sdk/platform-tools:$PATH
OUT="$HOME/aera/logs/crash-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

echo "== Жду телефон в recovery (adb) =="
adb wait-for-recovery 2>/dev/null || adb wait-for-device
adb devices -l | tail -2

echo
echo "== Tombstone'ы предыдущего падения (если /data смонтирован) =="
for d in /data/tombstones /tmp/tombstones /data/anr; do
    n=$(adb shell "ls $d 2>/dev/null | wc -l" | tr -d '\r')
    echo "   $d: ${n:-0} файлов"
    [ "${n:-0}" != "0" ] && adb pull "$d" "$OUT/" >/dev/null 2>&1
done

echo
echo "== Снимок текущего состояния =="
adb shell 'cat /tmp/recovery.log'        > "$OUT/recovery-before.log" 2>&1
adb shell dmesg                          > "$OUT/dmesg-before.log"     2>&1
adb shell 'logcat -d -v threadtime'      > "$OUT/logcat-before.log"   2>&1
adb shell 'ps -A'                        > "$OUT/ps-before.txt"       2>&1
adb shell 'getevent -pl'                 > "$OUT/getevent.txt"        2>&1
adb shell getprop                        > "$OUT/getprop.txt"         2>&1
wc -l "$OUT"/*.log "$OUT"/*.txt 2>/dev/null | tail -7

echo
echo "== Включаю живой стрим (logcat + dmesg) =="
adb logcat -v threadtime            > "$OUT/logcat-live.log" 2>&1 &
LOGCAT_PID=$!
adb shell 'dmesg -w'                > "$OUT/dmesg-live.log"  2>&1 &
DMESG_PID=$!

cleanup() {
    echo
    echo "== Останавливаю стримы =="
    kill $LOGCAT_PID $DMESG_PID 2>/dev/null
    sleep 1
    # Если adbd ещё жив — добираем то, что осталось
    if adb devices | grep -q "recovery"; then
        adb shell 'cat /tmp/recovery.log' > "$OUT/recovery-after.log" 2>&1
        for d in /data/tombstones /tmp/tombstones; do
            adb pull "$d" "$OUT/after-$(basename $d)" >/dev/null 2>&1
        done
    else
        echo "   (adbd не отвечает — ожидаемо после падения UI)"
    fi
    echo
    echo "== Собрано в: $OUT =="
    ls -la "$OUT"
    echo
    echo "Интересное из стрима:"
    grep -nE 'FATAL|signal |SIGSEGV|SIGABRT|backtrace|aeraui|lv_|Fatal signal|DEBUG   ' \
        "$OUT/logcat-live.log" 2>/dev/null | head -25
}
trap cleanup EXIT INT TERM

cat <<'MSG'

   ТЕПЕРЬ ВОСПРОИЗВОДИ ПАДЕНИЕ НА ТЕЛЕФОНЕ:
   зайди в Backups и проведи влево — так же, как в прошлый раз.

   Когда UI упадёт (или тач умрёт) — нажми здесь Ctrl-C.

MSG

# Ждём, пока пользователь не остановит
while true; do sleep 5; done
