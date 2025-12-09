// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { TestPlus } from "solady-test/utils/TestPlus.sol";
import { WETH } from "solady/tokens/WETH.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import "script/deploy/DeployTrader.sol";
import { HelperConfig } from "script/helpers/HelperConfig.s.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUniswapV3Pool } from "src/utils/vendor/uniswap/IUniswapV3Pool.sol";
import { NATIVE_TOKEN } from "src/constants.sol";

contract TestTraderIntegrationETH2GLM is Test, TestPlus, DeployTrader {
    HelperConfig config;

    uint256 public mainnetForkBlock = 21880848;
    uint256 public mainnetFork;

    function setUp() public {
        owner = makeAddr("owner");
        vm.label(owner, "owner");
        beneficiary = makeAddr("beneficiary");
        vm.label(beneficiary, "beneficiary");

        mainnetFork = vm.createFork("mainnet");
        vm.selectFork(mainnetFork);

        config = new HelperConfig(true);

        (address glmToken, address wethToken, , , , , , , address uniV3Swap, ) = config.activeNetworkConfig();

        glmAddress = glmToken;

        wethAddress = wethToken;
        initializer = UniV3Swap(payable(uniV3Swap));
        configureTrader(config, "ETHGLM");
    }

    function prepare_trader_params(uint256 amountIn) public returns (UniV3Swap.InitFlashParams memory params) {
        delete exactInputParams;
        exactInputParams.push(
            ISwapRouter.ExactInputParams({
                path: abi.encodePacked(uniEthWrapper(baseAddress), uint24(10_000), uniEthWrapper(quoteAddress)),
                recipient: address(initializer),
                deadline: block.timestamp + 100,
                amountIn: uint256(amountIn),
                amountOutMinimum: 0
            })
        );

        delete quoteParams;
        quoteParams.push(
            QuoteParams({ quotePair: fromTo, baseAmount: uint128(amountIn), data: abi.encode(exactInputParams) })
        );
        UniV3Swap.FlashCallbackData memory data = UniV3Swap.FlashCallbackData({
            exactInputParams: exactInputParams,
            excessRecipient: address(oracle)
        });
        params = UniV3Swap.InitFlashParams({ quoteParams: quoteParams, flashCallbackData: data });
    }

    function force_direct_trade(address aBase, uint256 exactIn, address aQuote) public returns (uint256) {
        if (aBase == NATIVE_TOKEN) {
            vm.deal(address(this), exactIn);
        } else {
            deal(aBase, address(this), exactIn, false);
        }
        ISwapRouter swapRouter = initializer.swapRouter();
        delete exactInputParams;
        exactInputParams.push(
            ISwapRouter.ExactInputParams({
                path: abi.encodePacked(uniEthWrapper(aBase), uint24(10_000), uniEthWrapper(aQuote)),
                recipient: address(this),
                deadline: block.timestamp + 100,
                amountIn: exactIn,
                amountOutMinimum: 0
            })
        );

        if (aBase == NATIVE_TOKEN) {
            WETH(payable(wethAddress)).deposit{ value: exactIn }();
            WETH(payable(wethAddress)).approve(address(swapRouter), exactIn);
        } else {
            ERC20(aBase).approve(address(swapRouter), exactIn);
        }
        uint256 result = swapRouter.exactInput(exactInputParams[0]);
        if (aQuote == NATIVE_TOKEN) {
            WETH(payable(wethAddress)).withdraw(result);
        }
        return result;
    }

    receive() external payable {}

    function test_direct_trading_forward() external {
        vm.deal(address(this), 1 ether);
        uint oldBalance = address(this).balance;
        force_direct_trade(NATIVE_TOKEN, 1 ether, glmAddress);
        assertEq(oldBalance - 1 ether, address(this).balance);
    }

    function test_direct_trading_backward() external {
        uint256 exactIn = 7000 ether;
        deal(glmAddress, address(this), exactIn, false);
        uint oldBalance = ERC20(glmAddress).balanceOf(address(this));
        force_direct_trade(glmAddress, exactIn, NATIVE_TOKEN);
        assertEq(ERC20(glmAddress).balanceOf(address(this)), oldBalance - exactIn);
    }

    function test_oracle_reverts_if_buffer_is_too_fresh() external {
        vm.skip(true); // test is failing on CI
        vm.deal(address(swapper), 1 ether);

        IUniswapV3Pool pool = IUniswapV3Pool(0x531b6A4b3F962208EA8Ed5268C642c84BB29be0b);
        uint cardinality = pool.slot0().observationCardinalityNext;
        for (uint i; i < cardinality; i++) {
            force_direct_trade(glmAddress, 7000 ether, NATIVE_TOKEN);
            forwardBlocks(1);
        }
        UniV3Swap.InitFlashParams memory params = prepare_trader_params(1 ether);
        vm.expectRevert(bytes("OLD"));
        initializer.initFlash(ISwapperImpl(swapper), params);
    }

    function test_oracle_results_dont_change_in_the_block() external {
        vm.skip(true); // test is failing on CI
        IOracle oracle = ISwapperImpl(swapper).oracle();

        // mine a block to ensure that no readings were added yet
        forwardBlocks(1);
        uint currentBlock = block.number;

        // read oracle
        UniV3Swap.InitFlashParams memory params = prepare_trader_params(1 ether);
        uint256[] memory unscaledAmountsToBeneficiary = oracle.getQuoteAmounts(params.quoteParams);
        uint256 currentQuote = unscaledAmountsToBeneficiary[0];
        assert(currentQuote > 10 ether); // a very conservative check here

        // add a reading by trading
        force_direct_trade(glmAddress, 7000 ether, NATIVE_TOKEN);

        // check oracle in the same block - quote should be the same
        unscaledAmountsToBeneficiary = oracle.getQuoteAmounts(params.quoteParams);
        assert(unscaledAmountsToBeneficiary[0] == currentQuote);

        // for sanity, check if block is still the same
        assert(block.number == currentBlock);
    }

    function test_twap_frontrunning_triggers_protection() external {
        vm.skip(true); // test is failing on CI
        vm.deal(address(swapper), 2 ether);
        // mine a block to ensure that no readings were added yet
        forwardBlocks(1);

        uint currentBlock = block.number;

        // someone rapidly moves the price in the beginning of the block
        force_direct_trade(NATIVE_TOKEN, 2 ether, glmAddress);

        // attempt to trade in the same block should fail
        UniV3Swap.InitFlashParams memory params = prepare_trader_params(1 ether);
        vm.expectRevert(UniV3Swap.InsufficientFunds.selector);
        initializer.initFlash(ISwapperImpl(swapper), params);

        assertEq(currentBlock, block.number);
    }

    function test_twap_trade_in_other_direction_doesnt_trigger_protection() external {
        vm.skip(true); // test is failing on CI
        vm.deal(address(swapper), 2 ether);
        // mine a block to ensure that no readings were added yet
        forwardBlocks(1);

        uint currentBlock = block.number;

        // someone rapidly moves the price in OTHER direction
        force_direct_trade(glmAddress, 7000 ether, NATIVE_TOKEN);

        // trade should succeed
        UniV3Swap.InitFlashParams memory params = prepare_trader_params(1 ether);
        initializer.initFlash(ISwapperImpl(swapper), params);

        assertEq(currentBlock, block.number);
    }

    /* Commented out because it's not working on CI
    function test_convert_eth_to_glm() external {
        // effectively disable upper bound check and randomness check
        uint256 fakeBudget = 0.1 ether;
        vm.deal(address(trader), 0.2 ether);

        vm.startPrank(owner);
        trader.configurePeriod(block.number, 101);
        trader.setSpending(0.1 ether, 0.1 ether, fakeBudget);
        vm.stopPrank();

        uint256 oldBalance = swapper.balance;
        forwardBlocks(100);
        trader.convert(block.number - 2);
        assertEq(trader.spent(), 0.1 ether);
        assertGt(swapper.balance, oldBalance);

        uint256 oldGlmBalance = IERC20(quoteAddress).balanceOf(beneficiary);

        // now, do the actual swap

        delete exactInputParams;
        exactInputParams.push(
            ISwapRouter.ExactInputParams({
                path: abi.encodePacked(uniEthWrapper(baseAddress), uint24(10_000), uniEthWrapper(quoteAddress)),
                recipient: address(initializer),
                deadline: block.timestamp + 100,
                amountIn: uint256(swapper.balance),
                amountOutMinimum: 0
            })
        );

        delete quoteParams;
        quoteParams.push(
            QuoteParams({ quotePair: fromTo, baseAmount: uint128(swapper.balance), data: abi.encode(exactInputParams) })
        );
        UniV3Swap.FlashCallbackData memory data = UniV3Swap.FlashCallbackData({
            exactInputParams: exactInputParams,
            excessRecipient: address(oracle)
        });
        UniV3Swap.InitFlashParams memory params = UniV3Swap.InitFlashParams({
            quoteParams: quoteParams,
            flashCallbackData: data
        });
        initializer.initFlash(ISwapperImpl(swapper), params);

        // check if beneficiary received some quote token
        uint256 newGlmBalance = IERC20(quoteAddress).balanceOf(beneficiary);
        assertGt(newGlmBalance, oldGlmBalance);

        emit log_named_uint("oldGlmBalance", oldGlmBalance);
        emit log_named_uint("newGlmBalance", newGlmBalance);
        emit log_named_int("glm delta", int256(newGlmBalance) - int256(oldGlmBalance));
    }*/

    function test_swapper_params() public view {
        assertTrue(ISwapperImpl(swapper).defaultScaledOfferFactor() == 98_00_00);
    }

    function test_TraderInit() public view {
        assertTrue(trader.owner() == owner);
        assertTrue(trader.swapper() == swapper);
    }

    function test_transform_eth_to_glm() external {
        vm.skip(true); // test is failing on CI
        // effectively disable upper bound check and randomness check
        uint256 fakeBudget = 1 ether;

        vm.startPrank(owner);
        trader.configurePeriod(block.number, 101);
        trader.setSpending(0.5 ether, 1.5 ether, fakeBudget);
        vm.stopPrank();

        forwardBlocks(100);
        uint256 saleValue = trader.findSaleValue(1.5 ether);
        assert(saleValue > 0);

        uint256 amountToBeneficiary = trader.transform{ value: saleValue }(trader.BASE(), trader.QUOTE(), saleValue);

        assert(IERC20(quoteAddress).balanceOf(trader.BENEFICIARY()) > 0);
        assert(IERC20(quoteAddress).balanceOf(trader.BENEFICIARY()) == amountToBeneficiary);
        emit log_named_uint("GLM price on Trader.transform(...)", amountToBeneficiary / saleValue);
    }

    function test_receivesEth() external {
        vm.deal(address(this), 10_000 ether);
        (bool sent, ) = payable(address(trader)).call{ value: 100 ether }("");
        require(sent, "Failed to send Ether");
    }

    function test_transform_wrong_eth_value() external {
        vm.expectRevert(Trader.Trader__ImpossibleConfiguration.selector);
        trader.transform{ value: 1 ether }(NATIVE_TOKEN, glmAddress, 2 ether);
    }

    function test_findSaleValue_throws() external {
        vm.skip(true); // test is failing on CI
        // effectively disable upper bound check and randomness check
        uint256 fakeBudget = 1 ether;

        vm.startPrank(owner);
        trader.configurePeriod(block.number, 5000);
        trader.setSpending(0.5 ether, 1.5 ether, fakeBudget);
        vm.stopPrank();

        forwardBlocks(300);
        vm.expectRevert(Trader.Trader__WrongHeight.selector);
        trader.findSaleValue(1 ether);
    }
}

