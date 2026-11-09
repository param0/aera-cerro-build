#!/bin/bash
# AERA Recovery (манифест aera-16.0, база AOSP android-16.0.0_r1)
# для Nubia Z60 Ultra (NX721J / cerro)
#
# Запуск с хоста:  bash ~/build-aera-cerro.sh
# Скрипт сам зайдёт в distrobox-контейнер "rom" и продолжит уже внутри него.
#
#   Синк   -> 3 потока  (медленно, но переживает обрывы; есть авто-ретраи)
#   Сборка -> 16 потоков
#
# Что собирается и из чего:
#   * манифест AERA берётся ЦЕЛИКОМ, как в его README. Урезание проектов уже
#     сделано самим проектом в remove-minimal.xml (601 remove-project), поэтому
#     никаких своих local_manifests/slim.xml и вырезания build/make/core/tasks
#     здесь НЕТ: именно это в прошлый раз давало битую сборку.
#   * дерево устройства — recovery-tree от delvoryx (ветка fox_14.1):
#     prebuilt-кернел, init.recovery.usb.rc (отсюда рабочий ADB), vendor-блобы
#     keymint/gatekeeper/qseecomd/boot-HAL, vintf-манифесты, recovery.fstab и
#     twrp.flags. У AERA/OrangeFox общий набор переменных: aera_config.mk
#     транслирует публичные AERA_* в внутренние OF_*/TW_*, а OF_*/TW_*,
#     выставленные деревом напрямую, читаются как есть. Под A16 дереву нужны
#     две правки — имя релиза ap2a -> bp2a и кавычки в
#     TARGET_RECOVERY_PIXEL_FORMAT (см. блок правок ниже).
#
# Полезные переопределения:
#   NO_SYNC=1    bash ~/build-aera-cerro.sh   # пропустить repo sync, сразу собирать
#   SYNC_ONLY=1  bash ~/build-aera-cerro.sh   # только синк, без сборки
#   UPDATE_DT=1  bash ~/build-aera-cerro.sh   # обновить дерево устройства (git reset --hard)
#   WIPE_OUT=1   bash ~/build-aera-cerro.sh   # принудительно снести out/
#   WIPE_OUT=0   ...                          # запретить снос out/
#   SYNC_THREADS=1 ...                        # если совсем плохой канал
#   SYNC_DEPTH=0 ...                          # полная история git вместо --depth=1
#   KEEP_AWAKE=0 ...                          # разрешить машине уснуть во время сборки

if [ -z "$CONTAINER_ID" ]; then
    # Мы на хосте. hypridle усыпляет машину через 20 мин простоя (systemctl suspend),
    # а сборка для idle-таймера "активностью" не считается. Держим блокировку logind
    # на всё время работы — hypridle её уважает (ignore_systemd_inhibit не выставлен).
    SELF="$(readlink -f "$0")"
    if [ "${KEEP_AWAKE:-1}" = "1" ] && command -v systemd-inhibit >/dev/null; then
        echo "== Сон и автоблокировка отключены на время сборки (systemd-inhibit) =="
        exec systemd-inhibit \
            --what=idle:sleep:handle-lid-switch \
            --who="AERA recovery build" \
            --why="Идёт сборка AERA recovery для cerro" \
            --mode=block \
            distrobox enter rom -- bash "$SELF" "$@"
    fi
    exec distrobox enter rom -- bash "$SELF" "$@"
fi

set -e

# ==========================================
WORK_DIR="${WORK_DIR:-$HOME/aera}"

MANIFEST_URL="https://github.com/AERA-Recovery/android_manifest"
MANIFEST_BRANCH="aera-16.0"        # AERA 16.0 (AOSP android-16.0.0_r1)

DEVICE="cerro"                     # Nubia Z60 Ultra, NX721J
PRODUCT="twrp_$DEVICE"             # имя продукта в дереве (так же и у AERA: twrp_dodge)
RELEASE="bp2a"                     # релиз-конфиг Android 16 (у A14-дерева было ap2a)
VARIANT="eng"                      # AERA собирает recovery как eng

# Дерево устройства. В манифест AERA device trees не входят — клонируем отдельно.
DT_URL="https://github.com/delvoryx/android_device_nubia_cerro-recovery"
DT_BRANCH="fox_14.1"
DT_PATH="device/nubia/$DEVICE"

# Пусто = оставить мейнтейнера дерева (delvoryx). Поставь своё имя, если нужно
# видеть его в UI recovery; авторство дерева при этом не трогаем.
MAINTAINER="${MAINTAINER:-}"

SYNC_THREADS="${SYNC_THREADS:-3}"      # потоки для repo sync
BUILD_THREADS="${BUILD_THREADS:-16}"   # потоки для сборки
SYNC_RETRIES="${SYNC_RETRIES:-8}"      # сколько раз пробовать досинкать при обрывах
SYNC_DEPTH="${SYNC_DEPTH:-1}"          # глубина истории git. На состав дерева не влияет:
                                       # проекты все, просто без старых коммитов.
                                       # SYNC_DEPTH=0 -> полная история (+~100 ГБ).

NO_SYNC="${NO_SYNC:-0}"
SYNC_ONLY="${SYNC_ONLY:-0}"
UPDATE_DT="${UPDATE_DT:-0}"
WIPE_OUT="${WIPE_OUT:-auto}"       # auto = снести out/, если он от другой ветки/манифеста
USE_CCACHE_BUILD="true"
CCACHE_SIZE="30G"

# Ограничение параллельных «тяжёлых по памяти» задач (линковка, R8/d8).
HIGHMEM_JOBS="${HIGHMEM_JOBS:-4}"

NEED_FREE_GB="${NEED_FREE_GB:-140}"   # сколько места хотим видеть перед синком
# ==========================================

