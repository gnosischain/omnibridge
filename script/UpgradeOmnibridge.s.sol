pragma solidity 0.7.5;
pragma abicoder v2;

import "./base/OmnibridgeScript.sol";
import "../contracts/upgradeability/EternalStorageProxy.sol";
import "../contracts/upgradeable_contracts/HomeOmnibridge.sol";
import "../contracts/upgradeable_contracts/ForeignOmnibridge.sol";

/**
 * @dev Deploys a new mediator implementation and upgrades the proxy to it. Optionally switches the token factory.
 *
 * Env:
 *   MEDIATOR             mediator proxy
 *   MEDIATOR_SIDE        "home" (HomeOmnibridge) or "foreign" (ForeignOmnibridge)
 *   TOKEN_NAME_SUFFIX    suffix passed to the implementation constructor, e.g. " from Mainnet"
 *   NEW_TOKEN_FACTORY    optional, token factory to switch to (see DeployTokenFactory.s.sol)
 *
 * upgradeTo needs the proxy's upgradeability owner, setTokenFactory needs the bridge owner and
 * setDeployer (allowing the mediator on NEW_TOKEN_FACTORY) needs the factory owner.
 * If the broadcaster is not that account (e.g. a Safe), the script prints the calls instead.
 * Run both calls in one Safe batch (MultiSend) so the old implementation never talks to the new factory.
 */
contract UpgradeOmnibridge is OmnibridgeScript {
    function run() external returns (address implementation) {
        EternalStorageProxy proxy = EternalStorageProxy(payable(vm.envAddress("MEDIATOR")));
        string memory side = vm.envString("MEDIATOR_SIDE");
        string memory suffix = vm.envString("TOKEN_NAME_SUFFIX");

        vm.startBroadcast();
        address sender = _broadcaster();

        if (_equal(side, "home")) {
            implementation = address(new HomeOmnibridge(suffix));
        } else if (_equal(side, "foreign")) {
            implementation = address(new ForeignOmnibridge(suffix));
        } else {
            revert("MEDIATOR_SIDE must be home or foreign");
        }
        console2.log("New implementation:", implementation);

        uint256 newVersion = proxy.version() + 1;
        bool upgraded = sender == proxy.upgradeabilityOwner();
        if (upgraded) {
            proxy.upgradeTo(newVersion, implementation);
            console2.log("Proxy upgraded to version", newVersion);
        } else {
            _printCall(
                "upgradeTo (by upgradeability owner)",
                address(proxy),
                abi.encodeWithSelector(proxy.upgradeTo.selector, newVersion, implementation)
            );
        }

        address newFactory = vm.envOr("NEW_TOKEN_FACTORY", address(0));
        if (newFactory != address(0)) {
            // The new factory only accepts deploy() calls from allowed deployers.
            _setFactoryDeployer(TokenFactory(newFactory), address(proxy));
        }

        vm.stopBroadcast();
    }

    function _printCall(
        string memory _label,
        address _to,
        bytes memory _data
    ) internal view {
        console2.log(_label);
        console2.log("  to:", _to);
        console2.log("  data:");
        console2.logBytes(_data);
    }
}
