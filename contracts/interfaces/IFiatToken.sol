pragma solidity 0.7.5;

interface IFiatToken {
    function burn(uint256 _amount)external;
    function transferFrom( address from,address to,uint256 value)external returns(bool);
     function mint(address _to, uint256 _amount)external returns(bool);
}