export PATH="$HOME/.local/bin:$PATH"
LOG_DIR="$WORK_DIR/logs"

echo "=============================================="
echo " AERA recovery $MANIFEST_BRANCH -> $DEVICE ($PRODUCT-$RELEASE-$VARIANT)"
echo " sync: -j$SYNC_THREADS   build: -j$BUILD_THREADS"
echo "=============================================="

command -v repo >/dev/null || { echo "!! repo не найден в PATH ($PATH)"; exit 1; }

mkdir -p "$WORK_DIR" "$LOG_DIR" && cd "$WORK_DIR"

free_gb=$(df -BG --output=avail . | tail -1 | tr -dc '0-9')
echo "== Свободно на разделе с $WORK_DIR: ${free_gb} ГБ (хотим >= ${NEED_FREE_GB}) =="
if [ "$free_gb" -lt "$NEED_FREE_GB" ]; then
    echo "!! Места мало. Синк (~90 ГБ) + out/ (~40 ГБ) могут не влезть."
    echo "   Если уверен — запусти с NEED_FREE_GB=$free_gb"
    if [ "$NEED_FREE_GB" != "$free_gb" ]; then
        exit 1
    fi
fi

if [ "$NO_SYNC" != "1" ]; then

# ------------------------------------------------------------------
# Никаких своих local_manifests: манифест AERA самодостаточен, а любые
# свои remove-project здесь — прямой путь к битой сборке.
# ------------------------------------------------------------------
if [ -d .repo/local_manifests ] && [ -n "$(ls -A .repo/local_manifests 2>/dev/null)" ]; then
    echo "== В .repo/local_manifests что-то есть — отношу в сторону =="
    mv .repo/local_manifests "$WORK_DIR/local_manifests.disabled.$(date +%s)"
fi

echo "== repo init -b $MANIFEST_BRANCH =="
repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" --no-clone-bundle \
    $([ "$SYNC_DEPTH" != "0" ] && echo "--depth=$SYNC_DEPTH")

# ------------------------------------------------------------------
# Синк с автоматическими повторами при обрывах. repo sync возвращает
# ненулевой код, если хоть один проект не докачался, поэтому просто крутим
# цикл — уже скачанное не перекачивается.
#
# Гоним через script(1): repo печатает прогресс только когда видит tty, а в
# обычном пайпе на tee замолкает на часы. script даёт ему pty, и прогресс
# виден в терминале, и лог пишется.
# ------------------------------------------------------------------
echo "== repo sync -j$SYNC_THREADS (до $SYNC_RETRIES попыток) =="
SYNC_CMD="repo sync -c -j$SYNC_THREADS --force-sync --no-clone-bundle --no-tags --retry-fetches=3 --optimized-fetch"
sync_ok=0
for attempt in $(seq 1 "$SYNC_RETRIES"); do
    echo "---- sync: попытка $attempt/$SYNC_RETRIES ----"
    if command -v script >/dev/null; then
        script -q -e -a "$LOG_DIR/sync.log" -c "$SYNC_CMD"
    else
        $SYNC_CMD 2>&1 | tee -a "$LOG_DIR/sync.log"
    fi
    if [ $? -eq 0 ]; then
        sync_ok=1
        break
    fi
    echo "---- обрыв, пауза 20с перед повтором ----"
    sleep 20
done

if [ "$sync_ok" != "1" ]; then
    cat <<EOF

!! repo sync не завершился за $SYNC_RETRIES попыток (лог: $LOG_DIR/sync.log).
   Включи VPN и перезапусти этот же скрипт — докачает только недостающее.
EOF
    exit 1
fi

echo "== repo sync завершён =="

fi # NO_SYNC

# ------------------------------------------------------------------
# Закрепление версий AERA.
#
# AERA разрабатывается очень бурно: только в bootable/recovery с 17.10 по
# 07.11.2026 легло больше 100 коммитов, в том числе прямо в путь раннего
# старта (runtime: stage opted-in device dependencies in RAM; startup: avoid
# covering RAM runtime while reading ROM metadata; build: add opt-in extreme
# recovery runtime compression). Сборка на HEAD поэтому невоспроизводима:
# образ от 07.11 роняет ядро на cerro (ZTE memory dump mode), а сборка на
# f2ce8f7 от 13.10 как минимум доходит до анимации.
#
# Пины ниже = ровно та кодовая база, на которой собран рабочий сторонний
# образ (его ro.build.aera_codebase = 2026-10-13 (f2ce8f7)).
# AERA_PIN=0 -> собирать на HEAD манифеста.
# ------------------------------------------------------------------
AERA_PIN="${AERA_PIN:-1}"
AERA_PINS=(
    "bootable/recovery=42ed6b66808200ce0d388bb0b4f05e4c2af4d207"
    "vendor/recovery=1f4b6e19882c83f95d1420872d0c31be0b97a7a6"
)

if [ "$AERA_PIN" = "1" ]; then
    echo "== Закрепляю версии AERA (AERA_PIN=0 чтобы собирать на HEAD) =="
    for pin in "${AERA_PINS[@]}"; do
        path="${pin%%=*}"; sha="${pin#*=}"
        [ -d "$path/.git" ] || { echo "   !! нет $path — пропускаю"; continue; }
        cur="$(git -C "$path" rev-parse HEAD 2>/dev/null)"
        if [ "$cur" = "$sha" ]; then
            echo "   $path уже на ${sha:0:12}"
            continue
        fi
        echo "   $path -> ${sha:0:12}"
        # у проектов под repo remote называется по манифесту (AERA), не origin
        rem="$(git -C "$path" remote | head -1)"
        [ -n "$rem" ] || { echo "   !! у $path нет remote"; exit 1; }
        # дерево синкается с --depth=1, поэтому нужного коммита локально нет;
        # GitHub отдаёт произвольный SHA по запросу
        git -C "$path" fetch --depth=1 "$rem" "$sha" || {
            echo "   !! не удалось получить $sha для $path"; exit 1; }
        git -C "$path" checkout -q --detach FETCH_HEAD
    done
