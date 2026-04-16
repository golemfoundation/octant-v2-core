// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import { PSMSwapper } from "src/swappers/PSMSwapper.sol";
import { IPSM, IExchange } from "src/strategies/interfaces/IPSM.sol";

contract PSMSwapperTest is Test {
    ERC20Mock public gem; // e.g., USDC (6 decimals conceptually, but ERC20Mock uses 18)
    ERC20Mock public dai;
    ERC20Mock public usds;

    address public protocol = address(0xABC1);
    address public exchange = address(0xABC2);
    address public receiver = address(0xBEEF);

    uint256 internal constant WAD = 1e18;
    uint256 internal constant CONVERSION_FACTOR = 1e12; // 6 -> 18 decimal conversion

    function setUp() public {
        gem = new ERC20Mock();
        dai = new ERC20Mock();
        usds = new ERC20Mock();

        vm.label(address(gem), "GEM");
        vm.label(address(dai), "DAI");
        vm.label(address(usds), "USDS");
        vm.label(protocol, "PSM");
        vm.label(exchange, "DaiUsdsExchange");
        vm.label(receiver, "Receiver");
    }

    // ═══════════════════════════════════════════════════════════
    // CONSTRUCTOR TESTS
    // ═══════════════════════════════════════════════════════════

    function test_constructor_setsImmutables() public {
        PSMSwapper s = new PSMSwapper(protocol, PSMSwapper.Route.SELL_GEM, address(gem), address(dai), 0);
        assertEq(s.protocol(), protocol);
        assertEq(uint8(s.route()), uint8(PSMSwapper.Route.SELL_GEM));
        assertEq(s.tokenIn(), address(gem));
        assertEq(s.tokenOut(), address(dai));
        assertEq(s.conversionFactor(), 0);
    }

    function test_constructor_revertsOnZeroProtocol() public {
        vm.expectRevert(PSMSwapper.InvalidProtocol.selector);
        new PSMSwapper(address(0), PSMSwapper.Route.SELL_GEM, address(gem), address(dai), 0);
    }

    function test_constructor_revertsOnZeroTokenIn() public {
        vm.expectRevert(PSMSwapper.InvalidToken.selector);
        new PSMSwapper(protocol, PSMSwapper.Route.SELL_GEM, address(0), address(dai), 0);
    }

    function test_constructor_revertsOnZeroTokenOut() public {
        vm.expectRevert(PSMSwapper.InvalidToken.selector);
        new PSMSwapper(protocol, PSMSwapper.Route.SELL_GEM, address(gem), address(0), 0);
    }

    function test_constructor_revertsOnZeroConversionFactorForBuyGem() public {
        vm.expectRevert(PSMSwapper.InvalidConversionFactor.selector);
        new PSMSwapper(protocol, PSMSwapper.Route.BUY_GEM, address(dai), address(gem), 0);
    }

    function test_constructor_allowsZeroConversionFactorForNonBuyGemRoutes() public {
        // SELL_GEM, DAI_TO_USDS, USDS_TO_DAI should all accept conversionFactor = 0
        new PSMSwapper(protocol, PSMSwapper.Route.SELL_GEM, address(gem), address(dai), 0);
        new PSMSwapper(protocol, PSMSwapper.Route.DAI_TO_USDS, address(dai), address(usds), 0);
        new PSMSwapper(protocol, PSMSwapper.Route.USDS_TO_DAI, address(usds), address(dai), 0);
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — TOKEN MISMATCH
    // ═══════════════════════════════════════════════════════════

    function test_swap_revertsOnTokenInMismatch() public {
        PSMSwapper s = new PSMSwapper(protocol, PSMSwapper.Route.SELL_GEM, address(gem), address(dai), 0);
        vm.expectRevert(PSMSwapper.InvalidToken.selector);
        s.swap(address(0xDEAD), address(dai), 100, 0, receiver);
    }

    function test_swap_revertsOnTokenOutMismatch() public {
        PSMSwapper s = new PSMSwapper(protocol, PSMSwapper.Route.SELL_GEM, address(gem), address(dai), 0);
        vm.expectRevert(PSMSwapper.InvalidToken.selector);
        s.swap(address(gem), address(0xDEAD), 100, 0, receiver);
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — INSUFFICIENT OUTPUT
    // ═══════════════════════════════════════════════════════════

    // ═══════════════════════════════════════════════════════════
    // SWAP — FULL ROUTE TESTS (using mock PSM/Exchange)
    // ═══════════════════════════════════════════════════════════

    function test_swap_sellGem_route() public {
        MockPSM mockPSM = new MockPSM(address(gem), address(dai));
        PSMSwapper s = new PSMSwapper(address(mockPSM), PSMSwapper.Route.SELL_GEM, address(gem), address(dai), 0);

        uint256 amountIn = 1000e18;
        gem.mint(address(s), amountIn);

        uint256 amountOut = s.swap(address(gem), address(dai), amountIn, 0, receiver);

        assertEq(amountOut, (amountIn * WAD) / WAD, "SELL_GEM: output should match 1:1");
        assertEq(dai.balanceOf(receiver), amountOut, "Receiver should have DAI");
    }

    function test_swap_buyGem_route() public {
        MockPSM mockPSM = new MockPSM(address(dai), address(gem));
        mockPSM.setTout(0); // 0% fee

        PSMSwapper s = new PSMSwapper(
            address(mockPSM),
            PSMSwapper.Route.BUY_GEM,
            address(dai),
            address(gem),
            CONVERSION_FACTOR
        );

        uint256 amountIn = 1000e18;
        dai.mint(address(s), amountIn);

        uint256 amountOut = s.swap(address(dai), address(gem), amountIn, 0, receiver);

        // gemAmt = amountIn * WAD / (CONVERSION_FACTOR * (WAD + 0)) = 1000e18 / 1e12 = 1000e6
        uint256 expectedGemAmt = (amountIn * WAD) / (CONVERSION_FACTOR * WAD);
        assertEq(amountOut, expectedGemAmt, "BUY_GEM: output should match fee-adjusted amount");
        assertEq(gem.balanceOf(receiver), amountOut, "Receiver should have gem");
    }

    function test_swap_buyGem_withFee() public {
        MockPSM mockPSM = new MockPSM(address(dai), address(gem));
        uint256 tout = 0.01e18; // 1% fee
        mockPSM.setTout(tout);

        PSMSwapper s = new PSMSwapper(
            address(mockPSM),
            PSMSwapper.Route.BUY_GEM,
            address(dai),
            address(gem),
            CONVERSION_FACTOR
        );

        uint256 amountIn = 1000e18;
        dai.mint(address(s), amountIn);

        uint256 amountOut = s.swap(address(dai), address(gem), amountIn, 0, receiver);

        uint256 expectedGemAmt = (amountIn * WAD) / (CONVERSION_FACTOR * (WAD + tout));
        assertEq(amountOut, expectedGemAmt, "BUY_GEM with fee: output should be fee-adjusted");
        assertEq(gem.balanceOf(receiver), amountOut, "Receiver should have gem");
    }

    function test_swap_daiToUsds_route() public {
        MockExchange mockExchange = new MockExchange(address(dai), address(usds));
        PSMSwapper s = new PSMSwapper(
            address(mockExchange),
            PSMSwapper.Route.DAI_TO_USDS,
            address(dai),
            address(usds),
            0
        );

        uint256 amountIn = 1000e18;
        dai.mint(address(s), amountIn);

        // minAmountOut = amountIn: 1:1 conversion, exact output enforced internally
        uint256 amountOut = s.swap(address(dai), address(usds), amountIn, amountIn, receiver);

        assertEq(amountOut, amountIn, "DAI_TO_USDS: should be 1:1");
        assertEq(usds.balanceOf(receiver), amountIn, "Receiver should have USDS");
    }

    function test_swap_usdsToDai_route() public {
        MockExchange mockExchange = new MockExchange(address(usds), address(dai));
        PSMSwapper s = new PSMSwapper(
            address(mockExchange),
            PSMSwapper.Route.USDS_TO_DAI,
            address(usds),
            address(dai),
            0
        );

        uint256 amountIn = 1000e18;
        usds.mint(address(s), amountIn);

        // minAmountOut = amountIn: 1:1 conversion, exact output enforced internally
        uint256 amountOut = s.swap(address(usds), address(dai), amountIn, amountIn, receiver);

        assertEq(amountOut, amountIn, "USDS_TO_DAI: should be 1:1");
        assertEq(dai.balanceOf(receiver), amountIn, "Receiver should have DAI");
    }

    function test_swap_buyGem_insufficientOutput() public {
        MockPSM mockPSM = new MockPSM(address(dai), address(gem));
        mockPSM.setTout(0);

        PSMSwapper s = new PSMSwapper(
            address(mockPSM),
            PSMSwapper.Route.BUY_GEM,
            address(dai),
            address(gem),
            CONVERSION_FACTOR
        );

        uint256 amountIn = 1000e18;
        dai.mint(address(s), amountIn);

        // Expected gem = 1000e6, require more
        uint256 tooHigh = 2000e6;
        vm.expectRevert(abi.encodeWithSelector(PSMSwapper.InsufficientOutput.selector, tooHigh, 1000e6));
        s.swap(address(dai), address(gem), amountIn, tooHigh, receiver);
    }

    function test_swap_buyGem_revertsOnZeroGemAmt() public {
        MockPSM mockPSM = new MockPSM(address(dai), address(gem));
        mockPSM.setTout(0);

        PSMSwapper s = new PSMSwapper(
            address(mockPSM),
            PSMSwapper.Route.BUY_GEM,
            address(dai),
            address(gem),
            CONVERSION_FACTOR
        );

        // amountIn too small: 999 wei of DAI with 1e12 conversion = gemAmt truncates to 0
        uint256 tinyAmount = CONVERSION_FACTOR - 1;
        dai.mint(address(s), tinyAmount);

        vm.expectRevert(abi.encodeWithSelector(PSMSwapper.InsufficientOutput.selector, 1, 0));
        s.swap(address(dai), address(gem), tinyAmount, 0, receiver);
    }

    function test_swap_daiToUsds_ignoresCallerMinAmountOut() public {
        MockExchange mockExchange = new MockExchange(address(dai), address(usds));
        PSMSwapper s = new PSMSwapper(
            address(mockExchange),
            PSMSwapper.Route.DAI_TO_USDS,
            address(dai),
            address(usds),
            0
        );

        uint256 amountIn = 1000e18;
        dai.mint(address(s), amountIn);

        // Caller passes 0 as minAmountOut, but contract enforces amountIn internally
        uint256 amountOut = s.swap(address(dai), address(usds), amountIn, 0, receiver);
        assertEq(amountOut, amountIn, "1:1 enforced regardless of caller minAmountOut");
    }

    function test_swap_usdsToDai_ignoresCallerMinAmountOut() public {
        MockExchange mockExchange = new MockExchange(address(usds), address(dai));
        PSMSwapper s = new PSMSwapper(
            address(mockExchange),
            PSMSwapper.Route.USDS_TO_DAI,
            address(usds),
            address(dai),
            0
        );

        uint256 amountIn = 1000e18;
        usds.mint(address(s), amountIn);

        // Caller passes 0 as minAmountOut, but contract enforces amountIn internally
        uint256 amountOut = s.swap(address(usds), address(dai), amountIn, 0, receiver);
        assertEq(amountOut, amountIn, "1:1 enforced regardless of caller minAmountOut");
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — RESIDUAL DUST FLUSH
    // ═══════════════════════════════════════════════════════════

    /// @dev Regression test for residual tokenIn dust. Under a non-zero PSM fee (`tout`), floor
    ///      division in `_buyGem` means PSM pulls less DAI than `amountIn`; the leftover
    ///      must be flushed back to `msg.sender` so the adapter does not accumulate dust
    ///      that a later caller could sweep via `swap(..., receiver=self)`.
    function test_swap_buyGem_flushesResidualToMsgSender() public {
        MockPSM mockPSM = new MockPSM(address(dai), address(gem));
        uint256 tout = 0.01e18; // 1% fee — triggers non-trivial floor-division remainder
        mockPSM.setTout(tout);
        // Enable real-PSM behavior: mock now pulls the exact DAI charge via transferFrom.
        mockPSM.setConversionFactor(CONVERSION_FACTOR);

        PSMSwapper s = new PSMSwapper(
            address(mockPSM),
            PSMSwapper.Route.BUY_GEM,
            address(dai),
            address(gem),
            CONVERSION_FACTOR
        );

        uint256 amountIn = 1000e18;
        dai.mint(address(s), amountIn);

        // Compute the exact DAI amount PSM will pull — leftover is the residual dust.
        uint256 gemAmt = (amountIn * WAD) / (CONVERSION_FACTOR * (WAD + tout));
        uint256 pulled = (gemAmt * CONVERSION_FACTOR * (WAD + tout)) / WAD;
        uint256 dust = amountIn - pulled;
        assertGt(dust, 0, "pre-check: non-zero dust expected for this scenario");

        uint256 callerBalBefore = dai.balanceOf(address(this));

        s.swap(address(dai), address(gem), amountIn, 0, receiver);

        assertEq(dai.balanceOf(address(s)), 0, "swapper must hold zero tokenIn between calls");
        assertEq(dai.balanceOf(address(this)), callerBalBefore + dust, "residual dust must be returned to msg.sender");
        assertEq(gem.balanceOf(receiver), gemAmt, "receiver gets the gem output");
    }

    /// @dev The residual flush must also zero-out `_sellGem` (defense-in-depth). On the
    ///      happy path PSM consumes the full amount, but unconditional flushing keeps the
    ///      adapter caller-agnostic and closes any future edge case.
    function test_swap_sellGem_flushesAnyResidualToMsgSender() public {
        MockPSM mockPSM = new MockPSM(address(gem), address(dai));
        PSMSwapper s = new PSMSwapper(address(mockPSM), PSMSwapper.Route.SELL_GEM, address(gem), address(dai), 0);

        uint256 amountIn = 1000e18;
        gem.mint(address(s), amountIn);

        // Seed pre-existing dust that would have been strandable under the old adapter.
        uint256 preExistingDust = 7 wei;
        gem.mint(address(s), preExistingDust);

        uint256 callerBalBefore = gem.balanceOf(address(this));

        s.swap(address(gem), address(dai), amountIn, 0, receiver);

        assertEq(gem.balanceOf(address(s)), 0, "swapper must hold zero tokenIn between calls");
        assertEq(
            gem.balanceOf(address(this)),
            callerBalBefore + preExistingDust,
            "pre-existing dust must be flushed to msg.sender"
        );
    }

    /// @dev Flush in `_daiToUsds` is a defensive no-op on the happy path; this test
    ///      seeds pre-existing dust and verifies the flush drains it.
    function test_swap_daiToUsds_flushesAnyResidualToMsgSender() public {
        MockExchange mockExchange = new MockExchange(address(dai), address(usds));
        PSMSwapper s = new PSMSwapper(
            address(mockExchange),
            PSMSwapper.Route.DAI_TO_USDS,
            address(dai),
            address(usds),
            0
        );

        uint256 amountIn = 1000e18;
        dai.mint(address(s), amountIn);

        uint256 preExistingDust = 3 wei;
        dai.mint(address(s), preExistingDust);

        uint256 callerBalBefore = dai.balanceOf(address(this));

        s.swap(address(dai), address(usds), amountIn, amountIn, receiver);

        assertEq(dai.balanceOf(address(s)), 0, "swapper must hold zero tokenIn between calls");
        assertEq(
            dai.balanceOf(address(this)),
            callerBalBefore + preExistingDust,
            "pre-existing dust must be flushed to msg.sender"
        );
    }

    /// @dev Flush in `_usdsToDai` is a defensive no-op on the happy path; this test
    ///      seeds pre-existing dust and verifies the flush drains it.
    function test_swap_usdsToDai_flushesAnyResidualToMsgSender() public {
        MockExchange mockExchange = new MockExchange(address(usds), address(dai));
        PSMSwapper s = new PSMSwapper(
            address(mockExchange),
            PSMSwapper.Route.USDS_TO_DAI,
            address(usds),
            address(dai),
            0
        );

        uint256 amountIn = 1000e18;
        usds.mint(address(s), amountIn);

        uint256 preExistingDust = 5 wei;
        usds.mint(address(s), preExistingDust);

        uint256 callerBalBefore = usds.balanceOf(address(this));

        s.swap(address(usds), address(dai), amountIn, amountIn, receiver);

        assertEq(usds.balanceOf(address(s)), 0, "swapper must hold zero tokenIn between calls");
        assertEq(
            usds.balanceOf(address(this)),
            callerBalBefore + preExistingDust,
            "pre-existing dust must be flushed to msg.sender"
        );
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — NON-1:1 CONVERSION REVERT
    // ═══════════════════════════════════════════════════════════

    function test_swap_daiToUsds_revertsOnNonOneToOne() public {
        MockExchange mockExchange = new MockExchange(address(dai), address(usds));
        mockExchange.setSkim(1); // converter returns 1 wei less than expected
        PSMSwapper s = new PSMSwapper(
            address(mockExchange),
            PSMSwapper.Route.DAI_TO_USDS,
            address(dai),
            address(usds),
            0
        );

        uint256 amountIn = 1000e18;
        dai.mint(address(s), amountIn);

        vm.expectRevert(abi.encodeWithSelector(PSMSwapper.NonOneToOneConversion.selector, amountIn, amountIn - 1));
        s.swap(address(dai), address(usds), amountIn, 0, receiver);
    }

    function test_swap_usdsToDai_revertsOnNonOneToOne() public {
        MockExchange mockExchange = new MockExchange(address(usds), address(dai));
        mockExchange.setSkim(1); // converter returns 1 wei less than expected
        PSMSwapper s = new PSMSwapper(
            address(mockExchange),
            PSMSwapper.Route.USDS_TO_DAI,
            address(usds),
            address(dai),
            0
        );

        uint256 amountIn = 1000e18;
        usds.mint(address(s), amountIn);

        vm.expectRevert(abi.encodeWithSelector(PSMSwapper.NonOneToOneConversion.selector, amountIn, amountIn - 1));
        s.swap(address(usds), address(dai), amountIn, 0, receiver);
    }
}

// ═══════════════════════════════════════════════════════════
// MOCK CONTRACTS
// ═══════════════════════════════════════════════════════════

/// @dev Mock PSM that simulates sellGem and buyGem
contract MockPSM {
    uint256 internal constant WAD = 1e18;

    ERC20Mock public tokenIn;
    ERC20Mock public tokenOut;
    uint256 public tout_;
    uint256 public conversionFactor;

    constructor(address _tokenIn, address _tokenOut) {
        tokenIn = ERC20Mock(_tokenIn);
        tokenOut = ERC20Mock(_tokenOut);
    }

    function setTout(uint256 _tout) external {
        tout_ = _tout;
    }

    /// @dev Optional: set the gem-to-DAI conversion factor so buyGem pulls the exact
    ///      DAI amount real LitePSM would charge. Default 0 preserves legacy mock
    ///      behavior (no DAI pull) for tests that don't care about the pull pattern.
    function setConversionFactor(uint256 _conversionFactor) external {
        conversionFactor = _conversionFactor;
    }

    function tout() external view returns (uint256) {
        return tout_;
    }

    /// @dev sellGem: caller sends gem, PSM mints DAI/USDS to caller (1:1 at 18 decimals)
    function sellGem(address usr, uint256 gemAmt) external {
        // Pull gem from caller
        tokenIn.transferFrom(msg.sender, address(this), gemAmt);
        // Mint output to usr (caller is the swapper contract, usr is the swapper too)
        tokenOut.mint(usr, gemAmt);
    }

    /// @dev buyGem: caller sends DAI, PSM sends gem to caller. If `conversionFactor`
    ///      is set, pulls the exact DAI charge `gemAmt * conversionFactor * (WAD + tout) / WAD`
    ///      from msg.sender -- matching real LitePSM behavior.
    function buyGem(address usr, uint256 gemAmt) external {
        if (conversionFactor != 0) {
            uint256 daiAmt = (gemAmt * conversionFactor * (WAD + tout_)) / WAD;
            tokenIn.transferFrom(msg.sender, address(this), daiAmt);
        }
        tokenOut.mint(usr, gemAmt);
    }
}

/// @dev Mock DaiUsds Exchange that simulates 1:1 conversion (with optional skim for testing)
contract MockExchange {
    ERC20Mock public tokenIn;
    ERC20Mock public tokenOut;
    uint256 public skim; // amount to withhold from output (0 = perfect 1:1)

    constructor(address _tokenIn, address _tokenOut) {
        tokenIn = ERC20Mock(_tokenIn);
        tokenOut = ERC20Mock(_tokenOut);
    }

    function setSkim(uint256 _skim) external {
        skim = _skim;
    }

    /// @dev DAI -> USDS: pull DAI from caller, mint USDS to usr
    function daiToUsds(address usr, uint256 wad) external {
        tokenIn.transferFrom(msg.sender, address(this), wad);
        tokenOut.mint(usr, wad - skim);
    }

    /// @dev USDS -> DAI: pull USDS from caller, mint DAI to usr
    function usdsToDai(address usr, uint256 wad) external {
        tokenIn.transferFrom(msg.sender, address(this), wad);
        tokenOut.mint(usr, wad - skim);
    }
}
