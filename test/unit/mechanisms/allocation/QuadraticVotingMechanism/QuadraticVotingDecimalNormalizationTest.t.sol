// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { QuadraticVotingMechanism } from "src/mechanisms/mechanism/QuadraticVotingMechanism.sol";
import { AllocationMechanismFactory } from "src/mechanisms/AllocationMechanismFactory.sol";
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mock ERC20 with configurable decimals
contract MockToken is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title Quadratic Voting Decimal Normalization Test
/// @notice Tests that calculateOptimalAlpha() works correctly with tokens of different decimal configurations
/// @dev Demonstrates the fix for the decimal normalization bug where compareOptimalAlpha() would
///      incorrectly compare raw token amounts with 18-decimal normalized quadratic/linear sums
contract QuadraticVotingDecimalNormalizationTest is Test {
    AllocationMechanismFactory factory;
    MockToken token6Decimals; // USDC-like token
    MockToken token18Decimals; // ETH-like token
    MockToken token8Decimals; // WBTC-like token

    QuadraticVotingMechanism mechanism6;
    QuadraticVotingMechanism mechanism18;
    QuadraticVotingMechanism mechanism8;

    address alice = address(0x1);
    address bob = address(0x2);
    address charlie = address(0x3);
    address projectA = address(0xA);
    address projectB = address(0xB);

    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant TIMELOCK_DELAY = 1 days;
    uint256 constant GRACE_PERIOD = 7 days;
    uint256 constant QUORUM_REQUIREMENT = 100 ether; // In 18 decimals

    function _tokenized(address _mechanism) internal pure returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(_mechanism);
    }

    function setUp() public {
        factory = new AllocationMechanismFactory();

        // Create tokens with different decimal configurations
        token6Decimals = new MockToken("USDC", "USDC", 6);
        token18Decimals = new MockToken("ETH", "ETH", 18);
        token8Decimals = new MockToken("WBTC", "WBTC", 8);

        // Deploy mechanisms for each token type
        mechanism6 = _deployMechanism(token6Decimals);
        mechanism18 = _deployMechanism(token18Decimals);
        mechanism8 = _deployMechanism(token8Decimals);

        // Fund users with equivalent amounts in each token's decimals
        _fundUsers();
    }

    function _deployMechanism(MockToken token) internal returns (QuadraticVotingMechanism) {
        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: string.concat("QV Mechanism ", token.symbol()),
            symbol: string.concat("QV", token.symbol()),
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: QUORUM_REQUIREMENT,
            timelockDelay: TIMELOCK_DELAY,
            gracePeriod: GRACE_PERIOD,
            owner: address(this)
        });

        address mechanismAddr = factory.deployQuadraticVotingMechanism(config, 1, 2); // Alpha = 0.5
        return QuadraticVotingMechanism(payable(mechanismAddr));
    }

    function _fundUsers() internal {
        // Fund with equivalent amounts:
        // 6 decimals: 1000 USDC = 1000 * 10^6
        // 18 decimals: 1000 ETH = 1000 * 10^18
        // 8 decimals: 1000 WBTC = 1000 * 10^8

        uint256 amount6 = 1000 * 10 ** 6; // 1000 USDC
        uint256 amount18 = 1000 * 10 ** 18; // 1000 ETH
        uint256 amount8 = 1000 * 10 ** 8; // 1000 WBTC

        // Fund each user for each token
        address[3] memory users = [alice, bob, charlie];
        for (uint i = 0; i < users.length; i++) {
            token6Decimals.mint(users[i], amount6 * 10); // Extra for testing
            token18Decimals.mint(users[i], amount18 * 10);
            token8Decimals.mint(users[i], amount8 * 10);
        }
    }

    /// @notice Test that calculateOptimalAlpha produces consistent results across different decimal tokens
    /// @dev This test demonstrates the fix for the decimal normalization bug
    function testCalculateOptimalAlpha_DecimalNormalization() public {
        console.log("=== Decimal Normalization Test ===");

        // Setup: Register users and create proposals for each mechanism
        _setupVotingScenario(mechanism6, token6Decimals, 1000 * 10 ** 6); // 1000 USDC
        _setupVotingScenario(mechanism18, token18Decimals, 1000 * 10 ** 18); // 1000 ETH
        _setupVotingScenario(mechanism8, token8Decimals, 1000 * 10 ** 8); // 1000 WBTC

        // Cast equivalent votes on each mechanism
        _castEquivalentVotes();

        // Test calculateOptimalAlpha with equivalent amounts
        uint256 matchingPool6 = 5000 * 10 ** 6; // 5000 USDC
        uint256 matchingPool18 = 5000 * 10 ** 18; // 5000 ETH
        uint256 matchingPool8 = 5000 * 10 ** 8; // 5000 WBTC

        uint256 userDeposits6 = 3000 * 10 ** 6; // 3000 USDC
        uint256 userDeposits18 = 3000 * 10 ** 18; // 3000 ETH
        uint256 userDeposits8 = 3000 * 10 ** 8; // 3000 WBTC

        console.log("\n--- Calculate Optimal Alpha for Each Token ---");

        // Calculate optimal alpha for each mechanism
        (uint256 alpha6Num, uint256 alpha6Den) = mechanism6.calculateOptimalAlpha(matchingPool6, userDeposits6);
        (uint256 alpha18Num, uint256 alpha18Den) = mechanism18.calculateOptimalAlpha(matchingPool18, userDeposits18);
        (uint256 alpha8Num, uint256 alpha8Den) = mechanism8.calculateOptimalAlpha(matchingPool8, userDeposits8);

        console.log("6-decimal token (USDC) alpha:", alpha6Num, "/", alpha6Den);
        console.log("18-decimal token (ETH) alpha:", alpha18Num, "/", alpha18Den);
        console.log("8-decimal token (WBTC) alpha:", alpha8Num, "/", alpha8Den);

        // Assert that all mechanisms produce equivalent alpha ratios
        // They should be identical since we're using equivalent amounts
        uint256 alpha6Ratio = (alpha6Num * 1e18) / alpha6Den;
        uint256 alpha18Ratio = (alpha18Num * 1e18) / alpha18Den;
        uint256 alpha8Ratio = (alpha8Num * 1e18) / alpha8Den;

        console.log("6-decimal alpha ratio (scaled):", alpha6Ratio);
        console.log("18-decimal alpha ratio (scaled):", alpha18Ratio);
        console.log("8-decimal alpha ratio (scaled):", alpha8Ratio);

        // Verify consistency across all decimal configurations
        // Allow for small rounding differences due to decimal precision
        uint256 tolerance = 1e15; // 0.1% tolerance

        assertApproxEqAbs(alpha6Ratio, alpha18Ratio, tolerance, "6-decimal and 18-decimal alpha should be equivalent");
        assertApproxEqAbs(alpha18Ratio, alpha8Ratio, tolerance, "18-decimal and 8-decimal alpha should be equivalent");
        assertApproxEqAbs(alpha6Ratio, alpha8Ratio, tolerance, "6-decimal and 8-decimal alpha should be equivalent");

        console.log("SUCCESS: All decimal configurations produce consistent alpha calculations!");
    }

    /// @notice Test edge case where assets are insufficient for linear funding with low-decimal tokens
    /// @dev Before the fix, this would incorrectly always choose alpha=0 for tokens with < 18 decimals
    function testCalculateOptimalAlpha_InsufficientAssets_LowDecimalToken() public {
        console.log("=== Insufficient Assets Test - Low Decimal Token ===");

        // Setup with USDC (6 decimals)
        _setupVotingScenario(mechanism6, token6Decimals, 1000 * 10 ** 6);
        _castVotesOnMechanism(mechanism6);

        // Use very small matching pool and user deposits (in raw token amounts)
        uint256 smallMatchingPool = 100 * 10 ** 6; // 100 USDC
        uint256 smallUserDeposits = 50 * 10 ** 6; // 50 USDC

        uint256 linearSum = mechanism6.totalLinearSum();
        uint256 totalAssets = smallMatchingPool + smallUserDeposits;

        console.log("Linear sum (18 decimals):", linearSum);
        console.log("Total assets (6 decimals):", totalAssets);
        console.log("Total assets normalized (18 decimals):", totalAssets * 10 ** 12);

        (uint256 alphaNumerator, uint256 alphaDenominator) = mechanism6.calculateOptimalAlpha(
            smallMatchingPool,
            smallUserDeposits
        );

        console.log("Calculated alpha:", alphaNumerator, "/", alphaDenominator);

        // Before the fix: would always return alpha=0 because totalAssets (1.5e8) <= linearSum (~1e18+)
        // After the fix: should calculate proper alpha based on normalized amounts

        if (totalAssets * 10 ** 12 <= linearSum) {
            // If truly insufficient assets, should return alpha=0
            assertEq(alphaNumerator, 0, "Should return alpha=0 when assets insufficient");
            assertEq(alphaDenominator, 1, "Denominator should be 1 when alpha=0");
            console.log("SUCCESS: Correctly identified insufficient assets scenario");
        } else {
            // If sufficient assets, should return meaningful alpha
            assertTrue(alphaNumerator > 0, "Should return alpha>0 when assets sufficient");
            assertTrue(alphaDenominator > 0, "Denominator should be positive");
            console.log("SUCCESS: Correctly calculated alpha for sufficient assets");
        }
    }

    function _setupVotingScenario(QuadraticVotingMechanism mechanism, MockToken token, uint256 depositAmount) internal {
        // Get timeline info
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingStartTime = deploymentTime + votingDelay;

        // Stay before voting starts for registration
        vm.warp(votingStartTime - 1);

        // Users register and approve tokens
        address[3] memory users = [alice, bob, charlie];
        for (uint i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            token.approve(address(mechanism), depositAmount);
            _tokenized(address(mechanism)).signup(depositAmount);
            vm.stopPrank();
        }

        // Create proposals (only management can propose in QuadraticVotingMechanism)
        uint256 pid1 = _tokenized(address(mechanism)).propose(projectA, "Project A");
        uint256 pid2 = _tokenized(address(mechanism)).propose(projectB, "Project B");

        console.log("Setup complete for", token.symbol(), "mechanism");
        console.log("  Proposal 1 ID:", pid1, "for Project A");
        console.log("  Proposal 2 ID:", pid2, "for Project B");
    }

    function _castEquivalentVotes() internal {
        // Get timeline info for each mechanism
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism6)).votingDelay();
        uint256 votingStartTime = deploymentTime + votingDelay;

        // Move to voting period
        vm.warp(votingStartTime + 1);

        // Cast equivalent votes on all mechanisms
        // Each user votes weight=10 on both proposals in each mechanism
        address[3] memory users = [alice, bob, charlie];
        QuadraticVotingMechanism[3] memory mechanisms = [mechanism6, mechanism18, mechanism8];

        for (uint m = 0; m < mechanisms.length; m++) {
            for (uint i = 0; i < users.length; i++) {
                vm.startPrank(users[i]);

                // Vote on proposal 1 and 2 with weight 10 each
                // Cost: 10^2 = 100 voting power per vote, 200 total per user
                _tokenized(address(mechanisms[m])).castVote(1, TokenizedAllocationMechanism.VoteType.For, 10, projectA);
                _tokenized(address(mechanisms[m])).castVote(2, TokenizedAllocationMechanism.VoteType.For, 10, projectB);

                vm.stopPrank();
            }
        }

        console.log("Equivalent votes cast on all mechanisms");
    }

    function _castVotesOnMechanism(QuadraticVotingMechanism mechanism) internal {
        // Get timeline info
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingStartTime = deploymentTime + votingDelay;

        // Move to voting period
        vm.warp(votingStartTime + 1);

        // Cast votes on the mechanism
        address[3] memory users = [alice, bob, charlie];

        for (uint i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);

            // Vote on proposal 1 and 2 with weight 10 each
            _tokenized(address(mechanism)).castVote(1, TokenizedAllocationMechanism.VoteType.For, 10, projectA);
            _tokenized(address(mechanism)).castVote(2, TokenizedAllocationMechanism.VoteType.For, 10, projectB);

            vm.stopPrank();
        }

        console.log("Votes cast on mechanism");
    }
}
