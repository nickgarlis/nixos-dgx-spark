# Run `make` for the list of targets.

# Flake reference of the nixpkgs to build against. A cache hit needs the
# consumer's nixpkgs revision, e.g. NIXPKGS=github:NixOS/nixpkgs/<rev>.
NIXPKGS ?= github:NixOS/nixpkgs/nixos-unstable

.PHONY: help check-upstream build

help:
	@echo "make check-upstream   check the pinned NVIDIA/DGX OS versions against upstream"
	@echo "make build            build the NVIDIA kernel and driver module (aarch64-linux;"
	@echo "                      NIXPKGS=$(NIXPKGS))"

check-upstream:
	scripts/check-upstream.sh

build:
	nix build --impure -f build.nix --argstr nixpkgs '$(NIXPKGS)' kernel nvidia-open --print-out-paths
