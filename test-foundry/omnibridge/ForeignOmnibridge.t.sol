pragma solidity 0.7.5;
pragma abicoder v2;

import "./OmnibridgeCommonTest.sol";

/**
 * @dev Foundry port of contract('ForeignOmnibridge') in test/omnibridge/common.test.js:
 * the shared suite plus the foreign-only request gas limit tests.
 * The Compound and AAVE connector tests are not ported: they need the pre-deployed
 * Compound/AAVE contracts from the docker test chain (test/compound, test/aave).
 */
contract ForeignOmnibridgeTest is OmnibridgeCommonTest {
    function _isHome() internal pure override returns (bool) {
        return false;
    }

    function _deployMediator() internal override returns (address) {
        return address(new ForeignOmnibridge(SUFFIX));
    }

    function _foreign() internal view returns (ForeignOmnibridge) {
        return ForeignOmnibridge(address(mediator));
    }

    // =====================================================================
    // update mediator parameters / request gas limit
    // =====================================================================

    function test_requestGasLimit_setDefault() public {
        _afterInit();

        vm.expectRevert();
        vm.prank(user);
        _foreign().setRequestGasLimit(200000);
        vm.prank(owner);
        _foreign().setRequestGasLimit(200000);

        assertEq(_foreign().requestGasLimit(), 200000);
    }

    function test_requestGasLimit_usedWhenBridgingTokens() public {
        _afterInit();

        _send(0, MIN_PER_TX);
        _send(0, MIN_PER_TX);

        vm.prank(owner);
        _foreign().setRequestGasLimit(200000);

        _send(0, MIN_PER_TX);

        AmbMessage[] memory msgs = _ambMessages();
        assertEq(msgs.length, 3);
        assertEq(msgs[0].gas, 1000000);
        assertEq(msgs[1].gas, 1000000);
        assertEq(msgs[2].gas, 200000);
    }
}
