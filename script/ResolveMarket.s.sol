// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PredictionMarketV3ManagerCLOB} from "../contracts/PredictionMarketV3ManagerCLOB.sol";

/// @notice Resolves, admin-resolves, or voids a CLOB market.
///
///         Env vars:
///           PRIVATE_KEY   — signer
///           CLOB_MANAGER  — manager address
///           MARKET_ID     — market to resolve
///           OUTCOME       — resolution mode:
///                            -2  → use oracle (permissionless resolveMarket)
///                             0  → admin resolve to outcome 0
///                             1  → admin resolve to outcome 1
///                            -1  → void (requires OUTCOME0_PAYOUT_PCT, 0-100)
contract ResolveMarket is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address managerAddr = vm.envAddress("CLOB_MANAGER");
    uint256 marketId = vm.envUint("MARKET_ID");
    int256 outcome = vm.envInt("OUTCOME");

    require(
      outcome == -2 || outcome == -1 || outcome == 0 || outcome == 1,
      "OUTCOME must be -2 (oracle), -1 (void), 0, or 1"
    );

    PredictionMarketV3ManagerCLOB manager = PredictionMarketV3ManagerCLOB(managerAddr);

    vm.startBroadcast(privateKey);

    if (outcome == -2) {
      int256 resolved = manager.resolveMarket(marketId);
      console.log("Market %d resolved by oracle to outcome %d", marketId, uint256(resolved));
    } else if (outcome == -1) {
      uint256 pct0 = vm.envUint("OUTCOME0_PAYOUT_PCT");
      require(pct0 <= 100, "OUTCOME0_PAYOUT_PCT must be 0-100");
      uint256 payout0 = (pct0 * 1e18) / 100;
      uint256 payout1 = 1e18 - payout0;
      manager.adminVoidMarket(marketId, payout0, payout1);
      console.log("Market %d voided (outcome 0 %d%%, outcome 1 %d%%)", marketId, pct0, 100 - pct0);
    } else {
      int256 resolved = manager.adminResolveMarket(marketId, outcome);
      console.log("Market %d admin-resolved to outcome %d", marketId, uint256(resolved));
    }

    vm.stopBroadcast();
  }
}
