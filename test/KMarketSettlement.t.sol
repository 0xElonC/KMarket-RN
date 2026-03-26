// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KMarketSettlement} from "../src/settlement/KMarketSettlement.sol";
import {KMarketVault} from "../src/vault/KMarketVault.sol";
import {IKMarketSettlement} from "../src/interfaces/IKMarketSettlement.sol";
import {IKMarketVault} from "../src/interfaces/IKMarketVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract KMarketSettlementTest is Test {
    KMarketSettlement public settlement;
    KMarketVault public vault;
    MockERC20 public usdc;

    address admin = makeAddr("admin");
    address sequencer = makeAddr("sequencer");
    address oracle;
    uint256 oraclePk;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address lp = makeAddr("lp");

    bytes32 constant POOL_ID = keccak256("BTC-USD-UP");

    function setUp() public {
        (oracle, oraclePk) = makeAddrAndKey("oracle");

        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new KMarketVault(address(usdc), admin);
        settlement = new KMarketSettlement(address(vault), oracle, sequencer, admin);

        // Grant settlement contract the SETTLEMENT_ROLE on vault
        vm.startPrank(admin);
        vault.grantRole(vault.SETTLEMENT_ROLE(), address(settlement));
        settlement.initializePool(POOL_ID);
        vm.stopPrank();

        // Fund accounts
        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 10_000e6);
        usdc.mint(lp, 100_000e6);

        // Deposits
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(5000e6);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(5000e6);
        vm.stopPrank();

        // LP provides liquidity
        vm.startPrank(lp);
        usdc.approve(address(vault), 50_000e6);
        vault.lpDeposit(50_000e6);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //                     BATCH SETTLE TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_batchSettle_basic() public {
        // Lock balances (simulating bet placement)
        vm.startPrank(admin);
        vault.grantRole(vault.SETTLEMENT_ROLE(), admin);
        vm.stopPrank();

        vm.startPrank(admin);
        vault.updateLockedBalance(alice, 500e6);
        vault.updateLockedBalance(bob, 500e6);
        vm.stopPrank();

        // Alice wins, Bob loses
        IKMarketSettlement.SettlementItem[] memory items = new IKMarketSettlement.SettlementItem[](2);
        items[0] = IKMarketSettlement.SettlementItem({
            user: alice,
            netDelta: int128(int256(500e6)),
            lockedDelta: uint128(500e6)
        });
        items[1] = IKMarketSettlement.SettlementItem({
            user: bob,
            netDelta: -int128(int256(500e6)),
            lockedDelta: uint128(500e6)
        });

        IKMarketSettlement.PoolDelta memory poolDelta = IKMarketSettlement.PoolDelta({
            totalPayoutsDelta: uint128(1000e6),
            totalBetsReceivedDelta: uint128(1000e6),
            lockedBetsDelta: 0
        });

        bytes32 batchRoot = keccak256("batchRoot");
        bytes32 stateRoot = keccak256("stateRoot");

        // Sign oracle EIP-712
        bytes memory oracleSig = _signBatchSettle(POOL_ID, batchRoot, stateRoot, 0, 2);

        vm.prank(sequencer);
        settlement.batchSettle(POOL_ID, items, poolDelta, batchRoot, stateRoot, oracleSig);

        // Verify results
        assertEq(vault.balances(alice), 5500e6);
        assertEq(vault.balances(bob), 4500e6);
        assertEq(vault.lockedBalance(alice), 0);
        assertEq(vault.lockedBalance(bob), 0);
        assertEq(settlement.batchNonce(), 1);
        assertEq(settlement.getBatchRoot(0), batchRoot);
        assertEq(settlement.getStateRoot(0), stateRoot);
    }

    function test_batchSettle_revert_notSequencer() public {
        IKMarketSettlement.SettlementItem[] memory items = new IKMarketSettlement.SettlementItem[](1);
        items[0] = IKMarketSettlement.SettlementItem({user: alice, netDelta: 100, lockedDelta: 0});

        IKMarketSettlement.PoolDelta memory poolDelta;
        bytes32 batchRoot = keccak256("r");
        bytes32 stateRoot = keccak256("s");

        bytes memory sig = _signBatchSettle(POOL_ID, batchRoot, stateRoot, 0, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IKMarketSettlement.NotSequencer.selector, alice));
        settlement.batchSettle(POOL_ID, items, poolDelta, batchRoot, stateRoot, sig);
    }

    function test_batchSettle_revert_empty() public {
        IKMarketSettlement.SettlementItem[] memory items = new IKMarketSettlement.SettlementItem[](0);
        IKMarketSettlement.PoolDelta memory poolDelta;

        vm.prank(sequencer);
        vm.expectRevert(IKMarketSettlement.EmptySettlements.selector);
        settlement.batchSettle(POOL_ID, items, poolDelta, bytes32(0), bytes32(0), "");
    }

    function test_batchSettle_revert_poolNotInitialized() public {
        bytes32 unknownPool = keccak256("UNKNOWN");

        IKMarketSettlement.SettlementItem[] memory items = new IKMarketSettlement.SettlementItem[](1);
        items[0] = IKMarketSettlement.SettlementItem({user: alice, netDelta: 100, lockedDelta: 0});

        IKMarketSettlement.PoolDelta memory poolDelta;
        bytes32 batchRoot = keccak256("r");
        bytes32 stateRoot = keccak256("s");

        bytes memory sig = _signBatchSettle(unknownPool, batchRoot, stateRoot, 0, 1);

        vm.prank(sequencer);
        vm.expectRevert(abi.encodeWithSelector(IKMarketSettlement.PoolNotInitialized.selector, unknownPool));
        settlement.batchSettle(unknownPool, items, poolDelta, batchRoot, stateRoot, sig);
    }

    function test_batchSettle_revert_invalidOracle() public {
        IKMarketSettlement.SettlementItem[] memory items = new IKMarketSettlement.SettlementItem[](1);
        items[0] = IKMarketSettlement.SettlementItem({user: alice, netDelta: 0, lockedDelta: 0});

        IKMarketSettlement.PoolDelta memory poolDelta;
        bytes32 batchRoot = keccak256("r");
        bytes32 stateRoot = keccak256("s");

        // Sign with wrong key
        (, uint256 wrongPk) = makeAddrAndKey("wrong");
        bytes32 structHash = keccak256(
            abi.encode(settlement.BATCH_SETTLE_TYPEHASH(), POOL_ID, batchRoot, stateRoot, 0, 1)
        );
        bytes32 digest = _hashTypedData(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(sequencer);
        vm.expectRevert(IKMarketSettlement.InvalidOracleSignature.selector);
        settlement.batchSettle(POOL_ID, items, poolDelta, batchRoot, stateRoot, sig);
    }

    function test_batchSettle_incrementsNonce() public {
        // First batch
        _executeBatchSettle(500e6, -500e6);
        assertEq(settlement.batchNonce(), 1);

        // Lock more for second batch
        bytes32 settlementRole = vault.SETTLEMENT_ROLE();
        vm.startPrank(admin);
        vault.grantRole(settlementRole, admin);
        vault.updateLockedBalance(alice, 200e6);
        vault.updateLockedBalance(bob, 200e6);
        vm.stopPrank();

        // Second batch
        IKMarketSettlement.SettlementItem[] memory items = new IKMarketSettlement.SettlementItem[](2);
        items[0] = IKMarketSettlement.SettlementItem({
            user: alice,
            netDelta: -int128(int256(200e6)),
            lockedDelta: uint128(200e6)
        });
        items[1] = IKMarketSettlement.SettlementItem({
            user: bob,
            netDelta: int128(int256(200e6)),
            lockedDelta: uint128(200e6)
        });

        IKMarketSettlement.PoolDelta memory poolDelta = IKMarketSettlement.PoolDelta({
            totalPayoutsDelta: uint128(400e6),
            totalBetsReceivedDelta: uint128(400e6),
            lockedBetsDelta: 0
        });

        bytes32 batchRoot = keccak256("batch2");
        bytes32 stateRoot = keccak256("state2");
        bytes memory sig = _signBatchSettle(POOL_ID, batchRoot, stateRoot, 1, 2);

        vm.prank(sequencer);
        settlement.batchSettle(POOL_ID, items, poolDelta, batchRoot, stateRoot, sig);
        assertEq(settlement.batchNonce(), 2);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    SELF-SETTLEMENT TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_selfSettleAll() public {
        // Lock alice's balance for bets
        bytes32 settlementRole = vault.SETTLEMENT_ROLE();
        vm.startPrank(admin);
        vault.grantRole(settlementRole, admin);
        vault.updateLockedBalance(alice, 1000e6);
        vm.stopPrank();

        // Create orders (alice won one, lost one)
        IKMarketSettlement.SettleOrder[] memory orders = new IKMarketSettlement.SettleOrder[](2);
        orders[0] = IKMarketSettlement.SettleOrder({
            poolId: POOL_ID,
            tickId: keccak256("tick1"),
            betAmount: 500e6,
            payoutAmount: 1000e6,
            expiryTime: uint64(block.timestamp + 1 hours),
            timestamp: uint64(block.timestamp),
            user: alice,
            isWin: true
        });
        orders[1] = IKMarketSettlement.SettleOrder({
            poolId: POOL_ID,
            tickId: keccak256("tick2"),
            betAmount: 500e6,
            payoutAmount: 0,
            expiryTime: uint64(block.timestamp + 1 hours),
            timestamp: uint64(block.timestamp),
            user: alice,
            isWin: false
        });

        bytes32 userSeal = _computeOrdersSeal(orders);
        bytes memory oracleSig = _signSelfSettle(POOL_ID, userSeal, alice);

        vm.prank(alice);
        settlement.selfSettleAll(POOL_ID, orders, oracleSig, userSeal);

        // Net: +500 (win) - 500 (loss) = 0 net, but locked 1000 released
        assertEq(vault.balances(alice), 5000e6);
        assertEq(vault.lockedBalance(alice), 0);
    }

    function test_selfSettleAll_revert_notYourOrder() public {
        bytes32 settlementRole = vault.SETTLEMENT_ROLE();
        vm.startPrank(admin);
        vault.grantRole(settlementRole, admin);
        vault.updateLockedBalance(alice, 500e6);
        vm.stopPrank();

        IKMarketSettlement.SettleOrder[] memory orders = new IKMarketSettlement.SettleOrder[](1);
        orders[0] = IKMarketSettlement.SettleOrder({
            poolId: POOL_ID,
            tickId: keccak256("tick1"),
            betAmount: 500e6,
            payoutAmount: 1000e6,
            expiryTime: uint64(block.timestamp + 1 hours),
            timestamp: uint64(block.timestamp),
            user: bob, // wrong user!
            isWin: true
        });

        bytes32 userSeal = _computeOrdersSeal(orders);
        bytes memory oracleSig = _signSelfSettle(POOL_ID, userSeal, alice);

        vm.prank(alice);
        vm.expectRevert("Not your order");
        settlement.selfSettleAll(POOL_ID, orders, oracleSig, userSeal);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    VERIFY ORDER TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_verifyOrder_merkleProof() public {
        // Execute a batch to store batchRoot
        bytes32 leaf1 = keccak256("order1");
        bytes32 leaf2 = keccak256("order2");
        bytes32 batchRoot = _hashPair(leaf1, leaf2);

        _executeBatchSettleWithRoot(batchRoot);

        // Verify leaf1 with proof [leaf2]
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;
        assertTrue(settlement.verifyOrder(0, leaf1, proof));

        // Verify leaf2 with proof [leaf1]
        proof[0] = leaf1;
        assertTrue(settlement.verifyOrder(0, leaf2, proof));
    }

    function test_verifyOrder_invalidProof() public {
        bytes32 leaf1 = keccak256("order1");
        bytes32 leaf2 = keccak256("order2");
        bytes32 batchRoot = _hashPair(leaf1, leaf2);

        _executeBatchSettleWithRoot(batchRoot);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256("wrong");
        assertFalse(settlement.verifyOrder(0, leaf1, proof));
    }

    function test_verifyOrder_nonexistentBatch() public {
        bytes32[] memory proof = new bytes32[](0);
        assertFalse(settlement.verifyOrder(999, keccak256("x"), proof));
    }

    // ═══════════════════════════════════════════════════════════════
    //                     POOL LEDGER TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_poolLedgerUpdated() public {
        _executeBatchSettle(500e6, -500e6);

        IKMarketSettlement.PoolLedger memory ledger = settlement.getPoolLedger(POOL_ID);
        assertEq(ledger.totalBetsReceived, 1000e6);
        assertEq(ledger.totalPayouts, 1000e6);
        assertEq(ledger.lastBatchNonce, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                       ADMIN TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_setOracle() public {
        address newOracle = makeAddr("newOracle");

        vm.prank(admin);
        settlement.setOracle(newOracle);

        assertEq(settlement.oracle(), newOracle);
    }

    function test_setSequencer() public {
        address newSeq = makeAddr("newSeq");

        vm.prank(admin);
        settlement.setSequencer(newSeq);

        assertEq(settlement.sequencer(), newSeq);
    }

    function test_setOracle_revert_notAdmin() public {
        vm.prank(alice);
        vm.expectRevert("Not admin");
        settlement.setOracle(alice);
    }

    function test_initializePool_revert_alreadyInit() public {
        vm.prank(admin);
        vm.expectRevert("Already initialized");
        settlement.initializePool(POOL_ID);
    }

    // ═══════════════════════════════════════════════════════════════
    //                        HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _signBatchSettle(
        bytes32 poolId,
        bytes32 batchRoot,
        bytes32 stateRoot,
        uint256 nonce,
        uint256 count
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(settlement.BATCH_SETTLE_TYPEHASH(), poolId, batchRoot, stateRoot, nonce, count)
        );
        bytes32 digest = _hashTypedData(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signSelfSettle(bytes32 poolId, bytes32 userSeal, address user) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(settlement.SELF_SETTLE_TYPEHASH(), poolId, userSeal, user)
        );
        bytes32 digest = _hashTypedData(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _hashTypedData(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), structHash));
    }

    function _executeBatchSettle(int128 aliceDelta, int128 bobDelta) internal {
        // Lock balances first — grant admin the SETTLEMENT_ROLE so it can lock
        bytes32 settlementRole = vault.SETTLEMENT_ROLE();
        vm.startPrank(admin);
        vault.grantRole(settlementRole, admin);
        vault.updateLockedBalance(alice, 500e6);
        vault.updateLockedBalance(bob, 500e6);
        vm.stopPrank();

        IKMarketSettlement.SettlementItem[] memory items = new IKMarketSettlement.SettlementItem[](2);
        items[0] = IKMarketSettlement.SettlementItem({user: alice, netDelta: aliceDelta, lockedDelta: 500e6});
        items[1] = IKMarketSettlement.SettlementItem({user: bob, netDelta: bobDelta, lockedDelta: 500e6});

        IKMarketSettlement.PoolDelta memory poolDelta = IKMarketSettlement.PoolDelta({
            totalPayoutsDelta: 1000e6,
            totalBetsReceivedDelta: 1000e6,
            lockedBetsDelta: 0
        });

        bytes32 batchRoot = keccak256("batch");
        bytes32 stateRoot = keccak256("state");
        bytes memory sig = _signBatchSettle(POOL_ID, batchRoot, stateRoot, settlement.batchNonce(), 2);

        vm.prank(sequencer);
        settlement.batchSettle(POOL_ID, items, poolDelta, batchRoot, stateRoot, sig);
    }

    function _executeBatchSettleWithRoot(bytes32 batchRoot) internal {
        bytes32 settlementRole = vault.SETTLEMENT_ROLE();
        vm.startPrank(admin);
        vault.grantRole(settlementRole, admin);
        vault.updateLockedBalance(alice, 100e6);
        vm.stopPrank();

        IKMarketSettlement.SettlementItem[] memory items = new IKMarketSettlement.SettlementItem[](1);
        items[0] = IKMarketSettlement.SettlementItem({user: alice, netDelta: 0, lockedDelta: 100e6});

        IKMarketSettlement.PoolDelta memory poolDelta;
        bytes32 stateRoot = keccak256("state");

        bytes memory sig = _signBatchSettle(POOL_ID, batchRoot, stateRoot, settlement.batchNonce(), 1);

        vm.prank(sequencer);
        settlement.batchSettle(POOL_ID, items, poolDelta, batchRoot, stateRoot, sig);
    }

    function _computeOrdersSeal(IKMarketSettlement.SettleOrder[] memory orders) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](orders.length);
        for (uint256 i = 0; i < orders.length; i++) {
            hashes[i] = keccak256(
                abi.encode(
                    orders[i].poolId,
                    orders[i].tickId,
                    orders[i].betAmount,
                    orders[i].payoutAmount,
                    orders[i].expiryTime,
                    orders[i].timestamp,
                    orders[i].user,
                    orders[i].isWin
                )
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));
    }
}
