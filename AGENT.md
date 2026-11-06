# Notes for agents and developers

What you need to work on this repo without looking things up on-chain. On-chain values were read on
**2026-11-06**; they change through governance, so re-check them before relying on them for anything that ships.

## Repo layout

| Path | What it is |
| --- | --- |
| `contracts/` | Solidity 0.7.5 sources. Mediators: `upgradeable_contracts/HomeOmnibridge.sol` (Gnosis Chain), `ForeignOmnibridge.sol` (Ethereum), both on `BasicOmnibridge.sol`. Modules (token factory, fee manager, gas limit manager, forwarding rules) in `upgradeable_contracts/modules/`. Mocks in `mocks/`. |
| `precompiled/` | `ERC677BridgeToken.json`, `PermittableToken.json`: solc 0.4.24 artifacts. `PermittableToken` is the token image every bridged token proxies to. Deploy them from the `bytecode` field (see `test-foundry/utils/TestHelpers.sol`). |
| `test/` | Truffle JS tests (`yarn test`, needs Docker). Kept alongside Foundry. |
| `test-foundry/` | Foundry unit tests. `omnibridge/` is a port of `test/omnibridge/common.test.js`. |
| `test-e2e/` | Foundry fork tests against Ethereum + Gnosis Chain with the production AMBs. Profile `e2e`. |
| `script/` | Foundry deploy/upgrade scripts (`DeployOmnibridge.s.sol` mirrors `deploy/deploy.js`). |
| `deploy/` | Original JS deployment (`deploy/.env.example` lists every variable; the Foundry script reads the same ones). |
| `ci/` | `tenderly-vnets.sh` (create/delete Tenderly VNets), `mediators-changed.sh` (decides if the upgrade test runs). |
| `e2e-tests/` | Old docker-compose e2e (Ganache + oracle). Not used by CI any more. |

## Commands

```bash
git submodule update --init --recursive   # forge-std (lib/forge-std, v1.7.6)
yarn                                      # @openzeppelin/contracts 3.2.2-solc-0.7, read from node_modules
forge build
forge test -vvv                           # test-foundry/, no RPC needed
FOREIGN_RPC_URL=<eth rpc> HOME_RPC_URL=<gnosis rpc> FOUNDRY_PROFILE=e2e forge test   # test-e2e/
```

Any archive RPC works for the e2e tests (public ones such as `https://ethereum-rpc.publicnode.com` and
`https://rpc.gnosischain.com` are enough). Do not name the variable `ETH_RPC_URL`: Foundry treats it as a global
fork URL and every test would run forked.

## Compiler and Foundry gotchas

- solc **0.7.5**, optimizer 200 runs, `evm_version = "istanbul"`. Must match `truffle-config.js` and the deployed
  bytecode. No `block.chainid` (use `assembly { id := chainid() }`), no `bytes.concat`, no custom errors, and
  `fixed` is a reserved word (do not use it as a variable name).
- Profile `e2e` sets `evm_version = "cancun"`. Foundry still compiles for istanbul (solc 0.7.5 cannot target
  newer), but the forks then execute with a recent EVM, which the production contracts behind the AMBs need.
- `contracts/helpers/WETHOmnibridgeRouter.sol` is skipped in `foundry.toml`: it calls
  `IOmnibridge.relayTokensAndCall`, which `contracts/interfaces/IOmnibridge.sol` does not declare.
- `fs_permissions` allows reading `./precompiled` only.
- `contracts/mocks/TokenReaderTest.sol` has `test*` functions, so Forge runs it under every profile.
- `vm.getRecordedLogs()` drains the buffer. The test bases keep their own copy of the logs; reuse their helpers.
- Use `assertEq` overloads with explicit casts for `uint8`/`bytes4` (`uint256(x)`, `bytes4(...)`).

## Contract behaviour worth knowing

- **Per-token `minPerTx` always reads 1 wei** once a token is registered (`TokensBridgeLimits.minPerTx`, a
  governance decision). `minPerTx(address(0))` still returns the stored default. The JS tests still expect the old
  scaled values; the Foundry port asserts the current behaviour.
- New tokens get limits copied from the `address(0)` defaults, scaled by decimals (`_initializeTokenBridgeLimits`).
  If scaling down makes `minPerTx` 0, it becomes 1, and `maxPerTx` / `dailyLimit` are raised to 100 / 10000 when
  they would otherwise not exceed it.
