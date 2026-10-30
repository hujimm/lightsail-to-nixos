# 把 AWS Lightsail 就地转成 NixOS

> English: [README.md](./README.md)

不重装、不导入镜像，在原 Ubuntu / Debian 上用一条命令换成 NixOS。

仓库里是一个脚本：`lightsail-to-nixos.sh`。它只做 nixos-infect 不会替你做的事——
读出真实分区、生成 UEFI 或 BIOS 都能用的配置、注入、重启前核对，转换完再清掉旧系统残留。

## 一句话结论

**注入这一遍必须用 `nixos-26.05`（或更老的 channel）。**

`nixos-infect` 靠 `lustrate` 把旧系统整体挪进 `/old-root`，这段逻辑只实现在 bash 版
stage-1（`stage-1-init.sh` 的 `lustrateRoot`）里。NixOS 26.05 起 systemd-initrd 成为默认，
26.11 直接把这个选项删了——`boot.initrd.systemd.enable` 会报「option has been removed」。
装好之后想切哪个 channel 都行，与这一点无关。

## 用法

Ubuntu 镜像默认用户是 `ubuntu`，Debian 是 `admin`。

```bash
# 0. 本机准备
IP=<公网 IP>; KEY=~/.ssh/aws-nix.pem

# 1. 把脚本送上去（不改系统）
scp -i $KEY lightsail-to-nixos.sh ubuntu@$IP:/tmp/

# 2. 先看一眼它要写什么（不需要 root，不改任何东西）
ssh -i $KEY ubuntu@$IP 'bash /tmp/lightsail-to-nixos.sh --dry-run'

# 3. 注入。核对通过后自己重启
ssh -i $KEY ubuntu@$IP 'sudo bash /tmp/lightsail-to-nixos.sh --yes'

# 4. 重启后（约 20 秒），清掉旧系统残留
ssh -i $KEY root@$IP '/etc/nixos/lightsail-to-nixos.sh --cleanup'

# 5. 取回硬件描述，纳入自己的 flake
scp -i $KEY root@$IP:/etc/nixos/hardware.nix ./hosts/<名字>/hardware.nix
```

想截图或分步看，第 3 步加 `--no-reboot`：脚本会打印探测结果、四项核对和三段 UUID，
然后停下等你自己 `sudo systemctl reboot`。

## 语言

脚本输出跟随系统语言：`LANG=zh_CN.UTF-8` 输出中文，其它一律英文。也可以在单次运行时用
`--lang en` 或 `--lang zh` 指定。

```
$ LANG=zh_CN.UTF-8 sudo bash lightsail-to-nixos.sh --dry-run
=== 探测结果
根分区   /dev/nvme0n1p1  ext4  UUID=d662a37e-...
/boot      UUID=71a1f8dc-...  ext4
ESP        /boot/efi  UUID=876F-1C6F

$ sudo bash lightsail-to-nixos.sh --lang en --dry-run
=== detected layout
root       /dev/nvme0n1p1  ext4  UUID=d662a37e-...
/boot      UUID=71a1f8dc-...  ext4
ESP        /boot/efi  UUID=876F-1C6F
```

有两样东西固定英文，是有意的：

- **脚本注释**：源码只保留一种语言，谁读都一样；
- **生成的 `configuration.nix` 与 `hardware.nix`**：配置文件不该因为「当初是谁跑的安装脚本」
  而换语言，里面的注释是给以后维护这台机器的人看的。

提示语里的路径和命令不翻译，两种语言下都能直接复制执行。

## 脚本做了什么

**1. 读活系统，不看版本号**

| 探测项 | 用途 |
|---|---|
| `/sys/firmware/efi` 是否存在 | 决定走 UEFI 还是 BIOS 分支 |
| 根、`/boot`、ESP 的挂载源与 UUID | 生成 `fileSystems` |
| `/boot` 是否独立挂载 | 决定要不要写 `fileSystems."/boot"` |
| `/home/{ubuntu,admin,debian}` | 保留云镜像默认用户，控制台 Connect 还能用 |
| `authorized_keys` | 没有公钥就拒绝执行，避免把自己锁在门外 |

**2. 前置检查**：根分区可用空间不足 8 GB 直接停（旧根要挪进 `/old-root`，新闭包也在同一文件系统上）；
根不是 ext4、或者根在 LVM/btrfs 上，也直接停——这些要往 initrd 补模块和挂载参数，脚本不生成。

**3. 补 swap**：`MemTotal < 1024 MB` 加 4 GB 临时 swap，否则 2 GB；已有 swap 就跳过。
转换后的系统另声明 2 GB `/var/swapfile`。

**4. 生成两份文件**

- `/etc/nixos/configuration.nix`：注入用，含 `boot.initrd.systemd.enable = false`、SSH、用户、swap
- `/etc/nixos/hardware.nix`：给 flake 的 `hosts/<名字>/hardware.nix`，只有引导、文件系统、内核模块与参数

**5. 调 nixos-infect**：`PROVIDER=lightsail NO_SWAP=1 NO_REBOOT=1 NIX_CHANNEL=nixos-26.05`，
日志写到 `/var/log/lightsail-to-nixos.log`。

**6. 重启前核对四项**，任何一项不过就不重启：

```
[ok] /etc/NIXOS 存在
[ok] /etc/NIXOS_LUSTRATE 已就位
[ok] 根分区 label = nixos
[ok] ESP 里有 EFI 程序 / 或 /boot/grub/grub.cfg 指向 NixOS
```

**7. `--cleanup`**：删 `/old-root`、`/etc/NIXOS`、注入用配置、旧 generation，回收 store；
`hardware.nix` 保留，最后打印一份并给出 `scp` 命令。

