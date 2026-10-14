# nixos-dgx-spark

NixOS hardware support for NVIDIA GB10 (Grace Blackwell, aarch64) systems:
the NVIDIA DGX Spark, the ASUS Ascent GX10 and other GB10 boxes. Written in
[nixos-hardware] style (`lib.mkDefault`, no flake inputs) with the aim of
upstreaming it there.

> [!WARNING]
> **Untested, and largely AI-written.** This profile was scaffolded with heavy
> use of AI coding tools and has not yet been run on real hardware — so far it
> has only been evaluated, not booted. Every setting cites the NVIDIA source it
> mirrors, but expect bugs: review the configuration before relying on it, and
> keep a way back to DGX OS (a recovery image) when installing.

Not to be confused with [graham33/nixos-dgx-spark], which this builds on (see
Credits) and which also provides CUDA overlays, playbooks and a vLLM module.
This repo is hardware support only.

## Usage

```nix
{
  inputs.nixos-dgx-spark.url = "github:nickgarlis/nixos-dgx-spark";

  outputs = { nixpkgs, nixos-dgx-spark, ... }: {
    nixosConfigurations.my-gx10 = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        nixos-dgx-spark.nixosModules.asus-ascent-gx10 # or .nvidia-dgx-spark — same profile
        { nixpkgs.config.allowUnfree = true; }
        ./configuration.nix
      ];
    };
  };
}
```

## Binary cache

The NVIDIA kernel and the driver's kernel module have to be compiled; builds
of them are pushed to [nixos-dgx-spark.cachix.org]:

```nix
nix.settings = {
  extra-substituters = [ "https://nixos-dgx-spark.cachix.org" ];
  extra-trusted-public-keys = [ "nixos-dgx-spark.cachix.org-1:DmhfkXVHl1C+CocD9A/PoJRJgeRumBnF3BRWEWWJvLA=" ];
};
```

A hit needs the exact derivation that was pushed — the same nixpkgs revision
and profile version — so it helps most on a matching nixpkgs; otherwise the
kernel compiles as usual.

To build them yourself (on aarch64, e.g. a Spark — under emulation the kernel
takes hours), against the nixpkgs revision of the systems that will use them:

```bash
make build NIXPKGS=github:NixOS/nixpkgs/<rev>
cachix push nixos-dgx-spark $(make -s build NIXPKGS=github:NixOS/nixpkgs/<rev>)  # maintainers
```

## What the profile does

Reproduces what DGX OS ships on the Spark — every setting in `default.nix`
links the NVIDIA package (or kernel source) it comes from:

- **Kernel**: NVIDIA's DGX Spark kernel ([NVIDIA/NV-Kernels], pinned in
  `kernel-source.nix`) with the config DGX OS's kernel is built with
  (`kernel-config.nix`). Compiled unless a binary cache has the exact
  derivation; build on the Spark itself (`nixos-rebuild --build-host`) rather
  than under emulation, or use the binary cache above.
- **Driver**: open kernel modules, R580 (`nvidiaPackages.legacy_580`), the
  branch DGX OS ships; nvidia-drm modesetting off, nvidia-persistenced on,
  video memory preserved across suspend and GPU runtime power management, as
  on DGX OS.
- **Kernel command line** (`pci=pcie_bus_safe`,
  `initcall_blacklist=tegra234_cbb_init`, `kho=off`, `init_on_alloc=0`,
  `iommu.passthrough=0`, `earlycon=…`, consoles incl. `ttyS0,921600`) —
  matches DGX OS's `/proc/cmdline` apart from bootloader, splash and kdump
  (off on DGX OS) — **module settings**
  (`cppc_cpufreq auto_sel_mode=1`, RTL8127 → `r8127`, `sbsa_gwdt action=1`,
  `mstflint_access` loaded) and **module blocklist** (`snd-mixer-oss`,
  `snd-pcm-oss`, `coresight_etm4x`, `nouveau`).
- **System settings** DGX OS applies: memlock unlimited, 500000 open files,
  `performance` CPU governor, ARP sysctls, a 16G swap file at `/swap.img`,
  NVMe interrupt coalescing (NVIDIA's script; Samsung/Kioxia/Micron only).
- **Firmware** (`enableRedistributableFirmware`, `fwupd`) and **ConnectX-7
  hot-plug** power management.
- Optional `hardware.nvidia-dgx-spark.rdma.enable` for multi-node RDMA over the
  QSFP ports (rdma-core udev rules and tools).

Not included, on purpose: CUDA (`nixpkgs.config.cudaSupport`,
`cudaCapabilities`), container runtimes / `nvidia-container-toolkit`,
inference servers, QSFP addressing.

## Installing

Only DGX OS boots on the factory firmware: update firmware from DGX OS first
(`sudo fwupdmgr refresh && sudo fwupdmgr update`), then disable Secure Boot.
The installer must also use this kernel — stock aarch64 kernels have trouble
with the onboard Ethernet.

## Driver choice

R580 supports CUDA up to 13.0, which covers containers built on CUDA ≤ 13.0
and nixpkgs' default CUDA. Software built against a newer toolkit needs a
newer branch (the driver can't JIT newer PTX):

```nix
hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.latest;
```

## Updating the kernel

The kernel follows what DGX OS ships: Ubuntu's `linux-nvidia-7.0` package,
built from [NVIDIA/NV-Kernels] and tagged there per release
(`Ubuntu-nvidia-7.0-<version>`).

- `kernel-source.nix` pins that tag's commit.
- `kernel-config.nix` is the config DGX OS's kernel was built with —
  `usr/lib/linux/<abi>-nvidia/config` in Ubuntu's `linux-buildinfo-<abi>-nvidia`
  package for that version ([7.0.0-1019](http://ports.ubuntu.com/ubuntu-ports/pool/main/l/linux-nvidia-7.0/linux-buildinfo-7.0.0-1019-nvidia_7.0.0-1019.19~24.04.2_arm64.deb)) —
  reduced to the options that differ from NixOS defaults.

To bump: pin the new tag in `kernel-source.nix`, regenerate
`kernel-config.nix` from the new release's `linux-buildinfo` config, and move
the NV-Kernels source links in `default.nix` to the new tag.

## Upstream tracking

`.github/workflows/upstream.yml` runs daily and fails when NVIDIA ships
something this profile mirrors: a new DGX OS kernel (`linux-nvidia-7.0`) or
driver (`nvidia-graphics-drivers-580`) in Ubuntu noble-updates, a new DGX OS
release (`dgx-spark-ota-update-meta`), or a new version of a DGX OS
configuration package that `default.nix` mirrors (NVIDIA's BaseOS repo). The
pinned versions are the workflow's `env`; after updating the profile for a
change, bump them there. `make check-upstream` runs the same check locally.

## Credits

Much of this work is based on [graham33/nixos-dgx-spark](https://github.com/graham33/nixos-dgx-spark) by Graham Bennett
and contributors.

That project also provides CUDA overlays, playbooks and a vLLM module on top
of the hardware support.