fi

# ------------------------------------------------------------------
# Дерево устройства. Его нет в манифесте, repo sync его не трогает —
# поэтому клонируем/обновляем сами.
# ------------------------------------------------------------------
if [ ! -d "$DT_PATH/.git" ]; then
    echo "== Клонирую дерево устройства: $DT_URL ($DT_BRANCH) =="
    rm -rf "$DT_PATH"
    mkdir -p "$(dirname "$DT_PATH")"
    git clone --depth 1 -b "$DT_BRANCH" "$DT_URL" "$DT_PATH"
elif [ "$UPDATE_DT" = "1" ]; then
    echo "== Обновляю дерево устройства (reset --hard) =="
    git -C "$DT_PATH" fetch --depth 1 origin "$DT_BRANCH"
    git -C "$DT_PATH" reset --hard FETCH_HEAD
    git -C "$DT_PATH" clean -fd
else
    echo "== Дерево устройства на месте ($DT_PATH), не трогаю (UPDATE_DT=1 чтобы обновить) =="
fi

# ------------------------------------------------------------------
# Правки дерева под AERA 16. Делаются один раз, маркер снимается при UPDATE_DT=1.
#
# Дерево писалось под OrangeFox 14.1 (Android 14, релиз ap2a). Остальные
# переменные дерева (OF_*, TW_*, TARGET_*, BOARD_*) в A16 валидны, а inherit-цели
# (base.mk, core_64_bit_only.mk, virtual_ab_ota.mk, virtual_ab_ota/compression.mk,
# emulated_storage.mk, vendor/twrp/config/common.mk) в манифесте AERA есть.
#
# Правки идемпотентны, поэтому применяются при каждом запуске (маркера нет:
# иначе после правки скрипта старое дерево осталось бы непропатченным).
# ------------------------------------------------------------------
echo "== Правлю дерево под AERA 16 =="

# 1) релиз-конфиг: ap2a (A14) -> bp2a (A16)
sed -i "s/\btwrp_${DEVICE}-ap2a-eng\b/${PRODUCT}-${RELEASE}-${VARIANT}/g" \
    "$DT_PATH/AndroidProducts.mk"
grep -q "${PRODUCT}-${RELEASE}-${VARIANT}" "$DT_PATH/AndroidProducts.mk" || {
    echo "!! В AndroidProducts.mk нет COMMON_LUNCH_CHOICES с ${RELEASE}."
    echo "   Дерево изменилось — проверь файл руками:"
    cat "$DT_PATH/AndroidProducts.mk"
    exit 1
}

# 2) Выбрасываем A14-пребилт libc++.so из recovery/root.
#
# Дерево писалось под OrangeFox 14.1 и кладёт в recovery/root/system/lib64
# набор библиотек, снятых с A14. Каталог recovery/root копируется в ramdisk
# ПОВЕРХ собранного, поэтому A14-библиотеки затирают собранные A16.
# Для libc++ это смертельно: в A14-версии нет символов, которые требует
# A16-овый init (vtable std::basic_stringstream, std::__fs::filesystem::*).
# Результат — linker: CANNOT LINK EXECUTABLE "/system/bin/init", init
# не стартует, ядро паникует "Attempted to kill init" и телефон уходит в
# ZTE memory dump mode. Этим же пребилтом ломались recovery, fastbootd,
# update_engine_sideload, libtar, libvintf, libfs_mgr, lpunpack.
#
# Остальные пребилты оставляем: версионные HAL NDK (keymint-V3 и т.п.) нужны
# A14-блобам, а generic-библиотеки (libion, libexpat, ...) проверку символов
# проходят.
rm -f "$DT_PATH/recovery/root/system/lib64/libc++.so"

# 2b) То же с A14-парой binder на вендорной стороне.
#
# Вендорные бинарники ищут библиотеки в /vendor/lib64 раньше /system/lib64, и
# A14-овая vendor/lib64/libbinder_ndk.so не экспортирует символ API 36
# AIBinder_Class_setTransactionCodeToFunctionNameMap, который требуют A16-овые
# HAL NDK библиотеки (/system/lib64/android.hardware.boot-V1-ndk.so и др.).
# Итог: "CANNOT LINK EXECUTABLE /vendor/bin/hw/android.hardware.boot-service.qti",
# keymint/gatekeeper/boot/health падают с status 1, keystore2 не поднимается,
# recovery навсегда висит в futex_wait_queue на анимации, батарея мертва.
#
# После удаления все 23 вендорных потребителя линкуются с согласованной
# A16-парой из /system/lib64. Это безопасно: NDK binder — стабильный C API, а
# C++-ный libbinder.so на вендорной стороне нужен только самой libbinder_ndk.so
# (проверено по DT_NEEDED всех вендорных ELF).
rm -f "$DT_PATH/recovery/root/vendor/lib64/libbinder_ndk.so"
rm -f "$DT_PATH/recovery/root/vendor/lib64/libbinder.so"

# Удаления из дерева недостаточно: recovery/root в out/ — это staging-каталог,
# из которого собирается ramdisk, и пропавшие в дереве файлы там остаются
# (Soong вендорные варианты этих библиотек не собирает, перезаписывать нечем).
STAGE="$WORK_DIR/out/target/product/$DEVICE/recovery/root"
rm -f "$STAGE/vendor/lib64/libbinder_ndk.so" \
      "$STAGE/vendor/lib64/libbinder.so" \
      "$STAGE/system/lib64/libc++.so"

