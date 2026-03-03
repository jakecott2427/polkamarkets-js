// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../IMarketOracle.sol";
import "./IAggregatorV3.sol";

/// @title UpOrDownOracle
/// @notice Captures a snapshot of the Chainlink price at market creation and resolves
///         based on whether the price went up or down by resolution time.
///         outcome 0 = price went in the predicted direction, outcome 1 = it didn't.
///
/// @dev    Example: "Will ETH go up in the next 24h?"
///         → feed = ETH/USD, resolveUp = true
///         → At creation, startPrice is captured (e.g. $3,500)
///         → At resolution, if price > $3,500 → outcome 0, else → outcome 1
contract UpOrDownOracle is IMarketOracle {
    uint256 public constant MAX_STALENESS = 1 hours;

    address public immutable manager;

    struct Config {
        IAggregatorV3 feed;
        int256 startPrice;
        bool resolveUp; // true = outcome0 wins when price > startPrice
        bool initialized;
    }

    mapping(uint256 => Config) public configs;

    event UpOrDownConfigured(uint256 indexed marketId, address feed, int256 startPrice, bool resolveUp);

    constructor(address _manager) {
        require(_manager != address(0), "manager 0");
        manager = _manager;
    }

    /// @param data ABI-encoded (address feed, bool resolveUp)
    ///        The start price is automatically captured from the feed at initialization time.
    function initialize(uint256 marketId, bytes calldata data) external override {
        require(msg.sender == manager, "!manager");
        require(!configs[marketId].initialized, "already init");

        (address feed, bool resolveUp) = abi.decode(data, (address, bool));
        require(feed != address(0), "feed 0");

        (, int256 price,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        require(price > 0, "feed: bad price");
        require(block.timestamp - updatedAt <= MAX_STALENESS, "feed: stale");

        configs[marketId] = Config({
            feed: IAggregatorV3(feed),
            startPrice: price,
            resolveUp: resolveUp,
            initialized: true
        });

        emit UpOrDownConfigured(marketId, feed, price, resolveUp);
    }

    function getResult(uint256 marketId) external view override returns (int256 outcome, bool resolved) {
        Config storage c = configs[marketId];
        require(c.initialized, "!init");

        (, int256 price,, uint256 updatedAt,) = c.feed.latestRoundData();
        require(price > 0, "feed: bad price");
        require(block.timestamp - updatedAt <= MAX_STALENESS, "feed: stale");

        bool conditionMet = c.resolveUp
            ? price > c.startPrice
            : price < c.startPrice;

        return (conditionMet ? int256(0) : int256(1), true);
    }
}
