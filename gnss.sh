#!/usr/bin/env bash
# Real GNSS passthrough for Waydroid (Android 13, x86_64, overlay mode).
#
# Installs the legacy gps.default HAL from Lolmc0587/android_gps_libraries 2.1
# as new files under /var/lib/waydroid/overlay/vendor and binds a host serial
# device (default /dev/ttyGPSD) into the container. Android sees a real GPS
# provider; no mock location is involved.
#
#   sudo ./gnss.sh install     install HAL files, props, VINTF fragment, device mapping
#   sudo ./gnss.sh uninstall   remove exactly what install created
#   sudo ./gnss.sh reapply     restore config_nodes mapping (+ no_new_privs) after `waydroid upgrade`
#   ./gnss.sh status           show what is installed and wired up
#
# Environment:
#   GNSS_DEVICE=ttyGPSD     device name under /dev on host and in the container
#   GNSS_KEEP_NNP=1         reapply leaves lxc.no_new_privs alone (default: force 0)
#   WAYDROID_DIR, GNSS_STATE_DIR, GNSS_CACHE_DIR   path overrides
#   GNSS_TEST=1             skip root check and all waydroid commands (sandbox testing)

set -euo pipefail

readonly ARCHIVE_URL="https://github.com/Lolmc0587/android_gps_libraries/archive/refs/tags/2.1.zip"
readonly ARCHIVE_MD5="f84c369c7cebd9dbb8987ca15c6aa856"
readonly ARCHIVE_ROOT="android_gps_libraries-2.1/13/x86_64"

readonly DEVICE="${GNSS_DEVICE:-ttyGPSD}"
readonly WAYDROID_DIR="${WAYDROID_DIR:-/var/lib/waydroid}"
readonly STATE_DIR="${GNSS_STATE_DIR:-/var/lib/waydroid-gnss}"
readonly CACHE_DIR="${GNSS_CACHE_DIR:-/var/cache/waydroid-gnss}"
readonly TEST="${GNSS_TEST:-0}"

readonly CFG="$WAYDROID_DIR/waydroid.cfg"
readonly VENDOR="$WAYDROID_DIR/overlay/vendor"
readonly LXC_DIR="$WAYDROID_DIR/lxc/waydroid"
readonly OWNED="$STATE_DIR/owned"      # files of the committed install
readonly PENDING="$STATE_DIR/pending"  # new files of an install in progress / interrupted
readonly MAPPING="lxc.mount.entry = /dev/$DEVICE dev/$DEVICE none bind,create=file,optional 0 0"

# archive path (relative to ARCHIVE_ROOT) -> overlay/vendor path, mode
readonly ARCHIVE_FILES=(
    "vendor/bin/hw/android.hardware.gnss@1.0-service|bin/hw/android.hardware.gnss@1.0-service|0755"
    "system/lib/hw/android.hardware.gnss@1.0-impl.so|lib/hw/android.hardware.gnss@1.0-impl.so|0644"
    "system/lib64/hw/android.hardware.gnss@1.0-impl.so|lib64/hw/android.hardware.gnss@1.0-impl.so|0644"
    "system/lib/hw/gps.default.so|lib/hw/gps.default.so|0644"
    "system/lib64/hw/gps.default.so|lib64/hw/gps.default.so|0644"
    "system/etc/init/android.hardware.gnss@1.0-service.rc|etc/init/android.hardware.gnss@1.0-service.rc|0644"
)
# system.img path -> overlay/vendor path (HIDL interface lib the vendor HAL needs)
readonly IMAGE_FILES=(
    "/system/lib/android.hardware.gnss@1.0.so|lib/hw/android.hardware.gnss@1.0.so"
    "/system/lib64/android.hardware.gnss@1.0.so|lib64/hw/android.hardware.gnss@1.0.so"
)
readonly VINTF_FRAGMENT="etc/vintf/manifest/android.hardware.gnss@1.0-service.xml"
readonly PROPS_RC="etc/init/waydroid-gnss-props.rc"

log() { printf '[gnss] %s\n' "$*" >&2; }
die() { printf '[gnss] error: %s\n' "$*" >&2; exit 1; }