另外两种情况脚本会拒绝：`/etc/NIXOS_LUSTRATE` 还在时再跑（跳过注入、只核对，除非 `--force`）；
机器已经是 NixOS 时再跑（提示用 `--cleanup`）。

## 为什么不能直接用 nixos-infect 的一键

Lightsail 上那一行是：

```bash
curl -fsSL https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect \
  | PROVIDER=lightsail NIX_CHANNEL=nixos-26.05 bash
```

它会调 `makeLightsailConf` 生成这样一份配置：

```nix
{ config, pkgs, modulesPath, lib, ... }:
{
  imports = [ "${modulesPath}/virtualisation/amazon-image.nix" ];
  boot.loader.grub.device = lib.mkForce "/dev/nvme0n1";
}
```

两个问题：

- `amazon-image.nix` 的 `ec2.efi` 默认值是 `isAarch64`，x86_64 上为 false，于是
  `grub.efiSupport = false`，往 4 MB 的 `bios_grub` 分区装 BIOS GRUB。**UEFI 实例装完起不来。**
- 26.05 起默认 systemd-initrd，而 lustrate 只在 bash 版 stage-1 里，旧系统的 `/etc`、`/usr`
  不会被挪走，重启后网络起不来。

脚本的做法是先把自己的 `configuration.nix` 放进 `/etc/nixos/`——nixos-infect 的 `makeConf`
开头有一句「配置文件已存在就直接返回」，于是上面那份预设根本不会生成。

## 实测

四次真实转换，两个发行版、两种引导模式、两种内存档位：

| 镜像 | 引导 | 内存 | 磁盘 | 注入到重启 | 结果 |
|---|---|---|---|---|---|
| Ubuntu 24.04 | UEFI | 1906 MB | 60 GB | 2 分 53 秒 | 20 秒后 root 登录，失败单元 0 |
| Debian 13 | BIOS | 939 MB | 40 GB | 4 分 7 秒 | 20 秒后 root 登录，失败单元 0 |
| Ubuntu 24.04 | UEFI | 412 MB | 20 GB | 约 8 分钟 | 同上（早期手工验证轮） |
| Debian 13 | BIOS | 442 MB | 20 GB | 约 6 分钟 | 同上（早期手工验证轮） |

转换后清理：60 GB 盘 8.2 → 3.9 GB，40 GB 盘 8.9 → 3.9 GB。

早期两轮抓到的问题都已修掉：ESP 里的 `BOOTX64.EFI` 大小写、`/etc/nixos` 不存在时脚本自副本写不进去、
Debian 非 root 下 `blkid` 不在 PATH、`e2label` 改完 label 后 `lsblk` 因 udev 未刷新读到空值。

Lightsail 的分区布局（Ubuntu 和 Debian 都试过）：

```
Ubuntu:  p1 根 ext4   p14 4M   p15 ESP vfat /boot/efi   p16 /boot ext4
Debian:  p1 根 ext4   p14 3M   p15 ESP vfat /boot/efi（不使用，NixOS 里被挂到 /efi）
```

同一 AMI 重建实例时文件系统 UUID 不变，公网 IP 和 host key 会变。

## 支持与不支持

支持：x86_64、UEFI 或 BIOS、根分区为 ext4、Lightsail 能选到的 Ubuntu / Debian 云镜像。

不支持（脚本会直接停下，不生成半成品）：LVM、btrfs 子卷、LUKS、非 ext4 根；
其它发行版（CentOS 之类）没验证过。

`nixos-infect` 本身在老版本上也有记录：Debian 9/10/11、Ubuntu 20.04/22.04 都成功过。

## 为什么不用 nixos-anywhere

- Nitro 上 `kexec` 之后的行为不可靠（[issue #139](https://github.com/nix-community/nixos-anywhere/issues/139)：
  直接重启回原系统；当时猜是 2 GB 内存 OOM，最后以「请重试」关闭）。
- Lightsail 不支持导入自定义镜像，也就没法直接用 NixOS 官方 AMI。

只剩 `nixos-infect` 的 lustrate：在旧系统里装好 NixOS、写好标记，下次普通重启时由 stage-1
把旧系统整体挪走。设备正常复位，不涉及 kexec。

## 转换之后

脚本只负责把机器变成 NixOS。要交给自己的 flake 管理：

```nix
# flake.nix
nixosConfigurations.<名字> = nixpkgs.lib.nixosSystem {
  specialArgs = { inherit inputs; };
  modules = [ ./hosts/<名字> ];
};
```

`hosts/<名字>/hardware.nix` 直接用脚本生成的那份，`default.nix` 里 `imports` 它，然后：

```bash
nixos-rebuild switch --flake .#<名字> --target-host root@$IP
```

## 没有串口时怎么看到真相

Lightsail 不提供串口控制台，「内核没起来」和「起来了但没网」在外部表现一样。
排查办法是同区域、同机型再开一台 EC2，跑同样的步骤，用 `Get system log` 看串口：
成功时能看到 `<<< NixOS is now lustrating the root filesystem >>>`，失败时这句不出现。
看完 terminate，成本几毛钱。

## 文件

- [`lightsail-to-nixos.sh`](./lightsail-to-nixos.sh)：转换与清理脚本，`--help` 看全部选项

## 参考

- [nixos-infect](https://github.com/elitak/nixos-infect)
- `nixos/modules/system/boot/stage-1-init.sh` 的 `lustrateRoot`（仅存在于 26.05 及更早）
- [nixos-anywhere #139](https://github.com/nix-community/nixos-anywhere/issues/139)
