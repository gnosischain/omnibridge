// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.7.5;

interface IForeignOmnibridge {
    event CircleAddressSet(address indexed oldCircleAddress, address indexed newCircleAddress);
    event DailyLimitChanged(address indexed token, uint256 newLimit);
    event ExecutionDailyLimitChanged(address indexed token, uint256 newLimit);
    event FailedMessageFixed(bytes32 indexed messageId, address token, address recipient, uint256 value);
    event NewTokenRegistered(address indexed nativeToken, address indexed bridgedToken);
    event OwnershipTransferred(address previousOwner, address newOwner);
    event TokensBridged(address indexed token, address indexed recipient, uint256 value, bytes32 indexed messageId);
    event TokensBridgingInitiated(
        address indexed token,
        address indexed sender,
        uint256 value,
        bytes32 indexed messageId
    );

    function bridgeContract() external view returns (address);

    function bridgedTokenAddress(address _nativeToken) external view returns (address);

    function burnLockedUSDC(uint256 amount) external;

    function claimTokens(address _token, address _to) external;

    function claimTokensFromTokenContract(
        address _bridgedToken,
        address _token,
        address _to
    ) external;

    function dailyLimit(address _token) external view returns (uint256);

    function deployAndHandleBridgedTokens(
        address _token,
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _recipient,
        uint256 _value
    ) external;

    function deployAndHandleBridgedTokensAndCall(
        address _token,
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _recipient,
        uint256 _value,
        bytes memory _data
    ) external;

    function disableInterest(address _token) external;

    function executionDailyLimit(address _token) external view returns (uint256);

    function executionMaxPerTx(address _token) external view returns (uint256);

    function fixFailedMessage(bytes32 _messageId) external;

    function fixMediatorBalance(address _token, address _receiver) external;

    function getBridgeInterfacesVersion()
        external
        pure
        returns (
            uint64 major,
            uint64 minor,
            uint64 patch
        );

    function getBridgeMode() external pure returns (bytes4 _data);

    function getCircleAddress() external view returns (address);

    function getCurrentDay() external view returns (uint256);

    function handleBridgedTokens(
        address _token,
        address _recipient,
        uint256 _value
    ) external;

    function handleBridgedTokensAndCall(
        address _token,
        address _recipient,
        uint256 _value,
        bytes memory _data
    ) external;

    function handleNativeTokens(
        address _token,
        address _recipient,
        uint256 _value
    ) external;

    function handleNativeTokensAndCall(
        address _token,
        address _recipient,
        uint256 _value,
        bytes memory _data
    ) external;

    function initialize(
        address _bridgeContract,
        address _mediatorContract,
        uint256[3] memory _dailyLimitMaxPerTxMinPerTxArray,
        uint256[2] memory _executionDailyLimitExecutionMaxPerTxArray,
        uint256 _requestGasLimit,
        address _owner,
        address _tokenFactory
    ) external returns (bool);

    function initializeInterest(
        address _token,
        address _impl,
        uint256 _minCashThreshold
    ) external;

    function interestImplementation(address _token) external view returns (address);

    function invest(address _token) external;

    function isBridgedTokenDeployAcknowledged(address _token) external view returns (bool);

    function isInitialized() external view returns (bool);

    function isRegisteredAsNativeToken(address _token) external view returns (bool);

    function isTokenRegistered(address _token) external view returns (bool);

    function maxAvailablePerTx(address _token) external view returns (uint256);

    function maxPerTx(address _token) external view returns (uint256);

    function mediatorBalance(address _token) external view returns (uint256);

    function mediatorContractOnOtherSide() external view returns (address);

    function messageFixed(bytes32 _messageId) external view returns (bool);

    function minCashThreshold(address _token) external view returns (uint256);

    function minPerTx(address _token) external view returns (uint256);

    function nativeTokenAddress(address _bridgedToken) external view returns (address);

    function onTokenTransfer(
        address _from,
        uint256 _value,
        bytes memory _data
    ) external returns (bool);

    function owner() external view returns (address);

    function relayTokens(address token, uint256 _value) external;

    function relayTokens(
        address token,
        address _receiver,
        uint256 _value
    ) external;

    function relayTokensAndCall(
        address token,
        address _receiver,
        uint256 _value,
        bytes memory _data
    ) external;

    function requestFailedMessageFix(bytes32 _messageId) external;

    function requestGasLimit() external view returns (uint256);

    function setBridgeContract(address _bridgeContract) external;

    function setCircleAddress(address circleAddr) external;

    function setCustomTokenAddressPair(address _nativeToken, address _bridgedToken) external;

    function setDailyLimit(address _token, uint256 _dailyLimit) external;

    function setExecutionDailyLimit(address _token, uint256 _dailyLimit) external;

    function setExecutionMaxPerTx(address _token, uint256 _maxPerTx) external;

    function setMaxPerTx(address _token, uint256 _maxPerTx) external;

    function setMediatorContractOnOtherSide(address _mediatorContract) external;

    function setMinCashThreshold(address _token, uint256 _minCashThreshold) external;

    function setMinPerTx(address _token, uint256 _minPerTx) external;

    function setRequestGasLimit(uint256 _gasLimit) external;

    function setTokenFactory(address _tokenFactory) external;

    function tokenFactory() external view returns (address);

    function totalExecutedPerDay(address _token, uint256 _day) external view returns (uint256);

    function totalSpentPerDay(address _token, uint256 _day) external view returns (uint256);

    function transferOwnership(address newOwner) external;

    function upgradeToReverseMode(address _tokenFactory) external;

    function withinExecutionLimit(address _token, uint256 _amount) external view returns (bool);

    function withinLimit(address _token, uint256 _amount) external view returns (bool);
}
