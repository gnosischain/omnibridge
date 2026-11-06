pragma solidity 0.7.5;
pragma abicoder v2;

import "forge-std/Test.sol";

interface IBridgedToken {
    function owner() external view returns (address);

    function bridgeContract() external view returns (address);

    function implementation() external view returns (address);

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);

    function balanceOf(address) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function mint(address, uint256) external returns (bool);
}

/**
 * @dev Shared helpers for Foundry tests.
 */
abstract contract TestHelpers is Test {
    /**
     * @dev Deploys the precompiled PermittableToken (solc 0.4.24), used as the token image by TokenFactory.
     */
    function deployTokenImage() internal returns (address image) {
        uint256 chainId;
        assembly {
            chainId := chainid() // block.chainid needs solc >= 0.8
        }
        string memory json = vm.readFile("precompiled/PermittableToken.json");
        bytes memory code =
            abi.encodePacked(vm.parseJsonBytes(json, ".bytecode"), abi.encode("", "", uint8(0), chainId));
        assembly {
            image := create(0, add(code, 0x20), mload(code))
        }
        require(image != address(0), "token image deployment failed");
    }
}