- Mediators run behind `EternalStorageProxy`: `initialize` is `onlyRelevantSender` (proxy upgradeability owner,
  or anyone when called on a bare implementation). `claimTokens` and `fixMediatorBalance` are
  `onlyIfUpgradeabilityOwner`, so they only work through a proxy.
- `HomeOmnibridge` sends through `requireToPassMessage` (oracle lane, dataType 0) unless a forwarding rules manager
  is set and returns lane <= 0, then `requireToConfirmMessage` (manual lane, dataType 0x80).
- Request gas: Home uses its `SelectorTokenGasLimitManager` (or the AMB `maxGasPerTx` if none is set).
  Foreign uses `requestGasLimit()`, which must not exceed the foreign AMB `maxGasPerTx`.
- Fees exist only on the home side (`OmnibridgeFeeManager`): home->foreign fee taken on send, foreign->home fee
  taken on receive. Reward addresses are exempt when sending. An odd remainder goes to a random reward address
  (`blockhash(block.number - 1)`).
- Precompiled ERC677 tokens: `transferAndCall` to a contract requires the receiver to implement
  `onTokenTransfer` and return true; plain `transfer` only calls back the token's own bridge contract.

### Message selectors (other-side calls)

| Function | Selector |
| --- | --- |
| `deployAndHandleBridgedTokens` | `0x2ae87cdd` |
| `deployAndHandleBridgedTokensAndCall` | `0xd522cfd7` |
| `handleBridgedTokens` | `0x125e4cfb` |
| `handleBridgedTokensAndCall` | `0xc5345761` |
| `handleNativeTokens` | `0x272255bb` |
| `handleNativeTokensAndCall` | `0x867f7a4d` |
| `fixFailedMessage` | `0x0950d515` |

Bridge mode `getBridgeMode()` = `0xb1516c26` (`multi-erc-to-erc-amb`).

## Production deployment (read 2026-11-06)

Home = Gnosis Chain (chain id 100), Foreign = Ethereum (chain id 1).

### Ethereum (chain id 1)

| Contract | Address | Notes |
| --- | --- | --- |
| AMB (foreign) proxy | `0x4C36d2919e407f0Cc2Ee3c993ccF8ac26d9CE64e` | implementation `0x098f51bdfb5D6d319DD4FDf06b64773d25bD1316`, `maxGasPerTx` 4,000,000 |
| AMB validator contract | `0xed84a648b3c51432ad0fD1C2cD2C45677E9d4064` | `requiredSignatures` 4 of 7 |
| Foreign Omnibridge proxy | `0x88ad09518695c6c3712AC10a214bE5109a655671` | implementation `0x8eB3b7D8498a6716904577b2579e1c313d48E347`, proxy version 6, `requestGasLimit` 2,000,000 |
| Foreign token factory | `0x71d5ba4e37de72415F685490B684538Aae8f0424` | |
| Owner of all of the above | `0x42F38ec5A75acCEc50054671233dfAC9C0E7A3F6` | AMB owner, validator contract owner, Omnibridge owner and proxy upgradeability owner |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | bridged to Gnosis as `0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1` |

### Gnosis Chain (chain id 100)

| Contract | Address | Notes |
| --- | --- | --- |
| AMB (home) proxy | `0x75Df5AF045d91108662D8080fD1FEFAd6aA0bb59` | implementation `0xA033535983d1aBcc2648af730EDCb198909903D7`, `maxGasPerTx` 2,000,000 |
| AMB validator contract | `0xA280feD8D7CaD9a76C8b50cA5c33c2534fFa5008` | `requiredSignatures` 4 of 7 |
| Home Omnibridge proxy | `0xf6A78083ca3e2a662D6dd1703c939c8aCE2e268d` | implementation `0x2dbdCC6CAd1a5a11FD6337244407bC06162aAf92`, proxy version 8 |
| Home token factory | `0xEAAE83ac10f975a6456f4C4E48c45Ea2d8e1b5d2` | |
| Home gas limit manager | `0x68A3674028a785A8BCE19bA81B9ab7c9942BA3ED` | default `requestGasLimit()` 600,000; no per-selector overrides for the deploy/handle selectors |
| Owner of all of the above | `0x7a48Dac683DA91e4faa5aB13D91AB5fd170875bd` | AMB owner, validator contract owner, Omnibridge owner and proxy upgradeability owner |
| WETH (bridged from Ethereum) | `0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1` | `homeMediator.bridgedTokenAddress(WETH on Ethereum)` |