# 2c) Геометрия нативного UI AERA.
#
# Интерфейс AERA — не XML-тема, а LVGL-движок с канвой шириной 1440. Без
# AERA_UI_ADAPTIVE_RESOLUTION метрики зашиты в код как {3168, 165}, то есть
# layout рассчитан на панель 1440x3168 (OnePlus 13). На панели cerro 1116x2480
# интерфейс из-за этого съезжает и обрезается.
#
# В адаптивном режиме канва = 1440 x (AERA_SCREEN_H * 4/3), см.
# DisplayMetrics::FromThemeMetrics в aeraui/include/aeraui/runner.hpp.
# Для сохранения пропорций панели: 1440 * 2480/1116 = 3200 -> AERA_SCREEN_H=2400
# (сходится с эталонами: dodge 2376*4/3=3168, infiniti 2340*4/3=3120).
# STATUS_H и отступы — литеральные пиксели канвы.
#
# Переменные обязаны стоять в BoardConfig.mk: vendor/recovery/aera_soong_config.mk
# подключается из build/make/core/config.mk сразу после BoardConfig устройства.
if ! grep -q 'AERA_UI_ADAPTIVE_RESOLUTION' "$DT_PATH/BoardConfig.mk"; then
cat >> "$DT_PATH/BoardConfig.mk" << 'EOF'

# ==========================================
# AERA native UI (канва 1440 x 3200 под панель 1116x2480)
# ==========================================
AERA_UI_ADAPTIVE_RESOLUTION := true
AERA_SCREEN_H := 2400
AERA_STATUS_H := 130
AERA_STATUS_INDENT_LEFT := 60
AERA_STATUS_INDENT_RIGHT := 60
EOF
fi

# 2d) Wi-Fi.
#
# В дереве delvoryx WLAN не включён вообще, поэтому в recovery нет ни сети, ни
# wpa_supplicant. У AERA это опция AERA_ENABLE_WLAN (внутреннее имя
# OF_ENABLE_WLAN), и она требует трёх вещей:
#   * сам флаг (aera_build.mk подтягивает wpa_supplicant, wpa_cli, dhcptool,
#     ttyd, fuse и выставляет TW_ENABLE_NETWORK; external/wpa_supplicant_8 в
#     манифесте AERA уже есть);
#   * загрузки вендорных модулей Wi-Fi в recovery. Грузятся они из
#     /vendor_dlkm|/system_dlkm самого телефона, то есть собранные под его
#     ядро. Имена взяты из modules.load дерева nukisystems (по нему собрана
#     прошивка на устройстве); драйвер kiwi_v2 сходится с
#     firmware_class.path=.../wlan/qca_cld/kiwi_v2 из cmdline ядра;
#   * device-specific init.recovery.wifi.rc, который дёргает fs_ready у cnss2 и
#     поднимает wpa_supplicant (у dodge путь к узлу cnss зашит жёстко —
#     b0000000.qcom,cnss-peach; для cerro имя узла другое, поэтому обходим
#     каталог драйвера маской, чтобы не угадывать).
if ! grep -q 'AERA_ENABLE_WLAN' "$DT_PATH/BoardConfig.mk"; then
cat >> "$DT_PATH/BoardConfig.mk" << 'EOF'

# ==========================================
# Wi-Fi (WCN7850 / kiwi_v2)
# ==========================================
AERA_ENABLE_WLAN := 1
# Здесь только cnss-цепочка: она целиком лежит в vendor_dlkm и грузится
# загрузчиком AERA без проблем. rfkill/cfg80211/сам драйвер грузит наш
# init.recovery.wifi.rc — см. комментарий там.
AERA_LOAD_VENDOR_MODULES := "cnss_prealloc.ko cnss_utils.ko cnss_plat_ipc_qmi_svc.ko cnss_nl.ko wlan_firmware_service.ko cnss2.ko"
EOF
fi

# Блок выше дописывается только при первом прогоне, поэтому список модулей
# приводим к нужному виду отдельно — иначе на уже пропатченном дереве правка
# списка не применится.
sed -i -E 's|^AERA_LOAD_VENDOR_MODULES := ".*"$|AERA_LOAD_VENDOR_MODULES := "cnss_prealloc.ko cnss_utils.ko cnss_plat_ipc_qmi_svc.ko cnss_nl.ko wlan_firmware_service.ko cnss2.ko"|' \
    "$DT_PATH/BoardConfig.mk"

cat > "$DT_PATH/recovery/root/init.recovery.wifi.rc" << 'EOF'
# Wi-Fi в recovery для cerro (WCN7850 / kiwi_v2).
#
# Последовательность проверена вживую на устройстве 09.11.2026, каждый шаг
# закрывает конкретную найденную причину:
#
#  1) rfkill.ko лежит в system_dlkm (а не в vendor_dlkm), и загрузчик модулей
#     AERA его не находит. Без rfkill cfg80211 падает с
#     "Unknown symbol rfkill_destroy", а без cfg80211 не грузится драйвер.
#     Поэтому rfkill -> cfg80211 -> qca_cld3_kiwi_v2 грузим здесь и в этом
#     порядке, смонтировав оба раздела сами.
#  2) Драйверу нужен wlan/qca_cld/kiwi_v2/WCNSS_qcom_cfg.ini. Он лежит на
#     разделе vendor, а /vendor в recovery не смонтирован, поэтому ядро его не
#     находит ни по одному из путей firmware_class.path и probe падает с
#     "Failed to probe host driver, err = -1". Копируем ini в /etc/firmware
#     (это /system/etc в рамдиске, он доступен на запись) ДО того, как дёрнем
#     fs_ready.
#  3) wpa_supplicant.conf лежит там же на vendor — копируем в рамдиск, иначе
#     сервис умирает сразу ("failed to enter running state").
#  4) Только после этого дёргаем fs_ready у узла cnss2 (у cerro он называется
#     b0000000.qcom,cnss-kiwi, но идём по маске) и ждём появления wlan0.
#
# Разделы в mapper слот-суффиксные (vendor_a/vendor_b), поэтому перебираем
# варианты; vendor_dlkm_* исключаем явным перечислением имён.

