# Testing of Omnibridge upgrade for Circle Bridged USDC standard

## Setup 
```
git submodule --init 
git submodule update
yarn install
```

## Dev
Run the test
```
cd omnibridge
./usdcTest.sh
```
## Unit & Fuzz Test
1. USDC is burned correctly on ETH Omnibridge, only triggered by Circle Address ✅    
2. Authorized Circle address is set correctly ✅    
3. New Token address pair(USDC, USDC.e) is set correctly, legacy USDC on xDAI is no longer bridgable(can swap using [USDCTransmuter](https://github.com/zengzengzenghuy/stablecoin-evm/blob/foundry_deployment/contracts/USDCTransmuter.sol)) ✅

## E2E Test
1. Relay USDC from ETH, and receive USDC.e on GC ✅    
2. Relay USDC.e from GC, and receive USDC on ETH ✅

