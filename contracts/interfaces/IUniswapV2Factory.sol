pragma solidity >=0.5.0;

interface IUniswapV2Factory {
    // Emitted each time a pair is created via createPair()
    // token0 is guaranteed to be strictly less than token1 by sort order...
    // despite the fact that tokensA,B were given as input arguments to createPair() out-of-order
    // The final uint log value will be 1 for the first pair created, 2 for the second, etc. (see allPairs/getPair).
    // but how come multiple pairs - all are different-tokens pairs
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    // send the fee to this address, if feeOn == true
    function feeTo() external view returns (address);

    // The address allowed to change feeTo.
    function feeToSetter() external view returns (address);

    /*  Returns the address of the pair for tokenA and tokenB, if it has been created, else address(0) 
        tokenA and tokenB are interchangeable.  */
    // no such mandate of the Pair be created thru the Factory
    function getPair(address tokenA, address tokenB) external view returns (address pair);

    /*  Returns the address of the nth pair (0-indexed) created THRU THE FACTORY, or address(0)... 
        if not enough pairs have been created yet.
        Pass 0 for the address of the first pair created, 1 for the second, etc.    */
    function allPairs(uint) external view returns (address pair);

    // Returns the total number of pairs created THRU THE FACTORY so far.
    function allPairsLength() external view returns (uint);

    // critical function - deploys UniswapV2Pair.sol for a new pair of assets
    function createPair(address tokenA, address tokenB) external returns (address pair);

    function setFeeTo(address) external; // shouldn't there be a modifier that only feeToSetter can set it

    function setFeeToSetter(address) external; // sets the permission to adjust feeTo()
}
