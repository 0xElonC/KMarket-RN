// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {KMarketVault} from "../src/vault/KMarketVault.sol";
import {SessionKeyRegistry} from "../src/registry/SessionKeyRegistry.sol";
import {KMarketSettlement} from "../src/settlement/KMarketSettlement.sol";
import {OriginLockBox} from "../src/bridge/OriginLockBox.sol";
import {TreasuryRebalancer} from "../src/treasury/TreasuryRebalancer.sol";
import {AaveAdapter} from "../src/treasury/AaveAdapter.sol";

/// @notice Main deployment — Polygon chain (vault, settlement, rebalancer)
contract Deploy is Script {
    function run() external {
        address admin = vm.envAddress("ADMIN");
        address usdc = vm.envAddress("USDC");
        address oracle = vm.envAddress("ORACLE");
        address sequencer = vm.envAddress("SEQUENCER");

        vm.startBroadcast();

        // 1. Deploy Vault
        KMarketVault vault = new KMarketVault(usdc, admin);
        console2.log("KMarketVault:", address(vault));

        // 2. Deploy SessionKeyRegistry
        SessionKeyRegistry registry = new SessionKeyRegistry(admin);
        console2.log("SessionKeyRegistry:", address(registry));

        // 3. Deploy Settlement
        KMarketSettlement settlement = new KMarketSettlement(address(vault), oracle, sequencer, admin);
        console2.log("KMarketSettlement:", address(settlement));

        // 4. Deploy TreasuryRebalancer
        TreasuryRebalancer rebalancer = new TreasuryRebalancer(address(vault), usdc, admin);
        console2.log("TreasuryRebalancer:", address(rebalancer));

        // 5. Grant roles
        vault.grantRole(vault.SETTLEMENT_ROLE(), address(settlement));
        vault.grantRole(vault.SEQUENCER_ROLE(), sequencer);
        vault.grantRole(vault.REBALANCER_ROLE(), address(rebalancer));

        // 6. Set Settlement as recorder for SessionKeyRegistry
        registry.setRecorder(address(settlement), true);

        // 7. Initialize default pools on Settlement contract
        bytes32 ethPool = keccak256("ETH_USDT_10S");
        bytes32 btcPool = keccak256("BTC_USDT_10S");
        settlement.initializePool(ethPool);
        settlement.initializePool(btcPool);
        console2.log("Pools initialized: ETH_USDT_10S, BTC_USDT_10S");

        vm.stopBroadcast();

        console2.log("--- Polygon deployment complete ---");
        console2.log("POST-DEPLOY TODO:");
        console2.log("  1. Deploy AaveAdapter via DeployAaveAdapter script");
        console2.log("  2. rebalancer.setAdapter(aaveAdapterAddr, true)");
        console2.log("  3. rebalancer.setKeeper(reactiveRelayerAddr, true)");
    }
}

/// @notice Origin chain deployment — Arbitrum (OriginLockBox)
contract DeployOrigin is Script {
    function run() external {
        address usdc = vm.envAddress("ORIGIN_USDC");
        address guardian = vm.envAddress("GUARDIAN");
        uint256 singleCap = vm.envOr("SINGLE_CAP", uint256(10_000e6));
        uint256 dailyCap = vm.envOr("DAILY_CAP", uint256(100_000e6));

        vm.startBroadcast();

        OriginLockBox lockBox = new OriginLockBox(usdc, guardian, singleCap, dailyCap);
        console2.log("OriginLockBox:", address(lockBox));

        vm.stopBroadcast();

        console2.log("--- Origin chain deployment complete ---");
    }
}

/// @notice Aave adapter deployment — Polygon (run after Deploy)
contract DeployAaveAdapter is Script {
    function run() external {
        address usdc = vm.envAddress("USDC");
        address aUsdc = vm.envAddress("AAVE_AUSDC");
        address aavePool = vm.envAddress("AAVE_POOL");
        address rebalancer = vm.envAddress("REBALANCER");

        vm.startBroadcast();

        AaveAdapter adapter = new AaveAdapter(usdc, aUsdc, aavePool, rebalancer);
        console2.log("AaveAdapter:", address(adapter));

        // NOTE: After deployment, call rebalancer.setAdapter(address(adapter), true) via admin

        vm.stopBroadcast();

        console2.log("--- Aave adapter deployed ---");
    }
}
