pragma solidity 0.7.5;
pragma abicoder v2;

import "./OmnibridgeTestBase.sol";

/**
 * @dev Foundry port of the shared part of test/omnibridge/common.test.js (runTests).
 * Runs against both mediators through HomeOmnibridgeTest and ForeignOmnibridgeTest.
 * Tests that loop over send functions or decimals rebuild the fixture for every iteration,
 * matching the separate `it` blocks in the JS suite.
 */
abstract contract OmnibridgeCommonTest is OmnibridgeTestBase {
    // =====================================================================
    // getBridgeMode
    // =====================================================================

    function test_getBridgeMode() public {
        // 4 bytes of keccak256('multi-erc-to-erc-amb')
        assertEq(mediator.getBridgeMode(), bytes4(0xb1516c26));

        (uint64 major, uint64 minor, uint64 patch) = mediator.getBridgeInterfacesVersion();
        assertTrue(major >= 0 && minor >= 0 && patch >= 0);
    }

    // =====================================================================
    // claimTokens
    // =====================================================================

    function _claimTokensSetUp() internal {
        _useProxy();
        _initialize();
    }

    function test_claimTokens_unknownToken() public {
        _claimTokensSetUp();

        vm.prank(owner);
        token.mint(user, ONE);
        assertEq(token.balanceOf(user), ONE);

        vm.prank(user);
        token.transfer(address(mediator), ONE);
        assertEq(token.balanceOf(user), 0);
        assertEq(token.balanceOf(address(mediator)), ONE);

        vm.expectRevert();
        vm.prank(user);
        mediator.claimTokens(address(token), claimReceiver);
        vm.prank(owner);
        mediator.claimTokens(address(token), claimReceiver);

        assertEq(token.balanceOf(address(mediator)), 0);
        assertEq(token.balanceOf(claimReceiver), ONE);
    }

    function test_claimTokens_nativeCoins() public {
        _claimTokensSetUp();

        vm.deal(address(this), ONE);
        try new Sacrifice{ value: ONE }(payable(address(mediator))) {} catch {}
        assertEq(address(mediator).balance, ONE);
        uint256 balanceBefore = claimReceiver.balance;

        vm.expectRevert();
        vm.prank(user);
        mediator.claimTokens(address(0), claimReceiver);
        vm.prank(owner);
        mediator.claimTokens(address(0), claimReceiver);

        assertEq(address(mediator).balance, 0);
        assertEq(claimReceiver.balance, balanceBefore + ONE);
    }

    function test_claimTokens_notForNativeBridgedToken() public {
        _claimTokensSetUp();

        vm.prank(owner);
        token.mint(user, ONE);
        assertEq(token.balanceOf(user), ONE);

        vm.prank(user);
        token.transferAndCall(address(mediator), ONE, "");
        assertEq(token.balanceOf(user), 0);
        assertGt(token.balanceOf(address(mediator)), 0);

        vm.expectRevert();
        vm.prank(user);
        mediator.claimTokens(address(token), claimReceiver);
        vm.expectRevert();
        vm.prank(owner);
        mediator.claimTokens(address(token), claimReceiver);
    }

    function test_claimTokens_fromTokenContract() public {
        _claimTokensSetUp();

        address bridgedToken = address(_deployBridgedToken(user, ONE));

        vm.prank(owner);
        token.mint(user, 1);
        vm.prank(user);
        token.transfer(bridgedToken, 1);

        vm.expectRevert();
        vm.prank(user);
        mediator.claimTokensFromTokenContract(bridgedToken, address(token), claimReceiver);
        vm.prank(owner);
        mediator.claimTokensFromTokenContract(bridgedToken, address(token), claimReceiver);

        assertEq(token.balanceOf(claimReceiver), 1);
    }

    // =====================================================================
    // initialize
    // =====================================================================

    function test_initialize() public {
        // Given
        assertTrue(!mediator.isInitialized());
        assertEq(address(mediator.bridgeContract()), address(0));
        assertEq(mediator.mediatorContractOnOtherSide(), address(0));
        assertEq(mediator.dailyLimit(address(0)), 0);
        assertEq(mediator.maxPerTx(address(0)), 0);
        assertEq(mediator.minPerTx(address(0)), 0);
        assertEq(mediator.executionDailyLimit(address(0)), 0);
        assertEq(mediator.executionMaxPerTx(address(0)), 0);
        if (_isHome()) {
            assertEq(address(HomeOmnibridge(address(mediator)).gasLimitManager()), address(0));
        } else {
            assertEq(ForeignOmnibridge(address(mediator)).requestGasLimit(), 0);
        }
        assertEq(mediator.owner(), address(0));
        assertEq(address(mediator.tokenFactory()), address(0));

        // When
        InitArgs memory a;

        // not valid bridge address
        a = _defaultInitArgs();
        a.ambContract = address(0);
        vm.expectRevert();
        _initialize(a);

        // dailyLimit > maxPerTx
        a = _defaultInitArgs();
        a.limits = [MAX_PER_TX, MAX_PER_TX, MIN_PER_TX];
        vm.expectRevert();
        _initialize(a);

        // maxPerTx > minPerTx
        a = _defaultInitArgs();
        a.limits = [DAILY_LIMIT, MIN_PER_TX, MIN_PER_TX];
        vm.expectRevert();
        _initialize(a);

        // executionDailyLimit > executionMaxPerTx
        a = _defaultInitArgs();
        a.executionLimits = [EXECUTION_DAILY_LIMIT, EXECUTION_DAILY_LIMIT];
        vm.expectRevert();
        _initialize(a);

        if (_isHome()) {
            // gas limit manager is not a contract
            a = _defaultInitArgs();
            a.gasLimitManager = owner;
            vm.expectRevert();
            _initialize(a);

            // fee manager is not a contract
            a = _defaultInitArgs();
            a.feeManager = owner;
            vm.expectRevert();
            _initialize(a);

            // forwarding rules manager is not a contract
            a = _defaultInitArgs();
            a.forwardingRulesManager = owner;
            vm.expectRevert();
            _initialize(a);
        } else {
            // maxGasPerTx > bridge maxGasPerTx
            a = _defaultInitArgs();
            a.requestGasLimit = 1 ether;
            vm.expectRevert();
            _initialize(a);
        }

        // not valid owner
        a = _defaultInitArgs();
        a.owner = address(0);
        vm.expectRevert();
        _initialize(a);

        // token factory is not a contract
        a = _defaultInitArgs();
        a.tokenFactory = owner;
        vm.expectRevert();
        _initialize(a);

        _clearLogs();
        _initialize();
        _assertDefaultLimitEvent(EXECUTION_DAILY_LIMIT_CHANGED, EXECUTION_DAILY_LIMIT);
        _assertDefaultLimitEvent(DAILY_LIMIT_CHANGED, DAILY_LIMIT);

        // already initialized
        vm.expectRevert();
        _initialize();

        // Then
        assertTrue(mediator.isInitialized());
        assertEq(address(mediator.bridgeContract()), address(amb));
        assertEq(mediator.mediatorContractOnOtherSide(), otherSideMediator);
        assertEq(mediator.dailyLimit(address(0)), DAILY_LIMIT);
        assertEq(mediator.maxPerTx(address(0)), MAX_PER_TX);
        assertEq(mediator.minPerTx(address(0)), MIN_PER_TX);
        assertEq(mediator.executionDailyLimit(address(0)), EXECUTION_DAILY_LIMIT);
        assertEq(mediator.executionMaxPerTx(address(0)), EXECUTION_MAX_PER_TX);
        if (_isHome()) {
            assertEq(address(HomeOmnibridge(address(mediator)).gasLimitManager()), address(0));
        } else {
            assertEq(ForeignOmnibridge(address(mediator)).requestGasLimit(), 1000000);
        }
        assertEq(mediator.owner(), owner);
        assertEq(address(mediator.tokenFactory()), address(tokenFactory));
    }

    function _assertDefaultLimitEvent(bytes32 _sig, uint256 _limit) internal {
        RecordedLog[] memory logs = _events(address(mediator), _sig);
        assertEq(logs.length, 1);
        assertEq(_topicAddress(logs[0].topics[1]), address(0));
        assertEq(abi.decode(logs[0].data, (uint256)), _limit);
    }

    // =====================================================================
    // afterInitialization / update mediator parameters / limits
    // =====================================================================

    function test_limits_updateDefaultDailyLimits() public {
        _afterInit();

        vm.expectRevert();
        vm.prank(user);
        mediator.setDailyLimit(address(0), 5 ether);
        vm.expectRevert();
        vm.prank(user);
        mediator.setExecutionDailyLimit(address(0), 5 ether);
        vm.expectRevert();
        vm.prank(owner);
        mediator.setDailyLimit(address(0), 0.5 ether);
        vm.expectRevert();
        vm.prank(owner);
        mediator.setExecutionDailyLimit(address(0), 0.5 ether);
        vm.prank(owner);
        mediator.setDailyLimit(address(0), 5 ether);
        vm.prank(owner);
        mediator.setExecutionDailyLimit(address(0), 5 ether);

        assertEq(mediator.dailyLimit(address(0)), 5 ether);
        assertEq(mediator.executionDailyLimit(address(0)), 5 ether);

        vm.prank(owner);
        mediator.setDailyLimit(address(0), 0);
        vm.prank(owner);
        mediator.setExecutionDailyLimit(address(0), 0);

        assertEq(mediator.dailyLimit(address(0)), 0);
        assertEq(mediator.executionDailyLimit(address(0)), 0);
    }

    function test_limits_updateDefaultMaxPerTx() public {
        _afterInit();

        vm.expectRevert();
        vm.prank(user);
        mediator.setMaxPerTx(address(0), 1.5 ether);
        vm.expectRevert();
        vm.prank(user);
        mediator.setExecutionMaxPerTx(address(0), 1.5 ether);
        vm.expectRevert();
        vm.prank(owner);
        mediator.setMaxPerTx(address(0), 5 ether);
        vm.expectRevert();
        vm.prank(owner);
        mediator.setExecutionMaxPerTx(address(0), 5 ether);
        vm.expectRevert();
        vm.prank(owner);
        mediator.setMaxPerTx(address(0), 0.001 ether);
        vm.prank(owner);
        mediator.setMaxPerTx(address(0), 1.5 ether);
        vm.prank(owner);
        mediator.setExecutionMaxPerTx(address(0), 1.5 ether);

        assertEq(mediator.maxPerTx(address(0)), 1.5 ether);
        assertEq(mediator.executionMaxPerTx(address(0)), 1.5 ether);

        vm.prank(owner);
        mediator.setMaxPerTx(address(0), 0);
        vm.prank(owner);
        mediator.setExecutionMaxPerTx(address(0), 0);

        assertEq(mediator.maxPerTx(address(0)), 0);
        assertEq(mediator.executionMaxPerTx(address(0)), 0);
    }

    function test_limits_updateDefaultMinPerTx() public {
        _afterInit();

        vm.expectRevert();
        vm.prank(user);
        mediator.setMinPerTx(address(0), 0.1 ether);
        vm.expectRevert();
        vm.prank(owner);
        mediator.setMinPerTx(address(0), 0);
        vm.prank(owner);
        mediator.setMinPerTx(address(0), 0.1 ether);

        assertEq(mediator.minPerTx(address(0)), 0.1 ether);

        vm.expectRevert();
        vm.prank(owner);
        mediator.setMinPerTx(address(0), 0);
    }

    function test_limits_onlyForKnownTokens() public {
        _afterInit();

        vm.expectRevert();
        vm.prank(owner);
        mediator.setDailyLimit(address(token), 5 ether);
        vm.expectRevert();
        vm.prank(owner);
        mediator.setMaxPerTx(address(token), 1.5 ether);
        vm.expectRevert();
        vm.prank(owner);
        mediator.setMinPerTx(address(token), 0.02 ether);
        vm.expectRevert();
        vm.prank(owner);
        mediator.setExecutionDailyLimit(address(token), 5 ether);
        vm.expectRevert();
        vm.prank(owner);
        mediator.setExecutionMaxPerTx(address(token), 1.5 ether);

        vm.prank(user);
        token.transferAndCall(address(mediator), ONE, "");

        _setAndCheckTokenLimits(address(token));

        address bridgedToken = address(_deployBridgedToken(user, ONE));

        _setAndCheckTokenLimits(bridgedToken);
    }

    function _setAndCheckTokenLimits(address _token) internal {
        vm.prank(owner);
        mediator.setDailyLimit(_token, 5 ether);
        vm.prank(owner);
        mediator.setMaxPerTx(_token, 1.5 ether);
        vm.prank(owner);
        mediator.setMinPerTx(_token, 0.02 ether);
        vm.prank(owner);
        mediator.setExecutionDailyLimit(_token, 6 ether);
        vm.prank(owner);
        mediator.setExecutionMaxPerTx(_token, 1.6 ether);

        assertEq(mediator.dailyLimit(_token), 5 ether);
        assertEq(mediator.maxPerTx(_token), 1.5 ether);
        // JS expects 0.02 ether. Per-token minPerTx always reads 1 wei once set (TokensBridgeLimits.minPerTx).
        assertEq(mediator.minPerTx(_token), 1);
        assertEq(mediator.executionDailyLimit(_token), 6 ether);
        assertEq(mediator.executionMaxPerTx(_token), 1.6 ether);
    }

    // =====================================================================
    // afterInitialization / update mediator parameters / token factory
    // =====================================================================

    function test_tokenFactory_changeTokenImage() public {
        _afterInit();

        address newTokenImage = _deployPermittableToken("Test", "TST", 18);
        vm.expectRevert();
        vm.prank(owner);
        tokenFactory.setTokenImage(owner);
        vm.expectRevert();
        vm.prank(user);
        tokenFactory.setTokenImage(newTokenImage);
        vm.prank(owner);
        tokenFactory.setTokenImage(newTokenImage);

        assertEq(tokenFactory.tokenImage(), newTokenImage);
    }

    function test_tokenFactory_changeTokenFactory() public {
        _afterInit();

        TokenFactory newTokenFactory = new TokenFactory(owner, tokenImage);
        vm.expectRevert();
        vm.prank(owner);
        mediator.setTokenFactory(owner);
        vm.expectRevert();
        vm.prank(user);
        mediator.setTokenFactory(address(newTokenFactory));
        vm.prank(owner);
        mediator.setTokenFactory(address(newTokenFactory));

        assertEq(address(mediator.tokenFactory()), address(newTokenFactory));
    }

    // =====================================================================
    // commonRelayTests
    // =====================================================================

    function _respectGlobalShutdown() internal {
        vm.prank(owner);
        mediator.setDailyLimit(address(0), 0);
        for (uint256 i = 0; i < SEND_FUNCTIONS; i++) {
            _sendReverts(i, ONE);
        }
        vm.prank(owner);
        mediator.setDailyLimit(address(0), DAILY_LIMIT);
        for (uint256 i = 0; i < SEND_FUNCTIONS; i++) {
            _send(i, MIN_PER_TX);
        }
    }

    function _respectLimits() internal {
        for (uint256 i = 0; i < SEND_FUNCTIONS; i++) {
            // JS sends 0.001 here. Per-token minPerTx is now fixed at 1 wei (see TokensBridgeLimits.minPerTx),
            // so 0 is the amount below the minimum.
            _sendReverts(i, 0);
            _sendReverts(i, 1.001 ether);
        }

        _send(0);
        _send(0);

        assertEq(mediator.maxAvailablePerTx(address(token)), HALF);

        for (uint256 i = 0; i < SEND_FUNCTIONS; i++) {
            _sendReverts(i, 1.001 ether);
            _sendReverts(i, 0.8 ether);
            _send(i, MIN_PER_TX);
        }
    }

    // =====================================================================
    // native tokens / initialization
    // =====================================================================

    function test_nativeTokens_initializeLimitsByDecimals() public {
        uint8[3] memory decimalsList = [uint8(3), 18, 20];
        for (uint256 i = 0; i < decimalsList.length; i++) {
            setUp();
            _afterInit();
            _checkNativeLimitsByDecimals(decimalsList[i]);
        }
    }

    function _checkNativeLimitsByDecimals(uint8 _decimals) internal {
        token = _deployERC677Token("TEST", "TST", _decimals);
        uint256 amount = _scale(ONE, _decimals);
        vm.prank(owner);
        token.mint(user, amount);
        vm.prank(user);
        token.transferAndCall(address(mediator), amount, "");

        assertEq(mediator.dailyLimit(address(token)), _scale(DAILY_LIMIT, _decimals));
        assertEq(mediator.maxPerTx(address(token)), _scale(MAX_PER_TX, _decimals));
        // JS expects the scaled default. Per-token minPerTx always reads 1 wei (TokensBridgeLimits.minPerTx).
        assertEq(mediator.minPerTx(address(token)), 1);
        assertEq(mediator.executionDailyLimit(address(token)), _scale(EXECUTION_DAILY_LIMIT, _decimals));
        assertEq(mediator.executionMaxPerTx(address(token)), _scale(EXECUTION_MAX_PER_TX, _decimals));
    }

    function test_nativeTokens_initializeLimitsForZeroDecimals() public {
        _afterInit();

        token = _deployERC677Token("TEST", "TST", 0);
        vm.prank(owner);
        token.mint(user, 1);
        vm.prank(user);
        token.transferAndCall(address(mediator), 1, "");

        assertEq(mediator.dailyLimit(address(token)), 10000);
        assertEq(mediator.maxPerTx(address(token)), 100);
        assertEq(mediator.minPerTx(address(token)), 1);
        assertEq(mediator.executionDailyLimit(address(token)), 10000);
        assertEq(mediator.executionMaxPerTx(address(token)), 100);
    }

    // =====================================================================
    // native tokens / tokens relay
    // =====================================================================

    function test_nativeTokens_relay_allSendFunctions() public {
        for (uint256 i = 0; i < SEND_FUNCTIONS; i++) {
            setUp();
            _afterInit();
            _nativeRelay(i);
        }
    }

    function _nativeRelay(uint256 _kind) internal {
        address receiver = _send(_kind);

        assertEq(mediator.maxAvailablePerTx(address(token)), ONE);
        assertTrue(mediator.isRegisteredAsNativeToken(address(token)));

        _send(_kind, HALF);

        assertTrue(!mediator.isBridgedTokenDeployAcknowledged(address(token)));
        assertTrue(_exec(OTHER_MESSAGE_ID, _handleNativeData(address(token), user, HALF)));
        assertTrue(mediator.isBridgedTokenDeployAcknowledged(address(token)));

        _send(_kind, HALF);

        AmbMessage[] memory msgs = _ambMessages();
        assertEq(msgs.length, 3);
        _assertDeployMessage(msgs[0], receiver, ONE);
        _assertDeployMessage(msgs[1], receiver, HALF);
        _assertHandleMessage(
            msgs[2],
            HANDLE_BRIDGED_TOKENS,
            HANDLE_BRIDGED_TOKENS_AND_CALL,
            receiver == address(tokenReceiver),
            address(token),
            receiver,
            HALF
        );

        assertEq(mediator.totalSpentPerDay(address(token), currentDay), TWO);
        assertEq(mediator.mediatorBalance(address(token)), 1.5 ether);
        assertTrue(mediator.isTokenRegistered(address(token)));
        assertEq(token.balanceOf(address(mediator)), 1.5 ether);
        assertEq(mediator.maxAvailablePerTx(address(token)), HALF);

        TokenEvent[] memory deposits = _tokenEvents(TOKENS_BRIDGING_INITIATED);
        assertEq(deposits.length, 3);
        _assertInitiated(deposits[0], address(token), user, ONE);
        _assertInitiated(deposits[1], address(token), user, HALF);
        _assertInitiated(deposits[2], address(token), user, HALF);
    }

    function test_nativeTokens_relayTokensAndCall() public {
        _afterInit();

        _send(0);

        assertTrue(_exec(OTHER_MESSAGE_ID, _handleNativeData(address(token), user, HALF)));

        assertEq(_ambMessages().length, 1);

        vm.prank(user);
        token.approve(address(mediator), ONE);
        vm.prank(user);
        mediator.relayTokensAndCall(IERC677(address(token)), otherSideToken1, ONE, hex"1122");

        AmbMessage[] memory msgs = _ambMessages();
        assertEq(msgs.length, 2);
        _assertHandleMessage(
            msgs[1],
            HANDLE_BRIDGED_TOKENS,
            HANDLE_BRIDGED_TOKENS_AND_CALL,
            true,
            address(token),
            otherSideToken1,
            ONE
        );

        assertEq(mediator.totalSpentPerDay(address(token), currentDay), TWO);
        assertEq(mediator.mediatorBalance(address(token)), 1.5 ether);
        assertTrue(mediator.isTokenRegistered(address(token)));
        assertEq(token.balanceOf(address(mediator)), 1.5 ether);
        assertEq(mediator.maxAvailablePerTx(address(token)), HALF);

        TokenEvent[] memory deposits = _tokenEvents(TOKENS_BRIDGING_INITIATED);
        assertEq(deposits.length, 2);
        _assertInitiated(deposits[1], address(token), user, ONE);
    }

    function test_nativeTokens_respectGlobalShutdown() public {
        _afterInit();
        _respectGlobalShutdown();
    }

    function test_nativeTokens_respectLimits() public {
        _afterInit();
        _respectLimits();
    }

    // =====================================================================
    // native tokens / tokens relay / fixFailedMessage
    // =====================================================================

    function test_nativeTokens_fixFailedMessage_allSendFunctions() public {
        for (uint256 i = 0; i < SEND_FUNCTIONS; i++) {
            setUp();
            _afterInit();
            _nativeFixFailedMessage(i);
        }
    }

    function _nativeFixFailedMessage(uint256 _kind) internal {
        // User transfer tokens twice
        _send(_kind, HALF);
        _send(_kind, ONE);

        assertTrue(_exec(OTHER_MESSAGE_ID_2, _handleNativeData(address(token), user, ONE)));

        _send(_kind, HALF);

        assertEq(mediator.mediatorBalance(address(token)), ONE);
        assertEq(token.balanceOf(user), 9 ether);

        AmbMessage[] memory msgs = _ambMessages();
        assertEq(msgs.length, 3);
        bytes32 transferMessageId1 = msgs[0].messageId;
        bytes32 transferMessageId2 = msgs[2].messageId;
        assertTrue(!mediator.messageFixed(transferMessageId1));
        assertTrue(!mediator.messageFixed(transferMessageId2));

        vm.expectRevert();
        vm.prank(user);
        mediator.fixFailedMessage(transferMessageId2);
        vm.expectRevert();
        vm.prank(owner);
        mediator.fixFailedMessage(transferMessageId2);

        // Should be called by mediator from other side so it will fail
        assertTrue(!_execFrom(FAILED_MESSAGE_ID, _fixData(transferMessageId2), owner));
        assertTrue(!amb.messageCallStatus(FAILED_MESSAGE_ID));
        assertTrue(!mediator.messageFixed(transferMessageId2));

        assertTrue(_exec(EXAMPLE_MESSAGE_ID, _fixData(transferMessageId2)));
        assertEq(token.balanceOf(user), 9.5 ether);
        assertEq(mediator.mediatorBalance(address(token)), HALF);
        assertTrue(!mediator.messageFixed(transferMessageId1));
        assertTrue(mediator.messageFixed(transferMessageId2));
        assertGt(mediator.minPerTx(address(token)), 0);

        assertTrue(_exec(OTHER_MESSAGE_ID, _fixData(transferMessageId1)));
        assertEq(token.balanceOf(user), 10 ether);
        assertEq(mediator.mediatorBalance(address(token)), 0);
        assertTrue(mediator.messageFixed(transferMessageId1));

        RecordedLog[] memory fixedLogs = _events(address(mediator), FAILED_MESSAGE_FIXED);
        assertEq(fixedLogs.length, 2);
        _assertFailedMessageFixed(fixedLogs[0], transferMessageId2, address(token), user, HALF);
        _assertFailedMessageFixed(fixedLogs[1], transferMessageId1, address(token), user, HALF);

        assertTrue(!_exec(FAILED_MESSAGE_ID, _fixData(transferMessageId1)));
        assertTrue(!_exec(FAILED_MESSAGE_ID, _fixData(transferMessageId2)));
    }

    // =====================================================================
    // native tokens / tokens relay / fixMediatorBalance
    // =====================================================================

    function _fixMediatorBalanceSetUp() internal {
        _afterInit();
        _useProxy();

        vm.prank(owner);
        token.mint(user, TWO);
        vm.prank(owner);
        token.mint(address(mediator), TWO);

        _initialize();

        vm.prank(user);
        token.transferAndCall(address(mediator), ONE, "");

        assertEq(mediator.mediatorBalance(address(token)), ONE);
        assertEq(token.balanceOf(address(mediator)), 3 ether);
        assertEq(mediator.totalSpentPerDay(address(token), currentDay), ONE);
        assertEq(_ambMessages().length, 1);
    }

    function test_fixMediatorBalance_fixExtraBalance() public {
        _fixMediatorBalanceSetUp();

        vm.prank(owner);
        mediator.setDailyLimit(address(token), 5 ether);
        vm.prank(owner);
        mediator.setMaxPerTx(address(token), TWO);

        vm.expectRevert();
        vm.prank(user);
        mediator.fixMediatorBalance(address(token), owner);
        vm.expectRevert();
        vm.prank(owner);
        mediator.fixMediatorBalance(address(0), owner);
        vm.expectRevert();
        vm.prank(owner);
        mediator.fixMediatorBalance(address(token), address(0));
        vm.prank(owner);
        mediator.fixMediatorBalance(address(token), owner);
        vm.expectRevert();
        vm.prank(owner);
        mediator.fixMediatorBalance(address(token), owner);

        assertEq(mediator.mediatorBalance(address(token)), 3 ether);
        assertEq(token.balanceOf(address(mediator)), 3 ether);
        assertEq(mediator.totalSpentPerDay(address(token), currentDay), 3 ether);

        AmbMessage[] memory msgs = _ambMessages();
        assertEq(msgs.length, 2);
        assertEq(_selectorOf(msgs[1].data), DEPLOY_AND_HANDLE_BRIDGED_TOKENS);
        assertEq(msgs[1].executor, otherSideMediator);
        assertEq(uint256(msgs[1].dataType), 0);
    }

    function test_fixMediatorBalance_usesDifferentMethodsOnOtherSide() public {
        _fixMediatorBalanceSetUp();

        vm.prank(owner);
        mediator.fixMediatorBalance(address(token), owner);

        assertTrue(_exec(OTHER_MESSAGE_ID, _handleNativeData(address(token), user, HALF)));

        vm.prank(owner);
        mediator.fixMediatorBalance(address(token), owner);

        AmbMessage[] memory msgs = _ambMessages();
        assertEq(msgs.length, 3);
        assertEq(_selectorOf(msgs[1].data), DEPLOY_AND_HANDLE_BRIDGED_TOKENS);
        assertEq(_selectorOf(msgs[2].data), HANDLE_BRIDGED_TOKENS);
    }

    function test_fixMediatorBalance_respectsLimits() public {
        _fixMediatorBalanceSetUp();

        vm.expectRevert();
        vm.prank(user);
        mediator.fixMediatorBalance(address(token), owner);
        vm.expectRevert();
        vm.prank(owner);
        mediator.fixMediatorBalance(address(0), owner);
        vm.expectRevert();
        vm.prank(owner);
        mediator.fixMediatorBalance(address(token), address(0));
        vm.prank(owner);
        mediator.fixMediatorBalance(address(token), owner);

        assertEq(mediator.mediatorBalance(address(token)), TWO);
        assertEq(token.balanceOf(address(mediator)), 3 ether);
        assertEq(mediator.totalSpentPerDay(address(token), currentDay), TWO);

        vm.prank(owner);
        mediator.fixMediatorBalance(address(token), owner);

        assertEq(mediator.mediatorBalance(address(token)), 2.5 ether);
        assertEq(token.balanceOf(address(mediator)), 3 ether);
        assertEq(mediator.totalSpentPerDay(address(token), currentDay), 2.5 ether);
        assertEq(_ambMessages().length, 3);

        vm.expectRevert();
        vm.prank(owner);
        mediator.fixMediatorBalance(address(token), owner);
        vm.prank(owner);
        mediator.setDailyLimit(address(token), 1.5 ether);
        vm.expectRevert();
        vm.prank(owner);
        mediator.fixMediatorBalance(address(token), owner);
    }

    // =====================================================================
    // native tokens / handleNativeTokens
    // =====================================================================

    function _lockTwoTokens() internal {
        vm.prank(user);
        token.transferAndCall(address(mediator), ONE, "");
        vm.prank(user);
        token.transferAndCall(address(mediator), ONE, "");
    }

    function test_handleNativeTokens_unlocksTokens() public {
        _afterInit();
        _lockTwoTokens();

        assertEq(token.balanceOf(address(mediator)), TWO);
        assertEq(mediator.mediatorBalance(address(token)), TWO);

        // can't be called by user
        vm.expectRevert();
        vm.prank(user);
        mediator.handleNativeTokens(address(token), user, ONE);

        // can't be called by owner
        vm.expectRevert();
        vm.prank(owner);
        mediator.handleNativeTokens(address(token), user, ONE);

        bytes memory data = _handleNativeData(address(token), user, ONE);

        // message must be generated by mediator contract on the other network
        assertTrue(!_execFrom(FAILED_MESSAGE_ID, data, owner));

        assertTrue(_exec(EXAMPLE_MESSAGE_ID, data));

        assertEq(mediator.totalExecutedPerDay(address(token), currentDay), ONE);
        assertEq(mediator.mediatorBalance(address(token)), ONE);
        assertEq(token.balanceOf(user), 9 ether);
        assertEq(token.balanceOf(address(mediator)), ONE);
        assertTrue(mediator.isBridgedTokenDeployAcknowledged(address(token)));

        TokenEvent[] memory evs = _tokenEvents(TOKENS_BRIDGED);
        assertEq(evs.length, 1);
        _assertBridged(evs[0], address(token), user, ONE, EXAMPLE_MESSAGE_ID);
    }

    function test_handleNativeTokens_rejectsUnregisteredTokens() public {
        _afterInit();
        _rejectUnregisteredNativeToken();
    }

    function test_handleNativeTokens_respectsGlobalShutdown() public {
        _afterInit();
        _nativeGlobalShutdown();
    }

    function _rejectUnregisteredNativeToken() internal {
        ITestToken otherToken = _deployERC677Token("Test", "TST", 18);
        vm.prank(owner);
        otherToken.mint(address(mediator), ONE);

        assertTrue(!_exec(FAILED_MESSAGE_ID, _handleNativeData(address(otherToken), user, ONE)));
    }

    function _nativeGlobalShutdown() internal {
        _lockTwoTokens();

        bytes memory data = _handleNativeData(address(token), user, ONE);

        vm.prank(owner);
        mediator.setExecutionDailyLimit(address(0), 0);

        assertTrue(!_exec(FAILED_MESSAGE_ID, data));

        vm.prank(owner);
        mediator.setExecutionDailyLimit(address(0), EXECUTION_DAILY_LIMIT);

        assertTrue(_exec(OTHER_MESSAGE_ID, data));
    }

    // =====================================================================
    // native tokens / handleNativeTokensAndCall
    // =====================================================================

    function test_handleNativeTokensAndCall_unlocksTokens() public {
        _afterInit();
        _lockTwoTokens();

        assertEq(token.balanceOf(address(mediator)), TWO);
        assertEq(mediator.mediatorBalance(address(token)), TWO);

        // can't be called by user
        vm.expectRevert();
        vm.prank(user);
        mediator.handleNativeTokensAndCall(address(token), address(tokenReceiver), ONE, hex"5566");

        // can't be called by owner
        vm.expectRevert();
        vm.prank(owner);
        mediator.handleNativeTokensAndCall(address(token), address(tokenReceiver), ONE, hex"5566");

        bytes memory data = _handleNativeAndCallData(address(token), address(tokenReceiver), ONE, hex"5566");

        // message must be generated by mediator contract on the other network
        assertTrue(!_execFrom(FAILED_MESSAGE_ID, data, owner));

        assertTrue(_exec(EXAMPLE_MESSAGE_ID, data));

        assertEq(mediator.totalExecutedPerDay(address(token), currentDay), ONE);
        assertEq(mediator.mediatorBalance(address(token)), ONE);
        assertEq(token.balanceOf(address(tokenReceiver)), ONE);
        assertEq(token.balanceOf(address(mediator)), ONE);

        TokenEvent[] memory evs = _tokenEvents(TOKENS_BRIDGED);
        assertEq(evs.length, 1);
        _assertBridged(evs[0], address(token), address(tokenReceiver), ONE, EXAMPLE_MESSAGE_ID);

        assertEq(tokenReceiver.data(), hex"5566");
    }

    function test_handleNativeTokensAndCall_rejectsUnregisteredTokens() public {
        _afterInit();
        _rejectUnregisteredNativeToken();
    }

    function test_handleNativeTokensAndCall_respectsGlobalShutdown() public {
        _afterInit();
        _nativeGlobalShutdown();
    }

    // =====================================================================
    // native tokens / requestFailedMessageFix
    // =====================================================================

    function _nativeFailedMsgData() internal view returns (bytes memory) {
        return _handleNativeData(address(token), user, ONE);
    }

    function test_nativeTokens_requestFailedMessageFix() public {
        _afterInit();

        assertTrue(!_exec(FAILED_MESSAGE_ID, _nativeFailedMsgData()));

        mediator.requestFailedMessageFix(FAILED_MESSAGE_ID);

        AmbMessage[] memory msgs = _ambMessages();
        assertEq(msgs.length, 1);
        assertEq(_selectorOf(msgs[0].data), FIX_FAILED_MESSAGE);
        assertEq(abi.decode(_argsOf(msgs[0].data), (bytes32)), FAILED_MESSAGE_ID);
    }

    function test_nativeTokens_requestFailedMessageFix_onlyFailedMessage() public {
        _afterInit();

        vm.prank(user);
        token.transferAndCall(address(mediator), ONE, "");

        assertTrue(_exec(EXAMPLE_MESSAGE_ID, _nativeFailedMsgData()));

        vm.expectRevert();
        mediator.requestFailedMessageFix(EXAMPLE_MESSAGE_ID);
    }

    function test_nativeTokens_requestFailedMessageFix_onlyIfReceiver() public {
        _afterInit();

        assertTrue(!_exec(FAILED_MESSAGE_ID, _nativeFailedMsgData(), address(amb), otherSideMediator, 1000000));

        vm.expectRevert();
        mediator.requestFailedMessageFix(FAILED_MESSAGE_ID);
    }

    function test_nativeTokens_requestFailedMessageFix_onlyFromOtherSideMediator() public {
        _afterInit();

        assertTrue(!_execFrom(FAILED_MESSAGE_ID, _nativeFailedMsgData(), owner));

        vm.expectRevert();
        mediator.requestFailedMessageFix(FAILED_MESSAGE_ID);
    }

    function test_nativeTokens_requestFailedMessageFix_multipleTimes() public {
        _afterInit();

        assertTrue(!_exec(FAILED_MESSAGE_ID, _nativeFailedMsgData()));

        mediator.requestFailedMessageFix(FAILED_MESSAGE_ID);
        mediator.requestFailedMessageFix(FAILED_MESSAGE_ID);

        AmbMessage[] memory msgs = _ambMessages();
        assertEq(msgs.length, 2);
        assertEq(_selectorOf(msgs[0].data), FIX_FAILED_MESSAGE);
        assertEq(_selectorOf(msgs[1].data), FIX_FAILED_MESSAGE);
    }

    // =====================================================================
    // bridged tokens / tokens relay
    // =====================================================================

    function _bridgedRelaySetUp() internal {
        _afterInit();
        vm.prank(owner);
        mediator.setExecutionDailyLimit(address(0), 10 ether);
        vm.prank(owner);
        mediator.setExecutionMaxPerTx(address(0), 5 ether);
        token = _deployBridgedToken(user, 5 ether);
    }

    function test_bridgedTokens_relay_allSendFunctions() public {
        for (uint256 i = 0; i < SEND_FUNCTIONS; i++) {
            setUp();
            _bridgedRelaySetUp();
            _bridgedRelay(i);
        }
    }

    function _bridgedRelay(uint256 _kind) internal {
        address receiver = _send(_kind);
        bool withData = receiver == address(tokenReceiver);

        AmbMessage[] memory msgs = _ambMessages();
        assertEq(msgs.length, 1);
        _assertHandleMessage(
            msgs[0],
            HANDLE_NATIVE_TOKENS,
            HANDLE_NATIVE_TOKENS_AND_CALL,
            withData,
            otherSideToken1,
            receiver,
            ONE
        );
        assertEq(mediator.maxAvailablePerTx(address(token)), ONE);

        _send(_kind);

        msgs = _ambMessages();
        assertEq(msgs.length, 2);
        _assertHandleMessage(
            msgs[1],
            HANDLE_NATIVE_TOKENS,
            HANDLE_NATIVE_TOKENS_AND_CALL,
            withData,
            otherSideToken1,
            receiver,
            ONE
        );

        assertEq(mediator.totalSpentPerDay(address(token), currentDay), TWO);
        assertEq(mediator.mediatorBalance(address(token)), 0);
        assertTrue(mediator.isTokenRegistered(address(token)));
        assertEq(token.balanceOf(address(mediator)), 0);
        assertEq(mediator.maxAvailablePerTx(address(token)), HALF);

        TokenEvent[] memory deposits = _tokenEvents(TOKENS_BRIDGING_INITIATED);
        assertEq(deposits.length, 2);
        _assertInitiated(deposits[0], address(token), user, ONE);
        _assertInitiated(deposits[1], address(token), user, ONE);
    }

    function test_bridgedTokens_respectGlobalShutdown() public {
        _bridgedRelaySetUp();
        _respectGlobalShutdown();
    }

    function test_bridgedTokens_respectLimits() public {
        _bridgedRelaySetUp();
        _respectLimits();
    }

    function test_bridgedTokens_fixFailedMessage_allSendFunctions() public {
        for (uint256 i = 0; i < SEND_FUNCTIONS; i++) {
            setUp();
            _bridgedRelaySetUp();
            _bridgedFixFailedMessage(i);
        }
    }

    function _bridgedFixFailedMessage(uint256 _kind) internal {
        // User transfer tokens
        _send(_kind);

        assertEq(token.balanceOf(user), 4 ether);

        AmbMessage[] memory msgs = _ambMessages();
        assertEq(msgs.length, 1);
        bytes32 transferMessageId = msgs[0].messageId;
        assertTrue(!mediator.messageFixed(transferMessageId));

        vm.expectRevert();
        vm.prank(user);
        mediator.fixFailedMessage(transferMessageId);
        vm.expectRevert();
        vm.prank(owner);
        mediator.fixFailedMessage(transferMessageId);

        bytes memory fixData = _fixData(transferMessageId);

        // Should be called by mediator from other side so it will fail
        assertTrue(!_execFrom(FAILED_MESSAGE_ID, fixData, owner));
        assertTrue(!amb.messageCallStatus(FAILED_MESSAGE_ID));
        assertTrue(!mediator.messageFixed(transferMessageId));

        assertTrue(_exec(EXAMPLE_MESSAGE_ID, fixData));
        assertEq(token.balanceOf(user), 5 ether);
        assertTrue(mediator.messageFixed(transferMessageId));
        assertGt(mediator.minPerTx(address(token)), 0);

        RecordedLog[] memory fixedLogs = _events(address(mediator), FAILED_MESSAGE_FIXED);
        assertEq(fixedLogs.length, 1);
        _assertFailedMessageFixed(fixedLogs[0], transferMessageId, address(token), user, ONE);

        assertTrue(!_exec(FAILED_MESSAGE_ID, fixData));
    }

    // =====================================================================
    // bridged tokens / deployAndHandleBridgedTokens
    // =====================================================================

    function test_deployAndHandleBridgedTokens_deploysAndMints() public {
        _afterInit();

        // can't be called by user
        vm.expectRevert();
        vm.prank(user);
        mediator.deployAndHandleBridgedTokens(otherSideToken1, "Test", "TST", 18, user, ONE);

        // can't be called by owner
        vm.expectRevert();
        vm.prank(owner);
        mediator.deployAndHandleBridgedTokens(otherSideToken1, "Test", "TST", 18, user, ONE);

        bytes memory data = _deployData(user, ONE);

        // message must be generated by mediator contract on the other network
        assertTrue(!_execFrom(FAILED_MESSAGE_ID, data, owner));

        assertTrue(_exec(EXAMPLE_MESSAGE_ID, data));

        address bridgedToken = _assertNewTokenRegistered();

        ITestToken deployedToken = ITestToken(bridgedToken);
        assertEq(deployedToken.name(), string(abi.encodePacked("Test", SUFFIX)));
        assertEq(deployedToken.symbol(), "TST");
        assertEq(uint256(deployedToken.decimals()), 18);
        _assertTokenPair(otherSideToken1, bridgedToken);
        assertTrue(!mediator.isRegisteredAsNativeToken(bridgedToken));
        assertEq(mediator.totalExecutedPerDay(bridgedToken, currentDay), ONE);
        assertEq(mediator.mediatorBalance(bridgedToken), 0);
        assertEq(deployedToken.balanceOf(user), ONE);
        assertEq(deployedToken.balanceOf(address(mediator)), 0);

        TokenEvent[] memory evs = _tokenEvents(TOKENS_BRIDGED);
        assertEq(evs.length, 1);
        _assertBridged(evs[0], bridgedToken, user, ONE, EXAMPLE_MESSAGE_ID);
    }

    // Checks there is exactly one NewTokenRegistered event for otherSideToken1 and returns the bridged token.
    function _assertNewTokenRegistered() internal returns (address bridgedToken) {
        RecordedLog[] memory logs = _events(address(mediator), NEW_TOKEN_REGISTERED);
        assertEq(logs.length, 1);
        assertEq(_topicAddress(logs[0].topics[1]), otherSideToken1);
        bridgedToken = _topicAddress(logs[0].topics[2]);
    }

    function _assertTokenPair(address _nativeToken, address _bridgedToken) internal {
        assertEq(mediator.nativeTokenAddress(_bridgedToken), _nativeToken);
        assertEq(mediator.bridgedTokenAddress(_nativeToken), _bridgedToken);
        if (_isHome()) {
            assertEq(HomeOmnibridge(address(mediator)).foreignTokenAddress(_bridgedToken), _nativeToken);
            assertEq(HomeOmnibridge(address(mediator)).homeTokenAddress(_nativeToken), _bridgedToken);
        }
    }

    function test_deployAndHandleBridgedTokens_doesNotRedeploy() public {
        _afterInit();

        bytes memory data = _deployData(user, ONE);

        assertTrue(_exec(EXAMPLE_MESSAGE_ID, data));
        assertTrue(_exec(bytes32(uint256(uint160(otherSideToken1))), data));

        assertEq(_countEvents(address(mediator), NEW_TOKEN_REGISTERED), 1);
        assertEq(_countEvents(address(mediator), TOKENS_BRIDGED), 2);
    }

    function test_deployAndHandleBridgedTokens_usesSymbolIfNameEmpty() public {
        _afterInit();

        assertTrue(_exec(EXAMPLE_MESSAGE_ID, _deployData(otherSideToken1, "", "TST", 18, user, ONE)));

        ITestToken deployedToken = ITestToken(mediator.bridgedTokenAddress(otherSideToken1));
        assertEq(deployedToken.name(), string(abi.encodePacked("TST", SUFFIX)));
        assertEq(deployedToken.symbol(), "TST");
        assertEq(uint256(deployedToken.decimals()), 18);
    }

    function test_deployAndHandleBridgedTokens_usesNameIfSymbolEmpty() public {
        _afterInit();

        assertTrue(_exec(EXAMPLE_MESSAGE_ID, _deployData(otherSideToken1, "Test", "", 18, user, ONE)));

        ITestToken deployedToken = ITestToken(mediator.bridgedTokenAddress(otherSideToken1));
        assertEq(deployedToken.name(), string(abi.encodePacked("Test", SUFFIX)));
        assertEq(deployedToken.symbol(), "Test");
        assertEq(uint256(deployedToken.decimals()), 18);
    }

    function test_deployAndHandleBridgedTokens_differentDecimals() public {
        uint8[3] memory decimalsList = [uint8(3), 18, 20];
        for (uint256 i = 0; i < decimalsList.length; i++) {
            setUp();
            _afterInit();
            _checkBridgedLimitsByDecimals(decimalsList[i]);
        }
    }

    function _checkBridgedLimitsByDecimals(uint8 _decimals) internal {
        bytes memory data = _deployData(otherSideToken1, "Test", "TST", _decimals, user, _scale(ONE, _decimals));

        assertTrue(_exec(EXAMPLE_MESSAGE_ID, data));

        address deployedToken = mediator.bridgedTokenAddress(otherSideToken1);

        assertEq(uint256(ITestToken(deployedToken).decimals()), uint256(_decimals));
        assertEq(mediator.dailyLimit(deployedToken), _scale(DAILY_LIMIT, _decimals));
        assertEq(mediator.maxPerTx(deployedToken), _scale(MAX_PER_TX, _decimals));
        // JS expects the scaled default. Per-token minPerTx always reads 1 wei (TokensBridgeLimits.minPerTx).
        assertEq(mediator.minPerTx(deployedToken), 1);
        assertEq(mediator.executionDailyLimit(deployedToken), _scale(EXECUTION_DAILY_LIMIT, _decimals));
        assertEq(mediator.executionMaxPerTx(deployedToken), _scale(EXECUTION_MAX_PER_TX, _decimals));
    }

    function test_deployAndHandleBridgedTokens_zeroDecimals() public {
        _afterInit();

        assertTrue(_exec(EXAMPLE_MESSAGE_ID, _deployData(otherSideToken1, "Test", "TST", 0, user, 1)));

        address deployedToken = mediator.bridgedTokenAddress(otherSideToken1);

        assertEq(uint256(ITestToken(deployedToken).decimals()), 0);
        assertEq(mediator.dailyLimit(deployedToken), 10000);
        assertEq(mediator.maxPerTx(deployedToken), 100);
        assertEq(mediator.minPerTx(deployedToken), 1);
        assertEq(mediator.executionDailyLimit(deployedToken), 10000);
        assertEq(mediator.executionMaxPerTx(deployedToken), 100);
    }

    function test_deployAndHandleBridgedTokens_respectsGlobalShutdown() public {
        _afterInit();

        bytes memory data = _deployData(user, ONE);

        vm.prank(owner);
        mediator.setExecutionDailyLimit(address(0), 0);

        assertTrue(!_exec(FAILED_MESSAGE_ID, data));

        vm.prank(owner);
        mediator.setExecutionDailyLimit(address(0), EXECUTION_DAILY_LIMIT);

        assertTrue(_exec(OTHER_MESSAGE_ID, data));
    }

    // =====================================================================
    // bridged tokens / deployAndHandleBridgedTokensAndCall
    // =====================================================================

    function test_deployAndHandleBridgedTokensAndCall_deploysAndMints() public {
        _afterInit();

        // can't be called by user
        vm.expectRevert();
        vm.prank(user);
        mediator.deployAndHandleBridgedTokensAndCall(
            otherSideToken1,
            "Test",
            "TST",
            18,
            address(tokenReceiver),
            ONE,
            hex"5566"
        );

        // can't be called by owner
        vm.expectRevert();
        vm.prank(owner);
        mediator.deployAndHandleBridgedTokensAndCall(
            otherSideToken1,
            "Test",
            "TST",
            18,
            address(tokenReceiver),
            ONE,
            hex"5566"
        );

        bytes memory data = _deployAndCallData(address(tokenReceiver), ONE, hex"5566");

        // message must be generated by mediator contract on the other network
        assertTrue(!_execFrom(FAILED_MESSAGE_ID, data, owner));

        assertTrue(_exec(EXAMPLE_MESSAGE_ID, data));

        address bridgedToken = _assertNewTokenRegistered();

        ITestToken deployedToken = ITestToken(bridgedToken);
        assertEq(deployedToken.name(), string(abi.encodePacked("Test", SUFFIX)));
        assertEq(deployedToken.symbol(), "TST");
        assertEq(uint256(deployedToken.decimals()), 18);
        _assertTokenPair(otherSideToken1, bridgedToken);
        assertEq(mediator.totalExecutedPerDay(bridgedToken, currentDay), ONE);
        assertEq(mediator.mediatorBalance(bridgedToken), 0);
        assertEq(deployedToken.balanceOf(address(tokenReceiver)), ONE);
        assertEq(deployedToken.balanceOf(address(mediator)), 0);

        TokenEvent[] memory evs = _tokenEvents(TOKENS_BRIDGED);
        assertEq(evs.length, 1);
        _assertBridged(evs[0], bridgedToken, address(tokenReceiver), ONE, EXAMPLE_MESSAGE_ID);

        assertEq(tokenReceiver.data(), hex"5566");
    }

    // =====================================================================
    // bridged tokens / handleBridgedTokens
    // =====================================================================

    // beforeEach of describe('handleBridgedTokens') and describe('handleBridgedTokensAndCall')
    function _handleBridgedSetUp() internal returns (ITestToken deployedToken) {
        _afterInit();

        assertTrue(_exec(EXAMPLE_MESSAGE_ID, _deployData(user, ONE)));

        deployedToken = ITestToken(_assertNewTokenRegistered());

        assertEq(mediator.totalExecutedPerDay(address(deployedToken), currentDay), ONE);
        assertEq(deployedToken.balanceOf(user), ONE);
        assertEq(deployedToken.balanceOf(address(mediator)), 0);
    }

    function test_handleBridgedTokens_mintsOnRepeatedMessages() public {
        ITestToken deployedToken = _handleBridgedSetUp();

        // can't be called by user
        vm.expectRevert();
        vm.prank(user);
        mediator.handleBridgedTokens(otherSideToken1, user, ONE);

        // can't be called by owner
        vm.expectRevert();
        vm.prank(owner);
        mediator.handleBridgedTokens(otherSideToken1, user, ONE);

        bytes memory data = _handleBridgedData(otherSideToken1, user, ONE);

        // message must be generated by mediator contract on the other network
        assertTrue(!_execFrom(FAILED_MESSAGE_ID, data, owner));

        assertTrue(_exec(EXAMPLE_MESSAGE_ID, data));

        assertEq(mediator.totalExecutedPerDay(address(deployedToken), currentDay), TWO);
        assertEq(mediator.mediatorBalance(address(deployedToken)), 0);
        assertEq(deployedToken.balanceOf(user), TWO);
        assertEq(deployedToken.balanceOf(address(mediator)), 0);

        TokenEvent[] memory evs = _tokenEvents(TOKENS_BRIDGED);
        assertEq(evs.length, 2);
        _assertBridged(evs[1], address(deployedToken), user, ONE, EXAMPLE_MESSAGE_ID);
    }

    function test_handleBridgedTokens_rejectsUnknownTokens() public {
        _handleBridgedSetUp();

        assertTrue(!_exec(FAILED_MESSAGE_ID, _handleBridgedData(otherSideToken2, user, ONE)));
    }

    function test_handleBridgedTokens_respectsGlobalShutdown() public {
        _handleBridgedSetUp();
        _bridgedGlobalShutdown(_handleBridgedData(otherSideToken1, user, ONE));
    }

    function _bridgedGlobalShutdown(bytes memory _data) internal {
        vm.prank(owner);
        mediator.setExecutionDailyLimit(address(0), 0);

        assertTrue(!_exec(FAILED_MESSAGE_ID, _data));

        vm.prank(owner);
        mediator.setExecutionDailyLimit(address(0), EXECUTION_DAILY_LIMIT);

        assertTrue(_exec(OTHER_MESSAGE_ID, _data));
    }

    // =====================================================================
    // bridged tokens / handleBridgedTokensAndCall
    // =====================================================================

    function test_handleBridgedTokensAndCall_mintsAndCallsReceiver() public {
        ITestToken deployedToken = _handleBridgedSetUp();

        // can't be called by user
        vm.expectRevert();
        vm.prank(user);
        mediator.handleBridgedTokensAndCall(otherSideToken1, address(tokenReceiver), ONE, hex"1122");
        // can't be called by owner
        vm.expectRevert();
        vm.prank(owner);
        mediator.handleBridgedTokensAndCall(otherSideToken1, address(tokenReceiver), ONE, hex"1122");

        bytes memory data = _handleBridgedAndCallData(otherSideToken1, address(tokenReceiver), ONE, hex"1122");

        // message must be generated by mediator contract on the other network
        assertTrue(!_execFrom(FAILED_MESSAGE_ID, data, owner));

        assertTrue(_exec(EXAMPLE_MESSAGE_ID, data));

        assertEq(mediator.totalExecutedPerDay(address(deployedToken), currentDay), TWO);
        assertEq(mediator.mediatorBalance(address(deployedToken)), 0);
        assertEq(deployedToken.balanceOf(address(tokenReceiver)), ONE);
        assertEq(deployedToken.balanceOf(address(mediator)), 0);
        assertEq(tokenReceiver.token(), address(deployedToken));
        assertEq(tokenReceiver.from(), address(mediator));
        assertEq(tokenReceiver.value(), ONE);
        assertEq(tokenReceiver.data(), hex"1122");

        TokenEvent[] memory evs = _tokenEvents(TOKENS_BRIDGED);
        assertEq(evs.length, 2);
        _assertBridged(evs[1], address(deployedToken), address(tokenReceiver), ONE, EXAMPLE_MESSAGE_ID);
    }

    function test_handleBridgedTokensAndCall_handlesMissingOnTokenTransfer() public {
        ITestToken deployedToken = _handleBridgedSetUp();

        // can't be called by user
        vm.expectRevert();
        vm.prank(user);
        mediator.handleBridgedTokensAndCall(otherSideToken1, user, ONE, hex"1122");
        // can't be called by owner
        vm.expectRevert();
        vm.prank(owner);
        mediator.handleBridgedTokensAndCall(otherSideToken1, user, ONE, hex"1122");

        bytes memory data = _handleBridgedAndCallData(otherSideToken1, user, ONE, hex"1122");

        // message must be generated by mediator contract on the other network
        assertTrue(!_execFrom(FAILED_MESSAGE_ID, data, owner));

        assertTrue(_exec(EXAMPLE_MESSAGE_ID, data));

        assertEq(mediator.totalExecutedPerDay(address(deployedToken), currentDay), TWO);
        assertEq(mediator.mediatorBalance(address(deployedToken)), 0);
        assertEq(deployedToken.balanceOf(user), TWO);
        assertEq(deployedToken.balanceOf(address(mediator)), 0);

        TokenEvent[] memory evs = _tokenEvents(TOKENS_BRIDGED);
        assertEq(evs.length, 2);
        _assertBridged(evs[1], address(deployedToken), user, ONE, EXAMPLE_MESSAGE_ID);
    }

    function test_handleBridgedTokensAndCall_rejectsUnknownTokens() public {
        _handleBridgedSetUp();

        assertTrue(!_exec(FAILED_MESSAGE_ID, _handleBridgedAndCallData(otherSideToken2, user, ONE, hex"00")));
    }

    function test_handleBridgedTokensAndCall_respectsGlobalShutdown() public {
        _handleBridgedSetUp();
        _bridgedGlobalShutdown(_handleBridgedAndCallData(otherSideToken1, user, ONE, hex"00"));
    }

    // =====================================================================
    // bridged tokens / requestFailedMessageFix
    // =====================================================================

    function test_bridgedTokens_requestFailedMessageFix() public {
        _afterInit();

        assertTrue(!_exec(FAILED_MESSAGE_ID, _deployData(user, ONE), address(mediator), otherSideMediator, 100));

        mediator.requestFailedMessageFix(FAILED_MESSAGE_ID);

        AmbMessage[] memory msgs = _ambMessages();
        assertEq(msgs.length, 1);
        assertEq(_selectorOf(msgs[0].data), FIX_FAILED_MESSAGE);
        assertEq(abi.decode(_argsOf(msgs[0].data), (bytes32)), FAILED_MESSAGE_ID);
    }

    function test_bridgedTokens_requestFailedMessageFix_onlyFailedMessage() public {
        _afterInit();

        assertTrue(_exec(EXAMPLE_MESSAGE_ID, _deployData(user, ONE)));

        vm.expectRevert();
        mediator.requestFailedMessageFix(EXAMPLE_MESSAGE_ID);
    }

    function test_bridgedTokens_requestFailedMessageFix_onlyIfReceiver() public {
        _afterInit();

        assertTrue(!_exec(FAILED_MESSAGE_ID, _deployData(user, ONE), address(amb), otherSideMediator, 1000000));

        vm.expectRevert();
        mediator.requestFailedMessageFix(FAILED_MESSAGE_ID);
    }

    function test_bridgedTokens_requestFailedMessageFix_onlyFromOtherSideMediator() public {
        _afterInit();

        assertTrue(!_execFrom(FAILED_MESSAGE_ID, _deployData(user, ONE), owner));

        vm.expectRevert();
        mediator.requestFailedMessageFix(FAILED_MESSAGE_ID);
    }

    function test_bridgedTokens_requestFailedMessageFix_multipleTimes() public {
        _afterInit();

        assertTrue(!_exec(FAILED_MESSAGE_ID, _deployData(user, ONE), address(mediator), otherSideMediator, 100));

        mediator.requestFailedMessageFix(FAILED_MESSAGE_ID);
        mediator.requestFailedMessageFix(FAILED_MESSAGE_ID);

        AmbMessage[] memory msgs = _ambMessages();
        assertEq(msgs.length, 2);
        assertEq(_selectorOf(msgs[0].data), FIX_FAILED_MESSAGE);
        assertEq(_selectorOf(msgs[1].data), FIX_FAILED_MESSAGE);
    }

    // =====================================================================
    // bridged tokens / custom token pair
    // =====================================================================

    function test_customTokenPair_setCustomBridgedToken() public {
        _afterInit();

        address deployedToken = address(_deployBridgedToken(user, ONE));

        vm.expectRevert();
        vm.prank(owner);
        mediator.setCustomTokenAddressPair(otherSideToken2, address(token));
        vm.expectRevert();
        vm.prank(owner);
        mediator.setCustomTokenAddressPair(otherSideToken2, address(amb));

        vm.prank(owner);
        token.transferOwnership(address(mediator));

        vm.expectRevert();
        vm.prank(user);
        mediator.setCustomTokenAddressPair(otherSideToken2, address(token));
        vm.expectRevert();
        vm.prank(owner);
        mediator.setCustomTokenAddressPair(otherSideToken1, address(token));
        vm.expectRevert();
        vm.prank(owner);
        mediator.setCustomTokenAddressPair(otherSideToken2, deployedToken);
        vm.prank(owner);
        mediator.setCustomTokenAddressPair(otherSideToken2, address(token));
        vm.expectRevert();
        vm.prank(owner);
        mediator.setCustomTokenAddressPair(otherSideToken2, address(token));

        assertEq(mediator.bridgedTokenAddress(otherSideToken2), address(token));
        assertEq(mediator.nativeTokenAddress(address(token)), otherSideToken2);
    }

    function test_customTokenPair_rejectsDifferentDecimals() public {
        _afterInit();

        token = ITestToken(_deployPermittableToken("Test", "TST", 18));
        vm.prank(owner);
        token.transferOwnership(address(mediator));
        vm.prank(owner);
        mediator.setCustomTokenAddressPair(otherSideToken1, address(token));

        assertTrue(!_exec(EXAMPLE_MESSAGE_ID, _deployData(otherSideToken1, "Test", "TST", 20, user, ONE)));
        assertTrue(_exec(OTHER_MESSAGE_ID, _deployData(otherSideToken1, "Test", "TST", 18, user, ONE)));
    }
}
