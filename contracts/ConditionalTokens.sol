// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./AdminRegistry.sol";
import "./IMyriadMarketManager.sol";
import "./Outcomes.sol";

/// @title ConditionalTokens
/// @notice ERC1155 outcome positions for binary (outcome 0 / outcome 1) markets.
///         No privileged minting path — all position creation goes through splitPosition.
contract ConditionalTokens is ERC1155, ReentrancyGuard {
  using SafeERC20 for IERC20;

  AdminRegistry public immutable registry;
  IMyriadMarketManager public immutable manager;

  event PositionSplit(address indexed user, uint256 indexed marketId, address indexed collateral, uint256 amount);
  event PositionMerged(address indexed user, uint256 indexed marketId, address indexed collateral, uint256 amount);
  event PositionRedeemed(address indexed user, uint256 indexed marketId, address indexed collateral, uint8 outcomeId, uint256 amount);
  event VoidedPositionRedeemed(address indexed user, uint256 indexed marketId, address indexed collateral, uint8 outcomeId, uint256 amount);
  event PositionPruned(address indexed user, uint256 indexed marketId, address indexed collateral, uint8 outcomeId, uint256 amount);

  constructor(AdminRegistry _registry, IMyriadMarketManager _manager) ERC1155("") {
    registry = _registry;
    manager = _manager;
  }

  function splitPosition(uint256 marketId, uint256 amount) external nonReentrant {
    require(amount > 0, "amount 0");
    require(manager.getMarketState(marketId) == IMyriadMarketManager.MarketState.open, "market not open");

    IERC20 collateral = manager.getMarketCollateral(marketId);
    collateral.safeTransferFrom(msg.sender, address(this), amount);

    _mint(msg.sender, getTokenId(marketId, Outcomes.YES), amount, "");
    _mint(msg.sender, getTokenId(marketId, Outcomes.NO), amount, "");

    emit PositionSplit(msg.sender, marketId, address(collateral), amount);
  }

  function mergePositions(uint256 marketId, uint256 amount) external nonReentrant {
    require(amount > 0, "amount 0");

    _burn(msg.sender, getTokenId(marketId, Outcomes.YES), amount);
    _burn(msg.sender, getTokenId(marketId, Outcomes.NO), amount);

    IERC20 collateral = manager.getMarketCollateral(marketId);
    collateral.safeTransfer(msg.sender, amount);

    emit PositionMerged(msg.sender, marketId, address(collateral), amount);
  }

  function redeemPosition(uint256 marketId) external nonReentrant {
    int256 outcome = manager.getMarketResolvedOutcome(marketId);
    require(outcome == int256(Outcomes.YES) || outcome == int256(Outcomes.NO), "not resolved");

    uint256 tokenId = getTokenId(marketId, uint256(outcome));
    uint256 amount = balanceOf(msg.sender, tokenId);
    require(amount > 0, "no balance");

    _burn(msg.sender, tokenId, amount);

    IERC20 collateral = manager.getMarketCollateral(marketId);
    collateral.safeTransfer(msg.sender, amount);

    emit PositionRedeemed(msg.sender, marketId, address(collateral), uint8(uint256(outcome)), amount);
  }

  /// @notice Redeem positions from a voided market using admin-specified payout ratios.
  function redeemVoided(uint256 marketId) external nonReentrant {
    int256 outcome = manager.getMarketResolvedOutcome(marketId);
    require(outcome == Outcomes.VOIDED, "not voided");

    (uint256 outcome0Payout, uint256 outcome1Payout) = manager.getVoidedPayouts(marketId);
    require(outcome0Payout + outcome1Payout == 1e18, "invalid payout ratios");

    IERC20 collateral = manager.getMarketCollateral(marketId);

    uint256 outcome0Id = getTokenId(marketId, Outcomes.YES);
    uint256 outcome1Id = getTokenId(marketId, Outcomes.NO);
    uint256 outcome0Balance = balanceOf(msg.sender, outcome0Id);
    uint256 outcome1Balance = balanceOf(msg.sender, outcome1Id);
    require(outcome0Balance > 0 || outcome1Balance > 0, "no balance");

    uint256 totalPayout;

    if (outcome0Balance > 0) {
      _burn(msg.sender, outcome0Id, outcome0Balance);
      totalPayout += (outcome0Balance * outcome0Payout) / 1e18;
      emit VoidedPositionRedeemed(msg.sender, marketId, address(collateral), uint8(Outcomes.YES), outcome0Balance);
    }

    if (outcome1Balance > 0) {
      _burn(msg.sender, outcome1Id, outcome1Balance);
      totalPayout += (outcome1Balance * outcome1Payout) / 1e18;
      emit VoidedPositionRedeemed(msg.sender, marketId, address(collateral), uint8(Outcomes.NO), outcome1Balance);
    }

    require(totalPayout > 0, "zero payout");

    collateral.safeTransfer(msg.sender, totalPayout);
  }

  /// @notice Burn the caller's losing outcome tokens after resolution. Reverts for voided markets or if the caller holds no losing balance.
  function prunePosition(uint256 marketId) external nonReentrant {
    int256 resolvedOutcome = manager.getMarketResolvedOutcome(marketId);
    require(resolvedOutcome == int256(Outcomes.YES) || resolvedOutcome == int256(Outcomes.NO), "not resolved");

    uint8 losingOutcomeId = resolvedOutcome == int256(Outcomes.YES) ? uint8(Outcomes.NO) : uint8(Outcomes.YES);
    uint256 losingTokenId = getTokenId(marketId, losingOutcomeId);
    uint256 amount = balanceOf(msg.sender, losingTokenId);
    require(amount > 0, "no losing balance");

    IERC20 collateral = manager.getMarketCollateral(marketId);

    _burn(msg.sender, losingTokenId, amount);

    emit PositionPruned(msg.sender, marketId, address(collateral), losingOutcomeId, amount);
  }

  function getTokenId(uint256 marketId, uint256 outcome) public pure returns (uint256) {
    return (marketId << 1) | outcome;
  }
}