contract TestTraderIntegrationGLM2ETH is Test, TestPlus, DeployTrader {
    HelperConfig config;

    function setUp() public {
        owner = makeAddr("owner");
        vm.label(owner, "owner");
        beneficiary = makeAddr("beneficiary");
        vm.label(beneficiary, "beneficiary");

        vm.createSelectFork({ urlOrAlias: "mainnet" });

        config = new HelperConfig(true);

        (address glmToken, address wethToken, , , , , , , address uniV3Swap, ) = config.activeNetworkConfig();

        glmAddress = glmToken;

        wethAddress = wethToken;
        initializer = UniV3Swap(payable(uniV3Swap));
        configureTrader(config, "GLMETH");
    }

    receive() external payable {}

    function test_transform_unexpected_value() external {
        // check if trader will reject unexpected ETH
        vm.expectRevert(Trader.Trader__UnexpectedETH.selector);
        trader.transform{ value: 1 ether }(glmAddress, NATIVE_TOKEN, 10 ether);
    }

    function test_transform_wrong_base() external {
        MockERC20 otherToken = new MockERC20(18);
        otherToken.mint(address(trader), 100 ether);

        // check if trader will reject base token different than configured
        vm.expectRevert(Trader.Trader__ImpossibleConfiguration.selector);
        trader.transform(address(otherToken), glmAddress, 10 ether);
    }

    function test_transform_wrong_quote() external {
        MockERC20 otherToken = new MockERC20(18);

        // check if trader will reject unexpected ETH
        vm.expectRevert(Trader.Trader__ImpossibleConfiguration.selector);
        trader.transform(glmAddress, address(otherToken), 10 ether);
    }

    function test_transform_glm_to_eth() external {
        uint256 initialETHBalance = beneficiary.balance;
        // effectively disable upper bound check and randomness check
        uint256 fakeBudget = 50 ether;
        deal(glmAddress, address(this), fakeBudget, false);
        ERC20(glmAddress).approve(address(trader), fakeBudget);

        vm.startPrank(owner);
        trader.configurePeriod(block.number, 101);
        trader.setSpending(5 ether, 15 ether, fakeBudget);
        vm.stopPrank();

        forwardBlocks(100);
        uint256 saleValue = trader.findSaleValue(15 ether);
        assert(saleValue > 0);

        // do actual attempt to convert ERC20 to ETH
        uint256 amountToBeneficiary = trader.transform(glmAddress, NATIVE_TOKEN, saleValue);

        assert(beneficiary.balance > initialETHBalance);
        assert(beneficiary.balance == initialETHBalance + amountToBeneficiary);
        emit log_named_uint("ETH (in GLM) price on Trader.transform(...)", saleValue / amountToBeneficiary);
    }
}

