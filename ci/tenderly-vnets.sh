#!/usr/bin/env bash
# Creates or deletes the Tenderly Virtual TestNets used by the e2e fork tests (test-e2e/, see README.md).
#
#   ci/tenderly-vnets.sh create   Ethereum (chain id 1) and Gnosis Chain (chain id 100) VNets
#   ci/tenderly-vnets.sh delete   deletes every VNet recorded by `create`; safe to run more than once
#
# Env: TENDERLY_API_TOKEN, TENDERLY_ACCOUNT_ID, TENDERLY_PROJECT (required)
#      TENDERLY_FORK_BLOCK_ETH, TENDERLY_FORK_BLOCK_GC (optional block numbers, default latest)
#
# `create` writes FOREIGN_RPC_URL (Ethereum) and HOME_RPC_URL (Gnosis) to $GITHUB_ENV in CI, masked in logs.
# Run locally, it prints them as export lines instead:  eval "$(ci/tenderly-vnets.sh create)"
# Each VNet id is saved to .tenderly-vnets.json as soon as it exists, so `delete` can clean up after a failure.
set -euo pipefail
cd "$(dirname "$0")/.."

VNETS_FILE=.tenderly-vnets.json

for var in TENDERLY_API_TOKEN TENDERLY_ACCOUNT_ID TENDERLY_PROJECT; do
  if [ -z "${!var:-}" ]; then
    echo "Missing env var $var" >&2
    exit 1
  fi
done
API="https://api.tenderly.co/api/v1/account/${TENDERLY_ACCOUNT_ID}/project/${TENDERLY_PROJECT}/vnets"

record_vnet() {
  local id=$1 slug=$2
  local current='[]'
  [ -f "$VNETS_FILE" ] && current=$(cat "$VNETS_FILE")
  jq --arg id "$id" --arg slug "$slug" '. + [{id: $id, slug: $slug}]' <<<"$current" >"$VNETS_FILE"
}

export_rpc() {
  local name=$1 url=$2
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "::add-mask::$url"
    echo "$name=$url" >>"$GITHUB_ENV"
  else
    echo "export $name=$url"
  fi
}

# create_vnet <chain id> <display name> <fork block> <env var for the RPC URL>
create_vnet() {
  local chain_id=$1 name=$2 block=$3 rpc_var=$4
  local slug="omnibridge-e2e-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${name}-$(date +%s)"
  local body response id rpc

  body=$(jq -n --arg slug "$slug" --arg name "$name" --arg block "$block" --argjson chain "$chain_id" '{
    slug: $slug,
    display_name: ("omnibridge e2e " + $name),
    fork_config: { network_id: $chain, block_number: $block },
    virtual_network_config: { chain_config: { chain_id: $chain } },
    sync_state_config: { enabled: false },
    explorer_page_config: { enabled: false, verification_visibility: "bytecode" }
  }')

  echo "Creating $name VNet (chain id $chain_id, block $block)..." >&2
  response=$(curl -sS --fail-with-body -X POST "$API" \
    -H "X-Access-Key: $TENDERLY_API_TOKEN" -H "Content-Type: application/json" -d "$body")

  id=$(jq -r '.id // empty' <<<"$response")
  if [ -z "$id" ]; then
    echo "Tenderly returned no VNet id" >&2
    exit 1
  fi
  record_vnet "$id" "$slug"

  # The tests only read state and fork it locally, so the public RPC is enough.
  rpc=$(jq -r '.rpcs[] | select(.name == "Public RPC") | .url' <<<"$response")
  if [ -z "$rpc" ]; then
    echo "Tenderly returned no Public RPC for VNet $id" >&2
    exit 1
  fi
  export_rpc "$rpc_var" "$rpc"
  echo "  created $id ($slug)" >&2
}

delete_vnets() {
  if [ ! -f "$VNETS_FILE" ]; then
    echo "No recorded VNets to delete." >&2
    return 0
  fi
  local failed='[]' id slug status
  while read -r entry; do
    id=$(jq -r .id <<<"$entry")
    slug=$(jq -r .slug <<<"$entry")
    status=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$API/$id" -H "X-Access-Key: $TENDERLY_API_TOKEN" || echo 000)
    if [ "$status" = 200 ] || [ "$status" = 204 ] || [ "$status" = 404 ]; then
      echo "  deleted $id ($slug)" >&2
    else
      echo "  FAILED to delete $id ($slug): HTTP $status" >&2
      failed=$(jq --argjson e "$entry" '. + [$e]' <<<"$failed")
    fi
  done < <(jq -c '.[]' "$VNETS_FILE")

  if [ "$(jq length <<<"$failed")" = 0 ]; then
    rm -f "$VNETS_FILE"
  else
    echo "$failed" >"$VNETS_FILE"
    # do not fail an otherwise green run because of a Tenderly hiccup
    echo "::warning::Some Tenderly VNets could not be deleted, see the log above."
  fi
}

case "${1:-}" in
  create)
    create_vnet 1 ethereum "${TENDERLY_FORK_BLOCK_ETH:-latest}" FOREIGN_RPC_URL
    create_vnet 100 gnosis "${TENDERLY_FORK_BLOCK_GC:-latest}" HOME_RPC_URL
    ;;
  delete)
    delete_vnets
    ;;
  *)
    echo "Usage: $0 create|delete" >&2
    exit 2
    ;;
esac
