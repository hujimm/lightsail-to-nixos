#!/usr/bin/env bash
#
# lightsail-to-nixos.sh — convert an AWS Lightsail Ubuntu/Debian instance to NixOS in place.
#
# It only does the parts nixos-infect cannot do for you:
#   1. read the real root / /boot / ESP partitions and generate a configuration.nix that
#      matches the actual firmware (nixos-infect's Lightsail preset installs BIOS GRUB,
#      which leaves a UEFI instance unbootable)
#   2. add a temporary swap file (a 512 MB instance peaks around 800 MB during evaluation)
#   3. call nixos-infect with NIX_CHANNEL=nixos-26.05 and verify what lustrate staged
#
# Usage (on the instance, as root):
#   sudo bash lightsail-to-nixos.sh --dry-run     # print the generated configs, change nothing
#   sudo bash lightsail-to-nixos.sh               # generate, inject, reboot
#   sudo bash lightsail-to-nixos.sh --no-reboot   # inject, then stop and let you check
#
# Clean up the leftovers once the machine boots NixOS:
#   sudo bash lightsail-to-nixos.sh --cleanup
#
# Requirements: Ubuntu / Debian cloud image, x86_64, UEFI or BIOS, and a partition layout of
# "root + separate /boot + ESP", "root + ESP" or "root + bios_grub + ESP". This is not a
# general-purpose installer; if your layout does not match, do it by hand.
#
# Output language follows LANG (en/zh) or --lang. Comments and the generated Nix files are
# English on purpose, so the same file does not mix two languages.
#
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Localisation
# ─────────────────────────────────────────────────────────────
UI_LANG="${UI_LANG:-}"
if [[ -z $UI_LANG ]]; then
  case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
    zh*) UI_LANG=zh ;;
    *) UI_LANG=en ;;
  esac
fi

