// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./AdminRegistry.sol";
import "./IMyriadMarketManager.sol";

/// @title ConditionalTokens
/// @notice ERC1155 outcome positions for binary (outcome 0 / outcome 1) markets.
contract ConditionalTokens is ERC1155, ReentrancyGuard {
  using SafeERC20 for IERC20;

  AdminRegistry public immutable registry;
  IMyriadMarketManager public immutable manager;

  address public exchange;

  constructor(AdminRegistry _registry, IMyriadMarketManager _manager) ERC1155("") {
    registry = _registry;
    manager = _manager;
  }

  modifier onlyExchange() {
    require(msg.sender == exchange, "only exchange");
    _;
  }

  function setExchange(address newExchange) external {
    require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender), "not admin");
    exchange = newExchange;
  }

  function splitPosition(uint256 marketId, uint256 amount) external nonReentrant {
    require(amount > 0, "amount 0");
    // Block splits once market is closed or resolved — no new positions in a non-open market.
    require(manager.getMarketState(marketId) == IMyriadMarketManager.MarketState.open, "market not open");

    IERC20 collateral = manager.getMarketCollateral(marketId);
    collateral.safeTransferFrom(msg.sender, address(this), amount);

    _mint(msg.sender, getTokenId(marketId, 0), amount, "");
    _mint(msg.sender, getTokenId(marketId, 1), amount, "");
  }

  function mergePositions(uint256 marketId, uint256 amount) external nonReentrant {
    require(amount > 0, "amount 0");

    _burn(msg.sender, getTokenId(marketId, 0), amount);
    _burn(msg.sender, getTokenId(marketId, 1), amount);

    IERC20 collateral = manager.getMarketCollateral(marketId);
    collateral.safeTransfer(msg.sender, amount);
  }

  function redeemPositions(uint256 marketId) external nonReentrant {
    int256 outcome = manager.getMarketOutcome(marketId);
    require(outcome == 0 || outcome == 1, "not resolved");

    uint256 tokenId = getTokenId(marketId, uint256(outcome));
    uint256 amount = balanceOf(msg.sender, tokenId);
    require(amount > 0, "no balance");

    _burn(msg.sender, tokenId, amount);

    IERC20 collateral = manager.getMarketCollateral(marketId);
    collateral.safeTransfer(msg.sender, amount);
  }

  /// @notice Redeem positions from a voided market using admin-specified payout ratios.
  function redeemVoided(uint256 marketId) external nonReentrant {
    int256 outcome = manager.getMarketOutcome(marketId);
    require(outcome == -1, "not voided");

    (uint256 outcome0Payout, uint256 outcome1Payout) = manager.getVoidedPayouts(marketId);
    // Sanity-check the admin-set ratios on every redemption to prevent over-paying collateral.
    require(outcome0Payout + outcome1Payout == 1e18, "invalid payout ratios");

    uint256 outcome0Id = getTokenId(marketId, 0);
    uint256 outcome1Id = getTokenId(marketId, 1);
    uint256 outcome0Balance = balanceOf(msg.sender, outcome0Id);
    uint256 outcome1Balance = balanceOf(msg.sender, outcome1Id);
    require(outcome0Balance > 0 || outcome1Balance > 0, "no balance");

    uint256 totalPayout;

    if (outcome0Balance > 0) {
      _burn(msg.sender, outcome0Id, outcome0Balance);
      totalPayout += (outcome0Balance * outcome0Payout) / 1e18;
    }

    if (outcome1Balance > 0) {
      _burn(msg.sender, outcome1Id, outcome1Balance);
      totalPayout += (outcome1Balance * outcome1Payout) / 1e18;
    }

    require(totalPayout > 0, "zero payout");

    IERC20 collateral = manager.getMarketCollateral(marketId);
    collateral.safeTransfer(msg.sender, totalPayout);
  }

  /// @notice Exchange-only mint for mint-matched buys.
  function mintPositionsTo(
    address outcome0Recipient,
    address outcome1Recipient,
    uint256 marketId,
    uint256 amount
  ) external onlyExchange {
    require(amount > 0, "amount 0");
    // Guard against minting into a closed/paused/resolved market — a compromised
    // exchange address should not be able to mint positions at will.
    require(manager.getMarketState(marketId) == IMyriadMarketManager.MarketState.open, "market not open");
    require(!manager.isMarketPaused(marketId), "market paused");
    _mint(outcome0Recipient, getTokenId(marketId, 0), amount, "");
    _mint(outcome1Recipient, getTokenId(marketId, 1), amount, "");
  }

  /// @notice Exchange-only merge that burns positions held by the exchange.
  function mergePositionsTo(address recipient, uint256 marketId, uint256 amount) external onlyExchange {
    require(amount > 0, "amount 0");

    _burn(msg.sender, getTokenId(marketId, 0), amount);
    _burn(msg.sender, getTokenId(marketId, 1), amount);

    IERC20 collateral = manager.getMarketCollateral(marketId);
    collateral.safeTransfer(recipient, amount);
  }

  function getTokenId(uint256 marketId, uint256 outcome) public pure returns (uint256) {
    return (marketId << 1) | outcome;
  }
}