# Запускаемся по старту самого recovery: это надёжно. Триггер
# post.decrypt.modules=true (как у dodge) не годится — вызов, который его
# выставляет, обёрнут в #ifdef TW_POST_DECRYPT_MODULES и к тому же требует
# TW_CRYPTO_PWTYPE==0, то есть на устройстве с PIN не срабатывает вообще.
on property:init.svc.recovery=running
    start aera-prep

# И повторно, когда интерфейс просит включить Wi-Fi.
on property:sys.aera.wlan.up=1
    start aera-prep

on property:wifi.driver.ready=true
    mkdir /tmp/recovery 0777 root root
    mkdir /tmp/recovery/sockets 0777 root root
    start wpa_supplicant

on property:sys.aera.wlan.up=1 && property:wifi.driver.ready=true
    setprop sys.aera.wlan.up 0
    mkdir /tmp/recovery 0777 root root
    mkdir /tmp/recovery/sockets 0777 root root
    start wpa_supplicant

service aera-prep /system/bin/sh /system/bin/aera-prep.sh
    disabled
    oneshot
    user root
    group root
    seclabel u:r:recovery:s0

service wpa_supplicant /system/bin/wpa_supplicant -Dnl80211 -iwlan0 -dd -O/tmp/recovery/sockets -c/vendor/etc/wifi/wpa_supplicant.conf
    disabled
    seclabel u:r:recovery:s0
EOF

mkdir -p "$DT_PATH/recovery/root/system/bin"
cat > "$DT_PATH/recovery/root/system/bin/aera-prep.sh" << 'EOF'
#!/system/bin/sh
# Подготовка железа для AERA recovery (cerro): Wi-Fi и GPU. Запускается из
# init.recovery.wifi.rc по post.decrypt.modules=true. Подробности причин — там.

log() { echo "aera-prep: $*" > /dev/kmsg 2>/dev/null; }

log "start"

# Уже поднимали — выходим (сервис может быть запущен несколькими триггерами)
[ -e /sys/class/net/wlan0 ] && { log "wlan0 already up"; setprop wifi.driver.ready true; exit 0; }

# --- 0. ждём cnss2: его грузит загрузчик модулей AERA в начале работы
#        recovery, а драйвер qca_cld3_kiwi_v2 зависит от него
i=0
while [ $i -lt 60 ]; do
    [ -d /sys/bus/platform/drivers/cnss2 ] && break
    sleep 1
    i=$((i+1))
done
[ -d /sys/bus/platform/drivers/cnss2 ] || { log "cnss2 driver never appeared"; exit 1; }
log "cnss2 present after ${i}s"

# --- 1. ждём появления dm-устройств разделов (их создаёт recovery при
#        разборе разделов) и монтируем ИМЕННО по каноническим путям:
#        modules.dep содержит абсолютные пути /vendor_dlkm/lib/modules/...,
#        и modprobe ищет зависимости строго по ним.
i=0
while [ $i -lt 30 ]; do
    ls /dev/block/mapper/vendor_dlkm_* >/dev/null 2>&1 && break
    sleep 1
    i=$((i+1))
done

mkdir -p /vendor_dlkm /system_dlkm /tmp/wlan/vendor
for d in /dev/block/mapper/vendor_dlkm_a /dev/block/mapper/vendor_dlkm_b /dev/block/by-name/vendor_dlkm; do
    [ -e "$d" ] && mount -o ro "$d" /vendor_dlkm 2>/dev/null && break
done
for d in /dev/block/mapper/system_dlkm_a /dev/block/mapper/system_dlkm_b /dev/block/by-name/system_dlkm; do
    [ -e "$d" ] && mount -o ro "$d" /system_dlkm 2>/dev/null && break
done
for d in /dev/block/mapper/vendor_a /dev/block/mapper/vendor_b /dev/block/mapper/vendor; do
    [ -e "$d" ] && mount -o ro "$d" /tmp/wlan/vendor 2>/dev/null && break
done
log "mounted: $(grep -cE '/vendor_dlkm|/system_dlkm|/tmp/wlan/vendor' /proc/mounts) of 3"

# --- 2. прошивка чипа и конфиги supplicant из вендора в рамдиск.
#        Права обязательны: cp сохраняет исходные 0600/0700, и wpa_supplicant
#        падает в цикле с "Failed to open config file ... Permission denied".
mkdir -p /etc/firmware/wlan/qca_cld/kiwi_v2 /vendor/etc/wifi
if [ -f /tmp/wlan/vendor/etc/wifi/WCNSS_qcom_cfg.ini ]; then
    cp /tmp/wlan/vendor/etc/wifi/WCNSS_qcom_cfg.ini /etc/firmware/wlan/qca_cld/kiwi_v2/
    chmod 644 /etc/firmware/wlan/qca_cld/kiwi_v2/WCNSS_qcom_cfg.ini
    log "staged WCNSS_qcom_cfg.ini"
else
    log "WCNSS_qcom_cfg.ini not found on vendor"
fi
for f in wpa_supplicant.conf wpa_supplicant_overlay.conf p2p_supplicant_overlay.conf; do
    [ -f "/tmp/wlan/vendor/etc/wifi/$f" ] && cp "/tmp/wlan/vendor/etc/wifi/$f" /vendor/etc/wifi/
