// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PredictionMarketV3ManagerCLOB} from "../contracts/PredictionMarketV3ManagerCLOB.sol";
import {RealitioOracle} from "../contracts/oracles/RealitioOracle.sol";
import {IRealityETH_ERC20} from "../contracts/IRealityETH_ERC20.sol";

/// @notice Submits an answer to a market's Realitio question then resolves.
///
///         Env vars:
///           PRIVATE_KEY       — signer
///           CLOB_MANAGER      — manager address
///           REALITIO_ORACLE   — RealitioOracle address
///           REALITIO          — RealityETH_ERC20 address
///           MARKET_ID         — market to answer & resolve
///           ANSWER            — 0 for outcome 0, 1 for outcome 1
///           BOND              — bond amount in token wei
contract SubmitRealitioAnswer is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address managerAddr = vm.envAddress("CLOB_MANAGER");
        address oracleAddr = vm.envAddress("REALITIO_ORACLE");
        address realitioAddr = vm.envAddress("REALITIO");
        uint256 marketId = vm.envUint("MARKET_ID");
        uint256 answer = vm.envUint("ANSWER");
        uint256 bond = vm.envUint("BOND");

        RealitioOracle oracle = RealitioOracle(oracleAddr);
        IRealityETH_ERC20 realitio = IRealityETH_ERC20(realitioAddr);

        (bytes32 questionId, bool initialized) = oracle.questions(marketId);
        require(initialized, "Market oracle not initialized");

        console.log("Market ID:", marketId);
        console.log("Question ID:");
        console.logBytes32(questionId);
        console.log("Submitting answer:", answer);

        vm.startBroadcast(privateKey);

        realitio.submitAnswerERC20(questionId, bytes32(answer), 0, bond);
        console.log("Answer submitted to RealityETH");

        int256 resolved = PredictionMarketV3ManagerCLOB(managerAddr).resolveMarket(marketId);
        console.log("Market resolved to outcome:", uint256(resolved));

        vm.stopBroadcast();
    }
}
