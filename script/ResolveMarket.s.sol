// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PredictionMarketV3ManagerCLOB} from "../contracts/PredictionMarketV3ManagerCLOB.sol";

/// @notice Resolves a CLOB market to a given outcome via adminResolveMarket.
///         Env vars: PRIVATE_KEY, CLOB_MANAGER, MARKET_ID, OUTCOME (0, 1, or -1 for void).
contract ResolveMarket is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address managerAddr = vm.envAddress("CLOB_MANAGER");
    uint256 marketId = vm.envUint("MARKET_ID");
    int256 outcome = vm.envInt("OUTCOME");

    require(outcome == 0 || outcome == 1 || outcome == -1, "OUTCOME must be 0, 1, or -1");

    PredictionMarketV3ManagerCLOB manager = PredictionMarketV3ManagerCLOB(managerAddr);

    vm.startBroadcast(privateKey);
    int256 resolved = manager.adminResolveMarket(marketId, outcome);
    vm.stopBroadcast();

    if (outcome == -1) {
      console.log("Market %d voided (outcome -1)", marketId);
    } else {
      console.log("Market %d resolved to outcome %d", marketId, uint256(resolved));
    }
  }
}
