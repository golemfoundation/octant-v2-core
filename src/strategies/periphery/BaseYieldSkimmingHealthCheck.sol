// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import { BaseStrategy } from "src/core/BaseStrategy.sol";
import { IBaseHealthCheck } from "src/strategies/interfaces/IBaseHealthCheck.sol";
import { IYieldSkimmingStrategy } from "src/strategies/yieldSkimming/IYieldSkimmingStrategy.sol";
import { WadRayMath } from "src/utils/libs/Maths/WadRay.sol";

/**
 * @title Base Yield Skimming Health Check
 * @author Yearn.finance; modified by [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Health check for Yield Skimming strategies preventing unexpected profit/loss recording
 * @dev Adapted for Yield Skimming with exchange rate monitoring. Reverts if profit/loss exceeds
 *      configured limits during harvestAndReport(). Does not prevent loss reporting, but requires
 *      manual intervention for unexpected values.
 * @custom:origin https://github.com/yearn/tokenized-strategy-periphery/blob/master/src/Bases/HealthCheck/BaseHealthCheck.sol
 */
abstract contract BaseYieldSkimmingHealthCheck is BaseStrategy, IBaseHealthCheck {
    using WadRayMath for uint256;

    bool public doHealthCheck = true;

    uint256 internal constant MAX_BPS = 10_000;

    uint16 private _profitLimitRatio = uint16(MAX_BPS);

    uint16 private _lossLimitRatio;

    /// @notice Emitted when the health check flag is updated
    /// @param doHealthCheck True if health check is enabled
    event HealthCheckUpdated(bool doHealthCheck);

    /// @notice Emitted when the profit limit ratio is updated
    /// @param newProfitLimitRatio New profit limit ratio in basis points
    event ProfitLimitRatioUpdated(uint256 newProfitLimitRatio);

    /// @notice Emitted when the loss limit ratio is updated
    /// @param newLossLimitRatio New loss limit ratio in basis points
    event LossLimitRatioUpdated(uint256 newLossLimitRatio);

    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        address _tokenizedStrategyAddress
    )
        BaseStrategy(
            _asset,
            _name,
            _symbol,
            _management,
            _keeper,
            _emergencyAdmin,
            _donationAddress,
            _enableBurning,
            _tokenizedStrategyAddress
        )
    {}

    /**
     * @notice Returns the current profit limit ratio.
     * @dev Use a getter function to keep the variable private.
     * @return profitLimitRatio Current profit limit ratio
     */
    function profitLimitRatio() public view returns (uint256) {
        return _profitLimitRatio;
    }

    /**
     * @notice Returns the current loss limit ratio.
     * @dev Use a getter function to keep the variable private.
     * @return lossLimitRatio Current loss limit ratio
     */
    function lossLimitRatio() public view returns (uint256) {
        return _lossLimitRatio;
    }

    /**
     * @notice Set the `profitLimitRatio`.
     * @dev Denominated in basis points. I.E. 1_000 == 10%.
     * @param _newProfitLimitRatio New profit limit ratio
     */
    function setProfitLimitRatio(uint256 _newProfitLimitRatio) external onlyManagement {
        _setProfitLimitRatio(_newProfitLimitRatio);
    }

    /**
     * @dev Internally set the profit limit ratio. Denominated
     * in basis points. I.E. 1_000 == 10%.
     * @param _newProfitLimitRatio New profit limit ratio
     */
    function _setProfitLimitRatio(uint256 _newProfitLimitRatio) internal {
        require(_newProfitLimitRatio > 0, "!zero profit");
        require(_newProfitLimitRatio <= type(uint16).max, "!too high");
        _profitLimitRatio = uint16(_newProfitLimitRatio);
        emit ProfitLimitRatioUpdated(_newProfitLimitRatio);
    }

    /**
     * @notice Returns the current exchange rate in RAY format
     * @return Current exchange rate in RAY format
     */
    function getCurrentRateRay() public view returns (uint256) {
        uint256 currentRate = IYieldSkimmingStrategy(address(this)).getCurrentExchangeRate();
        uint256 decimals = IYieldSkimmingStrategy(address(this)).decimalsOfExchangeRate();

        // Convert directly to RAY (27 decimals) to avoid precision loss
        if (decimals < 27) {
            return currentRate * 10 ** (27 - decimals);
        } else if (decimals > 27) {
            return currentRate / 10 ** (decimals - 27);
        } else {
            return currentRate;
        }
    }

    /**
     * @notice Set the `lossLimitRatio`.
     * @dev Denominated in basis points. I.E. 1_000 == 10%.
     * @param _newLossLimitRatio New loss limit ratio
     */
    function setLossLimitRatio(uint256 _newLossLimitRatio) external onlyManagement {
        _setLossLimitRatio(_newLossLimitRatio);
    }

    /**
     * @dev Internally set the loss limit ratio. Denominated
     * in basis points. I.E. 1_000 == 10%.
     * @param _newLossLimitRatio New loss limit ratio
     */
    function _setLossLimitRatio(uint256 _newLossLimitRatio) internal {
        require(_newLossLimitRatio < MAX_BPS, "!loss limit");
        _lossLimitRatio = uint16(_newLossLimitRatio);
        emit LossLimitRatioUpdated(_newLossLimitRatio);
    }

    /**
     * @notice Turns the healthcheck on and off.
     * @dev If turned off the next report will auto turn it back on.
     * @param _doHealthCheck Bool if healthCheck should be done.
     */
    function setDoHealthCheck(bool _doHealthCheck) public onlyManagement {
        doHealthCheck = _doHealthCheck;
        emit HealthCheckUpdated(_doHealthCheck);
    }

    /**
     * @notice Overrides the default {harvestAndReport} to include a healthcheck.
     * @return _totalAssets New totalAssets post report.
     */
    function harvestAndReport() external override onlySelf returns (uint256 _totalAssets) {
        // Let the strategy report.
        _totalAssets = _harvestAndReport();

        // Run the healthcheck on the amount returned.
        _executeHealthCheck(_totalAssets);
    }

    /**
     * @dev To be called during a report to make sure the profit
     * or loss being recorded is within the acceptable bound.
     */
    function _executeHealthCheck(uint256 /*_newTotalAssets*/) internal virtual {
        if (!doHealthCheck) {
            doHealthCheck = true;
            return;
        }

        uint256 currentExchangeRate = IYieldSkimmingStrategy(address(this)).getLastRateRay();
        uint256 newExchangeRate = getCurrentRateRay();

        if (currentExchangeRate < newExchangeRate) {
            require(
                ((newExchangeRate - currentExchangeRate) <=
                    (currentExchangeRate * uint256(_profitLimitRatio)) / MAX_BPS),
                "!profit"
            );
        } else if (currentExchangeRate > newExchangeRate) {
            require(
                ((currentExchangeRate - newExchangeRate) <= (currentExchangeRate * uint256(_lossLimitRatio)) / MAX_BPS),
                "!loss"
            );
        }
    }
}
