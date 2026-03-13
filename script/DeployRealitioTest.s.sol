// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {RealitioOracle} from "../contracts/oracles/RealitioOracle.sol";
import {IRealityETH_ERC20} from "../contracts/IRealityETH_ERC20.sol";

/// @notice Deploys a RealitioOracle pointing at an existing Reality.eth instance.
///
///         Required env vars:
///           PRIVATE_KEY   — deployer private key
///           CLOB_MANAGER  — address of the deployed PredictionMarketV3ManagerCLOB
///           REALITIO      — address of the deployed RealityETH_ERC20 instance
contract DeployRealitioTest is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address managerAddr = vm.envAddress("CLOB_MANAGER");
        address realitioAddr = vm.envAddress("REALITIO");

        vm.startBroadcast(privateKey);

        RealitioOracle oracle = new RealitioOracle(
            IRealityETH_ERC20(realitioAddr),
            managerAddr
        );
        console.log("RealitioOracle:", address(oracle));

        vm.stopBroadcast();
    }
}
