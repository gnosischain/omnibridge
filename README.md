[![Join the chat at https://gitter.im/poanetwork/poa-bridge](https://badges.gitter.im/poanetwork/poa-bridge.svg)](https://gitter.im/poanetwork/poa-bridge?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge)
[![Build Status](https://github.com/poanetwork/omnibridge/workflows/omnibridge-contracts/badge.svg?branch=master)](https://github.com/poanetwork/omnibridge/workflows/omnibridge-contracts/badge.svg?branch=master)

# Omnibridge Smart Contracts
These contracts provide the core functionality for the Omnibridge AMB extension.

## Development

Truffle and Foundry are set up side by side and compile the same `contracts/` with the same settings
(solc 0.7.5, optimizer 200 runs, `istanbul`). Both need `yarn` first, for `@openzeppelin/contracts`.

### Truffle

`yarn compile`, `yarn test` (JS tests in `test/`, needs Docker), `yarn coverage`, `yarn deploy` (see [deploy/README.md](deploy/README.md)).

### Foundry

```bash
git submodule update --init --recursive   # forge-std
yarn                                      # @openzeppelin/contracts
forge build                               # or: yarn forge:build
forge test -vvv                           # Solidity tests in test-foundry/; or: yarn forge:test
forge coverage --report summary           # or: yarn forge:coverage
```

`test-foundry/omnibridge/` is a port of the JS tests in `test/omnibridge/common.test.js`, except the Compound and
AAVE connector tests, which need the docker test chain.

`contracts/helpers/WETHOmnibridgeRouter.sol` does not compile (it calls `relayTokensAndCall`, which `IOmnibridge` lacks),
so `foundry.toml` skips it.

Scripts in `script/` (pass a signer with `--private-key`, `--account` or `--ledger`):

| Script | What it does |
| --- | --- |
| `DeployOmnibridge.s.sol` | Deploys and initializes both sides, like `deploy/deploy.js`. Reads the same variables as `deploy/.env`. |
| `UpgradeOmnibridge.s.sol` | Deploys a new mediator implementation and upgrades the proxy. Prints the call if the signer is not the proxy owner (e.g. a Safe). |

```bash
set -a; source deploy/.env; set +a
forge script script/DeployOmnibridge.s.sol --broadcast --private-key $DEPLOYMENT_ACCOUNT_PRIVATE_KEY

MEDIATOR=0x... MEDIATOR_SIDE=home TOKEN_NAME_SUFFIX=" from Mainnet" \
  forge script script/UpgradeOmnibridge.s.sol --rpc-url $HOME_RPC_URL --broadcast --account deployer
```

`DeployOmnibridge.s.sol` broadcasts to two chains. Foundry fails to decode the transactions when the deployer has
the same nonce on both chains, so the script stops early in that case; send any transaction on one chain first.

### E2E tests

`test-e2e/` holds Foundry fork tests that fork Ethereum and Gnosis Chain in the same test and use the production
AMB contracts (`0x4C36…E64e` on Ethereum, `0x75Df…bb59` on Gnosis Chain). Each test adds a mock validator to the AMB
validator contracts with the threshold set to 1, and carries the messages between the chains itself, so no off-chain
oracle is needed.

| File | What it tests |
| --- | --- |
| `ForeignToHome.t.sol`, `HomeToForeign.t.sol` | A new Omnibridge pair on top of the production AMBs: first and repeated bridging, `relayTokensAndCall`, bridging back, fixing a failed message, limits. |
| `Upgrade.t.sol` | Upgrades the production Omnibridge proxies (`0x88ad…5671` on Ethereum, `0xf6A7…268d` on Gnosis Chain), checks the stored state is unchanged, then bridges both ways. |

```bash
FOREIGN_RPC_URL=<Ethereum RPC> HOME_RPC_URL=<Gnosis Chain RPC> FOUNDRY_PROFILE=e2e forge test
```

In CI (`.github/workflows/e2e.yml`), `ci/tenderly-vnets.sh` creates a Tenderly Virtual TestNet for each chain
and deletes them at the end. It needs the `TENDERLY_API_TOKEN`, `TENDERLY_ACCOUNT_ID` and `TENDERLY_PROJECT` secrets.
The upgrade test only runs when `ci/mediators-changed.sh` finds that the `HomeOmnibridge` or `ForeignOmnibridge`
bytecode differs from the base commit, or when the workflow is started by hand with `upgrade` ticked.

## License

[![License: GPL v3.0](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

This project is licensed under the GNU General Public License v3.0. See the [LICENSE](LICENSE) file for details.



