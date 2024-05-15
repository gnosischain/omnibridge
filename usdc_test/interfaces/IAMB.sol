pragma solidity 0.7.5;

interface IAMB {
    function executeAffirmation(bytes memory message) external;

    function submitSignature(bytes memory signature, bytes memory message) external;

    function executeSignatures(bytes memory message, bytes memory signatures) external;

    function numMessagesSigned(bytes32 _message) external view returns (uint256);

    function isAlreadyProcessed(uint256 _number) external pure returns (bool);

    function signature(bytes32 _hash, uint256 _index) external view returns (bytes memory);
}
