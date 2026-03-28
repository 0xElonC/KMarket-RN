// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title IReactive — Minimal interface for Reactive Network smart contracts
/// @notice See https://docs.reactive.network
interface IReactive {
    /// @notice Called by ReactVM when a subscribed event is detected
    function react(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3,
        bytes calldata data,
        uint256 block_number,
        uint256 op_code
    ) external;
}
