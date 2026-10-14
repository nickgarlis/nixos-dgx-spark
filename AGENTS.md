# AGENTS.md

How this repo is maintained. Follow it exactly; the rules exist because the
obvious shortcuts produced wrong settings before.

## Goal

A NixOS hardware profile that reproduces **what DGX OS ships on the DGX
Spark** (GB10), hardware only, in [nixos-hardware] style, so it can be
upstreamed there. Not a CUDA, container or inference stack.

## Sources of truth

Only NVIDIA's shipped artifacts count as upstream. In order:

1. **The Spark OTA manifest** — `opt/nvidia/spark-ota-check/metadata/spark-ota-<release>.json`
   in the `nvidia-spark-ota-check` package. It lists the packages a Spark
   actually has. A package in NVIDIA's repo but not in this manifest (or in
   `dgx-spark-ota-update-meta`'s `Depends`) is not evidence of Spark behaviour.
   Per-platform values (kernel parameters, console, swap, kdump) come from
   the `dgx_spark` entry in `etc/nvidia-platform.d/nvidia-platform-configs.json`
   (`nv-common-apis`), which NVIDIA's first-boot scripts read — a package's
   name or another platform's table entry is not evidence for the Spark. The
   scripts pick the entry by DMI system family (`"DGX Spark"`), which OEM
   models such as the ASUS GX10 also report, so it applies to all of them.
2. **NVIDIA's BaseOS apt repo** —
   `https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/`, suites
   `noble` and `noble-updates`, components `common` and `dgx`. The files inside
   each `.deb` are the settings.
3. **Ubuntu's packages that make up DGX OS's kernel and driver** (Launchpad /
   `ports.ubuntu.com`, `noble-updates`):
   - `linux-nvidia-7.0` — the kernel. Its build config is
     `usr/lib/linux/<abi>-nvidia/config` in `linux-buildinfo-<abi>-nvidia`;
     its module list is `usr/lib/linux/<abi>-nvidia/modules` in the same
     package. `linux-modules-<abi>-nvidia` installs
     `/lib/modprobe.d/blacklist_linux-nvidia-7.0_<abi>-nvidia.conf`.
   - `nvidia-graphics-drivers-580` — the driver. Its packages carry settings
     too: `nvidia-kernel-common-580` installs `modprobe.d` options and
     `udev/rules.d/71-nvidia.rules`. Link these as `ports.ubuntu.com` pool URLs
     of the exact version.
4. **NVIDIA's source trees**, at the tag of the release DGX OS ships:
   - [NVIDIA/NV-Kernels] at `Ubuntu-nvidia-7.0-<version with ~ as _>`:
     kernel source, and Ubuntu packaging under `debian.nvidia-7.0/`
     (`modprobe.d/`, `dkms-versions`, `config/annotations`).
   - [NVIDIA/open-gpu-kernel-modules] at the driver version tag.
5. **nixpkgs** — only for how NixOS does something (option semantics, module
   behaviour), never for what the hardware needs.

A few values live only in the DGX OS installer image (e.g. the serial
console device in its `/etc/default/grub`), not in any package. Take those
from a real DGX OS install (`/proc/cmdline`, `/etc/default/grub`), say so in
the comment ("observed on DGX OS, kernel <abi>"), and prefer NVIDIA's image
itself as the citation once available. One machine's observations cover that
model and image version only.

Never cite another community project as a source in code, comments or the drift
check. Credit borrowed work only in README.md → Credits.

## Rules for `default.nix`

- **Every setting cites its source** in a comment directly above it:
  - the NVIDIA package (versioned `.deb` pool URL) and the file inside it that
    does the same thing (e.g. `etc/modprobe.d/cppc_cpufreq.conf`), and
  - where a kernel parameter, module or module option is involved, the
    defining source line(s), with a line anchor.
- **Link formats**: NV-Kernels by **tag name**, not commit
  (`/blob/Ubuntu-nvidia-7.0-…/path#Lx-Ly`; release commits are tag-only, so
  commit links show GitHub's "does not belong to any branch" warning).
  open-gpu-kernel-modules by driver version tag (`/blob/580.178.04/…`).
  nixpkgs by full commit hash.
- **Mirror DGX OS's mechanism, not just the effect.** If DGX OS sets a module
  option in `modprobe.d`, use `boot.extraModprobeConfig`, not a kernel
  parameter; a module alias stays an alias, not a blocklist entry. Keep kernel
  parameters in DGX OS's order where it matters (the last `console=` is
  `/dev/console`).
- **When DGX OS runs a script, package NVIDIA's script** from its `.deb` (see
  `connectx7-hotplug.nix`, `nvme-interrupt-coalescing.nix`: extract, patch
  paths, wrap `PATH`) and copy its systemd unit — don't reimplement the logic.
- **No claims without an NVIDIA source.** No performance numbers, no "X breaks
  without this", no reasoning copied from other projects. A comment says what
  the setting is and where DGX OS does it.
- **Deviations from DGX OS** are allowed only for NixOS/Nix mechanics, and must
  cite the nixpkgs line that forces them (e.g. the driver modules'
  `allowedReferences = [ ]`, which `scrubKernelDevRefs` works around).
