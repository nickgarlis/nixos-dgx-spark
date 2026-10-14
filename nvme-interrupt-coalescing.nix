# NVIDIA's NVMe interrupt coalescing script (enables it on Samsung, Kioxia and
# Micron controllers, skips others) from the DGX OS BaseOS apt repo.
{ lib, stdenvNoCC, fetchurl, dpkg, makeWrapper, bash, coreutils, gnugrep, gawk, nvme-cli, util-linux }:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "nvidia-nvme-options";
  version = "26.02-1";

  src = fetchurl {
    url = "https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/pool/common/n/nvidia-nvme-options/${finalAttrs.pname}_${finalAttrs.version}_all.deb";
    hash = "sha256-2SWRJldOSGbP1VwZ1cowJipS2EAMtg/7qNg0V807IUs=";
  };

  strictDeps = true;
  nativeBuildInputs = [ dpkg makeWrapper ];
  buildInputs = [ bash ];

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb --extract "$src" .
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 usr/bin/nvidia-nvme-interrupt-coalescing.sh "$out/bin/nvidia-nvme-interrupt-coalescing.sh"
    install -Dm644 usr/share/doc/nvidia-nvme-options/copyright "$out/share/doc/nvidia-nvme-options/copyright"
    patchShebangs "$out/bin/nvidia-nvme-interrupt-coalescing.sh"
    wrapProgram "$out/bin/nvidia-nvme-interrupt-coalescing.sh" \
      --prefix PATH : ${lib.makeBinPath [ coreutils gnugrep gawk nvme-cli util-linux ]}
    runHook postInstall
  '';

  meta = {
    description = "NVMe interrupt coalescing configuration from NVIDIA DGX OS";
    license = lib.licenses.unfree;
    platforms = lib.platforms.linux;
  };
})
