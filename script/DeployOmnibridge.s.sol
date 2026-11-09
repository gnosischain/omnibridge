pragma solidity 0.7.5;
pragma abicoder v2;

import "./base/OmnibridgeScript.sol";
import "../contracts/upgradeability/EternalStorageProxy.sol";
import "../contracts/upgradeable_contracts/HomeOmnibridge.sol";
import "../contracts/upgradeable_contracts/ForeignOmnibridge.sol";
import "../contracts/upgradeable_contracts/modules/fee_manager/OmnibridgeFeeManager.sol";
import "../contracts/upgradeable_contracts/modules/gas_limit/SelectorTokenGasLimitManager.sol";
import "../contracts/upgradeable_contracts/modules/forwarding_rules/MultiTokenForwardingRulesManager.sol";

/**
 * @dev Foundry version of deploy/deploy.js: deploys and initializes both sides of a new Omnibridge.
 * Reads the same variables as deploy/.env (see deploy/.env.example).
 *
 * Usage:
 *   set -a; source deploy/.env; set +a
 *   forge script script/DeployOmnibridge.s.sol --broadcast --private-key $DEPLOYMENT_ACCOUNT_PRIVATE_KEY
 */
contract DeployOmnibridge is OmnibridgeScript {
    struct Home {
        EternalStorageProxy proxy;
        address tokenFactory;
        address feeManager;
        address gasLimitManager;
        address forwardingRulesManager;
    }

    struct Foreign {
        EternalStorageProxy proxy;
        address tokenFactory;
    }

    uint256 internal homeFork;
    uint256 internal foreignFork;

    function run() external returns (address homeMediator, address foreignMediator) {
        homeFork = vm.createFork(vm.envString("HOME_RPC_URL"));
        foreignFork = vm.createFork(vm.envString("FOREIGN_RPC_URL"));
        _checkNonces();

        Home memory home = _deployHome();
        Foreign memory foreign = _deployForeign();
        _initializeHome(home, address(foreign.proxy));
        _initializeForeign(foreign, address(home.proxy));

        homeMediator = address(home.proxy);
        foreignMediator = address(foreign.proxy);
        console2.log("\nDeployment has been completed.");
        console2.log("[   Home  ] Bridge Mediator:", homeMediator);
        console2.log("[ Foreign ] Bridge Mediator:", foreignMediator);
    }

    /**
     * @dev Foundry multi-chain broadcasts fail ("Failed to decode constructor arguments") when the deployer has the
     * same nonce on both chains, because different contracts then share an address. Stop early with a clear message.
     */
    function _checkNonces() internal {
        vm.selectFork(homeFork);
        vm.startBroadcast();
        address deployer = _broadcaster();
        vm.stopBroadcast();
        uint64 homeNonce = vm.getNonce(deployer);
        vm.selectFork(foreignFork);
        uint64 foreignNonce = vm.getNonce(deployer);
        require(
            homeNonce != foreignNonce,
            "deployer has the same nonce on both chains; send one transaction on either chain first"
        );
    }

    function _deployHome() internal returns (Home memory home) {
        vm.selectFork(homeFork);
        vm.startBroadcast();
        address owner = vm.envAddress("HOME_BRIDGE_OWNER");

        home.proxy = new EternalStorageProxy();
        console2.log("[Home] Bridge Mediator storage:", address(home.proxy));

        home.tokenFactory = _tokenFactory("HOME", owner);
        home.feeManager = _homeFeeManager(address(home.proxy), owner);
        home.forwardingRulesManager = _homeForwardingRulesManager(owner);

        home.gasLimitManager = address(
            new SelectorTokenGasLimitManager(
                IAMB(vm.envAddress("HOME_AMB_BRIDGE")),
                owner,
                vm.envUint("HOME_MEDIATOR_REQUEST_GAS_LIMIT")
            )
        );
        console2.log("[Home] Gas limit manager:", home.gasLimitManager);
        console2.log("[Home] Please, call setCommonRequestGasLimits on the Gas Limit Manager contract.");

        address implementation = address(new HomeOmnibridge(vm.envString("HOME_TOKEN_NAME_SUFFIX")));
        console2.log("[Home] Bridge Mediator implementation:", implementation);
        home.proxy.upgradeTo(1, implementation);
        vm.stopBroadcast();
    }

    function _deployForeign() internal returns (Foreign memory foreign) {
        vm.selectFork(foreignFork);
        vm.startBroadcast();

        foreign.proxy = new EternalStorageProxy();
        console2.log("[Foreign] Bridge Mediator storage:", address(foreign.proxy));

        foreign.tokenFactory = _tokenFactory("FOREIGN", vm.envAddress("FOREIGN_BRIDGE_OWNER"));

        address implementation = address(new ForeignOmnibridge(vm.envString("FOREIGN_TOKEN_NAME_SUFFIX")));
        console2.log("[Foreign] Bridge Mediator implementation:", implementation);
        foreign.proxy.upgradeTo(1, implementation);
        vm.stopBroadcast();
    }

    function _initializeHome(Home memory _home, address _foreignMediator) internal {
        vm.selectFork(homeFork);
        vm.startBroadcast();
        HomeOmnibridge(address(_home.proxy)).initialize(
            vm.envAddress("HOME_AMB_BRIDGE"),
            _foreignMediator,
            [
                vm.envUint("HOME_DAILY_LIMIT"),
                vm.envUint("HOME_MAX_AMOUNT_PER_TX"),
                vm.envUint("HOME_MIN_AMOUNT_PER_TX")
            ],
            [vm.envUint("FOREIGN_DAILY_LIMIT"), vm.envUint("FOREIGN_MAX_AMOUNT_PER_TX")],
            _home.gasLimitManager,
            vm.envAddress("HOME_BRIDGE_OWNER"),
            _home.tokenFactory,
            _home.feeManager,
            _home.forwardingRulesManager
        );
        _home.proxy.transferProxyOwnership(vm.envAddress("HOME_UPGRADEABLE_ADMIN"));
        vm.stopBroadcast();
    }

    function _initializeForeign(Foreign memory _foreign, address _homeMediator) internal {
        vm.selectFork(foreignFork);
        vm.startBroadcast();
        ForeignOmnibridge(address(_foreign.proxy)).initialize(
            vm.envAddress("FOREIGN_AMB_BRIDGE"),
            _homeMediator,
            [
                vm.envUint("FOREIGN_DAILY_LIMIT"),
                vm.envUint("FOREIGN_MAX_AMOUNT_PER_TX"),
                vm.envUint("FOREIGN_MIN_AMOUNT_PER_TX")
            ],
            [vm.envUint("HOME_DAILY_LIMIT"), vm.envUint("HOME_MAX_AMOUNT_PER_TX")],
            vm.envUint("FOREIGN_MEDIATOR_REQUEST_GAS_LIMIT"),
            vm.envAddress("FOREIGN_BRIDGE_OWNER"),
            _foreign.tokenFactory
        );
        _foreign.proxy.transferProxyOwnership(vm.envAddress("FOREIGN_UPGRADEABLE_ADMIN"));
        vm.stopBroadcast();
    }

    /**
     * @dev Uses <SIDE>_TOKEN_FACTORY if set, otherwise deploys a new factory owned by the bridge owner
     * (and a token image unless <SIDE>_ERC677_TOKEN_IMAGE is set), like deploy.js.
     */
    function _tokenFactory(string memory _side, address _owner) internal returns (address) {
        address existing = vm.envOr(string(abi.encodePacked(_side, "_TOKEN_FACTORY")), address(0));
        if (existing != address(0)) {
            console2.log("Using existing token factory:", existing);
            return existing;
        }

        address image = vm.envOr(string(abi.encodePacked(_side, "_ERC677_TOKEN_IMAGE")), address(0));
        if (image == address(0)) {
            image = _deployTokenImage();
        }
        address factory = address(new TokenFactory(_owner, image));
        console2.log("Token factory deployed:", factory);
        return factory;
    }

    function _homeFeeManager(address _mediator, address _owner) internal returns (address) {
        if (!_equal(vm.envOr("HOME_REWARDABLE", string("false")), "BOTH_DIRECTIONS")) {
            return address(0);
        }
        uint256[2] memory fees =
            [_parseEther(vm.envString("HOME_TRANSACTIONS_FEE")), _parseEther(vm.envString("FOREIGN_TRANSACTIONS_FEE"))];
        address[] memory rewardList = vm.envAddress("HOME_MEDIATOR_REWARD_ACCOUNTS", " ");
        address manager = address(new OmnibridgeFeeManager(_mediator, _owner, rewardList, fees));
        console2.log("[Home] Fee manager:", manager);
        return manager;
    }

    /**
     * @dev HOME_FORWARDING_RULES_MANAGER: "false" = none, empty = deploy a new one, address = use it.
     */
    function _homeForwardingRulesManager(address _owner) internal returns (address) {
        string memory value = vm.envOr("HOME_FORWARDING_RULES_MANAGER", string("false"));
        if (_equal(value, "false")) {
            return address(0);
        }
        if (bytes(value).length > 0) {
            return vm.parseAddress(value);
        }
        address manager = address(new MultiTokenForwardingRulesManager(_owner));
        console2.log("[Home] Forwarding rules manager:", manager);
        return manager;
    }
}
