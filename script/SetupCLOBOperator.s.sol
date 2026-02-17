// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {AdminRegistry} from "../contracts/AdminRegistry.sol";
import {FeeModule} from "../contracts/FeeModule.sol";

/// @title SetupCLOBOperator
/// @notice Grants OPERATOR_ROLE to the matcher wallet and FEE_ADMIN_ROLE to the deployer.
///         Idempotent — safe to re-run if already configured.
contract SetupCLOBOperator is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(privateKey);

    address feeModuleAddr = vm.envAddress("CLOB_FEE_MODULE");
    address operatorAddr = vm.envAddress("OPERATOR");

    FeeModule feeModule = FeeModule(feeModuleAddr);
    AdminRegistry registry = feeModule.registry();

    // ── Diagnostics (read-only) ──────────────────────────────────────
    console.log("=== CLOB Operator Setup ===");
    console.log("FeeModule:", feeModuleAddr);
    console.log("AdminRegistry:", address(registry));
    console.log("Deployer (caller):", deployer);
    console.log("Operator:", operatorAddr);

    bytes32 defaultAdminRole = registry.DEFAULT_ADMIN_ROLE();
    bytes32 operatorRole = registry.OPERATOR_ROLE();
    bytes32 feeAdminRole = registry.FEE_ADMIN_ROLE();

    bool callerIsAdmin = registry.hasRole(defaultAdminRole, deployer);
    bool operatorHasRole = registry.hasRole(operatorRole, operatorAddr);
    bool callerIsFeeAdmin = registry.hasRole(feeAdminRole, deployer);

    console.log("");
    console.log("--- Current State ---");
    console.log("Caller has DEFAULT_ADMIN_ROLE:", callerIsAdmin);
    console.log("Operator has OPERATOR_ROLE:", operatorHasRole);
    console.log("Caller has FEE_ADMIN_ROLE:", callerIsFeeAdmin);

    require(callerIsAdmin, "Caller does not have DEFAULT_ADMIN_ROLE - cannot grant roles");

    // ── Broadcast transactions ───────────────────────────────────────
    vm.startBroadcast(privateKey);

    // 1. Grant OPERATOR_ROLE (idempotent — AccessControl silently skips if already granted)
    if (!operatorHasRole) {
      console.log("");
      console.log("[tx] Granting OPERATOR_ROLE to", operatorAddr);
      registry.grantRole(operatorRole, operatorAddr);
    } else {
      console.log("");
      console.log("[skip] OPERATOR_ROLE already granted to", operatorAddr);
    }

    // 2. Grant FEE_ADMIN_ROLE to caller so they can set market fees & withdraw
    if (!callerIsFeeAdmin) {
      console.log("[tx] Granting FEE_ADMIN_ROLE to", deployer);
      registry.grantRole(feeAdminRole, deployer);
    } else {
      console.log("[skip] FEE_ADMIN_ROLE already granted to", deployer);
    }

    vm.stopBroadcast();

    console.log("");
    console.log("=== Setup complete ===");
  }
}
