// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IYieldAdapter — Uniform interface for DeFi yield strategies
interface IYieldAdapter {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external returns (uint256 withdrawn);
    function withdrawAll() external returns (uint256 withdrawn);
    function totalAssets() external view returns (uint256);
    function underlying() external view returns (address);
}