t() {
  local key="$1"; shift
  local fmt=""
  case "$UI_LANG:$key" in
    zh:err_prefix)          fmt='错误:' ;;
    en:err_prefix)          fmt='error:' ;;
    zh:usage_desc)          fmt='把 AWS Lightsail 的 Ubuntu / Debian 就地转成 NixOS。' ;;
    en:usage_desc)          fmt='Convert an AWS Lightsail Ubuntu/Debian instance to NixOS in place.' ;;
    zh:usage_sections)      fmt='用法 / 选项：' ;;
    en:usage_sections)      fmt='Usage / options:' ;;
    zh:opt_channel)         fmt='  --channel <名字>     nixpkgs channel，默认 nixos-26.05（必须自带 bash 版 stage-1）' ;;
    en:opt_channel)         fmt='  --channel <name>    nixpkgs channel, default nixos-26.05 (must ship the bash stage 1)' ;;
    zh:opt_hostname)        fmt='  --hostname <名字>    networking.hostName，默认 lightsail' ;;
    en:opt_hostname)        fmt='  --hostname <name>   networking.hostName, default "lightsail"' ;;
    zh:opt_swap_gb)         fmt='  --swap-gb <数字>     临时 swap 大小，默认 <1 GB 内存用 4，其余用 2' ;;
    en:opt_swap_gb)         fmt='  --swap-gb <n>       temporary swap size in GB; default 4 below 1 GB RAM, else 2' ;;
    zh:opt_pubkey)          fmt='  --pubkey <文件>      从指定文件读公钥（默认扫 /root 与 /home/* 的 authorized_keys）' ;;
    en:opt_pubkey)          fmt='  --pubkey <file>     read keys from this file (default: /root and /home/* authorized_keys)' ;;
    zh:opt_no_swap)         fmt='  --no-swap           不加 swap（nixos-infect 会自己造 1 GB 的 /tmp swap）' ;;
    en:opt_no_swap)         fmt='  --no-swap           no swap at all (nixos-infect makes its own 1 GB /tmp swap)' ;;
    zh:opt_no_reboot)       fmt='  --no-reboot         注入后不自动重启' ;;
    en:opt_no_reboot)       fmt='  --no-reboot         stop after the checks instead of rebooting' ;;
    zh:opt_yes)             fmt='  --yes               跳过确认' ;;
    en:opt_yes)             fmt='  --yes               do not ask for confirmation' ;;
    zh:opt_dry_run)         fmt='  --dry-run           只打印配置，不动系统' ;;
    en:opt_dry_run)         fmt='  --dry-run           print the configs and exit' ;;
    zh:opt_cleanup)         fmt='  --cleanup           转换成 NixOS 之后清理 /old-root 与旧 generation' ;;
    en:opt_cleanup)         fmt='  --cleanup           remove /old-root and old generations (run on NixOS)' ;;
    zh:opt_keep_config)     fmt='  --keep-config       --cleanup 时保留 /etc/nixos 下的文件' ;;
    en:opt_keep_config)     fmt='  --keep-config       keep /etc/nixos files during --cleanup' ;;
    zh:opt_force)           fmt='  --force             已有 /etc/NIXOS_LUSTRATE 时仍然重新注入' ;;
    en:opt_force)           fmt='  --force             inject again even if /etc/NIXOS_LUSTRATE exists' ;;
    zh:opt_lang)            fmt='  --lang <en|zh>      输出语言（默认跟随 LANG）' ;;
    en:opt_lang)            fmt='  --lang <en|zh>      message language (default: derived from LANG)' ;;
    zh:opt_help)            fmt='  -h, --help          显示这段帮助' ;;
    en:opt_help)            fmt='  -h, --help          show this help' ;;
    zh:unknown_arg)         fmt='未知参数: %s（--help 查看用法）' ;;
    en:unknown_arg)         fmt='unknown argument: %s (see --help)' ;;
    zh:need_root)           fmt='需要 root：sudo bash %s' ;;
    en:need_root)           fmt='root required: sudo bash %s' ;;
    zh:not_nixos)           fmt='当前不是 NixOS，--cleanup 只能在转换成功后执行' ;;
    en:not_nixos)           fmt='this is not NixOS; --cleanup only works after a successful conversion' ;;
    zh:cleanup_before)      fmt='清理前' ;;
    en:cleanup_before)      fmt='before cleanup' ;;
    zh:cleanup_rm_oldroot)  fmt='删除 /old-root（旧系统的整棵根）' ;;
    en:cleanup_rm_oldroot)  fmt='removing /old-root (the entire old root filesystem)' ;;
    zh:cleanup_gc)          fmt='删除旧 system generation 并回收 store' ;;
    en:cleanup_gc)          fmt='removing old system generations and collecting garbage' ;;
    zh:cleanup_rm_cfg)      fmt='删除注入用的 /etc/nixos/configuration.nix' ;;
    en:cleanup_rm_cfg)      fmt='removing the injection config /etc/nixos/configuration.nix' ;;
    zh:cleanup_after)       fmt='清理后' ;;
    en:cleanup_after)       fmt='after cleanup' ;;
    zh:lustrate_left)       fmt='注意: /etc/NIXOS_LUSTRATE 仍在，下次启动会再 lustrate 一次' ;;
    en:lustrate_left)       fmt='note: /etc/NIXOS_LUSTRATE is still present; the next boot will lustrate again' ;;
    zh:hardware_kept)       fmt='硬件描述留在这里，取回去当 flake 的 hosts/<名字>/hardware.nix：' ;;
    en:hardware_kept)       fmt='hardware description kept here; copy it out as hosts/<name>/hardware.nix:' ;;
    zh:hardware_scp)        fmt='  scp root@<IP>:%s ./hosts/<名字>/hardware.nix' ;;
    en:hardware_scp)        fmt='  scp root@<IP>:%s ./hosts/<name>/hardware.nix' ;;
    zh:cleanup_done)        fmt='完成。接下来在本机用 flake 接管：nixos-rebuild switch --flake .#<host> --target-host root@<IP>' ;;
    en:cleanup_done)        fmt='done. Take the machine over from your flake: nixos-rebuild switch --flake .#<host> --target-host root@<IP>' ;;
    zh:arch)                fmt='只覆盖 x86_64 实例（当前 %s）' ;;
    en:arch)                fmt='only x86_64 instances are supported (this is %s)' ;;
    zh:distro_note)         fmt='注意: 当前系统是 %s，不是 Ubuntu/Debian；脚本按 apt 系云镜像验证过，继续前自行确认' ;;
    en:distro_note)         fmt='note: this is %s, not Ubuntu/Debian; the script was verified on apt-based cloud images, continue at your own risk' ;;
    zh:no_root_mount)       fmt='读不到根分区' ;;
    en:no_root_mount)       fmt='cannot read the root mount' ;;
    zh:root_no_uuid)        fmt='根分区 %s 没有 UUID' ;;
    en:root_no_uuid)        fmt='root partition %s has no UUID' ;;
    zh:root_fs)             fmt='根分区是 %s，脚本只生成 ext4 的配置；请手工写 configuration.nix' ;;
    en:root_fs)             fmt='root filesystem is %s; the script only generates ext4 configs, write configuration.nix by hand' ;;
    zh:root_lvm)            fmt='根分区在 LVM 上（%s），initrd 需要 lvm 模块，脚本不生成；请手工写' ;;
    en:root_lvm)            fmt='root filesystem is on LVM (%s); the initrd needs the lvm module, which the script does not generate. Write it by hand' ;;
    zh:no_disk)             fmt='推不出根分区所在的整块盘（lsblk PKNAME 为空）' ;;
    en:no_disk)             fmt='cannot determine the disk holding the root partition (lsblk PKNAME is empty)' ;;
    zh:no_esp)              fmt='找不到 ESP（/boot/efi、/boot/EFI 或 vfat 的 /boot）' ;;
    en:no_esp)              fmt='no ESP found (/boot/efi, /boot/EFI or a vfat /boot)' ;;
    zh:esp_no_uuid)         fmt='ESP 没有 UUID' ;;
    en:esp_no_uuid)         fmt='the ESP has no UUID' ;;
    zh:boot_no_uuid)        fmt='/boot 没有 UUID' ;;
    en:boot_no_uuid)        fmt='/boot has no UUID' ;;
    zh:pubkey_unreadable)   fmt='读不到公钥文件 %s' ;;
    en:pubkey_unreadable)   fmt='cannot read public key file %s' ;;
    zh:pubkey_empty)        fmt='%s 里没有 SSH 公钥' ;;
    en:pubkey_empty)        fmt='no SSH public key in %s' ;;
    zh:no_keys)             fmt='找不到任何 SSH 公钥（/root 或 /home/*/.ssh/authorized_keys）。没有公钥会把自己锁在门外' ;;
    en:no_keys)             fmt='no SSH public key found (/root or /home/*/.ssh/authorized_keys). Without one you would lock yourself out' ;;
    zh:disk_low)            fmt='根分区只剩 %s GB。至少留 8 GB：旧根要挪进 /old-root，新系统闭包也在同一文件系统上' ;;
    en:disk_low)            fmt='only %s GB free on the root filesystem. At least 8 GB is required: the old root moves into /old-root and the new closure lands on the same filesystem' ;;
    zh:disk_free)           fmt='根分区可用 %s GB' ;;
    en:disk_free)           fmt='root filesystem has %s GB free' ;;
    zh:swap_skipped)        fmt='按要求不加 swap' ;;
    en:swap_skipped)        fmt='not adding swap, as requested' ;;
    zh:swap_existing)       fmt='已有 swap 在用，跳过创建：' ;;
    en:swap_existing)       fmt='swap already in use, skipping creation:' ;;
    zh:swap_creating)       fmt='内存 %s MB，创建 %s GB 临时 swap 到 /swapfile' ;;
    en:swap_creating)       fmt='%s MB of RAM, creating %s GB of temporary swap at /swapfile' ;;
    zh:channel_unreachable) fmt='注意: 拉不到 %s 的 stage-1-init.sh，跳过 channel 检查（离线或代理问题）' ;;
    en:channel_unreachable) fmt='warning: cannot fetch stage-1-init.sh for %s, skipping the channel check (offline or proxy issue)' ;;
    zh:channel_bad)         fmt='%s 没有 bash 版 stage-1（lustrateRoot），nixos-infect 无法完成转换。用 --channel nixos-26.05' ;;
    en:channel_bad)         fmt='%s does not ship the bash stage 1 (lustrateRoot); nixos-infect cannot complete. Use --channel nixos-26.05' ;;
    zh:channel_ok)          fmt='channel %s 带 lustrateRoot，OK' ;;
    en:channel_ok)          fmt='channel %s ships lustrateRoot, OK' ;;
    zh:backup)              fmt='已有文件备份到 %s' ;;
    en:backup)              fmt='existing file backed up to %s' ;;
    zh:wrote_config)        fmt='写入 %s（注入用）' ;;
    en:wrote_config)        fmt='wrote %s (used for the injection)' ;;
    zh:wrote_hardware)      fmt='写入 %s（交给 flake 用，--cleanup 不会删）' ;;
    en:wrote_hardware)      fmt='wrote %s (for your flake; --cleanup keeps it)' ;;
    zh:verify_title)        fmt='重启前核对' ;;
    en:verify_title)        fmt='pre-reboot checks' ;;
    zh:ok_nixos_file)       fmt='/etc/NIXOS 存在' ;;
    en:ok_nixos_file)       fmt='/etc/NIXOS exists' ;;
    zh:bad_nixos_file)      fmt='/etc/NIXOS 不存在：注入没走到最后' ;;
    en:bad_nixos_file)      fmt='/etc/NIXOS is missing: the injection did not reach the end' ;;
    zh:ok_lustrate)         fmt='/etc/NIXOS_LUSTRATE 已就位' ;;
    en:ok_lustrate)         fmt='/etc/NIXOS_LUSTRATE is staged' ;;
    zh:bad_lustrate)        fmt='/etc/NIXOS_LUSTRATE 缺失或不含 etc/nixos' ;;
    en:bad_lustrate)        fmt='/etc/NIXOS_LUSTRATE is missing or does not list etc/nixos' ;;
    zh:ok_label)            fmt='根分区 label = nixos' ;;
    en:ok_label)            fmt='root partition label is nixos' ;;
    zh:bad_label)           fmt='根分区 label 是 "%s"，不是 nixos' ;;
    en:bad_label)           fmt='root partition label is "%s", not nixos' ;;
    zh:ok_efi)              fmt='ESP 里有 EFI 程序：' ;;
    en:ok_efi)              fmt='ESP contains an EFI binary:' ;;
    zh:bad_efi)             fmt='ESP 里没有 .efi 文件' ;;
    en:bad_efi)             fmt='no .efi file on the ESP' ;;
    zh:ok_grub)             fmt='/boot/grub/grub.cfg 指向 NixOS：' ;;
    en:ok_grub)             fmt='/boot/grub/grub.cfg points at NixOS:' ;;
    zh:bad_grub)            fmt='/boot/grub/grub.cfg 缺失或不含 nixos-system' ;;
    en:bad_grub)            fmt='/boot/grub/grub.cfg is missing or does not mention nixos-system' ;;
    zh:verify_failed)       fmt='核对未通过，不要重启。日志：%s' ;;
    en:verify_failed)       fmt='checks failed, do not reboot. Log: %s' ;;
    zh:verify_ok)           fmt='全部通过。' ;;
    en:verify_ok)           fmt='all checks passed.' ;;
    zh:probe_title)         fmt='探测结果' ;;
    en:probe_title)         fmt='detected layout' ;;
    zh:probe_root)          fmt='根分区   %s  %s  UUID=%s' ;;
    en:probe_root)          fmt='root       %s  %s  UUID=%s' ;;
    zh:probe_boot)          fmt='/boot      UUID=%s  %s' ;;
    en:probe_boot)          fmt='/boot      UUID=%s  %s' ;;
    zh:probe_esp)           fmt='ESP        %s  UUID=%s' ;;
    en:probe_esp)           fmt='ESP        %s  UUID=%s' ;;
    zh:probe_bios)          fmt='启动模式 BIOS，GRUB 装到 %s' ;;
    en:probe_bios)          fmt='firmware   BIOS, GRUB goes to %s' ;;
    zh:probe_channel)       fmt='channel    %s' ;;
    en:probe_channel)       fmt='channel    %s' ;;
    zh:probe_keys)          fmt='公钥       %d 条' ;;
    en:probe_keys)          fmt='keys       %d' ;;
    zh:preview1)            fmt='配置预览 1/2：/etc/nixos/configuration.nix（注入用）' ;;
    en:preview1)            fmt='preview 1/2: /etc/nixos/configuration.nix (injection)' ;;
    zh:preview2)            fmt='配置预览 2/2：/etc/nixos/hardware.nix（给 flake 的 hosts/<名字>/hardware.nix）' ;;
    en:preview2)            fmt='preview 2/2: /etc/nixos/hardware.nix (for hosts/<name>/hardware.nix)' ;;
    zh:already_nixos)       fmt='这台已经是 NixOS（%s）。要清理残留请用 --cleanup' ;;
    en:already_nixos)       fmt='this machine already runs NixOS (%s). Use --cleanup to remove leftovers' ;;
    zh:script_placed)       fmt='脚本已放到 /etc/nixos/lightsail-to-nixos.sh（重启后还在）' ;;
    en:script_placed)       fmt='script copied to /etc/nixos/lightsail-to-nixos.sh (survives the reboot)' ;;
    zh:resume)              fmt='检测到 /etc/NIXOS_LUSTRATE：这台机器已经注入过，跳过注入，只做核对' ;;
    en:resume)              fmt='found /etc/NIXOS_LUSTRATE: this machine was already injected, skipping the injection and only running the checks' ;;
    zh:resume_force)        fmt='（要强制重新注入请加 --force）' ;;
    en:resume_force)        fmt='(use --force to inject again)' ;;
    zh:need_yes)            fmt='非交互环境请加 --yes' ;;
    en:need_yes)            fmt='non-interactive shell, add --yes' ;;
    zh:confirm)             fmt='即将注入。这会安装 Nix、构建新系统并改写引导；确认无误后回车' ;;
    en:confirm)             fmt='about to inject. This installs Nix, builds the new system and rewrites the boot loader' ;;
    zh:confirm_prompt)      fmt='回车继续，Ctrl-C 退出: ' ;;
    en:confirm_prompt)      fmt='press Enter to continue, Ctrl-C to abort: ' ;;
    zh:downloading)         fmt='下载 nixos-infect' ;;
    en:downloading)         fmt='downloading nixos-infect' ;;
    zh:not_infect)          fmt='下载到的脚本不像 nixos-infect' ;;
    en:not_infect)          fmt='the downloaded script does not look like nixos-infect' ;;
    zh:injecting)           fmt='注入（日志同时写入 %s）' ;;
    en:injecting)           fmt='injecting (log also written to %s)' ;;
    zh:infect_failed)       fmt='nixos-infect 退出码 %s，见 %s' ;;
    en:infect_failed)       fmt='nixos-infect exited with %s, see %s' ;;
    zh:uuids_title)         fmt='本机可直接用于 flake 的文件系统片段' ;;
    en:uuids_title)         fmt='filesystem UUIDs for your flake' ;;
    zh:uuid_root)           fmt='    root uuid  %s' ;;
    en:uuid_root)           fmt='    root uuid  %s' ;;
    zh:uuid_boot)           fmt='    boot uuid  %s' ;;
    en:uuid_boot)           fmt='    boot uuid  %s' ;;
    zh:uuid_esp)            fmt='    esp  uuid  %s' ;;
    en:uuid_esp)            fmt='    esp  uuid  %s' ;;
    zh:uuid_none)           fmt='无' ;;
    en:uuid_none)           fmt='none' ;;
    zh:hardware_hint)       fmt='重启后完整的一份在 /etc/nixos/hardware.nix（清理时不会删）' ;;
    en:hardware_hint)       fmt='a complete copy is at /etc/nixos/hardware.nix (--cleanup keeps it)' ;;
    zh:no_reboot_done)      fmt='按要求不重启。确认后执行： sudo systemctl reboot' ;;
    en:no_reboot_done)      fmt='not rebooting, as requested. When ready: sudo systemctl reboot' ;;
    zh:no_reboot_next)      fmt='重启后： ssh root@<IP>，然后 /etc/nixos/lightsail-to-nixos.sh --cleanup' ;;
    en:no_reboot_next)      fmt='after the reboot: ssh root@<IP>, then /etc/nixos/lightsail-to-nixos.sh --cleanup' ;;
    zh:reboot_soon)         fmt='10 秒后重启（Ctrl-C 取消）' ;;
    en:reboot_soon)         fmt='rebooting in 10 seconds (Ctrl-C to cancel)' ;;
    *)                      fmt="[missing message: $key]" ;;
  esac
  printf "$fmt" "$@"
}

