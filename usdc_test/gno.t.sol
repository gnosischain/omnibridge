// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.7.5;
pragma abicoder v2;
import "forge-std/Test.sol";
import "forge-std/console.sol";
import "forge-std/StdUtils.sol";
import "forge-std/StdJson.sol";
import { IHomeOmnibridge } from "./interfaces/IHomeOmnibridge.sol";
import { HomeOmnibridge } from "../contracts/upgradeable_contracts/HomeOmnibridge.sol";
import { EternalStorageProxy } from "../contracts/upgradeability/EternalStorageProxy.sol";
import { IFiatTokenV2_2 } from "./interfaces/IFiatTokenV2_2.sol";
import { IMasterMinter } from "./interfaces/IMasterMinter.sol";
import { IBridgeValidators } from "./interfaces/IBridgeValidators.sol";
import { IAMB } from "./interfaces/IAMB.sol";
import { IERC20 } from "./interfaces/IERC20.sol";

contract gnoTest is Test {
    IHomeOmnibridge homeOmnibridge;
    IAMB amb;
    IBridgeValidators bridgeValidators;
    IFiatTokenV2_2 usdcE;
    IMasterMinter masterMinter;
    IERC20 usdcOnGno;
    address testValidator;
    address receiver;
    address senderFromGC;
    address senderFromETH;
    uint256 gcSenderUSDCEAmount;
    uint256 ethSenderUSDCAmount;

    function setUp() public {
        HomeOmnibridge newHomeOmnibridgeImplementation = new HomeOmnibridge(" on xDAI");
        EternalStorageProxy homeOmnibridgeProxy = EternalStorageProxy(payable(vm.envAddress("HOME_OMNIBRIDGE")));
        vm.prank(homeOmnibridgeProxy.upgradeabilityOwner());
        homeOmnibridgeProxy.upgradeTo(9, address(newHomeOmnibridgeImplementation));
        homeOmnibridge = IHomeOmnibridge(address(homeOmnibridgeProxy));
        vm.prank(homeOmnibridge.owner());
        homeOmnibridge.upgradeToVersion9();

        amb = IAMB(vm.envAddress("HOME_AMB"));
        bridgeValidators = IBridgeValidators(vm.envAddress("HOME_VALIDATOR_CONTRACT"));
        testValidator = vm.envAddress("VALIDATOR_ADDRESS");
        setNewValidator();

        usdcE = IFiatTokenV2_2(vm.envAddress("USDCE"));
        masterMinter = IMasterMinter(vm.envAddress("USDCE_MASTER_MINTER"));
        usdcOnGno = IERC20(vm.envAddress("USDC_ON_GNO"));
        vm.startPrank(masterMinter.owner());
        masterMinter.configureController(masterMinter.owner(), address(homeOmnibridge));
        masterMinter.configureMinter(1e30);
        vm.stopPrank();

        senderFromETH = 0xD6153F5af5679a75cC85D8974463545181f48772; // USDC holder on Ethereum, for testing only
        senderFromGC = makeAddr("senderFromGC");
        gcSenderUSDCEAmount = 1e10;
        ethSenderUSDCAmount = 1e10;

        vm.prank(address(homeOmnibridge));
        usdcE.mint(senderFromGC, gcSenderUSDCEAmount);
        assertEq(usdcE.balanceOf(senderFromGC), gcSenderUSDCEAmount);
    }

    function test_receiveUSDCFromETH() public {
        string memory root = vm.projectRoot();
        string memory path = string(abi.encodePacked(root, "/usdc_test/test_output/GNO_input.json"));
        string memory json = vm.readFile(path);
        bytes memory messageInBytes = vm.parseJson(json, ".data");
        bytes memory message = abi.decode(messageInBytes, (bytes));

        uint256 userBalanceBefore = usdcE.balanceOf(senderFromETH);
        uint256 bridgeBalanceBefore = usdcE.balanceOf(address(homeOmnibridge));

        vm.prank(testValidator);
        amb.executeAffirmation(message);

        assertEq(usdcE.balanceOf(senderFromETH), userBalanceBefore + ethSenderUSDCAmount);
        assertEq(usdcE.balanceOf(address(homeOmnibridge)), bridgeBalanceBefore);
    }

    function test_relayLegacyUSDCFromGC() public {
        address usdcWhale = 0xBA12222222228d8Ba445958a75a0704d566BF2C8; // Legacy USDC (USDC on xDAI) holder on Gnosis Chain
        vm.startPrank(usdcWhale);
        usdcOnGno.approve(address(homeOmnibridge), usdcOnGno.balanceOf(usdcWhale));
        vm.expectRevert();
        homeOmnibridge.relayTokens(address(usdcOnGno), 1e10);
        vm.stopPrank();
    }

    function test_relayUSDCEFromGC() public {
        vm.startPrank(senderFromGC);
        usdcE.approve(address(homeOmnibridge), usdcE.balanceOf(senderFromGC));
        homeOmnibridge.relayTokens(address(usdcE), usdcE.balanceOf(senderFromGC));
        vm.stopPrank();

        assertEq(usdcE.balanceOf(senderFromGC), 0);
        assertEq(usdcE.balanceOf(address(homeOmnibridge)), 0);
    }

    // ============= Helper ===================
    function setNewValidator() public {
        address bridgeValidatorOwner = bridgeValidators.owner();
        vm.startPrank(bridgeValidatorOwner);
        bridgeValidators.setRequiredSignatures(1);
        bridgeValidators.addValidator(testValidator);
        vm.stopPrank();
    }
}
