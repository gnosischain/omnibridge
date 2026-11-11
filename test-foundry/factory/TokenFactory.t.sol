pragma solidity 0.7.5;
pragma abicoder v2;

import "../utils/TestHelpers.sol";
import "../../contracts/upgradeable_contracts/modules/factory/TokenFactory.sol";

/**
 * @dev Unit tests for TokenFactory: CREATE2 address prediction, deployment and revert cases.
 */
contract TokenFactoryTest is TestHelpers {
    address internal owner = makeAddr("owner");
    address internal deployer = makeAddr("deployer");
    address internal stranger = makeAddr("stranger");
    address internal sourceToken = makeAddr("sourceToken");

    address internal tokenImage;
    TokenFactory internal factory;

    function setUp() public {
        tokenImage = deployTokenImage();
        factory = new TokenFactory(owner, tokenImage);
        vm.prank(owner);
        factory.setDeployer(deployer, true);
    }

    function _codeSize(address _a) internal view returns (uint256 size) {
        assembly {
            size := extcodesize(_a)
        }
    }

    function _deploy(address _token) internal returns (address) {
        vm.prank(deployer);
        return factory.deploy("Bridged Token", "BT", 18, 100, _token);
    }

    // ---------------------------------------------------------------------
    // Address prediction
    // ---------------------------------------------------------------------

    function test_predict_matchesStandardCreate2Formula() public {
        // Same formula as EIP-1014, computed independently by forge-std.
        address expected =
            computeCreate2Address(
                bytes32(uint256(uint160(sourceToken))),
                keccak256(type(TokenProxy).creationCode),
                address(factory)
            );
        assertEq(factory.predictTokenProxyAddress(sourceToken), expected);
    }

    function test_predict_hasNoCodeBeforeDeploy() public {
        address predicted = factory.predictTokenProxyAddress(sourceToken);
        assertTrue(predicted != address(0));
        assertEq(_codeSize(predicted), 0);
    }

    function test_deploy_landsOnPredictedAddress() public {
        address predicted = factory.predictTokenProxyAddress(sourceToken);
        address deployed = _deploy(sourceToken);

        assertEq(deployed, predicted);
        assertGt(_codeSize(deployed), 0);
        // Prediction stays the same after deployment.
        assertEq(factory.predictTokenProxyAddress(sourceToken), deployed);
    }

    function testFuzz_deploy_landsOnPredictedAddress(address _token) public {
        address predicted = factory.predictTokenProxyAddress(_token);
        assertEq(_deploy(_token), predicted);
    }

    function test_predict_differsPerSourceToken() public {
        address other = makeAddr("otherSourceToken");
        assertTrue(factory.predictTokenProxyAddress(sourceToken) != factory.predictTokenProxyAddress(other));
    }

    function test_predict_differsPerFactory() public {
        TokenFactory otherFactory = new TokenFactory(owner, tokenImage);
        assertTrue(factory.predictTokenProxyAddress(sourceToken) != otherFactory.predictTokenProxyAddress(sourceToken));
    }

    function test_predict_independentOfTokenImageAndMetadata() public {
        address predicted = factory.predictTokenProxyAddress(sourceToken);

        // Changing the image must not move the address: it is not part of the init code.
        address newImage = deployTokenImage();
        vm.prank(owner);
        factory.setTokenImage(newImage);
        assertEq(factory.predictTokenProxyAddress(sourceToken), predicted);

        // Metadata is passed to initialize(), not the constructor, so it does not affect the address either.
        vm.prank(deployer);
        address deployed = factory.deploy("Other Name", "ON", 6, 1, sourceToken);
        assertEq(deployed, predicted);
    }

    // ---------------------------------------------------------------------
    // Deployment result
    // ---------------------------------------------------------------------

    function test_deploy_initializesToken() public {
        IBridgedToken token = IBridgedToken(_deploy(sourceToken));

        assertEq(token.name(), "Bridged Token");
        assertEq(token.symbol(), "BT");
        assertEq(uint256(token.decimals()), 18);
        assertEq(token.owner(), deployer);
        assertEq(token.bridgeContract(), deployer);
        assertEq(token.implementation(), tokenImage);
        assertEq(token.totalSupply(), 0);
    }

    function test_deploy_ownerCanMint() public {
        IBridgedToken token = IBridgedToken(_deploy(sourceToken));
        vm.prank(deployer);
        token.mint(stranger, 1 ether);
        assertEq(token.balanceOf(stranger), 1 ether);
    }

    // ---------------------------------------------------------------------
    // Revert cases
    // ---------------------------------------------------------------------

    function test_deploy_revertsForNonDeployer() public {
        vm.expectRevert(bytes("TokenFactory: Not a deployer"));
        vm.prank(stranger);
        factory.deploy("Bridged Token", "BT", 18, 100, sourceToken);
    }

    function test_deploy_revertsForOwnerWhoIsNotDeployer() public {
        vm.expectRevert(bytes("TokenFactory: Not a deployer"));
        vm.prank(owner);
        factory.deploy("Bridged Token", "BT", 18, 100, sourceToken);
    }

    function test_deploy_revertsAfterDeployerRevoked() public {
        vm.prank(owner);
        factory.setDeployer(deployer, false);

        vm.expectRevert(bytes("TokenFactory: Not a deployer"));
        _deploy(sourceToken);
    }

    function test_deploy_revertsForSameSourceTokenTwice() public {
        _deploy(sourceToken);

        // CREATE2 collision: the address is taken, so create2 returns 0 and the factory reverts.
        vm.expectRevert();
        _deploy(sourceToken);
    }

    function test_proxy_initializeRevertsWhenCalledAgainByFactory() public {
        address proxy = _deploy(sourceToken);

        vm.expectRevert();
        vm.prank(address(factory));
        TokenProxy(payable(proxy)).initialize(tokenImage, "X", "X", 18, 100, stranger);
    }

    function test_proxy_initializeRevertsForNonFactory() public {
        address proxy = _deploy(sourceToken);

        vm.expectRevert();
        vm.prank(stranger);
        TokenProxy(payable(proxy)).initialize(tokenImage, "X", "X", 18, 100, stranger);
    }

    function test_setDeployer_revertsForNonOwner() public {
        vm.expectRevert();
        vm.prank(stranger);
        factory.setDeployer(stranger, true);
        assertTrue(!factory.isDeployer(stranger));
    }

    function test_setDeployer_ownerCanToggle() public {
        vm.startPrank(owner);
        factory.setDeployer(stranger, true);
        assertTrue(factory.isDeployer(stranger));
        factory.setDeployer(stranger, false);
        assertTrue(!factory.isDeployer(stranger));
        vm.stopPrank();
    }

    function test_setTokenImage_revertsForNonOwner() public {
        address newImage = deployTokenImage();
        vm.expectRevert();
        vm.prank(stranger);
        factory.setTokenImage(newImage);
    }

    function test_setTokenImage_revertsForNonContract() public {
        vm.expectRevert();
        vm.prank(owner);
        factory.setTokenImage(stranger);
    }
}
