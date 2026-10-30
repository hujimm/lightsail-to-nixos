#!/usr/bin/env bash
#
# lightsail-to-nixos.sh —— 在 AWS Lightsail 的 Ubuntu / Debian 上就地转成 NixOS
#
# 只做三件 nixos-infect 不会替你做的事：
#   1. 从当前系统读真实的根/启动/ESP 分区 UUID，生成 UEFI 版 configuration.nix
#      （nixos-infect 自带的 lightsail 预设会按 BIOS 安装 GRUB，UEFI 实例装完起不来）
#   2. 补一块临时 swap（512 MB 机型求值阶段会用到 800 MB 上下）
#   3. 用 NIX_CHANNEL=nixos-26.05 调 nixos-infect，并在重启前核对 lustrate 的落盘结果
#
# 用法（在实例上执行，需要 root）：
#   sudo bash lightsail-to-nixos.sh --dry-run     # 只打印将写入的配置，不动系统
#   sudo bash lightsail-to-nixos.sh               # 生成配置 + 注入 + 自动重启
#   sudo bash lightsail-to-nixos.sh --no-reboot   # 注入后停下，人工核对再重启
#
# 转换完成后（已经在 NixOS 里）清掉一次性残留：
#   sudo bash lightsail-to-nixos.sh --cleanup
#
# 适用前提：Ubuntu / Debian 云镜像、x86_64、UEFI 或 BIOS、
# 磁盘为「根 + 独立 /boot + ESP」「根 + ESP」或「根 + bios_grub + ESP」布局。
# 这是照着两次成功的手工流程写的，不是通用安装器；不满足前提就应当手工来。
#
# 选项：
#   --channel <名字>     nixpkgs channel，默认 nixos-26.05（必须自带 bash 版 stage-1）
#   --hostname <名字>    networking.hostName，默认 lightsail
#   --swap-gb <数字>     临时 swap 大小，默认 512 MB 内存用 4，其余用 2
#   --pubkey <文件>      从指定文件读公钥（默认扫 /root 与 /home/* 的 authorized_keys）
#   --no-swap            不加 swap（nixos-infect 会自己造 1 GB 的 /tmp swap）
#   --no-reboot          注入后不自动重启
#   --yes                跳过确认
#   --dry-run            只打印配置
#   --cleanup            转换成 NixOS 之后清理 /old-root 与旧 generation
#   --keep-config        --cleanup 时保留 /etc/nixos 下的文件
#   --force              已有 /etc/NIXOS_LUSTRATE 时仍然重新注入（默认跳过注入只做核对）
#
set -euo pipefail

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

CONFIG_PATH=/etc/nixos/configuration.nix
HARDWARE_PATH=/etc/nixos/hardware.nix
LOG=/var/log/lightsail-to-nixos.log
INFECT_URL=https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect

die() { printf '\n错误: %s\n' "$*" >&2; exit 1; }
note() { printf '\n=== %s\n' "$*"; }

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)    CHANNEL="$2"; shift 2 ;;
    --hostname)   HOST_NAME="$2"; shift 2 ;;
    --swap-gb)    TEMP_SWAP_GB="$2"; shift 2 ;;
    --no-swap)    USE_SWAP=0; shift ;;
    --no-reboot)  DO_REBOOT=0; shift ;;
    --yes)        ASSUME_YES=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --cleanup)    CLEANUP=1; shift ;;
    --keep-config) KEEP_CONFIG=1; shift ;;
    --force)      FORCE=1; shift ;;
    --pubkey)     PUBKEY_FILE="$2"; shift 2 ;;
    -h|--help)    usage ;;
    *)            die "未知参数: $1（--help 查看用法）" ;;
  esac
done

need_root() {
  [[ ${EUID:-0} -eq 0 ]] || die "需要 root：sudo bash $0"
}

