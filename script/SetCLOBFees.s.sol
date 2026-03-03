// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {FeeModule} from "../contracts/FeeModule.sol";

/// @notice Sets fees for a CLOB market using tiered fee structure.
///         Creates a single tier covering all prices [0, 1e18) with the given BPS values.
contract SetCLOBFees is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address feeModuleAddr = vm.envAddress("CLOB_FEE_MODULE");
    uint256 marketId = vm.envUint("MARKET_ID");
    uint64 makerFeeBps = uint64(vm.envUint("MAKER_FEE_BPS"));
    uint64 takerFeeBps = uint64(vm.envUint("TAKER_FEE_BPS"));

    FeeModule.FeeTier[] memory tiers = new FeeModule.FeeTier[](1);
    tiers[0] = FeeModule.FeeTier({maxPrice: uint128(1e18), makerFeeBps: makerFeeBps, takerFeeBps: takerFeeBps});

    vm.startBroadcast(privateKey);
    FeeModule(feeModuleAddr).setMarketFees(marketId, tiers);
    vm.stopBroadcast();
  }
}
