// LPool code - deployed using CREATE2 by Factory.sol - for every unique trading pair of ERC20s
pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';      // Liquidity token of pools
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath  for uint;       // handle overflow/underflow/division by zero errors
    using UQ112x112 for uint224;    // handles representation of floating points like 1.0, 1.5
    
    // 1000 - to avoid division by zero errors
    uint public constant MINIMUM_LIQUIDITY = 10**3;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));
    
    // factory: init inside constructor()
    address public factory;         // central point connecting all the LPools - deploys LPools
    address public token0;          // the 2 ERC20 tokens for this pool
    address public token1;          // both initialized in initialize()

    // uint256 - 256 total - gas save - 1 single storage cell = 112+112+32=256
    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves
    // the timestamp for the last exchange of tokens to keep a track of exchange rates across times

    uint public price0CumulativeLast;   // comments @ end # 1
    uint public price1CumulativeLast;   // comments @ end
    // used to calc. Avg. Exchange Rate over a period of time. 
    uint public kLast; 
    // reserve0 * reserve1, as of immediately after the most recent liquidity event (all 3: add, remove, swap)
    // The Constant Product Formulae => x*y = k (kLast)

    // below (lock/unlock) mechanism is here to avoid Re-entrancy attacks
    uint private unlocked = 1;

    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;   // (0=false) LOCK the function, then execute
        _;
        unlocked = 1;   // (unlock = true) => complete fn. executed, now re-entrancy threat gone
        // re-entrant call cannot happen in the same txn anymore
        // fn. call m,ay happen anytime in the future in a different txn
    }

    // Misc. fn
    // #1
    // reserve0 and reserve1 are a fn(_blockTimestampLast) for calc. of AvgExRate
    // => hence, all 3 return values are coupled
    // assigned 3 state vars to 3 local vars
    // current state of the exchange
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    // #2
    // helper - private
    // To transfer an amount (value) of ERC20 tokens from the exchange to "to" address.
    // SELECTOR specifies that the function we are calling is transfer(address,uint)
    function _safeTransfer(address token, address to, uint value) private {
        // abi.encodeWithSelector(SELECTOR, to, value) returns bytes memory = calldata for .call(arg)
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        // To avoid having to import an interface for the token function: transfer(), 
        // we "manually" created the call (.call(calldata)) using one of the ABI functions
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
        // comments for require @ end # 2
    }

    // 4 events:
    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    // Sender may Not be = to, in case of Burn
    event Swap(
        address indexed sender, // initiated the swap.
        uint amount0In,         // first token in the trading pair sent into the swap.
        uint amount1In,
        uint amount0Out,
        uint amount1Out,        // 2nd token in the pair that got received from the awap
        address indexed to      
        // destination address: that received the swapped token (concept of "path").
    );
    // (_update()) - when reserves get synced after any of the 3 main events
    // to get correct AvgExRate of both the tokens in ques.
    event Sync(uint112 reserve0, uint112 reserve1);

    // 8 Setup functions

    constructor() public {
        factory = msg.sender;
        // only factory can deploy the Pair, hence msg.sender = factory's address
    }

    // called once by the factory at time of deployment
    // can be called externally ONLY by the Factory after deployment
    // specifies which 2 tokens can be exchanged by this deployed LPool
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }
    
    // _update() runs many times, hence gas op. technique to couple all 3 params together in 1 storage cell
    // update reserves and, on the first call per block, price accumulators
    // This function is called every time tokens are deposited or withdrawn.
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        // uint112(-1) = =2^112-1 (max value of uint112 = odd = all 1s in 112 bits)
        // reverts when balance0 >= uint112(-1) = Overflow
        // each exchange is limited to about 5.1*10^15 of each tokens - YTFO ?
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        // comments @ end # 3
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        // blockTimestampLast = 0for the first time, before any swap, addL, removeL happens
        // time elapsed since last addL, removeL, swap
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            /* this `timeElapsed > 0` making sure to protect against flash loan attacks - YTFO ?
             * only first transaction of a block will trigger this if statement
             * transactions after that (in the same block) will have 0 timeElapsed
             * as blockTimestampLast is getting updated in last of `_update` function
            */
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // if (Protocol) fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k) - later
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // Externally Accessible Functions
    // this low-level function should be called from a contract (Periphery) which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
           _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract (Periphery) which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract (Periphery) which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}

// YTFO = Yet To Figure Out

/* # 1
AVERAGE EXCHANGE RATE:

Initial setup:	token0=1,000	token1=1,000	rx*ry = kLast = 1,000,000	
Trader A swaps 50 token0 for 47.619 token1:	t0=1,050	t1=952.381	kLast=1,000,000 AvgExRate=0.952 =>

Case # 1--
AvgExRate=token1/token0 = 47.619/50 = 0.952
Case # 2--
AvgExRate=token0/token1 = 50/47.619 = 1.050 

Case # 1=> token1 = 0.952(token0) = AvgExRate
For every 1 token0, we got 0.952 of token1 IN THAT SPECIFIC SWAP
*/

/* # 2
1. "success" return value:
.call() itself fail = external call to ERC20 fn. failed

2. bytes memory data:
.call() succeed in calling transfer() of ERC20 token contract
BUT, transfer itself failed and returned "false" = non-zero

Suppose, the ERC-20 token is a "bad" one and does not return anything.
like USDT, BNB - incomplete implementations of ERC20 standard's transfer fn.
If nothing returned, success, else there would have been an error msg returned

abi.decode(bytes memory encodedData, (...)) returns (...): 
ABI-decodes the given data, while the types are given in parentheses as second argument. 
Example:(uint a, uint[2] memory b, bytes memory c) = abi.decode(data, (uint, uint[2], bytes))
If the transfer is successful (success == true) 
and either the returned data is empty or can be decoded into a boolean value (abi.decode(data, (bool)) == true), 
the transfer is considered successful.
*/

/* # 3
As far as the block.timestamp is < 4294967296, returns the same value else resets to 0, 1, 2, etc.

we divide any number it will be same as original
e.g. 5000 % 2**32 = 5000 (check in your console)
but it's valid if value is smaller than 2**32
the value of 2**32 is 4294967296
`4294967296 - 1` is allowed but if we use 4294967296 or greater, the value will be reset (try it yourself on browser console)
that's why they are modding it by 2**32, so if the value is greater than this, it gets reset.
Note: Always double check what I am writing. This is what I can understand
*/