// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../contracts/AdminRegistry.sol";
import "../contracts/PredictionMarketV3ManagerCLOB.sol";
import "../contracts/ConditionalTokens.sol";
import "../contracts/MyriadCTFExchange.sol";
import "../contracts/FeeModule.sol";

contract MockERC20 is ERC20 {
  constructor() ERC20("Collateral", "COL") {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}

contract MockRealitio {
  uint256 public counter;
  mapping(bytes32 => bytes32) public results;

  function askQuestionERC20(
    uint256,
    string calldata,
    address,
    uint32,
    uint32,
    uint256,
    uint256
  ) external returns (bytes32) {
    counter++;
    return bytes32(counter);
  }

  function resultFor(bytes32 questionId) external view returns (bytes32) {
    return results[questionId];
  }

  function setResult(bytes32 questionId, bytes32 answer) external {
    results[questionId] = answer;
  }
}

contract PredictionMarketCLOBTest is Test {
  uint256 private constant ONE = 1e18;
  uint256 private constant BPS = 10000;

  AdminRegistry internal registry;
  PredictionMarketV3ManagerCLOB internal manager;
  ConditionalTokens internal conditionalTokens;
  MyriadCTFExchange internal exchange;
  FeeModule internal feeModule;
  MockERC20 internal collateral;
  MockRealitio internal realitio;

  address internal admin;
  address internal operator;
  address internal maker;
  address internal taker;

  uint256 internal makerPk = 0xA11CE;
  uint256 internal takerPk = 0xB0B;

  uint256 internal marketId;

  function setUp() public {
    admin = address(this);
    operator = address(this);
    maker = vm.addr(makerPk);
    taker = vm.addr(takerPk);

    collateral = new MockERC20();
    realitio = new MockRealitio();

    registry = new AdminRegistry(admin);
    manager = new PredictionMarketV3ManagerCLOB(
      registry,
      IRealityETH_ERC20(address(realitio)),
      IERC20(address(collateral))
    );
    conditionalTokens = new ConditionalTokens(registry, IMyriadMarketManager(address(manager)));

    uint256 deployerNonce = vm.getNonce(address(this));
    address predictedExchange = vm.computeCreateAddress(address(this), deployerNonce + 1);

    feeModule = new FeeModule(registry, MyriadCTFExchange(predictedExchange));
    exchange = new MyriadCTFExchange(IMyriadMarketManager(address(manager)), conditionalTokens, address(feeModule));

    // set exchange in conditional tokens
    conditionalTokens.setExchange(address(exchange));

    // grant roles
    registry.grantRole(registry.MARKET_ADMIN_ROLE(), admin);
    registry.grantRole(registry.FEE_ADMIN_ROLE(), admin);
    registry.grantRole(registry.OPERATOR_ROLE(), operator);
    registry.grantRole(registry.RESOLUTION_ADMIN_ROLE(), admin);

    // create market (marketIndex starts at 1)
    PredictionMarketV3ManagerCLOB.CreateMarketParams memory params = PredictionMarketV3ManagerCLOB.CreateMarketParams({
      closesAt: block.timestamp + 1 days,
      question: "Will it rain?",
      image: "ipfs://img",
      arbitrator: address(0x9999),
      realitioTimeout: 1 hours,
      executionMode: PredictionMarketV3ManagerCLOB.ExecutionMode.CLOB,
      feeModule: address(feeModule)
    });
    marketId = manager.createMarket(params);

    // set market fees (uniform 1% maker, 2% taker across all price points)
    feeModule.setMarketFees(marketId, _uniformFeeArray(100), _uniformFeeArray(200));
  }

  // =========================================================================
  // Full-fill tests (fillAmount == order.amount, backward compatible)
  // =========================================================================

  function testMintMatchBuys() public {
    uint256 amount = 100 ether;
    uint256 priceYes = (60 * ONE) / 100;
    uint256 priceNo = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceYes,
      nonce: 1
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId_: marketId,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceNo,
      nonce: 2
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    uint256 makerBefore = collateral.balanceOf(maker);
    uint256 takerBefore = collateral.balanceOf(taker);

    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);

    uint256 yesId = conditionalTokens.getTokenId(marketId, 0);
    uint256 noId = conditionalTokens.getTokenId(marketId, 1);

    assertEq(conditionalTokens.balanceOf(maker, yesId), amount);
    assertEq(conditionalTokens.balanceOf(taker, noId), amount);

    uint256 makerNotional = (amount * priceYes) / ONE;
    uint256 takerNotional = amount - makerNotional; // derived (dust-free)
    uint256 makerFee = (makerNotional * 100) / BPS;
    uint256 takerFee = (takerNotional * 200) / BPS;
    uint256 totalProtocolFees = makerFee + takerFee;

    // Flat fees: each participant pays their own fee (no rebates)
    uint256 expectedMaker = makerBefore - makerNotional - makerFee;
    uint256 expectedTaker = takerBefore - takerNotional - takerFee;

    assertEq(collateral.balanceOf(maker), expectedMaker);
    assertEq(collateral.balanceOf(taker), expectedTaker);

    // Fees are held as a total in FeeModule — no split, just accrued
    assertEq(feeModule.accruedFees(address(collateral)), totalProtocolFees);
    assertEq(collateral.balanceOf(address(feeModule)), totalProtocolFees);
  }

  function testDirectMatchBuySell() public {
    uint256 amount = 50 ether;
    uint256 priceSell = (55 * ONE) / 100;
    uint256 priceBuy = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, amount);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Sell,
      amount: amount,
      price: priceSell,
      nonce: 3
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceBuy,
      nonce: 4
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    uint256 makerBefore = collateral.balanceOf(maker);
    uint256 takerBefore = collateral.balanceOf(taker);

    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);

    uint256 yesId = conditionalTokens.getTokenId(marketId, 0);

    assertEq(conditionalTokens.balanceOf(taker, yesId), amount);

    uint256 notional = (amount * priceSell) / ONE;
    uint256 makerFee = (notional * 100) / BPS;
    uint256 takerFee = (notional * 200) / BPS;

    // Maker (seller) receives notional minus their own fee
    assertEq(collateral.balanceOf(maker), makerBefore + notional - makerFee);
    // Taker (buyer) pays notional plus their own fee
    assertEq(collateral.balanceOf(taker), takerBefore - notional - takerFee);
  }

  function testMergeMatchSells() public {
    uint256 amount = 25 ether;
    uint256 priceYes = (52 * ONE) / 100;
    uint256 priceNo = ONE - priceYes;

    address sellerYes = maker;
    address sellerNo = taker;

    collateral.mint(sellerYes, 1000 ether);
    collateral.mint(sellerNo, 1000 ether);

    vm.startPrank(sellerYes);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, amount);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();

    vm.startPrank(sellerNo);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, amount);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: sellerYes,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Sell,
      amount: amount,
      price: priceYes,
      nonce: 5
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: sellerNo,
      marketId_: marketId,
      outcome: 1,
      side: MyriadCTFExchange.Side.Sell,
      amount: amount,
      price: priceNo,
      nonce: 6
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    uint256 yesBefore = collateral.balanceOf(sellerYes);
    uint256 noBefore = collateral.balanceOf(sellerNo);

    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);

    uint256 yesNotional = (amount * priceYes) / ONE;
    uint256 noNotional = amount - yesNotional; // derived (dust-free)
    uint256 makerFee = (yesNotional * 100) / BPS;
    uint256 takerFee = (noNotional * 200) / BPS;

    // Merge match: each seller's fee deducted from their own USDC proceeds
    assertEq(collateral.balanceOf(sellerYes), yesBefore + yesNotional - makerFee);
    assertEq(collateral.balanceOf(sellerNo), noBefore + noNotional - takerFee);
  }

  // =========================================================================
  // Partial fill tests
  // =========================================================================

  function testPartialFillMint() public {
    uint256 makerAmount = 100 ether;
    uint256 takerAmount = 40 ether;
    uint256 priceYes = (60 * ONE) / 100;
    uint256 priceNo = (40 * ONE) / 100;
    uint256 fillAmount = 40 ether; // fill the smaller order fully

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: makerAmount,
      price: priceYes,
      nonce: 10
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId_: marketId,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: takerAmount,
      price: priceNo,
      nonce: 11
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    uint256 makerBefore = collateral.balanceOf(maker);
    uint256 takerBefore = collateral.balanceOf(taker);

    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, fillAmount);

    uint256 yesId = conditionalTokens.getTokenId(marketId, 0);
    uint256 noId = conditionalTokens.getTokenId(marketId, 1);

    // Each side receives fillAmount shares of their outcome
    assertEq(conditionalTokens.balanceOf(maker, yesId), fillAmount);
    assertEq(conditionalTokens.balanceOf(taker, noId), fillAmount);

    // Check filledAmounts on-chain
    bytes32 makerHash = exchange.hashOrder(makerOrder);
    bytes32 takerHash = exchange.hashOrder(takerOrder);
    assertEq(exchange.filledAmounts(makerHash), fillAmount);
    assertEq(exchange.filledAmounts(takerHash), fillAmount);

    // Maker is NOT invalidated — can still be filled more
    assertFalse(exchange.orderInvalidated(makerHash));
    // Taker is fully filled but also not invalidated (just can't fill more due to filledAmounts check)
    assertFalse(exchange.orderInvalidated(takerHash));

    // Collateral checks: each side paid fillAmount * price + fee
    uint256 makerNotional = (fillAmount * priceYes) / ONE;
    uint256 takerNotional = fillAmount - makerNotional;
    uint256 makerFee = (makerNotional * 100) / BPS;
    uint256 takerFee = (takerNotional * 200) / BPS;

    assertEq(collateral.balanceOf(maker), makerBefore - makerNotional - makerFee);
    assertEq(collateral.balanceOf(taker), takerBefore - takerNotional - takerFee);
  }

  function testPartialFillThenSecondFill() public {
    uint256 makerAmount = 100 ether;
    uint256 priceYes = (60 * ONE) / 100;
    uint256 priceNo = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    // Maker places a large YES buy order for 100 shares
    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: makerAmount,
      price: priceYes,
      nonce: 20
    });

    // First taker: 40 shares
    MyriadCTFExchange.Order memory taker1Order = _buildOrder({
      trader: taker,
      marketId_: marketId,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: 40 ether,
      price: priceNo,
      nonce: 21
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory taker1Sig = _signOrder(taker1Order, takerPk);

    // First fill: 40 shares
    feeModule.matchOrdersWithFees(makerOrder, makerSig, taker1Order, taker1Sig, 40 ether);

    bytes32 makerHash = exchange.hashOrder(makerOrder);
    assertEq(exchange.filledAmounts(makerHash), 40 ether);

    // Second taker: another 60 shares to fill the rest
    MyriadCTFExchange.Order memory taker2Order = _buildOrder({
      trader: taker,
      marketId_: marketId,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: 60 ether,
      price: priceNo,
      nonce: 22
    });
    bytes memory taker2Sig = _signOrder(taker2Order, takerPk);

    // Second fill: 60 shares (fills the rest of maker's 100)
    feeModule.matchOrdersWithFees(makerOrder, makerSig, taker2Order, taker2Sig, 60 ether);

    assertEq(exchange.filledAmounts(makerHash), 100 ether);

    // Maker should have 100 YES shares total
    uint256 yesId = conditionalTokens.getTokenId(marketId, 0);
    assertEq(conditionalTokens.balanceOf(maker, yesId), 100 ether);
  }

  function testOverfillReverts() public {
    uint256 amount = 50 ether;
    uint256 priceYes = (60 * ONE) / 100;
    uint256 priceNo = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceYes,
      nonce: 30
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId_: marketId,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceNo,
      nonce: 31
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    // fillAmount > order amount should revert
    vm.expectRevert("maker overfill");
    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount + 1);
  }

  function testPartialFillDirect() public {
    uint256 makerAmount = 100 ether;
    uint256 takerAmount = 30 ether;
    uint256 priceSell = (55 * ONE) / 100;
    uint256 priceBuy = (60 * ONE) / 100;
    uint256 fillAmount = 30 ether;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, makerAmount);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Sell,
      amount: makerAmount,
      price: priceSell,
      nonce: 40
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: takerAmount,
      price: priceBuy,
      nonce: 41
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    uint256 makerBefore = collateral.balanceOf(maker);
    uint256 takerBefore = collateral.balanceOf(taker);

    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, fillAmount);

    uint256 yesId = conditionalTokens.getTokenId(marketId, 0);
    assertEq(conditionalTokens.balanceOf(taker, yesId), fillAmount);

    // Execution price = maker's price (seller's ask)
    uint256 notional = (fillAmount * priceSell) / ONE;
    uint256 makerFee = (notional * 100) / BPS;
    uint256 takerFee = (notional * 200) / BPS;

    // Seller receives notional - fee
    assertEq(collateral.balanceOf(maker), makerBefore + notional - makerFee);
    // Buyer pays notional + fee
    assertEq(collateral.balanceOf(taker), takerBefore - notional - takerFee);

    // Maker still has 70 remaining
    bytes32 makerHash = exchange.hashOrder(makerOrder);
    assertEq(exchange.filledAmounts(makerHash), fillAmount);
    assertFalse(exchange.orderInvalidated(makerHash));
  }

  // =========================================================================
  // Cancel tests
  // =========================================================================

  function testCancelThenFillReverts() public {
    uint256 amount = 10 ether;
    uint256 priceYes = (60 * ONE) / 100;
    uint256 priceNo = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceYes,
      nonce: 100
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId_: marketId,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceNo,
      nonce: 101
    });

    // Maker cancels their order
    MyriadCTFExchange.Order[] memory toCancel = new MyriadCTFExchange.Order[](1);
    toCancel[0] = makerOrder;
    vm.prank(maker);
    exchange.cancelOrders(toCancel);

    bytes32 makerHash = exchange.hashOrder(makerOrder);
    assertTrue(exchange.orderInvalidated(makerHash));

    // Attempting to match should revert with "invalidated"
    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    vm.expectRevert("invalidated");
    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);
  }

  function testPartialFillThenCancelThenFillReverts() public {
    uint256 amount = 100 ether;
    uint256 priceYes = (60 * ONE) / 100;
    uint256 priceNo = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceYes,
      nonce: 110
    });
    MyriadCTFExchange.Order memory taker1Order = _buildOrder({
      trader: taker,
      marketId_: marketId,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: 40 ether,
      price: priceNo,
      nonce: 111
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory taker1Sig = _signOrder(taker1Order, takerPk);

    // First fill: 40 shares
    feeModule.matchOrdersWithFees(makerOrder, makerSig, taker1Order, taker1Sig, 40 ether);

    bytes32 makerHash = exchange.hashOrder(makerOrder);
    assertEq(exchange.filledAmounts(makerHash), 40 ether);

    // Maker cancels remaining
    MyriadCTFExchange.Order[] memory toCancel = new MyriadCTFExchange.Order[](1);
    toCancel[0] = makerOrder;
    vm.prank(maker);
    exchange.cancelOrders(toCancel);

    assertTrue(exchange.orderInvalidated(makerHash));

    // Attempting a second fill should revert
    MyriadCTFExchange.Order memory taker2Order = _buildOrder({
      trader: taker,
      marketId_: marketId,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: 60 ether,
      price: priceNo,
      nonce: 112
    });
    bytes memory taker2Sig = _signOrder(taker2Order, takerPk);

    vm.expectRevert("invalidated");
    feeModule.matchOrdersWithFees(makerOrder, makerSig, taker2Order, taker2Sig, 60 ether);
  }

  function testCancelAlreadyCancelledReverts() public {
    MyriadCTFExchange.Order memory order = _buildOrder({
      trader: maker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: 10 ether,
      price: (50 * ONE) / 100,
      nonce: 120
    });

    MyriadCTFExchange.Order[] memory toCancel = new MyriadCTFExchange.Order[](1);
    toCancel[0] = order;

    // First cancel succeeds
    vm.prank(maker);
    exchange.cancelOrders(toCancel);

    // Second cancel reverts
    vm.expectRevert("already cancelled");
    vm.prank(maker);
    exchange.cancelOrders(toCancel);
  }

  function testCancelSomeoneElsesOrderReverts() public {
    MyriadCTFExchange.Order memory order = _buildOrder({
      trader: maker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: 10 ether,
      price: (50 * ONE) / 100,
      nonce: 130
    });

    MyriadCTFExchange.Order[] memory toCancel = new MyriadCTFExchange.Order[](1);
    toCancel[0] = order;

    vm.expectRevert("not trader");
    vm.prank(taker);
    exchange.cancelOrders(toCancel);
  }

  // =========================================================================
  // Edge case tests
  // =========================================================================

  function testSelfTradeReverts() public {
    // Same trader on both sides of a direct match
    uint256 amount = 10 ether;
    uint256 price = (50 * ONE) / 100;

    collateral.mint(maker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, amount);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();

    MyriadCTFExchange.Order memory buyOrder = _buildOrder({
      trader: maker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: price,
      nonce: 140
    });
    MyriadCTFExchange.Order memory sellOrder = _buildOrder({
      trader: maker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Sell,
      amount: amount,
      price: price,
      nonce: 141
    });

    bytes memory buySig = _signOrder(buyOrder, makerPk);
    bytes memory sellSig = _signOrder(sellOrder, makerPk);

    // This actually works on-chain — same trader buys their own shares back.
    // It's economically wasteful (paying fees for nothing) but not invalid.
    // If we want to block it, we'd need an explicit check.
    feeModule.matchOrdersWithFees(buyOrder, buySig, sellOrder, sellSig, amount);

    // Maker still has the same shares (bought back what they sold)
    uint256 yesId = conditionalTokens.getTokenId(marketId, 0);
    assertEq(conditionalTokens.balanceOf(maker, yesId), amount);
  }

  function testExpiredOrderReverts() public {
    uint256 amount = 10 ether;
    uint256 priceYes = (60 * ONE) / 100;
    uint256 priceNo = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    // Maker order expires in 1 hour
    MyriadCTFExchange.Order memory makerOrder = MyriadCTFExchange.Order({
      trader: maker,
      marketId: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceYes,
      nonce: 150,
      expiration: block.timestamp + 1 hours
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId_: marketId,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceNo,
      nonce: 151
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    // Warp past the expiration
    vm.warp(block.timestamp + 2 hours);

    vm.expectRevert("expired");
    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);
  }

  function testMarketIndexStartsAt1() public view {
    // Market 0 should not exist as a real market
    // The first market created in setUp() should be marketId == 1
    assertEq(marketId, 1);
    assertEq(manager.marketIndex(), 2); // next available ID
  }

  function testFillAmountOneWei() public {
    // Minimum fill: 1 wei
    uint256 makerAmount = 100 ether;
    uint256 takerAmount = 1; // 1 wei
    uint256 priceYes = (60 * ONE) / 100;
    uint256 priceNo = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: makerAmount,
      price: priceYes,
      nonce: 160
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId_: marketId,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: takerAmount,
      price: priceNo,
      nonce: 161
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    // Fill 1 wei of shares — notionals will round to 0, which means 0 collateral transferred
    // yesNotional = (1 * 0.6e18) / 1e18 = 0; noNotional = 1 - 0 = 1
    // This should still work (taker pays 1 wei of collateral)
    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, 1);

    assertEq(exchange.filledAmounts(exchange.hashOrder(makerOrder)), 1);
    assertEq(exchange.filledAmounts(exchange.hashOrder(takerOrder)), 1);
  }

  function testZeroFeeMarket() public {
    // Create a second market with zero fees
    PredictionMarketV3ManagerCLOB.CreateMarketParams memory params = PredictionMarketV3ManagerCLOB.CreateMarketParams({
      closesAt: block.timestamp + 1 days,
      question: "Zero fee market?",
      image: "ipfs://img2",
      arbitrator: address(0x9999),
      realitioTimeout: 1 hours,
      executionMode: PredictionMarketV3ManagerCLOB.ExecutionMode.CLOB,
      feeModule: address(feeModule)
    });
    uint256 zeroFeeMarketId = manager.createMarket(params);
    feeModule.setMarketFees(zeroFeeMarketId, _uniformFeeArray(0), _uniformFeeArray(0)); // 0% across all price points

    uint256 amount = 50 ether;
    uint256 priceYes = (70 * ONE) / 100;
    uint256 priceNo = (30 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId_: zeroFeeMarketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceYes,
      nonce: 170
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId_: zeroFeeMarketId,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceNo,
      nonce: 171
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    uint256 makerBefore = collateral.balanceOf(maker);
    uint256 takerBefore = collateral.balanceOf(taker);

    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);

    uint256 makerNotional = (amount * priceYes) / ONE;
    uint256 takerNotional = amount - makerNotional;

    // No fees — exact notional deducted
    assertEq(collateral.balanceOf(maker), makerBefore - makerNotional);
    assertEq(collateral.balanceOf(taker), takerBefore - takerNotional);

    // No fees accrued
    assertEq(feeModule.accruedFees(address(collateral)), 0);
    assertEq(collateral.balanceOf(address(feeModule)), 0);
  }

  function testOverlappingPricesDirectMatch() public {
    // Buyer bids 0.70, seller asks 0.50 — execution at maker's price
    uint256 amount = 20 ether;
    uint256 sellerAsk = (50 * ONE) / 100;
    uint256 buyerBid = (70 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, amount);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    // Maker is the seller at 0.50
    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Sell,
      amount: amount,
      price: sellerAsk,
      nonce: 180
    });
    // Taker is the buyer at 0.70
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: buyerBid,
      nonce: 181
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    uint256 makerBefore = collateral.balanceOf(maker);
    uint256 takerBefore = collateral.balanceOf(taker);

    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);

    // Execution at maker's price (0.50), taker gets the benefit
    uint256 executionPrice = sellerAsk;
    uint256 notional = (amount * executionPrice) / ONE;
    uint256 makerFee = (notional * 100) / BPS;
    uint256 takerFee = (notional * 200) / BPS;

    // Seller gets notional - makerFee
    assertEq(collateral.balanceOf(maker), makerBefore + notional - makerFee);
    // Buyer pays notional + takerFee (at 0.50 not 0.70 — saves 0.20 per share)
    assertEq(collateral.balanceOf(taker), takerBefore - notional - takerFee);
  }

  function testClosedMarketReverts() public {
    uint256 amount = 10 ether;
    uint256 priceYes = (60 * ONE) / 100;
    uint256 priceNo = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceYes,
      nonce: 190
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId_: marketId,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceNo,
      nonce: 191
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    // Warp past market close time
    vm.warp(block.timestamp + 2 days);

    vm.expectRevert("market closed");
    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);
  }

  function testResolvedMarketReverts() public {
    uint256 amount = 10 ether;
    uint256 priceYes = (60 * ONE) / 100;
    uint256 priceNo = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    // Resolve the market
    manager.adminResolveMarket(marketId, 0);

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceYes,
      nonce: 200
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId_: marketId,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceNo,
      nonce: 201
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    vm.expectRevert("market closed");
    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);
  }

  function testAdminResolveInvalidOutcomeReverts() public {
    vm.expectRevert("invalid outcome");
    manager.adminResolveMarket(marketId, 2);

    vm.expectRevert("invalid outcome");
    manager.adminResolveMarket(marketId, -2);
  }

  function testAdminResolveVoid() public {
    int256 result = manager.adminResolveMarket(marketId, -1);
    assertEq(result, -1);

    // Market is resolved
    assertEq(uint8(manager.getMarketState(marketId)), uint8(IMyriadMarketManager.MarketState.resolved));

    // Outcome is -1 (voided)
    assertEq(manager.getMarketOutcome(marketId), -1);
  }

  function testFillZeroReverts() public {
    uint256 priceYes = (60 * ONE) / 100;
    uint256 priceNo = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: 10 ether,
      price: priceYes,
      nonce: 210
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId_: marketId,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: 10 ether,
      price: priceNo,
      nonce: 211
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    vm.expectRevert("fill 0");
    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, 0);
  }

  function testDustFreeNotionals() public {
    // Use an odd price that would cause dust: 33%
    uint256 amount = 100 ether;
    uint256 priceYes = (33 * ONE) / 100; // 0.33e18
    uint256 priceNo = ONE - priceYes; // 0.67e18

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceYes,
      nonce: 220
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId_: marketId,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceNo,
      nonce: 221
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    uint256 ctBefore = collateral.balanceOf(address(conditionalTokens));

    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);

    // CT should receive exactly fillAmount of collateral (no dust left in exchange)
    uint256 ctAfter = collateral.balanceOf(address(conditionalTokens));
    assertEq(ctAfter - ctBefore, amount, "CT collateral should match fillAmount exactly");
  }

  function testPausedMarketReverts() public {
    uint256 amount = 10 ether;
    uint256 priceYes = (60 * ONE) / 100;
    uint256 priceNo = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    // Pause the market
    manager.pauseMarket(marketId, true);

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceYes,
      nonce: 230
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId_: marketId,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceNo,
      nonce: 231
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    vm.expectRevert("market paused");
    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);

    // Unpause and verify it works
    manager.pauseMarket(marketId, false);
    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);

    assertEq(exchange.filledAmounts(exchange.hashOrder(makerOrder)), amount);
  }

  // =========================================================================
  // Fee withdrawal tests
  // =========================================================================

  function testWithdrawFees() public {
    // Do a mint match to generate fees
    uint256 amount = 100 ether;
    uint256 priceYes = (60 * ONE) / 100;
    uint256 priceNo = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId_: marketId,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceYes,
      nonce: 300
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId_: marketId,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceNo,
      nonce: 301
    });

    feeModule.matchOrdersWithFees(
      makerOrder, _signOrder(makerOrder, makerPk),
      takerOrder, _signOrder(takerOrder, takerPk),
      amount
    );

    // Compute expected total fees
    uint256 makerNotional = (amount * priceYes) / ONE;
    uint256 takerNotional = amount - makerNotional;
    uint256 makerFee = (makerNotional * 100) / BPS;
    uint256 takerFee = (takerNotional * 200) / BPS;
    uint256 totalFees = makerFee + takerFee;

    assertEq(feeModule.accruedFees(address(collateral)), totalFees);
    assertEq(collateral.balanceOf(address(feeModule)), totalFees);

    // Fee admin withdraws a specific amount to a treasury wallet
    address treasury = address(0x1111);
    feeModule.withdrawFees(address(collateral), treasury, totalFees);

    assertEq(collateral.balanceOf(treasury), totalFees);
    assertEq(feeModule.accruedFees(address(collateral)), 0);
    assertEq(collateral.balanceOf(address(feeModule)), 0);
  }

  function testWithdrawNoFeesReverts() public {
    address treasury = address(0x1111);
    vm.expectRevert("insufficient fees");
    feeModule.withdrawFees(address(collateral), treasury, 1);
  }

  function testWithdrawToZeroAddressReverts() public {
    // Generate some fees first
    uint256 amount = 10 ether;
    uint256 priceYes = (60 * ONE) / 100;
    uint256 priceNo = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, priceYes, 310);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, priceNo, 311);
    feeModule.matchOrdersWithFees(makerOrder, _signOrder(makerOrder, makerPk), takerOrder, _signOrder(takerOrder, takerPk), amount);

    uint256 accrued = feeModule.accruedFees(address(collateral));
    vm.expectRevert(bytes("to 0"));
    feeModule.withdrawFees(address(collateral), address(0), accrued);
  }

  function testWithdrawNotFeeAdminReverts() public {
    // Generate some fees first
    uint256 amount = 10 ether;
    uint256 priceYes = (60 * ONE) / 100;
    uint256 priceNo = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, priceYes, 320);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, priceNo, 321);
    feeModule.matchOrdersWithFees(makerOrder, _signOrder(makerOrder, makerPk), takerOrder, _signOrder(takerOrder, takerPk), amount);

    // Random address tries to withdraw — should fail
    uint256 accrued = feeModule.accruedFees(address(collateral));
    vm.prank(maker);
    vm.expectRevert("not fee admin");
    feeModule.withdrawFees(address(collateral), maker, accrued);
  }

  function testFeesAccumulateAcrossMultipleMatches() public {
    uint256 amount = 50 ether;
    uint256 priceYes = (60 * ONE) / 100;
    uint256 priceNo = (40 * ONE) / 100;

    collateral.mint(maker, 2000 ether);
    collateral.mint(taker, 2000 ether);

    vm.startPrank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    // Match 1
    MyriadCTFExchange.Order memory m1 = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, priceYes, 400);
    MyriadCTFExchange.Order memory t1 = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, priceNo, 401);
    feeModule.matchOrdersWithFees(m1, _signOrder(m1, makerPk), t1, _signOrder(t1, takerPk), amount);

    uint256 feesAfterFirst = collateral.balanceOf(address(feeModule));
    assertGt(feesAfterFirst, 0);

    // Match 2
    MyriadCTFExchange.Order memory m2 = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, priceYes, 402);
    MyriadCTFExchange.Order memory t2 = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, priceNo, 403);
    feeModule.matchOrdersWithFees(m2, _signOrder(m2, makerPk), t2, _signOrder(t2, takerPk), amount);

    uint256 feesAfterSecond = collateral.balanceOf(address(feeModule));
    // Fees should have doubled (same amounts)
    assertEq(feesAfterSecond, feesAfterFirst * 2);

    // Fee admin withdraws all accumulated fees at once
    uint256 totalAccrued = feeModule.accruedFees(address(collateral));
    assertEq(totalAccrued, feesAfterSecond);

    address treasury = address(0x1111);
    feeModule.withdrawFees(address(collateral), treasury, totalAccrued);
    assertEq(collateral.balanceOf(treasury), totalAccrued);
    assertEq(collateral.balanceOf(address(feeModule)), 0);
  }

  // =========================================================================
  // Helpers
  // =========================================================================

  function _buildOrder(
    address trader,
    uint256 marketId_,
    uint8 outcome,
    MyriadCTFExchange.Side side,
    uint256 amount,
    uint256 price,
    uint256 nonce
  ) internal pure returns (MyriadCTFExchange.Order memory) {
    return
      MyriadCTFExchange.Order({
        trader: trader,
        marketId: marketId_,
        outcome: outcome,
        side: side,
        amount: amount,
        price: price,
        nonce: nonce,
        expiration: 0
      });
  }

  function _signOrder(MyriadCTFExchange.Order memory order, uint256 pk) internal view returns (bytes memory) {
    bytes32 digest = exchange.hashOrder(order);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
    return abi.encodePacked(r, s, v);
  }

  /// @dev Build a uint16[100] array where every entry has the same value.
  function _uniformFeeArray(uint16 value) internal pure returns (uint16[100] memory arr) {
    for (uint256 i = 0; i < 100; i++) {
      arr[i] = value;
    }
  }
}