require_root() {
    [[ $TEST == 1 || $EUID -eq 0 ]] || die "run as root (sudo $0 $*)"
}

cfg_get() { # key -> value from [waydroid] section
    sed -n "/^\[waydroid\]/,/^\[/{s/^$1[[:space:]]*=[[:space:]]*//p}" "$CFG"
}

check_target() {
    [[ -f $CFG ]] || die "$CFG not found; is Waydroid initialised?"
    [[ $(cfg_get mount_overlays) == True ]] || die "mount_overlays is not True in $CFG"
    [[ $(cfg_get arch) == x86_64 ]] || die "only x86_64 is supported (arch=$(cfg_get arch))"
    local release
    release=$(debugfs -R "cat /system/build.prop" "$(system_img)" 2>/dev/null |
        sed -n 's/^ro\.build\.version\.release=//p')
    [[ $release == 13 ]] || die "only Android 13 is supported (system.img reports '${release:-unknown}')"
}

system_img() {
    local dir
    dir=$(cfg_get images_path)
    echo "${dir:-$WAYDROID_DIR/images}/system.img"
}

stop_container() {
    [[ $TEST == 1 ]] && return
    if waydroid status 2>/dev/null | grep -qE '^Container:[[:space:]]+(RUNNING|FROZEN)'; then
        log "stopping Waydroid container"
        waydroid container stop
    fi
}

fetch_archive() {
    local zip="$CACHE_DIR/android_gps_libraries-2.1.zip"
    mkdir -p "$CACHE_DIR"
    if [[ ! -f $zip ]] || [[ $(md5sum <"$zip" | cut -d' ' -f1) != "$ARCHIVE_MD5" ]]; then
        log "downloading $ARCHIVE_URL"
        curl -fsSL -o "$zip.part" "$ARCHIVE_URL"
        mv "$zip.part" "$zip"
    fi
    [[ $(md5sum <"$zip" | cut -d' ' -f1) == "$ARCHIVE_MD5" ]] || die "archive md5 mismatch: $zip"
    echo "$zip"
}

# Install $1 to overlay/vendor/$2 with mode $3.
place() {
    local src=$1 rel=$2 mode=$3 dst="$VENDOR/$2"
    if [[ $TEST == 1 ]]; then
        install -D -m "$mode" "$src" "$dst"
    else
        install -D -m "$mode" -o 0 -g 0 "$src" "$dst"
    fi
}

