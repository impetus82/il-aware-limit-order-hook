// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

/// @title RecoverPool - Reverse swap to restore pool price to ~1.0
/// @author Yuri (Phase 4.5)
/// @dev The pool is stuck at tick 887271 (MAX_TICK - 1) after Phase 3.13 E2E testing.
///      All TTB has been drained from the pool - only TTA remains.
///      We need to sell TTA (token0) for TTB (token1) → zeroForOne = true → price DOWN.
///
///   Usage:
///     forge script script/RecoverPool.s.sol:RecoverPool \
///       --rpc-url $SEPOLIA_RPC_URL --broadcast --slow --with-gas-price 5000000000 -vvvv
contract RecoverPool is Script {
    using StateLibrary for IPoolManager;

    // --- Phase 3.15 deployed addresses (CURRENT) ---
    address constant HOOK = 0x43BF7DA3d2e26D295a8965109505767e93B24040;
    address constant TOKEN0 = 0x93345833027Ab2Ab863b812fA7cA9D5cfee883BC; // TTA
    address constant TOKEN1 = 0xcD11CC946B446088A987d3163E662C335C20d410; // TTB
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    int24 constant TICK_SPACING = 60;
    uint24 constant FEE = 3000;

    // Swap a large amount of TTA to push price back down.
    // Pool had 10M liquidity; 5M swap should be more than enough
    // to move from MAX_TICK back to ~0.
    uint256 constant SWAP_AMOUNT = 5_000_000 ether;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(TOKEN0),
            currency1: Currency.wrap(TOKEN1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });

        console2.log("=== RecoverPool: Reverse Swap (Phase 4.5) ===");
        console2.log("Deployer:", deployer);
        console2.log("Selling TTA (token0) for TTB (token1) - push price DOWN");
        console2.log("Amount:", SWAP_AMOUNT / 1 ether, "TTA");

        vm.startBroadcast(pk);

        // Step 1: Deploy fresh PoolSwapTest router
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        console2.log("SwapRouter deployed:", address(swapRouter));

        // Step 2: Mint TTA to deployer (MockERC20 has public mint)
        MockERC20(TOKEN0).mint(deployer, SWAP_AMOUNT);
        console2.log("Minted", SWAP_AMOUNT / 1 ether, "TTA");

        // Step 3: Approve router for TTA
        IERC20(TOKEN0).approve(address(swapRouter), SWAP_AMOUNT);
        console2.log("Approved SwapRouter for TTA");

        // Step 4: Execute swap - sell TTA (token0) for TTB (token1)
        // zeroForOne = true  → selling token0, buying token1 → price goes DOWN
        // amountSpecified < 0 → exact input (we specify how much TTA to sell)
        // sqrtPriceLimitX96 = MIN_SQRT_PRICE + 1 → allow price to drop all the way
        //   (target is tick 0 / price ~1.0, which is sqrtPriceX96 = 2^96 ≈ 7.92e28)
        //   Using MIN + 1 is safe - the pool will stop when liquidity runs out
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(SWAP_AMOUNT),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(poolKey, swapParams, testSettings, "");

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== RECOVERY SWAP EXECUTED ===");
        console2.log("Sold TTA -> received TTB");
        console2.log("Price should now be near 1.0 (tick ~0)");
        console2.log("");
        console2.log("Next: Run ReadPoolState to verify new tick/price");
    }
}