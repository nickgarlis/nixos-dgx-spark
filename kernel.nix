# NVIDIA's DGX Spark kernel (NVIDIA/NV-Kernels, the kernel DGX OS is built
# from) with the NVIDIA-derived config in kernel-config.nix.
{ lib, buildLinux, fetchFromGitHub, kernelPatches, ... }:

let
  source = import ./kernel-source.nix;
in
buildLinux {
  src = source.mkNvidiaKernelSource { inherit fetchFromGitHub; };
  version = "${source.nvidiaKernelVersion}-nvidia";
  modDirVersion = source.nvidiaKernelVersion;
  # The patches nixpkgs applies to its own kernels.
  kernelPatches = [
    kernelPatches.bridge_stp_helper
    kernelPatches.request_key_helper
  ];
  extraMeta.branch = lib.versions.majorMinor source.nvidiaKernelVersion;
  # The NVIDIA-derived config sets options this nixpkgs' kernel tree may not
  # know about; tolerate those instead of failing the build.
  ignoreConfigErrors = true;
  structuredExtraConfig = import ./kernel-config.nix { inherit lib; };
}
