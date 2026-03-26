// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SessionKeyRegistry} from "../src/registry/SessionKeyRegistry.sol";
import {ISessionKeyRegistry} from "../src/interfaces/ISessionKeyRegistry.sol";

contract SessionKeyRegistryTest is Test {
    SessionKeyRegistry public registry;

    address admin = makeAddr("admin");
    address recorder = makeAddr("recorder");
    address alice = makeAddr("alice");
    address sessionKey1 = makeAddr("sk1");
    address sessionKey2 = makeAddr("sk2");

    uint64 constant PERM_BET = 1 << 0;
    uint64 constant PERM_CANCEL = 1 << 1;
    uint64 constant PERM_SETTLE = 1 << 2;

    function setUp() public {
        registry = new SessionKeyRegistry(admin);

        vm.prank(admin);
        registry.setRecorder(recorder, true);
    }

    // ═══════════════════════════════════════════════════════════════
    //                       AUTHORIZE TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_authorize() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);

        vm.prank(alice);
        registry.authorize(sessionKey1, expiry, 1000e6, PERM_BET);

        ISessionKeyRegistry.SessionKeyData memory data = registry.getKeyData(alice, sessionKey1);
        assertTrue(data.active);
        assertEq(data.expiry, expiry);
        assertEq(data.spendingLimit, 1000e6);
        assertEq(data.permissions, PERM_BET);
        assertEq(data.totalSpent, 0);

        assertEq(registry.activeKey(alice), sessionKey1);
    }

    function test_authorize_replacesOldKey() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);

        vm.startPrank(alice);
        registry.authorize(sessionKey1, expiry, 1000e6, PERM_BET);
        registry.authorize(sessionKey2, expiry, 2000e6, PERM_BET | PERM_CANCEL);
        vm.stopPrank();

        // Old key deactivated
        ISessionKeyRegistry.SessionKeyData memory old = registry.getKeyData(alice, sessionKey1);
        assertFalse(old.active);

        // New key active
        ISessionKeyRegistry.SessionKeyData memory newData = registry.getKeyData(alice, sessionKey2);
        assertTrue(newData.active);
        assertEq(registry.activeKey(alice), sessionKey2);
    }

    function test_authorize_revert_zeroAddress() public {
        vm.prank(alice);
        vm.expectRevert("Zero session key");
        registry.authorize(address(0), uint64(block.timestamp + 1), 100, PERM_BET);
    }

    function test_authorize_revert_expired() public {
        vm.prank(alice);
        vm.expectRevert("Already expired");
        registry.authorize(sessionKey1, uint64(block.timestamp - 1), 100, PERM_BET);
    }

    function test_authorize_revert_noPermissions() public {
        vm.prank(alice);
        vm.expectRevert("No permissions");
        registry.authorize(sessionKey1, uint64(block.timestamp + 1), 100, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                        REVOKE TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_revoke() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);

        vm.startPrank(alice);
        registry.authorize(sessionKey1, expiry, 1000e6, PERM_BET);
        registry.revoke(sessionKey1);
        vm.stopPrank();

        ISessionKeyRegistry.SessionKeyData memory data = registry.getKeyData(alice, sessionKey1);
        assertFalse(data.active);
        assertEq(registry.activeKey(alice), address(0));
    }

    function test_revoke_revert_notActive() public {
        vm.prank(alice);
        vm.expectRevert("Not active");
        registry.revoke(sessionKey1);
    }

    // ═══════════════════════════════════════════════════════════════
    //                     VALIDATION TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_isValid_true() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);

        vm.prank(alice);
        registry.authorize(sessionKey1, expiry, 1000e6, PERM_BET | PERM_CANCEL);

        assertTrue(registry.isValid(alice, sessionKey1, PERM_BET));
        assertTrue(registry.isValid(alice, sessionKey1, PERM_CANCEL));
        assertTrue(registry.isValid(alice, sessionKey1, PERM_BET | PERM_CANCEL));
    }

    function test_isValid_false_expired() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);

        vm.prank(alice);
        registry.authorize(sessionKey1, expiry, 1000e6, PERM_BET);

        vm.warp(expiry + 1);
        assertFalse(registry.isValid(alice, sessionKey1, PERM_BET));
    }

    function test_isValid_false_wrongPermission() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);

        vm.prank(alice);
        registry.authorize(sessionKey1, expiry, 1000e6, PERM_BET);

        assertFalse(registry.isValid(alice, sessionKey1, PERM_CANCEL));
    }

    function test_isValid_false_revoked() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);

        vm.startPrank(alice);
        registry.authorize(sessionKey1, expiry, 1000e6, PERM_BET);
        registry.revoke(sessionKey1);
        vm.stopPrank();

        assertFalse(registry.isValid(alice, sessionKey1, PERM_BET));
    }

    // ═══════════════════════════════════════════════════════════════
    //                    RECORD SPENDING TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_recordSpending() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);

        vm.prank(alice);
        registry.authorize(sessionKey1, expiry, 1000e6, PERM_BET);

        vm.prank(recorder);
        registry.recordSpending(alice, sessionKey1, 300e6);

        ISessionKeyRegistry.SessionKeyData memory data = registry.getKeyData(alice, sessionKey1);
        assertEq(data.totalSpent, 300e6);
    }

    function test_recordSpending_revert_limitExceeded() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);

        vm.prank(alice);
        registry.authorize(sessionKey1, expiry, 1000e6, PERM_BET);

        vm.startPrank(recorder);
        registry.recordSpending(alice, sessionKey1, 800e6);

        vm.expectRevert("Spending limit exceeded");
        registry.recordSpending(alice, sessionKey1, 300e6);
        vm.stopPrank();
    }

    function test_recordSpending_revert_notRecorder() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);

        vm.prank(alice);
        registry.authorize(sessionKey1, expiry, 1000e6, PERM_BET);

        vm.prank(alice);
        vm.expectRevert("Not recorder");
        registry.recordSpending(alice, sessionKey1, 100e6);
    }

    function test_recordSpending_revert_keyExpired() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);

        vm.prank(alice);
        registry.authorize(sessionKey1, expiry, 1000e6, PERM_BET);

        vm.warp(expiry + 1);

        vm.prank(recorder);
        vm.expectRevert("Key expired");
        registry.recordSpending(alice, sessionKey1, 100e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                        ADMIN TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_setRecorder() public {
        address newRecorder = makeAddr("newRecorder");

        vm.prank(admin);
        registry.setRecorder(newRecorder, true);

        assertTrue(registry.isRecorder(newRecorder));
    }

    function test_setRecorder_revert_notAdmin() public {
        vm.prank(alice);
        vm.expectRevert("Not admin");
        registry.setRecorder(alice, true);
    }

    function test_transferAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        registry.transferAdmin(newAdmin);

        assertEq(registry.admin(), newAdmin);

        // old admin can't act
        vm.prank(admin);
        vm.expectRevert("Not admin");
        registry.setRecorder(alice, true);
    }
}
