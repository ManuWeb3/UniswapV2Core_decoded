pragma solidity >=0.5.0;

interface IUniswapV2ERC20 {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);

    function symbol() external pure returns (string memory);

    function decimals() external pure returns (uint8);

    function totalSupply() external view returns (uint);

    function balanceOf(address owner) external view returns (uint);

    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);

    function transfer(address to, uint value) external returns (bool);

    function transferFrom(address from, address to, uint value) external returns (bool);

    // Returns a domain separator for use in permit.
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    function PERMIT_TYPEHASH() external pure returns (bytes32);

    // Returns the current nonce for an address for use in permit.
    function nonces(address owner) external view returns (uint);

    // Sets the allowance for a spender where approval is granted via a signature.
    // Supporting meta transactions
    // This obviates the need for a blocking approve transaction before programmatic interactions with pool tokens can occur.
    // using ERC-712
    // https://docs.uniswap.org/contracts/v2/guides/smart-contract-integration/supporting-meta-transactions
    // Permit = No more "Blocking Approve Transaction"
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
}
