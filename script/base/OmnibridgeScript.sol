pragma solidity 0.7.5;
pragma abicoder v2;

import "forge-std/Script.sol";
import "../../contracts/upgradeable_contracts/modules/factory/TokenFactory.sol";

/**
 * @dev Shared helpers for Omnibridge deployment scripts.
 */
abstract contract OmnibridgeScript is Script {
    /**
     * @dev Address that signs the broadcast transactions (--private-key, --account, --ledger, ...).
     * Must be called after vm.startBroadcast().
     */
    function _broadcaster() internal returns (address sender) {
        (, sender, ) = vm.readCallers();
    }

    function _isContract(address _addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }

    function _chainId() internal pure returns (uint256 id) {
        assembly {
            id := chainid() // block.chainid needs solc >= 0.8
        }
    }

    /**
     * @dev Deploys the precompiled PermittableToken (solc 0.4.24) used as the token image.
     */
    function _deployTokenImage() internal returns (address image) {
        string memory json = vm.readFile("precompiled/PermittableToken.json");
        bytes memory code =
            abi.encodePacked(vm.parseJsonBytes(json, ".bytecode"), abi.encode("", "", uint8(0), _chainId()));
        assembly {
            image := create(0, add(code, 0x20), mload(code))
        }
        require(image != address(0), "token image deployment failed");
        console2.log("Token image deployed:", image);
    }

    /**
     * @dev Parses a decimal string such as "0.001" into wei (18 decimals), like web3's toWei.
     */
    function _parseEther(string memory _value) internal pure returns (uint256 result) {
        bytes memory b = bytes(_value);
        bool dot;
        uint256 decimals;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ".") {
                require(!dot, "invalid number");
                dot = true;
                continue;
            }
            require(b[i] >= "0" && b[i] <= "9", "invalid number");
            if (dot) {
                decimals++;
                require(decimals <= 18, "too many decimals");
            }
            result = result * 10 + (uint8(b[i]) - 48);
        }
        result = result * 10**(18 - decimals);
    }

    function _equal(string memory _a, string memory _b) internal pure returns (bool) {
        return keccak256(bytes(_a)) == keccak256(bytes(_b));
    }
}
