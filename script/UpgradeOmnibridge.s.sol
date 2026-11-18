pragma solidity 0.7.5;
pragma abicoder v2;

import "./base/OmnibridgeScript.sol";
import "../contracts/upgradeability/EternalStorageProxy.sol";
import "../contracts/upgradeable_contracts/HomeOmnibridge.sol";
import "../contracts/upgradeable_contracts/ForeignOmnibridge.sol";

/**
 * @dev Deploys a new mediator implementation and builds the upgrade batch:
 *   1. factory.setDeployer(proxy, true)        only if the new factory does not allow the proxy yet
 *   2. proxy.upgradeTo(version + 1, implementation)
 *   3. mediator.setTokenFactory(newFactory)    only if NEW_TOKEN_FACTORY is set
 *
 * The new implementation calls the 5-argument TokenFactory.deploy, so it must never run against an old factory.
 * Steps 2 and 3 therefore belong to one batch. NEW_TOKEN_FACTORY is required unless the current factory already
 * allows the proxy as a deployer (i.e. is already a CREATE2 TokenFactory).
 *
 * Env:
 *   MEDIATOR             mediator proxy
 *   MEDIATOR_SIDE        "home" (HomeOmnibridge) or "foreign" (ForeignOmnibridge)
 *   TOKEN_NAME_SUFFIX    suffix passed to the implementation constructor, e.g. " from Mainnet"
 *   NEW_TOKEN_FACTORY    token factory to switch to (see DeployTokenFactory.s.sol)
 *
 * upgradeTo needs the proxy's upgradeability owner, setTokenFactory needs the bridge owner and setDeployer needs the
 * factory owner. All of them must be the same account, so the batch can run from one place:
 * - If the broadcaster is that account, the script sends the batch and checks the result.
 * - Otherwise (e.g. a Safe), it sends nothing but the implementation deployment and prints the batch as single calls
 *   and as MultiSend calldata. Execute it as ONE Safe transaction (MultiSendCallOnly); never send the calls one by one.
 * It also prints the rollback batch, which restores the current implementation and factory together.
 */
