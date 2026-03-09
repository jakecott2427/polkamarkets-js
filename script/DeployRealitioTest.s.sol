// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {MockRealityETH_ERC20} from "../contracts/oracles/MockRealityETH_ERC20.sol";
import {RealitioOracle} from "../contracts/oracles/RealitioOracle.sol";
import {IRealityETH_ERC20} from "../contracts/IRealityETH_ERC20.sol";

/// @notice Deploys a MockRealityETH_ERC20 and the RealitioOracle for testnet testing.
///
///         Required env vars:
///           PRIVATE_KEY   — deployer private key
///           CLOB_MANAGER  — address of the deployed PredictionMarketV3ManagerCLOB
contract DeployRealitioTest is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address managerAddr = vm.envAddress("CLOB_MANAGER");

        vm.startBroadcast(privateKey);

        MockRealityETH_ERC20 mockRealitio = new MockRealityETH_ERC20();
        console.log("MockRealityETH_ERC20:", address(mockRealitio));

        RealitioOracle oracle = new RealitioOracle(
            IRealityETH_ERC20(address(mockRealitio)),
            managerAddr
        );
        console.log("RealitioOracle:", address(oracle));

        vm.stopBroadcast();
    }
}