- **nixos-hardware style**: `lib.mkDefault` on scalar options; lists and
  attrsets merge (no `mkDefault` needed); no flake inputs; no opinionated
  non-hardware choices — those belong to the consuming system, not here.
- Comments explain _what_ and _why_, briefly. No attribution, no history, no
  homelab-specific notes.

## Verifying a setting before adding it

1. Confirm the package is on a Spark: present in the latest
   `spark-ota-*.json` (step 1 above) or in `dgx-spark-ota-update-meta`'s
   `Depends`.
2. Download and unpack the `.deb`, and read the file — don't infer from the
   package name or description:
   ```bash
   curl -sO <pool URL>; ar x <pkg>.deb; tar xf data.tar.*
   ```
3. For kernel options, read the shipped config (`linux-buildinfo`); for
   modules, check the shipped module list; for kernel packaging files, read
   them at the release tag in NV-Kernels.
4. Check the NixOS side in nixpkgs source (what the option actually emits —
   e.g. `hardware.nvidia.modesetting` sets `nvidia-drm modeset=1 fbdev=1`).
5. Check every new URL resolves:
   ```bash
   grep -oE 'https://[^ ]+' default.nix | sed 's/#.*//' | sort -u |
     while read u; do echo "$(curl -s -o /dev/null -w '%{http_code}' -L -r 0-0 "$u") $u"; done
   ```
6. `nix flake check`, and evaluate the result, e.g.
   `nix eval --impure -f build.nix --argstr nixpkgs <ref> kernel.outPath`.
7. Compare the evaluated `boot.kernelParams` with a DGX OS `/proc/cmdline`:
   the only differences should be bootloader/root, splash (`quiet splash
   vt.handoff=7`), `crashkernel` while kdump is off on DGX OS, and NixOS's own
   parameters.

## Drift check

`.github/workflows/upstream.yml` pins what the profile was last reconciled
against; `make check-upstream` runs the same check locally. It covers:

- `UBUNTU_PACKAGES`: `linux-nvidia-7.0`, `nvidia-graphics-drivers-580`
  (`noble-updates` versions).
- `BASEOS_PACKAGES`: the DGX OS release metapackage and **every BaseOS package
  `default.nix` mirrors**. Adding a mirrored setting means adding its package
  here; removing one means removing it.

Keep the script small: one lookup per source, one compare. Don't add checks
that another check already implies. Anything read from a specific kernel
release (its build config, `debian.nvidia-7.0/` files) can only change when
the `linux-nvidia-7.0` version does — published versions are immutable — so
it's covered by that check and reconciled in the kernel steps below.

## When the drift check fails

- **A BaseOS package changed**: unpack old and new `.deb`, diff the contents,
  update `default.nix` (setting, `.deb` URL), bump the pin.
- **The DGX OS release metapackage changed**: diff its `Depends` and the new
  `spark-ota-*.json`; review every added or removed package with the steps
  above.
- **The kernel changed** (`linux-nvidia-7.0`):
  1. Pin the new tag's commit and hash in `kernel-source.nix`.
  2. Diff the old and new release's build config
     (`usr/lib/linux/<abi>-nvidia/config` in `linux-buildinfo-<abi>-nvidia`)
     and regenerate `kernel-config.nix` from the new one: the options that
     differ from NixOS defaults.
  3. Diff `debian.nvidia-7.0/modprobe.d/common.conf` and
     `debian.nvidia-7.0/dkms-versions` between the old and new tag; mirror
     changes to the blocklist and to `mstflint_access`.
  4. Move every NV-Kernels link in `default.nix` to the new tag and re-check
     each anchored line still points at the right code.
  5. Bump the `linux-nvidia-7.0` version in `UBUNTU_PACKAGES`.
- **The driver changed**: check nixpkgs' `nvidiaPackages.legacy_580` follows,
  and whether DGX OS moved to another branch. Diff the old and new
  `nvidia-kernel-common-580` (`modprobe.d`, `71-nvidia.rules`) and mirror
  changes; move the open-gpu-kernel-modules and `ports.ubuntu.com` links in
  `default.nix` to the new version.

## Building

`make build NIXPKGS=github:NixOS/nixpkgs/<rev>` builds the two things this
profile compiles (NVIDIA kernel, driver kernel module). Build on aarch64 (a
Spark); under emulation the kernel takes hours. A binary cache only serves
systems on the same nixpkgs revision. Push only GPL/MIT outputs (kernel, open
driver module) to the public cache, not NVIDIA-licensed binaries.

## Testing limits

Evaluation is not proof. Anything touching boot, drivers or modules is only
verified once it has run on a Spark; say so when reporting a change. The
README's warning says the profile is untested: once it has run on hardware,
update it to name the models and DGX OS/kernel versions it was tested against.

[nixos-hardware]: https://github.com/NixOS/nixos-hardware
[NVIDIA/NV-Kernels]: https://github.com/NVIDIA/NV-Kernels
[NVIDIA/open-gpu-kernel-modules]: https://github.com/NVIDIA/open-gpu-kernel-modules
