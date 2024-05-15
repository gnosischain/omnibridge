#!/usr/bin/env bash

source .env

echo "End to End Test"

echo "Relay USDC from Ethereum"
forge test --match-test test_relayTokensFromETH --rpc-url $ETH_RPC_URL --json | jq > usdc_test/test_output/ETH_relayTokens.json
node usdc_test/utils/collectAffirmation.js
forge test --match-test test_receiveUSDCFromETH --rpc-url $GNO_RPC_URL 
echo "ETH->GC: Done ✅"
echo "Relay USDC.e from Gnosis Chain"
forge test --match-test test_relayUSDCEFromGC --rpc-url $GNO_RPC_URL --json | jq > usdc_test/test_output/GNO_relayTokens.json
node usdc_test/utils/signAndGetSignature.js
forge test --match-test test_receiveUSDCFromGC --rpc-url $ETH_RPC_URL 
echo "GC->ETH: Done ✅"

echo "End to End Test:  Done ✅"

echo "Unit & Fuzz Test"
forge test --no-match-test test_receiveUSDCFromGC --match-path usdc_test/eth.t.sol --rpc-url $ETH_RPC_URL -v
forge test --no-match-test test_receiveUSDCFromETH --match-path usdc_test/gno.t.sol --rpc-url $GNO_RPC_URL -v
echo "Unit & Fuzz Test: :  Done ✅"