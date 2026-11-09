pragma solidity 0.7.5;
pragma abicoder v2;

import "./OmnibridgeCommonTest.sol";

/**
 * @dev Foundry port of contract('HomeOmnibridge') in test/omnibridge/common.test.js:
 * the shared suite plus the home-only gas limit manager, fee and forwarding rules tests.
 */
contract HomeOmnibridgeTest is OmnibridgeCommonTest {
    SelectorTokenGasLimitManager internal gasManager;
    OmnibridgeFeeManager internal feeManager;
    bytes32 internal homeToForeignFee;
    bytes32 internal foreignToHomeFee;

    address internal reward7 = makeAddr("reward7"); // accounts[7]
    address internal reward8 = makeAddr("reward8"); // accounts[8]
    address internal reward9 = makeAddr("reward9"); // accounts[9]

    function _isHome() internal pure override returns (bool) {
        return true;
    }

    function _deployMediator() internal override returns (address) {
        return address(new HomeOmnibridge(SUFFIX));
    }

    function _home() internal view returns (HomeOmnibridge) {
        return HomeOmnibridge(address(mediator));
    }

    // =====================================================================
    // update mediator parameters / gas limit manager
    // =====================================================================

    function _gasManagerSetUp() internal {
        _afterInit();
        gasManager = new SelectorTokenGasLimitManager(IAMB(address(amb)), owner, 1000000);
    }

    function _setGasManager() internal {
        vm.prank(owner);
        _home().setGasLimitManager(address(gasManager));
    }

    function test_gasLimitManager_setNewManager() public {
        _gasManagerSetUp();

        assertEq(address(_home().gasLimitManager()), address(0));

        vm.expectRevert();
        vm.prank(user);
        _home().setGasLimitManager(address(gasManager));
        _setGasManager();

        assertEq(address(_home().gasLimitManager()), address(gasManager));
        assertEq(gasManager.owner(), owner);
        assertEq(address(gasManager.bridge()), address(amb));
        assertEq(gasManager.requestGasLimit(), 1000000);
    }

    function test_gasLimitManager_setForSelector() public {
        _gasManagerSetUp();
        _setGasManager();

        vm.expectRevert();
        vm.prank(user);
        gasManager.setRequestGasLimit(bytes4(0xffffffff), 200000);
        vm.prank(owner);
        gasManager.setRequestGasLimit(bytes4(0xffffffff), 200000);

        assertEq(gasManager.requestGasLimit(bytes4(0xffffffff)), 200000);
        assertEq(gasManager.requestGasLimit(), 1000000);
    }

    function test_gasLimitManager_usedWhenBridgingTokens() public {
        _gasManagerSetUp();
        _setGasManager();

        _send(0, MIN_PER_TX);
        assertTrue(_exec(OTHER_MESSAGE_ID, _handleNativeData(address(token), user, MIN_PER_TX)));
        _send(0, MIN_PER_TX);

        vm.prank(owner);
        gasManager.setRequestGasLimit(HANDLE_BRIDGED_TOKENS, 200000);

        _send(0, MIN_PER_TX);

        AmbMessage[] memory msgs = _ambMessages();
        assertEq(msgs.length, 3);
        assertEq(msgs[0].gas, 1000000);
        assertEq(msgs[1].gas, 1000000);
        assertEq(msgs[2].gas, 200000);
    }

    function test_gasLimitManager_setForSelectorAndToken() public {
        _gasManagerSetUp();
        _setGasManager();

        vm.expectRevert();
        vm.prank(user);
        gasManager.setRequestGasLimit(bytes4(0xffffffff), address(token), 200000);
        vm.prank(owner);
        gasManager.setRequestGasLimit(bytes4(0xffffffff), address(token), 200000);

        assertEq(gasManager.requestGasLimit(bytes4(0xffffffff), address(token)), 200000);
        assertEq(gasManager.requestGasLimit(bytes4(0xffffffff)), 0);
        assertEq(gasManager.requestGasLimit(), 1000000);
    }

    function test_gasLimitManager_usedWhenBridgingSpecificToken() public {
        _gasManagerSetUp();
        _setGasManager();

        vm.prank(owner);
        gasManager.setRequestGasLimit(HANDLE_BRIDGED_TOKENS, 100000);

        _send(0, MIN_PER_TX);
        assertTrue(_exec(OTHER_MESSAGE_ID, _handleNativeData(address(token), user, MIN_PER_TX)));
        _send(0, MIN_PER_TX);

        vm.prank(owner);
        gasManager.setRequestGasLimit(HANDLE_BRIDGED_TOKENS, address(token), 200000);

        _send(0, MIN_PER_TX);

        AmbMessage[] memory msgs = _ambMessages();
        assertEq(msgs.length, 3);
        assertEq(msgs[0].gas, 1000000);
        assertEq(msgs[1].gas, 100000);
        assertEq(msgs[2].gas, 200000);
    }

    // --- common gas limits setters ---

    function test_gasLimitManager_setCommonRequestGasLimits() public {
        _gasManagerSetUp();

        vm.expectRevert();
        vm.prank(user);
        gasManager.setCommonRequestGasLimits(_u7(100, 200, 50, 100, 50, 100, 99));
        vm.expectRevert();
        vm.prank(owner);
        gasManager.setCommonRequestGasLimits(_u7(200, 100, 50, 100, 50, 100, 99));
        vm.expectRevert();
        vm.prank(owner);
        gasManager.setCommonRequestGasLimits(_u7(100, 200, 100, 50, 50, 100, 99));
        vm.expectRevert();
        vm.prank(owner);
        gasManager.setCommonRequestGasLimits(_u7(100, 200, 50, 100, 100, 50, 99));
        vm.expectRevert();
        vm.prank(owner);
        gasManager.setCommonRequestGasLimits(_u7(10, 20, 50, 100, 50, 100, 99));
        vm.prank(owner);
        gasManager.setCommonRequestGasLimits(_u7(100, 200, 50, 100, 50, 100, 99));

        assertEq(gasManager.requestGasLimit(DEPLOY_AND_HANDLE_BRIDGED_TOKENS), 100);
        assertEq(gasManager.requestGasLimit(DEPLOY_AND_HANDLE_BRIDGED_TOKENS_AND_CALL), 200);
        assertEq(gasManager.requestGasLimit(HANDLE_BRIDGED_TOKENS), 50);
        assertEq(gasManager.requestGasLimit(HANDLE_BRIDGED_TOKENS_AND_CALL), 100);
        assertEq(gasManager.requestGasLimit(HANDLE_NATIVE_TOKENS), 50);
        assertEq(gasManager.requestGasLimit(HANDLE_NATIVE_TOKENS_AND_CALL), 100);
        assertEq(gasManager.requestGasLimit(FIX_FAILED_MESSAGE), 99);
    }

    function test_gasLimitManager_setBridgedTokenRequestGasLimits() public {
        _gasManagerSetUp();

        vm.expectRevert();
        vm.prank(user);
        gasManager.setBridgedTokenRequestGasLimits(otherSideToken1, _u2(100, 200));
        vm.expectRevert();
        vm.prank(owner);
        gasManager.setBridgedTokenRequestGasLimits(otherSideToken1, _u2(200, 100));
        vm.prank(owner);
        gasManager.setBridgedTokenRequestGasLimits(otherSideToken1, _u2(100, 200));

        assertEq(gasManager.requestGasLimit(HANDLE_NATIVE_TOKENS, otherSideToken1), 100);
        assertEq(gasManager.requestGasLimit(HANDLE_NATIVE_TOKENS_AND_CALL, otherSideToken1), 200);
    }

    function test_gasLimitManager_setNativeTokenRequestGasLimits() public {
        _gasManagerSetUp();

        vm.expectRevert();
        vm.prank(user);
        gasManager.setNativeTokenRequestGasLimits(otherSideToken1, _u4(100, 200, 50, 100));
        vm.expectRevert();
        vm.prank(owner);
        gasManager.setNativeTokenRequestGasLimits(otherSideToken1, _u4(200, 100, 50, 100));
        vm.expectRevert();
        vm.prank(owner);
        gasManager.setNativeTokenRequestGasLimits(otherSideToken1, _u4(100, 200, 100, 50));
        vm.expectRevert();
        vm.prank(owner);
        gasManager.setNativeTokenRequestGasLimits(otherSideToken1, _u4(10, 20, 50, 100));
        vm.prank(owner);
        gasManager.setNativeTokenRequestGasLimits(otherSideToken1, _u4(100, 200, 50, 100));

        assertEq(gasManager.requestGasLimit(DEPLOY_AND_HANDLE_BRIDGED_TOKENS, otherSideToken1), 100);
        assertEq(gasManager.requestGasLimit(DEPLOY_AND_HANDLE_BRIDGED_TOKENS_AND_CALL, otherSideToken1), 200);
        assertEq(gasManager.requestGasLimit(HANDLE_BRIDGED_TOKENS, otherSideToken1), 50);
        assertEq(gasManager.requestGasLimit(HANDLE_BRIDGED_TOKENS_AND_CALL, otherSideToken1), 100);
    }

    function _u2(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function _u4(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory r) {
        r = new uint256[](4);
        r[0] = a;
        r[1] = b;
        r[2] = c;
        r[3] = d;
    }

    function _u7(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 d,
        uint256 e,
        uint256 f,
        uint256 g
    ) internal pure returns (uint256[] memory r) {
        r = new uint256[](7);
        r[0] = a;
        r[1] = b;
        r[2] = c;
        r[3] = d;
        r[4] = e;
        r[5] = f;
        r[6] = g;
    }

    // =====================================================================
    // fees management
    // =====================================================================

    function _feesSetUp() internal {
        _initialize();

        address[] memory rewards = new address[](1);
        rewards[0] = owner;
        feeManager = new OmnibridgeFeeManager(address(mediator), owner, rewards, [uint256(0.02 ether), 0.01 ether]);
        vm.prank(owner);
        _home().setFeeManager(address(feeManager));

        assertEq(_ambMessages().length, 0);

        homeToForeignFee = feeManager.HOME_TO_FOREIGN_FEE();
        foreignToHomeFee = feeManager.FOREIGN_TO_HOME_FEE();
    }

    function _setFee(bytes32 _feeType, address _token, uint256 _fee) internal {
        vm.prank(owner);
        feeManager.setFee(_feeType, _token, _fee);
    }

    function _assertRewardList(address[] memory _expected) internal {
        address[] memory list = feeManager.rewardAddressList();
        assertEq(list.length, _expected.length);
        for (uint256 i = 0; i < list.length; i++) {
            assertEq(list[i], _expected[i]);
        }
        assertEq(feeManager.rewardAddressCount(), _expected.length);
    }

    function _addresses(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _addresses(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function _addresses(address a, address b, address c) internal pure returns (address[] memory r) {
        r = new address[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function test_fees_changeRewardAddresses() public {
        _feesSetUp();

        vm.expectRevert();
        vm.prank(user);
        feeManager.addRewardAddress(reward8);
        vm.expectRevert();
        vm.prank(owner);
        feeManager.addRewardAddress(owner);
        vm.prank(owner);
        feeManager.addRewardAddress(reward8);

        _assertRewardList(_addresses(owner, reward8));
        assertTrue(feeManager.isRewardAddress(owner));
        assertTrue(feeManager.isRewardAddress(reward8));

        vm.prank(owner);
        feeManager.addRewardAddress(reward9);
        _assertRewardList(_addresses(owner, reward8, reward9));

        vm.expectRevert();
        vm.prank(user);
        feeManager.removeRewardAddress(owner);
        vm.expectRevert();
        vm.prank(owner);
        feeManager.removeRewardAddress(reward7);
        vm.prank(owner);
        feeManager.removeRewardAddress(reward8);
        vm.expectRevert();
        vm.prank(owner);
        feeManager.removeRewardAddress(reward8);

        _assertRewardList(_addresses(owner, reward9));
        assertTrue(!feeManager.isRewardAddress(reward8));

        vm.prank(owner);
        feeManager.removeRewardAddress(owner);
        _assertRewardList(_addresses(reward9));
        assertTrue(!feeManager.isRewardAddress(owner));

        vm.prank(owner);
        feeManager.removeRewardAddress(reward9);
        _assertRewardList(new address[](0));
        assertTrue(!feeManager.isRewardAddress(reward9));
    }

    // --- initialize fees ---

    function test_fees_initializeForNativeToken() public {
        _feesSetUp();

        vm.prank(owner);
        token.mint(user, 10 ether);
        vm.prank(user);
        token.transferAndCall(address(mediator), ONE, "");

        assertEq(feeManager.getFee(homeToForeignFee, address(token)), 0.02 ether);
        assertEq(feeManager.getFee(foreignToHomeFee, address(token)), 0.01 ether);
    }

    function test_fees_initializeForBridgedToken() public {
        _feesSetUp();

        address bridgedToken = address(_deployBridgedToken(user, ONE));

        assertEq(feeManager.getFee(homeToForeignFee, bridgedToken), 0.02 ether);
        assertEq(feeManager.getFee(foreignToHomeFee, bridgedToken), 0.01 ether);
    }

    // --- update fee parameters ---

    function _assertFeeUpdatedEmitted() internal {
        assertEq(_countEvents(address(feeManager), FEE_UPDATED), 1);
        _clearLogs();
    }

    function test_fees_updateDefaultFee() public {
        _feesSetUp();

        vm.expectRevert();
        vm.prank(user);
        feeManager.setFee(homeToForeignFee, address(0), 0.1 ether);
        vm.expectRevert();
        vm.prank(owner);
        feeManager.setFee(homeToForeignFee, address(0), 1.1 ether);
        _clearLogs();
        _setFee(homeToForeignFee, address(0), 0.1 ether);

        _assertFeeUpdatedEmitted();
        assertEq(feeManager.getFee(homeToForeignFee, address(0)), 0.1 ether);
        assertEq(feeManager.getFee(foreignToHomeFee, address(0)), 0.01 ether);
    }

    function test_fees_updateDefaultOppositeDirectionFee() public {
        _feesSetUp();

        vm.expectRevert();
        vm.prank(user);
        feeManager.setFee(foreignToHomeFee, address(0), 0.1 ether);
        vm.expectRevert();
        vm.prank(owner);
        feeManager.setFee(foreignToHomeFee, address(0), 1.1 ether);
        _clearLogs();
        _setFee(foreignToHomeFee, address(0), 0.1 ether);

        _assertFeeUpdatedEmitted();
        assertEq(feeManager.getFee(foreignToHomeFee, address(0)), 0.1 ether);
        assertEq(feeManager.getFee(homeToForeignFee, address(0)), 0.02 ether);
    }

    function test_fees_updateForNativeToken() public {
        _feesSetUp();

        vm.prank(owner);
        token.mint(user, 10 ether);
        vm.prank(user);
        token.transferAndCall(address(mediator), ONE, "");

        _updateTokenFees(address(token));
    }

    function test_fees_updateForBridgedToken() public {
        _feesSetUp();

        address bridgedToken = address(_deployBridgedToken(user, ONE));

        _updateTokenFees(bridgedToken);
    }

    function _updateTokenFees(address _token) internal {
        vm.expectRevert();
        vm.prank(user);
        feeManager.setFee(homeToForeignFee, _token, 0.1 ether);
        vm.expectRevert();
        vm.prank(owner);
        feeManager.setFee(homeToForeignFee, _token, 1.1 ether);
        _clearLogs();
        _setFee(homeToForeignFee, _token, 0.1 ether);
        _assertFeeUpdatedEmitted();
        _setFee(foreignToHomeFee, _token, 0.2 ether);
        _assertFeeUpdatedEmitted();

        assertEq(feeManager.getFee(homeToForeignFee, _token), 0.1 ether);
        assertEq(feeManager.getFee(foreignToHomeFee, _token), 0.2 ether);
    }

    // --- testHomeToForeignFee(isNative) ---

    function _transferToMediator(address _from, uint256 _value) internal {
        vm.prank(_from);
        token.transferAndCall(address(mediator), _value, "");
    }

    function _h2fZeroFee(bool _isNative) internal {
        _setFee(homeToForeignFee, _isNative ? address(0) : address(token), 0);
        assertEq(mediator.totalSpentPerDay(address(token), currentDay), 0);
        _transferToMediator(user, ONE);
        assertEq(mediator.totalSpentPerDay(address(token), currentDay), ONE);
        assertEq(token.balanceOf(address(mediator)), _isNative ? ONE : 0);
        _transferToMediator(user, ONE);
        assertEq(mediator.totalSpentPerDay(address(token), currentDay), TWO);
        assertEq(token.balanceOf(address(mediator)), _isNative ? TWO : 0);

        assertEq(_countEvents(address(mediator), FEE_DISTRIBUTED), 0);
    }

    function _h2fTwoPercentFee(bool _isNative) internal {
        assertEq(mediator.totalSpentPerDay(address(token), currentDay), 0);
        _transferToMediator(user, ONE);
        assertEq(mediator.totalSpentPerDay(address(token), currentDay), ONE);
        assertEq(token.balanceOf(address(mediator)), _isNative ? 0.98 ether : 0);
        assertEq(token.balanceOf(owner), 0.02 ether);
        _transferToMediator(user, ONE);
        assertEq(mediator.totalSpentPerDay(address(token), currentDay), TWO);
        assertEq(token.balanceOf(address(mediator)), _isNative ? 1.96 ether : 0);
        assertEq(token.balanceOf(owner), 0.04 ether);

        assertEq(_countEvents(address(mediator), FEE_DISTRIBUTED), 2);
    }

    function _h2fTwoRewardAddresses(bool _isNative) internal {
        vm.prank(owner);
        feeManager.addRewardAddress(reward9);
        assertEq(feeManager.rewardAddressCount(), 2);

        assertEq(mediator.totalSpentPerDay(address(token), currentDay), 0);
        _transferToMediator(user, 100000000000000050);
        assertEq(mediator.totalSpentPerDay(address(token), currentDay), 100000000000000050);
        assertEq(token.balanceOf(address(mediator)), _isNative ? 98000000000000049 : 0);

        _assertSplitReward(owner, reward9);

        _transferToMediator(user, ONE);
        assertEq(mediator.totalSpentPerDay(address(token), currentDay), 1100000000000000050);
        assertEq(token.balanceOf(address(mediator)), _isNative ? 1078000000000000049 : 0);

        assertEq(_countEvents(address(mediator), FEE_DISTRIBUTED), 2);
    }

    // The odd wei of fee goes to a random reward address.
    function _assertSplitReward(address _a, address _b) internal {
        uint256 balance1 = token.balanceOf(_a);
        uint256 balance2 = token.balanceOf(_b);
        assertTrue(
            (balance1 == 1000000000000001 && balance2 == 1000000000000000) ||
                (balance1 == 1000000000000000 && balance2 == 1000000000000001)
        );
    }

    function _h2fRewardAddressSender(bool _isNative) internal {
        vm.prank(user);
        token.transferAndCall(owner, ONE, "");

        assertEq(mediator.totalSpentPerDay(address(token), currentDay), 0);
        _transferToMediator(owner, ONE);
        assertEq(mediator.totalSpentPerDay(address(token), currentDay), ONE);
        assertEq(token.balanceOf(address(mediator)), _isNative ? ONE : 0);
        assertEq(token.balanceOf(owner), 0);

        assertEq(_countEvents(address(mediator), FEE_DISTRIBUTED), 0);
    }

    // --- distribute fee for native tokens / home => foreign ---

    function _nativeH2FSetUp() internal {
        _feesSetUp();
        vm.prank(owner);
        token.mint(user, 10 ether);
    }

    function test_fees_nativeHomeToForeign_zeroFee() public {
        _nativeH2FSetUp();
        _h2fZeroFee(true);
    }

    function test_fees_nativeHomeToForeign_twoPercentFee() public {
        _nativeH2FSetUp();
        _h2fTwoPercentFee(true);
    }

    function test_fees_nativeHomeToForeign_twoRewardAddresses() public {
        _nativeH2FSetUp();
        _h2fTwoRewardAddresses(true);
    }

    function test_fees_nativeHomeToForeign_noFeeForRewardAddress() public {
        _nativeH2FSetUp();
        _h2fRewardAddressSender(true);
    }

    // --- distribute fee for native tokens / foreign => home ---

    function _nativeF2HSetUp() internal {
        _feesSetUp();
        _setFee(homeToForeignFee, address(0), 0);
        vm.prank(owner);
        token.mint(user, 10 ether);
        _transferToMediator(user, ONE);
        _transferToMediator(user, ONE);
    }

    function test_fees_nativeForeignToHome_zeroFee() public {
        _nativeF2HSetUp();

        _setFee(foreignToHomeFee, address(token), 0);
        bytes memory data = _handleNativeData(address(token), user, ONE);

        assertTrue(_exec(EXAMPLE_MESSAGE_ID, data));

        TokenEvent[] memory evs = _tokenEvents(TOKENS_BRIDGED);
        assertEq(evs.length, 1);
        _assertBridged(evs[0], address(token), user, ONE, EXAMPLE_MESSAGE_ID);
        assertEq(_countEvents(address(mediator), FEE_DISTRIBUTED), 0);

        assertTrue(_exec(OTHER_MESSAGE_ID, data));
        assertEq(mediator.totalExecutedPerDay(address(token), currentDay), TWO);

        evs = _tokenEvents(TOKENS_BRIDGED);
        assertEq(evs.length, 2);
        _assertBridged(evs[1], address(token), user, ONE, OTHER_MESSAGE_ID);
        assertEq(_countEvents(address(mediator), FEE_DISTRIBUTED), 0);

        assertEq(token.balanceOf(user), 10 ether);
        assertEq(token.balanceOf(address(mediator)), 0);
        assertEq(token.balanceOf(owner), 0);
    }

    function test_fees_nativeForeignToHome_onePercentFee() public {
        _nativeF2HSetUp();

        bytes memory data = _handleNativeData(address(token), user, ONE);

        assertTrue(_exec(EXAMPLE_MESSAGE_ID, data));

        TokenEvent[] memory evs = _tokenEvents(TOKENS_BRIDGED);
        assertEq(evs.length, 1);
        _assertBridged(evs[0], address(token), user, 0.99 ether, EXAMPLE_MESSAGE_ID);
        assertEq(_countEvents(address(mediator), FEE_DISTRIBUTED), 1);

        assertEq(token.balanceOf(user), 8.99 ether);
        assertEq(token.balanceOf(address(mediator)), ONE);
        assertEq(token.balanceOf(owner), 0.01 ether);

        assertTrue(_exec(OTHER_MESSAGE_ID, data));
        assertEq(mediator.totalExecutedPerDay(address(token), currentDay), TWO);

        evs = _tokenEvents(TOKENS_BRIDGED);
        assertEq(evs.length, 2);
        _assertBridged(evs[1], address(token), user, 0.99 ether, OTHER_MESSAGE_ID);
        assertEq(_countEvents(address(mediator), FEE_DISTRIBUTED), 2);

        assertEq(token.balanceOf(user), 9.98 ether);
        assertEq(token.balanceOf(address(mediator)), 0);
        assertEq(token.balanceOf(owner), 0.02 ether);
    }

    function test_fees_nativeForeignToHome_twoRewardAddresses() public {
        _nativeF2HSetUp();

        vm.prank(owner);
        feeManager.addRewardAddress(reward9);
        assertEq(feeManager.rewardAddressCount(), 2);

        bytes memory data = _handleNativeData(address(token), user, 200000000000000100);

        assertTrue(_exec(EXAMPLE_MESSAGE_ID, data));

        assertEq(_countEvents(address(mediator), TOKENS_BRIDGED), 1);
        assertEq(_countEvents(address(mediator), FEE_DISTRIBUTED), 1);

        assertEq(token.balanceOf(user), 8198000000000000099);
        assertEq(token.balanceOf(address(mediator)), 1799999999999999900);
        _assertSplitReward(owner, reward9);

        assertTrue(_exec(OTHER_MESSAGE_ID, data));
        assertEq(mediator.totalExecutedPerDay(address(token), currentDay), 400000000000000200);

        assertEq(_countEvents(address(mediator), TOKENS_BRIDGED), 2);
        assertEq(_countEvents(address(mediator), FEE_DISTRIBUTED), 2);
    }

    // --- distribute fee for bridged tokens / foreign => home ---

    function test_fees_bridgedForeignToHome_zeroFee() public {
        _feesSetUp();

        _setFee(foreignToHomeFee, address(0), 0);

        ITestToken bridgedToken = _deployBridgedToken(user, ONE);

        TokenEvent[] memory evs = _tokenEvents(TOKENS_BRIDGED);
        assertEq(evs.length, 1);
        _assertBridged(evs[0], address(bridgedToken), user, ONE, EXAMPLE_MESSAGE_ID);
        assertEq(_countEvents(address(mediator), FEE_DISTRIBUTED), 0);

        assertTrue(_exec(OTHER_MESSAGE_ID, _handleBridgedData(otherSideToken1, user, ONE)));
        assertEq(mediator.totalExecutedPerDay(address(bridgedToken), currentDay), TWO);

        evs = _tokenEvents(TOKENS_BRIDGED);
        assertEq(evs.length, 2);
        _assertBridged(evs[1], address(bridgedToken), user, ONE, OTHER_MESSAGE_ID);
        assertEq(_countEvents(address(mediator), FEE_DISTRIBUTED), 0);

        assertEq(bridgedToken.balanceOf(user), TWO);
        assertEq(bridgedToken.balanceOf(address(mediator)), 0);
        assertEq(bridgedToken.balanceOf(owner), 0);
    }

    function test_fees_bridgedForeignToHome_onePercentFee() public {
        _feesSetUp();

        ITestToken bridgedToken = _deployBridgedToken(user, ONE);

        TokenEvent[] memory evs = _tokenEvents(TOKENS_BRIDGED);
        assertEq(evs.length, 1);
        _assertBridged(evs[0], address(bridgedToken), user, 0.99 ether, EXAMPLE_MESSAGE_ID);
        assertEq(_countEvents(address(mediator), FEE_DISTRIBUTED), 1);

        assertEq(bridgedToken.balanceOf(user), 0.99 ether);
        assertEq(bridgedToken.balanceOf(address(mediator)), 0);
        assertEq(bridgedToken.balanceOf(owner), 0.01 ether);

        assertTrue(_exec(OTHER_MESSAGE_ID, _handleBridgedData(otherSideToken1, user, ONE)));
        assertEq(mediator.totalExecutedPerDay(address(bridgedToken), currentDay), TWO);

        evs = _tokenEvents(TOKENS_BRIDGED);
        assertEq(evs.length, 2);
        _assertBridged(evs[1], address(bridgedToken), user, 0.99 ether, OTHER_MESSAGE_ID);
        assertEq(_countEvents(address(mediator), FEE_DISTRIBUTED), 2);

        assertEq(bridgedToken.balanceOf(user), 1.98 ether);
        assertEq(bridgedToken.balanceOf(address(mediator)), 0);
        assertEq(bridgedToken.balanceOf(owner), 0.02 ether);
    }

    function test_fees_bridgedForeignToHome_twoRewardAddresses() public {
        _feesSetUp();

        vm.prank(owner);
        feeManager.addRewardAddress(reward9);
        assertEq(feeManager.rewardAddressCount(), 2);

        token = _deployBridgedToken(user, 200000000000000100);

        assertEq(_countEvents(address(mediator), TOKENS_BRIDGED), 1);
        assertEq(_countEvents(address(mediator), FEE_DISTRIBUTED), 1);

        assertEq(token.balanceOf(user), 198000000000000099);
        assertEq(token.balanceOf(address(mediator)), 0);
        _assertSplitReward(owner, reward9);

        assertTrue(_exec(OTHER_MESSAGE_ID, _handleBridgedData(otherSideToken1, user, 200000000000000100)));
        assertEq(mediator.totalExecutedPerDay(address(token), currentDay), 400000000000000200);

        assertEq(_countEvents(address(mediator), TOKENS_BRIDGED), 2);
        assertEq(_countEvents(address(mediator), FEE_DISTRIBUTED), 2);
    }

    // --- distribute fee for bridged tokens / home => foreign ---

    function _bridgedH2FSetUp() internal {
        _feesSetUp();
        _setFee(foreignToHomeFee, address(0), 0);
        bytes memory deployData = _deployData(user, ONE);
        assertTrue(_exec(EXAMPLE_MESSAGE_ID, deployData));
        assertTrue(_exec(EXAMPLE_MESSAGE_ID, deployData));
        token = ITestToken(mediator.bridgedTokenAddress(otherSideToken1));
    }

    function test_fees_bridgedHomeToForeign_zeroFee() public {
        _bridgedH2FSetUp();
        _h2fZeroFee(false);
    }

    function test_fees_bridgedHomeToForeign_twoPercentFee() public {
        _bridgedH2FSetUp();
        _h2fTwoPercentFee(false);
    }

    function test_fees_bridgedHomeToForeign_twoRewardAddresses() public {
        _bridgedH2FSetUp();
        _h2fTwoRewardAddresses(false);
    }

    function test_fees_bridgedHomeToForeign_noFeeForRewardAddress() public {
        _bridgedH2FSetUp();
        _h2fRewardAddressSender(false);
    }

    // =====================================================================
    // oracle driven lane permissions
    // =====================================================================

    function test_forwardingRules_updateManagerAddress() public {
        MultiTokenForwardingRulesManager manager = new MultiTokenForwardingRulesManager(owner);
        assertEq(manager.owner(), owner);

        _initialize();
        vm.expectRevert();
        vm.prank(user);
        _home().setForwardingRulesManager(address(manager));
        vm.prank(owner);
        _home().setForwardingRulesManager(address(manager));

        assertEq(address(_home().forwardingRulesManager()), address(manager));

        MultiTokenForwardingRulesManager otherManager = new MultiTokenForwardingRulesManager(address(mediator));
        vm.prank(owner);
        _home().setForwardingRulesManager(address(otherManager));

        assertEq(address(_home().forwardingRulesManager()), address(otherManager));

        vm.expectRevert();
        vm.prank(owner);
        _home().setForwardingRulesManager(owner);
        vm.prank(owner);
        _home().setForwardingRulesManager(address(0));

        assertEq(address(_home().forwardingRulesManager()), address(0));
    }

    function test_forwardingRules_setLanePermissions() public {
        MultiTokenForwardingRulesManager manager = new MultiTokenForwardingRulesManager(owner);
        address t = address(token);

        assertEq(manager.destinationLane(t, user, user2), 0);

        vm.expectRevert();
        vm.prank(user);
        manager.setTokenForwardingRule(t, true);
        vm.prank(owner);
        manager.setTokenForwardingRule(t, true);

        assertEq(manager.destinationLane(t, user, user2), 1);

        vm.expectRevert();
        vm.prank(user);
        manager.setSenderExceptionForTokenForwardingRule(t, user, true);
        vm.prank(owner);
        manager.setSenderExceptionForTokenForwardingRule(t, user, true);

        assertEq(manager.destinationLane(t, user, user2), -1);
        assertEq(manager.destinationLane(t, user2, user2), 1);

        vm.prank(owner);
        manager.setSenderExceptionForTokenForwardingRule(t, user, false);
        vm.expectRevert();
        vm.prank(user);
        manager.setReceiverExceptionForTokenForwardingRule(t, user, true);
        vm.prank(owner);
        manager.setReceiverExceptionForTokenForwardingRule(t, user, true);

        assertEq(manager.destinationLane(t, user, user), -1);
        assertEq(manager.destinationLane(t, user, user2), 1);

        vm.prank(owner);
        manager.setTokenForwardingRule(t, false);

        assertEq(manager.destinationLane(t, user2, user2), 0);

        vm.expectRevert();
        vm.prank(user);
        manager.setSenderForwardingRule(user2, true);
        vm.prank(owner);
        manager.setSenderForwardingRule(user2, true);

        assertEq(manager.destinationLane(t, user2, user2), 1);

        vm.expectRevert();
        vm.prank(user);
        manager.setReceiverForwardingRule(user2, true);
        vm.prank(owner);
        manager.setReceiverForwardingRule(user2, true);

        assertEq(manager.destinationLane(t, user, user2), 1);
    }

    function test_forwardingRules_sendToOracleDrivenLane() public {
        MultiTokenForwardingRulesManager manager = new MultiTokenForwardingRulesManager(owner);

        _initialize();
        vm.prank(owner);
        token.mint(user, 10 ether);
        ITestToken bridgedToken = _deployBridgedToken(user, ONE);

        _transferToMediator(user, 0.1 ether);
        vm.prank(user);
        bridgedToken.transferAndCall(address(mediator), 0.1 ether, "");
        vm.prank(owner);
        _home().setForwardingRulesManager(address(manager));
        _transferToMediator(user, 0.1 ether);
        vm.prank(user);
        bridgedToken.transferAndCall(address(mediator), 0.1 ether, "");
        vm.prank(owner);
        manager.setTokenForwardingRule(address(token), true);
        vm.prank(owner);
        manager.setTokenForwardingRule(address(bridgedToken), true);
        _transferToMediator(user, 0.1 ether);
        vm.prank(user);
        bridgedToken.transferAndCall(address(mediator), 0.1 ether, "");

        AmbMessage[] memory msgs = _ambMessages();
        assertEq(msgs.length, 6);
        assertEq(uint256(msgs[0].dataType), 0);
        assertEq(uint256(msgs[1].dataType), 0);
        assertEq(uint256(msgs[2].dataType), 128);
        assertEq(uint256(msgs[3].dataType), 128);
        assertEq(uint256(msgs[4].dataType), 0);
        assertEq(uint256(msgs[5].dataType), 0);
    }
}
