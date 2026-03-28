// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOriginLockBox {
    // ============ Structs ============

    struct DepositRecord {
        address sender;
        address receiver; // address on destination chain
        uint256 amount;
        uint256 timestamp;
        bool refunded;
    }

    // ============ Events ============

    event Deposited(
        bytes32 indexed depositId, address indexed sender, address indexed receiver, uint256 amount, uint256 timestamp
    );
    event Refunded(bytes32 indexed depositId, address indexed sender, uint256 amount);
    event DailyCapUpdated(uint256 newCap);
    event SingleCapUpdated(uint256 newCap);

    // ============ Errors ============

    error ZeroAmount();
    error ZeroAddress();
    error ExceedsSingleCap(uint256 amount, uint256 cap);
    error ExceedsDailyCap(uint256 todayTotal, uint256 cap);
    error DepositNotFound(bytes32 depositId);
    error AlreadyRefunded(bytes32 depositId);
    error NotGuardian();

    // ============ Functions ============

    function deposit(uint256 amount, address polygonReceiver) external;
    function refund(bytes32 depositId) external;
    function setDailyCap(uint256 newCap) external;
    function setSingleCap(uint256 newCap) external;

    // ============ View ============

    function getDeposit(bytes32 depositId) external view returns (DepositRecord memory);
    function dailyVolume() external view returns (uint256);
}
