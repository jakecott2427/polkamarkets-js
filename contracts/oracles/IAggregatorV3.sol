// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Minimal Chainlink AggregatorV3Interface — only the functions we use.
// Source: chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}
