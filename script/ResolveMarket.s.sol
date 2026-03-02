// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PredictionMarketV3ManagerCLOB} from "../contracts/PredictionMarketV3ManagerCLOB.sol";

/// @notice Resolves or voids a CLOB market.
///         Env vars: PRIVATE_KEY, CLOB_MANAGER, MARKET_ID, OUTCOME (0, 1, or -1 for void).
///         When OUTCOME=-1, also requires YES_PAYOUT_PCT (0-100) — NO gets the remainder.
contract ResolveMarket is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address managerAddr = vm.envAddress("CLOB_MANAGER");
    uint256 marketId = vm.envUint("MARKET_ID");
    int256 outcome = vm.envInt("OUTCOME");

    require(outcome == 0 || outcome == 1 || outcome == -1, "OUTCOME must be 0, 1, or -1");

    PredictionMarketV3ManagerCLOB manager = PredictionMarketV3ManagerCLOB(managerAddr);

    vm.startBroadcast(privateKey);

    if (outcome == -1) {
      uint256 yesPct = vm.envUint("YES_PAYOUT_PCT");
      require(yesPct <= 100, "YES_PAYOUT_PCT must be 0-100");
      uint256 yesPayout = (yesPct * 1e18) / 100;
      uint256 noPayout = 1e18 - yesPayout;
      manager.adminVoidMarket(marketId, yesPayout, noPayout);
      console.log("Market %d voided (YES %d%%, NO %d%%)", marketId, yesPct, 100 - yesPct);
    } else {
      int256 resolved = manager.adminResolveMarket(marketId, outcome);
      console.log("Market %d resolved to outcome %d", marketId, uint256(resolved));
    }

    vm.stopBroadcast();
  }
}