# ─────────────────────────────────────────────────────────────
# Options
# ─────────────────────────────────────────────────────────────
CHANNEL="${CHANNEL:-nixos-26.05}"
HOST_NAME="lightsail"
TEMP_SWAP_GB=""
FINAL_SWAP_MB=2048
USE_SWAP=1
DO_REBOOT=1
DRY_RUN=0
CLEANUP=0
ASSUME_YES=0
KEEP_CONFIG=0
FORCE=0
PUBKEY_FILE=""
LANG_FROM_FLAG=0

CONFIG_PATH=/etc/nixos/configuration.nix
HARDWARE_PATH=/etc/nixos/hardware.nix
LOG=/var/log/lightsail-to-nixos.log
INFECT_URL=https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect

die() { printf '\n%s %s\n' "$(t err_prefix)" "$*" >&2; exit 1; }
note() { printf '\n=== %s\n' "$*"; }

usage() {
  t usage_desc; printf '\n\n'
  t usage_sections; printf '\n'
  local k
  for k in opt_channel opt_hostname opt_swap_gb opt_pubkey opt_no_swap opt_no_reboot \
           opt_yes opt_dry_run opt_cleanup opt_keep_config opt_force opt_lang opt_help; do
    t "$k"; printf '\n'
  done
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)     CHANNEL="$2"; shift 2 ;;
    --hostname)    HOST_NAME="$2"; shift 2 ;;
    --swap-gb)     TEMP_SWAP_GB="$2"; shift 2 ;;
    --no-swap)     USE_SWAP=0; shift ;;
    --no-reboot)   DO_REBOOT=0; shift ;;
    --yes)         ASSUME_YES=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --cleanup)     CLEANUP=1; shift ;;
    --keep-config) KEEP_CONFIG=1; shift ;;
    --force)       FORCE=1; shift ;;
    --pubkey)      PUBKEY_FILE="$2"; shift 2 ;;
    --lang)        UI_LANG="$2"; LANG_FROM_FLAG=1; shift 2 ;;
    -h|--help)     usage ;;
    *)             die "$(t unknown_arg "$1")" ;;
  esac
