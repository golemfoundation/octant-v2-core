// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

interface IEpochs {
    function getCurrentEpoch() external view returns (uint256);
    function getFinalizedEpoch() external view returns (uint256);
    function getPendingEpoch() external view returns (uint256);
    function getEpochDuration() external view returns (uint256);
    function getDecisionWindow() external view returns (uint256);
    function isStarted() external view returns (bool);
    function isDecisionWindowOpen() external view returns (bool);
    function auth() external view returns (address);
    // EpochProps struct: { uint32 from, uint32 to, uint64 fromTs, uint64 duration, uint64 decisionWindow }
    function getCurrentEpochProps() external view returns (uint32 from, uint32 to, uint64 fromTs, uint64 duration, uint64 decisionWindow);
    function epochPropsIndex() external view returns (uint256);
    function getCurrentEpochEnd() external view returns (uint256);
    function setEpochProps(uint256 _epochDuration, uint256 _decisionWindow) external;
}

interface IAuth {
    function multisig() external view returns (address);
}

contract OctantEpochsTest is Test {
    IEpochs public epochs;

    // Contract addresses
    address constant EPOCHS_CONTRACT = 0xc292eBCa7855CB464755Aa638f9784c131F27D59;
    address constant AUTH_ADDRESS = 0x287493F76b8A1833E9E0BF2dE0D972Fb16C6C8ae;
    address constant MULTISIG_ADDRESS = 0xa40FcB633d0A6c0d27aA9367047635Ff656229B0;

    // Target date
    uint256 constant FEB_18_2026_END = 1771459200; // End of February 18, 2026

    // setEpochProps parameters (new epoch duration to end on Feb 18, 2026)
    uint256 constant NEW_EPOCH_DURATION = FEB_18_2026_END - 1767715200; // ~43 days (Feb 18 - Jan 6)

    // _verifyInitialState expected values (ordered: propsIndex, duration, window, epochEnd, props)
    uint256 constant INITIAL_EPOCH_PROPS_INDEX = 1;
    uint256 constant INITIAL_EPOCH_DURATION = 90 days;
    uint256 constant INITIAL_DECISION_WINDOW = 14 days;
    uint64 constant INITIAL_CURRENT_EPOCH_END = 1767715200; // Jan 6, 2026
    uint32 constant INITIAL_PROPS_FROM = 2; // epoch when props became active
    uint32 constant INITIAL_PROPS_TO = 0; // 0 = indefinite (until setEpochProps called)
    uint64 constant INITIAL_PROPS_FROM_TS = 1697731200; // Oct 19, 2023 - when props were set
    uint64 constant INITIAL_PROPS_DURATION = 90 days;
    uint64 constant INITIAL_PROPS_DECISION_WINDOW = 14 days;

    // _verifyFinalState expected values (after setEpochProps, before epoch transition)
    uint256 constant FINAL_EPOCH_PROPS_INDEX = INITIAL_EPOCH_PROPS_INDEX + 1; // incremented
    uint256 constant FINAL_EPOCH_DURATION = INITIAL_EPOCH_DURATION; // unchanged
    uint256 constant FINAL_DECISION_WINDOW = INITIAL_DECISION_WINDOW; // unchanged
    uint256 constant FINAL_CURRENT_EPOCH_END = INITIAL_CURRENT_EPOCH_END; // unchanged
    uint32 constant FINAL_PROPS_FROM = 2; // unchanged
    uint32 constant FINAL_PROPS_TO = 10; // current epoch (props end when new props queued)
    uint64 constant FINAL_PROPS_FROM_TS = INITIAL_PROPS_FROM_TS; // unchanged
    uint64 constant FINAL_PROPS_DURATION = INITIAL_PROPS_DURATION; // unchanged
    uint64 constant FINAL_PROPS_DECISION_WINDOW = INITIAL_PROPS_DECISION_WINDOW; // unchanged

    // _verifyStateAfterEpochTransition expected values (new props now active)
    uint256 constant POST_TRANSITION_EPOCH_PROPS_INDEX = FINAL_EPOCH_PROPS_INDEX; // unchanged
    uint256 constant POST_TRANSITION_EPOCH_DURATION = NEW_EPOCH_DURATION; // ~43 days active
    uint256 constant POST_TRANSITION_DECISION_WINDOW = INITIAL_DECISION_WINDOW; // unchanged (14 days)
    uint256 constant POST_TRANSITION_CURRENT_EPOCH_END = FEB_18_2026_END;
    uint32 constant POST_TRANSITION_PROPS_FROM = 11; // new props active from epoch 11
    uint32 constant POST_TRANSITION_PROPS_TO = 0; // 0 = indefinite (until next setEpochProps)
    uint64 constant POST_TRANSITION_PROPS_FROM_TS = INITIAL_CURRENT_EPOCH_END; // Jan 6, 2026
    uint64 constant POST_TRANSITION_PROPS_DURATION = uint64(NEW_EPOCH_DURATION);
    uint64 constant POST_TRANSITION_PROPS_DECISION_WINDOW = uint64(INITIAL_DECISION_WINDOW);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        epochs = IEpochs(EPOCHS_CONTRACT);
    }

    /// @dev Logs current epoch state for debugging
    function _logState(string memory label) internal view {
        console.log("===", label, "===");
        console.log("getCurrentEpoch():", epochs.getCurrentEpoch());
        console.log("getCurrentEpochEnd():", epochs.getCurrentEpochEnd());
        console.log("getEpochDuration():", epochs.getEpochDuration(), "(%d days)", epochs.getEpochDuration() / 86400);
        console.log("getDecisionWindow():", epochs.getDecisionWindow(), "(%d days)", epochs.getDecisionWindow() / 86400);
        console.log("getFinalizedEpoch():", epochs.getFinalizedEpoch());
        console.log("epochPropsIndex():", epochs.epochPropsIndex());
    }

    /// @dev Verifies initial state before any changes
    function _verifyInitialState() internal view {
        assertEq(epochs.epochPropsIndex(), INITIAL_EPOCH_PROPS_INDEX, "initial: epoch props index");
        assertEq(epochs.getEpochDuration(), INITIAL_EPOCH_DURATION, "initial: epoch duration");
        assertEq(epochs.getDecisionWindow(), INITIAL_DECISION_WINDOW, "initial: decision window");
        assertEq(epochs.getCurrentEpochEnd(), INITIAL_CURRENT_EPOCH_END, "initial: epoch end");

        (uint32 from, uint32 to, uint64 fromTs, uint64 duration, uint64 decisionWindow) = epochs.getCurrentEpochProps();
        assertEq(from, INITIAL_PROPS_FROM, "initial: props from");
        assertEq(to, INITIAL_PROPS_TO, "initial: props to");
        assertEq(fromTs, INITIAL_PROPS_FROM_TS, "initial: props fromTs");
        assertEq(duration, INITIAL_PROPS_DURATION, "initial: props duration");
        assertEq(decisionWindow, INITIAL_PROPS_DECISION_WINDOW, "initial: props decision window");
    }

    /// @dev Pranks as the authorized multisig and calls setEpochProps
    /// @notice setEpochProps behavior:
    ///   1. Authorization: checks msg.sender == Auth(auth).multisig()
    ///   2. Caps current props at current epoch (sets props.to = currentEpoch)
    ///   3. Queues new props at epochPropsIndex++ (does NOT immediately activate)
    ///   4. getEpochDuration/getDecisionWindow/getCurrentEpochEnd remain UNCHANGED
    ///   5. New props activate only after epoch transition (when currentEpoch ends)
    /// @param _epochDuration Duration in seconds for the new epoch
    /// @param _decisionWindow Decision window in seconds for the new epoch
    function _setEpochPropsAsMultisig(uint256 _epochDuration, uint256 _decisionWindow) internal {
        vm.prank(MULTISIG_ADDRESS);
        epochs.setEpochProps(_epochDuration, _decisionWindow);
    }

    /// @dev Verifies state after setEpochProps (props queued but not active)
    function _verifyFinalState() internal view {
        assertEq(epochs.epochPropsIndex(), FINAL_EPOCH_PROPS_INDEX, "final: epoch props index");
        assertEq(epochs.getEpochDuration(), FINAL_EPOCH_DURATION, "final: epoch duration");
        assertEq(epochs.getDecisionWindow(), FINAL_DECISION_WINDOW, "final: decision window");
        assertEq(epochs.getCurrentEpochEnd(), FINAL_CURRENT_EPOCH_END, "final: epoch end");

        (uint32 from, uint32 to, uint64 fromTs, uint64 duration, uint64 decisionWindow) = epochs.getCurrentEpochProps();
        assertEq(from, FINAL_PROPS_FROM, "final: props from");
        assertEq(to, FINAL_PROPS_TO, "final: props to");
        assertEq(fromTs, FINAL_PROPS_FROM_TS, "final: props fromTs");
        assertEq(duration, FINAL_PROPS_DURATION, "final: props duration");
        assertEq(decisionWindow, FINAL_PROPS_DECISION_WINDOW, "final: props decision window");
    }

    /// @dev Verifies state after epoch transition (new props now active)
    function _verifyStateAfterEpochTransition() internal view {
        assertEq(epochs.epochPropsIndex(), POST_TRANSITION_EPOCH_PROPS_INDEX, "post: epoch props index");
        assertEq(epochs.getEpochDuration(), POST_TRANSITION_EPOCH_DURATION, "post: epoch duration");
        assertEq(epochs.getDecisionWindow(), POST_TRANSITION_DECISION_WINDOW, "post: decision window");
        assertEq(epochs.getCurrentEpochEnd(), POST_TRANSITION_CURRENT_EPOCH_END, "post: epoch end");

        (uint32 from, uint32 to, uint64 fromTs, uint64 duration, uint64 decisionWindow) = epochs.getCurrentEpochProps();
        assertEq(from, POST_TRANSITION_PROPS_FROM, "post: props from");
        assertEq(to, POST_TRANSITION_PROPS_TO, "post: props to");
        assertEq(fromTs, POST_TRANSITION_PROPS_FROM_TS, "post: props fromTs");
        assertEq(duration, POST_TRANSITION_PROPS_DURATION, "post: props duration");
        assertEq(decisionWindow, POST_TRANSITION_PROPS_DECISION_WINDOW, "post: props decision window");
    }

    function test_auth_returns_expected_address() public view {
        assertEq(epochs.auth(), AUTH_ADDRESS);
    }

    function test_epoch_functions() public view {
        _verifyInitialState();
    }

    function test_setEpochProps_for_feb_18_2026() public {
        // Log and verify initial state
        _logState("Initial State");
        _verifyInitialState();

        // Set new epoch props - duration changes, decision window stays the same
        uint256 currentDecisionWindow = epochs.getDecisionWindow();
        _setEpochPropsAsMultisig(NEW_EPOCH_DURATION, currentDecisionWindow);

        // Log and verify state after setEpochProps (props queued but not active)
        _logState("After setEpochProps");
        _verifyFinalState();

        // Warp to end of current epoch + 1 second to activate new props
        vm.warp(INITIAL_CURRENT_EPOCH_END + 1);

        // Log and verify state after epoch transition (new props now active)
        _logState("After Epoch Transition");
        _verifyStateAfterEpochTransition();
    }
}
