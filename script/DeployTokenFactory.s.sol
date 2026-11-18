pragma solidity 0.7.5;
pragma abicoder v2;

import "./base/OmnibridgeScript.sol";

/**
 * @dev Deploys the CREATE2 TokenFactory through the EIP-7997 deterministic factory, then configures it:
 * setTokenImage(TOKEN_IMAGE), setDeployer(MEDIATOR, true), transferOwnership(FACTORY_OWNER).
 *
 * The factory is created with (owner = signer, image = address(0)), so its address depends only on the signer and
 * TOKEN_FACTORY_SALT: the same signer and salt give the same address on every chain, and nobody else can take it.
 * The chain specific token image is set after deployment.
 *
 * Env:
 *   MEDIATOR             mediator proxy allowed to deploy tokens
 *   TOKEN_IMAGE          PermittableToken image of this chain
 *   FACTORY_OWNER        final owner of the factory (bridge owner)
 *   TOKEN_FACTORY_SALT   optional bytes32, default 0. Use a different salt per mediator.
 *
 * Usage:
 *   MEDIATOR=0x... TOKEN_IMAGE=0x... FACTORY_OWNER=0x... \
 *     forge script script/DeployTokenFactory.s.sol --rpc-url $RPC --broadcast --account deployer
 */
contract DeployTokenFactory is OmnibridgeScript {
    // EIP-7997: calldata = salt (32 bytes) ++ init code, returns the created address as 20 bytes.
    address internal constant EIP7997_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (address factory) {
        address mediator = vm.envAddress("MEDIATOR");
        address image = vm.envAddress("TOKEN_IMAGE");
        address finalOwner = vm.envAddress("FACTORY_OWNER");
        bytes32 salt = vm.envOr("TOKEN_FACTORY_SALT", bytes32(0));

        require(_isContract(EIP7997_FACTORY), "EIP-7997 factory is not deployed on this chain");
        require(_isContract(image), "TOKEN_IMAGE is not a contract");

        vm.startBroadcast();
        address signer = _broadcaster();

        bytes memory initCode = abi.encodePacked(type(TokenFactory).creationCode, abi.encode(signer, address(0)));
        factory = _predict(salt, initCode);

        if (_isContract(factory)) {
            console2.log("Token factory already deployed:", factory);
        } else {
            (bool ok, bytes memory ret) = EIP7997_FACTORY.call(abi.encodePacked(salt, initCode));
            require(ok && ret.length == 20, "EIP-7997 deployment failed");
            address deployed;
            assembly {
                deployed := shr(96, mload(add(ret, 0x20)))
            }
            require(deployed == factory, "unexpected factory address");
            console2.log("Token factory deployed:", factory);
        }

        TokenFactory tokenFactory = TokenFactory(factory);
        if (tokenFactory.owner() == signer) {
            if (tokenFactory.tokenImage() != image) {
                tokenFactory.setTokenImage(image);
            }
            _setFactoryDeployer(tokenFactory, mediator);
            if (finalOwner != signer) {
                tokenFactory.transferOwnership(finalOwner);
            }
        } else {
            console2.log("Signer no longer owns the factory, skipping configuration. Owner:", tokenFactory.owner());
        }
        vm.stopBroadcast();

        console2.log("  owner:", tokenFactory.owner());
        console2.log("  tokenImage:", tokenFactory.tokenImage());
        console2.log("  isDeployer(mediator):", tokenFactory.isDeployer(mediator));
    }

    function _predict(bytes32 _salt, bytes memory _initCode) internal pure returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), EIP7997_FACTORY, _salt, keccak256(_initCode)))))
            );
    }
}
