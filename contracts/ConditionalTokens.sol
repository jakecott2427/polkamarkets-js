// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./AdminRegistry.sol";
import "./IMyriadMarketManager.sol";

/// @title ConditionalTokens
/// @notice ERC1155 outcome positions for binary (outcome 0 / outcome 1) markets.
///         No privileged minting path — all position creation goes through splitPosition.
contract ConditionalTokens is ERC1155, ReentrancyGuard {
  using SafeERC20 for IERC20;

  AdminRegistry public immutable registry;
  IMyriadMarketManager public immutable manager;

  constructor(AdminRegistry _registry, IMyriadMarketManager _manager) ERC1155("") {
    registry = _registry;
    manager = _manager;
  }

  function splitPosition(uint256 marketId, uint256 amount) external nonReentrant {
    require(amount > 0, "amount 0");
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
    int256 outcome = manager.getMarketResolvedOutcome(marketId);
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
    int256 outcome = manager.getMarketResolvedOutcome(marketId);
    require(outcome == -1, "not voided");

    (uint256 outcome0Payout, uint256 outcome1Payout) = manager.getVoidedPayouts(marketId);
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

  function getTokenId(uint256 marketId, uint256 outcome) public pure returns (uint256) {
    return (marketId << 1) | outcome;
  }
}
