// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IRealityETH_ERC20} from "../contracts/IRealityETH_ERC20.sol";
import {RealitioOracle} from "../contracts/oracles/RealitioOracle.sol";
import {PriceThresholdOracle} from "../contracts/oracles/PriceThresholdOracle.sol";
import {UpOrDownOracle} from "../contracts/oracles/UpOrDownOracle.sol";

/// @notice Deploys oracle contracts for use with PredictionMarketV3ManagerCLOB.
///
///         Required env vars:
///           PRIVATE_KEY        — deployer private key
///           CLOB_MANAGER       — address of the deployed PredictionMarketV3ManagerCLOB
///
///         Optional env vars:
///           REALITIO_ERC20     — Reality.eth address (omit to skip RealitioOracle)
contract DeployOracles is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address managerAddr = vm.envAddress("CLOB_MANAGER");
        address realitioAddr = vm.envOr("REALITIO_ERC20", address(0));

        vm.startBroadcast(privateKey);

        if (realitioAddr != address(0)) {
            RealitioOracle realitioOracle = new RealitioOracle(
                IRealityETH_ERC20(realitioAddr),
                managerAddr
            );
            console.log("RealitioOracle:", address(realitioOracle));
        } else {
            console.log("RealitioOracle: skipped (no REALITIO_ERC20)");
        }

        PriceThresholdOracle priceOracle = new PriceThresholdOracle(managerAddr);
        UpOrDownOracle upDownOracle = new UpOrDownOracle(managerAddr);

        vm.stopBroadcast();

        console.log("PriceThresholdOracle:", address(priceOracle));
        console.log("UpOrDownOracle:", address(upDownOracle));
    }
}
