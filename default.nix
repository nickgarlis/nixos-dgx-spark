# NVIDIA DGX Spark platform (GB10 Grace Blackwell, aarch64): the DGX Spark
# itself and OEM variants such as the ASUS Ascent GX10.
#
# Hardware support only, aiming to reproduce DGX OS's supported stack: NVIDIA's
# kernel, the R580 driver branch NVIDIA supports on the Spark, DGX OS's kernel
# command line, firmware and ConnectX-7 hot-plug. No CUDA, containers or
# inference stack — see README.md. Written in nixos-hardware style (mkDefault,
# no flake inputs) so it can be upstreamed there.
#
# Needs `nixpkgs.config.allowUnfree` (NVIDIA driver, hot-plug helper).
{ config, lib, pkgs, ... }:

let
  cfg = config.hardware.nvidia-dgx-spark;

  # Plain import, not callPackage: its `kernelPatches` argument (nixpkgs' patch
  # set) would otherwise collide with buildLinux's own `kernelPatches` list
  # when the kernel is overridden.
  nvidiaKernelPackages = pkgs.linuxPackagesFor (import ./kernel.nix {
    inherit (pkgs) lib buildLinux fetchFromGitHub kernelPatches;
  });

  # nixpkgs builds the driver's kernel modules with `allowedReferences = [ ]`,
  # but this kernel leaks paths to its `dev` output (build tree) into the .ko
  # files (__FILE__ strings from inlined headers), which fails that check.
  # Strip those strings.
  # https://github.com/NixOS/nixpkgs/blob/8ce4ef6cb6f871616146b9fe26d2a5ae594e94fe/pkgs/os-specific/linux/nvidia-x11/kernel-modules.nix#L54
  scrubKernelDevRefs = drv: drv.overrideAttrs (old: {
    postFixup = (old.postFixup or "") + ''
      if [ -d "$out/lib/modules" ]; then
        find $out/lib/modules -name '*.ko' -print0 \
          | xargs -0 -r ${pkgs.removeReferencesTo}/bin/remove-references-to \
              -t ${config.boot.kernelPackages.kernel.dev}
      fi
    '';
  });
