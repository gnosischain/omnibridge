// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.7.5;
pragma abicoder v2;
import "forge-std/Test.sol";
import "forge-std/console.sol";
import "forge-std/StdUtils.sol";
import { IForeignOmnibridge } from "./interfaces/IForeignOmnibridge.sol";
import { ForeignOmnibridge } from "../contracts/upgradeable_contracts/ForeignOmnibridge.sol";
import { EternalStorageProxy } from "../contracts/upgradeability/EternalStorageProxy.sol";
import { IFiatTokenV2_2 } from "./interfaces/IFiatTokenV2_2.sol";
import { IMasterMinter } from "./interfaces/IMasterMinter.sol";
import { IBridgeValidators } from "./interfaces/IBridgeValidators.sol";
import { IAMB } from "./interfaces/IAMB.sol";

contract ethTest is Test {
    IForeignOmnibridge foreignOmnibridge;
    IAMB amb;
    IBridgeValidators bridgeValidators;
    IFiatTokenV2_2 usdc;
    IMasterMinter masterMinter;
    address circleAddr;
    address senderFromETH;
    address testValidator;
    address senderFromGC;
    uint256 gcSenderUSDCEAmount;
    uint256 ethSenderUSDCAmount;

    event CircleAddressSet(address indexed oldCircleAddress, address indexed newCircleAddress);

    function setUp() public {
        ForeignOmnibridge newForeignOmnibridgeImplementation = new ForeignOmnibridge(" on Mainnet");
        EternalStorageProxy foreignOmnibridgeProxy = EternalStorageProxy(payable(vm.envAddress("FOREIGN_OMNIBRIDGE")));
        vm.prank(foreignOmnibridgeProxy.upgradeabilityOwner());
        foreignOmnibridgeProxy.upgradeTo(7, address(newForeignOmnibridgeImplementation));
        foreignOmnibridge = IForeignOmnibridge(address(foreignOmnibridgeProxy));

        amb = IAMB(vm.envAddress("FOREIGN_AMB"));
        bridgeValidators = IBridgeValidators(vm.envAddress("FOREIGN_VALIDATOR_CONTRACT"));
        testValidator = vm.envAddress("VALIDATOR_ADDRESS");
        setNewValidator();

        usdc = IFiatTokenV2_2(vm.envAddress("USDC_ON_ETH"));
        masterMinter = IMasterMinter(vm.envAddress("USDC_MASTER_MINTER"));
        circleAddr = makeAddr("Circle");
        vm.startPrank(masterMinter.owner());
        masterMinter.configureController(masterMinter.owner(), address(foreignOmnibridge));
        masterMinter.configureMinter(1e30);
        vm.stopPrank();

        senderFromGC = makeAddr("senderFromGC");
        senderFromETH = 0xD6153F5af5679a75cC85D8974463545181f48772; // USDC holder on Ethereum, for testing only

        gcSenderUSDCEAmount = 1e10;
        ethSenderUSDCAmount = 1e10;
    }

    function test_setCircleAddress() public {
        vm.startPrank(foreignOmnibridge.owner());
        vm.expectEmit(address(foreignOmnibridge));
        emit CircleAddressSet(address(0), circleAddr);
        foreignOmnibridge.setCircleAddress(circleAddr);
        assertEq(foreignOmnibridge.getCircleAddress(), circleAddr);
        vm.stopPrank();

        vm.prank(makeAddr("randomAddress"));
        vm.expectRevert();
        foreignOmnibridge.setCircleAddress(circleAddr);
    }

    function testFuzz_burnLockedUSDC(uint256 amount) public {
        vm.assume(amount <= usdc.balanceOf(address(foreignOmnibridge)) && amount > 0);
        // actual USDC balance of Omnibridge
        uint256 balanceBefore = usdc.balanceOf(address(foreignOmnibridge));
        // registered USDC balance of Omnibridge (the net amount of USDC bridged by user)
        uint256 mediatorBalanceBefore = foreignOmnibridge.mediatorBalance(address(usdc));

        grantMintingAllowance(amount); // set omnibridge as minter
        setCircleAddress();

        vm.prank(circleAddr);
        foreignOmnibridge.burnLockedUSDC(amount);

        uint256 balanceAfter = usdc.balanceOf(address(foreignOmnibridge));
        assertEq(balanceBefore - amount, balanceAfter);
        assertEq(foreignOmnibridge.mediatorBalance(address(usdc)), mediatorBalanceBefore - amount);
    }

    function testFuzz_relayTokensFromETH(uint256 amount) public {
        // actual USDC balance of Omnibridge
        uint256 bridgeBalanceBefore = usdc.balanceOf(address(foreignOmnibridge));
        uint256 userBalanceBefore = usdc.balanceOf(senderFromETH);
        // registered USDC balance of Omnibridge (the accumultive amount of USDC bridged by user)
        uint256 mediatorBalanceBefore = foreignOmnibridge.mediatorBalance(address(usdc));
        uint256 maxUSDCToBridge =
            userBalanceBefore < foreignOmnibridge.maxPerTx(address(usdc))
                ? userBalanceBefore
                : foreignOmnibridge.maxPerTx(address(usdc));

        amount = bound(amount, foreignOmnibridge.minPerTx(address(usdc)), maxUSDCToBridge);
        grantMintingAllowance(amount);

        vm.startPrank(senderFromETH);
        usdc.approve(address(foreignOmnibridge), amount);
        foreignOmnibridge.relayTokens(address(usdc), amount);
        vm.stopPrank();

        uint256 bridgeBalanceAfter = usdc.balanceOf(address(foreignOmnibridge));
        uint256 userBalanceAfter = usdc.balanceOf(senderFromETH);
        assertEq(bridgeBalanceBefore, bridgeBalanceAfter);
        assertEq(userBalanceBefore, userBalanceAfter + amount);
        assertEq(foreignOmnibridge.mediatorBalance(address(usdc)), mediatorBalanceBefore + amount);
    }

    function test_relayTokensFromETH() public {
        uint256 bridgeBalanceBefore = usdc.balanceOf(address(foreignOmnibridge));
        uint256 userBalanceBefore = usdc.balanceOf(senderFromETH);

        uint256 mediatorBalanceBefore = foreignOmnibridge.mediatorBalance(address(usdc));

        grantMintingAllowance(ethSenderUSDCAmount);

        vm.startPrank(senderFromETH);
        usdc.approve(address(foreignOmnibridge), ethSenderUSDCAmount);
        foreignOmnibridge.relayTokens(address(usdc), ethSenderUSDCAmount);
        vm.stopPrank();

        uint256 bridgeBalanceAfter = usdc.balanceOf(address(foreignOmnibridge));
        uint256 userBalanceAfter = usdc.balanceOf(senderFromETH);
        assertEq(bridgeBalanceBefore, bridgeBalanceAfter);
        assertEq(userBalanceBefore, userBalanceAfter + ethSenderUSDCAmount);
        assertEq(foreignOmnibridge.mediatorBalance(address(usdc)), mediatorBalanceBefore + ethSenderUSDCAmount);
    }

    function test_receiveUSDCFromGC() public {
        string memory root = vm.projectRoot();
        string memory path = string(abi.encodePacked(root, "/usdc_test/test_output/ETH_input.json"));
        string memory json = vm.readFile(path);
        bytes memory messageInBytes = vm.parseJson(json, ".message");
        bytes memory message = abi.decode(messageInBytes, (bytes));
        bytes memory signaturesInBytes = vm.parseJson(json, ".packedSignatures");
        bytes memory signatures = abi.decode(signaturesInBytes, (bytes));
        uint256 bridgeBalanceBefore = usdc.balanceOf(address(foreignOmnibridge));
        uint256 senderBalanceBefore = usdc.balanceOf(senderFromGC);
        uint256 mediatorBalanceBefore = foreignOmnibridge.mediatorBalance(address(usdc));

        vm.prank(testValidator);
        amb.executeSignatures(message, signatures);

        assertEq(usdc.balanceOf(address(foreignOmnibridge)), bridgeBalanceBefore);
        assertEq(usdc.balanceOf(senderFromGC), senderBalanceBefore + gcSenderUSDCEAmount);
        assertEq(foreignOmnibridge.mediatorBalance(address(usdc)), mediatorBalanceBefore - gcSenderUSDCEAmount);
    }

    // ================= Helper ==============================
    function setCircleAddress() public {
        vm.prank(foreignOmnibridge.owner());
        foreignOmnibridge.setCircleAddress(circleAddr);
        assertEq(foreignOmnibridge.getCircleAddress(), circleAddr);
    }

    function grantMintingAllowance(uint256 mintingAllowance) public {
        vm.prank(masterMinter.owner());
        masterMinter.configureController(circleAddr, address(foreignOmnibridge));
        vm.prank(circleAddr);
        masterMinter.configureMinter(mintingAllowance);
        assertEq(masterMinter.getWorker(circleAddr), address(foreignOmnibridge));
    }

    function setNewValidator() public {
        address bridgeValidatorOwner = bridgeValidators.owner();
        vm.startPrank(bridgeValidatorOwner);
        bridgeValidators.setRequiredSignatures(1);
        bridgeValidators.addValidator(testValidator);
        vm.stopPrank();
    }
}
