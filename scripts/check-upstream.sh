#!/usr/bin/env bash
# Compares the versions pinned in .github/workflows/upstream.yml (its
# UBUNTU_PACKAGES / BASEOS_PACKAGES env vars) with what NVIDIA currently ships.
# Run via `make check-upstream`, or by the workflow.
set -euo pipefail

# Outside Actions (e.g. `make check-upstream`), read the pins from the workflow.
workflow_list() { # name -> the lines of that block scalar in the workflow's env
  awk -v key="  $1: |" '
    $0 == key { on = 1; next }
    on && /^    / { sub(/^    /, ""); print; next }
    on { exit }' "$(dirname "$0")/../.github/workflows/upstream.yml"
}
UBUNTU_PACKAGES=${UBUNTU_PACKAGES:-$(workflow_list UBUNTU_PACKAGES)}
BASEOS_PACKAGES=${BASEOS_PACKAGES:-$(workflow_list BASEOS_PACKAGES)}

BASEOS=https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64
LP=https://api.launchpad.net/1.0

# Newest published version of an Ubuntu source package in noble-updates.
ubuntu() {
  curl -fsS "$LP/ubuntu/+archive/primary?ws.op=getPublishedSources&exact_match=true&status=Published&pocket=Updates&source_name=$1&distro_series=$LP/ubuntu/noble" |
    jq -r '.entries[].source_package_version' | sort -V | tail -n1
}

# All BaseOS package stanzas (noble + noble-updates, common + dgx).
index=$(for suite in noble noble-updates; do for comp in common dgx; do
  curl -fsS "$BASEOS/dists/$suite/$comp/binary-arm64/Packages.gz" | gunzip
  echo
done; done)

# Newest version of a BaseOS package.
baseos() {
  awk -v pkg="$1" '$1 == "Package:" { p = $2 } $1 == "Version:" && p == pkg { print $2 }' <<<"$index" |
    sort -V | tail -n1
}

stale=0
check() { # where package pinned current
  if [[ "$4" == "$3" ]]; then
    echo "ok  $2 $3"
  else
    echo "::error::$2 ($1): pinned $3, now ${4:-missing}"
    stale=1
  fi
}

while read -r pkg pinned; do
  [[ -n $pkg ]] || continue
  check "Ubuntu noble-updates" "$pkg" "$pinned" "$(ubuntu "$pkg")"
done <<<"${UBUNTU_PACKAGES:?}"

while read -r pkg pinned; do
  [[ -n $pkg ]] || continue
  check "NVIDIA BaseOS" "$pkg" "$pinned" "$(baseos "$pkg")"
done <<<"${BASEOS_PACKAGES:?}"

exit "$stale"
