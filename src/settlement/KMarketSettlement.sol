// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IKMarketSettlement} from "../interfaces/IKMarketSettlement.sol";
import {IKMarketVault} from "../interfaces/IKMarketVault.sol";

/// @title KMarketSettlement — Batch settlement engine for KMarket prediction market
/// @notice Sequencer submits batch settlements with Oracle signature verification;
///         internally adjusts Vault balances without ERC20 transfers.
contract KMarketSettlement is IKMarketSettlement, EIP712, ReentrancyGuard {

    bytes32 public constant BATCH_SETTLE_TYPEHASH = keccak256(
        "BatchSettle(bytes32 poolId,bytes32 batchRoot,bytes32 stateRoot,uint256 batchNonce,uint256 settlementCount)"
    );

    bytes32 public constant SELF_SETTLE_TYPEHASH = keccak256(
        "SelfSettle(bytes32 poolId,bytes32 userSeal,address user)"
    );

    // ============ State ============
    IKMarketVault public immutable vault;
    address public oracle;
    address public sequencer;
    address public admin;

    uint256 public override batchNonce;

    /// poolId => ledger
    mapping(bytes32 => PoolLedger) private _poolLedgers;
    /// batchNonce => batchRoot
    mapping(uint256 => bytes32) private _batchRoots;
    /// batchNonce => stateRoot
    mapping(uint256 => bytes32) private _stateRoots;

    modifier onlySequencer() {
        if (msg.sender != sequencer) revert NotSequencer(msg.sender);
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor(address _vault, address _oracle, address _sequencer, address _admin) EIP712("KMarketSettlement", "1") {
        if (_vault == address(0) || _oracle == address(0) || _sequencer == address(0) || _admin == address(0)) {
            revert ZeroAddress();
        }
        vault = IKMarketVault(_vault);
        oracle = _oracle;
        sequencer = _sequencer;
        admin = _admin;
    }

    // ═══════════════════════════════════════════════════════════════
    //                        ADMIN
    // ═══════════════════════════════════════════════════════════════

    function setOracle(address _oracle) external onlyAdmin {
        if (_oracle == address(0)) revert ZeroAddress();
        emit OracleUpdated(oracle, _oracle);
        oracle = _oracle;
    }

    function setSequencer(address _sequencer) external onlyAdmin {
        if (_sequencer == address(0)) revert ZeroAddress();
        emit SequencerUpdated(sequencer, _sequencer);
        sequencer = _sequencer;
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        admin = newAdmin;
    }

    // ═══════════════════════════════════════════════════════════════
    //                     POOL MANAGEMENT
    // ═══════════════════════════════════════════════════════════════

    function initializePool(bytes32 poolId) external override onlyAdmin {
        PoolLedger storage ledger = _poolLedgers[poolId];
        require(ledger.lastUpdateTime == 0, "Already initialized");
        ledger.lastUpdateTime = uint64(block.timestamp);
        emit PoolInitialized(poolId);
    }

    // ═══════════════════════════════════════════════════════════════
    //                     BATCH SETTLEMENT
    // ═══════════════════════════════════════════════════════════════

    function batchSettle(
        bytes32 poolId,
        SettlementItem[] calldata settlements,
        PoolDelta calldata poolDelta,
        bytes32 batchRoot,
        bytes32 stateRoot,
        bytes calldata oracleSignature
    ) external override onlySequencer nonReentrant {
        if (settlements.length == 0) revert EmptySettlements();

        PoolLedger storage ledger = _poolLedgers[poolId];
        if (ledger.lastUpdateTime == 0) revert PoolNotInitialized(poolId);

        uint256 currentNonce = batchNonce;

        // Verify Oracle EIP-712 signature
        bytes32 structHash = keccak256(
            abi.encode(BATCH_SETTLE_TYPEHASH, poolId, batchRoot, stateRoot, currentNonce, settlements.length)
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, oracleSignature);
        if (signer != oracle) revert InvalidOracleSignature();

        // Build arrays for Vault.settleBalances
        address[] memory users = new address[](settlements.length);
        int256[] memory deltas = new int256[](settlements.length);
        uint256[] memory lockedDeltas = new uint256[](settlements.length);
        int256 netDelta = 0;

        for (uint256 i = 0; i < settlements.length; i++) {
            users[i] = settlements[i].user;
            deltas[i] = int256(settlements[i].netDelta);
            lockedDeltas[i] = uint256(settlements[i].lockedDelta);
            netDelta += int256(settlements[i].netDelta);
        }

        // Call Vault to adjust internal balances
        vault.settleBalances(users, deltas, lockedDeltas);

        // Update pool ledger
        ledger.totalBetsReceived += poolDelta.totalBetsReceivedDelta;
        ledger.totalPayouts += poolDelta.totalPayoutsDelta;
        if (poolDelta.lockedBetsDelta > 0) {
            ledger.lockedBets -= uint128(poolDelta.lockedBetsDelta);
        }
        ledger.lastBatchNonce = uint64(currentNonce);
        ledger.lastUpdateTime = uint64(block.timestamp);

        // Store roots
        _batchRoots[currentNonce] = batchRoot;
        _stateRoots[currentNonce] = stateRoot;
        batchNonce = currentNonce + 1;

        emit BatchSettled(poolId, currentNonce, batchRoot, stateRoot, settlements.length);
        emit PoolLedgerUpdated(poolId, ledger.totalBetsReceived, ledger.totalPayouts, ledger.lockedBets);
    }

    // ═══════════════════════════════════════════════════════════════
    //                     SELF-SETTLEMENT
    // ═══════════════════════════════════════════════════════════════

    function selfSettleAll(
        bytes32 poolId,
        SettleOrder[] calldata orders,
        bytes calldata oracleSignature,
        bytes32 userSeal
    ) external override nonReentrant {
        if (orders.length == 0) revert EmptySettlements();

        PoolLedger storage ledger = _poolLedgers[poolId];
        if (ledger.lastUpdateTime == 0) revert PoolNotInitialized(poolId);

        // Verify oracle signature on user-seal
        bytes32 structHash = keccak256(
            abi.encode(SELF_SETTLE_TYPEHASH, poolId, userSeal, msg.sender)
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, oracleSignature);
        if (signer != oracle) revert InvalidOracleSignature();

        // Verify user seal matches orders hash
        bytes32 computedSeal = _computeOrdersSeal(orders);
        if (computedSeal != userSeal) revert InvalidUserSeal(userSeal, computedSeal);

        // Calculate net delta from orders
        int128 netDelta = 0;
        uint128 totalLocked = 0;
        for (uint256 i = 0; i < orders.length; i++) {
            SettleOrder calldata order = orders[i];
            require(order.user == msg.sender, "Not your order");

            if (order.isWin) {
                netDelta += int128(order.payoutAmount) - int128(order.betAmount);
            } else {
                netDelta -= int128(order.betAmount);
            }
            totalLocked += order.betAmount;
        }

        // Build single-element arrays for Vault
        address[] memory users = new address[](1);
        int256[] memory deltas = new int256[](1);
        uint256[] memory lockedDeltas = new uint256[](1);
        users[0] = msg.sender;
        deltas[0] = int256(netDelta);
        lockedDeltas[0] = uint256(totalLocked);

        vault.settleBalances(users, deltas, lockedDeltas);

        emit SelfSettled(msg.sender, poolId, orders.length, netDelta);
    }

    // ═══════════════════════════════════════════════════════════════
    //                       VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    function verifyOrder(uint256 _batchNonce, bytes32 orderHash, bytes32[] calldata merkleProof)
        external
        view
        override
        returns (bool)
    {
        bytes32 root = _batchRoots[_batchNonce];
        if (root == bytes32(0)) return false;
        return MerkleProof.verify(merkleProof, root, orderHash);
    }

    function getPoolLedger(bytes32 poolId) external view override returns (PoolLedger memory) {
        return _poolLedgers[poolId];
    }

    function getBatchRoot(uint256 _batchNonce) external view override returns (bytes32) {
        return _batchRoots[_batchNonce];
    }

    function getStateRoot(uint256 _batchNonce) external view override returns (bytes32) {
        return _stateRoots[_batchNonce];
    }

    // ============ Internal ============

    function _computeOrdersSeal(SettleOrder[] calldata orders) internal pure returns (bytes32) {
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

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
