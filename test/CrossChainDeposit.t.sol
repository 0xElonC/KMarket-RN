// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {KMarketVault} from "../src/vault/KMarketVault.sol";
import {IKMarketVault} from "../src/interfaces/IKMarketVault.sol";
import {OriginLockBox} from "../src/bridge/OriginLockBox.sol";
import {IOriginLockBox} from "../src/interfaces/IOriginLockBox.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract CrossChainDepositTest is Test {
    KMarketVault public vault;
    OriginLockBox public lockBox;
    MockERC20 public usdc;

    address admin = makeAddr("admin");
    address bridge = makeAddr("bridge");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address lp = makeAddr("lp");

    uint256 constant SINGLE_CAP = 10_000e6;
    uint256 constant DAILY_CAP = 100_000e6;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy vault (Polygon side)
        vault = new KMarketVault(address(usdc), admin);
        vm.startPrank(admin);
        vault.grantRole(vault.BRIDGE_ROLE(), bridge);
        vm.stopPrank();

        // Deploy lockbox (Arbitrum side — same test environment)
        lockBox = new OriginLockBox(address(usdc), guardian, SINGLE_CAP, DAILY_CAP);

        // Fund accounts
        usdc.mint(alice, 50_000e6);
        usdc.mint(bob, 50_000e6);
        usdc.mint(lp, 200_000e6);

        // LP backstop
        vm.startPrank(lp);
        usdc.approve(address(vault), 100_000e6);
        vault.lpDeposit(100_000e6);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //                   ORIGIN LOCKBOX TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_lockBox_deposit() public {
        vm.startPrank(alice);
        usdc.approve(address(lockBox), 1000e6);
        lockBox.deposit(1000e6, alice);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(lockBox)), 1000e6);
        assertEq(lockBox.dailyVolume(), 1000e6);
    }

    function test_lockBox_deposit_emitsEvent() public {
        vm.startPrank(alice);
        usdc.approve(address(lockBox), 500e6);

        vm.expectEmit(false, true, true, true);
        // depositId is computed — skip matching it (first indexed param)
        emit IOriginLockBox.Deposited(bytes32(0), alice, alice, 500e6, block.timestamp);
        lockBox.deposit(500e6, alice);
        vm.stopPrank();
    }

    function test_lockBox_revert_exceedsSingleCap() public {
        vm.startPrank(alice);
        usdc.approve(address(lockBox), SINGLE_CAP + 1);
        vm.expectRevert(abi.encodeWithSelector(IOriginLockBox.ExceedsSingleCap.selector, SINGLE_CAP + 1, SINGLE_CAP));
        lockBox.deposit(SINGLE_CAP + 1, alice);
        vm.stopPrank();
    }

    function test_lockBox_revert_exceedsDailyCap() public {
        usdc.mint(alice, DAILY_CAP);
        vm.startPrank(alice);
        usdc.approve(address(lockBox), DAILY_CAP + SINGLE_CAP);

        // Fill up to daily cap using multiple deposits
        for (uint256 i = 0; i < 10; i++) {
            lockBox.deposit(SINGLE_CAP, alice);
        }
        assertEq(lockBox.dailyVolume(), DAILY_CAP);

        // Next deposit should fail
        vm.expectRevert(
            abi.encodeWithSelector(IOriginLockBox.ExceedsDailyCap.selector, DAILY_CAP + 100e6, DAILY_CAP)
        );
        lockBox.deposit(100e6, alice);
        vm.stopPrank();
    }

    function test_lockBox_revert_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IOriginLockBox.ZeroAmount.selector);
        lockBox.deposit(0, alice);
    }

    function test_lockBox_revert_zeroReceiver() public {
        vm.prank(alice);
        vm.expectRevert(IOriginLockBox.ZeroAddress.selector);
        lockBox.deposit(100e6, address(0));
    }

    function test_lockBox_refund() public {
        vm.startPrank(alice);
        usdc.approve(address(lockBox), 1000e6);
        lockBox.deposit(1000e6, alice);
        vm.stopPrank();

        // Find depositId from storage (counter was 0 before deposit)
        bytes32 depositId =
            keccak256(abi.encodePacked(block.chainid, uint256(0), alice, uint256(1000e6), block.timestamp));

        uint256 balBefore = usdc.balanceOf(alice);

        vm.prank(guardian);
        lockBox.refund(depositId);

        assertEq(usdc.balanceOf(alice), balBefore + 1000e6);

        IOriginLockBox.DepositRecord memory rec = lockBox.getDeposit(depositId);
        assertTrue(rec.refunded);
    }

    function test_lockBox_refund_revert_notGuardian() public {
        vm.startPrank(alice);
        usdc.approve(address(lockBox), 1000e6);
        lockBox.deposit(1000e6, alice);
        vm.stopPrank();

        bytes32 depositId =
            keccak256(abi.encodePacked(block.chainid, uint256(0), alice, uint256(1000e6), block.timestamp));

        vm.prank(alice);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        lockBox.refund(depositId);
    }

    function test_lockBox_dailyVolumeResets() public {
        vm.startPrank(alice);
        usdc.approve(address(lockBox), 2000e6);
        lockBox.deposit(1000e6, alice);
        assertEq(lockBox.dailyVolume(), 1000e6);

        // Warp to next day
        vm.warp(block.timestamp + 1 days);
        lockBox.deposit(500e6, alice);
        assertEq(lockBox.dailyVolume(), 500e6); // reset
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //              VAULT — CROSS-CHAIN CREDIT TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_creditCrossChainDeposit() public {
        bytes32 depositId = keccak256("test-deposit-1");

        vm.prank(bridge);
        vault.creditCrossChainDeposit(depositId, alice, 2000e6);

        assertEq(vault.balances(alice), 2000e6);
        assertTrue(vault.processedDeposits(depositId));
    }

    function test_creditCrossChainDeposit_emitsEvent() public {
        bytes32 depositId = keccak256("test-deposit-2");

        vm.prank(bridge);
        vm.expectEmit(true, true, false, true);
        emit IKMarketVault.CrossChainDeposited(depositId, bob, 500e6);
        vault.creditCrossChainDeposit(depositId, bob, 500e6);
    }

    function test_creditCrossChainDeposit_emitsLiquidityState() public {
        bytes32 depositId = keccak256("test-deposit-3");

        vm.prank(bridge);
        vm.expectEmit(false, false, false, false);
        emit IKMarketVault.LiquidityStateUpdated(0, 0, 0, 0);
        vault.creditCrossChainDeposit(depositId, alice, 1000e6);
    }

    function test_creditCrossChainDeposit_revert_duplicate() public {
        bytes32 depositId = keccak256("dup-dep");

        vm.startPrank(bridge);
        vault.creditCrossChainDeposit(depositId, alice, 100e6);

        vm.expectRevert(abi.encodeWithSelector(IKMarketVault.DepositAlreadyProcessed.selector, depositId));
        vault.creditCrossChainDeposit(depositId, alice, 100e6);
        vm.stopPrank();
    }

    function test_creditCrossChainDeposit_revert_notBridgeRole() public {
        bytes32 depositId = keccak256("no-role");

        vm.prank(alice);
        vm.expectRevert(); // AccessControlUnauthorizedAccount
        vault.creditCrossChainDeposit(depositId, alice, 100e6);
    }

    function test_creditCrossChainDeposit_revert_zeroAmount() public {
        bytes32 depositId = keccak256("zero-amt");

        vm.prank(bridge);
        vm.expectRevert(IKMarketVault.ZeroAmount.selector);
        vault.creditCrossChainDeposit(depositId, alice, 0);
    }

    function test_creditCrossChainDeposit_revert_whenPaused() public {
        vm.prank(admin);
        vault.pause();

        bytes32 depositId = keccak256("paused");
        vm.prank(bridge);
        vm.expectRevert(); // EnforcedPause
        vault.creditCrossChainDeposit(depositId, alice, 100e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  END-TO-END FLOW SIMULATION
    // ═══════════════════════════════════════════════════════════════

    function test_e2e_crossChainDepositFlow() public {
        // 1. Alice deposits on "Arbitrum" (lockbox)
        vm.startPrank(alice);
        usdc.approve(address(lockBox), 5000e6);
        lockBox.deposit(5000e6, alice);
        vm.stopPrank();

        // Verify USDC locked
        assertEq(usdc.balanceOf(address(lockBox)), 5000e6);

        // 2. Simulate Reactive Network callback → bridge credits on "Polygon"
        bytes32 depositId =
            keccak256(abi.encodePacked(block.chainid, uint256(0), alice, uint256(5000e6), block.timestamp));

        vm.prank(bridge);
        vault.creditCrossChainDeposit(depositId, alice, 5000e6);

        // 3. Alice now has balance in vault (fast credit, no actual USDC transfer)
        assertEq(vault.balances(alice), 5000e6);

        // 4. USDC still in lockbox, vault funded by LP backstop
        assertEq(usdc.balanceOf(address(lockBox)), 5000e6);
    }
}
