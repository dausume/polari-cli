#!/bin/bash
# wipe-stick.sh — erase a Polari app stick (or prepare a blank one). Root only. Guarded: the target must be a
# REMOVABLE / USB drive, never the disk holding /, /boot, /home or swap; the device and size are named before
# anything happens, and nothing happens without --yes.
#   wipe-stick.sh <mountpoint|/dev/sdX> --yes [--fs vfat|ext4] [--label NAME] [--owner UID:GID]
#   wipe-stick.sh <mountpoint> --polari-only --yes      remove only what Polari put there (polari-apps/, autorun.sh)
# --fs ext4 makes a SELF-PROMPTING stick (Linux only: the desktop can run autorun.sh from ext4; FAT is mounted
# with showexec, so nothing on a FAT stick is executable and the prompt cannot start by itself).
set -u
TARGET=${1:?mountpoint or device}; shift
YES=0; FS=vfat; LABEL=""; ONLY=0; OWNER=""
while [ $# -gt 0 ]; do case "$1" in --yes) YES=1; shift ;; --fs) FS="$2"; shift 2 ;; --label) LABEL="$2"; shift 2 ;; --polari-only) ONLY=1; shift ;; --owner) OWNER="$2"; shift 2 ;; *) shift ;; esac; done
need_root() { [ "$(id -u)" = 0 ] || { echo "run as root (sudo) to do it"; exit 1; }; }
if [ "$ONLY" = 1 ]; then
    [ -d "$TARGET/polari-apps" ] || { echo "$TARGET carries no polari-apps/"; exit 1; }
    [ "$YES" = 1 ] || { echo "would remove $TARGET/polari-apps and $TARGET/autorun.sh (add --yes)"; exit 2; }
    need_root
    rm -rf "$TARGET/polari-apps" "$TARGET/autorun.sh" && sync && echo "removed Polari's files from $TARGET; the rest of the drive is untouched"; exit $?
fi
if [ -b "$TARGET" ]; then DEV=$TARGET; else DEV=$(findmnt -no SOURCE "$TARGET" 2>/dev/null); fi
[ -n "$DEV" ] && [ -b "$DEV" ] || { echo "$TARGET is not a mounted drive or a block device"; exit 1; }
DISK=/dev/$(lsblk -no PKNAME "$DEV" 2>/dev/null | head -1); [ "$DISK" = /dev/ ] && DISK=$DEV
RM=$(lsblk -dno RM "$DISK"); TRAN=$(lsblk -dno TRAN "$DISK"); SIZE=$(lsblk -dno SIZE "$DISK")
if [ "$RM" != 1 ] && [ "$TRAN" != usb ] && [ "${POLARI_WIPE_ALLOW_LOOP:-0}" != 1 ]; then
    echo "REFUSED: $DISK is not a removable/USB drive (RM=$RM TRAN=$TRAN) — a Polari wipe only ever touches a stick"; exit 3
fi
for mp in $(lsblk -no MOUNTPOINT "$DISK" 2>/dev/null); do
    case "$mp" in /|/boot|/boot/efi|/home|/var|/usr|"[SWAP]") echo "REFUSED: $DISK holds $mp — that is a system disk, not a stick"; exit 3 ;; esac
done
echo "target: $DISK ($SIZE, RM=$RM TRAN=${TRAN:-?}) — every partition on it will be erased and replaced by one $FS filesystem${LABEL:+ labelled $LABEL}"
[ "$YES" = 1 ] || { echo "nothing done (add --yes to erase it)"; exit 2; }
need_root
for mp in $(lsblk -no MOUNTPOINT "$DISK" 2>/dev/null); do umount "$mp" 2>/dev/null || udisksctl unmount -b "$(findmnt -no SOURCE "$mp")" >/dev/null 2>&1; done
wipefs -a "$DISK" >/dev/null || { echo "wipefs failed"; exit 1; }
case "$FS" in
    vfat) mkfs.vfat -I ${LABEL:+-n "$LABEL"} "$DISK" >/dev/null || { echo "mkfs.vfat failed"; exit 1; } ;;
    ext4) mkfs.ext4 -q -F ${LABEL:+-L "$LABEL"} "$DISK" || { echo "mkfs.ext4 failed"; exit 1; }
          if [ -n "$OWNER" ]; then t=$(mktemp -d); mount "$DISK" "$t" && chown "$OWNER" "$t" && umount "$t"; rmdir "$t"; fi ;;
    *) echo "--fs takes vfat or ext4"; exit 1 ;;
esac
sync; partprobe "$DISK" 2>/dev/null
echo "wiped: $DISK is now an empty $FS drive${LABEL:+ ($LABEL)}"