in
{
  options.hardware.nvidia-dgx-spark = {
    rdma.enable = lib.mkEnableOption ''
      RDMA over the ConnectX-7 QSFP ports (multi-node NCCL/RoCE): rdma-core's
      udev rules (DGX OS's device names, e.g. rocep1s0f0, and access to
      /dev/infiniband) and its tools
    '';
  };

  config = {
    # Upstream: replace with nixos-hardware's ../../common/gpu/nvidia/blackwell
    # (open driver + videoDrivers), which this mirrors.
    services.xserver.videoDrivers = lib.mkDefault [ "nvidia" ];

    boot.kernelPackages = lib.mkDefault nvidiaKernelPackages;

    hardware.nvidia = {
      # Blackwell requires the open kernel modules.
      open = lib.mkDefault true;
      # DGX OS turns nvidia-drm modesetting off (nvidia-drm-options-modeset0,
      # etc/modprobe.d/zz-nvidia-drm-override.conf: "options nvidia-drm modeset=0").
      # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/common/n/nvidia-drm-options-modeset0/nvidia-drm-options-modeset0_25.07-1_all.deb
      # https://github.com/NVIDIA/open-gpu-kernel-modules/blob/580.178.04/kernel-open/nvidia-drm/nvidia-drm-linux.c#L35
      modesetting.enable = lib.mkDefault false;
      moduleParams.nvidia-drm.modeset = lib.mkDefault 0;
      # DGX OS's driver package keeps video memory across suspend
      # (nvidia-kernel-common-580, etc/modprobe.d/nvidia-graphics-drivers-kms.conf).
      # http://ports.ubuntu.com/ubuntu-ports/pool/restricted/n/nvidia-graphics-drivers-580/nvidia-kernel-common-580_580.178.04-0ubuntu0.24.04.1_arm64.deb
      moduleParams.nvidia = {
        NVreg_PreserveVideoMemoryAllocations = lib.mkDefault 1;
        NVreg_TemporaryFilePath = lib.mkDefault "/var";
      };
      # As on DGX OS (nv-persistence-mode: nvidia-persistenced
      # --persistence-mode).
      # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/common/n/nvhelpers/nv-persistence-mode_25.10-1_all.deb
      nvidiaPersistenced = lib.mkDefault true;
      # R580, the branch DGX OS ships on the Spark. Covers CUDA up to 13.0;
      # see README.md for newer toolkits.
      package = lib.mkDefault (
        let driver = config.boot.kernelPackages.nvidiaPackages.legacy_580;
        in driver // {
          open = scrubKernelDevRefs driver.open;
          mod = scrubKernelDevRefs driver.mod;
        }
      );
    };

    # DGX OS's kernel command line, one nvidia-spark-grub-* /
    # nvidia-spark-initcall-bl package per parameter. Kernel source links are to
    # the pinned kernel's tag (kernel-source.nix); update them with the tag.
    boot.kernelParams = [
      # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/dgx/n/nvidia-spark-grub-pci/nvidia-spark-grub-pci_1.0-1_arm64.deb
      # https://github.com/NVIDIA/NV-Kernels/blob/Ubuntu-nvidia-7.0-7.0.0-1019.19_24.04.2/drivers/pci/pci.c#L6742
      "pci=pcie_bus_safe"
      # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/dgx/n/nvidia-spark-initcall-bl/nvidia-spark-initcall-bl_1.0-1_arm64.deb
      # https://github.com/NVIDIA/NV-Kernels/blob/Ubuntu-nvidia-7.0-7.0.0-1019.19_24.04.2/drivers/soc/tegra/cbb/tegra234-cbb.c#L1639-L1643
      "initcall_blacklist=tegra234_cbb_init"
      # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/dgx/n/nvidia-spark-grub-kho/nvidia-spark-grub-kho_1.0-1_arm64.deb
      # https://github.com/NVIDIA/NV-Kernels/blob/Ubuntu-nvidia-7.0-7.0.0-1019.19_24.04.2/kernel/liveupdate/kexec_handover.c#L53-L65
      "kho=off"

      # Per-platform values NVIDIA's first-boot scripts write from the
      # "dgx_spark" entry in etc/nvidia-platform.d/nvidia-platform-configs.json:
      # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/common/n/nv-common-apis/nv-common-apis_26.08-2_all.deb
      # NeedsDisableInitOnAlloc (nvidia-disable-init-on-alloc); the kernel
      # defaults to on (CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y).
      # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/common/n/nvidia-disable-init-on-alloc/nvidia-disable-init-on-alloc_24.10-1_all.deb
      # https://github.com/NVIDIA/NV-Kernels/blob/Ubuntu-nvidia-7.0-7.0.0-1019.19_24.04.2/mm/mm_init.c#L2510-L2515
      "init_on_alloc=0"
      # IommuPt (nv-iommu); the kernel defaults to passthrough
      # (CONFIG_IOMMU_DEFAULT_PASSTHROUGH=y).
      # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/common/n/nvhelpers/nv-iommu_25.12-1_all.deb
      # https://github.com/NVIDIA/NV-Kernels/blob/Ubuntu-nvidia-7.0-7.0.0-1019.19_24.04.2/drivers/iommu/iommu.c#L791-L807
      "iommu.passthrough=0"
      # ConsoleSetting (nvidia-console-settings).
      # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/common/n/nvidia-console-settings/nvidia-console-settings_25.07-1_all.deb
      "console=tty0"
      "plymouth.ignore-serial-consoles"
      "plymouth.use-simpledrm"
      # NeedsEarlycon (nvidia-earlycon).
      # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/common/n/nvidia-earlycon/nvidia-earlycon_25.06-1_all.deb
      # https://github.com/NVIDIA/NV-Kernels/blob/Ubuntu-nvidia-7.0-7.0.0-1019.19_24.04.2/drivers/tty/serial/earlycon.c#L230-L249
      "earlycon=uart,mmio32,0x16A00000"

      # Serial console, last so it is /dev/console as on DGX OS. The device
      # comes from the DGX OS image's /etc/default/grub (no package sets it;
      # observed in /proc/cmdline on DGX OS, kernel 7.0.0-1019-nvidia); the
      # 921600 baud rate from SerialBaudRate / nvidia-spark-baud-rate.
      # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/common/n/nvidia-spark-baud-rate/nvidia-spark-baud-rate_25.09-1_all.deb
      "console=ttyS0,921600"
    ];

    # DGX OS's kernel package blocks these (debian.nvidia-7.0/modprobe.d/common.conf,
    # installed as /lib/modprobe.d/blacklist_linux-nvidia-7.0_<abi>-nvidia.conf
    # by linux-modules-<abi>-nvidia).
    # https://github.com/NVIDIA/NV-Kernels/blob/Ubuntu-nvidia-7.0-7.0.0-1019.19_24.04.2/debian.nvidia-7.0/modprobe.d/common.conf#L1-L4
    boot.blacklistedKernelModules = [ "snd-mixer-oss" "snd-pcm-oss" "coresight_etm4x" ]
      # nouveau, as NVIDIA's DGX systems do (nv-blacklist-nouveau). NixOS's
      # hardware.nvidia module blocks it too; stated here so the profile
      # doesn't depend on that.
      # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/common/n/nvhelpers/nv-blacklist-nouveau_25.10-1_all.deb
      # https://github.com/NixOS/nixpkgs/blob/8ce4ef6cb6f871616146b9fe26d2a5ae594e94fe/nixos/modules/hardware/video/nvidia.nix#L430-L434
      ++ [ "nouveau" ];

    # DGX OS's module settings. Comments are kept in the generated
    # /etc/modprobe.d/nixos.conf.
    boot.extraModprobeConfig = ''
      # CPPC autonomous performance selection (nvidia-cppc-cpufreq-options,
      # etc/modprobe.d/cppc_cpufreq.conf).
      # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/common/n/nvidia-cppc-cpufreq-options/nvidia-cppc-cpufreq-options_25.06-1_all.deb
      # https://github.com/NVIDIA/NV-Kernels/blob/Ubuntu-nvidia-7.0-7.0.0-1019.19_24.04.2/drivers/cpufreq/cppc_cpufreq.c#L1114-L1115
      options cppc_cpufreq auto_sel_mode=1

      # The onboard Realtek RTL8127 10GbE (PCI 10ec:8127) matches both mainline
      # r8169 and NVIDIA's bundled vendor driver r8127; DGX OS aliases it to
      # r8127 (nvidia-spark-realtek-mod-options, etc/modprobe.d/nvidia-spark-r8169.conf).
      # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/dgx/n/nvidia-spark-realtek-mod-options/nvidia-spark-realtek-mod-options_1.1-1_arm64.deb
      #   r8127: https://github.com/NVIDIA/NV-Kernels/blob/Ubuntu-nvidia-7.0-7.0.0-1019.19_24.04.2/drivers/net/ethernet/realtek/r8127/r8127_n.c#L141-L142
      #   r8169: https://github.com/NVIDIA/NV-Kernels/blob/Ubuntu-nvidia-7.0-7.0.0-1019.19_24.04.2/drivers/net/ethernet/realtek/r8169_main.c#L106-L107
      alias pci:v000010ECd00008127sv*sd*bc*sc*i* r8127

      # SBSA watchdog: panic on the first (WS0) timeout instead of waiting for
      # the second to reset (nvidia-sbsa-gwdt-options, etc/modprobe.d/sbsa_gwdt.conf).
      # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/common/n/nvidia-sbsa-gwdt-options/nvidia-sbsa-gwdt-options_25.06-1_arm64.deb
      # https://github.com/NVIDIA/NV-Kernels/blob/Ubuntu-nvidia-7.0-7.0.0-1019.19_24.04.2/drivers/watchdog/sbsa_gwdt.c#L116-L117
      options sbsa_gwdt action=1
    '';

    # Load mstflint_access, the kernel side of the ConnectX firmware tools
    # (nvidia-mstflint-loader, etc/modules-load.d/nvidia-mstflint.conf). DGX
    # OS's kernel package builds it from mstflint-dkms; here it's nixpkgs'
    # build of the same module (version may differ).
    # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/common/n/nvidia-mstflint-loader/nvidia-mstflint-loader_23.03-1_all.deb
    # https://github.com/NVIDIA/NV-Kernels/blob/Ubuntu-nvidia-7.0-7.0.0-1019.19_24.04.2/debian.nvidia-7.0/dkms-versions#L4
    boot.extraModulePackages = [ config.boot.kernelPackages.mstflint_access ];

    # Runtime power management for the GPU's PCI functions, as DGX OS's
    # driver package does (nvidia-kernel-common-580, lib/udev/rules.d/71-nvidia.rules).
    # http://ports.ubuntu.com/ubuntu-ports/pool/restricted/n/nvidia-graphics-drivers-580/nvidia-kernel-common-580_580.178.04-0ubuntu0.24.04.1_arm64.deb
    services.udev.extraRules = ''
      ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x03[0-9]*", TEST=="power/control", ATTR{power/control}="auto"
      ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x040300", TEST=="power/control", ATTR{power/control}="auto"
      ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c0330", TEST=="power/control", ATTR{power/control}="auto"
      ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c8000", TEST=="power/control", ATTR{power/control}="auto"
    '';

    # NVMe interrupt coalescing, NVIDIA's own script and unit
    # (nvidia-nvme-options, lib/systemd/system/nvidia-nvme-interrupt-coalescing.service).
    # It only touches Samsung, Kioxia and Micron controllers.
    # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/common/n/nvidia-nvme-options/nvidia-nvme-options_26.02-1_all.deb
    systemd.services.nvidia-nvme-interrupt-coalescing =
      let pkg = pkgs.callPackage ./nvme-interrupt-coalescing.nix { };
      in {
        description = "Configure NVMe Interrupt Coalescing";
        after = [ "systemd-udevd.service" ];
        requires = [ "systemd-udevd.service" ];
        unitConfig.ConditionPathExistsGlob = "/dev/nvme[0-9]*";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkg}/bin/nvidia-nvme-interrupt-coalescing.sh enable";
          ExecStop = "${pkg}/bin/nvidia-nvme-interrupt-coalescing.sh disable";
        };
      };

    # DGX OS requires a swap file at /swap.img (nvidia-spark-fstab-config adds
    # "/swap.img none swap sw 0 0" to /etc/fstab). Its size comes from the
    # DGX OS image (16G, observed with swapon on DGX OS). A list, so it adds to
    # any other swap the system defines.
    # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/dgx/n/nvidia-spark-fstab-config/nvidia-spark-fstab-config_1.0.0-1_arm64.deb
    swapDevices = [ { device = "/swap.img"; size = 16 * 1024; } ];

    # Includes the MediaTek MT7925 Wi-Fi/Bluetooth firmware. DGX OS adds a
    # Canonical PPA with a patched MT7925 build (nvidia-spark-wifi-fw-ppa:
    # canonical-nvidia/linux-firmware-mbssid-patches, LP: #2119479); nixpkgs'
    # linux-firmware already ships a newer MT7925 build than that PPA, so
    # nothing extra is needed.
    # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/dgx/n/nvidia-spark-wifi-fw-ppa/nvidia-spark-wifi-fw-ppa_1.1-1_arm64.deb
    # https://bugs.launchpad.net/bugs/2119479
    hardware.enableRedistributableFirmware = lib.mkDefault true;
    # NVIDIA publishes DGX Spark firmware to LVFS.
    services.fwupd.enable = lib.mkDefault true;

    # ConnectX-7 hot-plug power management, as on DGX OS
    # (dgx-spark-mlnx-hotplug, connectx7-hotplug.nix). The module only exists
    # in the NVIDIA kernel (CONFIG_MTK_PCIE_HOTPLUG).
    # https://github.com/NVIDIA/NV-Kernels/blob/Ubuntu-nvidia-7.0-7.0.0-1019.19_24.04.2/drivers/platform/arm64/nvidia/mtk-pcie-hotplug.c#L2321-L2324
    # https://github.com/NVIDIA/NV-Kernels/blob/Ubuntu-nvidia-7.0-7.0.0-1019.19_24.04.2/drivers/platform/arm64/nvidia/Kconfig#L6
    boot.kernelModules = [ "mtk-pcie-hotplug" "mstflint_access" ];
    services.udev.packages = [ (pkgs.callPackage ./connectx7-hotplug.nix { }) ]
      ++ lib.optional cfg.rdma.enable pkgs.rdma-core;
    # NVIDIA's .deb creates this marker in its post-install script; the helper
    # leaves hot-plug disabled without it.
    environment.etc."nvidia/cx7-hotplug-enabled".text = ''
      # Presence of this file enables ConnectX-7 hot-plug power management.
    '';

    environment.systemPackages = lib.optional cfg.rdma.enable pkgs.rdma-core;

    # DGX OS's limits for all users: unlimited memlock (nvidia-spark-limits,
    # etc/security/limits.d/99-nv-spark-limits.conf) and 500000 open files
    # (nv-limits, etc/security/limits.d/nv-limits.conf).
    # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/dgx/n/nvidia-spark-limits/nvidia-spark-limits_1.0-1_all.deb
    # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/common/n/nvhelpers/nv-limits_25.10-1_all.deb
    security.pam.loginLimits = [
      { domain = "*"; type = "soft"; item = "memlock"; value = "unlimited"; }
      { domain = "*"; type = "hard"; item = "memlock"; value = "unlimited"; }
      { domain = "*"; type = "soft"; item = "nofile"; value = "500000"; }
      { domain = "*"; type = "hard"; item = "nofile"; value = "500000"; }
    ];

    # CPU frequency governor, as DGX OS sets it at boot (nv-cpu-governor:
    # cpupower frequency-set -g performance).
    # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/common/n/nv-cpu-governor/nv-cpu-governor_22.05-1_all.deb
    powerManagement.cpuFreqGovernor = lib.mkDefault "performance";

    # DGX OS's ARP sysctls (nvidia-kernel-defaults, etc/sysctl.d/20-nvidia-defaults.conf).
    # https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/common/n/nvidia-kernel-defaults/nvidia-kernel-defaults_21.05-1_all.deb
    boot.kernel.sysctl = {
      "net.ipv4.conf.all.arp_announce" = lib.mkDefault 2;
      "net.ipv4.conf.default.arp_announce" = lib.mkDefault 2;
      "net.ipv4.conf.all.arp_ignore" = lib.mkDefault 1;
      "net.ipv4.conf.default.arp_ignore" = lib.mkDefault 1;
    };
  };
}
