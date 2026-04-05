// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IKMarketVault {
    // ============ Structs ============
    struct SlowWithdrawRequest {
        uint256 amount;
        uint256 requestTime;
        bool executed;
    }

    struct EmergencyRequest {
        uint256 requestTime;
        bool active;
    }

    // ============ Events ============
    event Deposited(address indexed user, uint256 amount, uint256 newBalance);
    event FastWithdrawn(address indexed user, uint256 amount, uint256 nonce);
    event SlowWithdrawRequested(address indexed user, uint256 amount, uint256 readyTime);
    event SlowWithdrawn(address indexed user, uint256 amount);
    event EmergencyWithdrawRequested(address indexed user, uint256 readyTime);
    event EmergencyWithdrawn(address indexed user, uint256 amount);
    event EmergencyWithdrawCancelled(address indexed user);
    event BalancesSettled(uint256 userCount, int256 netDelta);
    event LPDeposited(address indexed provider, uint256 amount, uint256 shares);
    event LPWithdrawn(address indexed provider, uint256 amount, uint256 shares);
    event LiquidityStateUpdated(uint256 lpPool, uint256 totalUserDeposits, uint256 totalLockedBalance, uint256 timestamp);

    // ============ Errors ============
    error ZeroAmount();
    error InsufficientAvailable(uint256 available, uint256 requested);
    error InsufficientLP(uint256 lpPool, uint256 required);
    error SignatureExpired(uint256 deadline, uint256 currentTime);
    error InvalidSequencerSig(address recovered);
    error PendingSlowWithdraw();
    error NoActiveRequest();
    error TooEarly(uint256 readyTime, uint256 currentTime);
    error NoBalance();
    error LengthMismatch();
    error InvalidShares();
    error SlippageExceeded(uint256 actual, uint256 minimum);

    // ============ User Functions ============
    function deposit(uint256 amount) external;

    function fastWithdraw(uint256 amount, uint256 deadline, bytes calldata sequencerSig) external;

    function requestSlowWithdraw(uint256 amount) external;

    function executeSlowWithdraw() external;

    function requestEmergencyWithdraw() external;

    function executeEmergencyWithdraw() external;

    function cancelEmergencyWithdraw() external;

    // ============ Settlement Functions ============
    function settleBalances(
        address[] calldata users,
        int256[] calldata deltas,
        uint256[] calldata lockedDeltas
    ) external;

    function updateLockedBalance(address user, uint256 amount) external;

    // ============ LP Functions ============
    function lpDeposit(uint256 amount, uint256 minShares) external;

    function lpWithdraw(uint256 shares, uint256 minAmount) external;

    // ============ View Functions ============
    function balances(address user) external view returns (uint256);

    function lockedBalance(address user) external view returns (uint256);

    function getAvailableBalance(address user) external view returns (uint256);

    function getSlowWithdrawStatus(address user)
        external
        view
        returns (uint256 amount, uint256 readyTime, bool canExecute);

    function getEmergencyStatus(address user)
        external
        view
        returns (bool active, uint256 readyTime, uint256 timeRemaining);

    function getAvailableLiquidity() external view returns (uint256);

    function getTotalAssets() external view returns (uint256);

    function lpPool() external view returns (uint256);

    function lpShares(address provider) external view returns (uint256);

    function totalLPShares() external view returns (uint256);

    function fastWithdrawNonce(address user) external view returns (uint256);
}
