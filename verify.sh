#!/usr/bin/env bash
#
# verify.sh — check that the locally built runtime bytecode of ForeignOmnibridge and
# HomeOmnibridge matches the deployed implementations on-chain.
#
# Runs from a freshly cloned repo with nothing installed: it pins node, yarn, foundry and
# forge-std, installs any of them that are missing or at the wrong version into ./.toolchain,
# then builds and compares.
#
# The build output can never match the on-chain code byte-for-byte as compiled:
# BasicOmnibridge keeps the bridged-token name suffix in two immutables (SUFFIX,
# SUFFIX_SIZE). solc emits 32 zero bytes at each use site and records the offsets in
# deployedBytecode.immutableReferences; the constructor patches the real values in at deploy
# time. So we write the known values into those placeholder slots and then compare sha256 of
# both runtime bytecodes.
#
# See docs/basicomnibridge-fix.md ("Why are there differences in deployed bytecode ...").
#
# Usage: ./verify.sh [--no-build]
#   ETH_RPC_URL     Ethereum RPC (default: https://ethereum-rpc.publicnode.com)
#   GNOSIS_RPC_URL  Gnosis  RPC  (default: https://rpc.gnosischain.com)

set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
cd "$(dirname "$0")"

# ---------------------------------------------------------------- pinned toolchain
NODE_VERSION=20.19.0
YARN_VERSION=1.22.22
FOUNDRY_VERSION=v1.3.0
FORGE_STD_VERSION=v1.7.6

TOOLCHAIN_DIR="$PWD/.toolchain"

ETH_RPC_URL="${ETH_RPC_URL:-https://ethereum-rpc.publicnode.com}"
GNOSIS_RPC_URL="${GNOSIS_RPC_URL:-https://rpc.gnosischain.com}"

for dep in curl tar git jq xxd; do
  command -v "$dep" >/dev/null 2>&1 || { printf 'missing dependency: %s\n' "$dep" >&2; exit 1; }
done

# sha256sum is coreutils (Linux); shasum is the Perl one shipped on macOS.
if command -v sha256sum >/dev/null 2>&1; then
  SHA256_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  SHA256_CMD="shasum -a 256"
else
  printf 'missing dependency: sha256sum or shasum\n' >&2; exit 1
fi

# ---------------------------------------------------------------- node
ensure_node() {
  if command -v node >/dev/null 2>&1 && [ "$(node -v)" = "v$NODE_VERSION" ]; then
    echo "==> node v$NODE_VERSION (system)"
    return
  fi

  local os arch dir
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux)  os=linux ;;
    *) echo "unsupported OS for automatic node install: $(uname -s)" >&2; exit 1 ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64)  arch=x64 ;;
    *) echo "unsupported arch for automatic node install: $(uname -m)" >&2; exit 1 ;;
  esac

  dir="$TOOLCHAIN_DIR/node-v$NODE_VERSION-$os-$arch"
  if [ ! -x "$dir/bin/node" ]; then
    echo "==> installing node v$NODE_VERSION into $dir"
    mkdir -p "$TOOLCHAIN_DIR"
    curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-$os-$arch.tar.gz" \
      | tar -xz -C "$TOOLCHAIN_DIR"
  else
    echo "==> node v$NODE_VERSION (.toolchain)"
  fi
  PATH="$dir/bin:$PATH"
  export PATH
}

# ---------------------------------------------------------------- foundry
forge_is_pinned() {
  command -v forge >/dev/null 2>&1 &&
    forge --version 2>/dev/null | grep -q "${FOUNDRY_VERSION#v}"
}

ensure_foundry() {
  if forge_is_pinned; then
    echo "==> foundry $FOUNDRY_VERSION (system)"
    return
  fi

  local dir="$TOOLCHAIN_DIR/foundry"
  PATH="$dir/bin:$PATH"
  export PATH
  if forge_is_pinned; then
    echo "==> foundry $FOUNDRY_VERSION (.toolchain)"
    return
  fi

  echo "==> installing foundry $FOUNDRY_VERSION into $dir"
  mkdir -p "$dir/bin"
  # the installer is pinned to the same tag as the release, not master: master's foundryup
  # is a moving target whose CLI has already changed once. Fetched from raw.githubusercontent
  # rather than foundry.paradigm.xyz so nothing touches shell profiles.
  curl -fsSL "https://raw.githubusercontent.com/foundry-rs/foundry/$FOUNDRY_VERSION/foundryup/foundryup" \
    -o "$dir/bin/foundryup"
  chmod +x "$dir/bin/foundryup"
  # foundryup verifies the downloaded binaries against the release attestation
  FOUNDRY_DIR="$dir" "$dir/bin/foundryup" --install "$FOUNDRY_VERSION" >/dev/null

  forge_is_pinned || { echo "foundry $FOUNDRY_VERSION install failed" >&2; exit 1; }
}

