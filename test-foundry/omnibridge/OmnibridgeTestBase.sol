pragma solidity 0.7.5;
pragma abicoder v2;

import "../utils/TestHelpers.sol";
import "../../contracts/upgradeability/EternalStorageProxy.sol";
import "../../contracts/upgradeable_contracts/HomeOmnibridge.sol";
import "../../contracts/upgradeable_contracts/ForeignOmnibridge.sol";
import "../../contracts/upgradeable_contracts/Sacrifice.sol";
import "../../contracts/mocks/AMBMock.sol";
import "../../contracts/mocks/TokenReceiver.sol";

/**
 * @dev Interface of the precompiled ERC677BridgeToken / PermittableToken (solc 0.4.24) used in the tests.
 */
interface ITestToken {
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);

    function balanceOf(address) external view returns (uint256);

    function owner() external view returns (address);

    function mint(address, uint256) external returns (bool);

    function transfer(address, uint256) external returns (bool);

    function approve(address, uint256) external returns (bool);

    function transferAndCall(address, uint256, bytes calldata) external returns (bool);

    function transferOwnership(address) external;
}

/**
 * @dev Shared setup and helpers for the Foundry port of test/omnibridge/common.test.js.
 * Mirrors the JS fixtures: a fresh mediator, AMBMock, ERC677 token and TokenReceiver for every test,
 * a TokenFactory backed by the precompiled PermittableToken image, and the same accounts and constants.
 */
