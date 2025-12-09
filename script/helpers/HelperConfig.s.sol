/* SPDX-License-Identifier: GPL-3.0 */

pragma solidity ^0.8.23;

import { Script } from "forge-std/Script.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { IUniswapV3Pool } from "../../src/utils/vendor/uniswap/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from "../../src/utils/vendor/uniswap/IUniswapV3Factory.sol";
import { NATIVE_TOKEN } from "src/constants.sol";

contract HelperConfig is Script {
    struct UniswapPoolConfig {
        address base;
        address quote;
        uint24 fee;
    }

    struct NetworkConfig {
        address glmToken;
        address wethToken;
        address nonfungiblePositionManager;
        uint256 deployerKey;
        address uniswapV3Router;
        address trader;
        address swapperFactory;
        address oracleFactory;
        address uniV3Swap;
        address uniswapV3Factory;
    }

    // This is the private key for dev account available in anvil. It is not a secret!
    uint256 public immutable DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    NetworkConfig public activeNetworkConfig;
    mapping(string => UniswapPoolConfig) public poolByName;
    string[] public pools;

    constructor(bool forking) {
        if (block.chainid == 1) {
            // running on mainnet or on a mainnet fork
            activeNetworkConfig = initMainnetEthConfig(forking);
        }
        if (block.chainid == 11155111) {
            activeNetworkConfig = initSepoliaETHConfig(forking);
        } else {
            activeNetworkConfig = createAnvilEthConfig();
        }
        vm.label(activeNetworkConfig.glmToken, "glmToken");
        vm.label(activeNetworkConfig.wethToken, "wethToken");
        vm.label(activeNetworkConfig.nonfungiblePositionManager, "nonfungiblePositionManager");
        vm.label(activeNetworkConfig.uniswapV3Router, "uniswapV3Router");
        vm.label(activeNetworkConfig.swapperFactory, "swapperFactory");
        vm.label(activeNetworkConfig.oracleFactory, "oracleFactory");
        vm.label(activeNetworkConfig.uniV3Swap, "uniV3Swap");
        vm.label(activeNetworkConfig.uniswapV3Factory, "uniswapV3Factory");
    }

    function initSepoliaETHConfig(bool forking) internal returns (NetworkConfig memory) {
        uint256 deployerKey;
        if (forking) {
            // throw-away environment; using ETH from test account
            deployerKey = DEFAULT_ANVIL_KEY;
        } else {
            // some other environment, user needs to provide their own source of ETH for gas
            deployerKey = vm.envUint("PRIVATE_KEY");
        }

        addPool("ETHGLM", NATIVE_TOKEN, 0x71432DD1ae7DB41706ee6a22148446087BdD0906, 10_000); // ETH -> GLM, 1%
        addPool("GLMETH", 0x71432DD1ae7DB41706ee6a22148446087BdD0906, NATIVE_TOKEN, 10_000); // GLM -> ETH, 1%

        return
            // UniswapV3Factory at 0x7eb12e415F88477B3Ef2f0D839161Ffa0f5329a0
            NetworkConfig({
                glmToken: 0x71432DD1ae7DB41706ee6a22148446087BdD0906,
                wethToken: 0xeA438fB469540f1Ba54Ad2D2342d2dBCb191cE29,
                nonfungiblePositionManager: 0xC8118AcDf29cBa90c3142437c0e84AE3902bfA74,
                uniswapV3Router: 0xD6601e25cF43CAc433A23cB95a39D38012B2e9f0,
                deployerKey: deployerKey,
                trader: 0xc654a254EEab4c65F8a786f8c1516ea7e9824daF,
                swapperFactory: 0xa244bbe019cf1BA177EE5A532250be2663Fb55cA,
                oracleFactory: 0x074827E8bD77B0A66c6008a51AF9BD1F33105caf,
                uniV3Swap: 0x981a6aC55c7D39f50666938CcD0df53D59797e87,
                uniswapV3Factory: 0x7eb12e415F88477B3Ef2f0D839161Ffa0f5329a0
            });
    }

    function initMainnetEthConfig(bool forking) internal returns (NetworkConfig memory) {
        uint256 deployerKey;
        if (forking) {
            deployerKey = DEFAULT_ANVIL_KEY;
        } else {
            deployerKey = vm.envUint("PRIVATE_KEY");
        }

        addPool("ETHGLM", NATIVE_TOKEN, 0x7DD9c5Cba05E151C895FDe1CF355C9A1D5DA6429, 10_000); // ETH -> GLM, 1%
        addPool("GLMETH", 0x7DD9c5Cba05E151C895FDe1CF355C9A1D5DA6429, NATIVE_TOKEN, 10_000); // ETH -> GLM, 1%

        return
            NetworkConfig({
                glmToken: 0x7DD9c5Cba05E151C895FDe1CF355C9A1D5DA6429,
                wethToken: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                nonfungiblePositionManager: 0xC36442b4a4522E871399CD717aBDD847Ab11FE88,
                uniswapV3Router: 0xE592427A0AEce92De3Edee1F18E0157C05861564,
                deployerKey: deployerKey,
                trader: address(0),
                swapperFactory: 0xa244bbe019cf1BA177EE5A532250be2663Fb55cA,
                oracleFactory: 0x498f316fEB85a250fdC64B859a130515491EC888,
                uniV3Swap: 0x981a6aC55c7D39f50666938CcD0df53D59797e87,
                uniswapV3Factory: 0x1F98431c8aD98523631AE4a59f267346ea31F984
            });
    }

    function addPool(string memory _name, address _base, address _quote, uint24 _fee) internal {
        UniswapPoolConfig memory pool = UniswapPoolConfig({ base: _base, quote: _quote, fee: _fee });
        pools.push(_name);
        poolByName[_name] = pool;
    }

    function poolCount() public view returns (uint) {
        return pools.length;
    }

    function getPoolAddress(address _base, address _quote, uint24 _fee) public returns (address) {
        IUniswapV3Factory factory = IUniswapV3Factory(activeNetworkConfig.uniswapV3Factory);
        return factory.getPool(_base, _quote, _fee);
    }

    function createAnvilEthConfig() internal returns (NetworkConfig memory) {
        if (activeNetworkConfig.glmToken != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();

        ERC20Mock wethMock = new ERC20Mock();
        ERC20Mock glmMock = new ERC20Mock();

        vm.stopBroadcast();

        return
            NetworkConfig({
                glmToken: address(glmMock),
                wethToken: address(wethMock),
                nonfungiblePositionManager: address(0), // deploy
                uniswapV3Router: address(0),
                deployerKey: DEFAULT_ANVIL_KEY,
                trader: address(0),
                swapperFactory: address(0),
                oracleFactory: address(0),
                uniV3Swap: address(0),
                uniswapV3Factory: address(0)
            });
    }
}
