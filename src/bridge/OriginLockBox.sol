// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IOriginLockBox} from "../interfaces/IOriginLockBox.sol";

/// @title OriginLockBox — Deployed on Arbitrum (or any origin chain)
/// @notice Users lock USDC here; Reactive Network monitors the Deposited event
///         and triggers creditCrossChainDeposit on the Polygon KMarketVault.
contract OriginLockBox is IOriginLockBox, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;

    uint256 public singleCap;
    uint256 public dailyCap;

    uint256 public depositCounter;
    mapping(bytes32 => DepositRecord) private _deposits;

    // Daily volume tracking (resets each UTC day)
    uint256 public override dailyVolume;
    uint256 private _currentDay;

    constructor(address _usdc, address _guardian, uint256 _singleCap, uint256 _dailyCap)
        Ownable(_guardian)
    {
        if (_usdc == address(0) || _guardian == address(0)) revert ZeroAddress();
        usdc = IERC20(_usdc);
        singleCap = _singleCap;
        dailyCap = _dailyCap;
        _currentDay = block.timestamp / 1 days;
    }

    // ═══════════════════════════════════════════════════════════════
    //                          DEPOSIT
    // ═══════════════════════════════════════════════════════════════

    function deposit(uint256 amount, address polygonReceiver) external override nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (polygonReceiver == address(0)) revert ZeroAddress();
        if (amount > singleCap) revert ExceedsSingleCap(amount, singleCap);

        _rollDay();
        if (dailyVolume + amount > dailyCap) revert ExceedsDailyCap(dailyVolume + amount, dailyCap);

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        bytes32 depositId =
            keccak256(abi.encodePacked(block.chainid, depositCounter, msg.sender, amount, block.timestamp));
        depositCounter++;

        _deposits[depositId] = DepositRecord({
            sender: msg.sender,
            receiver: polygonReceiver,
            amount: amount,
            timestamp: block.timestamp,
            refunded: false
        });

        dailyVolume += amount;

        emit Deposited(depositId, msg.sender, polygonReceiver, amount, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════
    //                          REFUND
    // ═══════════════════════════════════════════════════════════════

    function refund(bytes32 depositId) external override onlyOwner nonReentrant {
        DepositRecord storage rec = _deposits[depositId];
        if (rec.sender == address(0)) revert DepositNotFound(depositId);
        if (rec.refunded) revert AlreadyRefunded(depositId);

        rec.refunded = true;
        usdc.safeTransfer(rec.sender, rec.amount);

        emit Refunded(depositId, rec.sender, rec.amount);
    }

    // ═══════════════════════════════════════════════════════════════
    //                       ADMIN SETTINGS
    // ═══════════════════════════════════════════════════════════════

    function setDailyCap(uint256 newCap) external override onlyOwner {
        dailyCap = newCap;
        emit DailyCapUpdated(newCap);
    }

    function setSingleCap(uint256 newCap) external override onlyOwner {
        singleCap = newCap;
        emit SingleCapUpdated(newCap);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ═══════════════════════════════════════════════════════════════
    //                        VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    function getDeposit(bytes32 depositId) external view override returns (DepositRecord memory) {
        return _deposits[depositId];
    }

    // ═══════════════════════════════════════════════════════════════
    //                          INTERNAL
    // ═══════════════════════════════════════════════════════════════

    function _rollDay() internal {
        uint256 today = block.timestamp / 1 days;
        if (today != _currentDay) {
            _currentDay = today;
            dailyVolume = 0;
        }
    }
}
