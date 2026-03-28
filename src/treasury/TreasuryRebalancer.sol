// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";
import {IKMarketVault} from "../interfaces/IKMarketVault.sol";

/// @title TreasuryRebalancer — Manages idle USDC deployment into DeFi yield sources
/// @notice Called by ReactiveLiquidityGuardian (via Callback) or by admin.
///         Pulls USDC from KMarketVault → deposits into adapter; or withdraws back.
contract TreasuryRebalancer is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum WaterLevel { HEALTHY, LOW, CRITICAL }

    // ============ State ============

    IKMarketVault public immutable vault;
    IERC20 public immutable usdc;

    /// @notice Whitelisted yield adapters (adapter address → active)
    mapping(address => bool) public adapters;

    /// @notice Address authorized to call rebalance (Reactive Relayer or admin EOA)
    mapping(address => bool) public keepers;

    // ============ Events ============

    event Rebalanced(WaterLevel level, address adapter, uint256 amount);
    event AdapterUpdated(address adapter, bool active);
    event KeeperUpdated(address keeper, bool active);

    // ============ Errors ============

    error NotKeeper();
    error AdapterNotWhitelisted(address adapter);

    modifier onlyKeeper() {
        if (!keepers[msg.sender] && msg.sender != owner()) revert NotKeeper();
        _;
    }

    constructor(address _vault, address _usdc, address _owner) Ownable(_owner) {
        vault = IKMarketVault(_vault);
        usdc = IERC20(_usdc);

        // Approve vault to pull USDC for rebalanceIn
        IERC20(_usdc).approve(_vault, type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════
    //                        REBALANCE CORE
    // ═══════════════════════════════════════════════════════════════

    /// @notice Main entry point called by Reactive Callback or keeper
    /// @param level  Water level determined by ReactiveLiquidityGuardian
    /// @param adapter  Target yield adapter
    /// @param amount   USDC amount to deploy or pull
    function rebalance(WaterLevel level, address adapter, uint256 amount)
        external
        onlyKeeper
        nonReentrant
        whenNotPaused
    {
        if (!adapters[adapter]) revert AdapterNotWhitelisted(adapter);

        if (level == WaterLevel.HEALTHY) {
            _deployToYield(adapter, amount);
        } else if (level == WaterLevel.LOW) {
            _pullFromYield(adapter, amount);
        } else {
            _emergencyPullAll(adapter);
        }

        emit Rebalanced(level, adapter, amount);
    }

    // ═══════════════════════════════════════════════════════════════
    //                         INTERNAL
    // ═══════════════════════════════════════════════════════════════

    /// @dev Pull USDC from Vault → deposit into yield adapter
    function _deployToYield(address adapter, uint256 amount) internal {
        // Vault transfers USDC to this contract
        vault.rebalanceOut(address(this), amount);

        // Forward to adapter
        usdc.approve(adapter, amount);
        IYieldAdapter(adapter).deposit(amount);
    }

    /// @dev Withdraw from yield adapter → push USDC back to Vault
    function _pullFromYield(address adapter, uint256 amount) internal {
        uint256 withdrawn = IYieldAdapter(adapter).withdraw(amount);

        // Approve vault to pull
        usdc.approve(address(vault), withdrawn);
        vault.rebalanceIn(address(this), withdrawn);
    }

    /// @dev Emergency: withdraw everything from adapter → push to Vault
    function _emergencyPullAll(address adapter) internal {
        uint256 withdrawn = IYieldAdapter(adapter).withdrawAll();
        if (withdrawn > 0) {
            usdc.approve(address(vault), withdrawn);
            vault.rebalanceIn(address(this), withdrawn);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                          ADMIN
    // ═══════════════════════════════════════════════════════════════

    function setAdapter(address adapter, bool active) external onlyOwner {
        adapters[adapter] = active;
        emit AdapterUpdated(adapter, active);
    }

    function setKeeper(address keeper, bool active) external onlyOwner {
        keepers[keeper] = active;
        emit KeeperUpdated(keeper, active);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
