// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IKMarketSettlement {
    // ============ Structs ============
    struct SettlementItem {
        address user;
        int128 netDelta;
        uint128 lockedDelta;
    }

    struct PoolLedger {
        uint128 totalBetsReceived;
        uint128 totalPayouts;
        uint128 lockedBets;
        uint128 lpBalance;
        uint64 lastBatchNonce;
        uint64 lastUpdateTime;
    }

    struct PoolDelta {
        uint128 totalPayoutsDelta;
        uint128 totalBetsReceivedDelta;
        uint128 lockedBetsDelta;
    }

    struct SettleOrder {
        bytes32 poolId;
        bytes32 tickId;
        uint128 betAmount;
        uint128 payoutAmount;
        uint64 expiryTime;
        uint64 timestamp;
        address user;
        bool isWin;
    }

    // ============ Events ============
    event BatchSettled(
        bytes32 indexed poolId,
        uint256 batchNonce,
        bytes32 batchRoot,
        bytes32 stateRoot,
        uint256 settlementCount
    );
    event SelfSettled(address indexed user, bytes32 indexed poolId, uint256 orderCount, int128 netDelta);
    event PoolLedgerUpdated(
        bytes32 indexed poolId, uint128 totalBetsReceived, uint128 totalPayouts, uint128 lockedBets
    );
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event SequencerUpdated(address indexed oldSequencer, address indexed newSequencer);
    event PoolInitialized(bytes32 indexed poolId);

    // ============ Errors ============
    error InvalidOracleSignature();
    error InvalidStateRoot(bytes32 expected, bytes32 actual);
    error InvalidUserSeal(bytes32 expected, bytes32 actual);
    error DeltaMismatch(int256 expected, int256 actual);
    error BatchNonceMismatch(uint256 expected, uint256 actual);
    error NotSequencer(address caller);
    error EmptySettlements();
    error PoolNotInitialized(bytes32 poolId);
    error ZeroAddress();

    // ============ Functions ============
    function batchSettle(
        bytes32 poolId,
        SettlementItem[] calldata settlements,
        PoolDelta calldata poolDelta,
        bytes32 batchRoot,
        bytes32 stateRoot,
        bytes calldata oracleSignature
    ) external;

    function selfSettleAll(
        bytes32 poolId,
        SettleOrder[] calldata orders,
        bytes calldata oracleSignature,
        bytes32 userSeal
    ) external;

    function initializePool(bytes32 poolId) external;

    function verifyOrder(uint256 batchNonce, bytes32 orderHash, bytes32[] calldata merkleProof)
        external
        view
        returns (bool);

    function getPoolLedger(bytes32 poolId) external view returns (PoolLedger memory);

    function getBatchRoot(uint256 batchNonce) external view returns (bytes32);

    function getStateRoot(uint256 batchNonce) external view returns (bytes32);

    function batchNonce() external view returns (uint256);
}