contract UpgradeOmnibridge is OmnibridgeScript {
    struct Call {
        string label;
        address to;
        bytes data;
    }

    struct Context {
        EternalStorageProxy proxy;
        BasicOmnibridge mediator;
        address owner;
        TokenFactory oldFactory;
        TokenFactory newFactory; // address(0) keeps the current factory
        address oldImplementation;
        address implementation;
        uint256 newVersion;
        bool needsDeployer;
    }

    function run() external returns (address) {
        return
            _run(
                vm.envAddress("MEDIATOR"),
                vm.envString("MEDIATOR_SIDE"),
                vm.envString("TOKEN_NAME_SUFFIX"),
                vm.envOr("NEW_TOKEN_FACTORY", address(0))
            );
    }

    function _run(
        address _mediator,
        string memory _side,
        string memory _suffix,
        address _newFactory
    ) internal returns (address) {
        Context memory c = _loadAndCheck(_mediator, _newFactory);

        vm.startBroadcast();
        address sender = _broadcaster();
        c.implementation = _deployImplementation(_side, _suffix);
        console2.log("New implementation:", c.implementation);

        Call[] memory batch = _upgradeBatch(c);
        if (sender == c.owner) {
            _send(batch);
        } else {
            console2.log("Signer is not the owner. Execute this batch as ONE Safe transaction from", c.owner);
            _printBatch(batch);
        }
        vm.stopBroadcast();

        if (sender == c.owner) {
            _postCheck(c);
            console2.log("Proxy upgraded to version", c.newVersion);
        }

        console2.log("Rollback batch (keep it, do not execute now):");
        _printBatch(_rollbackBatch(c));
        return c.implementation;
    }

    function _loadAndCheck(address _mediator, address _newFactory) internal view returns (Context memory c) {
        c.proxy = EternalStorageProxy(payable(_mediator));
        c.mediator = BasicOmnibridge(_mediator);
        c.newFactory = TokenFactory(_newFactory);
        c.owner = c.mediator.owner();
        c.oldFactory = c.mediator.tokenFactory();
        c.oldImplementation = c.proxy.implementation();
        c.newVersion = c.proxy.version() + 1;

        require(
            c.proxy.upgradeabilityOwner() == c.owner,
            "upgradeability owner and bridge owner differ: upgradeTo and setTokenFactory cannot run in one batch"
        );
        if (address(c.newFactory) == address(0)) {
            require(
                _allowsDeployer(c.oldFactory, address(c.proxy)),
                "NEW_TOKEN_FACTORY required: the current factory does not support the new deploy call"
            );
        } else {
            require(_isContract(address(c.newFactory)), "NEW_TOKEN_FACTORY has no code");
            require(_isContract(c.newFactory.tokenImage()), "NEW_TOKEN_FACTORY has no token image");
            require(c.newFactory.owner() == c.owner, "NEW_TOKEN_FACTORY owner must be the bridge owner");
            c.needsDeployer = !c.newFactory.isDeployer(address(c.proxy));
        }
    }

    function _deployImplementation(string memory _side, string memory _suffix) internal returns (address) {
        if (_equal(_side, "home")) {
            return address(new HomeOmnibridge(_suffix));
        }
        if (_equal(_side, "foreign")) {
            return address(new ForeignOmnibridge(_suffix));
        }
        revert("MEDIATOR_SIDE must be home or foreign");
    }

    function _upgradeBatch(Context memory c) internal pure returns (Call[] memory batch) {
        bool switchFactory = address(c.newFactory) != address(0);
        batch = new Call[]((c.needsDeployer ? 1 : 0) + 1 + (switchFactory ? 1 : 0));
        uint256 n;
        if (c.needsDeployer) {
            batch[n++] = Call(
                "factory.setDeployer(proxy, true)",
                address(c.newFactory),
                abi.encodeWithSelector(TokenFactory.setDeployer.selector, address(c.proxy), true)
            );
        }
        batch[n++] = Call(
            "proxy.upgradeTo(version + 1, implementation)",
            address(c.proxy),
            abi.encodeWithSelector(OwnedUpgradeabilityProxy.upgradeTo.selector, c.newVersion, c.implementation)
        );
        if (switchFactory) {
            batch[n++] = Call(
                "mediator.setTokenFactory(newFactory)",
                address(c.proxy),
                abi.encodeWithSelector(TokenFactoryConnector.setTokenFactory.selector, address(c.newFactory))
            );
        }
    }

    // The old implementation only works with the old factory, so a rollback restores both together.
    function _rollbackBatch(Context memory c) internal pure returns (Call[] memory batch) {
        bool switchFactory = address(c.newFactory) != address(0);
        batch = new Call[](switchFactory ? 2 : 1);
        batch[0] = Call(
            "proxy.upgradeTo(version + 2, oldImplementation)",
            address(c.proxy),
            abi.encodeWithSelector(OwnedUpgradeabilityProxy.upgradeTo.selector, c.newVersion + 1, c.oldImplementation)
        );
        if (switchFactory) {
            batch[1] = Call(
                "mediator.setTokenFactory(oldFactory)",
                address(c.proxy),
                abi.encodeWithSelector(TokenFactoryConnector.setTokenFactory.selector, address(c.oldFactory))
            );
        }
    }

    function _send(Call[] memory _batch) internal {
        for (uint256 i = 0; i < _batch.length; i++) {
            (bool ok, bytes memory ret) = _batch[i].to.call(_batch[i].data);
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            console2.log("Sent:", _batch[i].label);
        }
    }

    function _postCheck(Context memory c) internal view {
        TokenFactory factory = address(c.newFactory) == address(0) ? c.oldFactory : c.newFactory;
        require(c.proxy.implementation() == c.implementation, "post-check: implementation");
        require(c.proxy.version() == c.newVersion, "post-check: version");
        require(address(c.mediator.tokenFactory()) == address(factory), "post-check: token factory");
        require(factory.isDeployer(address(c.proxy)), "post-check: factory deployer");
        require(factory.owner() == c.owner, "post-check: factory owner");
        require(_isContract(factory.tokenImage()), "post-check: token image");
    }

    /**
     * @dev True if `_factory` is a CREATE2 TokenFactory that allows `_deployer`. Old factories have no isDeployer.
     */
    function _allowsDeployer(TokenFactory _factory, address _deployer) internal view returns (bool) {
        try _factory.isDeployer(_deployer) returns (bool allowed) {
            return allowed;
        } catch {
            return false;
        }
    }

    /**
     * @dev Prints every call and the Safe MultiSend calldata: multiSend(bytes) with each call packed as
     * operation (uint8, 0 = call) ++ to ++ value (uint256) ++ data length (uint256) ++ data.
     */
    function _printBatch(Call[] memory _batch) internal view {
        bytes memory packed;
        for (uint256 i = 0; i < _batch.length; i++) {
            console2.log(_batch[i].label);
            console2.log("  to:", _batch[i].to);
            console2.log("  data:");
            console2.logBytes(_batch[i].data);
            packed = abi.encodePacked(
                packed,
                uint8(0),
                _batch[i].to,
                uint256(0),
                uint256(_batch[i].data.length),
                _batch[i].data
            );
        }
        console2.log("MultiSendCallOnly calldata (delegatecall from the Safe):");
        console2.logBytes(abi.encodeWithSignature("multiSend(bytes)", packed));
    }
}
