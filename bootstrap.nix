# AWS Lightsail 就地安装配置（供 nixos-infect 使用）。
#
# 为什么不用 nixos-anywhere / disko：Lightsail 是 Nitro 平台，kexec 后 ENA/NVMe
# 设备不重新初始化（nixos-anywhere issue #139），会失联；且 Lightsail 不支持导入
# 自定义镜像。故采用 nixos-infect 的 lustrate「就地替换」（普通重启，设备正常复位）。
#
# 为什么自带配置：nixos-infect 的 lightsail 预设只 import amazon-image.nix，
# 而 ec2.efi 默认值 = isAarch64（x86_64 上为 false），会装 BIOS GRUB —— 对这台
# UEFI 机器是致命的。这里显式写 UEFI：ESP 挂 /boot/efi、可移动回退路径，
# 与 nixos-infect 的 EFI 收尾（它把 ESP 挂到 /boot/efi）一致，也与当前 Ubuntu 布局一致。
#
# 本文件同时被 hosts/lightsail/default.nix 作为 flake host 复用，所以自包含
# （不依赖 flake inputs、不使用 disko）。
{
  lib,
  pkgs,
  ...
}:

{
  # 引导：UEFI + 可移动回退路径（EFI/BOOT/BOOTX64.EFI）；ESP 在 /boot/efi，内核放独立 /boot
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev";
  };
  boot.loader.efi.efiSysMountPoint = "/boot/efi";

  # 【关键】必须关闭 systemd-initrd！
  # NixOS 26.05 起 boot.initrd.systemd.enable 默认为 true，而 nixos-infect 依赖的
  # NIXOS_LUSTRATE（首次启动把旧系统整体挪到 /old-root）只在【bash 版 stage-1】
  # （stage-1-init.sh 的 lustrateRoot）里实现，systemd-initrd 完全没有这段逻辑。
  # 若不关闭，首次启动不会挪走旧 Ubuntu 的 /etc、/usr，导致 Ubuntu 的 systemd
  # 单元（systemd-networkd/resolved/dbus 等）泄漏进来、网络起不来——这正是
  # Lightsail/EC2 上"装完重启即失联"的真因（已在 EC2 串口日志中确认）。
  boot.initrd.systemd.enable = false;

  # 磁盘按 UUID 引用（nixos-infect 会把根分区 relabel 成 nixos，UUID 不变）
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/d662a37e-da8d-4720-94ff-f588450178c0";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/71a1f8dc-6e9a-4e94-bf6b-9b1ea9866c4b";
    fsType = "ext4";
  };
  fileSystems."/boot/efi" = {
    device = "/dev/disk/by-uuid/876F-1C6F";
    fsType = "vfat";
  };

  # AWS Nitro（NVMe + ENA）
  boot.initrd.availableKernelModules = [
    "nvme"
    "ena"
    "virtio_pci"
    "virtio_blk"
    "sd_mod"
    "uas"
  ];
  boot.initrd.kernelModules = [ "nvme" ];
  boot.kernelParams = [
    "nvme_core.io_timeout=4294967295"
    "random.trust_cpu=on"
    "console=ttyS0,115200n8"
  ];

  networking.hostName = "lightsail";
  networking.useDHCP = lib.mkDefault true;
  time.timeZone = "Asia/Shanghai";

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  # 复用 AWS 密钥对（私钥 /home/orion/下载/aws-nix.pem）
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-rsa AAAA...<YOUR_SSH_PUBLIC_KEY>"
  ];

  # Lightsail 浏览器 SSH 默认以 ubuntu 用户登录；建一个同名用户当"健康探针"，
  # 这样控制台的 Connect using SSH 能真连进来（NixOS 默认没有 ubuntu 用户）。
  users.users.ubuntu = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAA...<YOUR_SSH_PUBLIC_KEY>"
    ];
  };

  # 内存 ~1.9GiB，加 2GiB swapfile（与 nixos-infect 的 /tmp 临时 swap 不冲突）
  swapDevices = [
    {
      device = "/var/swapfile";
      size = 2048;
    }
  ];

  environment.systemPackages = with pkgs; [
    git
    vim
  ];

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
    trusted-users = [
      "root"
      "@wheel"
    ];
    auto-optimise-store = false;
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.optimise.automatic = true;

  system.stateVersion = "26.05";
}
