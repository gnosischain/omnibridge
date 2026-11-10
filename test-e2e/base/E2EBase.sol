pragma solidity 0.7.5;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../test-foundry/utils/TestHelpers.sol";
import "../../contracts/upgradeability/EternalStorageProxy.sol";
import "../../contracts/upgradeable_contracts/HomeOmnibridge.sol";
import "../../contracts/upgradeable_contracts/ForeignOmnibridge.sol";

interface IBridgeValidators {
    function owner() external view returns (address);

    function addValidator(address _validator) external;

    function setRequiredSignatures(uint256 _requiredSignatures) external;

    function isValidator(address _validator) external view returns (bool);

    function requiredSignatures() external view returns (uint256);
}

interface IProductionAMB {
    function validatorContract() external view returns (address);

    function messageCallStatus(bytes32 _messageId) external view returns (bool);
}

// AMB on Ethereum (foreign side)
interface IForeignAMB is IProductionAMB {
    function executeSignatures(bytes calldata _data, bytes calldata _signatures) external;
}

// AMB on Gnosis Chain (home side)
interface IHomeAMB is IProductionAMB {
    function executeAffirmation(bytes calldata _message) external;
}

/**
 * @dev Plain mintable ERC20 used as the native token in the scenarios.
 */
contract E2EToken is ERC20 {
    constructor(string memory _name, string memory _symbol, uint8 _decimals) ERC20(_name, _symbol) {
        _setupDecimals(_decimals);
    }

    function mint(address _to, uint256 _value) external {
        _mint(_to, _value);
    }
}

/**
 * @dev Base for the e2e fork tests (see README.md).
 *
 * Forks Ethereum (FOREIGN_RPC_URL) and Gnosis Chain (HOME_RPC_URL) in the same test. In CI both URLs point to
 * fresh Tenderly Virtual TestNets. The production AMB contracts are used as they are; a mock validator is added
 * to each AMB validator contract with the signature threshold set to 1, so the test itself can carry messages
 * between the chains in place of the off-chain oracle:
 *   Ethereum -> Gnosis: UserRequestForAffirmation on the foreign AMB, then executeAffirmation on the home AMB.
 *   Gnosis -> Ethereum: UserRequestForSignature on the home AMB, then executeSignatures on the foreign AMB.
 */
