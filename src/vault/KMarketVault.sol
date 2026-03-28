// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IKMarketVault} from "../interfaces/IKMarketVault.sol";

/// @title KMarketVault — Centralized fund pool for KMarket prediction market
/// @notice Users deposit USDC directly; settlement is done via internal mapping writes
contract KMarketVault is IKMarketVault, AccessControl, ReentrancyGuard, Pausable, EIP712 {
    using SafeERC20 for IERC20;

    // ============ Roles ============
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    bytes32 public constant SEQUENCER_ROLE = keccak256("SEQUENCER_ROLE");
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");

    // ============ Constants ============
    uint256 public constant SLOW_WITHDRAW_DELAY = 120; // 120 seconds (2 settlement cycles)
    uint256 public constant EMERGENCY_WITHDRAW_DELAY = 7 days;

    bytes32 public constant FAST_WITHDRAW_TYPEHASH =
        keccak256("FastWithdraw(address user,uint256 amount,uint256 nonce,uint256 deadline)");

    // ============ Immutables ============
    IERC20 public immutable usdc;

    // ============ User Balances ============
    mapping(address => uint256) public override balances;
    mapping(address => uint256) public override lockedBalance;

    // ============ Withdrawal State ============
    mapping(address => uint256) public override fastWithdrawNonce;
    mapping(address => SlowWithdrawRequest) private _slowWithdrawRequests;
    mapping(address => EmergencyRequest) private _emergencyRequests;

    // ============ LP Pool ============
    uint256 public override lpPool;
    mapping(address => uint256) public override lpShares;
    uint256 public override totalLPShares;

    // ============ Global Accounting ============
    uint256 public totalUserDeposits;
    uint256 public totalLockedBalance;

    // ============ Cross-Chain ============
    mapping(bytes32 => bool) public override processedDeposits;

    constructor(address _usdc, address _admin) EIP712("KMarketVault", "1") {
        require(_usdc != address(0) && _admin != address(0), "Zero address");
        usdc = IERC20(_usdc);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    // ═══════════════════════════════════════════════════════════════
    //                        USER — DEPOSIT
    // ═══════════════════════════════════════════════════════════════

    function deposit(uint256 amount) external override nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
        totalUserDeposits += amount;

        emit Deposited(msg.sender, amount, balances[msg.sender]);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    USER — FAST WITHDRAW
    // ═══════════════════════════════════════════════════════════════

    function fastWithdraw(uint256 amount, uint256 deadline, bytes calldata sequencerSig)
        external
        override
        nonReentrant
        whenNotPaused
    {
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert SignatureExpired(deadline, block.timestamp);

        uint256 available = balances[msg.sender] - lockedBalance[msg.sender];
        if (available < amount) revert InsufficientAvailable(available, amount);

        // Verify sequencer EIP-712 signature
        uint256 nonce = fastWithdrawNonce[msg.sender]++;
        bytes32 structHash = keccak256(abi.encode(FAST_WITHDRAW_TYPEHASH, msg.sender, amount, nonce, deadline));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, sequencerSig);
        if (!hasRole(SEQUENCER_ROLE, signer)) revert InvalidSequencerSig(signer);

        balances[msg.sender] -= amount;
        totalUserDeposits -= amount;
        usdc.safeTransfer(msg.sender, amount);

        emit FastWithdrawn(msg.sender, amount, nonce);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    USER — SLOW WITHDRAW
    // ═══════════════════════════════════════════════════════════════

    function requestSlowWithdraw(uint256 amount) external override nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        uint256 available = balances[msg.sender] - lockedBalance[msg.sender];
        if (available < amount) revert InsufficientAvailable(available, amount);

        SlowWithdrawRequest storage req = _slowWithdrawRequests[msg.sender];
        if (req.amount > 0 && !req.executed) revert PendingSlowWithdraw();

        _slowWithdrawRequests[msg.sender] =
            SlowWithdrawRequest({amount: amount, requestTime: block.timestamp, executed: false});

        emit SlowWithdrawRequested(msg.sender, amount, block.timestamp + SLOW_WITHDRAW_DELAY);
    }

    function executeSlowWithdraw() external override nonReentrant {
        SlowWithdrawRequest storage req = _slowWithdrawRequests[msg.sender];
        if (req.amount == 0 || req.executed) revert NoActiveRequest();
        if (block.timestamp < req.requestTime + SLOW_WITHDRAW_DELAY) {
            revert TooEarly(req.requestTime + SLOW_WITHDRAW_DELAY, block.timestamp);
        }

        uint256 available = balances[msg.sender] - lockedBalance[msg.sender];
        if (available < req.amount) revert InsufficientAvailable(available, req.amount);

        req.executed = true;
        balances[msg.sender] -= req.amount;
        totalUserDeposits -= req.amount;
        usdc.safeTransfer(msg.sender, req.amount);

        emit SlowWithdrawn(msg.sender, req.amount);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  USER — EMERGENCY WITHDRAW
    // ═══════════════════════════════════════════════════════════════

    function requestEmergencyWithdraw() external override {
        if (balances[msg.sender] == 0) revert NoBalance();

        _emergencyRequests[msg.sender] = EmergencyRequest({requestTime: block.timestamp, active: true});

        emit EmergencyWithdrawRequested(msg.sender, block.timestamp + EMERGENCY_WITHDRAW_DELAY);
    }

    function executeEmergencyWithdraw() external override nonReentrant {
        EmergencyRequest storage req = _emergencyRequests[msg.sender];
        if (!req.active) revert NoActiveRequest();
        if (block.timestamp < req.requestTime + EMERGENCY_WITHDRAW_DELAY) {
            revert TooEarly(req.requestTime + EMERGENCY_WITHDRAW_DELAY, block.timestamp);
        }

        uint256 totalAmount = balances[msg.sender];
        if (totalAmount == 0) revert NoBalance();

        // Clear all state — ignores lockedBalance
        uint256 locked = lockedBalance[msg.sender];
        balances[msg.sender] = 0;
        lockedBalance[msg.sender] = 0;
        totalUserDeposits -= totalAmount;
        if (totalLockedBalance >= locked) {
            totalLockedBalance -= locked;
        }
        req.active = false;

        usdc.safeTransfer(msg.sender, totalAmount);

        emit EmergencyWithdrawn(msg.sender, totalAmount);
    }

    function cancelEmergencyWithdraw() external override {
        if (!_emergencyRequests[msg.sender].active) revert NoActiveRequest();
        _emergencyRequests[msg.sender].active = false;

        emit EmergencyWithdrawCancelled(msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════
    //                SETTLEMENT — INTERNAL BOOKKEEPING
    // ═══════════════════════════════════════════════════════════════

    function settleBalances(address[] calldata users, int256[] calldata deltas, uint256[] calldata lockedDeltas)
        external
        override
        onlyRole(SETTLEMENT_ROLE)
        nonReentrant
    {
        if (users.length != deltas.length || users.length != lockedDeltas.length) revert LengthMismatch();

        int256 netDelta = 0;

        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            int256 delta = deltas[i];

            // Unlock settled bet amounts
            if (lockedDeltas[i] > 0) {
                lockedBalance[user] -= lockedDeltas[i];
                totalLockedBalance -= lockedDeltas[i];
            }

            // Adjust balances
            if (delta > 0) {
                balances[user] += uint256(delta);
            } else if (delta < 0) {
                uint256 loss = uint256(-delta);
                balances[user] -= loss;
            }

            netDelta += delta;
        }

        // Net delta compensated by LP pool
        if (netDelta > 0) {
            uint256 required = uint256(netDelta);
            if (lpPool < required) revert InsufficientLP(lpPool, required);
            lpPool -= required;
        } else if (netDelta < 0) {
            lpPool += uint256(-netDelta);
        }

        emit BalancesSettled(users.length, netDelta);
        _emitLiquidityState();
    }

    function updateLockedBalance(address user, uint256 amount) external override onlyRole(SETTLEMENT_ROLE) {
        lockedBalance[user] += amount;
        totalLockedBalance += amount;
    }

    // ═══════════════════════════════════════════════════════════════
    //                          LP POOL
    // ═══════════════════════════════════════════════════════════════

    function lpDeposit(uint256 amount) external override nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        uint256 shares;
        if (totalLPShares == 0 || lpPool == 0) {
            shares = amount;
        } else {
            shares = (amount * totalLPShares) / lpPool;
        }

        lpShares[msg.sender] += shares;
        totalLPShares += shares;
        lpPool += amount;

        emit LPDeposited(msg.sender, amount, shares);
        _emitLiquidityState();
    }

    function lpWithdraw(uint256 shares) external override nonReentrant {
        if (shares == 0 || lpShares[msg.sender] < shares) revert InvalidShares();

        uint256 amount = (shares * lpPool) / totalLPShares;

        lpShares[msg.sender] -= shares;
        totalLPShares -= shares;
        lpPool -= amount;

        usdc.safeTransfer(msg.sender, amount);

        emit LPWithdrawn(msg.sender, amount, shares);
        _emitLiquidityState();
    }

    // ═══════════════════════════════════════════════════════════════
    //                   CROSS-CHAIN DEPOSIT (Reactive Network)
    // ═══════════════════════════════════════════════════════════════

    function creditCrossChainDeposit(bytes32 depositId, address user, uint256 amount)
        external
        override
        onlyRole(BRIDGE_ROLE)
        nonReentrant
        whenNotPaused
    {
        if (amount == 0) revert ZeroAmount();
        if (processedDeposits[depositId]) revert DepositAlreadyProcessed(depositId);

        processedDeposits[depositId] = true;
        balances[user] += amount;
        totalUserDeposits += amount;

        emit CrossChainDeposited(depositId, user, amount);
        _emitLiquidityState();
    }

    // ═══════════════════════════════════════════════════════════════
    //                  TREASURY REBALANCER (Reactive Network)
    // ═══════════════════════════════════════════════════════════════

    function rebalanceOut(address adapter, uint256 amount)
        external
        override
        onlyRole(REBALANCER_ROLE)
        nonReentrant
    {
        if (adapter == address(0)) revert InvalidAdapter();
        if (amount == 0) revert ZeroAmount();

        usdc.safeTransfer(adapter, amount);

        emit RebalancedOut(adapter, amount);
        _emitLiquidityState();
    }

    function rebalanceIn(address adapter, uint256 amount)
        external
        override
        onlyRole(REBALANCER_ROLE)
        nonReentrant
    {
        if (adapter == address(0)) revert InvalidAdapter();
        if (amount == 0) revert ZeroAmount();

        usdc.safeTransferFrom(adapter, address(this), amount);

        emit RebalancedIn(adapter, amount);
        _emitLiquidityState();
    }

    // ═══════════════════════════════════════════════════════════════
    //                        VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    function getAvailableBalance(address user) external view override returns (uint256) {
        return balances[user] - lockedBalance[user];
    }

    function getAvailableLiquidity() external view override returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function getTotalAssets() external view override returns (uint256) {
        return totalUserDeposits + lpPool;
    }

    function getSlowWithdrawStatus(address user)
        external
        view
        override
        returns (uint256 amount, uint256 readyTime, bool canExecute)
    {
        SlowWithdrawRequest storage req = _slowWithdrawRequests[user];
        amount = req.amount;
        readyTime = req.requestTime + SLOW_WITHDRAW_DELAY;
        canExecute = req.amount > 0 && !req.executed && block.timestamp >= readyTime;
    }

    function getEmergencyStatus(address user)
        external
        view
        override
        returns (bool active, uint256 readyTime, uint256 timeRemaining)
    {
        EmergencyRequest storage req = _emergencyRequests[user];
        active = req.active;
        if (req.active) {
            readyTime = req.requestTime + EMERGENCY_WITHDRAW_DELAY;
            timeRemaining = block.timestamp >= readyTime ? 0 : readyTime - block.timestamp;
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                       INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _emitLiquidityState() internal {
        emit LiquidityStateUpdated(lpPool, totalUserDeposits, totalLockedBalance, block.timestamp);
    }

    // ============ Admin ============

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Expose the EIP-712 domain separator for off-chain signature construction
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
