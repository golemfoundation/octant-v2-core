// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import { Ownable } from "solady/auth/Ownable.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

import { IOracle } from "src/utils/vendor/0xSplits/OracleParams.sol";
import { QuotePair, QuoteParams } from "src/utils/vendor/0xSplits/LibQuotes.sol";
import { IUniV3Swap } from "src/utils/vendor/0xSplits/IUniV3Swap.sol";

import { ITransformer } from "src/zodiac-core/interfaces/ITransformer.sol";
import { ISwapperImpl } from "src/utils/vendor/0xSplits/SwapperImpl.sol";
import { ISwapRouter } from "src/utils/vendor/uniswap/ISwapRouter.sol";
import { NATIVE_TOKEN } from "src/constants.sol";

/**
 * @title Octant Trader
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Dollar-cost averaging (DCA) trader with randomized execution timing
 * @dev Performs trades at pseudo-random intervals to prevent front-running and insider trading
 *
 *      DCA MECHANISM:
 *      - Budget amount sold over period (e.g., 1M USDS over 30 days)
 *      - Trade size randomized between [saleValueLow, saleValueHigh)
 *      - Trade timing randomized via blockhash entropy
 *      - Adaptive probability ensures budget spent by deadline
 *
 *      RANDOMNESS MODEL:
 *      - Uses blockhash(height) as entropy source
 *      - Each block has probability of trade (increases near deadline)
 *      - One randomness value used only once (prevents replays)
 *      - Recent 256 blocks available (EVM limitation)
 *
 *      ANTI-MANIPULATION:
 *      - Random timing prevents MEV/front-running
 *      - Overspending protection (linear budget enforcement)
 *      - Oracle validation via 0xSplits Swapper (fair price)
 *      - No privileged execution (owner can't trigger trades)
 *
 *      INTEGRATION:
 *      - Trader: Manages amounts, timing, randomness
 *      - Swapper: Validates fair pricing via oracle
 *      - UniV3Swap (integrator): Executes actual DEX trades
 *      - WETH conversion handled by integrator
 *
 *      CONFIGURATION:
 *      - setSpending(): Budget, low/high sale bounds
 *      - configurePeriod(): Period length and start height
 *      - setSwapper(): Update swapper/integrator contracts
 *      - emergencyStop(): Pause trading
 *
 *      LIMITATIONS:
 *      - Assumes ~7200 blocks/day (Ethereum mainnet)
 *      - Requires consistent block times
 *      - Limited to recent 256 blocks for randomness
 *
 * @custom:security Randomness prevents front-running but relies on blockhash unpredictability
 * @custom:security Oracle validation protects against bad trades
 */
