**English** | [中文](./README.zh-CN.md)

# Converting AWS Lightsail to NixOS in place — a field report

> Written from a real deployment in 2026-10. Goal: turn an **AWS Lightsail** instance
> (Sydney, `t3.small`, UEFI) from Ubuntu into NixOS 26.05 **in place**, without
> reinstalling the machine.
> This documents the **real hardware, the real parameters, the dead ends, and the fix** —
> not a "just follow X" second-hand tutorial.
>
> The fix is one line: **add `boot.initrd.systemd.enable = false;` to the config.** See §6.

---

## TL;DR

- A Lightsail instance is just an **EC2 `t3.small` (Nitro)** with **UEFI** boot and **in-tree**
  `nvme` + `ena` drivers — no exotic hardware.
- It **cannot** use `nixos-anywhere`/`disko`: on Nitro, ENA/NVMe are not re-initialized after
  `kexec` ([nixos-anywhere#139](https://github.com/nixos-anywhere/nixos-anywhere/issues/139)),
  and Lightsail does not allow importing custom images. The only path is **`nixos-infect`'s
  in-place "lustrate"** (takes effect on the next ordinary reboot).
- Symptom: **install finishes with `EXIT=0`, everything on disk is correct, yet after reboot SSH
  is permanently unreachable.** Lightsail has no serial console, so you cannot even tell whether
  it booted.
- **Root cause**: since NixOS 26.05, **`boot.initrd.systemd.enable` defaults to `true`**, while the
  `NIXOS_LUSTRATE` step that `nixos-infect` relies on (moving the old system to `/old-root` on first
  boot) is **only implemented in the bash stage-1** (`lustrateRoot`). systemd-initrd has none of it.
  So the old Ubuntu `/etc` and `/usr` stay in place → Ubuntu's systemd units
  (`systemd-networkd`/`systemd-resolved`/`dbus`…) leak into NixOS → **networking never comes up** →
  SSH is dead.
- **Fix**: set **`boot.initrd.systemd.enable = false;`** in the NixOS config so the bash stage-1
  runs and lustrate actually happens.

---

## 1. Understand the platform first — don't guess

Read it straight off the (working) Ubuntu instance — "everything is a file":

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
driver: ena            # in-tree kernel module
```

Key points:
- **The NIC is Amazon ENA and the disk is EBS NVMe — both driven by in-tree kernel modules.**
  There is no such thing as "a missing ENA driver" (I guessed in that direction early on; it was wrong).
- `t3.small` means Lightsail is a standard Nitro EC2 instance — officially supported by NixOS.

### Disk layout (Lightsail 2GB plan, 60GB disk)

```
nvme0n1        60G
├─nvme0n1p1    59G ext4   LABEL=cloudimg-rootfs   UUID=d662a37e-da8d-4720-94ff-f588450178c0   /        ← root
├─nvme0n1p14    4M
├─nvme0n1p15  106M vfat   LABEL=UEFI              UUID=876F-1C6F                              /boot/efi ← ESP
└─nvme0n1p16  913M ext4   LABEL=BOOT              UUID=71a1f8dc-6e9a-4e94-bf6b-9b1ea9866c4b   /boot
```

- Root PARTUUID = `047e559f-5363-4375-91d2-6aa49f34bcf7`
- Ubuntu's `fstab` uses `LABEL=…`; its kernel cmdline uses `root=PARTUUID=…`:
  `root=PARTUUID=047e559f-… ro console=tty1 console=ttyS0 nvme_core.io_timeout=4294967295 panic=-1`
- Ubuntu version: **Ubuntu 24.04.4 LTS (Noble Numbat)**, kernel **`7.0.0-1012-aws`**
- Firmware boot entries (`efibootmgr`):
  ```
  Boot0002* Ubuntu  HD(15,GPT,80149193-fbe8-43ee-8a33-5fa70634c9e2,…)/File(\EFI\ubuntu\shimx64.efi)
  Boot0001* UEFI Amazon Elastic Block Store … {auto_created_boot_option}
  ```

> **Recreating an instance from the same AMI keeps the filesystem UUIDs** (they are baked into the
> AMI snapshot); but the **public IP may change**, and the SSH host key changes — clear it with
> `ssh-keygen -R <IP>` before reconnecting.

---

## 2. Why not nixos-anywhere / disko

- Lightsail is **Nitro**: after `kexec`, ENA/NVMe devices are not re-initialized, so nixos-anywhere
  loses the machine (issue #139).
- Lightsail **does not allow importing custom images**, so you can't just use an official NixOS AMI
  the way you can on EC2.
- Conclusion: use [`nixos-infect`](https://github.com/elitak/nixos-infect)'s **lustrate** — install
  NixOS on the running system, write `/etc/NIXOS_LUSTRATE`, and let NixOS's stage-1 move the old
  system aside on the **next ordinary reboot** (devices reset normally).

### Do not use the `PROVIDER=lightsail` preset config as-is

nixos-infect's lightsail preset just `import`s `amazon-image.nix`, where `ec2.efi` defaults to
`isAarch64` — **`false` on x86_64, so it installs BIOS GRUB**, which is fatal for this UEFI machine.
So supply your **own config** (see §8) and use `PROVIDER=lightsail` only to trigger "relabel the root
partition to `nixos`".

---

## 3. Symptom: install succeeds, reboot loses the machine

```console
$ sudo env PROVIDER=lightsail NIX_CHANNEL=nixos-26.05 NO_REBOOT=1 bash -x ./nixos-infect
...
+ /nix/var/nix/profiles/system/bin/switch-to-configuration boot
installing the GRUB 2 boot loader into /boot/efi...
Installation finished. No error reported.
EXIT=0
```

`EXIT=0`, and every check passed:
- the ESP holds NixOS's `\EFI\BOOT\BOOTX64.EFI`;
- `/boot/kernels/` holds NixOS's `bzImage` and `initrd`;
- the root partition label was changed to `nixos`.

**Then reboot → SSH is forever `Connection timed out`.** After reboot, CPU shows a brief boot spike
then flatlines. Lightsail's browser SSH reports a generic error.

---

## 4. Why the cause stayed invisible

- **Lightsail gives you no serial console.** "Kernel never booted" and "booted but no network" look
  **identical** on Lightsail (CPU spike then zero), so you **cannot tell them apart**.
- From China, Sydney is blocked; through the local proxy (Clash TUN) the TCP connection looks
  "established" and then stalls at the banner exchange — **that signal is useless**.

Conclusion: you **must** get a machine where you can read the boot log.

---

## 5. Borrowing EC2 as "eyes"

Launch an EC2 instance in the **same region (Sydney), same type (`t3.small`), same Ubuntu (24.04)** —
its disk layout is **identical** to Lightsail (p1 root + p15 ESP + p16 /boot, UEFI), but it has
**`Get system log` (serial) + `Get instance screenshot`**.

Run the same nixos-infect (without touching NVRAM), reboot, and read the serial log — **the truth at last**:

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

Two crucial facts:
1. **NixOS actually booted fully** (kernel, initrd, root mount, switch root, multi-user all OK) — so
   "the install on disk" was never the problem.
2. **All the failing units are Ubuntu's** (`snapd`/`apport`/`chrony`/`rsyslog`/`networkd-dispatcher`…),
   and the network units (`systemd-networkd`/`resolved`) failed too → **no IP → no SSH**.

**Old Ubuntu systemd units leaked in** — that's the clue.

---

## 6. Root cause (verifiable in the source)

Checking the nixpkgs source:

- The definition of `boot.initrd.systemd.enable` (`nixos/modules/system/boot/systemd/initrd.nix`):
  ```nix
  enable = mkEnableOption "systemd in initrd" // {
    default = true;   # ← default since NixOS 26.05
    ...
  ```
- But the `NIXOS_LUSTRATE` handler **`lustrateRoot`** exists only in the **bash stage-1**
  (`nixos/modules/system/boot/stage-1-init.sh`):
  ```sh
  [ "$mountPoint" == "/" ] && [ -f "/mnt-root/etc/NIXOS_LUSTRATE" ] && lustrateRoot "/mnt-root"
  ```
  The entire `nixos/modules/system/boot/systemd/` directory contains **no `LUSTRATE`/`lustrate` at all**.

**Full causal chain:**
```
NixOS 26.05 defaults to systemd-initrd
   → first boot no longer runs lustrateRoot in stage-1
   → old Ubuntu /etc and /usr are never moved to /old-root
   → Ubuntu's systemd units leak into NixOS
   → systemd-networkd/resolved etc. fail on conflict
   → no IP → no SSH
```
This also explains the community adage "**26.05 images don't come up, 25.11 works**" — 25.11 didn't
default to systemd-initrd yet.

(Corroborating evidence: on the working install, nixos-infect prints
`evaluation warning: Scripted initrd is deprecated and scheduled for removal in 26.11`, and the
serial log shows `<<< NixOS is now lustrating the root filesystem (cruft goes to /old-root) >>>`.
On the failing boots, that lustrate line was **absent**.)

---

## 7. The fix: one line

Add to the NixOS config:

```nix
boot.initrd.systemd.enable = false;
```

Disabling systemd-initrd returns to the bash stage-1, `lustrateRoot` runs, the old system is archived
to `/old-root`, NixOS gets a clean `/etc`, and networking works again.

---

## 8. Full config (`bootstrap.nix`)

Self-contained: explicit UEFI, ESP mounted at `/boot/efi`, filesystems referenced by UUID. This is
also the content of `hosts/lightsail/bootstrap.nix` in the author's flake.

```nix
# AWS Lightsail in-place install config (used by nixos-infect).
{ lib, pkgs, ... }:

{
  # Boot: UEFI + removable fallback path (EFI/BOOT/BOOTX64.EFI); ESP at /boot/efi, kernel on a separate /boot
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev";
  };
  boot.loader.efi.efiSysMountPoint = "/boot/efi";

  # [CRITICAL] systemd-initrd MUST be off!
  # Since NixOS 26.05 boot.initrd.systemd.enable defaults to true, but the NIXOS_LUSTRATE
  # step nixos-infect relies on (moving the whole old system to /old-root on first boot)
  # exists ONLY in the bash stage-1 (stage-1-init.sh's lustrateRoot); systemd-initrd has
  # none of it. If left on, the first boot never moves the old Ubuntu /etc and /usr aside,
  # Ubuntu's systemd units (systemd-networkd/resolved/dbus …) leak in, and networking dies.
  boot.initrd.systemd.enable = false;

  # Refer to disks by UUID (nixos-infect relabels the root partition to "nixos"; UUID is unchanged)
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

  # AWS Nitro (NVMe + ENA)
  boot.initrd.availableKernelModules = [
    "nvme" "ena" "virtio_pci" "virtio_blk" "sd_mod" "uas"
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

  # Reuse your AWS key pair (put the public key here; keep the private key local)
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAA...<YOUR_SSH_PUBLIC_KEY>"
  ];
  # Lightsail's browser SSH logs in as user "ubuntu"; create one as a health probe
  users.users.ubuntu = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAA...<YOUR_SSH_PUBLIC_KEY>"
    ];
  };

  # ~1.9GiB RAM → add a 2GiB swapfile
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

