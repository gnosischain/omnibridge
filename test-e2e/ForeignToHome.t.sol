pragma solidity 0.7.5;
pragma abicoder v2;

import "./base/E2EBase.sol";
import "../contracts/mocks/TokenReceiver.sol";

/**
 * @dev Token native to Ethereum, bridged to Gnosis Chain and back, through a new Omnibridge pair
 * on top of the production AMBs.
 */
contract ForeignToHomeE2ETest is E2EBase {
    uint256 internal constant SUPPLY = 1000 ether;
    uint256 internal constant VALUE = 10 ether;

    E2EToken internal token; // on Ethereum

    function setUp() public override {
        super.setUp();
        _deployMediators();
        vm.selectFork(foreignFork);
        token = _deployToken(SUPPLY);
        _clearMessages();
    }

    // Bridges VALUE of `token` from Ethereum to `user` on Gnosis and returns the bridged token.
    function _bridgeToHome() internal returns (ERC20 bridged) {
        vm.selectFork(foreignFork);
        _relayTokens(foreignMediator, address(token), user, VALUE);
        (, bool status) = _relayToHome();
        assertTrue(status, "message failed on Gnosis");
        bridged = ERC20(homeMediator.bridgedTokenAddress(address(token)));
    }

    function test_firstBridge_deploysToken() public {
        ERC20 bridged = _bridgeToHome();

        // Gnosis: token deployed and minted to the user
        assertTrue(_hasCode(address(bridged)));
        assertEq(bridged.name(), "E2E Token on xDai");
        assertEq(bridged.symbol(), "E2E");
        assertEq(uint256(bridged.decimals()), 18);
        assertEq(bridged.balanceOf(user), VALUE);
        assertEq(homeMediator.nativeTokenAddress(address(bridged)), address(token));
        assertEq(homeMediator.foreignTokenAddress(address(bridged)), address(token));

        // Ethereum: tokens locked in the mediator
        vm.selectFork(foreignFork);
        assertEq(token.balanceOf(user), SUPPLY - VALUE);
        assertEq(token.balanceOf(address(foreignMediator)), VALUE);
        assertEq(foreignMediator.mediatorBalance(address(token)), VALUE);
        assertTrue(foreignMediator.isBridgedTokenDeployAcknowledged(address(token)) == false);
    }

    function test_secondBridge_reusesToken() public {
        ERC20 first = _bridgeToHome();
        ERC20 second = _bridgeToHome();

        assertEq(address(second), address(first));
        assertEq(second.balanceOf(user), 2 * VALUE);

        vm.selectFork(foreignFork);
        assertEq(foreignMediator.mediatorBalance(address(token)), 2 * VALUE);
    }

    function test_relayTokensAndCall_callsReceiverOnHome() public {
        vm.selectFork(homeFork);
        TokenReceiver receiver = new TokenReceiver();

        vm.selectFork(foreignFork);
        _relayTokensAndCall(foreignMediator, address(token), address(receiver), VALUE, hex"1122");
        (, bool status) = _relayToHome();
        assertTrue(status);

        address bridged = homeMediator.bridgedTokenAddress(address(token));
        assertEq(ERC20(bridged).balanceOf(address(receiver)), VALUE);
        assertEq(receiver.token(), bridged);
        assertEq(receiver.from(), address(homeMediator));
        assertEq(receiver.value(), VALUE);
        assertEq(receiver.data(), hex"1122");
    }

    function test_bridgeBack_unlocksOnForeign() public {
        ERC20 bridged = _bridgeToHome();

        // Gnosis -> Ethereum: bridged tokens are burnt and the native ones unlocked
        vm.selectFork(homeFork);
        _relayTokens(homeMediator, address(bridged), user, 4 ether);
        assertEq(bridged.balanceOf(user), VALUE - 4 ether);
        assertEq(bridged.totalSupply(), VALUE - 4 ether);

        (, bool status) = _relayToForeign();
        assertTrue(status, "message failed on Ethereum");

        assertEq(token.balanceOf(user), SUPPLY - VALUE + 4 ether);
        assertEq(foreignMediator.mediatorBalance(address(token)), VALUE - 4 ether);
        assertTrue(foreignMediator.isBridgedTokenDeployAcknowledged(address(token)));
    }

    function test_failedMessage_isFixedOnForeign() public {
        // make the transfer fail on Gnosis: execution limit below the bridged value
        vm.selectFork(homeFork);
        vm.prank(bridgeOwner);
        homeMediator.setExecutionMaxPerTx(address(0), 1 ether);

        vm.selectFork(foreignFork);
        _relayTokens(foreignMediator, address(token), user, VALUE);
        (bytes32 messageId, bool status) = _relayToHome();
        assertTrue(!status, "message should fail on Gnosis");
        assertEq(homeMediator.bridgedTokenAddress(address(token)), address(0));

        // Gnosis: anyone can ask Ethereum to return the tokens of the failed message
        homeMediator.requestFailedMessageFix(messageId);
        (, bool fixStatus) = _relayToForeign();
        assertTrue(fixStatus);

        assertTrue(foreignMediator.messageFixed(messageId));
        assertEq(token.balanceOf(user), SUPPLY);
        assertEq(foreignMediator.mediatorBalance(address(token)), 0);
    }

    function test_limits_rejectAboveMaxPerTx() public {
        vm.selectFork(foreignFork);
        vm.prank(user);
        token.approve(address(foreignMediator), MAX_PER_TX + 1);
        vm.expectRevert();
        vm.prank(user);
        foreignMediator.relayTokens(IERC677(address(token)), user, MAX_PER_TX + 1);
    }
}
