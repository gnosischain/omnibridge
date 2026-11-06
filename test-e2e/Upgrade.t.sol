pragma solidity 0.7.5;
pragma abicoder v2;

import "./base/E2EBase.sol";

/**
 * @dev Upgrades the production Omnibridge proxies to the implementation in this repo, the same way
 * script/UpgradeOmnibridge.s.sol does (new implementation, upgradeTo), checks that the stored state
 * is unchanged, then bridges through the upgraded production pair.
 */
contract UpgradeE2ETest is E2EBase {
    address internal constant WETH_ETHEREUM = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WETH_GNOSIS = 0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1;

    uint256 internal constant SUPPLY = 1000 ether;
    uint256 internal constant VALUE = 1 ether;

    function setUp() public override {
        super.setUp();
        foreignMediator = ForeignOmnibridge(FOREIGN_OMNIBRIDGE);
        homeMediator = HomeOmnibridge(HOME_OMNIBRIDGE);
    }

    // ---------------------------------------------------------------------
    // Upgrade
    // ---------------------------------------------------------------------

    function _upgrade(uint256 _fork, address _proxy, bool _isHome) internal {
        vm.selectFork(_fork);
        EternalStorageProxy proxy = EternalStorageProxy(payable(_proxy));
        BasicOmnibridge mediator = BasicOmnibridge(_proxy);

        address implementation = _isHome
            ? address(new HomeOmnibridge(HOME_SUFFIX))
            : address(new ForeignOmnibridge(FOREIGN_SUFFIX));
        address factory = address(mediator.tokenFactory());
        uint256 newVersion = proxy.version() + 1;

        vm.prank(proxy.upgradeabilityOwner());
        proxy.upgradeTo(newVersion, implementation);

        assertEq(proxy.implementation(), implementation);
        assertEq(proxy.version(), newVersion);
        assertEq(address(mediator.tokenFactory()), factory);
    }

    function _upgradeBoth() internal {
        _upgrade(foreignFork, FOREIGN_OMNIBRIDGE, false);
        _upgrade(homeFork, HOME_OMNIBRIDGE, true);
        _clearMessages();
    }

    // ---------------------------------------------------------------------
    // State preserved by the upgrade
    // ---------------------------------------------------------------------

    function _commonState(BasicOmnibridge _m, address _token) internal view returns (bytes memory) {
        return
            abi.encode(
                address(_m.bridgeContract()),
                _m.mediatorContractOnOtherSide(),
                _m.owner(),
                _m.dailyLimit(address(0)),
                _m.maxPerTx(address(0)),
                _m.executionDailyLimit(address(0)),
                _m.executionMaxPerTx(address(0)),
                _m.isTokenRegistered(_token),
                _m.dailyLimit(_token),
                _m.maxPerTx(_token),
                _m.executionDailyLimit(_token),
                _m.executionMaxPerTx(_token),
                _m.mediatorBalance(_token)
            );
    }

    function _foreignState() internal returns (bytes memory) {
        vm.selectFork(foreignFork);
        return
            abi.encode(
                _commonState(foreignMediator, WETH_ETHEREUM),
                foreignMediator.requestGasLimit(),
                foreignMediator.isBridgedTokenDeployAcknowledged(WETH_ETHEREUM)
            );
    }

    function _homeState() internal returns (bytes memory) {
        vm.selectFork(homeFork);
        return
            abi.encode(
                _commonState(homeMediator, WETH_GNOSIS),
                address(homeMediator.gasLimitManager()),
                address(homeMediator.feeManager()),
                address(homeMediator.forwardingRulesManager()),
                homeMediator.bridgedTokenAddress(WETH_ETHEREUM),
                homeMediator.nativeTokenAddress(WETH_GNOSIS)
            );
    }

    function test_upgrade_keepsState() public {
        // sanity check of the known token pair used below
        vm.selectFork(homeFork);
        assertEq(homeMediator.bridgedTokenAddress(WETH_ETHEREUM), WETH_GNOSIS);

        bytes memory foreignBefore = _foreignState();
        bytes memory homeBefore = _homeState();

        _upgradeBoth();

        assertEq(keccak256(_foreignState()), keccak256(foreignBefore), "foreign state changed");
        assertEq(keccak256(_homeState()), keccak256(homeBefore), "home state changed");
    }

    // ---------------------------------------------------------------------
    // Bridging through the upgraded production pair
    // ---------------------------------------------------------------------

    // Fee the production fee manager on Gnosis takes for `_value` of `_token` (0 without a fee manager).
    function _homeFee(bool _homeToForeign, address _token, uint256 _value) internal returns (uint256) {
        vm.selectFork(homeFork);
        OmnibridgeFeeManager manager = homeMediator.feeManager();
        if (address(manager) == address(0)) return 0;
        bytes32 feeType = _homeToForeign ? manager.HOME_TO_FOREIGN_FEE() : manager.FOREIGN_TO_HOME_FEE();
        return manager.calculateFee(feeType, _token, _value);
    }

    function test_upgraded_foreignToHomeAndBack() public {
        _upgradeBoth();

        vm.selectFork(foreignFork);
        E2EToken token = _deployToken(SUPPLY);

        // Ethereum -> Gnosis: first bridge deploys the token
        vm.selectFork(foreignFork);
        _relayTokens(foreignMediator, address(token), user, VALUE);
        (, bool status) = _relayToHome();
        assertTrue(status, "message failed on Gnosis");

        ERC20 bridged = ERC20(homeMediator.bridgedTokenAddress(address(token)));
        assertTrue(_hasCode(address(bridged)));
        uint256 received = VALUE - _homeFee(false, address(bridged), VALUE);
        vm.selectFork(homeFork);
        assertEq(bridged.balanceOf(user), received);

        // Gnosis -> Ethereum: bridge everything back
        _relayTokens(homeMediator, address(bridged), user, received);
        uint256 returned = received - _homeFee(true, address(bridged), received);
        (, bool backStatus) = _relayToForeign();
        assertTrue(backStatus, "message failed on Ethereum");

        assertEq(token.balanceOf(user), SUPPLY - VALUE + returned);
        assertEq(foreignMediator.mediatorBalance(address(token)), VALUE - returned);
    }

    function test_upgraded_homeToForeignAndBack() public {
        _upgradeBoth();

        vm.selectFork(homeFork);
        E2EToken token = _deployToken(SUPPLY);

        // Gnosis -> Ethereum: first bridge deploys the token
        vm.selectFork(homeFork);
        _relayTokens(homeMediator, address(token), user, VALUE);
        uint256 sent = VALUE - _homeFee(true, address(token), VALUE);
        (, bool status) = _relayToForeign();
        assertTrue(status, "message failed on Ethereum");

        ERC20 bridged = ERC20(foreignMediator.bridgedTokenAddress(address(token)));
        assertTrue(_hasCode(address(bridged)));
        assertEq(bridged.balanceOf(user), sent);

        // Ethereum -> Gnosis: bridge everything back
        _relayTokens(foreignMediator, address(bridged), user, sent);
        (, bool backStatus) = _relayToHome();
        assertTrue(backStatus, "message failed on Gnosis");

        uint256 returned = sent - _homeFee(false, address(token), sent);
        assertEq(token.balanceOf(user), SUPPLY - VALUE + returned);
    }
}
