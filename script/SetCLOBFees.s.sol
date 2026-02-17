// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {FeeModule} from "../contracts/FeeModule.sol";

/// @notice Sets maker/taker fees for a CLOB market.
///         Supports two modes controlled by FEE_CURVE env var:
///           false (default) — flat: every bucket gets the same BPS value.
///           true            — curve: triangle that peaks at the centre and
///                             falls to 0 at both edges (price 0¢ and 99¢).
contract SetCLOBFees is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address feeModule = vm.envAddress("CLOB_FEE_MODULE");
    uint256 marketId = vm.envUint("MARKET_ID");
    uint16 makerFeeBps = uint16(vm.envUint("MAKER_FEE_BPS"));
    uint16 takerFeeBps = uint16(vm.envUint("TAKER_FEE_BPS"));
    bool curve = vm.envOr("FEE_CURVE", false);

    uint16[100] memory makerFees;
    uint16[100] memory takerFees;

    for (uint256 i = 0; i < 100; i++) {
      if (curve) {
        // Triangle: 0 at edges, peak at indices 49-50
        //   i <= 49  →  peak * i / 49
        //   i >= 50  →  peak * (99 - i) / 49
        uint256 weight = i <= 49 ? i : 99 - i; // 0..49
        makerFees[i] = uint16((uint256(makerFeeBps) * weight) / 49);
        takerFees[i] = uint16((uint256(takerFeeBps) * weight) / 49);
      } else {
        makerFees[i] = makerFeeBps;
        takerFees[i] = takerFeeBps;
      }
    }

    vm.startBroadcast(privateKey);
    FeeModule(feeModule).setMarketFees(marketId, makerFees, takerFees);
    vm.stopBroadcast();
  }
}