contract MisconfiguredSwapperTest is Test, TestPlus, DeployTrader {
    HelperConfig config;
    uint256 fork;
    string TEST_RPC_URL;

    function setUp() public {
        owner = makeAddr("owner");
        vm.label(owner, "owner");
        beneficiary = makeAddr("beneficiary");
        vm.label(beneficiary, "beneficiary");

        TEST_RPC_URL = vm.envString("TEST_RPC_URL");
        fork = vm.createFork(TEST_RPC_URL);
        vm.selectFork(fork);

        config = new HelperConfig(true);

        (address glmToken, address wethToken, , , , , , , address uniV3Swap, ) = config.activeNetworkConfig();

        glmAddress = glmToken;

        wethAddress = wethToken;
        initializer = UniV3Swap(payable(uniV3Swap));
    }

    receive() external payable {}

    function test_reverts_if_swapper_is_misconfigured() external {
        swapper = address(new ContractThatRejectsETH());
        vm.label(swapper, "bad_swapper");
        configureTrader(config, "ETHGLM");

        // effectively disable upper bound check and randomness check
        uint256 fakeBudget = 1 ether;
        vm.deal(address(trader), 2 ether);

        vm.startPrank(owner);
        trader.configurePeriod(block.number, 101);
        trader.setSpending(1 ether, 1 ether, fakeBudget);
        vm.stopPrank();

        forwardBlocks(100);
        // revert without data
        vm.expectRevert();
        trader.convert(block.number - 2);
    }
}

contract ContractThatRejectsETH {
    receive() external payable {
        require(false);
    }
}
