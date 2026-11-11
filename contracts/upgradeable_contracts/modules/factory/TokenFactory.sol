pragma solidity 0.7.5;

import "./TokenProxy.sol";
import "../OwnableModule.sol";

/**
 * @title TokenFactory
 * @dev Factory contract for deployment of new TokenProxy contracts.
 */
contract TokenFactory is OwnableModule {
    address public tokenImage;
    mapping(address => bool) public isDeployer;

    /**
     * @dev Initializes this contract
     * @param _owner of this factory contract.
     * @param _tokenImage address of the token image contract that should be used for creation of new tokens.
     */
    constructor(address _owner, address _tokenImage) OwnableModule(_owner) {
        tokenImage = _tokenImage;
    }

    /**
     * @dev Tells the module interface version that this contract supports.
     * @return major value of the version
     * @return minor value of the version
     * @return patch value of the version
     */
    function getModuleInterfacesVersion()
        external
        pure
        returns (
            uint64 major,
            uint64 minor,
            uint64 patch
        )
    {
        return (1, 0, 0);
    }

    /**
     * @dev Updates the address of the used token image contract.
     * Only owner can call this method.
     * @param _tokenImage address of the new token image used for further deployments.
     */
    function setTokenImage(address _tokenImage) external onlyOwner {
        require(Address.isContract(_tokenImage));
        tokenImage = _tokenImage;
    }

    /**
     * @dev Allows or disallows an address to deploy new tokens (normally the bridge mediator).
     * Only owner can call this method.
     * @param _deployer address of the deployer.
     * @param _allowed true to allow, false to disallow.
     */
    function setDeployer(address _deployer, bool _allowed) external onlyOwner {
        isDeployer[_deployer] = _allowed;
    }

    /**
     * @dev Deploys a new TokenProxy contract with CREATE2, using saved token image contract as a template.
     * The address depends only on this factory address and the source token address.
     * Only allowed deployers can call this method. The caller becomes the token owner.
     * In production, a bridge mediator contract deploy a token proxy for a token from the source chain and be the token owner.
     * @param _name deployed token name.
     * @param _symbol deployed token symbol.
     * @param _decimals deployed token decimals.
     * @param _chainId chain id of the current environment.
     * @param _token address of the token on the source chain, used as the CREATE2 salt.
     * @return tokenProxy address of a newly created contract.
     */
    function deploy(
        string calldata _name,
        string calldata _symbol,
        uint8 _decimals,
        uint256 _chainId,
        address _token
    ) external returns (address tokenProxy) {
        require(isDeployer[msg.sender],"TokenFactory: Not a deployer");
        tokenProxy = _deployTokenProxy(_token);
        TokenProxy(payable(tokenProxy)).initialize(tokenImage, _name, _symbol, _decimals, _chainId, msg.sender);
    }

    /**
     * @dev Tells the address at which the token proxy for the given source token is (or will be) deployed.
     * @param _token address of the token on the source chain.
     * @return address of the token proxy.
     */
    function predictTokenProxyAddress(address _token) external view returns (address) {
        bytes32 hash =
            keccak256(
                abi.encodePacked(bytes1(0xff), address(this), _salt(_token), keccak256(type(TokenProxy).creationCode))
            );
        return address(uint160(uint256(hash)));
    }

    /**
     * @dev Internal function for computing the CREATE2 salt from the source token address.
     * @param _token address of the token on the source chain.
     * @return CREATE2 salt.
     */
    function _salt(address _token) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_token)));
    }

    function _deployTokenProxy(address _token) internal returns (address tokenProxy) {
        bytes memory initCode = type(TokenProxy).creationCode;
        bytes32 salt = _salt(_token);

        assembly {
            // bytes memory layout: [32-byte length][data...]
            tokenProxy := create2(0, add(initCode, 0x20), mload(initCode), salt)

            if iszero(tokenProxy) {
                // bubble up the constructor's revert reason
                let p := mload(0x40)
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
        }}
}
