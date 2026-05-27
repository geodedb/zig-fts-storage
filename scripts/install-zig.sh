#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2026 CodePros
#
# SEC-06, SEC-EXT-0501, WRK-043: this installer rejects TOFU. Both the
# tarball URL and its SHA256 are pinned in this script per (version, arch,
# os) tuple. We do NOT trust whatever ziglang.org/download/index.json claims
# the shasum is — the previous implementation downloaded the tarball and the
# expected SHA from the same origin, which means a compromised origin or
# transit MITM could substitute both and the check would still pass.
#
# To add a new pin: download the tarball over a separate trust path,
# compute the SHA256 locally (`sha256sum` or `shasum -a 256`), and add the
# entry to ZIG_TARBALL_SHA256 below. Treat the pin commit as a separate
# review event.

set -euo pipefail

ZIG_VERSION="${1:?usage: install-zig.sh <version>}"
ARCH="$(uname -m)"
OS="$(uname -s)"

case "${ARCH}" in
  x86_64|amd64) ZIG_ARCH="x86_64" ;;
  aarch64|arm64) ZIG_ARCH="aarch64" ;;
  *)
    echo "unsupported architecture: ${ARCH}" >&2
    exit 1
    ;;
esac

case "${OS}" in
  Linux)   ZIG_OS="linux" ;;
  Darwin)  ZIG_OS="macos" ;;
  *)
    echo "unsupported OS: ${OS}" >&2
    exit 1
    ;;
esac

TARGET_KEY="${ZIG_ARCH}-${ZIG_OS}"
ARCHIVE="zig-${ZIG_ARCH}-${ZIG_OS}-${ZIG_VERSION}"
TARBALL="${ARCHIVE}.tar.xz"

# Pinned SHA256 table. Key format: <version>-<arch>-<os>.
# SHA256s captured from ziglang.org and locally verified; subsequent runs
# never re-derive the SHA from a remote source.
declare -A ZIG_TARBALL_SHA256=(
  ["0.16.0-x86_64-linux"]="70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00"
  ["0.16.0-aarch64-linux"]="ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17"
  ["0.16.0-x86_64-macos"]="0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7"
  ["0.16.0-aarch64-macos"]="b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489"
)

PIN_KEY="${ZIG_VERSION}-${TARGET_KEY}"
EXPECTED_SHA256="${ZIG_TARBALL_SHA256[${PIN_KEY}]:-}"

if [ -z "${EXPECTED_SHA256}" ]; then
  if [ "${ALLOW_TOFU:-0}" != "1" ]; then
    echo "SEC-EXT-0501: refusing to install Zig ${ZIG_VERSION} for ${TARGET_KEY}: no pinned SHA256 in ZIG_TARBALL_SHA256." >&2
    echo "Add a pin to scripts/install-zig.sh after verifying the tarball out-of-band, or re-run with ALLOW_TOFU=1 (NOT recommended)." >&2
    exit 1
  fi
  echo "WARNING (SEC-EXT-0501): ALLOW_TOFU=1 set; deriving SHA256 from ziglang.org/download/index.json." >&2
  echo "WARNING: this trusts the same origin for both the tarball and its checksum." >&2
fi

if [ ! -x "zig-${ZIG_VERSION}/zig" ]; then
  if [ -n "${EXPECTED_SHA256}" ]; then
    # Safe path: download the tarball and verify against the pinned SHA256.
    TARBALL_URL="https://ziglang.org/download/${ZIG_VERSION}/${TARBALL}"
    curl -fsSL "${TARBALL_URL}" -o "/tmp/${TARBALL}"
    if command -v sha256sum >/dev/null 2>&1; then
      echo "${EXPECTED_SHA256}  /tmp/${TARBALL}" | sha256sum --check --strict
    else
      echo "${EXPECTED_SHA256}  /tmp/${TARBALL}" | shasum -a 256 -c -
    fi
  else
    # ALLOW_TOFU=1 fallback. Explicit opt-in only; the script refuses by
    # default. Preserved for bootstrap-on-new-platform scenarios where the
    # operator has out-of-band verified the publisher.
    export ZIG_VERSION TARGET_KEY
    curl -fsSL https://ziglang.org/download/index.json -o /tmp/zig-index.json
    mapfile -t VALUES < <(python3 - <<'PY'
import json, os
version = os.environ["ZIG_VERSION"]
target = os.environ["TARGET_KEY"]
idx = json.load(open("/tmp/zig-index.json"))
pkg = idx[version][target]
print(pkg["tarball"])
print(pkg["shasum"])
PY
    )
    curl -fsSL "${VALUES[0]}" -o "/tmp/${TARBALL}"
    if command -v sha256sum >/dev/null 2>&1; then
      echo "${VALUES[1]}  /tmp/${TARBALL}" | sha256sum --check --strict
    else
      echo "${VALUES[1]}  /tmp/${TARBALL}" | shasum -a 256 -c -
    fi
  fi

  tar -xJf "/tmp/${TARBALL}"
  mv "${ARCHIVE}" "zig-${ZIG_VERSION}"
fi
