{
  description = "NixOS hardware support for NVIDIA GB10 systems: DGX Spark, ASUS Ascent GX10";

  # No inputs, like nixos-hardware: the profile uses the importing system's
  # nixpkgs. One profile serves every GB10 box; the vendor names are aliases.
  outputs = { self }: {
    nixosModules = {
      default = import ./.;
      nvidia-dgx-spark = self.nixosModules.default;
      asus-ascent-gx10 = self.nixosModules.default;
    };
  };
}