abstract contract E2EBase is TestHelpers {
    address internal constant FOREIGN_AMB = 0x4C36d2919e407f0Cc2Ee3c993ccF8ac26d9CE64e;
    address internal constant HOME_AMB = 0x75Df5AF045d91108662D8080fD1FEFAd6aA0bb59;
    address internal constant FOREIGN_OMNIBRIDGE = 0x88ad09518695c6c3712AC10a214bE5109a655671;
    address internal constant HOME_OMNIBRIDGE = 0xf6A78083ca3e2a662D6dd1703c939c8aCE2e268d;

    bytes32 internal constant USER_REQUEST_FOR_AFFIRMATION = keccak256("UserRequestForAffirmation(bytes32,bytes)");
    bytes32 internal constant USER_REQUEST_FOR_SIGNATURE = keccak256("UserRequestForSignature(bytes32,bytes)");

    string internal constant HOME_SUFFIX = " on xDai";
    string internal constant FOREIGN_SUFFIX = " on Mainnet";

    // Limits for newly deployed mediators: [dailyLimit, maxPerTx, minPerTx] and [executionDailyLimit, executionMaxPerTx]
    uint256 internal constant DAILY_LIMIT = 1000 ether;
    uint256 internal constant MAX_PER_TX = 100 ether;
    uint256 internal constant MIN_PER_TX = 0.01 ether;
    // must not exceed maxGasPerTx of the foreign AMB (4M) and fits the home AMB (2M)
    uint256 internal constant FOREIGN_REQUEST_GAS_LIMIT = 2000000;

    uint256 internal foreignFork;
    uint256 internal homeFork;

    address internal validator;
    uint256 internal validatorKey;

    address internal user = makeAddr("user");
    address internal bridgeOwner = makeAddr("bridgeOwner");

    ForeignOmnibridge internal foreignMediator;
    HomeOmnibridge internal homeMediator;

    function setUp() public virtual {
        foreignFork = vm.createFork(vm.envString("FOREIGN_RPC_URL"));
        homeFork = vm.createFork(vm.envString("HOME_RPC_URL"));
        assertEq(_chainIdOn(foreignFork), 1, "FOREIGN_RPC_URL must be Ethereum (chain id 1)");
        assertEq(_chainIdOn(homeFork), 100, "HOME_RPC_URL must be Gnosis Chain (chain id 100)");

        (validator, validatorKey) = makeAddrAndKey("mockValidator");
        _addMockValidator(foreignFork, FOREIGN_AMB);
        _addMockValidator(homeFork, HOME_AMB);

        vm.recordLogs();
    }

    // ---------------------------------------------------------------------
    // Setup helpers
    // ---------------------------------------------------------------------

    function _chainIdOn(uint256 _fork) internal returns (uint256 id) {
        vm.selectFork(_fork);
        assembly {
            id := chainid()
        }
    }

    // Adds the mock validator and sets the threshold to 1 by acting as the validator contract owner.
    function _addMockValidator(uint256 _fork, address _amb) internal {
        vm.selectFork(_fork);
        IBridgeValidators validators = IBridgeValidators(IProductionAMB(_amb).validatorContract());
        vm.startPrank(validators.owner());
        validators.addValidator(validator);
        validators.setRequiredSignatures(1);
        vm.stopPrank();
        assertTrue(validators.isValidator(validator));
        assertEq(validators.requiredSignatures(), 1);
    }

    /**
     * @dev Deploys a new Omnibridge pair on top of the production AMBs, the same way script/DeployOmnibridge.s.sol
     * does: EternalStorageProxy + implementation, a TokenFactory, then initialize, then allow the mediator to deploy
     * tokens through the factory (setDeployer).
     * No fee, gas limit or forwarding rules managers on the home side.
     */
    function _deployMediators() internal {
        vm.selectFork(foreignFork);
        EternalStorageProxy foreignProxy = new EternalStorageProxy();
        vm.selectFork(homeFork);
        EternalStorageProxy homeProxy = new EternalStorageProxy();

        vm.selectFork(foreignFork);
        foreignProxy.upgradeTo(1, address(new ForeignOmnibridge(FOREIGN_SUFFIX)));
        foreignMediator = ForeignOmnibridge(address(foreignProxy));
        TokenFactory foreignFactory = _deployTokenFactory();
        foreignMediator.initialize(
            FOREIGN_AMB,
            address(homeProxy),
            [DAILY_LIMIT, MAX_PER_TX, MIN_PER_TX],
            [DAILY_LIMIT, MAX_PER_TX],
            FOREIGN_REQUEST_GAS_LIMIT,
            bridgeOwner,
            address(foreignFactory)
        );
        vm.prank(bridgeOwner); // factory owner
        foreignFactory.setDeployer(address(foreignMediator), true);

        vm.selectFork(homeFork);
        homeProxy.upgradeTo(1, address(new HomeOmnibridge(HOME_SUFFIX)));
        homeMediator = HomeOmnibridge(address(homeProxy));
        TokenFactory homeFactory = _deployTokenFactory();
        homeMediator.initialize(
            HOME_AMB,
            address(foreignProxy),
            [DAILY_LIMIT, MAX_PER_TX, MIN_PER_TX],
            [DAILY_LIMIT, MAX_PER_TX],
            address(0), // gas limit manager: use the AMB maxGasPerTx
            bridgeOwner,
            address(homeFactory),
            address(0), // fee manager
            address(0) // forwarding rules manager
        );
        vm.prank(bridgeOwner); // factory owner
        homeFactory.setDeployer(address(homeMediator), true);
    }

    // TokenFactory on the selected fork.
    function _deployTokenFactory() internal returns (TokenFactory) {
        return new TokenFactory(bridgeOwner, deployTokenImage());
    }

    // Native test token on the selected fork, with `_amount` minted to `user`.
    function _deployToken(uint256 _amount) internal returns (E2EToken token) {
        token = new E2EToken("E2E Token", "E2E", 18);
        token.mint(user, _amount);
    }

    // ---------------------------------------------------------------------
    // Bridging helpers
    // ---------------------------------------------------------------------

    // approve + relayTokens(token, receiver, value) from `user` on the selected fork.
    function _relayTokens(BasicOmnibridge _mediator, address _token, address _receiver, uint256 _value) internal {
        vm.prank(user);
        IERC20(_token).approve(address(_mediator), _value);
        vm.prank(user);
        _mediator.relayTokens(IERC677(_token), _receiver, _value);
    }

    // approve + relayTokensAndCall(token, receiver, value, data) from `user` on the selected fork.
    function _relayTokensAndCall(
        BasicOmnibridge _mediator,
        address _token,
        address _receiver,
        uint256 _value,
        bytes memory _data
    ) internal {
        vm.prank(user);
        IERC20(_token).approve(address(_mediator), _value);
        vm.prank(user);
        _mediator.relayTokensAndCall(IERC677(_token), _receiver, _value, _data);
    }

    // Drops the logs recorded so far, so the next relay only sees messages sent after this call.
    function _clearMessages() internal {
        vm.getRecordedLogs();
    }

    /**
     * @dev Delivers the one message sent through the foreign AMB since the last relay to the home AMB.
     * Leaves the home fork selected. Returns the message id and whether the call on the home side succeeded.
     */
    function _relayToHome() internal returns (bytes32 messageId, bool status) {
        bytes memory message;
        (messageId, message) = _takeMessage(FOREIGN_AMB, USER_REQUEST_FOR_AFFIRMATION);

        vm.selectFork(homeFork);
        vm.prank(validator);
        IHomeAMB(HOME_AMB).executeAffirmation(message);
        status = IHomeAMB(HOME_AMB).messageCallStatus(messageId);
    }

    /**
     * @dev Delivers the one message sent through the home AMB since the last relay to the foreign AMB,
     * signed by the mock validator. Leaves the foreign fork selected.
     */
    function _relayToForeign() internal returns (bytes32 messageId, bool status) {
        bytes memory message;
        (messageId, message) = _takeMessage(HOME_AMB, USER_REQUEST_FOR_SIGNATURE);

        vm.selectFork(foreignFork);
        vm.prank(validator);
        IForeignAMB(FOREIGN_AMB).executeSignatures(message, _sign(message));
        status = IForeignAMB(FOREIGN_AMB).messageCallStatus(messageId);
    }

    // Finds exactly one AMB request event among the logs recorded since the last call, and clears them.
    function _takeMessage(address _amb, bytes32 _event) internal returns (bytes32 messageId, bytes memory message) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == _amb && logs[i].topics.length > 0 && logs[i].topics[0] == _event) {
                messageId = logs[i].topics[1];
                message = abi.decode(logs[i].data, (bytes));
                found++;
            }
        }
        assertEq(found, 1, "expected exactly one AMB message");
    }

    // Signatures in the AMB format: [count][v...][r...][s...], over the eth_sign hash of the message.
    function _sign(bytes memory _message) internal view returns (bytes memory) {
        bytes32 hash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n", _uintToString(_message.length), _message)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validatorKey, hash);
        return abi.encodePacked(uint8(1), v, r, s);
    }

    function _uintToString(uint256 _value) internal pure returns (string memory) {
        if (_value == 0) return "0";
        uint256 digits;
        for (uint256 tmp = _value; tmp != 0; tmp /= 10) digits++;
        bytes memory buffer = new bytes(digits);
        while (_value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + (_value % 10)));
            _value /= 10;
        }
        return string(buffer);
    }

    function _hasCode(address _addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }
}