# ─────────────────────────────────────────────────────────────
# --cleanup：转换完成、已经进 NixOS 之后跑
# ─────────────────────────────────────────────────────────────
do_cleanup() {
  need_root
  [[ -e /run/current-system ]] || die "当前不是 NixOS，--cleanup 只能在转换成功后执行"

  note "清理前"
  df -h / | tail -1

  if [[ -d /old-root ]]; then
    note "删除 /old-root（旧系统的整棵根）"
    rm -rf /old-root
  fi

  note "删除旧 system generation 并回收 store"
  nix-env --delete-generations old --profile /nix/var/nix/profiles/system || true
  nix-collect-garbage -d || true

  rm -f /etc/NIXOS

  if [[ $KEEP_CONFIG -eq 0 ]]; then
    note "删除注入用的 /etc/nixos/configuration.nix"
    rm -f /etc/nixos/configuration.nix /etc/nixos/hardware-configuration.nix
  fi

  note "清理后"
  df -h / | tail -1
  rm -f /etc/nixos/lightsail-to-nixos.sh
  [[ -e /etc/NIXOS_LUSTRATE ]] && printf '注意: /etc/NIXOS_LUSTRATE 仍在，下次启动会再 lustrate 一次\n' >&2

  if [[ -f $HARDWARE_PATH ]]; then
    printf '\n硬件描述留在这里，取回去当 flake 的 hosts/<名字>/hardware.nix：\n'
    printf '  scp root@<IP>:%s ./hosts/<名字>/hardware.nix\n\n' "$HARDWARE_PATH"
    sed 's/^/  | /' "$HARDWARE_PATH"
  fi

  printf '\n完成。接下来在本机用 flake 接管：nixos-rebuild switch --flake .#<host> --target-host root@<IP>\n'
}

# ─────────────────────────────────────────────────────────────
# 平台与文件系统探测
# ─────────────────────────────────────────────────────────────
ROOT_SRC=""; ROOT_UUID=""; ROOT_FS=""
BOOT_MODE=""; GRUB_DEV=""
BOOT_UUID=""; BOOT_FS=""
ESP_MNT=""; ESP_UUID=""
TMP_SWAP_ACTIVE=0
KEYS=()
PROBE_USER=""

