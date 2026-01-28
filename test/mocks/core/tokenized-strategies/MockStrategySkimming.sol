// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.18;

import { MockYieldSource } from "../MockYieldSource.sol";
import { BaseStrategy, ERC20 } from "src/core/BaseStrategy.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { console2 } from "forge-std/console2.sol";
import { MockYieldSourceSkimming } from "./MockYieldSourceSkimming.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { WadRayMath } from "src/utils/libs/Maths/WadRay.sol";

contract MockStrategySkimming is BaseStrategy {
    using Math for uint256;
    using WadRayMath for uint256;

    address public yieldSource;
    bool public trigger;
    bool public managed;
    bool public kept;
    bool public emergentizated;
    address public yieldSourceSkimming;

    // Track the last reported total assets to calculate profit
    uint256 private lastReportedPPS = 1e18;

    constructor(
        address _yieldSource,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        address _tokenizedStrategyAddress
    )
        BaseStrategy(
            _yieldSource,
            "Test Strategy",
            "tsSYMBOL",
            _management,
            _keeper,
            _emergencyAdmin,
            _donationAddress,
            false,
            _tokenizedStrategyAddress
        )
    {
        initialize(_yieldSource, _yieldSource);
        yieldSourceSkimming = _yieldSource;
        lastReportedPPS = MockYieldSourceSkimming(_yieldSource).pricePerShare();
    }

    function initialize(address _asset, address _yieldSource) public {
        require(yieldSource == address(0));
        yieldSource = _yieldSource;
        ERC20(_asset).approve(_yieldSource, type(uint256).max);
    }

    function getCurrentExchangeRate() public view returns (uint256) {
        return lastReportedPPS;
    }

    function updateExchangeRate(uint256 _newRate) public {
        lastReportedPPS = _newRate;
    }

    function decimalsOfExchangeRate() public pure returns (uint256) {
        return 18;
    }

    function _deployFunds(uint256 _amount) internal override {}

    function _freeFunds(uint256 /*_amount*/) internal override {}

    function _harvestAndReport() internal view override returns (uint256) {
        return ITokenizedStrategy(address(this)).totalAssets();
    }

    function _tend(uint256 /*_idle*/) internal override {}

    function _emergencyWithdraw(uint256 /*_amount*/) internal override {}

    function _tendTrigger() internal view override returns (bool) {
        return trigger;
    }

    function setTrigger(bool _trigger) external {
        trigger = _trigger;
    }

    function onlyLetManagers() public onlyManagement {
        managed = true;
    }

    function onlyLetKeepersIn() public onlyKeepers {
        kept = true;
    }

    function onlyLetEmergencyAdminsIn() public onlyEmergencyAuthorized {
        emergentizated = true;
    }
}
