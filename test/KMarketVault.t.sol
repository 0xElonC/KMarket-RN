// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {KMarketVault} from "../src/vault/KMarketVault.sol";
import {IKMarketVault} from "../src/interfaces/IKMarketVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract KMarketVaultTest is Test {
    KMarketVault public vault;
    MockERC20 public usdc;

    address admin = makeAddr("admin");
    address sequencer;
    uint256 sequencerPk;
    address settlement = makeAddr("settlement");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address lp = makeAddr("lp");

    function setUp() public {
        (sequencer, sequencerPk) = makeAddrAndKey("sequencer");

        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new KMarketVault(address(usdc), admin);

        vm.startPrank(admin);
        vault.grantRole(vault.SEQUENCER_ROLE(), sequencer);
        vault.grantRole(vault.SETTLEMENT_ROLE(), settlement);
        vm.stopPrank();

        // Fund test accounts
        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 10_000e6);
        usdc.mint(lp, 100_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                        DEPOSIT TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_deposit() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6);
        vm.stopPrank();

        assertEq(vault.balances(alice), 1000e6);
        assertEq(usdc.balanceOf(address(vault)), 1000e6);
    }

    function test_deposit_multiple() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 2000e6);
        vault.deposit(1000e6);
        vault.deposit(500e6);
        vm.stopPrank();

        assertEq(vault.balances(alice), 1500e6);
    }

    function test_deposit_revert_zero() public {
        vm.prank(alice);
        vm.expectRevert(IKMarketVault.ZeroAmount.selector);
        vault.deposit(0);
    }

    function test_deposit_emitsEvent() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vm.expectEmit(true, false, false, true);
        emit IKMarketVault.Deposited(alice, 1000e6, 1000e6);
        vault.deposit(1000e6);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //                     FAST WITHDRAW TESTS
    // ═══════════════════════════════════════════════════════════════

    function _signFastWithdraw(address user, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(vault.FAST_WITHDRAW_TYPEHASH(), user, amount, nonce, deadline)
        );
        bytes32 digest = _hashTypedData(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sequencerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _hashTypedData(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
    }

    function test_fastWithdraw() public {
        _depositAs(alice, 1000e6);

        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signFastWithdraw(alice, 500e6, 0, deadline);

        vm.prank(alice);
        vault.fastWithdraw(500e6, deadline, sig);

        assertEq(vault.balances(alice), 500e6);
        assertEq(usdc.balanceOf(alice), 9500e6);
    }

    function test_fastWithdraw_revert_expired() public {
        _depositAs(alice, 1000e6);

        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signFastWithdraw(alice, 500e6, 0, deadline);

        vm.warp(deadline + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IKMarketVault.SignatureExpired.selector, deadline, deadline + 1));
        vault.fastWithdraw(500e6, deadline, sig);
    }

    function test_fastWithdraw_revert_insufficientAvailable() public {
        _depositAs(alice, 1000e6);

        // Lock some balance
        vm.prank(settlement);
        vault.updateLockedBalance(alice, 600e6);

        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signFastWithdraw(alice, 500e6, 0, deadline);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IKMarketVault.InsufficientAvailable.selector, 400e6, 500e6));
        vault.fastWithdraw(500e6, deadline, sig);
    }

    function test_fastWithdraw_nonce_increments() public {
        _depositAs(alice, 2000e6);

        uint256 deadline = block.timestamp + 300;
        bytes memory sig0 = _signFastWithdraw(alice, 500e6, 0, deadline);
        vm.prank(alice);
        vault.fastWithdraw(500e6, deadline, sig0);
        assertEq(vault.fastWithdrawNonce(alice), 1);

        bytes memory sig1 = _signFastWithdraw(alice, 500e6, 1, deadline);
        vm.prank(alice);
        vault.fastWithdraw(500e6, deadline, sig1);
        assertEq(vault.fastWithdrawNonce(alice), 2);
    }

    // ═══════════════════════════════════════════════════════════════
    //                     SLOW WITHDRAW TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_slowWithdraw_fullCycle() public {
        _depositAs(alice, 1000e6);

        vm.prank(alice);
        vault.requestSlowWithdraw(500e6);

        (uint256 amount, uint256 readyTime, bool canExecute) = vault.getSlowWithdrawStatus(alice);
        assertEq(amount, 500e6);
        assertFalse(canExecute);

        vm.warp(readyTime);

        (, , canExecute) = vault.getSlowWithdrawStatus(alice);
        assertTrue(canExecute);

        vm.prank(alice);
        vault.executeSlowWithdraw();

        assertEq(vault.balances(alice), 500e6);
        assertEq(usdc.balanceOf(alice), 9500e6);
    }

    function test_slowWithdraw_revert_tooEarly() public {
        _depositAs(alice, 1000e6);

        vm.prank(alice);
        vault.requestSlowWithdraw(500e6);

        vm.prank(alice);
        vm.expectRevert();
        vault.executeSlowWithdraw();
    }

    function test_slowWithdraw_revert_pending() public {
        _depositAs(alice, 1000e6);

        vm.prank(alice);
        vault.requestSlowWithdraw(500e6);

        vm.prank(alice);
        vm.expectRevert(IKMarketVault.PendingSlowWithdraw.selector);
        vault.requestSlowWithdraw(300e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                   EMERGENCY WITHDRAW TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_emergencyWithdraw_fullCycle() public {
        _depositAs(alice, 1000e6);

        // Lock some funds
        vm.prank(settlement);
        vault.updateLockedBalance(alice, 400e6);

        vm.prank(alice);
        vault.requestEmergencyWithdraw();

        (bool active, uint256 readyTime, ) = vault.getEmergencyStatus(alice);
        assertTrue(active);

        vm.warp(readyTime);

        vm.prank(alice);
        vault.executeEmergencyWithdraw();

        // Should withdraw FULL balance ignoring locked
        assertEq(vault.balances(alice), 0);
        assertEq(vault.lockedBalance(alice), 0);
        assertEq(usdc.balanceOf(alice), 10_000e6); // got original deposit back
    }

    function test_emergencyWithdraw_revert_noBalance() public {
        vm.prank(alice);
        vm.expectRevert(IKMarketVault.NoBalance.selector);
        vault.requestEmergencyWithdraw();
    }

    function test_emergencyWithdraw_cancel() public {
        _depositAs(alice, 1000e6);

        vm.prank(alice);
        vault.requestEmergencyWithdraw();

        vm.prank(alice);
        vault.cancelEmergencyWithdraw();

        (bool active, , ) = vault.getEmergencyStatus(alice);
        assertFalse(active);
    }

    // ═══════════════════════════════════════════════════════════════
    //                     SETTLEMENT TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_settleBalances_winnerAndLoser() public {
        _depositAs(alice, 1000e6);
        _depositAs(bob, 1000e6);

        // Lock both users' bets
        vm.startPrank(settlement);
        vault.updateLockedBalance(alice, 500e6);
        vault.updateLockedBalance(bob, 500e6);
        vm.stopPrank();

        // LP deposit to cover payouts
        vm.startPrank(lp);
        usdc.approve(address(vault), 10_000e6);
        vault.lpDeposit(10_000e6);
        vm.stopPrank();

        // Alice wins +500, Bob loses -500
        address[] memory users = new address[](2);
        int256[] memory deltas = new int256[](2);
        uint256[] memory lockedDeltas = new uint256[](2);

        users[0] = alice;
        users[1] = bob;
        deltas[0] = 500e6; // winner: +500
        deltas[1] = -500e6; // loser: -500
        lockedDeltas[0] = 500e6;
        lockedDeltas[1] = 500e6;

        vm.prank(settlement);
        vault.settleBalances(users, deltas, lockedDeltas);

        assertEq(vault.balances(alice), 1500e6); // 1000 + 500
        assertEq(vault.balances(bob), 500e6); // 1000 - 500
        assertEq(vault.lockedBalance(alice), 0);
        assertEq(vault.lockedBalance(bob), 0);
    }

    function test_settleBalances_lpPoolAbsorbs() public {
        _depositAs(alice, 1000e6);

        vm.prank(settlement);
        vault.updateLockedBalance(alice, 500e6);

        vm.startPrank(lp);
        usdc.approve(address(vault), 5000e6);
        vault.lpDeposit(5000e6);
        vm.stopPrank();

        // Alice wins 300 net from LP
        address[] memory users = new address[](1);
        int256[] memory deltas = new int256[](1);
        uint256[] memory lockedDeltas = new uint256[](1);
        users[0] = alice;
        deltas[0] = 300e6;
        lockedDeltas[0] = 500e6;

        vm.prank(settlement);
        vault.settleBalances(users, deltas, lockedDeltas);

        assertEq(vault.balances(alice), 1300e6);
        assertEq(vault.lpPool(), 4700e6); // LP absorbed 300
    }

    function test_settleBalances_revert_notSettlementRole() public {
        address[] memory users = new address[](1);
        int256[] memory deltas = new int256[](1);
        uint256[] memory lockedDeltas = new uint256[](1);

        vm.prank(alice);
        vm.expectRevert();
        vault.settleBalances(users, deltas, lockedDeltas);
    }

    function test_settleBalances_revert_lengthMismatch() public {
        address[] memory users = new address[](2);
        int256[] memory deltas = new int256[](1);
        uint256[] memory lockedDeltas = new uint256[](1);

        vm.prank(settlement);
        vm.expectRevert(IKMarketVault.LengthMismatch.selector);
        vault.settleBalances(users, deltas, lockedDeltas);
    }

    // ═══════════════════════════════════════════════════════════════
    //                        LP POOL TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_lpDeposit() public {
        vm.startPrank(lp);
        usdc.approve(address(vault), 5000e6);
        vault.lpDeposit(5000e6);
        vm.stopPrank();

        assertEq(vault.lpPool(), 5000e6);
        assertEq(vault.lpShares(lp), 5000e6); // first depositor: shares == amount
        assertEq(vault.totalLPShares(), 5000e6);
    }

    function test_lpWithdraw() public {
        vm.startPrank(lp);
        usdc.approve(address(vault), 5000e6);
        vault.lpDeposit(5000e6);
        vault.lpWithdraw(2500e6);
        vm.stopPrank();

        assertEq(vault.lpPool(), 2500e6);
        assertEq(vault.lpShares(lp), 2500e6);
    }

    function test_lpWithdraw_revert_invalidShares() public {
        vm.prank(lp);
        vm.expectRevert(IKMarketVault.InvalidShares.selector);
        vault.lpWithdraw(100);
    }

    function test_lp_profitSharing() public {
        // LP deposits 10000
        vm.startPrank(lp);
        usdc.approve(address(vault), 10_000e6);
        vault.lpDeposit(10_000e6);
        vm.stopPrank();

        // Simulate losers increasing LP pool via settlement
        _depositAs(alice, 1000e6);
        vm.startPrank(settlement);
        vault.updateLockedBalance(alice, 500e6);

        address[] memory users = new address[](1);
        int256[] memory deltas = new int256[](1);
        uint256[] memory lockedDeltas = new uint256[](1);
        users[0] = alice;
        deltas[0] = -500e6; // loser
        lockedDeltas[0] = 500e6;
        vault.settleBalances(users, deltas, lockedDeltas);
        vm.stopPrank();

        // LP pool should have grown by 500
        assertEq(vault.lpPool(), 10_500e6);

        // LP withdraws all shares, gets profit
        vm.prank(lp);
        vault.lpWithdraw(10_000e6); // all shares

        assertEq(usdc.balanceOf(lp), 100_500e6); // original 100k - 10k + 10.5k
    }

    // ═══════════════════════════════════════════════════════════════
    //                       PAUSE TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_pause_blocksDeposit() public {
        vm.prank(admin);
        vault.pause();

        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert();
        vault.deposit(1000e6);
        vm.stopPrank();
    }

    function test_unpause_allowsDeposit() public {
        vm.prank(admin);
        vault.pause();
        vm.prank(admin);
        vault.unpause();

        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6);
        vm.stopPrank();

        assertEq(vault.balances(alice), 1000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                      VIEW FUNCTION TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_getAvailableBalance() public {
        _depositAs(alice, 1000e6);

        vm.prank(settlement);
        vault.updateLockedBalance(alice, 300e6);

        assertEq(vault.getAvailableBalance(alice), 700e6);
    }

    function test_getTotalAssets() public {
        _depositAs(alice, 1000e6);

        vm.startPrank(lp);
        usdc.approve(address(vault), 5000e6);
        vault.lpDeposit(5000e6);
        vm.stopPrank();

        assertEq(vault.getTotalAssets(), 6000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                        HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _depositAs(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }
}