> Replace the three UUIDs with what `blkid` reports on your machine (usually identical for the same
> AMI, but **always verify**). The repo ships the same file as [`bootstrap.nix`](./bootstrap.nix).

---

## 9. Reproducible steps

Assumes a **fresh Ubuntu** instance, already reachable over SSH, with the matching private key locally.

```bash
IP=<your-public-ip>; KEY=<your-private-key>; U=ubuntu   # fresh Ubuntu uses the ubuntu user

# 0) Clear a stale host key locally (if the instance was recreated)
ssh-keygen -R "$IP"

# 1) Back up the original ESP as a fallback
ssh -i "$KEY" $U@$IP 'sudo mkdir -p /root/backup && \
  sudo tar czf /root/backup/esp-ubuntu.tgz -C /boot/efi . && \
  sudo efibootmgr -v | sudo tee /root/backup/efibootmgr.before.txt >/dev/null'

# 2) Drop in the config
ssh -i "$KEY" $U@$IP 'sudo mkdir -p /etc/nixos && sudo tee /etc/nixos/configuration.nix >/dev/null' < bootstrap.nix

# 3) Clone nixos-infect
ssh -i "$KEY" $U@$IP 'cd ~ && rm -rf nixos-infect && \
  git clone --depth 1 https://github.com/elitak/nixos-infect nixos-infect'

# 4) In-place install (NO_REBOOT=1: don't reboot yet, so you can inspect)
ssh -i "$KEY" $U@$IP 'sudo env PROVIDER=lightsail NIX_CHANNEL=nixos-26.05 NO_REBOOT=1 \
  bash ~/nixos-infect/nixos-infect'

# 5) Reboot once everything checks out
ssh -i "$KEY" $U@$IP 'sudo systemctl reboot'
```