done

case "$UI_LANG" in
  en|zh) ;;
  *)
    if [[ $LANG_FROM_FLAG -eq 1 ]]; then
      printf '\nerror: unsupported language: %s (en, zh)\n' "$UI_LANG" >&2
      exit 1
    fi
    UI_LANG=en
    ;;
esac

need_root() {
  [[ ${EUID:-0} -eq 0 ]] || die "$(t need_root "$0")"
}

# ─────────────────────────────────────────────────────────────
# --cleanup: run on NixOS after a successful conversion
# ─────────────────────────────────────────────────────────────
do_cleanup() {
  need_root
  [[ -e /run/current-system ]] || die "$(t not_nixos)"

  note "$(t cleanup_before)"
  df -h / | tail -1

  if [[ -d /old-root ]]; then
    note "$(t cleanup_rm_oldroot)"
    rm -rf /old-root
  fi

  note "$(t cleanup_gc)"
  nix-env --delete-generations old --profile /nix/var/nix/profiles/system || true
  nix-collect-garbage -d || true

  rm -f /etc/NIXOS

  if [[ $KEEP_CONFIG -eq 0 ]]; then
    note "$(t cleanup_rm_cfg)"
    rm -f /etc/nixos/configuration.nix /etc/nixos/hardware-configuration.nix
  fi

  note "$(t cleanup_after)"
  df -h / | tail -1
  rm -f /etc/nixos/lightsail-to-nixos.sh
  [[ -e /etc/NIXOS_LUSTRATE ]] && printf '%s\n' "$(t lustrate_left)" >&2

  if [[ -f $HARDWARE_PATH ]]; then
    printf '\n%s\n' "$(t hardware_kept)"
    printf '%s\n\n' "$(t hardware_scp "$HARDWARE_PATH")"
    sed 's/^/  | /' "$HARDWARE_PATH"
  fi

  printf '\n%s\n' "$(t cleanup_done)"
}

