// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {KMarketVault} from "../src/vault/KMarketVault.sol";
import {IKMarketVault} from "../src/interfaces/IKMarketVault.sol";
import {TreasuryRebalancer} from "../src/treasury/TreasuryRebalancer.sol";
import {AaveAdapter} from "../src/treasury/AaveAdapter.sol";
import {IYieldAdapter} from "../src/interfaces/IYieldAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Mock Aave Pool for testing
contract MockAavePool {
    MockERC20 public aToken;
    MockERC20 public underlying;

    constructor(address _underlying, address _aToken) {
        underlying = MockERC20(_underlying);
        aToken = MockERC20(_aToken);
    }

    function supply(address, uint256 amount, address onBehalfOf, uint16) external {
        underlying.transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address, uint256 amount, address to) external returns (uint256) {
        aToken.transferFrom(msg.sender, address(this), amount);
        underlying.transfer(to, amount);
        return amount;
    }
}

contract TreasuryRebalancerTest is Test {
    KMarketVault public vault;
    TreasuryRebalancer public rebalancer;
    AaveAdapter public aaveAdapter;
    MockAavePool public aavePool;
    MockERC20 public usdc;
    MockERC20 public aUsdc;

    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address settlement = makeAddr("settlement");
    address lp = makeAddr("lp");
    address alice = makeAddr("alice");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);

        // Deploy mock Aave
        aavePool = new MockAavePool(address(usdc), address(aUsdc));
        usdc.mint(address(aavePool), 1_000_000e6); // Aave liquidity

        // Deploy vault
        vault = new KMarketVault(address(usdc), admin);

        // Deploy rebalancer (owner = admin)
        rebalancer = new TreasuryRebalancer(address(vault), address(usdc), admin);

        // Deploy Aave adapter (owner = rebalancer)
        aaveAdapter = new AaveAdapter(
            address(usdc),
            address(aUsdc),
            address(aavePool),
            address(rebalancer)
        );

        // Grant roles
        vm.startPrank(admin);
        vault.grantRole(vault.SETTLEMENT_ROLE(), settlement);
        vault.grantRole(vault.REBALANCER_ROLE(), address(rebalancer));
        rebalancer.setAdapter(address(aaveAdapter), true);
        rebalancer.setKeeper(keeper, true);
        vm.stopPrank();

        // LP deposits to fund the vault
        usdc.mint(lp, 200_000e6);
        vm.startPrank(lp);
        usdc.approve(address(vault), 200_000e6);
        vault.lpDeposit(200_000e6);
        vm.stopPrank();

        // Approve aaveAdapter for USDC from rebalancer
        // (AaveAdapter pulls USDC from msg.sender = rebalancer using safeTransferFrom)
    }

    // ═══════════════════════════════════════════════════════════════
    //                    REBALANCE — DEPLOY TO YIELD
    // ═══════════════════════════════════════════════════════════════

    function test_rebalance_deployToYield() public {
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));

        vm.prank(keeper);
        rebalancer.rebalance(TreasuryRebalancer.WaterLevel.HEALTHY, address(aaveAdapter), 50_000e6);

        // USDC moved from vault → aave adapter → aave pool
        assertEq(usdc.balanceOf(address(vault)), vaultBalBefore - 50_000e6);
        assertEq(aaveAdapter.totalAssets(), 50_000e6);
    }

    function test_rebalance_pullFromYield() public {
        // First deploy
        vm.prank(keeper);
        rebalancer.rebalance(TreasuryRebalancer.WaterLevel.HEALTHY, address(aaveAdapter), 50_000e6);
        assertEq(aaveAdapter.totalAssets(), 50_000e6);

        uint256 vaultBalBefore = usdc.balanceOf(address(vault));

        // Then pull back
        vm.prank(keeper);
        rebalancer.rebalance(TreasuryRebalancer.WaterLevel.LOW, address(aaveAdapter), 20_000e6);

        assertEq(usdc.balanceOf(address(vault)), vaultBalBefore + 20_000e6);
        assertEq(aaveAdapter.totalAssets(), 30_000e6);
    }

    function test_rebalance_emergencyPullAll() public {
        // Deploy
        vm.prank(keeper);
        rebalancer.rebalance(TreasuryRebalancer.WaterLevel.HEALTHY, address(aaveAdapter), 80_000e6);
        assertEq(aaveAdapter.totalAssets(), 80_000e6);

        uint256 vaultBalBefore = usdc.balanceOf(address(vault));

        // Emergency pull
        vm.prank(keeper);
        rebalancer.rebalance(TreasuryRebalancer.WaterLevel.CRITICAL, address(aaveAdapter), 0);

        assertEq(usdc.balanceOf(address(vault)), vaultBalBefore + 80_000e6);
        assertEq(aaveAdapter.totalAssets(), 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                     REBALANCE — EVENTS
    // ═══════════════════════════════════════════════════════════════

    function test_rebalance_emitsLiquidityState() public {
        // After rebalanceOut, vault should emit LiquidityStateUpdated
        vm.prank(keeper);
        vm.expectEmit(false, false, false, false);
        emit IKMarketVault.LiquidityStateUpdated(0, 0, 0, 0);
        rebalancer.rebalance(TreasuryRebalancer.WaterLevel.HEALTHY, address(aaveAdapter), 10_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                     ACCESS CONTROL
    // ═══════════════════════════════════════════════════════════════

    function test_rebalance_revert_notKeeper() public {
        vm.prank(alice);
        vm.expectRevert(TreasuryRebalancer.NotKeeper.selector);
        rebalancer.rebalance(TreasuryRebalancer.WaterLevel.HEALTHY, address(aaveAdapter), 1000e6);
    }

    function test_rebalance_revert_adapterNotWhitelisted() public {
        address fakeAdapter = makeAddr("fake");
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(TreasuryRebalancer.AdapterNotWhitelisted.selector, fakeAdapter));
        rebalancer.rebalance(TreasuryRebalancer.WaterLevel.HEALTHY, fakeAdapter, 1000e6);
    }

    function test_rebalance_revert_whenPaused() public {
        vm.prank(admin);
        rebalancer.pause();

        vm.prank(keeper);
        vm.expectRevert(); // EnforcedPause
        rebalancer.rebalance(TreasuryRebalancer.WaterLevel.HEALTHY, address(aaveAdapter), 1000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    ADAPTER MANAGEMENT
    // ═══════════════════════════════════════════════════════════════

    function test_setAdapter() public {
        address newAdapter = makeAddr("newAdapter");
        vm.prank(admin);
        rebalancer.setAdapter(newAdapter, true);
        assertTrue(rebalancer.adapters(newAdapter));

        vm.prank(admin);
        rebalancer.setAdapter(newAdapter, false);
        assertFalse(rebalancer.adapters(newAdapter));
    }

    function test_setKeeper() public {
        address newKeeper = makeAddr("newKeeper");
        vm.prank(admin);
        rebalancer.setKeeper(newKeeper, true);
        assertTrue(rebalancer.keepers(newKeeper));
    }

    // ═══════════════════════════════════════════════════════════════
    //                        AAVE ADAPTER
    // ═══════════════════════════════════════════════════════════════

    function test_aaveAdapter_totalAssets() public {
        assertEq(aaveAdapter.totalAssets(), 0);

        vm.prank(keeper);
        rebalancer.rebalance(TreasuryRebalancer.WaterLevel.HEALTHY, address(aaveAdapter), 25_000e6);

        assertEq(aaveAdapter.totalAssets(), 25_000e6);
    }

    function test_aaveAdapter_underlying() public {
        assertEq(aaveAdapter.underlying(), address(usdc));
    }
}