# ---------------------------------------------------------------- project deps
ensure_deps() {
  # solc resolves "@openzeppelin/" to node_modules/ (see remappings in foundry.toml)
  if [ ! -d node_modules/@openzeppelin ]; then
    echo "==> yarn $YARN_VERSION install"
    npx --yes "yarn@$YARN_VERSION" install --ignore-engines --ignore-scripts
  fi
  if [ ! -d lib/forge-std ]; then
    echo "==> forge install forge-std $FORGE_STD_VERSION"
    forge install "foundry-rs/forge-std@$FORGE_STD_VERSION"
  fi
}

ensure_node
ensure_foundry
ensure_deps

if [ "${1:-}" != "--no-build" ]; then
  echo "==> forge build"
  forge build -q
fi

# ---------------------------------------------------------------- comparison
# 32-byte right-padded hex of a utf8 string (how solc lays out a short bytes32)
bytes32_str() {
  local hex
  hex="$(printf '%s' "$1" | xxd -p | tr -d '\n')"
  printf '%s' "$hex"
  printf '%0*d' $((64 - ${#hex})) 0
}

# 32-byte left-padded hex of a decimal number
bytes32_num() { printf '%064x' "$1"; }

# splice $3 (64 hex chars) into $1 at byte offset $2
splice() {
  local code="$1" off=$(( $2 * 2 )) val="$3"
  printf '%s%s%s' "${code:0:$off}" "$val" "${code:$((off + 64))}"
}

# sha256 of the 0x-prefixed hex string, i.e. the bytecode exactly as the explorer and the artifact show it.
sha256_hex() { printf '0x%s' "$1" | $SHA256_CMD | cut -d' ' -f1; }

fail=0

verify() {
  local name="$1" artifact="$2" addr="$3" rpc="$4" suffix="$5"
  echo
  echo "=== $name  ($addr)"

  local local_code onchain
  local_code="$(jq -r '.deployedBytecode.object' "$artifact" | tr 'A-F' 'a-f')"
  local_code="${local_code#0x}"

  # SUFFIX_SIZE is AST id 2927, SUFFIX is 2929 (BasicOmnibridge.sol:43)
  local off_size off_suffix
  off_size="$(jq -r '.deployedBytecode.immutableReferences["2927"][0].start' "$artifact")"
  off_suffix="$(jq -r '.deployedBytecode.immutableReferences["2929"][0].start' "$artifact")"

  # sanity: both slots must be 32 zero bytes in the local build
  local zeros; zeros="$(printf '%064d' 0)"
  for off in "$off_size" "$off_suffix"; do
    if [ "${local_code:$((off * 2)):64}" != "$zeros" ]; then
      echo "  ! immutable slot @${off} is not zero-filled in the local artifact" >&2
      fail=1; return
    fi
  done

  echo "  patching SUFFIX      @${off_suffix}  \"${suffix}\""
  local_code="$(splice "$local_code" "$off_suffix" "$(bytes32_str "$suffix")")"
  echo "  patching SUFFIX_SIZE @${off_size}  ${#suffix}"
  local_code="$(splice "$local_code" "$off_size" "$(bytes32_num "${#suffix}")")"

  onchain="$(cast code "$addr" --rpc-url "$rpc" | tr 'A-F' 'a-f')"
  onchain="${onchain#0x}"
  if [ -z "$onchain" ]; then
    echo "  ! no code at $addr" >&2; fail=1; return
  fi

  local h_local h_chain
  h_local="$(sha256_hex "$local_code")"
  h_chain="$(sha256_hex "$onchain")"

  echo "  local  : $(( ${#local_code} / 2 )) bytes  sha256(hex) $h_local"
  echo "  onchain: $(( ${#onchain} / 2 )) bytes  sha256(hex) $h_chain"

  if [ "$h_local" = "$h_chain" ]; then
    echo "  MATCH"
  else
    echo "  MISMATCH"
    fail=1
  fi
}

verify "ForeignOmnibridge (Ethereum)" \
  out/ForeignOmnibridge.sol/ForeignOmnibridge.json \
  0x00e7097e9c1ce7121fc466ff31a7c742d5a26ea2 \
  "$ETH_RPC_URL" \
  " from xDai"

verify "HomeOmnibridge (Gnosis)" \
  out/HomeOmnibridge.sol/HomeOmnibridge.json \
  0x992685a4117a5c217f3a0e33f735565ad132b12a \
  "$GNOSIS_RPC_URL" \
  " from Mainnet"

echo
if [ "$fail" -eq 0 ]; then
  echo "OK: both implementations match the local build."
else
  echo "FAILED"
fi
exit "$fail"