After reboot, log in as **root** (via the public key in the config):

```bash
ssh -i "$KEY" root@$IP 'nixos-version'
```

Day-to-day rebuilds (from the local flake repo):

```bash
nixos-rebuild switch --flake .#lightsail --target-host lightsail
```

---

## 10. Verification (after the fix)

Identical on both Lightsail and EC2:

```
nixos-version : 26.05.11576.7c8764b7c7b0 (Yarara)     kernel: 6.18.55
systemctl --failed : 0 loaded units listed
ip -4 -br a   : ens5  UP  172.26.1.140/20
curl cache.nixos.org : -> 200
lsblk         : p1 59G ext4 nixos /   p15 106M vfat UEFI /boot/efi   p16 913M ext4 BOOT /boot
free -h       : Swap 2.0Gi
ls /old-root  : bin etc usr var snap …   ← the old Ubuntu, fully archived
```

The serial log shows the decisive step:

```
<<< NixOS is now lustrating the root filesystem (cruft goes to /old-root) >>>
Moving impurities out of the way: '/mnt-root/etc' -> '/mnt-root/old-root.tmp/etc' ...
```

---

## 11. Gotchas

1. **Do not remove `boot.initrd.systemd.enable = false;`.** It is the crux of nixos-infect-style
   in-place installs on 26.05.
