// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {AbstractReactive} from "./AbstractReactive.sol";

/// @title ReactiveLiquidityGuardian — RSC deployed on Reactive Network
/// @notice Monitors KMarketVault.LiquidityStateUpdated events on Polygon,
///         evaluates the LP utilisation rate, and triggers TreasuryRebalancer
///         via Callback when the water level exits the neutral zone.
contract ReactiveLiquidityGuardian is AbstractReactive {
    // ============ Enums ============

    enum WaterLevel { HEALTHY, LOW, CRITICAL }

    // ============ Immutables ============

    uint256 private immutable LIQUIDITY_STATE_TOPIC0;

    uint256 public immutable vaultChainId;      // e.g. 137 (Polygon)
    address public immutable vault;             // KMarketVault on Polygon
    address public immutable rebalancer;        // TreasuryRebalancer on Polygon
    address public immutable defaultAdapter;    // Default yield adapter address

    // ============ Config (bps = basis points) ============

    /// @notice Target buffer: when utilisation < targetBps → HEALTHY → deploy excess to yield
    uint256 public targetBufferBps;    // e.g. 6000 = 60%

    /// @notice Critical threshold: when utilisation > criticalBps → CRITICAL
    uint256 public criticalBufferBps;  // e.g. 9000 = 90%

    /// @notice Minimum seconds between callbacks to prevent spam
    uint256 public cooldownSeconds;

    uint256 public lastCallbackTimestamp;

    // ============ Events ============

    event GuardianTriggered(WaterLevel level, uint256 utilizationBps, uint256 deployAmount);

    constructor(
        uint256 _vaultChainId,
        address _vault,
        address _rebalancer,
        address _defaultAdapter,
        uint256 _targetBufferBps,
        uint256 _criticalBufferBps,
        uint256 _cooldownSeconds
    ) {
        vaultChainId = _vaultChainId;
        vault = _vault;
        rebalancer = _rebalancer;
        defaultAdapter = _defaultAdapter;
        targetBufferBps = _targetBufferBps;
        criticalBufferBps = _criticalBufferBps;
        cooldownSeconds = _cooldownSeconds;

        // Must match KMarketVault: event LiquidityStateUpdated(uint256 lpPool, uint256 totalUserDeposits, uint256 totalLockedBalance, uint256 timestamp)
        LIQUIDITY_STATE_TOPIC0 = uint256(keccak256("LiquidityStateUpdated(uint256,uint256,uint256,uint256)"));

        SERVICE.subscribe(
            _vaultChainId,
            _vault,
            LIQUIDITY_STATE_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @notice Called by ReactVM when LiquidityStateUpdated is emitted
    function react(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256, /* topic_1 */
        uint256, /* topic_2 */
        uint256, /* topic_3 */
        bytes calldata data,
        uint256, /* block_number */
        uint256  /* op_code */
    ) external override {
        if (chain_id != vaultChainId || _contract != vault) return;
        if (topic_0 != LIQUIDITY_STATE_TOPIC0) return;

        // Cooldown check
        if (block.timestamp < lastCallbackTimestamp + cooldownSeconds) return;

        // Decode event data matching KMarketVault._emitLiquidityState() emission order:
        // emit LiquidityStateUpdated(lpPool, totalUserDeposits, totalLockedBalance, timestamp)
        (uint256 lpPool, uint256 totalUserDeposits,,) =
            abi.decode(data, (uint256, uint256, uint256, uint256));

        // Calculate utilisation: how much of the vault balance is committed
        // utilisation = totalUserDeposits / (totalUserDeposits + lpPool)
        uint256 totalLiquidity = totalUserDeposits + lpPool;
        if (totalLiquidity == 0) return;

        uint256 utilizationBps = (totalUserDeposits * 10_000) / totalLiquidity;

        WaterLevel level;
        uint256 actionAmount;

        if (utilizationBps >= criticalBufferBps) {
            // CRITICAL: pull everything from yield
            level = WaterLevel.CRITICAL;
            actionAmount = 0; // emergencyPullAll ignores amount
        } else if (utilizationBps >= targetBufferBps) {
            // LOW: pull some from yield to replenish
            // Pull enough to bring utilisation down to midpoint
            uint256 targetDeposits = (totalLiquidity * targetBufferBps) / 10_000;
            actionAmount = totalUserDeposits > targetDeposits ? totalUserDeposits - targetDeposits : 0;
            if (actionAmount == 0) return;
            level = WaterLevel.LOW;
        } else {
            // HEALTHY: deploy excess to yield
            // Deploy excess beyond target utilisation
            uint256 targetDeposits = (totalLiquidity * targetBufferBps) / 10_000;
            actionAmount = targetDeposits > totalUserDeposits ? targetDeposits - totalUserDeposits : 0;
            // Only deploy if we have enough idle USDC in vault
            // Estimate vault available = lpPool (since lpPool tracks undeployed LP funds)
            if (actionAmount == 0 || actionAmount > lpPool) return;
            level = WaterLevel.HEALTHY;
        }

        lastCallbackTimestamp = block.timestamp;

        // Encode call to TreasuryRebalancer.rebalance(WaterLevel, adapter, amount)
        bytes memory payload = abi.encodeWithSignature(
            "rebalance(uint8,address,uint256)", uint8(level), defaultAdapter, actionAmount
        );
        _callback(vaultChainId, rebalancer, payload);

        emit GuardianTriggered(level, utilizationBps, actionAmount);
    }
}
