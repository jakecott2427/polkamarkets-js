// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../IMarketOracle.sol";
import "./IAggregatorV3.sol";

/// @title PriceThresholdOracle
/// @notice Resolves a market based on whether a Chainlink price feed is above or
///         below a threshold at resolution time.
///         outcome 0 wins if the condition is met, outcome 1 otherwise.
///
/// @dev    Example: "Will BTC be above $100k?"
///         → feed = BTC/USD, threshold = 100_000e8, resolveAbove = true
///         → outcome 0 if price > 100k, outcome 1 otherwise
contract PriceThresholdOracle is IMarketOracle {
    /// @notice Maximum age (seconds) of a Chainlink answer before we consider it stale.
    uint256 public constant MAX_STALENESS = 1 hours;

    address public immutable manager;

    struct Config {
        IAggregatorV3 feed;
        int256 threshold;
        bool resolveAbove; // true = outcome0 wins when price > threshold
        bool initialized;
    }

    mapping(uint256 => Config) public configs;

    event PriceConfigured(uint256 indexed marketId, address feed, int256 threshold, bool resolveAbove);

    constructor(address _manager) {
        require(_manager != address(0), "manager 0");
        manager = _manager;
    }

    /// @param data ABI-encoded (address feed, int256 threshold, bool resolveAbove)
    function initialize(uint256 marketId, bytes calldata data) external override {
        require(msg.sender == manager, "!manager");
        require(!configs[marketId].initialized, "already init");

        (address feed, int256 threshold, bool resolveAbove) =
            abi.decode(data, (address, int256, bool));

        require(feed != address(0), "feed 0");

        // Validate the feed is responding
        (, int256 price,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        require(price > 0, "feed: bad price");
        require(block.timestamp - updatedAt <= MAX_STALENESS, "feed: stale");

        configs[marketId] = Config({
            feed: IAggregatorV3(feed),
            threshold: threshold,
            resolveAbove: resolveAbove,
            initialized: true
        });

        emit PriceConfigured(marketId, feed, threshold, resolveAbove);
    }

    function getResult(uint256 marketId) external view override returns (int256 outcome, bool resolved) {
        Config storage c = configs[marketId];
        require(c.initialized, "!init");

        (, int256 price,, uint256 updatedAt,) = c.feed.latestRoundData();
        require(price > 0, "feed: bad price");
        require(block.timestamp - updatedAt <= MAX_STALENESS, "feed: stale");

        bool conditionMet = c.resolveAbove
            ? price > c.threshold
            : price < c.threshold;

        return (conditionMet ? int256(0) : int256(1), true);
    }
}
