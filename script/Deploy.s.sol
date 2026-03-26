// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {KMarketVault} from "../src/vault/KMarketVault.sol";
import {SessionKeyRegistry} from "../src/registry/SessionKeyRegistry.sol";
import {KMarketSettlement} from "../src/settlement/KMarketSettlement.sol";

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

        // 4. Grant roles
        vault.grantRole(vault.SETTLEMENT_ROLE(), address(settlement));
        vault.grantRole(vault.SEQUENCER_ROLE(), sequencer);

        // 5. Set Settlement as recorder for SessionKeyRegistry
        registry.setRecorder(address(settlement), true);

        vm.stopBroadcast();

        console2.log("--- Deployment complete ---");
    }
}