detect_platform() {
  [[ "$(uname -m)" = "x86_64" ]] || die "只覆盖 x86_64 实例（当前 $(uname -m)）"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" = "ubuntu" ]] || [[ "${ID:-}" = "debian" ]] || printf '注意: 当前系统是 %s，不是 Ubuntu/Debian；脚本按 apt 系云镜像验证过，继续前自行确认\n' "${PRETTY_NAME:-未知}"
  fi

  # Lightsail 的 Ubuntu 镜像走 UEFI，Debian 镜像走 BIOS；两种都要覆盖
  if [[ -d /sys/firmware/efi ]]; then
    BOOT_MODE=uefi
  else
    BOOT_MODE=bios
  fi

  ROOT_SRC=$(findmnt -no SOURCE /) || die "读不到根分区"
  ROOT_SRC=${ROOT_SRC%%\[*}   # btrfs 子卷会带 [/@] 后缀
  ROOT_FS=$(findmnt -no FSTYPE /)
  ROOT_UUID=$(lsblk -no UUID "$ROOT_SRC" | tr -d " ") || die "根分区 $ROOT_SRC 没有 UUID"

  # 只覆盖「直接落在整块分区上的 ext4」。LVM/btrfs/加密根都需要往 initrd 里
  # 补模块和挂载参数，脚本不会自动生成，宁可在这里停住也不要装出起不来的系统。
  [[ $ROOT_FS = "ext4" ]] || die "根分区是 $ROOT_FS，脚本只生成 ext4 的配置；请手工写 configuration.nix"
  [[ $ROOT_SRC != /dev/mapper/* ]] || die "根分区在 LVM 上（$ROOT_SRC），initrd 需要 lvm 模块，脚本不生成；请手工写"

  # BIOS 要往整块盘装 GRUB（MBR + bios_grub 分区）
  if [[ $BOOT_MODE = bios ]]; then
    local disk
    disk=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1)
    [[ -n $disk ]] || die "推不出根分区所在的整块盘（lsblk PKNAME 为空）"
    GRUB_DEV="/dev/$disk"
  fi

  # ESP：Ubuntu 云镜像挂在 /boot/efi；没有独立 /boot 时可能直接挂在 /boot
  if [[ $BOOT_MODE = uefi ]]; then
    local d
    for d in /boot/efi /boot/EFI; do
      if findmnt -no TARGET "$d" >/dev/null 2>&1; then ESP_MNT="$d"; break; fi
    done
    if [[ -z $ESP_MNT ]] && [[ "$(findmnt -no FSTYPE /boot 2>/dev/null || true)" = "vfat" ]]; then
      ESP_MNT=/boot
    fi
    [[ -n $ESP_MNT ]] || die "找不到 ESP（/boot/efi、/boot/EFI 或 vfat 的 /boot）"
    ESP_UUID=$(lsblk -no UUID "$(findmnt -no SOURCE "$ESP_MNT")" | tr -d " ") || die "ESP 没有 UUID"
  fi

  # 独立 /boot（Ubuntu 云镜像有，913 MB ext4）
  local boot_src boot_mp
  boot_src=$(findmnt -no SOURCE /boot 2>/dev/null || true)
  boot_mp=$(findmnt -no TARGET /boot 2>/dev/null || true)
  if [[ -n $boot_src && $boot_mp = /boot && $boot_src != "$ROOT_SRC" && $boot_src != "${ESP_MNT:+$(findmnt -no SOURCE "$ESP_MNT")}" ]]; then
    BOOT_UUID=$(lsblk -no UUID "$boot_src" | tr -d " ") || die "/boot 没有 UUID"
    BOOT_FS=$(findmnt -no FSTYPE /boot)
  fi
}

collect_keys() {
  local f
  local -a found=()
  if [[ -n $PUBKEY_FILE ]]; then
    [[ -r $PUBKEY_FILE ]] || die "读不到公钥文件 $PUBKEY_FILE"
    mapfile -t found < <(grep -E '^(ssh-(rsa|ed25519)|ecdsa-|sk-ssh-|sk-ecdsa-)' "$PUBKEY_FILE" || true)
    [[ ${#found[@]} -gt 0 ]] || die "$PUBKEY_FILE 里没有 SSH 公钥"
    KEYS=("${found[@]}")
    return 0
  fi
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -r $f ]] || continue
    while IFS= read -r line; do
      [[ -n $line ]] && found+=("$line")
    done < <(grep -E '^(ssh-(rsa|ed25519)|ecdsa-|sk-ssh-|sk-ecdsa-)' "$f" || true)
  done
  # 去重，保持稳定顺序
  if [[ ${#found[@]} -gt 0 ]]; then
    mapfile -t KEYS < <(printf '%s\n' "${found[@]}" | sort -u)
  fi
  [[ ${#KEYS[@]} -gt 0 ]] || die "找不到任何 SSH 公钥（/root 或 /home/*/.ssh/authorized_keys）。没有公钥会把自己锁在门外"

  # 云镜像的默认登录用户（控制台 Connect 用它）：Ubuntu 是 ubuntu，Debian 是 admin
  local u
  for u in ubuntu admin debian; do
    if [[ -f /home/$u/.ssh/authorized_keys ]]; then PROBE_USER=$u; break; fi
  done
}

check_disk() {
  # 旧根整体挪进 /old-root，同一文件系统上还要放新闭包
  local free_gb
  free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  if [[ ${free_gb:-0} -lt 8 ]]; then
    die "根分区只剩 ${free_gb} GB。至少留 8 GB：旧根要挪进 /old-root，新系统闭包也在同一文件系统上"
  fi
  printf '根分区可用 %s GB\n' "$free_gb"
}

setup_swap() {
  [[ $USE_SWAP -eq 1 ]] || { printf '按要求不加 swap\n'; return 0; }

  if [[ -n "$(swapon --show=NAME --noheadings 2>/dev/null)" ]]; then
    printf '已有 swap 在用，跳过创建：\n'
    swapon --show
    TMP_SWAP_ACTIVE=1
    return 0
  fi

  local mem_mb gb
  mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  gb="${TEMP_SWAP_GB:-$([[ $mem_mb -lt 1024 ]] && echo 4 || echo 2)}"
  note "内存 ${mem_mb} MB，创建 ${gb} GB 临时 swap 到 /swapfile"

  fallocate -l "${gb}G" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  TMP_SWAP_ACTIVE=1
  swapon --show
}

# ─────────────────────────────────────────────────────────────
# 生成 configuration.nix
# ─────────────────────────────────────────────────────────────
gen_hardware_body() {
  # 参数 1 为 1 时插入「关闭 systemd-initrd」那一行——只有注入用配置需要，
  # 装好之后的日常配置不需要（而且 26.11 起这个选项已被删除）。
  local with_toggle="$1"

  if [[ $BOOT_MODE = uefi ]]; then
    cat <<EOF
  # UEFI，写到可移动回退路径 EFI/BOOT/BOOTX64.EFI
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
  # BIOS：GRUB 装到整块盘的 MBR，core.img 进 bios_grub 分区
  boot.loader.grub = {
    enable = true;
    device = "${GRUB_DEV}";
  };

EOF
  fi

  if [[ $with_toggle -eq 1 ]]; then
    cat <<EOF
  # lustrate（把旧系统挪到 /old-root）只在 bash 版 stage-1 里实现，
  # systemd-initrd 下不会执行，旧系统的 /etc、/usr 会留在根上。
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
  # 前三项来自 amazon-image.nix，直接照搬
  boot.kernelParams = [
    "nvme_core.io_timeout=4294967295"
    "random.trust_cpu=on"
    "console=ttyS0,115200n8"
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
EOF
}

# 注入用的配置：多出 systemd-initrd 开关、SSH、用户、swap、GC
gen_config() {
  local state_version="${CHANNEL#nixos-}"
  local key_lines
  key_lines=$(printf '%s\n' "${KEYS[@]}" | awk '{printf "    \"%s\"\n", $0}')

  cat <<EOF
# 由 lightsail-to-nixos.sh 生成，只在第一次 nixos-infect 注入时使用。
# 转换完成后本文件不再需要，--cleanup 会删掉它。
#
# 为什么不直接用 nixos-infect 的 lightsail 预设：它 import amazon-image.nix，
# 而 ec2.efi 的默认值是 isAarch64，x86_64 上为 false，UEFI 实例会被装成 BIOS GRUB，
# 重启即失联。
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

  # 云镜像的默认登录用户，Lightsail 控制台的 "Connect using SSH" 用它
  if [[ -n $PROBE_USER ]]; then
    cat <<EOF

  # 控制台 Connect 默认以 ${PROBE_USER} 登录，留个同名用户当探针
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

  # 转换后的系统自己也要有 swap（临时 /swapfile 会随旧系统一起进 /old-root）
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

# 交给 flake 的一份硬件描述，直接当 hosts/<名字>/hardware.nix 用。
# 不含 SSH、用户、swap、GC、stateVersion——那些属于你自己的主机配置。
gen_hardware() {
  cat <<EOF
# 由 lightsail-to-nixos.sh 从实例上读出，可直接作为 hosts/<名字>/hardware.nix。
# 磁盘按 UUID 引用；根分区 label 已被 nixos-infect 改成 nixos，UUID 不变。
{ lib, ... }:

{
EOF

  gen_hardware_body 0

  cat <<EOF
}
EOF
}

# ─────────────────────────────────────────────────────────────
# 前置检查
# ─────────────────────────────────────────────────────────────
check_channel() {
  local url="https://raw.githubusercontent.com/NixOS/nixpkgs/${CHANNEL}/nixos/modules/system/boot/stage-1-init.sh"
  local body
  if ! body=$(curl -fsSL --max-time 20 "$url" 2>/dev/null); then
    printf '注意: 拉不到 %s 的 stage-1-init.sh，跳过 channel 检查（离线或代理问题）\n' "$CHANNEL" >&2
    return 0
  fi
  if ! grep -q 'lustrateRoot' <<<"$body"; then
    die "$CHANNEL 没有 bash 版 stage-1（lustrateRoot），nixos-infect 无法完成转换。用 --channel nixos-26.05"
  fi
  printf 'channel %s 带 lustrateRoot，OK\n' "$CHANNEL"
}

write_config() {
  mkdir -p /etc/nixos
  local f bak
  for f in "$CONFIG_PATH" "$HARDWARE_PATH"; do
    if [[ -f $f ]]; then
      bak="${f}.bak.$(date +%Y%m%d%H%M%S)"
      mv "$f" "$bak"
      printf '已有文件备份到 %s\n' "$bak"
    fi
  done
  gen_config > "$CONFIG_PATH"
  gen_hardware > "$HARDWARE_PATH"
  chmod 600 "$CONFIG_PATH" "$HARDWARE_PATH"
  printf '写入 %s（注入用）\n' "$CONFIG_PATH"
  printf '写入 %s（交给 flake 用，--cleanup 不会删）\n' "$HARDWARE_PATH"
}

verify_before_reboot() {
  local ok=1
  note "重启前核对"

  if [[ -f /etc/NIXOS ]]; then
    printf '[ok] /etc/NIXOS 存在\n'
  else
    printf '[!!] /etc/NIXOS 不存在：注入没走到最后\n' >&2; ok=0
  fi

  if [[ -f /etc/NIXOS_LUSTRATE ]] && grep -qx 'etc/nixos' /etc/NIXOS_LUSTRATE; then
    printf '[ok] /etc/NIXOS_LUSTRATE 已就位\n'
  else
    printf '[!!] /etc/NIXOS_LUSTRATE 缺失或不含 etc/nixos\n' >&2; ok=0
  fi

  local label
  # 直接读超级块：e2label 刚改完，udev 里的 label 可能还是旧的
  label=$(e2label "$ROOT_SRC" 2>/dev/null || true)
  if [[ $label = "nixos" ]]; then
    printf '[ok] 根分区 label = nixos\n'
  else
    printf '[!!] 根分区 label 是 "%s"，不是 nixos\n' "$label" >&2; ok=0
  fi

  if [[ $BOOT_MODE = uefi ]]; then
    if find "$ESP_MNT" -iname '*.efi' -print -quit | grep -q .; then
      printf '[ok] ESP 里有 EFI 程序：\n'
      find "$ESP_MNT" -iname '*.efi' | head -5 | sed 's/^/     /'
    else
      printf '[!!] ESP 里没有 .efi 文件\n' >&2; ok=0
    fi
  else
    if [[ -s /boot/grub/grub.cfg ]] && grep -q 'nixos-system' /boot/grub/grub.cfg; then
      printf '[ok] /boot/grub/grub.cfg 指向 NixOS：\n'
      grep -m1 'nixos-system' /boot/grub/grub.cfg | sed 's/^/     /'
    else
      printf '[!!] /boot/grub/grub.cfg 缺失或不含 nixos-system\n' >&2; ok=0
    fi
  fi

  [[ $ok -eq 1 ]] || die "核对未通过，不要重启。日志：$LOG"
  printf '\n全部通过。\n'
}

# ─────────────────────────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────────────────────────
main() {
  if [[ $CLEANUP -eq 1 ]]; then do_cleanup; return; fi

  if [[ $DRY_RUN -eq 0 ]]; then need_root; fi

  detect_platform
  collect_keys

  note "探测结果"
  printf '根分区   %s  %s  UUID=%s\n' "$ROOT_SRC" "$ROOT_FS" "$ROOT_UUID"
  [[ -n $BOOT_UUID ]] && printf '/boot    UUID=%s  %s\n' "$BOOT_UUID" "$BOOT_FS"
  if [[ $BOOT_MODE = uefi ]]; then
    printf 'ESP      %s  UUID=%s\n' "$ESP_MNT" "$ESP_UUID"
  else
    printf '启动模式 BIOS，GRUB 装到 %s\n' "$GRUB_DEV"
  fi
  printf 'channel  %s\n' "$CHANNEL"
  printf '公钥     %d 条\n' "${#KEYS[@]}"

  if [[ $DRY_RUN -eq 1 ]]; then
    note "配置预览 1/2：/etc/nixos/configuration.nix（注入用）"
    gen_config
    note "配置预览 2/2：/etc/nixos/hardware.nix（给 flake 的 hosts/<名字>/hardware.nix）"
    gen_hardware
    return
  fi

  # 已经是 NixOS 就别再注入一遍（重跑 nixos-infect 会把系统搞坏）
  if [[ -e /run/current-system ]]; then
    die "这台已经是 NixOS（$(nixos-version 2>/dev/null || echo 未知版本)）。要清理残留请用 --cleanup"
  fi

  # lustrate 只保留 /nix、/boot 和 /etc/NIXOS_LUSTRATE 里列出的路径，
  # /tmp、/root、/var 全都会被搬进 /old-root。放到 /etc/nixos 才能活到重启之后，
  # --cleanup 还要用同一个脚本。
  local self
  self=$(readlink -f "$0")
  mkdir -p /etc/nixos
  install -m 0755 "$self" /etc/nixos/lightsail-to-nixos.sh
  printf '脚本已放到 /etc/nixos/lightsail-to-nixos.sh（重启后还在）\n'

  local already=0
  if [[ -f /etc/NIXOS_LUSTRATE && $FORCE -eq 0 ]]; then
    already=1
    note "检测到 /etc/NIXOS_LUSTRATE：这台机器已经注入过，跳过注入，只做核对"
    printf '（要强制重新注入请加 --force）\n'
  fi

  if [[ $already -eq 0 ]]; then
    check_channel

    check_disk
    setup_swap
    write_config

    if [[ $ASSUME_YES -eq 0 ]]; then
      [[ -t 0 ]] || die "非交互环境请加 --yes"
      note "即将注入。这会安装 Nix、构建新系统并改写引导；确认无误后回车"
      read -r -p '回车继续，Ctrl-C 退出: ' _
    fi

    note "下载 nixos-infect"
    local infect=/tmp/nixos-infect.sh
    curl -fsSL "$INFECT_URL" -o "$infect"
    grep -q 'NIXOS_LUSTRATE' "$infect" || die "下载到的脚本不像 nixos-infect"

    note "注入（日志同时写入 $LOG）"
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
    [[ $rc -eq 0 ]] || die "nixos-infect 退出码 $rc，见 $LOG"
  fi   # already

  # 注意：只在 rc=0 且下面四项核对通过时才算成功。
  # nixos-infect 本身不打印任何 "The new configuration is ..."（那是 nixos-rebuild 的输出）。
  verify_before_reboot

  note "本机可直接用于 flake 的文件系统片段"
  printf '    root uuid  %s\n    boot uuid  %s\n' "$ROOT_UUID" "${BOOT_UUID:-无}"
  [[ $BOOT_MODE = uefi ]] && printf '    esp  uuid  %s\n' "$ESP_UUID"
  printf '重启后完整的一份在 /etc/nixos/hardware.nix（清理时不会删）\n' 

  if [[ $DO_REBOOT -eq 0 ]]; then
    printf '\n按要求不重启。确认后执行： sudo systemctl reboot\n'
    printf '重启后： ssh root@<IP>，然后 /etc/nixos/lightsail-to-nixos.sh --cleanup\n'
    return
  fi

  printf '\n10 秒后重启（Ctrl-C 取消）\n'
  sleep 10
  systemctl reboot
}

main "$@"