done
chmod 755 /vendor /vendor/etc /vendor/etc/wifi 2>/dev/null
chmod 644 /vendor/etc/wifi/*.conf 2>/dev/null
log "staged supplicant configs"

# --- 3. драйвер через modprobe: сам тянет всю цепочку зависимостей
#        (cnss*, cfg80211, rfkill, ipam и прочее). Руками списком это не
#        собрать: драйверу нужен ещё и ipam.ko, иначе он падает с
#        "Unknown symbol ipa_wdi_*".
if modprobe -d /vendor_dlkm/lib/modules qca_cld3_kiwi_v2 >/dev/null 2>&1; then
    log "modprobe qca_cld3_kiwi_v2 ok"
else
    log "modprobe failed, пробую insmod вручную"
    for m in $(find /system_dlkm -name rfkill.ko 2>/dev/null | head -1) \
             /vendor_dlkm/lib/modules/cfg80211.ko \
             /vendor_dlkm/lib/modules/ipam.ko \
             /vendor_dlkm/lib/modules/qca_cld3_kiwi_v2.ko; do
        [ -f "$m" ] && insmod "$m" 2>/dev/null && log "loaded $(basename $m)"
    done
fi
grep -q "^qca_cld3_kiwi_v2 " /proc/modules && log "driver in kernel" || log "driver NOT loaded"

# --- 3b. GPU: песочница браузера пробрасывает внутрь /dev/kgsl-3d0, и без
#         драйвера minijail падает с "cannot create mount target
#         /tmp/aera-web-*/dev/kgsl-3d0" -> "Browsing unavailable".
#         msm_kgsl в recovery init не грузит (его нет среди 282 модулей),
#         поэтому грузим сами; modprobe подтягивает зависимости (nvmem_qfprom).
if [ ! -e /dev/kgsl-3d0 ]; then
    if modprobe -d /vendor_dlkm/lib/modules msm_kgsl >/dev/null 2>&1; then
        log "msm_kgsl loaded"
    else
        log "msm_kgsl failed"
    fi
fi
[ -e /dev/kgsl-3d0 ] && log "kgsl node present" || log "kgsl node MISSING"

