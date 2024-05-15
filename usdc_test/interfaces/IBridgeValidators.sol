pragma solidity 0.7.5;

interface IBridgeValidators {
    function addValidator(address _validator) external;

    function setRequiredSignatures(uint256 _requiredSignatures) external;

    function owner() external view returns (address);
}
