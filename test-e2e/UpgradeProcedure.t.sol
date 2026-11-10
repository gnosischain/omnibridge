pragma solidity 0.7.5;
pragma abicoder v2;

import "./base/E2EBase.sol";

/**
 * @dev Runs the "Bridge upgrade procedure" of docs/deterministic-create2-token-deployment.md (steps 1 to 4) against
 * the production Omnibridge pair on Ethereum and Gnosis Chain, runs the post-upgrade checks, then bridges a new token
 * from each side and checks it lands at the predicted CREATE2 address.
 */
contract UpgradeProcedureE2ETest is E2EBase {
    // EIP-7997 deterministic deployment factory, same address on both chains.
    address internal constant EIP7997_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant TOKEN_FACTORY_SALT = bytes32(0);

    // Tokens already bridged before the upgrade, used to check the stored address still wins after it.
    address internal constant WETH_ETHEREUM = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // native on Ethereum
    address internal constant GNOSIS_NATIVE_TOKEN = 0x4d378f18b00E469187F2a5348e4e7eb2f4d08c0C; // native on Gnosis

    // Step 3: gas limit for deployAndHandleBridgedTokens(AndCall) messages from Gnosis to Ethereum.
    bytes4 internal constant DEPLOY_AND_HANDLE = 0x2ae87cdd;
    bytes4 internal constant DEPLOY_AND_HANDLE_AND_CALL = 0xd522cfd7;
    uint256 internal constant DEPLOY_GAS_LIMIT = 850000;

    uint256 internal constant SUPPLY = 1000 ether;
    uint256 internal constant VALUE = 1 ether;

    address internal factoryDeployer = makeAddr("factoryDeployer");

    TokenFactory internal foreignFactory;
    TokenFactory internal homeFactory;

    function setUp() public override {
        super.setUp();
        foreignMediator = ForeignOmnibridge(FOREIGN_OMNIBRIDGE);
        homeMediator = HomeOmnibridge(HOME_OMNIBRIDGE);
    }

    // ---------------------------------------------------------------------
    // Upgrade procedure
    // ---------------------------------------------------------------------

    /**
     * @dev Step 1, as script/DeployTokenFactory.s.sol: EIP-7997 deploy with (owner = deployer, image = 0),
     * then setTokenImage(existing image), setDeployer(mediator, true), transferOwnership(bridge owner).
     */
    function _step1_deployTokenFactory(uint256 _fork, BasicOmnibridge _mediator) internal returns (TokenFactory) {
        vm.selectFork(_fork);
        address image = _mediator.tokenFactory().tokenImage(); // reuse the chain's existing token image
        address bridgeOwner_ = _mediator.owner();

        bytes memory initCode =
            abi.encodePacked(type(TokenFactory).creationCode, abi.encode(factoryDeployer, address(0)));
        vm.prank(factoryDeployer);
        (bool ok, bytes memory ret) = EIP7997_FACTORY.call(abi.encodePacked(TOKEN_FACTORY_SALT, initCode));
        assertTrue(ok && ret.length == 20, "EIP-7997 deployment failed");
        address deployed;
        assembly {
            deployed := shr(96, mload(add(ret, 0x20)))
        }
        TokenFactory factory = TokenFactory(deployed);

        vm.startPrank(factoryDeployer);
        factory.setTokenImage(image);
        factory.setDeployer(address(_mediator), true);
        factory.transferOwnership(bridgeOwner_);
        vm.stopPrank();
        return factory;
    }

    // Step 2: new mediator implementation with the live name suffix.
    function _step2_deployImplementation(uint256 _fork, bool _isHome) internal returns (address) {
        vm.selectFork(_fork);
        return _isHome ? address(new HomeOmnibridge(HOME_SUFFIX)) : address(new ForeignOmnibridge(FOREIGN_SUFFIX));
    }

    // Step 3: raise the Gnosis gas limits for deploy messages to Ethereum.
    function _step3_raiseGasLimits() internal {
        vm.selectFork(homeFork);
        SelectorTokenGasLimitManager manager = SelectorTokenGasLimitManager(address(homeMediator.gasLimitManager()));
        vm.startPrank(manager.owner());
        manager.setRequestGasLimit(DEPLOY_AND_HANDLE, DEPLOY_GAS_LIMIT);
        manager.setRequestGasLimit(DEPLOY_AND_HANDLE_AND_CALL, DEPLOY_GAS_LIMIT);
        vm.stopPrank();
        assertEq(manager.requestGasLimit(DEPLOY_AND_HANDLE), DEPLOY_GAS_LIMIT);
        assertEq(manager.requestGasLimit(DEPLOY_AND_HANDLE_AND_CALL), DEPLOY_GAS_LIMIT);
    }

    // Step 4: upgradeTo by the upgradeability owner, then setTokenFactory by the bridge owner (one Safe batch).
    function _step4_upgradeAndSetFactory(
        uint256 _fork,
        BasicOmnibridge _mediator,
        address _implementation,
        TokenFactory _factory
    ) internal {
        vm.selectFork(_fork);
        EternalStorageProxy proxy = EternalStorageProxy(payable(address(_mediator)));
        uint256 newVersion = proxy.version() + 1;

        vm.prank(proxy.upgradeabilityOwner());
        proxy.upgradeTo(newVersion, _implementation);
        vm.prank(_mediator.owner());
        _mediator.setTokenFactory(address(_factory));

        assertEq(proxy.implementation(), _implementation);
        assertEq(proxy.version(), newVersion);
    }

    function _runProcedure(bool _withStep3) internal {
        foreignFactory = _step1_deployTokenFactory(foreignFork, foreignMediator);
        homeFactory = _step1_deployTokenFactory(homeFork, homeMediator);

        address foreignImpl = _step2_deployImplementation(foreignFork, false);
        address homeImpl = _step2_deployImplementation(homeFork, true);

        if (_withStep3) _step3_raiseGasLimits();

        _step4_upgradeAndSetFactory(foreignFork, foreignMediator, foreignImpl, foreignFactory);
        _step4_upgradeAndSetFactory(homeFork, homeMediator, homeImpl, homeFactory);

        _clearMessages();
    }

    // "Check after the upgrade" of the procedure.
    function _checkAfterUpgrade(
        uint256 _fork,
        BasicOmnibridge _mediator,
        TokenFactory _factory,
        address _alreadyBridgedNative,
        address _storedBridged
    ) internal {
        vm.selectFork(_fork);
        assertEq(address(_mediator.tokenFactory()), address(_factory));
        assertTrue(_factory.isDeployer(address(_mediator)));
        assertEq(_factory.owner(), _mediator.owner());
        assertTrue(_hasCode(_factory.tokenImage()));

        assertEq(_mediator.bridgedTokenAddressOrPredicted(_alreadyBridgedNative), _storedBridged);
        address neverBridged = makeAddr("neverBridged");
        assertEq(_mediator.bridgedTokenAddressOrPredicted(neverBridged), _factory.predictTokenProxyAddress(neverBridged));
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    // Fee the production fee manager on Gnosis takes for `_value` of `_token` (0 without a fee manager).
    function _homeFee(bool _homeToForeign, address _token, uint256 _value) internal returns (uint256) {
        vm.selectFork(homeFork);
        OmnibridgeFeeManager manager = homeMediator.feeManager();
        if (address(manager) == address(0)) return 0;
        bytes32 feeType = _homeToForeign ? manager.HOME_TO_FOREIGN_FEE() : manager.FOREIGN_TO_HOME_FEE();
        return manager.calculateFee(feeType, _token, _value);
    }

    // Gas limit field of an AMB message: messageId (32) ++ sender (20) ++ executor (20) ++ gasLimit (4) ++ ...
    function _messageGasLimit(bytes memory _message) internal pure returns (uint256 gasLimit) {
        assembly {
            gasLimit := shr(224, mload(add(_message, 104))) // 32 (length) + 32 + 20 + 20
        }
    }

    // Like _relayToForeign, also returning the gas limit the message carries.
    function _relayToForeignWithGas() internal returns (bool status, uint256 gasLimit) {
        (bytes32 messageId, bytes memory message) = _takeMessage(HOME_AMB, USER_REQUEST_FOR_SIGNATURE);
        gasLimit = _messageGasLimit(message);

        vm.selectFork(foreignFork);
        vm.prank(validator);
        IForeignAMB(FOREIGN_AMB).executeSignatures(message, _sign(message));
        status = IForeignAMB(FOREIGN_AMB).messageCallStatus(messageId);
    }

    // ---------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------

    function test_procedure_upgradesBothSides() public {
        vm.selectFork(foreignFork);
        address storedOnForeign = foreignMediator.bridgedTokenAddress(GNOSIS_NATIVE_TOKEN);
        vm.selectFork(homeFork);
        address storedOnHome = homeMediator.bridgedTokenAddress(WETH_ETHEREUM);
        assertTrue(storedOnForeign != address(0) && storedOnHome != address(0), "expected already bridged tokens");

        _runProcedure(true);

        // Same deployer + salt give the same factory address on both chains.
        assertEq(address(foreignFactory), address(homeFactory));

        _checkAfterUpgrade(foreignFork, foreignMediator, foreignFactory, GNOSIS_NATIVE_TOKEN, storedOnForeign);
        _checkAfterUpgrade(homeFork, homeMediator, homeFactory, WETH_ETHEREUM, storedOnHome);
    }

    function test_procedure_bridgeNewTokenFromEthereum() public {
        _runProcedure(true);

        vm.selectFork(foreignFork);
        E2EToken token = _deployToken(SUPPLY);
        vm.selectFork(homeFork);
        address predicted = homeMediator.bridgedTokenAddressOrPredicted(address(token));
        assertTrue(!_hasCode(predicted));

        // Ethereum -> Gnosis: first bridge deploys the token at the predicted address
        vm.selectFork(foreignFork);
        _relayTokens(foreignMediator, address(token), user, VALUE);
        (, bool status) = _relayToHome();
        assertTrue(status, "message failed on Gnosis");

        ERC20 bridged = ERC20(homeMediator.bridgedTokenAddress(address(token)));
        assertEq(address(bridged), predicted);
        assertEq(homeFactory.predictTokenProxyAddress(address(token)), predicted);
        assertEq(bridged.name(), "E2E Token on xDai");
        assertEq(bridged.symbol(), "E2E");
        assertEq(uint256(bridged.decimals()), 18);
        assertEq(homeMediator.nativeTokenAddress(address(bridged)), address(token));
        assertEq(IBridgedToken(address(bridged)).owner(), address(homeMediator));
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

    function test_procedure_bridgeNewTokenFromGnosis() public {
        _runProcedure(true);

        vm.selectFork(homeFork);
        E2EToken token = _deployToken(SUPPLY);
        vm.selectFork(foreignFork);
        address predicted = foreignMediator.bridgedTokenAddressOrPredicted(address(token));
        assertTrue(!_hasCode(predicted));

        // Gnosis -> Ethereum: first bridge deploys the token at the predicted address, with the step 3 gas limit
        vm.selectFork(homeFork);
        _relayTokens(homeMediator, address(token), user, VALUE);
        uint256 sent = VALUE - _homeFee(true, address(token), VALUE);
        (bool status, uint256 gasLimit) = _relayToForeignWithGas();
        assertEq(gasLimit, DEPLOY_GAS_LIMIT);
        assertTrue(status, "message failed on Ethereum");

        ERC20 bridged = ERC20(foreignMediator.bridgedTokenAddress(address(token)));
        assertEq(address(bridged), predicted);
        assertEq(foreignFactory.predictTokenProxyAddress(address(token)), predicted);
        assertEq(bridged.name(), "E2E Token on Mainnet");
        assertEq(bridged.symbol(), "E2E");
        assertEq(uint256(bridged.decimals()), 18);
        assertEq(foreignMediator.nativeTokenAddress(address(bridged)), address(token));
        assertEq(IBridgedToken(address(bridged)).owner(), address(foreignMediator));
        assertEq(bridged.balanceOf(user), sent);

        // Ethereum -> Gnosis: bridge everything back
        _relayTokens(foreignMediator, address(bridged), user, sent);
        (, bool backStatus) = _relayToHome();
        assertTrue(backStatus, "message failed on Gnosis");

        uint256 returned = sent - _homeFee(false, address(token), sent);
        assertEq(token.balanceOf(user), SUPPLY - VALUE + returned);
    }

    // Without step 3, Gnosis -> Ethereum deploy messages keep the old limit and run out of gas on Ethereum.
    function test_procedure_withoutStep3_gnosisToEthereumDeployFails() public {
        _runProcedure(false);

        vm.selectFork(homeFork);
        E2EToken token = _deployToken(SUPPLY);
        _relayTokens(homeMediator, address(token), user, VALUE);
        (bool status, uint256 gasLimit) = _relayToForeignWithGas();

        assertLt(gasLimit, DEPLOY_GAS_LIMIT);
        assertTrue(!status, "expected the deploy message to fail");
        assertEq(foreignMediator.bridgedTokenAddress(address(token)), address(0));
    }
}
