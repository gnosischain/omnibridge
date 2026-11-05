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

`contracts/helpers/WETHOmnibridgeRouter.sol` does not compile (it calls `relayTokensAndCall`, which `IOmnibridge` lacks),
so `foundry.toml` skips it.

Scripts in `script/` (pass a signer with `--private-key`, `--account` or `--ledger`):

| Script | What it does |
| --- | --- |
| `DeployOmnibridge.s.sol` | Deploys and initializes both sides, like `deploy/deploy.js`. Reads the same variables as `deploy/.env`. |
| `DeployTokenFactory.s.sol` | Deploys the CREATE2 `TokenFactory` through the EIP-7997 factory (same address on every chain for the same signer and salt) and approves a mediator. |
| `UpgradeOmnibridge.s.sol` | Deploys a new mediator implementation, upgrades the proxy, optionally switches the token factory. Prints the calls if the signer is not the owner (e.g. a Safe). |

```bash
set -a; source deploy/.env; set +a
forge script script/DeployOmnibridge.s.sol --broadcast --private-key $DEPLOYMENT_ACCOUNT_PRIVATE_KEY

MEDIATOR=0x... TOKEN_IMAGE=0x... FACTORY_OWNER=0x... \
  forge script script/DeployTokenFactory.s.sol --rpc-url $HOME_RPC_URL --broadcast --account deployer

MEDIATOR=0x... MEDIATOR_SIDE=home TOKEN_NAME_SUFFIX=" from Mainnet" NEW_TOKEN_FACTORY=0x... \
  forge script script/UpgradeOmnibridge.s.sol --rpc-url $HOME_RPC_URL --broadcast --account deployer
```

Notes:
- `DeployOmnibridge.s.sol` broadcasts to two chains. Foundry fails to decode the transactions when the deployer has
  the same nonce on both chains, so the script stops early in that case; send any transaction on one chain first.
- Fees (`HOME_TRANSACTIONS_FEE`, `FOREIGN_TRANSACTIONS_FEE`) are read as decimals, like `deploy.js`.
- Use one token factory per mediator (different `TOKEN_FACTORY_SALT`): the bridged token address depends only on the
  factory and the source token address.

## License

[![License: GPL v3.0](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

This project is licensed under the GNU General Public License v3.0. See the [LICENSE](LICENSE) file for details.



