#!/bin/bash
source .env

HOME_OMNIBRIDGE_IMPLEMENTATION=$(forge create --rpc-url $GNO_RPC_URL --private-key $DEPLOYER_PRIV_KEY  -—verify —-etherscan-api-key $GNOSISSCAN_API_KEY omnibridge/contracts/upgradeable_contracts/HomeOmnibridge.sol:HomeOmnibridge --constructor-args $HOME_TOKEN_NAME_SUFFIX --json)
HOME_OMNIBRIDGE_IMPLEMENTATION_ADDRESS=$(jq -r '.deployedTo' <<< "$HOME_OMNIBRIDGE_IMPLEMENTATION")
echo "Home Omnibridge Implementation deployed to " $HOME_OMNIBRIDGE_IMPLEMENTATION_ADDRESS

FOREIGN_OMNIBRIDGE_IMPLEMENTATION=$(forge create --rpc-url $ETH_RPC_URL --private-key $DEPLOYER_PRIV_KEY—-verify —-etherscan-api-key $ETHERSCAN_API_KEY omnibridge/contracts/upgradeable_contracts/ForeignOmnibridge.sol:ForeignOmnibridge --constructor-args $FOREIGN_TOKEN_NAME_SUFFIX --json)
FOREIGN_OMNIBRIDGE_IMPLEMENTATION_ADDRESS=$(jq -r '.deployedTo' <<< "$FOREIGN_OMNIBRIDGE_IMPLEMENTATION")
echo "Foreign Omnibridge Implementation deployed to " $FOREIGN_OMNIBRIDGE_IMPLEMENTATION_ADDRESS

HOME_LIMIT_ARR=($HOME_DAILY_LIMIT $HOME_MAX_PER_TX $HOME_MIN_PER_TX)
FOREIGN_LIMIT_ARR=($FOREIGN_DAILY_LIMIT $FOREIGN_MAX_PER_TX $FOREIGN_MIN_PER_TX)

HOME_OMNIBRIDGE_UPGRADE_TX=$(cast send $HOME_OMNIBRIDGE "upgradeTo(uint256, address)" 9 $HOME_OMNIBRIDGE_IMPLEMENTATION_ADDRESS  --rpc-url $GNO_RPC_URL --private-key $DEPLOYER_PRIV_KEY --json)
HOME_OMNIBRIDGE_UPGRADE_TX_HASH=$(jq -r '.transactionHash' <<< "$HOME_OMNIBRIDGE_UPGRADE_TX")
echo "Home: Binding proxy and implementation " $HOME_OMNIBRIDGE_UPGRADE_TX_HASH

FOREIGN_OMNIBRIDGE_UPGRADE_TX=$(cast send $FOREIGN_OMNIBRIDGE "upgradeTo(uint256, address)" 9 $FOREIGN_OMNIBRIDGE_IMPLEMENTATION_ADDRESS  --rpc-url $SOURCE_RPC_URL --private-key $DEPLOYER_PRIV_KEY --json)
FOREIGN_OMNIBRIDGE_UPGRADE_TX_HASH=$(jq -r '.transactionHash' <<< "$FOREIGN_OMNIBRIDGE_UPGRADE_TX")
echo "Foreign: Binding proxy and implementation " $FOREIGN_OMNIBRIDGE_UPGRADE_TX_HASH

HOME_OMNI_INIT=$(cast send $HOME_OMNIBRIDGE "initialize(address,address,uint256[3],uint256[2],address,address,address,address,address)" $HOME_AMB_ $HOME_OMNIBRIDGE   ["${HOME_LIMIT_ARR[0]}","${HOME_LIMIT_ARR[1]}","${HOME_LIMIT_ARR[2]}"]  ["${FOREIGN_LIMIT_ARR[0]}","${FOREIGN_LIMIT_ARR[1]}"] $HOME_SELECTOR_GAS_LIMIT_ADDRESS $HOME_OWNER_ADDR $HOME_TOKEN_FACTORY_ADDRESS $HOME_FEE_MANAGER_ADDRESS $HOME_FORWARDING_RULE_ADDRESS --rpc-url $GNO_RPC_URL --private-key $DEPLOYER_PRIV_KEY --json)
HOME_OMNI_INIT_TX_HASH=$(jq -r '.transactionHash' <<< "$HOME_OMNI_INIT")
echo "Initialize Home Omnibridge " $HOME_OMNI_INIT_TX_HASH

FOREIGN_OMNI_INIT=$(cast send $FOREIGN_OMNIBRIDGE "initialize(address,address,uint256[3],uint256[2],uint256,address,address)" $FOREIGN_AMB $HOME_OMNIBRIDGE ["${FOREIGN_LIMIT_ARR[0]}","${FOREIGN_LIMIT_ARR[1]}","${FOREIGN_LIMIT_ARR[2]}"] ["${HOME_LIMIT_ARR[0]}",${HOME_LIMIT_ARR[1]}] $FOREIGN_REQUEST_GAS_LIMIT $FOREIGN_OWNER_ADDR $FOREIGN_TOKEN_FACTORY_ADDRESS  --rpc-url $ETH_RPC_URL --private-key $DEPLOYER_PRIV_KEY --json)
FOREIGN_OMNI_INIT_TX_HASH=$(jq -r '.transactionHash' <<< "$FOREIGN_OMNI_INIT")
echo "Initialize Foreign Omnibridge " $FOREIGN_OMNI_INIT_TX_HASH
