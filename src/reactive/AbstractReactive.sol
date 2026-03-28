// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IReactive} from "./IReactive.sol";
import {ISubscriptionService} from "./ISubscriptionService.sol";

/// @title AbstractReactive — Base contract for Reactive Network RSCs
/// @notice Provides subscription helpers, the Callback event, and wildcard constants.
abstract contract AbstractReactive is IReactive {
    /// @notice Wildcard value — tells Reactive Network "match any topic"
    uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38571571f4a9a0b86a2b6ad1deb82e83495b96bf3c15b40;

    /// @notice The system service contract deployed at a well-known address on ReactVM
    ISubscriptionService internal constant SERVICE = ISubscriptionService(0x0000000000000000000000000000000000fffFfF);

    /// @dev Emitted by RSC; picked up by Reactive Relayer and executed on the destination chain.
    event Callback(uint256 indexed chain_id, address indexed _contract, uint64 gas_limit, bytes payload);

    /// @dev Convenience overload — default gas limit 1 000 000
    function _callback(uint256 chainId, address target, bytes memory payload) internal {
        emit Callback(chainId, target, 1_000_000, payload);
    }
}
