pragma solidity 0.7.5;
pragma abicoder v2;

import "./base/E2EBase.sol";
import "../contracts/mocks/TokenReceiver.sol";

/**
 * @dev Token native to Gnosis Chain, bridged to Ethereum and back, through a new Omnibridge pair
 * on top of the production AMBs.
 */
contract HomeToForeignE2ETest is E2EBase {
    uint256 internal constant SUPPLY = 1000 ether;
    uint256 internal constant VALUE = 10 ether;

    E2EToken internal token; // on Gnosis Chain

    function setUp() public override {
        super.setUp();
        _deployMediators();
        vm.selectFork(homeFork);
        token = _deployToken(SUPPLY);
        _clearMessages();
    }

    // Bridges VALUE of `token` from Gnosis to `user` on Ethereum and returns the bridged token.
    function _bridgeToForeign() internal returns (ERC20 bridged) {
        vm.selectFork(homeFork);
        _relayTokens(homeMediator, address(token), user, VALUE);
        (, bool status) = _relayToForeign();
        assertTrue(status, "message failed on Ethereum");
        bridged = ERC20(foreignMediator.bridgedTokenAddress(address(token)));
    }

    function test_firstBridge_deploysToken() public {
        ERC20 bridged = _bridgeToForeign();

        // Ethereum: token deployed and minted to the user
        assertTrue(_hasCode(address(bridged)));
        assertEq(bridged.name(), "E2E Token on Mainnet");
        assertEq(bridged.symbol(), "E2E");
        assertEq(uint256(bridged.decimals()), 18);
        assertEq(bridged.balanceOf(user), VALUE);
        assertEq(foreignMediator.nativeTokenAddress(address(bridged)), address(token));

        // Gnosis: tokens locked in the mediator
        vm.selectFork(homeFork);
        assertEq(token.balanceOf(user), SUPPLY - VALUE);
        assertEq(token.balanceOf(address(homeMediator)), VALUE);
        assertEq(homeMediator.mediatorBalance(address(token)), VALUE);
    }

    function test_secondBridge_reusesToken() public {
        ERC20 first = _bridgeToForeign();
        ERC20 second = _bridgeToForeign();

        assertEq(address(second), address(first));
        assertEq(second.balanceOf(user), 2 * VALUE);

        vm.selectFork(homeFork);
        assertEq(homeMediator.mediatorBalance(address(token)), 2 * VALUE);
    }

    function test_relayTokensAndCall_callsReceiverOnForeign() public {
        vm.selectFork(foreignFork);
        TokenReceiver receiver = new TokenReceiver();

        vm.selectFork(homeFork);
        _relayTokensAndCall(homeMediator, address(token), address(receiver), VALUE, hex"1122");
        (, bool status) = _relayToForeign();
        assertTrue(status);

        address bridged = foreignMediator.bridgedTokenAddress(address(token));
        assertEq(ERC20(bridged).balanceOf(address(receiver)), VALUE);
        assertEq(receiver.token(), bridged);
        assertEq(receiver.from(), address(foreignMediator));
        assertEq(receiver.value(), VALUE);
        assertEq(receiver.data(), hex"1122");
    }

    function test_bridgeBack_unlocksOnHome() public {
        ERC20 bridged = _bridgeToForeign();

        // Ethereum -> Gnosis: bridged tokens are burnt and the native ones unlocked
        vm.selectFork(foreignFork);
        _relayTokens(foreignMediator, address(bridged), user, 4 ether);
        assertEq(bridged.balanceOf(user), VALUE - 4 ether);
        assertEq(bridged.totalSupply(), VALUE - 4 ether);

        (, bool status) = _relayToHome();
        assertTrue(status, "message failed on Gnosis");

        assertEq(token.balanceOf(user), SUPPLY - VALUE + 4 ether);
        assertEq(homeMediator.mediatorBalance(address(token)), VALUE - 4 ether);
        assertTrue(homeMediator.isBridgedTokenDeployAcknowledged(address(token)));
    }

    function test_failedMessage_isFixedOnHome() public {
        // make the transfer fail on Ethereum: execution limit below the bridged value
        vm.selectFork(foreignFork);
        vm.prank(bridgeOwner);
        foreignMediator.setExecutionMaxPerTx(address(0), 1 ether);

        vm.selectFork(homeFork);
        _relayTokens(homeMediator, address(token), user, VALUE);
        (bytes32 messageId, bool status) = _relayToForeign();
        assertTrue(!status, "message should fail on Ethereum");
        assertEq(foreignMediator.bridgedTokenAddress(address(token)), address(0));

        // Ethereum: anyone can ask Gnosis to return the tokens of the failed message
        foreignMediator.requestFailedMessageFix(messageId);
        (, bool fixStatus) = _relayToHome();
        assertTrue(fixStatus);

        assertTrue(homeMediator.messageFixed(messageId));
        assertEq(token.balanceOf(user), SUPPLY);
        assertEq(homeMediator.mediatorBalance(address(token)), 0);
    }

    function test_limits_rejectAboveMaxPerTx() public {
        vm.selectFork(homeFork);
        vm.prank(user);
        token.approve(address(homeMediator), MAX_PER_TX + 1);
        vm.expectRevert();
        vm.prank(user);
        homeMediator.relayTokens(IERC677(address(token)), user, MAX_PER_TX + 1);
    }
}