# --- 4. разрешаем чипу стартовать и ждём интерфейс
for f in /sys/bus/platform/drivers/cnss2/*/fs_ready; do
    chmod 222 "$f" 2>/dev/null
    echo 1 > "$f" 2>/dev/null
done

i=0
while [ $i -lt 30 ]; do
    [ -e /sys/class/net/wlan0 ] && break
    sleep 1
    i=$((i+1))
done

if [ -e /sys/class/net/wlan0 ]; then
    log "wlan0 is up"
    setprop wifi.driver.ready true
else
    log "wlan0 did not appear"
fi

# модули уже в памяти, разделы больше не нужны — отпускаем, чтобы не мешать
# recovery монтировать их по своему усмотрению
umount /tmp/wlan/vendor /vendor_dlkm /system_dlkm 2>/dev/null
EOF
chmod 755 "$DT_PATH/recovery/root/system/bin/aera-prep.sh"

# 2e-bis) Тип сборки: Stable намеренно выключает ADB и MTP.
#
# aera_build.mk: при пустом AERA_BUILD_TYPE подставляется Stable, а для Stable
# включается OF_ADVANCED_SECURITY, и twrp.cpp на старте пишет в лог
# "ADB & MTP disabled by maintainer", выставляя fox_advanced_security=1 и
# tw_mtp_enabled=0. Отсюда и наблюдаемое поведение: adb появлялся только в
# режиме sideload (он поднимается отдельным путём) и отваливался сразу после
# старта интерфейса.
# Допустимые значения: Alpha, Beta, Nightly, Stable.
if ! grep -q 'AERA_BUILD_TYPE' "$DT_PATH/BoardConfig.mk"; then
cat >> "$DT_PATH/BoardConfig.mk" << 'EOF'

# ==========================================
# Тип сборки: НЕ Stable, иначе AERA гасит ADB и MTP
# (aera_build.mk -> OF_ADVANCED_SECURITY -> twrp.cpp)
# ==========================================
AERA_BUILD_TYPE := Beta
EOF
fi

# 2f) Языки интерфейса.
#
# В движок AERA зашито 33 языка (aeraui/localization/i18n.cpp), но без
# AERA_EXTRA_LANGUAGES в сборку попадает только English. По тому же флагу
# подключается CJK-набор шрифтов (aeraui/localization/fonts/aera_fallback.cpp),
# без него китайские и японские глифы не отрисуются вообще.
# AERA_DEFAULT_LANGUAGE — язык при первом запуске; остальные выбираются в
# настройках recovery. Русский, 简体中文 и 繁體中文 входят в набор.
if ! grep -q 'AERA_EXTRA_LANGUAGES' "$DT_PATH/BoardConfig.mk"; then
cat >> "$DT_PATH/BoardConfig.mk" << 'EOF'

# ==========================================
# Языки: все 33 из движка + CJK-шрифты, по умолчанию русский
# ==========================================
AERA_EXTRA_LANGUAGES := true
AERA_DEFAULT_LANGUAGE := ru
EOF
fi

# 2g) Офлайн-провайдеры рута.
#
# По умолчанию AERA_ENABLE_ROOT_MANAGER=0 (aera_config.mk), и тогда каталог
# /system/etc/aera/root-providers в рамдиск не попадает — recovery пытается
# скачивать модули из сети и сообщает, что не может их загрузить. С флагом=1
# package_root_modules.py упаковывает в образ готовые KernelSU, KernelSU-Next
# и SukiSU Ultra (~5.5 МБ из bootable/recovery/prebuilt/aera/root), и сеть для
# них больше не нужна.
# AERA_ROOT_MODULE_KERNELS можно сузить до своей версии ядра (у нас 6.1),
# но оставляю все: образ в 100 МБ и так не заполнен.
if ! grep -q 'AERA_ENABLE_ROOT_MANAGER' "$DT_PATH/BoardConfig.mk"; then
cat >> "$DT_PATH/BoardConfig.mk" << 'EOF'

# ==========================================
# Root Manager: офлайн-модули ВЫКЛючены — 5,8 МБ отданы движку браузера.
# Качаются из сети сами: busybox в образе есть (см. AERA_USE_BUSYBOX_BINARY)
# ==========================================
AERA_ENABLE_ROOT_MANAGER := 0
EOF
fi
sed -i -E 's|^AERA_ENABLE_ROOT_MANAGER := .*$|AERA_ENABLE_ROOT_MANAGER := 0|' "$DT_PATH/BoardConfig.mk"

# 2h) Браузер.
#
# Движок — пребилт WPE WebKit (aeraui/features/browser/prebuilt/runtime.xz,
# 41 МБ), модуль aera-browser-runtime помечен optional, и в Android.mk прямо
# написано: "The device product opts in by including aera-browser-runtime".
# Без этой строки каталог /system/etc/aera-browser в образ не попадает, сессия
# не поднимается и UI пишет "Browsing unavailable".
#
# Место: раздел recovery у cerro — ровно 100 МБ (104857600 байт), поэтому под
# движок освобождены офлайн-модули рута (-5,8 МБ) и включено UPX-сжатие
# бинарников. Если образ всё равно не влезет, сборка упадёт на проверке
# размера — тогда придётся выбирать между браузером и CJK-шрифтами (21 МБ).
if ! grep -q 'aera-browser-runtime' "$DT_PATH/device.mk"; then
cat >> "$DT_PATH/device.mk" << 'EOF'

# Браузер AERA: движок ставится только по явному запросу продукта
PRODUCT_PACKAGES += aera-browser-runtime
EOF
fi

# Плюс cgroup для песочницы движка.
#
# jail_main.cpp ограничивает движок по памяти через собственные cgroup-группы
# и жёстко ждёт две точки монтирования:
#   mkdir /dev/cg2_bpf/<name>   (cgroup v2, оттуда же берётся cgroup.kill)
#   mkdir /dev/memcg/<name>     (memory cgroup v1, memory.limit_in_bytes)
# В recovery /dev/memcg смонтирован, а /dev/cg2_bpf — нет: cgroup2 висит
# только на /sys/fs/cgroup. Итог — Check(mkdir(...)) падает с ENOENT, в логе
# "private browser task group: No such file or directory", UI показывает
# бесконечный "Starting private browser" и затем "Browsing unavailable".
# Проверено на устройстве: cgroup2 спокойно монтируется второй точкой, после
# чего mkdir проходит и cgroup.kill доступен.
cat > "$DT_PATH/recovery/root/init.recovery.browser.rc" << 'EOF'
# Песочница браузера AERA: вторая точка монтирования cgroup2.
on early-init
    mkdir /dev/cg2_bpf 0700 root root
    mount cgroup2 none /dev/cg2_bpf nodev noexec nosuid
EOF

if ! grep -q 'init.recovery.browser.rc' "$DT_PATH/recovery/root/init.recovery.qcom.rc"; then
    sed -i '0,/^import /s//import init.recovery.browser.rc\nimport /' \
        "$DT_PATH/recovery/root/init.recovery.qcom.rc"
fi
# Идемпотентно — чтобы правка применялась и на уже пропатченном дереве
sed -i -E 's|^AERA_EXTRA_LANGUAGES := .*$|AERA_EXTRA_LANGUAGES := true|; s|^AERA_DEFAULT_LANGUAGE := .*$|AERA_DEFAULT_LANGUAGE := ru|' \
    "$DT_PATH/BoardConfig.mk"
# AERA_A16.sh читает ту же переменную из окружения — держим имя образа в согласии
export AERA_BUILD_TYPE=Beta

# 2e-ter) busybox в рамдиске — без него не работает загрузка из сети.
#
# AERA качает каталог плагинов не библиотекой, а через busybox:
#   aeraui/features/plugins/download.hpp ->
#   execv("/sbin/busybox", {"wget","-q","-T","120","-t","1","-O",path,url})
# При AERA_USE_BUSYBOX_BINARY != 1 скрипт сборки busybox из рамдиска УДАЛЯЕТ
# (AERA_A16.sh: rm -f $AERA_RAMDISK/$RAMDISK_SBIN/busybox), execv падает, и
# интерфейс показывает "Could not download the AERA plugin catalog" — при
# полностью рабочей сети. Проверено: с телефона TCP до raw.githubusercontent.com
# и jsDelivr проходит, DNS и маршрут на месте, busybox в образе отсутствовал.
#
# Эти переменные в make-мост aera_config.mk не входят, AERA_A16.sh читает их
# из окружения, поэтому именно export, а не BoardConfig.
export AERA_USE_BUSYBOX_BINARY=1

# MiSans — шрифт для корректного отображения китайского (AERA_A16.sh заменяет
# им InterDisplay). Нужен, раз в наборе языков есть 简体中文/繁體中文.
export AERA_USE_MISANS_FONTS=1

# UPX-сжатие бинарников /sbin и /system/bin — освобождает место под
# движок браузера. Самораспаковывающиеся файлы остаются исполняемыми.
export AERA_COMPRESS_EXECUTABLES=1

# 2e) ADB в обычном recovery.
#
# В init.recovery.usb.rc старт adbd висит на триггерах sys.usb.config=adb /
# mtp,adb / sideload, но саму переменную в обычном recovery никто не выставляет:
# persist.sys.usb.config=adb лежит в пропах, а persist-свойства читаются с /data,
# которого на старте ещё нет. Итог: adbd не стартует, sys.usb.ffs.ready остаётся
# 0, UDC не прописывается — телефона нет на USB вообще, adb появляется только в
# режиме sideload (он поднимает adbd отдельным путём).
if ! grep -q 'AERA: adb по умолчанию' "$DT_PATH/recovery/root/init.recovery.usb.rc"; then
cat >> "$DT_PATH/recovery/root/init.recovery.usb.rc" << 'EOF'

# AERA: adb по умолчанию
on property:sys.usb.configfs=1
    setprop sys.usb.config adb
EOF
fi

if ! grep -q 'init.recovery.wifi.rc' "$DT_PATH/recovery/root/init.recovery.qcom.rc"; then
    sed -i '0,/^import /s//import init.recovery.wifi.rc\nimport /' \
        "$DT_PATH/recovery/root/init.recovery.qcom.rc"
fi

# 3) TARGET_RECOVERY_PIXEL_FORMAT := "RGBX_8888" -> без кавычек.
# В A16 это значение уходит в out/soong/soong.$PRODUCT.extra.variables как
# "RecoveryPixelFormat": ""RGBX_8888"" — невалидный JSON, и merge_json роняет
# сборку на //build/soong:product_config (на ~90%, уже после компиляции).
sed -i -E 's/^(TARGET_RECOVERY_PIXEL_FORMAT[[:space:]]*:?=[[:space:]]*)"(.*)"[[:space:]]*$/\1\2/' \
    "$DT_PATH/BoardConfig.mk"

if [ -n "$MAINTAINER" ]; then
    echo "   мейнтейнер -> $MAINTAINER"
    sed -i "s/^OF_MAINTAINER :=.*/OF_MAINTAINER := $MAINTAINER/" "$DT_PATH/fox_cerro.mk"
