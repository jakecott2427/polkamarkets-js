// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import "./AdminRegistry.sol";
import "./ConditionalTokens.sol";
import "./IMyriadMarketManager.sol";

/// @dev Minimal interface consumed by the exchange. FeeModule implements these.
interface IFeeModule {
  /// @notice Return (makerFeeBps, takerFeeBps) for a given market price.
  function getFeesAtPrice(uint256 marketId, uint256 price) external view returns (uint16 makerBps, uint16 takerBps);

  /// @notice Record `amount` of `token` as accrued protocol fees.
  ///         Caller must have already transferred the tokens to FeeModule.
  function accrueFees(address token, uint256 amount) external;
}

/// @dev Minimal interface for the NegRiskAdapter, used by cross-market matching.
interface INegRiskAdapter {
  function mintAllYesTokens(bytes32 eventId, uint256 amount, address recipient) external;
  function getEventOutcomeCount(bytes32 eventId) external view returns (uint256);
}

/// @title MyriadCTFExchange
/// @notice On-chain settlement engine for matched signed orders with partial fill support.
///         Fees are looked up from FeeModule and accrued there after each match.
contract MyriadCTFExchange is ReentrancyGuard, Pausable, ERC1155Holder, EIP712 {
  using SafeERC20 for IERC20;

  enum Side {
    Buy,
    Sell
  }

  struct Order {
    address trader;
    uint256 marketId;
    uint8 outcome; // 0 = outcome 0, 1 = outcome 1
    Side side;
    uint256 amount;       // max shares for this order
    uint256 price;        // collateral per share, 1e18 precision
    uint256 minFillAmount; // minimum fill size; 0 = no minimum (slippage protection)
    uint256 nonce;
    uint256 expiration;
  }

  struct FeeConfig {
    uint256 makerFeeBps;
    uint256 takerFeeBps;
  }

  bytes32 private constant ORDER_TYPEHASH =
    keccak256(
      "Order(address trader,uint256 marketId,uint8 outcome,uint8 side,uint256 amount,uint256 price,uint256 minFillAmount,uint256 nonce,uint256 expiration)"
    );
  uint256 private constant ONE = 1e18;
  uint256 private constant BPS = 10000;

  AdminRegistry public immutable registry;
  IMyriadMarketManager public immutable manager;
  ConditionalTokens public immutable conditionalTokens;
  address public immutable feeModule;

  /// @notice NegRiskAdapter address for cross-market matching.
  address public negRiskAdapter;

  /// @notice Tracks cancellations — once true, the order can never be matched.
  mapping(bytes32 => bool) public orderInvalidated;

  /// @notice Cumulative fill amount per order hash (supports partial fills).
  mapping(bytes32 => uint256) public filledAmounts;

  event OrderCancelled(bytes32 indexed orderHash, address indexed trader);
  /// @notice Emitted on every successful match.
  ///         `makerTotalFilled` and `takerTotalFilled` are the cumulative fills
  ///         after this match, enabling off-chain book-keeping.
  event OrdersMatched(
    bytes32 indexed makerHash,
    bytes32 indexed takerHash,
    uint256 marketId,
    uint256 fillAmount,
    uint256 makerTotalFilled,
    uint256 takerTotalFilled
  );
  /// @notice Emitted for each order filled in a cross-market match.
  event CrossMarketOrderFilled(
    bytes32 indexed orderHash,
    bytes32 indexed eventId,
    uint256 marketId,
    uint256 fillAmount,
    uint256 totalFilled
  );

  constructor(
    IMyriadMarketManager _manager,
    ConditionalTokens _conditionalTokens,
    address _feeModule,
    AdminRegistry _registry
  ) EIP712("MyriadCTFExchange", "1") {
    manager = _manager;
    conditionalTokens = _conditionalTokens;
    feeModule = _feeModule;
    registry = _registry;
  }

  // ─── Emergency controls ───────────────────────────────────────────────

  function pause() external {
    require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender), "not admin");
    _pause();
  }

  function unpause() external {
    require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender), "not admin");
    _unpause();
  }

  function setNegRiskAdapter(address _adapter) external {
    require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender), "not admin");
    negRiskAdapter = _adapter;
  }

  // ─── Order management ────────────────────────────────────────────────

  function cancelOrders(Order[] calldata orders) external {
    for (uint256 i = 0; i < orders.length; i++) {
      Order calldata order = orders[i];
      require(order.trader == msg.sender, "not trader");
      bytes32 orderHash = hashOrder(order);
      require(!orderInvalidated[orderHash], "already cancelled");
      orderInvalidated[orderHash] = true;
      emit OrderCancelled(orderHash, msg.sender);
    }
  }

  // ─── Settlement entry point ──────────────────────────────────────────

  /// @notice Match two signed orders, filling `fillAmount` shares.
  ///         Only callable by an address holding OPERATOR_ROLE.
  ///         Fee rates are looked up from FeeModule based on order prices.
  function matchOrdersWithFees(
    Order calldata maker,
    bytes calldata makerSig,
    Order calldata taker,
    bytes calldata takerSig,
    uint256 fillAmount
  ) external whenNotPaused nonReentrant {
    require(registry.hasRole(registry.OPERATOR_ROLE(), msg.sender), "not operator");
    require(maker.marketId == taker.marketId, "market mismatch");

    // Build fee config from FeeModule schedules.
    // Direct match: both parties priced at maker's tier.
    // Mint / merge match: each party uses their own price tier.
    FeeConfig memory feeConfig;
    if (maker.side != taker.side) {
      (feeConfig.makerFeeBps, feeConfig.takerFeeBps) =
        IFeeModule(feeModule).getFeesAtPrice(maker.marketId, maker.price);
    } else {
      (feeConfig.makerFeeBps, ) = IFeeModule(feeModule).getFeesAtPrice(maker.marketId, maker.price);
      (, feeConfig.takerFeeBps) = IFeeModule(feeModule).getFeesAtPrice(maker.marketId, taker.price);
    }

    uint256 totalFees = _matchOrders(maker, makerSig, taker, takerSig, fillAmount, feeConfig);

    if (totalFees > 0) {
      address token = address(manager.getMarketCollateral(maker.marketId));
      IFeeModule(feeModule).accrueFees(token, totalFees);
    }
  }

  // ─── Cross-market settlement ─────────────────────────────────────────

  /// @notice Match BUY YES orders across different outcome markets in the same
  ///         neg risk event. All orders must be BUY side, outcome 0 (YES), for
  ///         distinct markets belonging to the same event. Prices must sum to >= ONE.
  ///         The NegRiskAdapter mints YES tokens via split + convert.
  ///         Same-trader orders across different outcomes are intentionally allowed,
  ///         as a trader may legitimately want YES exposure on multiple outcomes.
  function matchCrossMarketOrders(
    Order[] calldata orders,
    bytes[] calldata signatures,
    uint256 fillAmount
  ) external whenNotPaused nonReentrant {
    require(registry.hasRole(registry.OPERATOR_ROLE(), msg.sender), "not operator");
    require(negRiskAdapter != address(0), "no adapter");
    require(orders.length >= 2, "need >= 2 orders");
    require(signatures.length == orders.length, "sig count");
    require(fillAmount > 0, "fill 0");

    // Must provide one order per outcome to prevent stuck YES tokens
    {
      uint256 expectedCount = INegRiskAdapter(negRiskAdapter).getEventOutcomeCount(
        manager.getEventId(orders[0].marketId)
      );
      require(orders.length == expectedCount, "must match all outcomes");
    }

    // Validate orders: all BUY YES, all different markets in the same event
    bytes32 eventId = manager.getEventId(orders[0].marketId);
    require(eventId != bytes32(0), "not neg risk");

    uint256 priceSum;

    for (uint256 i = 0; i < orders.length; i++) {
      Order calldata order = orders[i];
      require(order.side == Side.Buy, "not buy");
      require(order.outcome == 0, "not YES");
      require(order.price > 0 && order.price <= ONE, "bad price");
      require(manager.getEventId(order.marketId) == eventId, "event mismatch");
      require(manager.isNegRisk(order.marketId), "not neg risk");

      _requireMarketOpen(order.marketId);
      _validateOrder(order, signatures[i]);

      bytes32 orderHash = hashOrder(order);
      require(filledAmounts[orderHash] + fillAmount <= order.amount, "overfill");
      require(order.minFillAmount == 0 || fillAmount >= order.minFillAmount, "below min fill");

      // Check no duplicate markets
      for (uint256 j = 0; j < i; j++) {
        require(order.marketId != orders[j].marketId, "dup market");
      }

      priceSum += order.price;
    }

    require(priceSum >= ONE, "price sum < 1");

    // Collect wcol from each buyer and calculate fees.
    // Convention: last order = taker (charged takerBps), all others = makers (charged makerBps).
    IERC20 collateral = manager.getMarketCollateral(orders[0].marketId);
    uint256 totalFees;
    uint256 totalCollected;
    uint256 takerIdx = orders.length - 1;

    uint256 collectedSoFar;
    for (uint256 i = 0; i < orders.length; i++) {
      // Taker (last) pays whatever remains to cover fillAmount; may be 0 when makers already covered it
      uint256 notional;
      if (i == orders.length - 1) {
        notional = collectedSoFar >= fillAmount ? 0 : fillAmount - collectedSoFar;
      } else {
        notional = (fillAmount * orders[i].price) / ONE;
        collectedSoFar += notional;
        require(notional > 0, "notional 0");
      }

      uint256 fee;
      if (i == takerIdx) {
        (, uint16 takerBps) = IFeeModule(feeModule).getFeesAtPrice(orders[i].marketId, orders[i].price);
        fee = (notional * takerBps) / BPS;
      } else {
        (uint16 makerBps, ) = IFeeModule(feeModule).getFeesAtPrice(orders[i].marketId, orders[i].price);
        fee = (notional * makerBps) / BPS;
      }
      totalFees += fee;
      totalCollected += notional;

      collateral.safeTransferFrom(orders[i].trader, address(this), notional + fee);
    }

    // Use forceApprove to handle tokens like USDT that revert on non-zero-to-non-zero approve
    collateral.forceApprove(negRiskAdapter, fillAmount);
    INegRiskAdapter(negRiskAdapter).mintAllYesTokens(eventId, fillAmount, address(this));

    // Distribute YES tokens to each buyer
    for (uint256 i = 0; i < orders.length; i++) {
      uint256 tokenId = conditionalTokens.getTokenId(orders[i].marketId, 0);
      conditionalTokens.safeTransferFrom(address(this), orders[i].trader, tokenId, fillAmount, "");

      bytes32 orderHash = hashOrder(orders[i]);
      filledAmounts[orderHash] += fillAmount;

      emit CrossMarketOrderFilled(orderHash, eventId, orders[i].marketId, fillAmount, filledAmounts[orderHash]);
    }

    // Accrue fees + any price surplus (totalCollected - fillAmount)
    uint256 surplus = totalCollected > fillAmount ? totalCollected - fillAmount : 0;
    uint256 totalToAccrue = totalFees + surplus;
    if (totalToAccrue > 0) {
      collateral.safeTransfer(feeModule, totalToAccrue);
      IFeeModule(feeModule).accrueFees(address(collateral), totalToAccrue);
    }
  }

  // ─── View helpers ─────────────────────────────────────────────────────

  function hashOrder(Order calldata order) public view returns (bytes32) {
    return
      _hashTypedDataV4(
        keccak256(
          abi.encode(
            ORDER_TYPEHASH,
            order.trader,
            order.marketId,
            order.outcome,
            order.side,
            order.amount,
            order.price,
            order.minFillAmount,
            order.nonce,
            order.expiration
          )
        )
      );
  }

  /// @notice Expose the EIP712 domain separator so off-chain clients can build
  ///         correctly-scoped signatures without hard-coding chain IDs.
  function DOMAIN_SEPARATOR() external view returns (bytes32) {
    return _domainSeparatorV4();
  }

  /// @notice Convenience query: returns cumulative fill and cancellation state.
  function getOrderStatus(bytes32 orderHash) external view returns (uint256 filled, bool invalidated) {
    return (filledAmounts[orderHash], orderInvalidated[orderHash]);
  }

  // ─── Internal settlement ─────────────────────────────────────────────

  function _matchOrders(
    Order calldata maker,
    bytes calldata makerSig,
    Order calldata taker,
    bytes calldata takerSig,
    uint256 fillAmount,
    FeeConfig memory feeConfig
  ) internal returns (uint256 totalFees) {
    _validateFeeConfig(feeConfig);
    _validateOrder(maker, makerSig);
    _validateOrder(taker, takerSig);

    require(maker.trader != taker.trader, "self trade");
    require(maker.outcome < 2 && taker.outcome < 2, "bad outcome");
    require(maker.price > 0 && taker.price > 0, "bad price");
    require(maker.price <= ONE && taker.price <= ONE, "price > 1");
    require(fillAmount > 0, "fill 0");

    bytes32 makerHash = hashOrder(maker);
    bytes32 takerHash = hashOrder(taker);

    require(filledAmounts[makerHash] + fillAmount <= maker.amount, "maker overfill");
    require(filledAmounts[takerHash] + fillAmount <= taker.amount, "taker overfill");

    // Slippage protection: enforce minimum fill sizes.
    require(maker.minFillAmount == 0 || fillAmount >= maker.minFillAmount, "below maker min fill");
    require(taker.minFillAmount == 0 || fillAmount >= taker.minFillAmount, "below taker min fill");

    filledAmounts[makerHash] += fillAmount;
    filledAmounts[takerHash] += fillAmount;

    if (maker.side != taker.side) {
      totalFees = _settleDirectMatch(maker, taker, fillAmount, feeConfig);
    } else if (maker.side == Side.Buy) {
      totalFees = _settleMintMatch(maker, taker, fillAmount, feeConfig);
    } else {
      totalFees = _settleMergeMatch(maker, taker, fillAmount, feeConfig);
    }

    emit OrdersMatched(makerHash, takerHash, maker.marketId, fillAmount, filledAmounts[makerHash], filledAmounts[takerHash]);
  }

  function _validateOrder(Order calldata order, bytes calldata signature) internal view {
    require(order.trader != address(0), "trader 0");
    require(order.amount > 0, "amount 0");
    require(order.expiration == 0 || order.expiration >= block.timestamp, "expired");

    bytes32 orderHash = hashOrder(order);
    require(!orderInvalidated[orderHash], "invalidated");

    // Use tryRecover so we can emit distinct errors for malformed vs wrong signer.
    (address signer, ECDSA.RecoverError recoverError, ) = ECDSA.tryRecover(orderHash, signature);
    require(recoverError == ECDSA.RecoverError.NoError, "invalid signature");
    require(signer == order.trader, "signer mismatch");
  }

  function _validateFeeConfig(FeeConfig memory feeConfig) internal pure {
    require(feeConfig.makerFeeBps <= BPS, "maker fee");
    require(feeConfig.takerFeeBps <= BPS, "taker fee");
  }

  function _settleDirectMatch(
    Order calldata maker,
    Order calldata taker,
    uint256 fillAmount,
    FeeConfig memory feeConfig
  ) internal returns (uint256 totalProtocolFees) {
    require(maker.outcome == taker.outcome, "outcome mismatch");

    if (maker.side == Side.Buy) {
      require(taker.side == Side.Sell, "side mismatch");
      require(maker.price >= taker.price, "price mismatch");
    } else {
      require(taker.side == Side.Buy, "side mismatch");
      require(maker.price <= taker.price, "price mismatch");
    }

    _requireMarketOpen(maker.marketId);

    uint256 executionPrice = maker.price;
    uint256 notional = (fillAmount * executionPrice) / ONE;
    require(notional > 0, "notional 0");

    IERC20 collateral = manager.getMarketCollateral(maker.marketId);
    uint256 makerFee = (notional * feeConfig.makerFeeBps) / BPS;
    uint256 takerFee = (notional * feeConfig.takerFeeBps) / BPS;
    totalProtocolFees = makerFee + takerFee;

    address buyer = maker.side == Side.Buy ? maker.trader : taker.trader;
    address seller = maker.side == Side.Sell ? maker.trader : taker.trader;
    bool makerIsBuyer = (maker.side == Side.Buy);

    uint256 buyerFee = makerIsBuyer ? makerFee : takerFee;
    uint256 buyerPayment = notional + buyerFee;
    collateral.safeTransferFrom(buyer, address(this), buyerPayment);

    conditionalTokens.safeTransferFrom(
      seller,
      buyer,
      conditionalTokens.getTokenId(maker.marketId, maker.outcome),
      fillAmount,
      ""
    );

    uint256 sellerFee = makerIsBuyer ? takerFee : makerFee;
    require(notional >= sellerFee, "fees exceed proceeds");
    uint256 sellerProceeds = notional - sellerFee;
    collateral.safeTransfer(seller, sellerProceeds);

    if (totalProtocolFees > 0) {
      collateral.safeTransfer(feeModule, totalProtocolFees);
    }
  }

  function _settleMintMatch(
    Order calldata maker,
    Order calldata taker,
    uint256 fillAmount,
    FeeConfig memory feeConfig
  ) internal returns (uint256 totalProtocolFees) {
    require(maker.side == Side.Buy && taker.side == Side.Buy, "side mismatch");
    require(maker.outcome != taker.outcome, "same outcome");
    _requireMarketOpen(maker.marketId);

    (Order calldata outcome0Order, Order calldata outcome1Order) = maker.outcome == 0 ? (maker, taker) : (taker, maker);
    require(outcome0Order.price + outcome1Order.price == ONE, "price sum");

    IERC20 collateral = manager.getMarketCollateral(maker.marketId);

    uint256 outcome0Notional = (fillAmount * outcome0Order.price) / ONE;
    uint256 outcome1Notional = fillAmount - outcome0Notional;
    require(outcome0Notional > 0 && outcome1Notional > 0, "notional 0");

    collateral.safeTransferFrom(outcome0Order.trader, address(conditionalTokens), outcome0Notional);
    collateral.safeTransferFrom(outcome1Order.trader, address(conditionalTokens), outcome1Notional);

    conditionalTokens.mintPositionsTo(outcome0Order.trader, outcome1Order.trader, maker.marketId, fillAmount);

    totalProtocolFees = _collectFees(maker, taker, fillAmount, feeConfig, collateral);
  }

  function _settleMergeMatch(
    Order calldata maker,
    Order calldata taker,
    uint256 fillAmount,
    FeeConfig memory feeConfig
  ) internal returns (uint256 totalProtocolFees) {
    require(maker.side == Side.Sell && taker.side == Side.Sell, "side mismatch");
    require(maker.outcome != taker.outcome, "same outcome");
    _requireMarketOpen(maker.marketId);

    (Order calldata outcome0Order, Order calldata outcome1Order) = maker.outcome == 0 ? (maker, taker) : (taker, maker);
    require(outcome0Order.price + outcome1Order.price == ONE, "price sum");

    uint256 outcome0TokenId = conditionalTokens.getTokenId(maker.marketId, 0);
    uint256 outcome1TokenId = conditionalTokens.getTokenId(maker.marketId, 1);

    // Transfer outcome tokens to exchange before merging.
    conditionalTokens.safeTransferFrom(outcome0Order.trader, address(this), outcome0TokenId, fillAmount, "");
    conditionalTokens.safeTransferFrom(outcome1Order.trader, address(this), outcome1TokenId, fillAmount, "");

    // Merge both outcome tokens back to collateral; reverts atomically if balances are insufficient.
    conditionalTokens.mergePositionsTo(address(this), maker.marketId, fillAmount);

    IERC20 collateral = manager.getMarketCollateral(maker.marketId);

    uint256 outcome0Notional = (fillAmount * outcome0Order.price) / ONE;
    uint256 outcome1Notional = fillAmount - outcome0Notional;
    require(outcome0Notional > 0 && outcome1Notional > 0, "notional 0");

    totalProtocolFees = _paySellerWithFees(maker, taker, fillAmount, feeConfig, collateral, outcome0Order, outcome1Order, outcome0Notional, outcome1Notional);
  }

  /// @dev Fee collection for mint matches — each buyer pays their own fee on top of notional.
  function _collectFees(
    Order calldata maker,
    Order calldata taker,
    uint256 fillAmount,
    FeeConfig memory feeConfig,
    IERC20 collateral
  ) internal returns (uint256 totalProtocolFees) {
    uint256 makerNotional = (fillAmount * maker.price) / ONE;
    uint256 takerNotional = fillAmount - makerNotional;

    uint256 makerFee = (makerNotional * feeConfig.makerFeeBps) / BPS;
    uint256 takerFee = (takerNotional * feeConfig.takerFeeBps) / BPS;
    totalProtocolFees = makerFee + takerFee;

    if (makerFee > 0) {
      collateral.safeTransferFrom(maker.trader, address(this), makerFee);
    }
    if (takerFee > 0) {
      collateral.safeTransferFrom(taker.trader, address(this), takerFee);
    }

    if (totalProtocolFees > 0) {
      collateral.safeTransfer(feeModule, totalProtocolFees);
    }
  }

  /// @dev Fee deduction for merge matches — each seller's fee is deducted from their proceeds.
  function _paySellerWithFees(
    Order calldata maker,
    Order calldata taker,
    uint256 fillAmount,
    FeeConfig memory feeConfig,
    IERC20 collateral,
    Order calldata outcome0Order,
    Order calldata outcome1Order,
    uint256 outcome0Notional,
    uint256 outcome1Notional
  ) internal returns (uint256 totalProtocolFees) {
    uint256 makerNotional = (fillAmount * maker.price) / ONE;
    uint256 takerNotional = fillAmount - makerNotional;

    uint256 makerFee = (makerNotional * feeConfig.makerFeeBps) / BPS;
    uint256 takerFee = (takerNotional * feeConfig.takerFeeBps) / BPS;
    totalProtocolFees = makerFee + takerFee;

    address makerTrader = maker.trader;
    address takerTrader = taker.trader;

    uint256 makerProceeds = makerTrader == outcome0Order.trader ? outcome0Notional : outcome1Notional;
    uint256 takerProceeds = takerTrader == outcome0Order.trader ? outcome0Notional : outcome1Notional;

    require(makerProceeds >= makerFee, "maker fees exceed proceeds");
    makerProceeds -= makerFee;

    require(takerProceeds >= takerFee, "taker fees exceed proceeds");
    takerProceeds -= takerFee;

    collateral.safeTransfer(outcome0Order.trader, makerTrader == outcome0Order.trader ? makerProceeds : takerProceeds);
    collateral.safeTransfer(outcome1Order.trader, makerTrader == outcome1Order.trader ? makerProceeds : takerProceeds);

    if (totalProtocolFees > 0) {
      collateral.safeTransfer(feeModule, totalProtocolFees);
    }
  }

  function _requireMarketOpen(uint256 marketId) internal view {
    require(manager.getMarketState(marketId) == IMyriadMarketManager.MarketState.open, "market closed");
    require(!manager.isMarketPaused(marketId), "market paused");
    require(manager.getMarketExecutionMode(marketId) == 1, "not clob");
  }
}