abstract contract OmnibridgeTestBase is TestHelpers {
    struct InitArgs {
        address ambContract;
        address otherSideMediator;
        uint256[3] limits;
        uint256[2] executionLimits;
        address gasLimitManager; // home only
        uint256 requestGasLimit; // foreign only
        address owner;
        address tokenFactory;
        address feeManager; // home only
        address forwardingRulesManager; // home only
    }

    struct RecordedLog {
        address emitter;
        bytes32[] topics;
        bytes data;
    }

    struct AmbMessage {
        bytes32 messageId;
        address executor;
        uint8 dataType;
        bytes data;
        uint256 gas;
    }

    // TokensBridgingInitiated(token, sender, value, messageId) and TokensBridged(token, recipient, value, messageId)
    struct TokenEvent {
        address token;
        address account;
        uint256 value;
        bytes32 messageId;
    }

    struct DeployCall {
        address token;
        string name;
        string symbol;
        uint8 decimals;
        address receiver;
        uint256 value;
        bytes data;
    }

    struct HandleCall {
        address token;
        address receiver;
        uint256 value;
        bytes data;
    }

    string internal constant SUFFIX = " on Testnet";

    uint256 internal constant ONE = 1 ether;
    uint256 internal constant HALF = 0.5 ether;
    uint256 internal constant TWO = 2 ether;
    uint256 internal constant DAILY_LIMIT = 2.5 ether;
    uint256 internal constant MAX_PER_TX = ONE;
    uint256 internal constant MIN_PER_TX = 0.01 ether;
    uint256 internal constant EXECUTION_DAILY_LIMIT = DAILY_LIMIT;
    uint256 internal constant EXECUTION_MAX_PER_TX = MAX_PER_TX;

    bytes32 internal constant EXAMPLE_MESSAGE_ID = 0xf308b922ab9f8a7128d9d7bc9bce22cd88b2c05c8213f0e2d8104d78e0a9ecbb;
    bytes32 internal constant OTHER_MESSAGE_ID = 0x35d3818e50234655f6aebb2a1cfbf30f59568d8a4ec72066fac5a25dbe7b8121;
    bytes32 internal constant OTHER_MESSAGE_ID_2 = 0x9f5102f0a927f5ddd371db9938354105719c4a36d083acea27ab535c1c7849c6;
    bytes32 internal constant FAILED_MESSAGE_ID = 0x2ebc2ccc755acc8eaf9252e19573af708d644ab63a39619adb080a3500a4ff2e;

    bytes4 internal constant DEPLOY_AND_HANDLE_BRIDGED_TOKENS = 0x2ae87cdd;
    bytes4 internal constant DEPLOY_AND_HANDLE_BRIDGED_TOKENS_AND_CALL = 0xd522cfd7;
    bytes4 internal constant HANDLE_BRIDGED_TOKENS = 0x125e4cfb;
    bytes4 internal constant HANDLE_BRIDGED_TOKENS_AND_CALL = 0xc5345761;
    bytes4 internal constant HANDLE_NATIVE_TOKENS = 0x272255bb;
    bytes4 internal constant HANDLE_NATIVE_TOKENS_AND_CALL = 0x867f7a4d;
    bytes4 internal constant FIX_FAILED_MESSAGE = 0x0950d515;

    bytes32 internal constant MOCKED_EVENT = keccak256("MockedEvent(bytes32,address,uint8,bytes,uint256)");
    bytes32 internal constant TOKENS_BRIDGING_INITIATED = keccak256("TokensBridgingInitiated(address,address,uint256,bytes32)");
    bytes32 internal constant TOKENS_BRIDGED = keccak256("TokensBridged(address,address,uint256,bytes32)");
    bytes32 internal constant NEW_TOKEN_REGISTERED = keccak256("NewTokenRegistered(address,address)");
    bytes32 internal constant FAILED_MESSAGE_FIXED = keccak256("FailedMessageFixed(bytes32,address,address,uint256)");
    bytes32 internal constant FEE_DISTRIBUTED = keccak256("FeeDistributed(uint256,address,bytes32)");
    bytes32 internal constant FEE_UPDATED = keccak256("FeeUpdated(bytes32,address,uint256)");
    bytes32 internal constant DAILY_LIMIT_CHANGED = keccak256("DailyLimitChanged(address,uint256)");
    bytes32 internal constant EXECUTION_DAILY_LIMIT_CHANGED = keccak256("ExecutionDailyLimitChanged(address,uint256)");

    // accounts[0], accounts[1], accounts[2], accounts[3] in the JS tests
    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");
    address internal user2 = makeAddr("user2");
    address internal claimReceiver = makeAddr("claimReceiver");

    address internal constant otherSideMediator = 0x1e33FBB006F47F78704c954555a5c52C2A7f409D;
    address internal constant otherSideToken1 = 0xAfb77d544aFc1e2aD3dEEAa20F3c80859E7Fc3C9;
    address internal constant otherSideToken2 = 0x876bD892b01D1c9696D873f74cbeF8fc9Bfb1142;

    BasicOmnibridge internal mediator;
    AMBMock internal amb;
    TokenFactory internal tokenFactory;
    address internal tokenImage;
    ITestToken internal token;
    TokenReceiver internal tokenReceiver;
    uint256 internal currentDay;

    RecordedLog[] internal recordedLogs;

    uint256 internal constant SEND_FUNCTIONS = 8;

    function _isHome() internal pure virtual returns (bool);

    function _deployMediator() internal virtual returns (address);

    // before() + beforeEach() of the JS suite. Also called inside loops to get a fresh state per iteration,
    // the same way every `it` gets a fresh beforeEach in mocha.
    function setUp() public virtual {
        vm.recordLogs();
        vm.getRecordedLogs();
        delete recordedLogs;

        tokenImage = _deployPermittableToken("TEST", "TST", 18);
        tokenFactory = new TokenFactory(owner, tokenImage);

        mediator = BasicOmnibridge(_deployMediator());
        amb = new AMBMock();
        token = _deployERC677Token("TEST", "TST", 18);
        currentDay = mediator.getCurrentDay();
        tokenReceiver = new TokenReceiver();
    }

    // ---------------------------------------------------------------------
    // Deployment helpers
    // ---------------------------------------------------------------------

    function _deployPrecompiled(string memory _name, bytes memory _args) internal returns (address addr) {
        string memory json = vm.readFile(string(abi.encodePacked("precompiled/", _name, ".json")));
        bytes memory code = abi.encodePacked(vm.parseJsonBytes(json, ".bytecode"), _args);
        vm.prank(owner);
        assembly {
            addr := create(0, add(code, 0x20), mload(code))
        }
        require(addr != address(0), "precompiled deployment failed");
    }

    function _deployERC677Token(string memory _name, string memory _symbol, uint8 _decimals)
        internal
        returns (ITestToken)
    {
        return ITestToken(_deployPrecompiled("ERC677BridgeToken", abi.encode(_name, _symbol, _decimals)));
    }

    function _deployPermittableToken(string memory _name, string memory _symbol, uint8 _decimals)
        internal
        returns (address)
    {
        return _deployPrecompiled("PermittableToken", abi.encode(_name, _symbol, _decimals, uint256(1337)));
    }

    // Puts the current mediator implementation behind an EternalStorageProxy owned by `owner`.
    function _useProxy() internal {
        vm.prank(owner);
        EternalStorageProxy proxy = new EternalStorageProxy();
        vm.prank(owner);
        proxy.upgradeTo(1, address(mediator));
        mediator = BasicOmnibridge(address(proxy));
    }

    function _defaultInitArgs() internal view returns (InitArgs memory a) {
        a.ambContract = address(amb);
        a.otherSideMediator = otherSideMediator;
        a.limits = [DAILY_LIMIT, MAX_PER_TX, MIN_PER_TX];
        a.executionLimits = [EXECUTION_DAILY_LIMIT, EXECUTION_MAX_PER_TX];
        a.gasLimitManager = address(0);
        a.requestGasLimit = 1000000;
        a.owner = owner;
        a.tokenFactory = address(tokenFactory);
        a.feeManager = address(0);
        a.forwardingRulesManager = address(0);
    }

    function _initialize() internal {
        _initialize(_defaultInitArgs());
    }

    function _initialize(InitArgs memory a) internal {
        if (_isHome()) {
            vm.prank(owner);
            HomeOmnibridge(address(mediator)).initialize(
                a.ambContract,
                a.otherSideMediator,
                a.limits,
                a.executionLimits,
                a.gasLimitManager,
                a.owner,
                a.tokenFactory,
                a.feeManager,
                a.forwardingRulesManager
            );
        } else {
            vm.prank(owner);
            ForeignOmnibridge(address(mediator)).initialize(
                a.ambContract,
                a.otherSideMediator,
                a.limits,
                a.executionLimits,
                a.requestGasLimit,
                a.owner,
                a.tokenFactory
            );
        }
    }

    // beforeEach of describe('afterInitialization')
    function _afterInit() internal {
        vm.prank(owner);
        token.mint(user, 10 ether);

        _initialize();

        assertEq(_ambMessages().length, 0);
    }

    // ---------------------------------------------------------------------
    // AMB message helpers
    // ---------------------------------------------------------------------

    function _exec(bytes32 _messageId, bytes memory _data) internal returns (bool) {
        return _exec(_messageId, _data, address(mediator), otherSideMediator, 1000000);
    }

    function _execFrom(bytes32 _messageId, bytes memory _data, address _sender) internal returns (bool) {
        return _exec(_messageId, _data, address(mediator), _sender, 1000000);
    }

    function _exec(bytes32 _messageId, bytes memory _data, address _executor, address _sender, uint256 _gas)
        internal
        returns (bool)
    {
        amb.executeMessageCall(_executor, _sender, _data, _messageId, _gas);
        return amb.messageCallStatus(_messageId);
    }

    function _deployData(
        address _token,
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _receiver,
        uint256 _value
    ) internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(
                mediator.deployAndHandleBridgedTokens.selector,
                _token,
                _name,
                _symbol,
                _decimals,
                _receiver,
                _value
            );
    }

    function _deployData(address _receiver, uint256 _value) internal view returns (bytes memory) {
        return _deployData(otherSideToken1, "Test", "TST", 18, _receiver, _value);
    }

    function _deployAndCallData(address _receiver, uint256 _value, bytes memory _data)
        internal
        view
        returns (bytes memory)
    {
        return
            abi.encodeWithSelector(
                mediator.deployAndHandleBridgedTokensAndCall.selector,
                otherSideToken1,
                "Test",
                "TST",
                uint8(18),
                _receiver,
                _value,
                _data
            );
    }

    function _handleBridgedData(address _token, address _receiver, uint256 _value)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSelector(mediator.handleBridgedTokens.selector, _token, _receiver, _value);
    }

    function _handleBridgedAndCallData(address _token, address _receiver, uint256 _value, bytes memory _data)
        internal
        view
        returns (bytes memory)
    {
        return
            abi.encodeWithSelector(mediator.handleBridgedTokensAndCall.selector, _token, _receiver, _value, _data);
    }

    function _handleNativeData(address _token, address _receiver, uint256 _value)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSelector(mediator.handleNativeTokens.selector, _token, _receiver, _value);
    }

    function _handleNativeAndCallData(address _token, address _receiver, uint256 _value, bytes memory _data)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSelector(mediator.handleNativeTokensAndCall.selector, _token, _receiver, _value, _data);
    }

    function _fixData(bytes32 _messageId) internal view returns (bytes memory) {
        return abi.encodeWithSelector(mediator.fixFailedMessage.selector, _messageId);
    }

    // Deploys the bridged token for otherSideToken1 through a message and returns its address.
    function _deployBridgedToken(address _receiver, uint256 _value) internal returns (ITestToken) {
        assertTrue(_exec(EXAMPLE_MESSAGE_ID, _deployData(_receiver, _value)));
        return ITestToken(mediator.bridgedTokenAddress(otherSideToken1));
    }

    // ---------------------------------------------------------------------
    // Send functions (sendFunctions in the JS tests)
    // ---------------------------------------------------------------------

    function _sendName(uint256 _kind) internal pure returns (string memory) {
        if (_kind == 0) return "emptyAlternativeReceiver";
        if (_kind == 1) return "sameAlternativeReceiver";
        if (_kind == 2) return "differentAlternativeReceiver";
        if (_kind == 3) return "simpleRelayTokens1";
        if (_kind == 4) return "simpleRelayTokens2";
        if (_kind == 5) return "relayTokensWithAlternativeReceiver";
        if (_kind == 6) return "alternativeReceiverWithData";
        return "relayTokensWithData";
    }

    function _send(uint256 _kind) internal returns (address) {
        return _send(_kind, ONE, false);
    }

    function _send(uint256 _kind, uint256 _value) internal returns (address) {
        return _send(_kind, _value, false);
    }

    function _sendReverts(uint256 _kind, uint256 _value) internal {
        _send(_kind, _value, true);
    }

    function _send(uint256 _kind, uint256 _value, bool _expectRevert) internal returns (address) {
        bool usesRelayTokens = _kind == 3 || _kind == 4 || _kind == 5 || _kind == 7;
        if (usesRelayTokens) {
            vm.prank(user);
            token.approve(address(mediator), _value);
        }
        if (_expectRevert) {
            vm.expectRevert();
        }
        vm.prank(user);
        if (_kind == 0) {
            token.transferAndCall(address(mediator), _value, "");
            return user;
        }
        if (_kind == 1) {
            token.transferAndCall(address(mediator), _value, abi.encodePacked(user));
            return user;
        }
        if (_kind == 2) {
            token.transferAndCall(address(mediator), _value, abi.encodePacked(user2));
            return user2;
        }
        if (_kind == 3) {
            mediator.relayTokens(IERC677(address(token)), _value);
            return user;
        }
        if (_kind == 4) {
            mediator.relayTokens(IERC677(address(token)), user, _value);
            return user;
        }
        if (_kind == 5) {
            mediator.relayTokens(IERC677(address(token)), user2, _value);
            return user2;
        }
        if (_kind == 6) {
            token.transferAndCall(address(mediator), _value, abi.encodePacked(address(tokenReceiver), hex"1122"));
            return address(tokenReceiver);
        }
        mediator.relayTokensAndCall(IERC677(address(token)), address(tokenReceiver), _value, hex"1122");
        return address(tokenReceiver);
    }

    // ---------------------------------------------------------------------
    // Event helpers (getEvents in the JS tests)
    // ---------------------------------------------------------------------

    function _flushLogs() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            recordedLogs.push();
            RecordedLog storage l = recordedLogs[recordedLogs.length - 1];
            l.emitter = logs[i].emitter;
            l.topics = logs[i].topics;
            l.data = logs[i].data;
        }
    }

    function _clearLogs() internal {
        vm.getRecordedLogs();
        delete recordedLogs;
    }

    function _events(address _emitter, bytes32 _sig) internal returns (RecordedLog[] memory out) {
        _flushLogs();
        uint256 n;
        for (uint256 i = 0; i < recordedLogs.length; i++) {
            if (_matches(i, _emitter, _sig)) n++;
        }
        out = new RecordedLog[](n);
        n = 0;
        for (uint256 i = 0; i < recordedLogs.length; i++) {
            if (_matches(i, _emitter, _sig)) out[n++] = recordedLogs[i];
        }
    }

    function _matches(uint256 _i, address _emitter, bytes32 _sig) private view returns (bool) {
        RecordedLog storage l = recordedLogs[_i];
        return l.emitter == _emitter && l.topics.length > 0 && l.topics[0] == _sig;
    }

    function _ambMessages() internal returns (AmbMessage[] memory msgs) {
        RecordedLog[] memory logs = _events(address(amb), MOCKED_EVENT);
        msgs = new AmbMessage[](logs.length);
        for (uint256 i = 0; i < logs.length; i++) {
            msgs[i].messageId = logs[i].topics[1];
            (msgs[i].executor, msgs[i].dataType, msgs[i].data, msgs[i].gas) = abi.decode(
                logs[i].data,
                (address, uint8, bytes, uint256)
            );
        }
    }

    function _tokenEvents(bytes32 _sig) internal returns (TokenEvent[] memory evs) {
        RecordedLog[] memory logs = _events(address(mediator), _sig);
        evs = new TokenEvent[](logs.length);
        for (uint256 i = 0; i < logs.length; i++) {
            evs[i].token = _topicAddress(logs[i].topics[1]);
            evs[i].account = _topicAddress(logs[i].topics[2]);
            evs[i].messageId = logs[i].topics[3];
            evs[i].value = abi.decode(logs[i].data, (uint256));
        }
    }

    function _countEvents(address _emitter, bytes32 _sig) internal returns (uint256) {
        return _events(_emitter, _sig).length;
    }

    function _topicAddress(bytes32 _topic) internal pure returns (address) {
        return address(uint160(uint256(_topic)));
    }

    // ---------------------------------------------------------------------
    // Calldata helpers
    // ---------------------------------------------------------------------

    function _selectorOf(bytes memory _data) internal pure returns (bytes4 sel) {
        assembly {
            sel := mload(add(_data, 32))
        }
    }

    function _argsOf(bytes memory _data) internal pure returns (bytes memory args) {
        args = new bytes(_data.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = _data[i + 4];
        }
    }

    function _decodeDeploy(bytes memory _data, bool _withData) internal pure returns (DeployCall memory c) {
        bytes memory args = _argsOf(_data);
        if (_withData) {
            (c.token, c.name, c.symbol, c.decimals, c.receiver, c.value, c.data) = abi.decode(
                args,
                (address, string, string, uint8, address, uint256, bytes)
            );
        } else {
            (c.token, c.name, c.symbol, c.decimals, c.receiver, c.value) = abi.decode(
                args,
                (address, string, string, uint8, address, uint256)
            );
        }
    }

    function _decodeHandle(bytes memory _data, bool _withData) internal pure returns (HandleCall memory c) {
        bytes memory args = _argsOf(_data);
        if (_withData) {
            (c.token, c.receiver, c.value, c.data) = abi.decode(args, (address, address, uint256, bytes));
        } else {
            (c.token, c.receiver, c.value) = abi.decode(args, (address, address, uint256));
        }
    }

    // ---------------------------------------------------------------------
    // Assertion helpers
    // ---------------------------------------------------------------------

    // Checks a deployAndHandleBridgedTokens(AndCall) message for the current native `token`.
    function _assertDeployMessage(AmbMessage memory _msg, address _receiver, uint256 _value) internal {
        bool withData = _receiver == address(tokenReceiver);
        assertEq(_msg.executor, otherSideMediator);
        assertEq(uint256(_msg.dataType), 0);
        assertEq(
            _selectorOf(_msg.data),
            withData ? DEPLOY_AND_HANDLE_BRIDGED_TOKENS_AND_CALL : DEPLOY_AND_HANDLE_BRIDGED_TOKENS
        );

        DeployCall memory c = _decodeDeploy(_msg.data, withData);
        assertEq(c.token, address(token));
        assertEq(c.name, token.name());
        assertEq(c.symbol, token.symbol());
        assertEq(uint256(c.decimals), uint256(token.decimals()));
        assertEq(c.receiver, _receiver);
        assertEq(c.value, _value);
        if (withData) {
            assertEq(c.data, hex"1122");
        }
    }

    // Checks a handle*Tokens(AndCall) message. The AndCall variant is expected when `_withData` is set.
    function _assertHandleMessage(
        AmbMessage memory _msg,
        bytes4 _selector,
        bytes4 _selectorWithData,
        bool _withData,
        address _token,
        address _receiver,
        uint256 _value
    ) internal {
        assertEq(_msg.executor, otherSideMediator);
        assertEq(uint256(_msg.dataType), 0);
        assertEq(_selectorOf(_msg.data), _withData ? _selectorWithData : _selector);

        HandleCall memory c = _decodeHandle(_msg.data, _withData);
        assertEq(c.token, _token);
        assertEq(c.receiver, _receiver);
        assertEq(c.value, _value);
        if (_withData) {
            assertEq(c.data, hex"1122");
        }
    }

    function _assertInitiated(TokenEvent memory _ev, address _token, address _sender, uint256 _value) internal {
        assertEq(_ev.token, _token);
        assertEq(_ev.account, _sender);
        assertEq(_ev.value, _value);
        // AMBMock message ids start with 0x11223344
        assertEq(bytes4(_ev.messageId), bytes4(0x11223344));
    }

    function _assertBridged(
        TokenEvent memory _ev,
        address _token,
        address _recipient,
        uint256 _value,
        bytes32 _messageId
    ) internal {
        assertEq(_ev.token, _token);
        assertEq(_ev.account, _recipient);
        assertEq(_ev.value, _value);
        assertEq(_ev.messageId, _messageId);
    }

    function _assertFailedMessageFixed(
        RecordedLog memory _log,
        bytes32 _messageId,
        address _token,
        address _recipient,
        uint256 _value
    ) internal {
        assertEq(_log.topics[1], _messageId);
        (address t, address r, uint256 v) = abi.decode(_log.data, (address, address, uint256));
        assertEq(t, _token);
        assertEq(r, _recipient);
        assertEq(v, _value);
    }

    // value.mul(10 ** decimals).div(10 ** 18)
    function _scale(uint256 _value, uint8 _decimals) internal pure returns (uint256) {
        return (_value * (uint256(10)**_decimals)) / 1 ether;
    }
}