fi
echo "== Правки применены =="

if [ "$SYNC_ONLY" = "1" ]; then
    echo "== SYNC_ONLY=1: исходники и дерево готовы, сборку не запускаю =="
    exit 0
fi

# ------------------------------------------------------------------
# out/ от другого манифеста/ветки несовместим — сносим.
# ------------------------------------------------------------------
OUT_STAMP="$WORK_DIR/out/.aera_manifest"
if [ "$WIPE_OUT" = "1" ] || \
   { [ "$WIPE_OUT" = "auto" ] && [ -d "$WORK_DIR/out" ] && \
     [ "$(cat "$OUT_STAMP" 2>/dev/null)" != "$MANIFEST_BRANCH" ]; }; then
    echo "== out/ остался от другой сборки — удаляю =="
    rm -rf "$WORK_DIR/out"
fi
mkdir -p "$WORK_DIR/out"
echo "$MANIFEST_BRANCH" > "$OUT_STAMP"

if [ "$USE_CCACHE_BUILD" = "true" ] && command -v ccache >/dev/null; then
    export USE_CCACHE=1
    export CCACHE_EXEC=$(command -v ccache)
    ccache -M "$CCACHE_SIZE" >/dev/null
    echo "== ccache включён, лимит $CCACHE_SIZE =="
fi

# Дерево собирается с ALLOW_MISSING_DEPENDENCIES (так же, как у AERA и у OFRP):
# recovery-продукт не тянет половину платформенных модулей.
export ALLOW_MISSING_DEPENDENCIES=true
export LC_ALL=C

# Держим тяжёлые по памяти шаги в узде: 31 ГБ RAM на 16 потоков — впритык
export NINJA_HIGHMEM_NUM_JOBS="$HIGHMEM_JOBS"

set +e
source build/envsetup.sh

# lunch нельзя гнать через pipe (ушёл бы в subshell вместе с TARGET_PRODUCT),
# поэтому пишем в лог и печатаем его отдельно.
lunch "${PRODUCT}-${RELEASE}-${VARIANT}" > "$LOG_DIR/lunch.log" 2>&1
rc=$?
cat "$LOG_DIR/lunch.log"
if [ $rc -ne 0 ] || [ "$TARGET_PRODUCT" != "$PRODUCT" ]; then
    cat <<EOF

!! lunch ${PRODUCT}-${RELEASE}-${VARIANT} не прошёл (лог: $LOG_DIR/lunch.log).
   Ошибки вида "XXX is obsolete" означают, что переменная из A14-дерева в A16
   больше не поддерживается — её надо осознанно убрать/заменить в
   $DT_PATH, а не вырезать вслепую.
EOF
    exit 1
fi

BUILD_LOG="$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log"
echo "== Сборка: mka adbd recoveryimage -j$BUILD_THREADS =="
echo "   лог: $BUILD_LOG"
mka adbd recoveryimage -j"$BUILD_THREADS" 2>&1 | tee "$BUILD_LOG"
rc=${PIPESTATUS[0]}

OUT_PRODUCT="$WORK_DIR/out/target/product/$DEVICE"
if [ $rc -eq 0 ]; then
    echo
    echo "== Готово =="
    ls -lh "$OUT_PRODUCT"/recovery.img 2>/dev/null
    ls -lh "$OUT_PRODUCT"/*.zip 2>/dev/null
    cat <<EOF

   recovery.img — ramdisk-only (кернел берётся из boot), под отдельный
   раздел recovery:   fastboot flash recovery $OUT_PRODUCT/recovery.img
EOF
else
    echo
    echo "!! Сборка упала (код $rc). Первые ошибки:"
    grep -nE "error:|FAILED|ninja: build stopped" "$BUILD_LOG" | head -20
    echo "   полный лог: $BUILD_LOG"
    echo "   повторный прогон без синка:  NO_SYNC=1 bash $0"
fi
exit $rc
