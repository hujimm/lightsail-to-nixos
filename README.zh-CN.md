[English](./README.md) | **中文**

# 把 AWS Lightsail 就地转成 NixOS —— 实战记录

> 2026-10 实战。目标：在 **AWS Lightsail（Sydney，t3.small，UEFI）** 上不重装系统、
> 直接**就地**把 Ubuntu 换成 NixOS 26.05。
> 本文记录**真实硬件、真实参数、踩坑过程和最终解决办法**，不是"照着 X 做就行"的二手教程。
>
> 结论就一行：**配置里必须加 `boot.initrd.systemd.enable = false;`**。原因见 §6。

---

## TL;DR

- Lightsail 的实例本质就是 **EC2 t3.small（Nitro）**，**UEFI** 引导，且是**内核自带**的 `nvme` + `ena` 驱动，没有花哨硬件。
- 它**不能**走 `nixos-anywhere`/`disko`：Nitro 平台 kexec 后 ENA/NVMe 不重新初始化（[nixos-anywhere#139](https://github.com/nixos-anywhere/nixos-anywhere/issues/139)），而且 Lightsail 不支持导入自定义镜像。只能用 **`nixos-infect` 就地替换（下次普通重启时生效）**。
- 症状：**安装全程 `EXIT=0`、盘上一切正确，重启后 SSH 却永远失联**。Lightsail 没有串口，你连"它到底有没有引导"都判断不了。
- **根因**：**NixOS 26.05 起 `boot.initrd.systemd.enable` 默认为 `true`**，而 `nixos-infect` 依赖的 `NIXOS_LUSTRATE`（首次启动把旧系统整体挪到 `/old-root`）**只在 bash 版 stage-1 的 `lustrateRoot` 里实现，systemd-initrd 完全没有这段逻辑**。于是旧 Ubuntu 的 `/etc`、`/usr` 原样留在根上 → Ubuntu 的 systemd 单元（`systemd-networkd`/`systemd-resolved`/`dbus`…）泄漏进 NixOS → **网络起不来** → SSH 不通。
- **修复**：在 NixOS 配置里加 **`boot.initrd.systemd.enable = false;`**，让 bash 版 stage-1 跑起来，lustrate 才会执行。

---

## 一、先弄清平台，别猜

从**能正常 SSH 的 Ubuntu** 里直接读（"一切皆文件"）：

```console
$ sudo dmidecode -s system-product-name
t3.small
$ [ -d /sys/firmware/efi ] && echo UEFI
UEFI
$ lspci -nnk | grep -A3 -E "NVMe EBS|Elastic Network"
00:04.0 Non-Volatile memory controller: Amazon.com, Inc. NVMe EBS Controller [1d0f:8061]
        Kernel driver in use: nvme
00:05.0 Ethernet controller: Amazon.com, Inc. Elastic Network Adapter (ENA) [1d0f:ec20]
        Kernel driver in use: ena
$ ethtool -i ens5 | head -1
driver: ena            # 内核自带 in-tree 模块
```

要点：
- **网卡是 Amazon ENA、磁盘是 EBS NVMe，都是内核自带驱动**。所以根本不存在"缺 ENA 驱动"这回事（我一开始猜过这个方向，是错的）。
- `t3.small` 说明 Lightsail 就是标准 Nitro EC2，NixOS 官方支持。

### 磁盘布局（Lightsail 2GB 套餐，60GB 盘）

```
nvme0n1        60G
├─nvme0n1p1    59G ext4   LABEL=cloudimg-rootfs   UUID=d662a37e-da8d-4720-94ff-f588450178c0   /        ← 根
├─nvme0n1p14    4M
├─nvme0n1p15  106M vfat   LABEL=UEFI              UUID=876F-1C6F                              /boot/efi ← ESP
└─nvme0n1p16  913M ext4   LABEL=BOOT              UUID=71a1f8dc-6e9a-4e94-bf6b-9b1ea9866c4b   /boot
```

- 根分区 PARTUUID = `047e559f-5363-4375-91d2-6aa49f34bcf7`
- Ubuntu 的 `fstab` 用 `LABEL=`，内核 cmdline 用 `root=PARTUUID=…`：
  `root=PARTUUID=047e559f-… ro console=tty1 console=ttyS0 nvme_core.io_timeout=4294967295 panic=-1`
- Ubuntu 版本：**Ubuntu 24.04.4 LTS (Noble Numbat)**，内核 **`7.0.0-1012-aws`**
- 固件引导项（`efibootmgr`）：
  ```
  Boot0002* Ubuntu  HD(15,GPT,80149193-fbe8-43ee-8a33-5fa70634c9e2,…)/File(\EFI\ubuntu\shimx64.efi)
  Boot0001* UEFI Amazon Elastic Block Store … {auto_created_boot_option}
  ```

> **同 AMI 重建实例，文件系统 UUID 不变**（写死在 AMI 快照里）；但**公网 IP 可能变**，且 host key 会变，重连前先 `ssh-keygen -R <IP>`。

---

## 二、为什么不用 nixos-anywhere / disko

- Lightsail 是 **Nitro**：`kexec` 后 ENA/NVMe 设备不会重新初始化，nixos-anywhere 会失联（issue #139）。
- Lightsail **不支持导入自定义镜像**，所以也不能像 EC2 那样直接用 NixOS 官方 AMI。
- 结论：用 [`nixos-infect`](https://github.com/elitak/nixos-infect) 的 **lustrate** 就地替换——在原系统里装好 NixOS，写好 `/etc/NIXOS_LUSTRATE`，**下次正常重启**（设备正常复位）时由 NixOS 的 stage-1 把旧系统挪走。

### 也不要直接用 `PROVIDER=lightsail` 的预设配置

`nixos-infect` 的 lightsail 预设只 `import amazon-image.nix`，而 `ec2.efi` 默认值 = `isAarch64`——**x86_64 上为 `false`，会去装 BIOS GRUB**，对这台 UEFI 机器是致命的。所以要**自带一份配置**（见 §8），只用 `PROVIDER=lightsail` 来触发"把根分区 label 改成 `nixos`"这一步。

---

## 三、现象：装成功，重启即失联

```console
$ sudo env PROVIDER=lightsail NIX_CHANNEL=nixos-26.05 NO_REBOOT=1 bash -x ./nixos-infect
...
+ /nix/var/nix/profiles/system/bin/switch-to-configuration boot
installing the GRUB 2 boot loader into /boot/efi...
Installation finished. No error reported.
EXIT=0
```

`EXIT=0`，而且逐项验证都对：
- ESP 里是 NixOS 的 `\EFI\BOOT\BOOTX64.EFI`；
- `/boot/kernels/` 里有 NixOS 的 `bzImage` 和 `initrd`；
- 根分区 label 已改成 `nixos`。

**然后重启 → SSH 永远 `Connection timed out`。** 重启后 CPU 有一下启动峰值然后归零。Lightsail 浏览器 SSH 报"您的实例遇到错误"。

---

## 四、为什么一直看不到原因

- **Lightsail 不给串口/控制台**。"内核没起来" 和 "起来了但没网" 在 Lightsail 上**表现完全一样**（CPU 都是峰值后归零），**无法区分**。
- 本机（中国）直连 Sydney 被墙，走本地代理（Clash TUN）时 TCP 表现得像"已连接"却在 banner 处卡死，**这个信号不可信**。

结论：**必须搞到一台能看引导日志的机器**。

---

## 五、借 EC2 当"眼睛"

开一台 **同区域（Sydney）、同机型（t3.small）、同 Ubuntu（24.04）** 的 EC2——它的磁盘布局和 Lightsail **一模一样**（p1 根 + p15 ESP + p16 /boot，UEFI），但**有 `Get system log`（串口）+ `Get instance screenshot`**。

同样跑一遍 nixos-infect（不改 NVRAM），重启后读串口，**第一次看到了真相**：

```
Booting initrd of NixOS 26.05 (Yarara) (Initrd).
Found device Amazon Elastic Block Store nixos.
Mounted /sysroot.
Starting NixOS Activation... Finished NixOS Activation.
Welcome to NixOS 26.05 (Yarara)!
...
[  OK  ] Reached target Multi-User System.
[  OK  ] Listening on OpenBSD Secure Shell server socket.

[FAILED] Failed to start Network Configuration.        ← systemd-networkd
[FAILED] Failed to start Network Name Resolution.       ← systemd-resolved
[FAILED] Failed to start D-Bus System Message Bus.
[FAILED] Failed to start … (snapd / apport / chrony / rsyslog / networkd-dispatcher / …)
```

两个关键信息：
1. **NixOS 其实完整起来了**（内核、initrd、根挂载、Switch Root、multi-user 全 OK）——所以"盘上装得对不对"根本没问题是。
2. **失败的都是 Ubuntu 的单元**（`snapd`/`apport`/`chrony`/`rsyslog`/`networkd-dispatcher`…），而且网络相关的 `systemd-networkd`/`resolved` 也挂了 → **没 IP → SSH 不通**。

**旧 Ubuntu 的 systemd 单元漏进来了**——这就是线索。

---

## 六、根因（有据可查）

在 nixpkgs 源码里对照：

- `boot.initrd.systemd.enable` 的定义（`nixos/modules/system/boot/systemd/initrd.nix`）：
  ```nix
  enable = mkEnableOption "systemd in initrd" // {
    default = true;   # ← NixOS 26.05 起默认开启
    ...
  ```
- 而 `NIXOS_LUSTRATE` 的处理函数 **`lustrateRoot`** 只存在于 **bash 版 stage-1**（`nixos/modules/system/boot/stage-1-init.sh`）：
  ```sh
  [ "$mountPoint" == "/" ] && [ -f "/mnt-root/etc/NIXOS_LUSTRATE" ] && lustrateRoot "/mnt-root"
  ```
  `systemd-initrd` 的整个 `nixos/modules/system/boot/systemd/` 目录里**搜不到任何 `LUSTRATE`/`lustrate`**。

**完整因果链**：
```
NixOS 26.05 默认 systemd-initrd
   → 首次启动 stage-1 不再执行 lustrateRoot
   → 旧 Ubuntu 的 /etc、/usr 没被挪到 /old-root
   → Ubuntu 的 systemd 单元泄漏进 NixOS
   → systemd-networkd/resolved 等冲突失败
   → 没有 IP → SSH 不通
```
这也正好解释了社区那句"**26.05 的镜像起不来、25.11 正常**"——25.11 默认还不是 systemd-initrd。

（旁证：修复后第一次安装时，nixos-infect 日志会打印
`evaluation warning: Scripted initrd is deprecated and scheduled for removal in 26.11`，
以及串口里会出现 `<<< NixOS is now lustrating the root filesystem (cruft goes to /old-root) >>>`；
之前失败时，串口里**根本没有**这句 lustrate 提示。）

---

## 七、修复：一行

在 NixOS 配置里加：

```nix
boot.initrd.systemd.enable = false;
```

关闭 systemd-initrd，回到 bash 版 stage-1，`lustrateRoot` 正常执行，旧系统被归档到 `/old-root`，NixOS 拿到干净的 `/etc` → 网络恢复正常。

---

## 八、完整配置（`bootstrap.nix`）

自包含：显式 UEFI、ESP 挂 `/boot/efi`、按 UUID 挂盘。也是仓库里 `hosts/lightsail/bootstrap.nix` 的内容。

```nix
# AWS Lightsail 就地安装配置（供 nixos-infect 使用）。
{ lib, pkgs, ... }:

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
  # 单元（systemd-networkd/resolved/dbus 等）泄漏进来、网络起不来。
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
    options = [ "fmask=0022" "dmask=0022" ];
  };

  # AWS Nitro（NVMe + ENA）
  boot.initrd.availableKernelModules = [
    "nvme" "ena" "virtio_pci" "virtio_blk" "sd_mod" "uas"
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
  time.timeZone = "Asia/Shanghai";

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  # 复用 AWS 密钥对（配置里放公钥；私钥只在本地）
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAA...<YOUR_SSH_PUBLIC_KEY>"
  ];
  # Lightsail 浏览器 SSH 默认以 ubuntu 用户登录；建一个同名用户当"健康探针"
  users.users.ubuntu = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAA...<YOUR_SSH_PUBLIC_KEY>"
    ];
  };

  # 内存 ~1.9GiB，加 2GiB swapfile
  swapDevices = [ { device = "/var/swapfile"; size = 2048; } ];

  environment.systemPackages = with pkgs; [ git vim ];

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
    trusted-users = [ "root" "@wheel" ];
    auto-optimise-store = false;
  };

  nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 14d"; };
  nix.optimise.automatic = true;

  system.stateVersion = "26.05";
}
```

> 把三处 UUID 换成你机器 `blkid` 读到的值（同 AMI 通常一致，但**务必实测**）。
> 仓库同目录下的 [`bootstrap.nix`](./bootstrap.nix) 就是这份。

---

## 九、可复现的操作步骤

前提：实例是**全新 Ubuntu**，且已能 SSH；本地有对应私钥。

```bash
IP=<你的公网IP>; KEY=<你的私钥路径>; U=ubuntu   # 全新 Ubuntu 用 ubuntu 用户

# 0) 清一下本地旧 host key（实例重建过的话）
ssh-keygen -R "$IP"

# 1) 备份原 ESP，留个后路
ssh -i "$KEY" $U@$IP 'sudo mkdir -p /root/backup && \
  sudo tar czf /root/backup/esp-ubuntu.tgz -C /boot/efi . && \
  sudo efibootmgr -v | sudo tee /root/backup/efibootmgr.before.txt >/dev/null'

# 2) 放配置
ssh -i "$KEY" $U@$IP 'sudo mkdir -p /etc/nixos && sudo tee /etc/nixos/configuration.nix >/dev/null' < bootstrap.nix

# 3) 克隆 nixos-infect
ssh -i "$KEY" $U@$IP 'cd ~ && rm -rf nixos-infect && \
  git clone --depth 1 https://github.com/elitak/nixos-infect nixos-infect'

# 4) 就地安装（NO_REBOOT=1：先不重启，便于检查）
ssh -i "$KEY" $U@$IP 'sudo env PROVIDER=lightsail NIX_CHANNEL=nixos-26.05 NO_REBOOT=1 \
  bash ~/nixos-infect/nixos-infect'

# 5) 检查无误后重启
ssh -i "$KEY" $U@$IP 'sudo systemctl reboot'
```

重启后应以 **root**（配置里的公钥）登录：

```bash
ssh -i "$KEY" root@$IP 'nixos-version'
```

之后日常重建（在本地 flake 仓库里）：

```bash
nixos-rebuild switch --flake .#lightsail --target-host lightsail
```

---

## 十、验证结果（修复后）

Lightsail 与 EC2 双端一致：

```
nixos-version : 26.05.11576.7c8764b7c7b0 (Yarara)     kernel: 6.18.55
systemctl --failed : 0 loaded units listed
ip -4 -br a   : ens5  UP  172.26.1.140/20
curl cache.nixos.org : -> 200
lsblk         : p1 59G ext4 nixos /   p15 106M vfat UEFI /boot/efi   p16 913M ext4 BOOT /boot
free -h       : Swap 2.0Gi
ls /old-root  : bin etc usr var snap …   ← 旧 Ubuntu 被完整归档
```

串口里能看到关键那步：

```
<<< NixOS is now lustrating the root filesystem (cruft goes to /old-root) >>>
Moving impurities out of the way: '/mnt-root/etc' -> '/mnt-root/old-root.tmp/etc' ...
```

---

## 十一、坑与注意

1. **`boot.initrd.systemd.enable = false;` 别删。** 这是 nixos-infect 类"就地安装"在 26.05 上的命门。
2. **26.11 的雷**：日志提示 `Scripted initrd is deprecated and scheduled for removal in 26.11`。对**已装好**的系统无影响；但若 26.11 真移除 bash initrd，nixos-infect 这套就地安装会再次失效——届时需换方法（如官方 AMI 或其它迁移路径）。
3. **NVRAM 其实不用手动改。** 我一度手动加了一条指向 `\EFI\BOOT\BOOTX64.EFI` 的引导项做"双保险"，后来在 EC2 上验证：即使 NVRAM 里还留着指向已删除的 `\EFI\ubuntu\shimx64.efi` 的旧 `Boot0002`，**固件也会自动回退到可移动路径 `\EFI\BOOT\BOOTX64.EFI`**。所以最终流程**不碰 NVRAM**。
4. **`--target-host` 的 GC root**：`nixos-rebuild --target-host` 是"本机构建、拷贝到远端"，**GC root 建在远端**，本机那份闭包无根，可能被本机 nightly GC 回收、导致下次重建重编。做法是在本机留个 root：
   ```bash
   nix build .#nixosConfigurations.lightsail.config.system.build.toplevel -o ~/nixos-lightsail
   ```
5. **Lightsail 没有串口**。排查引导/早期启动问题时，开一台**同区域、同机型、同 Ubuntu** 的 EC2 当替身，用 `Get system log` / `Get instance screenshot` 看真相；用完 `terminate`，成本几毛钱。
6. **重建实例**：同 AMI 的**文件系统 UUID 不变**，但**公网 IP、SSH host key 会变**。`~/.ssh/config` 里的别名可以固定，但 IP 变了要更新。
7. **"一切皆文件"能省很多事**：`/sys/class/net/*/device/{vendor,device,driver}`、`/sys/firmware/efi`、`blkid`、`lsblk`、`efibootmgr`、`dmesg`、`lsmod` —— 先把真实硬件/布局读出来，再动手，**别猜**。

---

## 十二、参考资料

- nixos-infect：<https://github.com/elitak/nixos-infect>
- nixos-anywhere issue #139（Nitro kexec 后 ENA/NVMe 不初始化）：<https://github.com/nixos-anywhere/nixos-anywhere/issues/139>
- nixpkgs `boot.initrd.systemd.enable`（默认 true）：`nixos/modules/system/boot/systemd/initrd.nix`
- nixpkgs `lustrateRoot`（只在 bash stage-1）：`nixos/modules/system/boot/stage-1-init.sh`
- NixOS 手动：`NIXOS_LUSTRATE` 机制
