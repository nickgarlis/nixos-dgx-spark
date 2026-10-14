# What this profile compiles (no binary cache has it by default): the NVIDIA
# kernel and the NVIDIA driver's kernel module, evaluated with the profile in a
# minimal NixOS system. `nixpkgs` is a flake reference; a binary cache only
# serves machines whose nixpkgs revision matches the one built here.
#   nix build --impure -f build.nix --argstr nixpkgs github:NixOS/nixpkgs/<rev>
{ nixpkgs ? "github:NixOS/nixpkgs/nixos-unstable" }:

let
  system = (builtins.getFlake nixpkgs).lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      ./.
      {
        nixpkgs.config.allowUnfree = true;
        # Just enough for the system to evaluate; nothing here is installed.
        fileSystems."/".device = "none";
        boot.loader.grub.enable = false;
        system.stateVersion = "26.05";
      }
    ];
  };
in
{
  kernel = system.config.boot.kernelPackages.kernel;
  nvidia-open = system.config.hardware.nvidia.package.open;
}
