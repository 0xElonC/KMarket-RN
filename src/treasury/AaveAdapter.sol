// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

/// @notice Minimal Aave V3 Pool interface used by the adapter
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/// @title AaveAdapter — Deploys idle USDC into Aave V3 on Polygon
/// @notice Only the TreasuryRebalancer (owner) may call deposit / withdraw
contract AaveAdapter is IYieldAdapter, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    IERC20 public immutable aUsdc; // aToken
    IAavePool public immutable pool;

    constructor(address _usdc, address _aUsdc, address _pool, address _owner) Ownable(_owner) {
        usdc = IERC20(_usdc);
        aUsdc = IERC20(_aUsdc);
        pool = IAavePool(_pool);

        // Max-approve Aave pool to pull USDC (for supply) and aToken (for withdraw)
        IERC20(_usdc).approve(_pool, type(uint256).max);
        IERC20(_aUsdc).approve(_pool, type(uint256).max);
    }

    function deposit(uint256 amount) external override onlyOwner {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        pool.supply(address(usdc), amount, address(this), 0);
    }

    function withdraw(uint256 amount) external override onlyOwner returns (uint256 withdrawn) {
        withdrawn = pool.withdraw(address(usdc), amount, msg.sender);
    }

    function withdrawAll() external override onlyOwner returns (uint256 withdrawn) {
        uint256 bal = aUsdc.balanceOf(address(this));
        if (bal == 0) return 0;
        withdrawn = pool.withdraw(address(usdc), bal, msg.sender);
    }

    function totalAssets() external view override returns (uint256) {
        return aUsdc.balanceOf(address(this));
    }

    function underlying() external view override returns (address) {
        return address(usdc);
    }
}
