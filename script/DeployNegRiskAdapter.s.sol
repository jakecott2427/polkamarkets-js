// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AdminRegistry} from "../contracts/AdminRegistry.sol";
import {PredictionMarketV3ManagerCLOB} from "../contracts/PredictionMarketV3ManagerCLOB.sol";
import {ConditionalTokens} from "../contracts/ConditionalTokens.sol";
import {MyriadCTFExchange} from "../contracts/MyriadCTFExchange.sol";
import {WrappedCollateral} from "../contracts/WrappedCollateral.sol";
import {NegRiskAdapter} from "../contracts/NegRiskAdapter.sol";

/// @notice Deploys WrappedCollateral + NegRiskAdapter and wires them to
///         the existing CLOB stack (Manager, Exchange, AdminRegistry).
///
///         Env vars:
///           PRIVATE_KEY           — deployer private key
///           ADMIN_REGISTRY        — AdminRegistry address
///           CLOB_MANAGER          — Manager address
///           CLOB_CONDITIONAL_TOKENS — ConditionalTokens address
///           CLOB_EXCHANGE         — Exchange address
///           COLLATERAL            — underlying collateral token (e.g. USDC)
///           TREASURY              — fee treasury address
contract DeployNegRiskAdapter is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");

    address registryAddr = vm.envAddress("ADMIN_REGISTRY");
    address managerAddr = vm.envAddress("CLOB_MANAGER");
    address ctAddr = vm.envAddress("CLOB_CONDITIONAL_TOKENS");
    address exchangeAddr = vm.envAddress("CLOB_EXCHANGE");
    address collateral = vm.envAddress("COLLATERAL");
    address treasuryAddr = vm.envAddress("TREASURY");

    AdminRegistry registry = AdminRegistry(registryAddr);

    vm.startBroadcast(privateKey);

    // Deploy WrappedCollateral (adapter address not known yet, use CREATE2-style workaround)
    // We deploy adapter first with a placeholder, then set. Actually, WrappedCollateral
    // needs the adapter address at construction. We use a two-step approach:
    // 1. Predict adapter address via CREATE nonce
    // 2. Deploy wcol with predicted address
    // 3. Deploy adapter with wcol

    // Simpler approach: deploy adapter first, then wcol, then link.
    // But wcol.adapter is immutable, so we need to know the adapter address first.
    // Use vm.computeCreateAddress to predict.

    address deployer = vm.addr(privateKey);
    uint64 nonce = vm.getNonce(deployer);
    // wcol will be deployed at nonce, adapter at nonce+1
    address predictedAdapter = vm.computeCreateAddress(deployer, nonce + 1);

    WrappedCollateral wcolContract = new WrappedCollateral(
      IERC20(collateral),
      predictedAdapter
    );

    NegRiskAdapter adapter = new NegRiskAdapter(
      registry,
      PredictionMarketV3ManagerCLOB(managerAddr),
      ConditionalTokens(ctAddr),
      wcolContract,
      treasuryAddr
    );

    require(address(adapter) == predictedAdapter, "adapter address mismatch");

    // Wire adapter to Manager and Exchange
    PredictionMarketV3ManagerCLOB(managerAddr).setNegRiskAdapter(address(adapter));
    MyriadCTFExchange(exchangeAddr).setNegRiskAdapter(address(adapter));
    adapter.setExchange(exchangeAddr);

    // Grant roles to adapter
    registry.grantRole(registry.MARKET_ADMIN_ROLE(), address(adapter));
    registry.grantRole(registry.RESOLUTION_ADMIN_ROLE(), address(adapter));

    vm.stopBroadcast();

    console.log("WrappedCollateral:", address(wcolContract));
    console.log("NegRiskAdapter:", address(adapter));
  }
}
