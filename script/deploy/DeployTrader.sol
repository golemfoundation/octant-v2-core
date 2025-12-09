pragma solidity ^0.8.23;

import { Script } from "forge-std/Script.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { CreateOracleParams, IOracleFactory, IOracle, OracleParams } from "src/utils/vendor/0xSplits/OracleParams.sol";
import { QuotePair, QuoteParams } from "src/utils/vendor/0xSplits/LibQuotes.sol";
import { IUniV3OracleImpl } from "src/utils/vendor/0xSplits/IUniV3OracleImpl.sol";
import { ISwapperImpl } from "src/utils/vendor/0xSplits/SwapperImpl.sol";
import { ISwapperFactory } from "src/utils/vendor/0xSplits/ISwapperFactory.sol";
import { UniV3Swap } from "src/utils/vendor/0xSplits/UniV3Swap.sol";
import { ISwapRouter } from "src/utils/vendor/uniswap/ISwapRouter.sol";
import { WETH } from "solady/tokens/WETH.sol";

import { Trader } from "src/utils/routers-transformers/Trader.sol";
import { HelperConfig } from "script/helpers/HelperConfig.s.sol";
import { NATIVE_TOKEN } from "src/constants.sol";

contract DeployTrader is Script {
    address public owner;
    Trader public trader;
    address public glmAddress;
    address public swapper;
    address public beneficiary;

    UniV3Swap public initializer;

    // oracle and swapper initialization
    IUniV3OracleImpl.SetPairDetailParams[] oraclePairDetails;
    OracleParams oracleParams;
    IOracle oracle;
    ISwapperImpl.SetPairScaledOfferFactorParams[] pairScaledOfferFactors;
    ISwapRouter.ExactInputParams[] exactInputParams;
    QuotePair fromTo;
    QuoteParams[] quoteParams;
    address baseAddress;
    uint24 poolFee;
    address quoteAddress;
    address wethAddress;
    uint32 defaultScaledOfferFactor = 98_00_00; // no discount or premium for oracle

    function run(address _owner, address _beneficiary) external {
        owner = _owner;
        vm.label(owner, "owner");
        beneficiary = _beneficiary;
        vm.label(beneficiary, "beneficiary");
    }

    function forwardBlocks(uint blocks) internal {
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * 12);
    }

    function forwardSeconds(uint sec) internal {
        uint blocks = sec / 12;
        assert((blocks * 12) == sec);
        forwardBlocks(blocks);
    }

    function configureTrader(HelperConfig _config, string memory _poolName) public {
        (baseAddress, quoteAddress, poolFee) = _config.poolByName(_poolName);
        if (swapper == address(0x0)) {
            swapper = deploySwapper(_config, _poolName);
        }

        trader = new Trader(
            abi.encode(
                owner,
                baseAddress,
                poolFee,
                quoteAddress,
                wethAddress,
                beneficiary,
                swapper,
                address(initializer),
                oracle
            )
        );
        vm.label(address(trader), "Trader");
    }

    function _initOracleParams() internal view returns (IUniV3OracleImpl.InitParams memory) {
        return
            IUniV3OracleImpl.InitParams({
                owner: owner,
                paused: false,
                defaultPeriod: 30 minutes,
                pairDetails: oraclePairDetails
            });
    }

    function _createSwapperParams() internal view returns (ISwapperFactory.CreateSwapperParams memory) {
        return
            ISwapperFactory.CreateSwapperParams({
                owner: owner,
                paused: false,
                beneficiary: beneficiary,
                tokenToBeneficiary: splitsEthWrapper(quoteAddress),
                oracleParams: oracleParams,
                defaultScaledOfferFactor: defaultScaledOfferFactor,
                pairScaledOfferFactors: pairScaledOfferFactors
            });
    }

    function deploySwapper(HelperConfig _config, string memory _poolName) public returns (address) {
        (, , , , , , address swapperFactoryAddress, address oracleFactoryAddress, , ) = _config.activeNetworkConfig();
        (address _base, address _quote, uint24 _fee) = _config.poolByName(_poolName);
        address poolAddress = _config.getPoolAddress(uniEthWrapper(_base), uniEthWrapper(_quote), _fee);
        require(poolAddress != address(0x0), "No pool address found!");

        IOracleFactory oracleFactory = IOracleFactory(oracleFactoryAddress);
        ISwapperFactory swapperFactory = ISwapperFactory(swapperFactoryAddress);

        fromTo = QuotePair({ base: splitsEthWrapper(_base), quote: splitsEthWrapper(_quote) });

        delete oraclePairDetails;
        oraclePairDetails.push(
            IUniV3OracleImpl.SetPairDetailParams({
                quotePair: fromTo,
                pairDetail: IUniV3OracleImpl.PairDetail({
                    pool: poolAddress,
                    period: 0 // no override
                })
            })
        );

        delete pairScaledOfferFactors;
        /* pairScaledOfferFactors.push( */
        /*     ISwapperImpl.SetPairScaledOfferFactorParams({ */
        /*         quotePair: fromTo, */
        /*         scaledOfferFactor: 0 // zero means that defaultScaledOfferFactor will be used instead
        /*     }) */
        /* ); */

        IUniV3OracleImpl.InitParams memory initOracleParams = _initOracleParams();
        oracleParams.createOracleParams = CreateOracleParams({
            factory: IOracleFactory(address(oracleFactory)),
            data: abi.encode(initOracleParams)
        });

        oracle = oracleFactory.createUniV3Oracle(initOracleParams);
        oracleParams.oracle = oracle;

        // setup LibCloneBase
        address clone = address(swapperFactory.createSwapper(_createSwapperParams()));
        vm.label(clone, "Swapper");
        return clone;
    }

    function uniEthWrapper(address _token) internal view returns (address result) {
        if (_token == NATIVE_TOKEN) result = wethAddress;
        else result = _token;
    }

    function splitsEthWrapper(address _token) internal pure returns (address) {
        if (_token == NATIVE_TOKEN) return address(0x0);
        else return _token;
    }
}
