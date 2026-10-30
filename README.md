# Convert an AWS Lightsail instance to NixOS in place

No reinstall, no custom image import. One script turns a stock Ubuntu or Debian Lightsail
instance into NixOS on the same disk.

This repo contains exactly that script: [`lightsail-to-nixos.sh`](./lightsail-to-nixos.sh).

> 中文版：[README.zh-CN.md](./README.zh-CN.md)

## TL;DR

**The injection run must use `nixos-26.05` or older.**

`nixos-infect` relies on `lustrate`, which moves the old root filesystem into `/old-root`.
That logic only exists in the bash-based stage 1 (`lustrateRoot` in `stage-1-init.sh`).
NixOS 26.05 made systemd-initrd the default, and 26.11 removed the option entirely —
setting `boot.initrd.systemd.enable` now fails with "option has been removed".
Once the system is installed you can follow any channel you like.

## Usage

The default login user is `ubuntu` on Ubuntu images and `admin` on Debian images.

```bash
# 0. on your machine
IP=<public ip>; KEY=~/.ssh/aws-nix.pem

# 1. copy the script over (changes nothing)
scp -i $KEY lightsail-to-nixos.sh ubuntu@$IP:/tmp/

# 2. see what it is going to write (no root needed, no changes)
ssh -i $KEY ubuntu@$IP 'bash /tmp/lightsail-to-nixos.sh --dry-run'

# 3. inject. Rebooting happens automatically once the checks pass
ssh -i $KEY ubuntu@$IP 'sudo bash /tmp/lightsail-to-nixos.sh --yes'

# 4. after it comes back (~20 s), remove the leftover old system
ssh -i $KEY root@$IP '/etc/nixos/lightsail-to-nixos.sh --cleanup'

# 5. take the hardware description into your own flake
scp -i $KEY root@$IP:/etc/nixos/hardware.nix ./hosts/<name>/hardware.nix
```

If you want screenshots or a manual step in between, add `--no-reboot` to step 3.
The script prints the detected layout, the four pre-reboot checks and the UUIDs,
then waits for you to run `sudo systemctl reboot`.

## What the script does

**1. It reads the running system instead of assuming a version**

| Probe | Purpose |
|---|---|
| presence of `/sys/firmware/efi` | pick the UEFI or the BIOS branch |
| mount sources and UUIDs of `/`, `/boot`, the ESP | generate `fileSystems` |
| whether `/boot` is a separate mount | decide if `fileSystems."/boot"` is needed |
| `/home/{ubuntu,admin,debian}` | keep the cloud image's default user so the Lightsail console SSH still works |
| `authorized_keys` | refuse to run without a key, so you cannot lock yourself out |

**2. Preflight checks.** It stops if the root filesystem has less than 8 GB free (the old root
moves into `/old-root` on the same filesystem while the new closure is written next to it).
It also stops on a non-ext4 root, or a root on LVM/btrfs — those need extra initrd modules and
mount options that the script does not generate.

**3. Swap.** `MemTotal < 1024 MB` gets a 4 GB temporary swap file, otherwise 2 GB; an existing
swap is left alone. The converted system declares its own 2 GB `/var/swapfile`.

**4. It writes two files**

- `/etc/nixos/configuration.nix` — used for the injection, includes
  `boot.initrd.systemd.enable = false`, SSH, users and swap
- `/etc/nixos/hardware.nix` — a drop-in `hosts/<name>/hardware.nix`: boot loader, file systems,
  initrd modules and kernel parameters only

**5. It runs nixos-infect** with
`PROVIDER=lightsail NO_SWAP=1 NO_REBOOT=1 NIX_CHANNEL=nixos-26.05`,
logging to `/var/log/lightsail-to-nixos.log`.

**6. Four checks before rebooting.** If any of them fails, the machine is not rebooted:

```
[ok] /etc/NIXOS exists
[ok] /etc/NIXOS_LUSTRATE is staged
[ok] root partition label is "nixos"
[ok] ESP contains an EFI binary / or /boot/grub/grub.cfg points at NixOS
```

**7. `--cleanup`** removes `/old-root`, `/etc/NIXOS`, the injection config and old generations,
then garbage-collects the store. `hardware.nix` is kept, printed to the terminal, and an
`scp` command for it is shown.

Two re-runs are refused on purpose: with `/etc/NIXOS_LUSTRATE` still present the script skips
the injection and only re-checks (use `--force` to inject again), and on a machine that already
boots NixOS it tells you to use `--cleanup` instead.

## Why not the official one-liner

On Lightsail the official command is:

```bash
curl -fsSL https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect \
  | PROVIDER=lightsail NIX_CHANNEL=nixos-26.05 bash
```

It calls `makeLightsailConf`, which writes:

```nix
{ config, pkgs, modulesPath, lib, ... }:
{
  imports = [ "${modulesPath}/virtualisation/amazon-image.nix" ];
  boot.loader.grub.device = lib.mkForce "/dev/nvme0n1";
}
```

Two problems:

- In `amazon-image.nix`, `ec2.efi` defaults to `isAarch64`, so on x86_64 it is false:
  `grub.efiSupport = false`, and GRUB gets installed as BIOS GRUB into the 4 MB `bios_grub`
  partition. **A UEFI instance will not boot afterwards.**
- Since 26.05 the default is systemd-initrd, and `lustrateRoot` only exists in the bash stage 1.
  The old `/etc` and `/usr` are never moved away, and networking does not come up after reboot.

The script sidesteps both by placing its own `configuration.nix` in `/etc/nixos/` first:
`makeConf` in nixos-infect returns immediately when that file already exists, so the preset
above is never generated.

## Real-world results

Four conversions, two distributions, both firmware types, two memory tiers:

| Image | Firmware | RAM | Disk | Inject → reboot | Result |
|---|---|---|---|---|---|
| Ubuntu 24.04 | UEFI | 1906 MB | 60 GB | 2m53s | root login after 20 s, 0 failed units |
| Debian 13 | BIOS | 939 MB | 40 GB | 4m07s | root login after 20 s, 0 failed units |
| Ubuntu 24.04 | UEFI | 412 MB | 20 GB | ~8 min | same (early manual runs) |
| Debian 13 | BIOS | 442 MB | 20 GB | ~6 min | same (early manual runs) |

Post-conversion cleanup, measured: 8.2 → 3.9 GB used on the 60 GB disk, 8.9 → 3.9 GB on the 40 GB disk.

Bugs the early runs caught and that are fixed: the case of `BOOTX64.EFI` on the ESP,
`/etc/nixos` not existing when the script copies itself there, `blkid` missing from a
non-root `PATH` on Debian, and `lsblk` returning an empty label right after `e2label`.

Partition layouts seen on Lightsail (both Ubuntu and Debian):

```
Ubuntu:  p1 root ext4   p14 4M   p15 ESP vfat /boot/efi   p16 /boot ext4
Debian:  p1 root ext4   p14 3M   p15 ESP vfat /boot/efi (unused; NixOS mounts it at /efi)
```

Rebuilding an instance from the same AMI keeps the filesystem UUIDs; the public IP and the
SSH host keys change.

## Supported / not supported

Supported: x86_64, UEFI or BIOS, ext4 root, the Ubuntu and Debian cloud images Lightsail offers.

Not supported — the script stops instead of writing a config that will not boot: LVM, btrfs
subvolumes, LUKS, non-ext4 roots. Other distributions were not tested.

Upstream `nixos-infect` additionally has success reports on Debian 9/10/11 and Ubuntu 20.04/22.04.

## Why not nixos-anywhere

- `kexec` on Nitro is unreliable here
  ([issue #139](https://github.com/nix-community/nixos-anywhere/issues/139) reports it simply
  boots back into the original system; the suspected cause was OOM on 2 GB, and the issue was
  closed with "please retry").
- Lightsail does not support importing custom images, so the official NixOS AMI is not an option.

That leaves `nixos-infect`'s lustrate: install NixOS into the running system, stage a marker,
and let the next ordinary reboot move the old system out of the way. Devices are reset normally;
no kexec involved.

## After the conversion

The script only turns the machine into NixOS. To bring it under your own flake:

```nix
# flake.nix
nixosConfigurations.<name> = nixpkgs.lib.nixosSystem {
  specialArgs = { inherit inputs; };
  modules = [ ./hosts/<name> ];
};
```

Use the generated `hardware.nix` as `hosts/<name>/hardware.nix`, import it from
`hosts/<name>/default.nix`, then:

```bash
nixos-rebuild switch --flake .#<name> --target-host root@$IP
```

## Debugging without a serial console

Lightsail has no serial console, so "the kernel never started" and "it started but has no
network" look identical from the outside. The workaround: launch a second EC2 instance in the
same region with the same instance type, run the same steps, and read `Get system log`.
On success you will see `<<< NixOS is now lustrating the root filesystem >>>`; on failure the
line is missing. Terminate it afterwards — it costs cents.

## Files

- [`lightsail-to-nixos.sh`](./lightsail-to-nixos.sh) — conversion and cleanup; see `--help`

## References

- [nixos-infect](https://github.com/elitak/nixos-infect)
- `nixos/modules/system/boot/stage-1-init.sh`, `lustrateRoot` (26.05 and older only)
- [nixos-anywhere #139](https://github.com/nix-community/nixos-anywhere/issues/139)
