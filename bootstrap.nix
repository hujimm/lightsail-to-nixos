# 就地转换用的单文件配置，喂给 nixos-infect。
#
# 必须配合 NIX_CHANNEL=nixos-26.05：lustrate 只在 bash 版 stage-1 里实现，
# 26.11 起 scripted initrd 被删，这个选项会直接 assertion 失败。
#
# 不用 nixos-infect 自带的 lightsail 预设：它 import amazon-image.nix，
# 而 ec2.efi 在 x86_64 上是 false，会去装 BIOS GRUB。
{ lib, ... }:

{
  # UEFI，写到可移动回退路径；NVRAM 不用手动改，旧启动项失效时固件会回退到这里
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev";
  };
  boot.loader.efi.efiSysMountPoint = "/boot/efi";

  # 不关的话旧系统的 /etc、/usr 不会挪进 /old-root，networkd/resolved 泄漏进来导致失联
  boot.initrd.systemd.enable = false;

  # UUID 用 blkid 读，同 AMI 的实例一致
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/<ROOT-UUID>";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/<BOOT-UUID>";
    fsType = "ext4";
  };
  fileSystems."/boot/efi" = {
    device = "/dev/disk/by-uuid/<ESP-UUID>";
    fsType = "vfat";
    options = [ "fmask=0022" "dmask=0022" ];
  };

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

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  networking.hostName = "lightsail";
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
    "<YOUR_SSH_PUBLIC_KEY>"
  ];

  # 控制台 Connect 默认以 ubuntu 登录，留个同名用户当探针
  users.users.ubuntu = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "<YOUR_SSH_PUBLIC_KEY>"
    ];
  };

  swapDevices = [
    {
      device = "/var/swapfile";
      size = 2048;
    }
  ];

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [
      "root"
      "@wheel"
    ];
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  system.stateVersion = "26.05";
}