contract Trader is ITransformer, Ownable, Pausable {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                          Constants
    //////////////////////////////////////////////////////////////*/

    uint256 public constant BLOCKS_PER_DAY = 7200;
    /// @notice Address of WETH wrapper
    address public immutable WETH_ADDRESS;
    /// @notice Token to be sold.
    address public immutable BASE;
    /// @notice Token to be bought.
    /// @dev Please note that contract that deals with quote token is the `swapper`. Here value of `quote` is purely informational.
    address public immutable QUOTE;
    /// @dev Price oracle used by splits to make sure that Trader gets fair price.
    IOracle public immutable ORACLE;

    /*//////////////////////////////////////////////////////////////
                          PRIVATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev Uniswap path representing base and quote token pair pool; includes pool provision.
    bytes private uniPair;
    /// @dev Base-to-quote pair encoded for price oracle used by splits.
    QuotePair private splitsPair;
    /// @dev Parameters for the swap.
    ISwapRouter.ExactInputParams[] private exactInputParams;
    /// @dev Parameters for the oracle.
    QuoteParams[] private quoteParams;

    /*//////////////////////////////////////////////////////////////
                          STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract that temporary stores sold token and makes sure that Trader/beneficiary gets fair price.
    address public swapper;
    /// @notice Address of the contract that integrates Uniswap (or possibly some other exchange). Implements IUniV3Swap interface.
    address public integrator;
    /// @notice Beneficiary will receive quote token after the sale of base token.
    address public immutable BENEFICIARY;
    /// @notice `budget` needs to be spend before the end of the period (in blocks).
    uint256 public periodLength;
    /// @notice Total token to be spent before deadline. Please note that balance of quote token may differ from value of budget.
    uint256 public budget;
    /// @notice Spent token since spentResetBlock.
    uint256 public spent;
    /// @notice Current deadline (defined by periodZero and periodLength).
    uint256 public deadline;
    /// @notice Rules for spending were last updated at this height.
    uint256 public spentResetBlock = block.number;
    /// @notice Block which starts the periods.
    uint256 public periodZero = block.number;
    /// @notice Lowest allowed size of a sale.
    uint256 public saleValueLow;
    /// @notice Highest allowed size of a sale.
    /// @dev Technically, this value minus one wei.
    uint256 public saleValueHigh;
    /// @notice Height of block hash used as a last source of randomness.
    uint256 public lastHeight;

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a trade is executed
    /// @param sold Amount of base token sold in base token units
    /// @param left Budget remaining after trade in base token units
    event Traded(uint256 sold, uint256 left);
    /// @notice Emitted when swapper and integrator are updated
    /// @param oldSwapper Previous swapper address
    /// @param newSwapper New swapper address
    /// @param oldIntegrator Previous integrator address
    /// @param newIntegrator New integrator address
    event SwapperChanged(address oldSwapper, address newSwapper, address oldIntegrator, address newIntegrator);
    /// @notice Emitted when spending parameters are updated
    /// @param low New minimum sale value in base token units
    /// @param high New maximum sale value in base token units
    /// @param spent Amount spent so far in base token units
    /// @param budget Total budget in base token units
    event SpendingChanged(uint256 low, uint256 high, uint256 spent, uint256 budget);
    /// @notice Emitted when period parameters are updated
    /// @param height Period zero block height
    /// @param length Period length in blocks
    /// @param deadline Current deadline block height
    event PeriodsChanged(uint256 height, uint256 length, uint256 deadline);

    /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Heights at which `convert()` can be called is decided by randomness.
    ///         If you see `Trader__WrongHeight()` error, retry in the next block.
    ///         Note, you don't need to pay for gas to learn if tx will apply!
    error Trader__WrongHeight();

    /// @notice This error indicates that contract has spent more than allowed.
    ///         Retry tx in the next block.
    error Trader__SpendingTooMuch();
    error Trader__RandomnessAlreadyUsed();
    error Trader__ZeroValueConvert();
    error Trader__RandomnessUnsafeSeed();
    error Trader__UnexpectedETH();
    error Trader__ImpossibleConfigurationDeadlineInThePast();
    error Trader__ImpossibleConfigurationSaleValueLowIsZero();
    error Trader__ImpossibleConfigurationSaleValueLowIsTooLow();
    error Trader__BudgetSpent();
    error Trader__ImpossibleConfiguration();
    error Trader__SoftwareError();

    /// @dev Whenever spending parameters are re-configured, this modifier is used to check if requested spending is realistic.
    modifier validateSpendingArgs() {
        _;
        if (budget != 0) {
            if (saleValueLow == 0) revert Trader__ImpossibleConfigurationSaleValueLowIsZero();
            if (getSafetyBlocks() > (deadline - block.number))
                revert Trader__ImpossibleConfigurationSaleValueLowIsTooLow();
        }
    }

    /*//////////////////////////////////////////////////////////////
      INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @dev Constructor accepts following list of parameters in encoded form.
    ///      address _owner - address that can configure Trader
    ///      address _base - sold token. If it is ETH, use whatever address that ETH() function returns.
    ///      address _quote - bought token. If it is ETH, use whatever address that ETH() function returns.
    ///      address _wethAddress - address of WETH.
    ///      address _beneficiary - bought token will be sent to this address
    ///      address _swapper - address of the contact that makes sure beneficiary is not being shortchanged during swapping.
    ///              Must implement ISwapperImpl interface.
    ///      address _integrator - address of the contract that does actual swapping. Must implement ISwapperFlashCallback interface.
    ///      address _oracle - oracle used by Splits' Swapper to ensure that beneficiary gets fair price.
    /// @param initializeParams Parameters of initialization encoded
    constructor(bytes memory initializeParams) {
        (
            address _owner,
            address _base,
            uint24 _fee,
            address _quote,
            address _wethAddress,
            address _beneficiary,
            address _swapper,
            address _integrator,
            address _oracle
        ) = abi.decode(
                initializeParams,
                (address, address, uint24, address, address, address, address, address, address)
            );
        _initializeOwner(msg.sender);
        BASE = _base;
        QUOTE = _quote;
        WETH_ADDRESS = _wethAddress;
        BENEFICIARY = _beneficiary;
        swapper = _swapper;
        integrator = _integrator;
        ORACLE = IOracle(_oracle);
        splitsPair = QuotePair({ base: splitsEthWrapper(BASE), quote: splitsEthWrapper(QUOTE) });
        uniPair = abi.encodePacked(uniEthWrapper(BASE), _fee, uniEthWrapper(QUOTE));
        transferOwnership(_owner);
    }

    /// @dev receive if integration doesn't use `transform` function
    receive() external payable {}

    /// @notice Prevent this contract from spending base token.
    /// @param enable Set to true to stop spending. Set to false to continue spending.
    function emergencyStop(bool enable) external onlyOwner {
        if (enable) _pause();
        else _unpause();
    }

    /// @notice Set address of the contract that will receive token (base) to be converted to target token (quote).
    /// @param swapper_ address of the contract handling the swapping.
    function setSwapper(address swapper_, address integrator_) external onlyOwner {
        emit SwapperChanged(swapper, swapper_, integrator, integrator_);
        swapper = payable(swapper_);
        integrator = integrator_;
    }

    /// @notice Implements Transformer.trader interface. This function can be used to synchronously convert one token to other token.
    ///         Please note that amount needs to be carefully chosen (see `findSaleValue(...)`).
    ///         This function will throw if fromToken and toToken are different from base and quote respectively.
    /// @param fromToken needs to be set to value of `base()`.
    /// @param toToken needs to be set to value of `quote()`.
    /// @param amount needs to be set to what `findSaleValue(...)` returns.
    /// @return amount of quote token that will be transferred to beneficiary.
    function transform(address fromToken, address toToken, uint256 amount) external payable returns (uint256) {
        if ((fromToken != BASE) || (toToken != QUOTE)) revert Trader__ImpossibleConfiguration();
        if (fromToken == NATIVE_TOKEN) {
            if (msg.value != amount) revert Trader__ImpossibleConfiguration();
        } else {
            if (msg.value != 0) revert Trader__UnexpectedETH();
            IERC20(BASE).safeTransferFrom(msg.sender, address(this), amount);
        }

        uint256 height;
        uint256 saleValue = 0;
        for (height = max(block.number - 255, lastHeight + 1); height < block.number; height++) {
            if (canTrade(height)) {
                saleValue = convert(height);
                break;
            }
        }
        if (saleValue != amount) revert Trader__SoftwareError();

        return callInitFlash(amount);
    }

    /// @notice Returns the average daily spending rate based on budget and deadline configuration
    /// @dev This reads configuration parameters, not current state of swapping process, which may diverge because of randomness.
    /// @return Average amount of token in wei to be sold in 24 hours.
    function spendADay() external view returns (uint256) {
        return (budget * BLOCKS_PER_DAY) / (deadline - spentResetBlock);
    }

    /// @notice This is a helper function, that can be used to trigger swapper's initFlash.
    /// @param amount Amount of `base` token that will be traded for `quote` token.
    /// @return Amount of `quote` token that beneficiary has received.
    /// @dev If `transform` interface is not used, `convert` and `callInitFlash` provide an alternative integration path.
    function callInitFlash(uint256 amount) public returns (uint256) {
        uint256 oldQuoteBalance = safeBalanceOf(QUOTE, BENEFICIARY);

        delete exactInputParams;
        exactInputParams.push(
            ISwapRouter.ExactInputParams({
                path: uniPair,
                recipient: address(integrator),
                deadline: block.timestamp + 60,
                amountIn: amount,
                amountOutMinimum: 0
            })
        );

        delete quoteParams;
        quoteParams.push(
            QuoteParams({ quotePair: splitsPair, baseAmount: uint128(amount), data: abi.encode(exactInputParams) })
        );
        IUniV3Swap.FlashCallbackData memory data = IUniV3Swap.FlashCallbackData({
            exactInputParams: exactInputParams,
            excessRecipient: address(BENEFICIARY)
        });
        IUniV3Swap.InitFlashParams memory params = IUniV3Swap.InitFlashParams({
            quoteParams: quoteParams,
            flashCallbackData: data
        });
        IUniV3Swap(payable(integrator)).initFlash(ISwapperImpl(swapper), params);

        return safeBalanceOf(QUOTE, BENEFICIARY) - oldQuoteBalance;
    }

    /// @notice Transfers funds that are to be converted by to target token by external converter.
    /// @param height that will be used as a source of randomness. One height value can be used only once.
    /// @return amount of base token that is transferred to the swapper.
    function convert(uint256 height) public whenNotPaused returns (uint256) {
        if (deadline < block.number) {
            deadline = nextDeadline();
            spent = 0;
            spentResetBlock = deadline - periodLength;
        }

        if (budget == spent) revert Trader__BudgetSpent();

        // handle randomness
        uint256 rand = getRandomNumber(height);
        uint256 _chance = chance();
        if (rand > _chance) revert Trader__WrongHeight();

        // handle overspending
        if (_chance != type(uint256).max && hasOverspent(height)) revert Trader__SpendingTooMuch();

        // don't allow to reuse randomness
        if (lastHeight >= height) revert Trader__RandomnessAlreadyUsed();
        lastHeight = height;

        uint256 balance = address(this).balance;
        if (BASE != NATIVE_TOKEN) {
            balance = IERC20(BASE).balanceOf(address(this));
        }

        uint256 saleValue = getSaleValue(rand, 0);
        //slither-disable-next-line incorrect-equality incorrect-equality
        if (saleValue == 0) revert Trader__ZeroValueConvert();

        spent = spent + saleValue;

        if (BASE == NATIVE_TOKEN) {
            payable(swapper).transfer(saleValue);
        } else {
            IERC20(BASE).safeTransfer(swapper, saleValue);
        }

        emit Traded(saleValue, balance - saleValue);
        return saleValue;
    }

    /// @notice Sets spending limits.
    /// @param low_ is a lower bound of sold token (in wei) for a single trade
    /// @param high_ is a higher bound of sold token (in wei) for a single trade
    /// @param budget_ sets amount of token (in wei) to be sold before deadline block height
    function setSpending(uint256 low_, uint256 high_, uint256 budget_) public onlyOwner validateSpendingArgs {
        lastHeight = block.number;
        saleValueLow = low_;
        saleValueHigh = high_;
        budget = budget_;
        if (spent > budget) spent = budget;
        emit SpendingChanged(low_, high_, spent, budget);
    }

    /// @notice Configures spending periods. Budget will be fully spend before the end of each period.
    /// @param length_ is length of a period in blocks.
    /// @param height_ is a block height remarking the beginning of a period.
    function configurePeriod(uint256 height_, uint256 length_) public onlyOwner validateSpendingArgs {
        periodZero = height_;
        periodLength = length_;
        deadline = nextDeadline();
        emit PeriodsChanged(height_, length_, deadline);
    }

    /// @notice Computes the next deadline block number for the spending period
    /// @dev Compute next deadline. If cached deadline (`deadline`) differs, `spent` needs to be reset.
    function nextDeadline() public view returns (uint256) {
        uint256 nextPeriodNo = (block.number - periodZero).divUp(periodLength);
        //slither-disable-next-line incorrect-equality incorrect-equality
        if (nextPeriodNo == (block.number - periodZero) / periodLength) {
            nextPeriodNo = nextPeriodNo + 1;
        }
        return periodZero + (periodLength * nextPeriodNo);
    }

    /// @notice Finds the sale value for a given transfer amount using unused randomness from recent blocks
    /// @dev Finds a earliest block with unused randomness and returns its sale value. Useful if `transfer(...)` is used instead of `convert(...)`
    /// @param transferAmount value will be added to balance before determining sale value
    function findSaleValue(uint256 transferAmount) public view returns (uint256) {
        for (uint256 height = max(block.number - 255, lastHeight + 1); height < block.number; height++) {
            uint256 rand = getRandomNumber(height);
            if (rand <= chance()) {
                return getSaleValue(rand, transferAmount);
            }
        }
        revert Trader__WrongHeight();
    }

    /// @notice Checks if a trade can be made at a specific block height based on randomness
    /// @dev Returns true if trade can be made at passed block height.
    function canTrade(uint256 height) public view returns (bool) {
        uint256 rand = getRandomNumber(height);
        return (rand <= chance());
    }

    /// @notice Checks if the mechanism has exceeded its spending budget at a specific block height
    /// @dev Returns true if mechanism is overspending. This may happen because randomness. Prevents mechanism from spending too much in a case of attack by a block producer.
    function hasOverspent(uint256 height) public view returns (bool) {
        if (height < spentResetBlock) return true;
        return spent > ((height - spentResetBlock) * budget) / (deadline - spentResetBlock);
    }

    /// @notice Returns upper bound of number of blocks enough to sold remaining budget.
    /// @dev Please note that in the worst case each trade amount will be `saleValueLow`.
    function getSafetyBlocks() public view returns (uint256) {
        return (budget - spent).divUp(saleValueLow);
    }

    /// @notice Returns probability of a trade normalized to [0, type(uint256).max] range
    /// @dev Probability of trade changes to make sure that contract will sell all of its budget before the deadline.
    function chance() public view returns (uint256) {
        uint256 safetyBlocks = getSafetyBlocks();
        if (deadline <= block.number + safetyBlocks) return type(uint256).max;
        uint256 avgSale = (saleValueLow + saleValueHigh) / 2;
        uint256 numberOfSales = (budget - spent).divUp(avgSale);
        uint256 blocks_left = remainingBlocks();
        if (blocks_left < numberOfSales) return type(uint256).max;
        //slither-disable-next-line divide-before-multiply
        else return (type(uint256).max / blocks_left) * numberOfSales;
    }

    /// @notice Number of blocks before deadline where probability of trade < 1
    /// @dev Due to the way this function is used, will return 0 if deadline has passed.
    function remainingBlocks() public view returns (uint256) {
        uint256 safety_blocks = getSafetyBlocks();
        if (block.number + safety_blocks > deadline) return 0;
        return deadline - block.number - safety_blocks;
    }

    /// @notice Get random value for particular blockchain height.
    /// @param height Height is block height to be used as a source of randomness. Will raise if called for blocks older than 256.
    /// @return a pseudorandom uint256 value in range [0, type(uint256).max]
    /// @dev Sourcing of randomness in this way enables tx inclusion in block which is different from block with randomness source. This prevents waste of gas on failed calls to `convert` even in absence of FlashBots-like infrastructure.
    function getRandomNumber(uint256 height) public view returns (uint256) {
        uint256 seed = uint256(blockhash(height));
        //slither-disable-next-line incorrect-equality incorrect-equality
        if (seed == 0) {
            revert Trader__RandomnessUnsafeSeed();
        }
        return apply_domain(seed);
    }

    /// @notice Applies domain transformation to a random seed value
    /// @dev Applies a domain separator to the given random seed. This function is intended to namespace the randomness to prevent cross-domain collisions.
    function apply_domain(uint256 seed) public pure returns (uint256) {
        return uint256(keccak256(abi.encode("Octant", seed)));
    }

    /// @notice Generates a uniform random number within a specified range
    /// @dev This function returns random value distributed uniformly in range [low, high).
    ///      Note, some values will not be chosen because of precision compromise.
    ///      Also, if high > 2**200, this function may overflow.
    /// @param low Low range of values returned
    function getUniformInRange(uint256 low, uint256 high, uint256 seed) public pure returns (uint256) {
        return low + (((high - low) * (apply_domain(seed) >> 200)) / 2 ** (256 - 200));
    }

    /// @dev This contract deals with native ETH, while Uniswap with WETH. This helper function does address conversion.
    function uniEthWrapper(address token) private view returns (address) {
        if (token == NATIVE_TOKEN) return WETH_ADDRESS;
        else return token;
    }

    /// @dev Simplifies checking of balance for ETH and ERC20 tokens. ETH is represented by a particular address.
    /// @return Balance of `token` currency associated with specified `owner`
    function safeBalanceOf(address token, address owner) private view returns (uint256) {
        if (token == NATIVE_TOKEN) {
            return owner.balance;
        } else {
            return IERC20(token).balanceOf(owner);
        }
    }

    /// @dev Returns sale value, in a range from [saleValueLow, saleValueHigh).
    ///      Returned value is capped so it doesn't exceed available funds.
    /// @param rand value of randomness for this height
    /// @param transferAmount value will be added to balance before determining sale value
    function getSaleValue(uint256 rand, uint256 transferAmount) private view returns (uint256 saleValue) {
        saleValue = getUniformInRange(saleValueLow, saleValueHigh, rand);
        if (saleValue > saleValueHigh) revert Trader__SoftwareError();

        uint256 balance = address(this).balance;
        if (BASE != NATIVE_TOKEN) {
            balance = IERC20(BASE).balanceOf(address(this));
        }

        if (saleValue > balance + transferAmount) {
            saleValue = balance + transferAmount;
        }
        if (saleValue > budget - spent) {
            saleValue = budget - spent;
        }
    }

    /// @dev This contract and Splits' Swapper use different addresses to represent ETH. This function does the conversion.
    function splitsEthWrapper(address token) private pure returns (address) {
        if (token == NATIVE_TOKEN) return address(0x0);
        else return token;
    }

    /// @dev Max function. Returns bigger of two unsigned integers.
    /// @param a first compared value
    /// @param b second compared value
    function max(uint256 a, uint256 b) private pure returns (uint256) {
        if (a > b) return a;
        else return b;
    }
}