Both Omnibridges point at each other (`mediatorContractOnOtherSide`).

### Validators (same 7 on both AMBs)

`0x59D3C2829900Ae20D02Ca547082b09FD27380eA6`, `0x5524b7a3e2Dc024f4C9c2Ecd7FE003ee316ac624`,
`0xE9fc29AE64c2923FeBb615cB016b77aF9492EBcE`, `0xAD93BffBC65002cC75AD2d5770d3AAfFdefd8D55`,
`0x4A07b8AE561CC558eDD3f1836365AB8e02C52dE2`, `0xb54B5572F3C4f70fF3cc8F67C19C8cddb838FBaA`,
`0x258667E543C913264388B33328337257aF208a8f`

### Hashi

Both AMBs: `HASHI_IS_ENABLED() == true`, `HASHI_IS_MANDATORY() == false`. Messages execute on validator
signatures alone; Hashi approval is not required.

## Relaying AMB messages in tests (no oracle)

`test-e2e/base/E2EBase.sol` does this; reuse it.

1. On each fork, act as the validator contract `owner()` (see tables): `addValidator(mock)` and
   `setRequiredSignatures(1)`.
2. Ethereum -> Gnosis: the foreign AMB emits `UserRequestForAffirmation(bytes32 indexed messageId, bytes encodedData)`.
   On the Gnosis fork, call `executeAffirmation(encodedData)` on the home AMB from the mock validator.
3. Gnosis -> Ethereum: the home AMB emits `UserRequestForSignature(bytes32 indexed messageId, bytes encodedData)`.
   Sign `keccak256("\x19Ethereum Signed Message:\n" + decimal length of encodedData + encodedData)` with the mock
   validator key, pack as `[uint8 count][v...][r...][s...]` (here `abi.encodePacked(uint8(1), v, r, s)`), and call
   `executeSignatures(encodedData, signatures)` on the foreign AMB.
4. Result: `messageCallStatus(messageId)` on the receiving AMB. A failed message can be fixed with
   `requestFailedMessageFix(messageId)` on the receiving mediator, then relaying that message back.

Both AMBs also expose `requireToPassMessage(address,bytes,uint256)`, `messageSender()`, `messageId()`,
`messageSourceChainId()`, `failedMessageSender/Receiver/DataHash(bytes32)`. The foreign AMB has the
`safeExecuteSignatures*` variants of `executeSignatures`; the home AMB has `submitSignature` for the normal oracle flow.

## Unit test conventions (test-foundry/omnibridge)

- `OmnibridgeTestBase` mirrors the JS fixtures: fresh mediator, `AMBMock`, ERC677 token and `TokenReceiver` per
  test; `owner`, `user`, `user2` are `makeAddr` EOAs and calls are made with `vm.prank`.
- `AMBMock.executeMessageCall(executor, sender, data, messageId, gas)` delivers a message;
  `messageCallStatus(messageId)` tells whether it succeeded. Sent messages are `MockedEvent`s with ids starting
  with `0x11223344`.
- JS tests that loop over send functions or decimals become one Foundry test with a loop that calls `setUp()`
  again on each iteration.
- `OmnibridgeCommonTest` holds the shared tests; `HomeOmnibridge.t.sol` / `ForeignOmnibridge.t.sol` add the
  side-specific ones. Use `_isHome()` for small branches inside shared tests.

## CI

- `.github/workflows/main.yml`: Truffle `lint` and `test`, Foundry `forge build --sizes` + `forge test`, coverage
  on master/develop/tags, Docker publish.
- `.github/workflows/e2e.yml`: creates Tenderly VNets (secrets `TENDERLY_API_TOKEN`, `TENDERLY_ACCOUNT_ID`,
  `TENDERLY_PROJECT`), runs `test-e2e/*To*.t.sol`, and runs `test-e2e/Upgrade.t.sol` only when
  `ci/mediators-changed.sh` reports a bytecode change in `HomeOmnibridge`/`ForeignOmnibridge` against the base
  commit (or on a manual run with `upgrade` ticked). VNets are deleted even when a step fails. Pull requests from
  forks skip it (no secrets).
- Locally: `eval "$(ci/tenderly-vnets.sh create)"`, run the tests, then `ci/tenderly-vnets.sh delete`.
