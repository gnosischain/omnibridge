// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.7.5;
pragma abicoder v2;

import {Test} from "forge-std/Test.sol";
import {ForeignOmnibridge} from "../contracts/upgradeable_contracts/ForeignOmnibridge.sol";
import {EternalStorageProxy} from "../contracts/upgradeability/EternalStorageProxy.sol";
import {WETHOmnibridgeRouter} from "../contracts/helpers/WETHOmnibridgeRouter.sol";
import {AMBMock} from "../contracts/mocks/AMBMock.sol";
import {WETH} from "../contracts/mocks/WETH.sol";
import {IOmnibridge} from "../contracts/interfaces/IOmnibridge.sol";
import {IWETH} from "../contracts/interfaces/IWETH.sol";

contract SeededForeignOmnibridge is ForeignOmnibridge {
    constructor() ForeignOmnibridge("") {}

    function seed(address token, uint256 value) external {
        _initializeTokenBridgeLimits(token, 18);
        _setMediatorBalance(token, value);
    }
}

contract RouterCallbackAtomicityTest is Test {
    address constant ETH_WETH_ROUTER = 0xa6439Ca0FCbA1d0F80df0bE6A17220feD9c9038a;

    function test_nestedWithdrawOutOfGasNeverCommitsRouterWeth() public {
        EternalStorageProxy proxy = new EternalStorageProxy();
        proxy.upgradeTo(1, address(new SeededForeignOmnibridge()));
        SeededForeignOmnibridge bridge = SeededForeignOmnibridge(payable(address(proxy)));
        AMBMock amb = new AMBMock();
        WETH weth = new WETH();
        WETHOmnibridgeRouter router = new WETHOmnibridgeRouter(
            IOmnibridge(address(bridge)), IWETH(address(weth)), address(this)
        );
        address routerSource = address(router);
        uint256 codeSize;
        assembly { codeSize := extcodesize(routerSource) }
        bytes memory routerCode = new bytes(codeSize);
        assembly { extcodecopy(routerSource, add(routerCode, 32), 0, codeSize) }
        vm.etch(ETH_WETH_ROUTER, routerCode);

        bridge.initialize(
            address(amb), address(0xBEEF),
            [uint256(3 ether), uint256(2 ether), uint256(1)],
            [uint256(3 ether), uint256(2 ether)],
            1000000, address(this), address(weth)
        );
        bridge.seed(address(weth), 1 ether);
        vm.deal(address(this), 1 ether);
        weth.deposit{value: 1 ether}();
        require(weth.transfer(address(bridge), 1 ether));

        address recipient = address(0x1234);
        uint256 recipientBalanceBefore = recipient.balance;
        bytes32 messageId = bytes32(uint256(1));
        bytes memory payload = abi.encodeWithSelector(
            bridge.handleNativeTokensAndCall.selector,
            address(weth), ETH_WETH_ROUTER, 1 ether, abi.encodePacked(recipient)
        );

        uint256 honestDeliveries;
        for (uint256 gasLimit = 70000; gasLimit <= 220000; gasLimit += 100) {
            uint256 snapshotId = vm.snapshot();
            amb.executeMessageCall(address(bridge), address(0xBEEF), payload, messageId, gasLimit);
            assertFalse(
                amb.messageCallStatus(messageId) && weth.balanceOf(ETH_WETH_ROUTER) == 1 ether,
                "successful AMB message stranded WETH"
            );
            if (amb.messageCallStatus(messageId) && recipient.balance == recipientBalanceBefore + 1 ether) {
                honestDeliveries++;
            }
            vm.revertTo(snapshotId);
        }
        assertGt(honestDeliveries, 0, "no successful delivery in gas sweep");
    }
}