# Remove now-empty parent directories of overlay/vendor/$1, never the vendor root.
prune_dirs() {
    local dir
    dir=$(dirname "$VENDOR/$1")
    while [[ $dir != "$VENDOR" && $dir == "$VENDOR"/* ]] && rmdir "$dir" 2>/dev/null; do
        dir=$(dirname "$dir")
    done
}

# True if overlay/vendor/$1 exists but was not created by this script.
foreign() {
    [[ -e $VENDOR/$1 ]] && ! grep -qxF "$1" "$OWNED" "$PENDING" 2>/dev/null
}

owned() { grep -qxF "$1" "$OWNED" 2>/dev/null; }

# Install transaction state, consumed by the EXIT trap.
TXN_WORK=""
TXN_ACTIVE=0
TXN_PLACED=()

# Undo every file touched by the current install: restore backed-up previous
# versions, delete files that did not exist before. The pending journal is only
# dropped once everything it lists is gone, so uninstall can still find leftovers.
rollback() {
    local rel backup ok=1
    for rel in "${TXN_PLACED[@]}"; do
        backup="$TXN_WORK/backup/$rel"
        if [[ -e $backup ]]; then
            cmp -s "$backup" "$VENDOR/$rel" && continue
            cp -a "$backup" "$VENDOR/$rel" || { ok=0; log "rollback: could not restore $VENDOR/$rel"; }
        else
            rm -f "$VENDOR/$rel" || { ok=0; log "rollback: could not remove $VENDOR/$rel"; }
            prune_dirs "$rel"
        fi
    done
    if [[ $ok == 1 ]]; then
        rm -f "$PENDING"
        log "install failed; rolled back ${#TXN_PLACED[@]} file(s), previous state kept"
    else
        log "install failed; rollback incomplete, leftovers recorded in $PENDING (removed by uninstall)"
    fi
}

on_exit() {
    set +e
    [[ $TXN_ACTIVE == 1 ]] && rollback
    [[ -n $TXN_WORK ]] && rm -rf "$TXN_WORK"
}

write_vintf_fragment() {
    cat <<'EOF'
<manifest version="1.0" type="device">
    <hal format="hidl">
        <name>android.hardware.gnss</name>
        <transport>hwbinder</transport>
        <version>1.0</version>
        <interface>
            <name>IGnss</name>
            <instance>default</instance>
        </interface>
    </hal>
</manifest>
EOF
}

write_props_rc() {
    # gps.default.so opens /dev/$(ro.kernel.android.gps). Baud is irrelevant for
    # USB CDC-ACM receivers; for a real UART add: setprop ro.kernel.android.gpsttybaud 9600
    cat <<EOF
on early-init
    setprop ro.kernel.android.gps $DEVICE
    setprop ro.factory.hasGPS true
EOF
}

cmd_install() {
    require_root install
    check_target
    local zip rel spec src mode staged=() rels=() new=()
    zip=$(fetch_archive)
    TXN_WORK=$(mktemp -d)
    trap on_exit EXIT
    trap 'exit 130' INT TERM

    # Stage everything first: download/extract failures touch nothing.
    unzip -q "$zip" "$ARCHIVE_ROOT/*" -d "$TXN_WORK"
    for spec in "${ARCHIVE_FILES[@]}"; do
        IFS='|' read -r src rel mode <<<"$spec"
        staged+=("$TXN_WORK/$ARCHIVE_ROOT/$src|$rel|$mode")
    done
    for spec in "${IMAGE_FILES[@]}"; do
        IFS='|' read -r src rel <<<"$spec"
        debugfs -R "dump $src $TXN_WORK/img-${rel//\//_}" "$(system_img)" 2>/dev/null
        [[ -s $TXN_WORK/img-${rel//\//_} ]] || die "could not extract $src from $(system_img)"
        staged+=("$TXN_WORK/img-${rel//\//_}|$rel|0644")
    done
    write_vintf_fragment >"$TXN_WORK/fragment.xml"
    staged+=("$TXN_WORK/fragment.xml|$VINTF_FRAGMENT|0644")
    write_props_rc >"$TXN_WORK/props.rc"
    staged+=("$TXN_WORK/props.rc|$PROPS_RC|0644")

    for spec in "${staged[@]}"; do
        IFS='|' read -r src rel mode <<<"$spec"
        if foreign "$rel"; then die "refusing to overwrite $VENDOR/$rel (not created by this script)"; fi
        rels+=("$rel")
        if [[ -e $VENDOR/$rel ]] && owned "$rel"; then
            # previous install's file: keep a copy so a failed reinstall can restore it
            mkdir -p "$(dirname "$TXN_WORK/backup/$rel")"
            cp -a "$VENDOR/$rel" "$TXN_WORK/backup/$rel"
        else
            # absent, or a leftover of an interrupted install: delete on rollback
            new+=("$rel")
        fi
    done

    stop_container
    mkdir -p "$STATE_DIR"
    # Journal new paths before creating them so even a SIGKILL leaves uninstall a record.
    printf '%s\n' "${new[@]}" >"$PENDING.tmp"
    mv "$PENDING.tmp" "$PENDING"

    TXN_ACTIVE=1
    for spec in "${staged[@]}"; do
        IFS='|' read -r src rel mode <<<"$spec"
        TXN_PLACED+=("$rel")
        place "$src" "$rel" "$mode"
    done

    printf '%s\n' "${rels[@]}" >"$OWNED.tmp"
    mv "$OWNED.tmp" "$OWNED"
    rm -f "$PENDING"
    TXN_ACTIVE=0
    log "installed ${#rels[@]} files under $VENDOR"

    cmd_reapply
    log "done; start a Waydroid session with the receiver plugged in"
}

cmd_reapply() {
    require_root reapply
    local nodes="$LXC_DIR/config_nodes" config="$LXC_DIR/config"
    [[ -f $nodes ]] || die "$nodes not found"
    if grep -qxF "$MAPPING" "$nodes"; then
        log "config_nodes: mapping already present"
    else
        echo "$MAPPING" >>"$nodes"
        log "config_nodes: added /dev/$DEVICE mapping"
    fi
    if [[ ${GNSS_KEEP_NNP:-0} != 1 ]] && grep -qE '^lxc\.no_new_privs[[:space:]]*=[[:space:]]*1' "$config"; then
        sed -i -E 's/^(lxc\.no_new_privs[[:space:]]*=[[:space:]]*)1/\10/' "$config"
        log "config: reset lxc.no_new_privs to 0"
    fi
    log "restart the Waydroid container/session for LXC changes to apply"
}

cmd_uninstall() {
    require_root uninstall
    stop_container
    local rel removed=0 nodes="$LXC_DIR/config_nodes"
    if [[ -f $OWNED || -f $PENDING ]]; then
        # owned = committed install; pending = files from an interrupted install
        while IFS= read -r rel; do
            [[ -n $rel ]] || continue
            rm -f "$VENDOR/$rel"
            prune_dirs "$rel"
            removed=$((removed + 1))
        done < <(cat "$OWNED" "$PENDING" 2>/dev/null | sort -u)
        log "removed $removed files"
        rm -f "$OWNED" "$PENDING"
        rmdir "$STATE_DIR" 2>/dev/null || true
    else
        log "no install record at $OWNED; skipping files"
    fi
    if [[ -f $nodes ]] && grep -qxF "$MAPPING" "$nodes"; then
        grep -vxF "$MAPPING" "$nodes" >"$nodes.tmp" || true
        cat "$nodes.tmp" >"$nodes"
        rm -f "$nodes.tmp"
        log "config_nodes: removed /dev/$DEVICE mapping"
    fi
    log "lxc.no_new_privs left as is"
}

cmd_status() {
    local rel f ok=1
    echo "install record: $OWNED"
    [[ -f $PENDING ]] && { echo "  WARNING: interrupted install left $PENDING; run: sudo $0 uninstall (or install again)"; ok=0; }
    if [[ -f $OWNED ]]; then
        while IFS= read -r rel; do
            f="$VENDOR/$rel"
            if [[ -e $f ]]; then
                printf '  %s %s\n' "$(stat -c '%a %U:%G' "$f")" "$rel"
            else
                printf '  MISSING %s\n' "$rel"
                ok=0
            fi
        done <"$OWNED"
    else
        echo "  not installed"
        ok=0
    fi
    if grep -qxF "$MAPPING" "$LXC_DIR/config_nodes" 2>/dev/null; then
        echo "config_nodes: /dev/$DEVICE mapped"
    else
        echo "config_nodes: /dev/$DEVICE NOT mapped (run: sudo $0 reapply)"
        ok=0
    fi
    echo "config: $(grep -E '^lxc\.no_new_privs' "$LXC_DIR/config" 2>/dev/null || echo 'lxc.no_new_privs unset')"
    if [[ -e /dev/$DEVICE ]]; then
        echo "host: /dev/$DEVICE -> $(readlink -f "/dev/$DEVICE") ($(stat -L -c '%a %U:%G' "/dev/$DEVICE"))"
    else
        echo "host: /dev/$DEVICE not present (receiver unplugged or udev rule missing)"
        ok=0
    fi
    if [[ $TEST != 1 && $EUID -eq 0 ]] && waydroid status 2>/dev/null | grep -q 'Container:[[:space:]]*RUNNING'; then
        echo "android: ro.kernel.android.gps=$(waydroid shell -- getprop ro.kernel.android.gps 2>/dev/null)"
        echo "android: /dev/$DEVICE $(waydroid shell -- ls -l "/dev/$DEVICE" 2>&1)"
    fi
    [[ $ok == 1 ]]
}

case "${1:-}" in
    install) cmd_install ;;
    uninstall) cmd_uninstall ;;
    reapply) cmd_reapply ;;
    status) cmd_status ;;
    *) sed -n '2,18s/^# \{0,1\}//p' "$0"; exit 2 ;;
esac