# ─────────────────────────────────────────────────────────────
# Platform and filesystem discovery
# ─────────────────────────────────────────────────────────────
ROOT_SRC=""; ROOT_UUID=""; ROOT_FS=""
BOOT_MODE=""; GRUB_DEV=""
BOOT_UUID=""; BOOT_FS=""
ESP_MNT=""; ESP_UUID=""
TMP_SWAP_ACTIVE=0
KEYS=()
PROBE_USER=""

detect_platform() {
  [[ "$(uname -m)" = "x86_64" ]] || die "$(t arch "$(uname -m)")"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" = "ubuntu" ]] || [[ "${ID:-}" = "debian" ]] \
      || printf '%s\n' "$(t distro_note "${PRETTY_NAME:-unknown}")"
  fi

  # Lightsail's Ubuntu images boot UEFI, Debian images boot BIOS; cover both
  if [[ -d /sys/firmware/efi ]]; then
    BOOT_MODE=uefi
  else
    BOOT_MODE=bios
  fi

  ROOT_SRC=$(findmnt -no SOURCE /) || die "$(t no_root_mount)"
  ROOT_SRC=${ROOT_SRC%%\[*}   # btrfs subvolumes come as /dev/x[/@]
  ROOT_FS=$(findmnt -no FSTYPE /)
  ROOT_UUID=$(lsblk -no UUID "$ROOT_SRC" | tr -d " ") || die "$(t root_no_uuid "$ROOT_SRC")"

  # Only ext4 directly on a partition. LVM, btrfs and encrypted roots need extra initrd
  # modules and mount options that this script does not generate: stop instead of writing
  # a config that will not boot.
  [[ $ROOT_FS = "ext4" ]] || die "$(t root_fs "$ROOT_FS")"
  [[ $ROOT_SRC != /dev/mapper/* ]] || die "$(t root_lvm "$ROOT_SRC")"

  # BIOS installs GRUB on the whole disk (MBR + bios_grub partition)
  if [[ $BOOT_MODE = bios ]]; then
    local disk
    disk=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1)
    [[ -n $disk ]] || die "$(t no_disk)"
    GRUB_DEV="/dev/$disk"
  fi

  # ESP: Ubuntu cloud images mount it at /boot/efi; without a separate /boot it may be /boot
  if [[ $BOOT_MODE = uefi ]]; then
    local d
    for d in /boot/efi /boot/EFI; do
      if findmnt -no TARGET "$d" >/dev/null 2>&1; then ESP_MNT="$d"; break; fi
    done
    if [[ -z $ESP_MNT ]] && [[ "$(findmnt -no FSTYPE /boot 2>/dev/null || true)" = "vfat" ]]; then
      ESP_MNT=/boot
    fi
    [[ -n $ESP_MNT ]] || die "$(t no_esp)"
    ESP_UUID=$(lsblk -no UUID "$(findmnt -no SOURCE "$ESP_MNT")" | tr -d " ") || die "$(t esp_no_uuid)"
  fi

  # Separate /boot (Ubuntu cloud images have a 913 MB ext4 one)
  local boot_src boot_mp
  boot_src=$(findmnt -no SOURCE /boot 2>/dev/null || true)
  boot_mp=$(findmnt -no TARGET /boot 2>/dev/null || true)
  if [[ -n $boot_src && $boot_mp = /boot && $boot_src != "$ROOT_SRC" && $boot_src != "${ESP_MNT:+$(findmnt -no SOURCE "$ESP_MNT")}" ]]; then
    BOOT_UUID=$(lsblk -no UUID "$boot_src" | tr -d " ") || die "$(t boot_no_uuid)"
    BOOT_FS=$(findmnt -no FSTYPE /boot)
  fi
}

collect_keys() {
  local f
  local -a found=()
  if [[ -n $PUBKEY_FILE ]]; then
    [[ -r $PUBKEY_FILE ]] || die "$(t pubkey_unreadable "$PUBKEY_FILE")"
    mapfile -t found < <(grep -E '^(ssh-(rsa|ed25519)|ecdsa-|sk-ssh-|sk-ecdsa-)' "$PUBKEY_FILE" || true)
    [[ ${#found[@]} -gt 0 ]] || die "$(t pubkey_empty "$PUBKEY_FILE")"
    KEYS=("${found[@]}")
    return 0
  fi
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -r $f ]] || continue
    while IFS= read -r line; do
      [[ -n $line ]] && found+=("$line")
    done < <(grep -E '^(ssh-(rsa|ed25519)|ecdsa-|sk-ssh-|sk-ecdsa-)' "$f" || true)
  done
  if [[ ${#found[@]} -gt 0 ]]; then
    mapfile -t KEYS < <(printf '%s\n' "${found[@]}" | sort -u)
  fi
  [[ ${#KEYS[@]} -gt 0 ]] || die "$(t no_keys)"

  # Default cloud user (used by the console's "Connect using SSH"): ubuntu, admin, debian
  local u
  for u in ubuntu admin debian; do
    if [[ -f /home/$u/.ssh/authorized_keys ]]; then PROBE_USER=$u; break; fi
  done
}

check_disk() {
  # The old root moves into /old-root, and the new closure lands on the same filesystem
  local free_gb
  free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  if [[ ${free_gb:-0} -lt 8 ]]; then
    die "$(t disk_low "${free_gb:-0}")"
  fi
  printf '%s\n' "$(t disk_free "$free_gb")"
}

setup_swap() {
  [[ $USE_SWAP -eq 1 ]] || { printf '%s\n' "$(t swap_skipped)"; return 0; }

  if [[ -n "$(swapon --show=NAME --noheadings 2>/dev/null)" ]]; then
    printf '%s\n' "$(t swap_existing)"
    swapon --show
    TMP_SWAP_ACTIVE=1
    return 0
  fi

  local mem_mb gb
  mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  gb="${TEMP_SWAP_GB:-$([[ $mem_mb -lt 1024 ]] && echo 4 || echo 2)}"
  note "$(t swap_creating "$mem_mb" "$gb")"

  fallocate -l "${gb}G" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  TMP_SWAP_ACTIVE=1
  swapon --show
}

# ─────────────────────────────────────────────────────────────
# Generated Nix files
# ─────────────────────────────────────────────────────────────
gen_hardware_body() {
  # Argument 1 = 1 inserts the "disable systemd-initrd" line, which only the injection
  # config needs (and which no longer exists from 26.11 on).
  local with_toggle="$1"

  if [[ $BOOT_MODE = uefi ]]; then
    cat <<EOF
  # UEFI, installed to the removable fallback path EFI/BOOT/BOOTX64.EFI
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev";
  };
  boot.loader.efi.efiSysMountPoint = "${ESP_MNT}";

EOF
  else
    cat <<EOF
  # BIOS: GRUB goes to the disk's MBR, core.img into the bios_grub partition
  boot.loader.grub = {
    enable = true;
    device = "${GRUB_DEV}";
  };

EOF
  fi

  if [[ $with_toggle -eq 1 ]]; then
    cat <<EOF
  # lustrate (moving the old system into /old-root) only exists in the bash stage 1;
  # under systemd-initrd the old /etc and /usr stay in place.
  boot.initrd.systemd.enable = false;

EOF
  fi

  cat <<EOF
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/${ROOT_UUID}";
    fsType = "${ROOT_FS}";
  };
EOF

  if [[ -n $BOOT_UUID ]]; then
    cat <<EOF
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/${BOOT_UUID}";
    fsType = "${BOOT_FS}";
  };
EOF
  fi

  if [[ $BOOT_MODE = uefi ]]; then
    cat <<EOF
  fileSystems."${ESP_MNT}" = {
    device = "/dev/disk/by-uuid/${ESP_UUID}";
    fsType = "vfat";
    options = [ "fmask=0022" "dmask=0022" ];
  };
EOF
  fi

  printf '\n'
  cat <<EOF
  boot.initrd.availableKernelModules = [
    "nvme"
    "ena"
    "virtio_pci"
    "virtio_blk"
    "sd_mod"
    "uas"
  ];
  boot.initrd.kernelModules = [ "nvme" ];
  # the first three values are copied from amazon-image.nix
  boot.kernelParams = [
    "nvme_core.io_timeout=4294967295"
    "random.trust_cpu=on"
    "console=ttyS0,115200n8"
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
EOF
}

# Injection config: adds the systemd-initrd toggle, SSH, users, swap and GC
gen_config() {
  local state_version="${CHANNEL#nixos-}"
  local key_lines
  key_lines=$(printf '%s\n' "${KEYS[@]}" | awk '{printf "    \"%s\"\n", $0}')

  cat <<EOF
# Generated by lightsail-to-nixos.sh; only used for the first nixos-infect run.
# --cleanup removes this file once the machine runs NixOS.
#
# Why not nixos-infect's Lightsail preset: it imports amazon-image.nix, whose ec2.efi
# defaults to isAarch64, so x86_64 gets BIOS GRUB - a UEFI instance will not boot.
{ lib, ... }:

{
EOF

  gen_hardware_body 1

  cat <<EOF

  networking.hostName = "${HOST_NAME}";
  networking.useDHCP = lib.mkDefault true;

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
${key_lines}
  ];
EOF

  # Default cloud user, used by the Lightsail console's "Connect using SSH"
  if [[ -n $PROBE_USER ]]; then
    cat <<EOF

  # the console logs in as ${PROBE_USER}; keep that user as a health probe
  users.users.${PROBE_USER} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
$(sed 's/^/  /' <<<"$key_lines")
    ];
  };
EOF
  fi

  if [[ $USE_SWAP -eq 1 ]]; then
    cat <<EOF

  # the converted system needs its own swap (the temporary /swapfile moves into /old-root)
  swapDevices = [
    {
      device = "/var/swapfile";
      size = ${FINAL_SWAP_MB};
    }
  ];
EOF
  fi

  cat <<EOF

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "@wheel" ];
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  system.stateVersion = "${state_version}";
}
EOF
}

# Hardware description for your flake, usable as hosts/<name>/hardware.nix as-is.
# No SSH, users, swap, GC or stateVersion: those belong to your own host config.
gen_hardware() {
  cat <<EOF
# Read off the instance by lightsail-to-nixos.sh; drop it in as hosts/<name>/hardware.nix.
# Disks are referenced by UUID; nixos-infect relabels the root partition to "nixos",
# the UUID stays the same.
{ lib, ... }:

{
EOF

  gen_hardware_body 0

  cat <<EOF
}
EOF
}

# ─────────────────────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────────────────────
check_channel() {
  local url="https://raw.githubusercontent.com/NixOS/nixpkgs/${CHANNEL}/nixos/modules/system/boot/stage-1-init.sh"
  local body
  if ! body=$(curl -fsSL --max-time 20 "$url" 2>/dev/null); then
    printf '%s\n' "$(t channel_unreachable "$CHANNEL")" >&2
    return 0
  fi
  if ! grep -q 'lustrateRoot' <<<"$body"; then
    die "$(t channel_bad "$CHANNEL")"
  fi
  printf '%s\n' "$(t channel_ok "$CHANNEL")"
}

write_config() {
  mkdir -p /etc/nixos
  local f bak
  for f in "$CONFIG_PATH" "$HARDWARE_PATH"; do
    if [[ -f $f ]]; then
      bak="${f}.bak.$(date +%Y%m%d%H%M%S)"
      mv "$f" "$bak"
      printf '%s\n' "$(t backup "$bak")"
    fi
  done
  gen_config > "$CONFIG_PATH"
  gen_hardware > "$HARDWARE_PATH"
  chmod 600 "$CONFIG_PATH" "$HARDWARE_PATH"
  printf '%s\n' "$(t wrote_config "$CONFIG_PATH")"
  printf '%s\n' "$(t wrote_hardware "$HARDWARE_PATH")"
}

verify_before_reboot() {
  local ok=1
  note "$(t verify_title)"

  if [[ -f /etc/NIXOS ]]; then
    printf '[ok] %s\n' "$(t ok_nixos_file)"
  else
    printf '[!!] %s\n' "$(t bad_nixos_file)" >&2; ok=0
  fi

  if [[ -f /etc/NIXOS_LUSTRATE ]] && grep -qx 'etc/nixos' /etc/NIXOS_LUSTRATE; then
    printf '[ok] %s\n' "$(t ok_lustrate)"
  else
    printf '[!!] %s\n' "$(t bad_lustrate)" >&2; ok=0
  fi

  local label
  # Read the superblock directly: udev may still report the old label right after e2label
  label=$(e2label "$ROOT_SRC" 2>/dev/null || true)
  if [[ $label = "nixos" ]]; then
    printf '[ok] %s\n' "$(t ok_label)"
  else
    printf '[!!] %s\n' "$(t bad_label "$label")" >&2; ok=0
  fi

  if [[ $BOOT_MODE = uefi ]]; then
    if find "$ESP_MNT" -iname '*.efi' -print -quit | grep -q .; then
      printf '[ok] %s\n' "$(t ok_efi)"
      find "$ESP_MNT" -iname '*.efi' | head -5 | sed 's/^/     /'
    else
      printf '[!!] %s\n' "$(t bad_efi)" >&2; ok=0
    fi
  else
    if [[ -s /boot/grub/grub.cfg ]] && grep -q 'nixos-system' /boot/grub/grub.cfg; then
      printf '[ok] %s\n' "$(t ok_grub)"
      grep -m1 'nixos-system' /boot/grub/grub.cfg | sed 's/^/     /'
    else
      printf '[!!] %s\n' "$(t bad_grub)" >&2; ok=0
    fi
  fi

  [[ $ok -eq 1 ]] || die "$(t verify_failed "$LOG")"
  printf '\n%s\n' "$(t verify_ok)"
}

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────
main() {
  if [[ $CLEANUP -eq 1 ]]; then do_cleanup; return; fi

  if [[ $DRY_RUN -eq 0 ]]; then need_root; fi

  detect_platform
  collect_keys

  note "$(t probe_title)"
  printf '%s\n' "$(t probe_root "$ROOT_SRC" "$ROOT_FS" "$ROOT_UUID")"
  [[ -n $BOOT_UUID ]] && printf '%s\n' "$(t probe_boot "$BOOT_UUID" "$BOOT_FS")"
  if [[ $BOOT_MODE = uefi ]]; then
    printf '%s\n' "$(t probe_esp "$ESP_MNT" "$ESP_UUID")"
  else
    printf '%s\n' "$(t probe_bios "$GRUB_DEV")"
  fi
  printf '%s\n' "$(t probe_channel "$CHANNEL")"
  printf '%s\n' "$(t probe_keys "${#KEYS[@]}")"

  if [[ $DRY_RUN -eq 1 ]]; then
    note "$(t preview1)"
    gen_config
    note "$(t preview2)"
    gen_hardware
    return
  fi

  # Never inject twice: re-running nixos-infect on a converted machine breaks it
  if [[ -e /run/current-system ]]; then
    die "$(t already_nixos "$(nixos-version 2>/dev/null || echo unknown)")"
  fi

  # lustrate keeps only /nix, /boot and the paths listed in /etc/NIXOS_LUSTRATE;
  # /tmp, /root and /var all move into /old-root. /etc/nixos survives, so the copy
  # of this script lives there and --cleanup can still find it after the reboot.
  local self
  self=$(readlink -f "$0")
  mkdir -p /etc/nixos
  install -m 0755 "$self" /etc/nixos/lightsail-to-nixos.sh
  printf '%s\n' "$(t script_placed)"

  local already=0
  if [[ -f /etc/NIXOS_LUSTRATE && $FORCE -eq 0 ]]; then
    already=1
    note "$(t resume)"
    printf '%s\n' "$(t resume_force)"
  fi

  if [[ $already -eq 0 ]]; then
    check_channel

    check_disk
    setup_swap
    write_config

    if [[ $ASSUME_YES -eq 0 ]]; then
      [[ -t 0 ]] || die "$(t need_yes)"
      note "$(t confirm)"
      read -r -p "$(t confirm_prompt)" _
    fi

    note "$(t downloading)"
    local infect=/tmp/nixos-infect.sh
    curl -fsSL "$INFECT_URL" -o "$infect"
    grep -q 'NIXOS_LUSTRATE' "$infect" || die "$(t not_infect)"

    note "$(t injecting "$LOG")"
    local infect_no_swap=""
    if [[ $TMP_SWAP_ACTIVE -eq 1 ]]; then infect_no_swap=1; fi

    set +e
    env PROVIDER=lightsail \
        ${infect_no_swap:+NO_SWAP=1} \
        NO_REBOOT=1 \
        NIX_CHANNEL="$CHANNEL" \
        bash -x "$infect" 2>&1 | tee "$LOG"
    local rc=${PIPESTATUS[0]}
    set -e
    [[ $rc -eq 0 ]] || die "$(t infect_failed "$rc" "$LOG")"
  fi

  # Success means: rc=0 and the four checks below. nixos-infect itself never prints
  # "The new configuration is ..." - that string comes from nixos-rebuild.
  verify_before_reboot

  note "$(t uuids_title)"
  printf '%s\n' "$(t uuid_root "$ROOT_UUID")"
  printf '%s\n' "$(t uuid_boot "${BOOT_UUID:-$(t uuid_none)}")"
  [[ $BOOT_MODE = uefi ]] && printf '%s\n' "$(t uuid_esp "$ESP_UUID")"
  printf '%s\n' "$(t hardware_hint)"

  if [[ $DO_REBOOT -eq 0 ]]; then
    printf '\n%s\n' "$(t no_reboot_done)"
    printf '%s\n' "$(t no_reboot_next)"
    return
  fi

  printf '\n%s\n' "$(t reboot_soon)"
  sleep 10
  systemctl reboot
}

main "$@"
