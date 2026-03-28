// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {AbstractReactive} from "./AbstractReactive.sol";
import {IKMarketVault} from "../interfaces/IKMarketVault.sol";

/// @title ReactiveDepositRouter — RSC deployed on Reactive Network (ReactVM)
/// @notice Monitors OriginLockBox.Deposited events on Arbitrum, then emits a Callback
///         that invokes KMarketVault.creditCrossChainDeposit on Polygon.
contract ReactiveDepositRouter is AbstractReactive {
    /// @dev topic0 of OriginLockBox.Deposited(bytes32,address,address,uint256,uint256)
    uint256 private immutable DEPOSITED_TOPIC0;

    uint256 public immutable originChainId;   // e.g. 42161 (Arbitrum)
    address public immutable lockBox;          // OriginLockBox address on Arbitrum
    uint256 public immutable destinationChainId; // e.g. 137 (Polygon)
    address public immutable vault;            // KMarketVault address on Polygon

    mapping(bytes32 => bool) public processedDeposits;

    event DepositRouted(bytes32 indexed depositId, address indexed receiver, uint256 amount);

    error DepositAlreadyProcessed(bytes32 depositId);
    error UnexpectedOrigin(uint256 chainId, address origin);

    constructor(
        uint256 _originChainId,
        address _lockBox,
        uint256 _destinationChainId,
        address _vault
    ) {
        originChainId = _originChainId;
        lockBox = _lockBox;
        destinationChainId = _destinationChainId;
        vault = _vault;

        // Deposited(bytes32 indexed depositId, address indexed sender, address indexed receiver, uint256 amount, uint256 timestamp)
        DEPOSITED_TOPIC0 = uint256(keccak256("Deposited(bytes32,address,address,uint256,uint256)"));

        // Subscribe to Deposited events from the LockBox on the origin chain
        // topic_1/2/3 = REACTIVE_IGNORE → match all senders / receivers / depositIds
        SERVICE.subscribe(
            _originChainId,
            _lockBox,
            DEPOSITED_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @notice Called by ReactVM when a matching event is detected
    function react(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1, // depositId (indexed)
        uint256 topic_2, // sender (indexed)
        uint256 topic_3, // receiver (indexed)
        bytes calldata data,
        uint256, /* block_number */
        uint256  /* op_code */
    ) external override {
        // Safety: only process expected origin
        if (chain_id != originChainId || _contract != lockBox) {
            revert UnexpectedOrigin(chain_id, _contract);
        }

        // Must match our subscribed topic
        if (topic_0 != DEPOSITED_TOPIC0) return;

        // Decode indexed parameters
        bytes32 depositId = bytes32(topic_1);
        address receiver = address(uint160(topic_3));

        // Decode non-indexed data: (uint256 amount, uint256 timestamp)
        (uint256 amount,) = abi.decode(data, (uint256, uint256));

        // Idempotency check
        if (processedDeposits[depositId]) revert DepositAlreadyProcessed(depositId);
        processedDeposits[depositId] = true;

        // Emit Callback → Reactive Relayer executes on Polygon
        bytes memory payload =
            abi.encodeCall(IKMarketVault.creditCrossChainDeposit, (depositId, receiver, amount));
        _callback(destinationChainId, vault, payload);

        emit DepositRouted(depositId, receiver, amount);
    }
}
