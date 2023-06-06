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
    // 'k' is constant in Physics :)
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
        // all 3 "good old friends in same slot" get updated in _update()
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
    
    // # 4:
    // _update() runs many times, hence gas op. technique to couple all 3 params together in 1 storage cell
    // update reserves and, on the first call per block, price accumulators
    // This function is called EVERYTIME tokens are deposited or withdrawn or swapped/traded/exchanged
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
            
            // AMM = Constant Product Formulae : Value0 = Value1 => 
            // Price0 * Reserve0 = Price1 * Reserve1 => 
            // price0 = (R1 / R0) * P1
            // priceCumu2 = priceCumu1 + (price2 * timeElapsed2) (consider price0 like price2)

            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
            // `price0CumulativeLast` is accumulating price of assets so later we can calculate the price of a asset
            // using the formulae @ the link - Uiswap v2 Oracle docs
            
            // we're using "priceCumu" above to calulate TWAP across a time interval
        }
        // good old 3 friends in the same storage slot
        // This price calculation is the reason we need to know the old reserve sizes.
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        // finally, emit
        emit Sync(reserve0, reserve1);
    }

    // if (Protocol) fee is on, mint liquidity (tokens) equivalent to...
    // 1/6th (0.05% (which pays Uniswap for their development effort) out of 0.3% trader fee) of the growth in sqrt(k) 
    // bcz rest of the 0.25% of the fee goes to the LProviders only

    // To reduce calculations (and therefore gas costs), 
    // this fee is ONLY (NOT at every txn (not at swaps bcz it has complex calc.) calculated when liquidity is added or removed from the pool, 
    // rather than at each transaction.
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo();
        // feeOn true if NOT address(0) else false
        feeOn = feeTo != address(0);

        uint _kLast = kLast; // gas savings
        // kLast (The Constant Product) is state var. saved it to memory-based iternal _kLast
        // The liquidity providers get their cut simply by the appreciation of their liquidity tokens. 
        // But the protocol fee requires new liquidity tokens to be minted and provided to the feeTo address.
        // Once for LProviders for every deposition of Liquidity to the Pool BUT
        // everytime for the Protocol as their dev-effort-Contracts are being used everytime a txn happens
        if (feeOn) {
            if (_kLast != 0) {
                // which situation will make kLast = 0. YTFO
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                // rootK ----------> this is root of current constant (_r0, _r1)
                uint rootKLast = Math.sqrt(_kLast);
                // rootKLast -------> this is root of previous contant (constant = reserve0 * reserve1)

                // Liquidity minted for the 1st time when LProvider adds to the Pool:
                // Sqrt(reserve0 * reserve1) (reserve0 * reserve1 = Constant Product = kLast)
                // kLast = reserv0 * reserve1 => _updates at every txn (addL, removeL, swap)
                // whereas _mintFee(_r0, _r1) gets clacl. only at addL and removeL
                // so, the 2 products viz. -kLast (it's actually kLast only) can be diff. from (_reserve0*_reserve1)
                // YTFO whether it's fully correct
                
                // # 5: (complete details at pg#24 of my personal notes)
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;

                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
            // If there is no fee set kLast to zero
        }
    }

    // 3 (main) + 2(extra)  = 5 Externally Accessible Functions:
    // # 6
    // this low-level function should be called from a contract (Periphery, external to the this contract) which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) {
        /* steps -
         * 1. liquidity provider uses router contract to deposit liquidity
         * 2. Router contract sends assets of liquidity provider to this address
         * 3. Then we calculate liquidity tokens to be minted
         * 4. And mint liquidity tokens for liquidity provider
         * 5. Update the reserves with `_update` function
         */
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

/* # 4
https://docs.uniswap.org/contracts/v2/concepts/core-concepts/oracles
Uniswapv2 as the Price Oracle:
Every pair measures (but does not store) the market price at the beginning of each block, before any trades take place. 
This price is expensive to manipulate because it is set by the last transaction, 
whether it is a mint, swap, or burn, in a previous block
==========================
Uniswap is also a price oracle
* It is a Time Weighted Average Price Oracle (TWAP).
* Uniswap calculates the price everytime a swap happens
* it calculates average price of security over a specified amount of time
* it is using price0CumulativeLast for calculating price 
* `price0CumulativeLast` is accumulating price of assets so later we can calculate the price of a asset
* UQ112x112 library is for encoding floating point numbers as solidity only support intergers
* `UQ112x112.encode(_reserve1)` is encoding so floating point numbers don't cause any problem
* `(UQ112x112.encode(_reserve1).uqdiv(_reserve0)` is dividing it by reserve of another token coz it's how a AMM works.
* multiplying `timeElapsed` as it is needed for mathematical formula
* Please look at this for clear understanding https://docs.uniswap.org/protocol/V2/concepts/core-concepts/oracles (must read)
* with `price0CumulativeLast` & timeStamp we can calculate average price across any time interval.
*/

/* # 5
2.4 Protocol fee: (Whitepaper)
Uniswap v2 includes a 0.05% protocol fee that can be turned on and off. If turned on,
this fee would be sent to a feeTo address specified in the factory contract.
Initially, feeTo is not set, and no fee is collected. A pre-specified address—feeToSetter—can
call the setFeeTo function on the Uniswap v2 factory contract, setting feeTo to a different
value. feeToSetter can also call the setFeeToSetter to change the feeToSetter address itself.
If the feeTo address is set, the protocol will begin charging a 5-basis-point fee, which is
taken as a 1/6 cut of the 30-basis-point fees earned by liquidity providers. That is, traders will
continue to pay a 0.30% fee on all trades; 83.3% of that fee (0.25% of the amount traded)
will go to liquidity providers, and 16.6% of that fee (0.05% of the amount traded) will go to
the feeTo address.
Collecting this 0.05% fee at the time of the trade would impose an additional gas cost on
every trade. To avoid this, accumulated fees are collected only when liquidity is deposited
or withdrawn. The contract computes the accumulated fees, and mints new liquidity tokens
to the fee beneficiary, immediately before any tokens are minted or burned.
*/

/* # 6:
Note that while any transaction or contract can call these functions, 
they are designed to be called from the periphery contract. 
If you call them directly you won't be able to cheat the pair exchange, 
but you might lose value through a mistake.
*/