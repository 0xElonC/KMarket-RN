// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISessionKeyRegistry {
    // ============ Structs ============
    struct SessionKeyData {
        uint64 expiry;
        uint64 permissions;
        uint128 spendingLimit;
        uint128 totalSpent;
        bool active;
    }

    // ============ Events ============
    event SessionKeyAuthorized(
        address indexed user,
        address indexed sessionKey,
        uint64 expiry,
        uint128 spendingLimit,
        uint64 permissions
    );
    event SessionKeyRevoked(address indexed user, address indexed sessionKey);
    event SessionKeyUsed(address indexed user, address indexed sessionKey, uint128 amount, uint128 totalSpent);

    // ============ Functions ============
    function authorize(address sessionKey, uint64 expiry, uint128 spendingLimit, uint64 permissions) external;

    function revoke(address sessionKey) external;

    function isValid(address user, address sessionKey, uint64 requiredPermission) external view returns (bool);

    function recordSpending(address user, address sessionKey, uint128 amount) external;

    function getKeyData(address user, address sessionKey) external view returns (SessionKeyData memory);

    function activeKey(address user) external view returns (address);
}
