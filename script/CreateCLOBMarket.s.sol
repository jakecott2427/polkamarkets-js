// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PredictionMarketV3ManagerCLOB} from "../contracts/PredictionMarketV3ManagerCLOB.sol";

/// @notice Creates a CLOB market with a pluggable oracle.
///
///         Env vars (required):
///           PRIVATE_KEY    — signer (must have MARKET_ADMIN_ROLE)
///           CLOB_MANAGER   — manager address
///           CLOB_FEE_MODULE — fee module address
///           CLOSES_AT      — unix timestamp when the market closes
///           QUESTION       — market question text
///
///         Env vars (optional):
///           IMAGE          — IPFS hash or URL (default: "")
///           ORACLE         — oracle contract address (default: address(0) = no oracle)
///           ORACLE_TYPE    — one of: "realitio", "price", "updown", "none" (default: "none")
///
///         Oracle-specific env vars:
///
///           ORACLE_TYPE=realitio:
///             ARBITRATOR      — Reality.eth arbitrator address
///             REALITIO_TIMEOUT — timeout in seconds (default: 3600)
///
///           ORACLE_TYPE=price:
///             CHAINLINK_FEED    — Chainlink price feed address
///             PRICE_THRESHOLD   — threshold value (in feed's native decimals, e.g. 100000e8 for $100k)
///             RESOLVE_ABOVE     — "true" if outcome0 wins when price > threshold (default: true)
///
///           ORACLE_TYPE=updown:
///             CHAINLINK_FEED    — Chainlink price feed address
///             RESOLVE_UP        — "true" if outcome0 wins when price goes up (default: true)
contract CreateCLOBMarket is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address managerAddr = vm.envAddress("CLOB_MANAGER");
        address feeModule = vm.envAddress("CLOB_FEE_MODULE");
        uint256 closesAt = vm.envUint("CLOSES_AT");
        string memory question = vm.envString("QUESTION");
        string memory image = vm.envOr("IMAGE", string(""));

        address oracle = vm.envOr("ORACLE", address(0));
        string memory oracleType = vm.envOr("ORACLE_TYPE", string("none"));

        bytes memory oracleData;

        if (_eq(oracleType, "realitio")) {
            address arbitrator = vm.envAddress("ARBITRATOR");
            uint32 timeout = uint32(vm.envOr("REALITIO_TIMEOUT", uint256(3600)));
            oracleData = abi.encode(question, arbitrator, timeout, uint32(closesAt));
        } else if (_eq(oracleType, "price")) {
            address feed = vm.envAddress("CHAINLINK_FEED");
            int256 threshold = vm.envInt("PRICE_THRESHOLD");
            bool resolveAbove = vm.envOr("RESOLVE_ABOVE", true);
            oracleData = abi.encode(feed, threshold, resolveAbove);
        } else if (_eq(oracleType, "updown")) {
            address feed = vm.envAddress("CHAINLINK_FEED");
            bool resolveUp = vm.envOr("RESOLVE_UP", true);
            oracleData = abi.encode(feed, resolveUp);
        }

        vm.startBroadcast(privateKey);

        uint256 marketId = PredictionMarketV3ManagerCLOB(managerAddr).createMarket(
            PredictionMarketV3ManagerCLOB.CreateMarketParams({
                closesAt: closesAt,
                question: question,
                image: image,
                feeModule: feeModule,
                oracle: oracle,
                oracleData: oracleData
            })
        );

        vm.stopBroadcast();

        console.log("Market created with ID:", marketId);
        console.log("Oracle:", oracle);
        console.log("Oracle type:", oracleType);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
