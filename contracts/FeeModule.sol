// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./AdminRegistry.sol";

/// @title FeeModule
/// @notice Stores per-market fee schedules as sorted tiers (up to MAX_TIERS each).
///         The exchange pushes tokens here and calls accrueFees() for accounting.
///         A fee-admin can withdraw to the configured treasury address only.
///
/// @dev Tiers are sorted ascending by maxPrice. The first tier whose maxPrice is
///      strictly greater than the trade price is applied; if none match, fees are 0.
///      Each FeeTier is packed into a single storage slot (128 + 64 + 64 = 256 bits).
contract FeeModule is Initializable, UUPSUpgradeable {
  using SafeERC20 for IERC20;

  // ─── Types ───────────────────────────────────────────────────────────

  /// @notice A fee tier covering prices in [prev.maxPrice, maxPrice).
  struct FeeTier {
    uint128 maxPrice;   // exclusive upper bound in 1e18 (0 < maxPrice <= 1e18)
    uint64 makerFeeBps; // maker fee in basis points (0-10000)
    uint64 takerFeeBps; // taker fee in basis points (0-10000)
  }

  // ─── Constants ───────────────────────────────────────────────────────

  uint256 private constant BPS = 10000;
  uint256 private constant ONE = 1e18;
  uint256 public constant MAX_TIERS = 100;
  uint256 public constant MAX_FEE_BPS = 1000; // 10% max per side

  // ─── State ───────────────────────────────────────────────────────────

  AdminRegistry public registry;

  /// @dev Fee tiers per market, sorted ascending by maxPrice.
  mapping(uint256 => FeeTier[]) internal _marketFees;

  /// @notice Total accrued (unclaimed) fees per collateral token.
  mapping(address => uint256) public accruedFees;

  /// @notice Only address allowed to push fee accruals (set to the exchange).
  address public exchange;

  /// @notice Sole recipient of fee withdrawals.
  address public treasury;

  // ─── Events ──────────────────────────────────────────────────────────

  event MarketFeesUpdated(uint256 indexed marketId, uint256 tierCount);
  event FeesAccrued(address indexed token, uint256 amount);
  event FeesWithdrawn(address indexed treasury, address indexed token, uint256 amount);
  event ExchangeUpdated(address indexed newExchange);
  event TreasuryUpdated(address indexed newTreasury);

  // ─── Constructor / Initializer ──────────────────────────────────────

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(AdminRegistry _registry, address _treasury) public initializer {
    __UUPSUpgradeable_init();

    require(address(_registry) != address(0), "registry 0");
    require(_treasury != address(0), "treasury 0");
    registry = _registry;
    treasury = _treasury;
  }

  function _authorizeUpgrade(address) internal view override {
    require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender), "not admin");
  }

  // ─── Admin setters ──────────────────────────────────────────────────

  function setExchange(address newExchange) external {
    require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender), "not admin");
    require(newExchange != address(0), "exchange 0");
    exchange = newExchange;
    emit ExchangeUpdated(newExchange);
  }

  function setTreasury(address newTreasury) external {
    require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender), "not admin");
    require(newTreasury != address(0), "treasury 0");
    treasury = newTreasury;
    emit TreasuryUpdated(newTreasury);
  }

  function setMarketFees(uint256 marketId, FeeTier[] calldata tiers) external {
    require(registry.hasRole(registry.FEE_ADMIN_ROLE(), msg.sender), "not fee admin");
    require(tiers.length <= MAX_TIERS, "too many tiers");

    for (uint256 i = 0; i < tiers.length; i++) {
      require(tiers[i].maxPrice > 0 && tiers[i].maxPrice <= ONE, "invalid max price");
      require(tiers[i].makerFeeBps <= MAX_FEE_BPS && tiers[i].takerFeeBps <= MAX_FEE_BPS, "fee too high");
      if (i > 0) {
        require(tiers[i].maxPrice > tiers[i - 1].maxPrice, "tiers not sorted");
      }
    }

    delete _marketFees[marketId];
    for (uint256 i = 0; i < tiers.length; i++) {
      _marketFees[marketId].push(tiers[i]);
    }

    emit MarketFeesUpdated(marketId, tiers.length);
  }

  // ─── Getters ─────────────────────────────────────────────────────────

  function getMarketFees(uint256 marketId) external view returns (FeeTier[] memory) {
    return _marketFees[marketId];
  }

  function getFeesAtPrice(uint256 marketId, uint256 price) external view returns (uint16 makerBps, uint16 takerBps) {
    return _lookupFees(marketId, price);
  }

  // ─── Fee accrual ─────────────────────────────────────────────────────

  function accrueFees(address token, uint256 amount) external {
    require(msg.sender == exchange, "only exchange");
    accruedFees[token] += amount;
    require(IERC20(token).balanceOf(address(this)) >= accruedFees[token], "balance < accrued");
    emit FeesAccrued(token, amount);
  }

  // ─── Withdrawal ──────────────────────────────────────────────────────

  function withdrawFees(address token, uint256 amount) external {
    require(registry.hasRole(registry.FEE_ADMIN_ROLE(), msg.sender), "not fee admin");
    require(treasury != address(0), "treasury not set");
    require(amount > 0, "amount 0");
    require(amount <= accruedFees[token], "insufficient fees");

    accruedFees[token] -= amount;
    IERC20(token).safeTransfer(treasury, amount);

    emit FeesWithdrawn(treasury, token, amount);
  }

  // ─── Internal ─────────────────────────────────────────────────────

  function _lookupFees(uint256 marketId, uint256 price) internal view returns (uint16 makerBps, uint16 takerBps) {
    FeeTier[] storage tiers = _marketFees[marketId];
    for (uint256 i = 0; i < tiers.length; i++) {
      if (price < tiers[i].maxPrice) {
        return (uint16(tiers[i].makerFeeBps), uint16(tiers[i].takerFeeBps));
      }
    }
    return (0, 0);
  }
}