2. **The 26.11 landmine**: the log warns `Scripted initrd is deprecated and scheduled for removal in
   26.11`. Already-installed systems are unaffected, but if 26.11 really removes the bash initrd,
   nixos-infect-style in-place installs break again — you'd need another approach (official AMI or
   another migration path).
3. **You do not need to touch NVRAM.** I once manually added a boot entry pointing at
   `\EFI\BOOT\BOOTX64.EFI` as "double insurance"; later, on EC2, I verified that **even with a stale
   `Boot0002` still pointing at the deleted `\EFI\ubuntu\shimx64.efi`, the firmware falls back to the
   removable path `\EFI\BOOT\BOOTX64.EFI` on its own**. So the final procedure leaves NVRAM alone.
4. **`--target-host` and the GC root**: `nixos-rebuild --target-host` builds locally and copies to the
   remote; the **GC root lives on the remote**, so the local closure is unrooted and may be collected
   by a local nightly GC, forcing rebuilds. Keep a local root:
   ```bash
   nix build .#nixosConfigurations.lightsail.config.system.build.toplevel -o ~/nixos-lightsail
   ```
5. **Lightsail has no serial console.** To debug boot/early-startup problems, spin up an EC2 twin in
   the **same region, same type, same Ubuntu** and use `Get system log` / `Get instance screenshot`;
   `terminate` it when done — it costs cents.
6. **Recreated instances**: for the same AMI the **filesystem UUIDs are unchanged**, but the **public
   IP and SSH host key change**. A `~/.ssh/config` alias can stay fixed, but update the IP.
7. **"Everything is a file" saves you a lot**: `/sys/class/net/*/device/{vendor,device,driver}`,
   `/sys/firmware/efi`, `blkid`, `lsblk`, `efibootmgr`, `dmesg`, `lsmod` — read the real
   hardware/layout first, **then act. Don't guess.**

---

## 12. References

- nixos-infect: <https://github.com/elitak/nixos-infect>
- nixos-anywhere issue #139 (ENA/NVMe not re-initialized after Nitro kexec):
  <https://github.com/nixos-anywhere/nixos-anywhere/issues/139>
- nixpkgs `boot.initrd.systemd.enable` (default true):
  `nixos/modules/system/boot/systemd/initrd.nix`
- nixpkgs `lustrateRoot` (bash stage-1 only): `nixos/modules/system/boot/stage-1-init.sh`
- NixOS manual: the `NIXOS_LUSTRATE` mechanism
