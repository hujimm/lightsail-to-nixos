# 把 AWS Lightsail 就地转成 NixOS

不重装、不导入镜像，在原 Ubuntu 上就地换成 NixOS。

一句话结论：**注入这一遍必须用 `nixos-26.05`**。`nixos-infect` 靠 `lustrate` 把旧系统挪进
`/old-root`，而这段逻辑只实现在 bash 版 stage-1 里；26.11 起 scripted initrd 被删除，
`boot.initrd.systemd.enable` 直接变成一条 assertion 错误，脚本走不到最后。装好之后想切哪个
channel 都行，与这一点无关。

## 平台事实

Lightsail 就是标准 Nitro EC2，从能 SSH 的 Ubuntu 里直接读：

```console
$ sudo dmidecode -s system-product-name     # t3.small
$ [ -d /sys/firmware/efi ] && echo UEFI
$ sudo lspci -nnk | grep -A2 "Non-Volatile memory"   # nvme
$ ethtool -i ens5 | head -1                 # driver: ena
```

`nvme` 和 `ena` 都是内核自带驱动，不存在"缺 ENA 驱动"这回事。

Ubuntu 24.04 AMI 的分区（Lightsail 各套餐相同，只是容量不同）：

```
nvme0n1
├─p1    ext4  /              LABEL=cloudimg-rootfs
├─p14    4M
├─p15  vfat  /boot/efi       LABEL=UEFI           ← ESP
└─p16  ext4  /boot           LABEL=BOOT           ← 独立 /boot，913M
```

同一 AMI 重建实例时文件系统 UUID 不变，公网 IP 和 host key 会变。

## 为什么不用 nixos-anywhere / disko

- Nitro 上 `kexec` 之后 ENA/NVMe 不会重新初始化，nixos-anywhere 直接失联
  （[issue #139](https://github.com/nixos-anywhere/nixos-anywhere/issues/139)）。
- Lightsail 不支持导入自定义镜像，也就没法直接用 NixOS 官方 AMI。

只剩 `nixos-infect` 的 lustrate：在旧系统里装好 NixOS、写好标记，**下次普通重启**时由
stage-1 把旧系统整体挪走。

## 唯一容易踩的地方

配置里必须有：

```nix
boot.initrd.systemd.enable = false;
```

不写的症状是安装全程 `EXIT=0`、盘上一切正确、重启后却永远连不上。原因是 26.05 起
systemd-initrd 成为默认，而 `lustrateRoot` 只存在于 `stage-1-init.sh`，systemd-initrd
里没有对应实现——旧 Ubuntu 的 `/etc`、`/usr` 留在根上，`systemd-networkd`/`resolved`
等单元泄漏进来，网络起不来。串口里能直接看到这些 Ubuntu 单元报 `[FAILED]`。

## 步骤

```bash
IP=<公网 IP>; KEY=<私钥>; U=ubuntu

# 0.5 GB 机型（t3.nano）先加 4 GB swap：脚本自带 1 GB，而求值阶段 swap 峰值用到 800 MB 上下
ssh -i $KEY $U@$IP 'sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile \
  && sudo mkswap /swapfile && sudo swapon /swapfile'

# 放配置：改掉三个 UUID 和公钥
ssh -i $KEY $U@$IP 'sudo mkdir -p /etc/nixos'
ssh -i $KEY $U@$IP 'sudo tee /etc/nixos/configuration.nix >/dev/null' < bootstrap.nix

# 注入。NO_SWAP=1 用我们自己加的 swap；NO_REBOOT=1 先看清楚日志再重启
ssh -i $KEY $U@$IP 'sudo env PROVIDER=lightsail NO_SWAP=1 NO_REBOOT=1 \
  NIX_CHANNEL=nixos-26.05 bash -x \
  <(curl -fsSL https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect)'

# 日志末尾出现 "The new configuration is ..." 后再重启
ssh -i $KEY $U@$IP 'sudo systemctl reboot'
```

重启后用 root 登录，然后清掉转换留下的一次性东西：

```bash
rm -rf /old-root
nix-env --delete-generations old --profile /nix/var/nix/profiles/system
nix-collect-garbage -d
```

之后这台机器就是普通 NixOS，日常重建照旧：

```bash
nixos-rebuild switch --flake .#<host> --target-host root@$IP
```

`PROVIDER=lightsail` 只用来让脚本把根分区 label 改成 `nixos`，配置走自己的
`bootstrap.nix`——脚本自带的 lightsail 预设会 `import amazon-image.nix`，而 `ec2.efi`
在 x86_64 上是 `false`，会去装 BIOS GRUB。

## 没有串口时怎么看到真相

Lightsail 不提供串口，"内核没起来"和"起来了但没网"在外部表现完全一样。排查办法是同区域、
同机型再开一台 EC2，跑同样的步骤，用 `Get system log` 看串口——成功时能看到
`<<< NixOS is now lustrating the root filesystem >>>`，失败时这句不出现。看完就 terminate，
成本几毛钱。

## 文件

[`bootstrap.nix`](./bootstrap.nix)：注入用的单文件配置，占位符换成自己的值。

## 参考

- [nixos-infect](https://github.com/elitak/nixos-infect)
- [nixos-anywhere #139](https://github.com/nixos-anywhere/nixos-anywhere/issues/139)
- `nixos/modules/system/boot/stage-1-init.sh` 的 `lustrateRoot`
