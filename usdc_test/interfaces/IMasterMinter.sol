// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.7.5;

interface IMasterMinter {
    event ControllerConfigured(address indexed _controller, address indexed _worker);
    event ControllerRemoved(address indexed _controller);
    event MinterAllowanceDecremented(
        address indexed msgSender,
        address indexed minter,
        uint256 decrement,
        uint256 newAllowance
    );
    event MinterAllowanceIncremented(
        address indexed _msgSender,
        address indexed _minter,
        uint256 _increment,
        uint256 _newAllowance
    );
    event MinterConfigured(address indexed _msgSender, address indexed _minter, uint256 _allowance);
    event MinterManagerSet(address indexed _oldMinterManager, address indexed _newMinterManager);
    event MinterRemoved(address indexed _msgSender, address indexed _minter);
    event OwnershipTransferred(address previousOwner, address newOwner);

    function configureController(address _controller, address _worker) external;

    function configureMinter(uint256 _newAllowance) external returns (bool);

    function decrementMinterAllowance(uint256 _allowanceDecrement) external returns (bool);

    function getMinterManager() external view returns (address);

    function getWorker(address _controller) external view returns (address);

    function incrementMinterAllowance(uint256 _allowanceIncrement) external returns (bool);

    function owner() external view returns (address);

    function removeController(address _controller) external;

    function removeMinter() external returns (bool);

    function setMinterManager(address _newMinterManager) external;

    function transferOwnership(address newOwner) external;
}
