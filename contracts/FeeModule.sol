// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./AdminRegistry.sol";
import "./MyriadCTFExchange.sol";

/// @title FeeModule
/// @notice Stores per-price-point maker/taker fee schedules (100 entries each,
///         one per whole-percent price bucket 0-99%).  Fees accrue inside this
///         contract; a fee-admin can withdraw any amount to any wallet.
contract FeeModule {
  using SafeERC20 for IERC20;

  uint256 private constant BPS = 10000;
  uint256 private constant ONE = 1e18;

  AdminRegistry public immutable registry;
  MyriadCTFExchange public immutable exchange;

  /// @dev makerFees[marketId][priceIndex] = fee in BPS
  mapping(uint256 => uint16[100]) internal _makerFees;
  /// @dev takerFees[marketId][priceIndex] = fee in BPS
  mapping(uint256 => uint16[100]) internal _takerFees;

  /// @notice Total accrued (unclaimed) fees per collateral token.
  mapping(address => uint256) public accruedFees;

  event MarketFeesUpdated(uint256 indexed marketId);
  event FeesAccrued(address indexed token, uint256 amount);
  event FeesWithdrawn(address indexed to, address indexed token, uint256 amount);

  constructor(AdminRegistry _registry, MyriadCTFExchange _exchange) {
    registry = _registry;
    exchange = _exchange;
  }

  // ─── Admin setters ──────────────────────────────────────────────────

  /// @notice Set the full 100-element fee schedules for a market.
  ///         Index i corresponds to the price bucket [i%, (i+1)%).
  function setMarketFees(
    uint256 marketId,
    uint16[100] calldata makerFeeBps,
    uint16[100] calldata takerFeeBps
  ) external {
    require(registry.hasRole(registry.FEE_ADMIN_ROLE(), msg.sender), "not fee admin");
    for (uint256 i = 0; i < 100; i++) {
      require(makerFeeBps[i] <= uint16(BPS) && takerFeeBps[i] <= uint16(BPS), "fee too high");
    }
    _makerFees[marketId] = makerFeeBps;
    _takerFees[marketId] = takerFeeBps;
    emit MarketFeesUpdated(marketId);
  }

  // ─── Getters ─────────────────────────────────────────────────────────

  /// @notice Return the full 100-element maker fee schedule for a market.
  function getMarketMakerFees(uint256 marketId) external view returns (uint16[100] memory) {
    return _makerFees[marketId];
  }

  /// @notice Return the full 100-element taker fee schedule for a market.
  function getMarketTakerFees(uint256 marketId) external view returns (uint16[100] memory) {
    return _takerFees[marketId];
  }

  /// @notice Convenience: return (makerBps, takerBps) for a given price.
  function getFeesAtPrice(uint256 marketId, uint256 price) external view returns (uint16 makerBps, uint16 takerBps) {
    uint256 idx = _priceIndex(price);
    return (_makerFees[marketId][idx], _takerFees[marketId][idx]);
  }

  // ─── Match + accrue ─────────────────────────────────────────────────

  function matchOrdersWithFees(
    MyriadCTFExchange.Order calldata maker,
    bytes calldata makerSig,
    MyriadCTFExchange.Order calldata taker,
    bytes calldata takerSig,
    uint256 fillAmount
  ) external {
    require(registry.hasRole(registry.OPERATOR_ROLE(), msg.sender), "not operator");
    require(maker.marketId == taker.marketId, "market mismatch");

    uint256 makerIdx = _priceIndex(maker.price);
    uint256 takerIdx;

    if (maker.side != taker.side) {
      takerIdx = makerIdx;
    } else {
      takerIdx = _priceIndex(taker.price);
    }

    MyriadCTFExchange.FeeConfig memory feeConfig = MyriadCTFExchange.FeeConfig({
      makerFeeBps: _makerFees[maker.marketId][makerIdx],
      takerFeeBps: _takerFees[maker.marketId][takerIdx]
    });

    uint256 totalFees = exchange.matchOrders(maker, makerSig, taker, takerSig, fillAmount, feeConfig);

    if (totalFees > 0) {
      address token = address(exchange.manager().getMarketCollateral(maker.marketId));
      accruedFees[token] += totalFees;
      emit FeesAccrued(token, totalFees);
    }
  }

  // ─── Withdraw ─────────────────────────────────────────────────────

  /// @notice Withdraw accrued fees for `token` to the specified address.
  ///         Only callable by a fee-admin.
  function withdrawFees(address token, address to, uint256 amount) external {
    require(registry.hasRole(registry.FEE_ADMIN_ROLE(), msg.sender), "not fee admin");
    require(to != address(0), "to 0");
    require(amount > 0, "amount 0");
    require(amount <= accruedFees[token], "insufficient fees");

    accruedFees[token] -= amount;
    IERC20(token).safeTransfer(to, amount);

    emit FeesWithdrawn(to, token, amount);
  }

  // ─── Internal ─────────────────────────────────────────────────────

  /// @dev Map a price (1e18 precision) to a 0-99 bucket index.
  ///      price 0.00-0.0099... -> 0, 0.01-0.0199... -> 1, ... 0.99-0.9999... -> 99
  function _priceIndex(uint256 price) internal pure returns (uint256) {
    uint256 idx = (price * 100) / ONE;
    return idx >= 100 ? 99 : idx;
  }
}
