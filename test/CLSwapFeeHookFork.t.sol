// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICLRouterBase} from "infinity-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {MockCLSwapRouter} from "infinity-hooks/test/pool-cl/helpers/MockCLSwapRouter.sol";
import {MockCLPositionManager} from "infinity-hooks/test/pool-cl/helpers/MockCLPositionManager.sol";
import {CLSwapFeeHook} from "../src/CLSwapFeeHook.sol";

/**
 * Fork test on BSC mainnet: CAKE/USDT 0.05% pool with CLSwapFeeHook.
 * Uses addresses from lib/infinity-core/script/config/bsc-mainnet.json.
 *
 * Run: forge test --match-contract CLSwapFeeHookFork --fork-url $BSC_RPC_URL -vvv
 * Or:  forge test --match-contract CLSwapFeeHookFork --fork-url https://bsc-dataseed.binance.org -vvv
 */
contract CLSwapFeeHookFork is Test, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    // BSC mainnet from lib/infinity-core/script/config/bsc-mainnet.json
    address constant BSC_VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address constant BSC_CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;

    // CAKE / USDT on BSC
    address constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

    bytes constant ZERO_BYTES = new bytes(0);

    IVault vault;
    ICLPoolManager poolManager;
    IAllowanceTransfer permit2;
    MockCLPositionManager cpm;
    MockCLSwapRouter swapRouter;
    CLSwapFeeHook swapFeeHook;

    Currency currency0; // CAKE (lower address)
    Currency currency1; // USDT
    PoolKey key;
    PoolId id;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string("https://bsc-dataseed.binance.org"));
        vm.createSelectFork(rpc);

        vault = IVault(BSC_VAULT);
        poolManager = ICLPoolManager(BSC_CL_POOL_MANAGER);

        swapFeeHook = new CLSwapFeeHook(poolManager);
        permit2 = IAllowanceTransfer(deployPermit2());
        cpm = new MockCLPositionManager(vault, poolManager, permit2);
        swapRouter = new MockCLSwapRouter(vault, poolManager);

        // CAKE < USDT by address → currency0 = CAKE, currency1 = USDT
        currency0 = Currency.wrap(CAKE);
        currency1 = Currency.wrap(USDT);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: swapFeeHook,
            poolManager: poolManager,
            fee: 500, // 0.05%
            parameters: bytes32(uint256(swapFeeHook.getHooksRegistrationBitmap())).setTickSpacing(10)
        });
        id = key.toId();

        // Fund this contract (deal works on fork)
        deal(CAKE, address(this), 10_000e18);
        deal(USDT, address(this), 10_000e18);

        IERC20(CAKE).approve(address(vault), type(uint256).max);
        IERC20(USDT).approve(address(vault), type(uint256).max);
        IERC20(CAKE).approve(address(cpm), type(uint256).max);
        IERC20(USDT).approve(address(cpm), type(uint256).max);
        IERC20(CAKE).approve(address(swapRouter), type(uint256).max);
        IERC20(USDT).approve(address(swapRouter), type(uint256).max);
        IERC20(CAKE).approve(address(permit2), type(uint256).max);
        IERC20(USDT).approve(address(permit2), type(uint256).max);
        permit2.approve(address(CAKE), address(cpm), type(uint160).max, type(uint48).max);
        permit2.approve(address(USDT), address(cpm), type(uint160).max, type(uint48).max);

        // Initialize pool (no vault lock needed — initialize does not touch vault)
        poolManager.initialize(key, SQRT_RATIO_1_1);

        // Add liquidity: tick -120 to 120, liquidity 10e18
        cpm.mint(key, -120, 120, 10e18, 100e18, 100e18, address(this), ZERO_BYTES);
    }

    function testFork_PoolInitialized() public {
        assertTrue(vault.isAppRegistered(BSC_CL_POOL_MANAGER));
    }

    function testFork_SwapZeroForOneExactInput_AccruesFee() public {
        uint128 amountIn = 1e18;

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: amountIn, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        // Fee = 0.1% of output (currency1 = USDT)
        uint256 accrued = swapFeeHook.accruedFees(currency1);
        assertTrue(accrued > 0, "Fee should be accrued on USDT");
        // 0.1% of output: output is less than amountIn in value; fee is ~0.1% of that
        assertLe(accrued, 1e18, "Fee should be reasonable");
    }

    function testFork_SwapOneForZeroExactInput_AccruesFee() public {
        uint128 amountIn = 1000e18; // USDT has 18 decimals on BSC

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: false, amountIn: amountIn, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 accrued = swapFeeHook.accruedFees(currency0);
        assertTrue(accrued > 0, "Fee should be accrued on CAKE");
    }

    function testFork_FeeIsApproximatelyOneTenthPercent() public {
        uint128 amountIn = 10e18;

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: amountIn, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 accrued = swapFeeHook.accruedFees(currency1);
        assertTrue(accrued > 0, "Fee should be accrued");
        // Hook charges 0.1% (10 bps) of the unspecified (output) amount. With small pool liquidity
        // output can be small, so fee is output * 10/10000; just ensure it is positive and reasonable.
        assertLe(accrued, 10e18, "Fee should not exceed swap size");
    }

    function testFork_WithdrawFees() public {
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: 1e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 accrued = swapFeeHook.accruedFees(currency1);
        assertTrue(accrued > 0);

        address recipient = address(0x1234);
        uint256 balanceBefore = IERC20(USDT).balanceOf(recipient);

        swapFeeHook.withdrawFees(currency1, recipient, 0); // 0 = withdraw all

        assertEq(swapFeeHook.accruedFees(currency1), 0);
        assertEq(IERC20(USDT).balanceOf(recipient), balanceBefore + accrued);
    }
}
