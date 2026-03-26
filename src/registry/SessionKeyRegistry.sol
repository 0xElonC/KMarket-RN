// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISessionKeyRegistry} from "../interfaces/ISessionKeyRegistry.sol";

/// @title SessionKeyRegistry — On-chain session-key whitelist
/// @notice Each user can authorize one active session key at a time, with expiry, spending limit,
///         and permission bitmask. Only authorized callers (e.g. Settlement contract) can record spending.
contract SessionKeyRegistry is ISessionKeyRegistry {
    // ============ Permission Bitmask Constants ============
    uint64 public constant PERMISSION_BET = 1 << 0;
    uint64 public constant PERMISSION_CANCEL = 1 << 1;
    uint64 public constant PERMISSION_SETTLE = 1 << 2;

    // ============ State ============
    /// user => sessionKey => data
    mapping(address => mapping(address => SessionKeyData)) private _keys;
    /// user => current active session key
    mapping(address => address) private _activeKey;

    // ============ Spending Recorder ============
    /// @notice Addresses that can call recordSpending (e.g. Settlement contract)
    mapping(address => bool) public isRecorder;
    address public admin;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor(address _admin) {
        require(_admin != address(0), "Zero address");
        admin = _admin;
    }

    function setRecorder(address recorder, bool enabled) external onlyAdmin {
        isRecorder[recorder] = enabled;
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Zero address");
        admin = newAdmin;
    }

    // ═══════════════════════════════════════════════════════════════
    //                       USER OPERATIONS
    // ═══════════════════════════════════════════════════════════════

    function authorize(address sessionKey, uint64 expiry, uint128 spendingLimit, uint64 permissions) external override {
        require(sessionKey != address(0), "Zero session key");
        require(expiry > block.timestamp, "Already expired");
        require(permissions > 0, "No permissions");

        // Deactivate previous key if exists
        address prevKey = _activeKey[msg.sender];
        if (prevKey != address(0)) {
            _keys[msg.sender][prevKey].active = false;
        }

        _keys[msg.sender][sessionKey] = SessionKeyData({
            expiry: expiry,
            permissions: permissions,
            spendingLimit: spendingLimit,
            totalSpent: 0,
            active: true
        });

        _activeKey[msg.sender] = sessionKey;

        emit SessionKeyAuthorized(msg.sender, sessionKey, expiry, spendingLimit, permissions);
    }

    function revoke(address sessionKey) external override {
        require(_keys[msg.sender][sessionKey].active, "Not active");

        _keys[msg.sender][sessionKey].active = false;
        if (_activeKey[msg.sender] == sessionKey) {
            _activeKey[msg.sender] = address(0);
        }

        emit SessionKeyRevoked(msg.sender, sessionKey);
    }

    // ═══════════════════════════════════════════════════════════════
    //                       VALIDATION
    // ═══════════════════════════════════════════════════════════════

    function isValid(address user, address sessionKey, uint64 requiredPermission) external view override returns (bool) {
        SessionKeyData storage k = _keys[user][sessionKey];
        if (!k.active) return false;
        if (block.timestamp > k.expiry) return false;
        if (k.permissions & requiredPermission != requiredPermission) return false;
        return true;
    }

    function recordSpending(address user, address sessionKey, uint128 amount) external override {
        require(isRecorder[msg.sender], "Not recorder");

        SessionKeyData storage k = _keys[user][sessionKey];
        require(k.active, "Key not active");
        require(block.timestamp <= k.expiry, "Key expired");

        k.totalSpent += amount;
        require(k.totalSpent <= k.spendingLimit, "Spending limit exceeded");

        emit SessionKeyUsed(user, sessionKey, amount, k.totalSpent);
    }

    // ═══════════════════════════════════════════════════════════════
    //                       VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    function getKeyData(address user, address sessionKey) external view override returns (SessionKeyData memory) {
        return _keys[user][sessionKey];
    }

    function activeKey(address user) external view override returns (address) {
        return _activeKey[user];
    }
}
