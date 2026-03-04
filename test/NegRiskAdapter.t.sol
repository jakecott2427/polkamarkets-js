// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../contracts/AdminRegistry.sol";
import "../contracts/PredictionMarketV3ManagerCLOB.sol";
import "../contracts/ConditionalTokens.sol";
import "../contracts/MyriadCTFExchange.sol";
import "../contracts/FeeModule.sol";
import "../contracts/IMyriadMarketManager.sol";
import "../contracts/WrappedCollateral.sol";
import "../contracts/NegRiskAdapter.sol";
import "../contracts/IMarketOracle.sol";

contract MockERC20NR is ERC20 {
  constructor() ERC20("Collateral", "COL") {}
  function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract NegRiskAdapterTest is Test, ERC1155Holder {
  uint256 private constant ONE = 1e18;
  uint256 private constant BPS = 10000;

  AdminRegistry internal registry;
  PredictionMarketV3ManagerCLOB internal manager;
  ConditionalTokens internal conditionalTokens;
  MyriadCTFExchange internal exchange;
  FeeModule internal feeModule;
  MockERC20NR internal collateral;
  WrappedCollateral internal wcol;
  NegRiskAdapter internal adapter;

  address internal admin;
  address internal operator;
  address internal treasury;
  address internal alice;
  address internal bob;
  address internal charlie;

  uint256 internal alicePk = 0xA11CE;
  uint256 internal bobPk = 0xB0B;
  uint256 internal charliePk = 0xC4A;

  function setUp() public {
    admin = address(this);
    operator = address(this);
    treasury = address(0xBEEF);
    alice = vm.addr(alicePk);
    bob = vm.addr(bobPk);
    charlie = vm.addr(charliePk);

    collateral = new MockERC20NR();

    registry = new AdminRegistry(admin);
    PredictionMarketV3ManagerCLOB managerImpl = new PredictionMarketV3ManagerCLOB();
    manager = PredictionMarketV3ManagerCLOB(address(new ERC1967Proxy(
      address(managerImpl),
      abi.encodeCall(PredictionMarketV3ManagerCLOB.initialize, (registry, IERC20(address(collateral))))
    )));
    conditionalTokens = new ConditionalTokens(registry, IMyriadMarketManager(address(manager)));
    FeeModule feeModuleImpl = new FeeModule();
    feeModule = FeeModule(address(new ERC1967Proxy(
      address(feeModuleImpl),
      abi.encodeCall(FeeModule.initialize, (registry, treasury))
    )));
    MyriadCTFExchange exchangeImpl = new MyriadCTFExchange();
    exchange = MyriadCTFExchange(address(new ERC1967Proxy(
      address(exchangeImpl),
      abi.encodeCall(MyriadCTFExchange.initialize, (
        IMyriadMarketManager(address(manager)), conditionalTokens, address(feeModule), registry
      ))
    )));

    feeModule.setExchange(address(exchange));

    registry.grantRole(registry.MARKET_ADMIN_ROLE(), admin);
    registry.grantRole(registry.FEE_ADMIN_ROLE(), admin);
    registry.grantRole(registry.OPERATOR_ROLE(), operator);
    registry.grantRole(registry.RESOLUTION_ADMIN_ROLE(), admin);

    // Deploy WrappedCollateral and NegRiskAdapter
    // Predict adapter address for wcol constructor
    uint64 nonce = vm.getNonce(address(this));
    address predictedAdapter = vm.computeCreateAddress(address(this), nonce + 1);

    wcol = new WrappedCollateral(IERC20(address(collateral)), predictedAdapter);
    adapter = new NegRiskAdapter(
      registry,
      manager,
      conditionalTokens,
      wcol,
      treasury
    );
    require(address(adapter) == predictedAdapter, "adapter address mismatch");

    manager.setNegRiskAdapter(address(adapter));
    exchange.setNegRiskAdapter(address(adapter));
    adapter.setExchange(address(exchange));

    registry.grantRole(registry.MARKET_ADMIN_ROLE(), address(adapter));
    registry.grantRole(registry.RESOLUTION_ADMIN_ROLE(), address(adapter));
  }

  // =========================================================================
  // Event creation
  // =========================================================================

  function testCreateEvent() public {
    (bytes32 eventId, uint256[] memory marketIds) = _createThreeOutcomeEvent();

    assertEq(marketIds.length, 3);

    (uint256 outcomeCount, bool resolved, int256 winningIndex, uint256[] memory ids,) = adapter.getEvent(eventId);
    assertEq(outcomeCount, 3);
    assertFalse(resolved);
    assertEq(winningIndex, -2); // unresolved sentinel
    assertEq(ids.length, 3);

    for (uint256 i = 0; i < 3; i++) {
      assertTrue(manager.isNegRisk(ids[i]));
      assertEq(manager.getEventId(ids[i]), eventId);
      assertEq(address(manager.getMarketCollateral(ids[i])), address(wcol));
    }
  }

  function testCreateEventRequiresAtLeast2Outcomes() public {
    PredictionMarketV3ManagerCLOB.CreateMarketParams[] memory params =
      new PredictionMarketV3ManagerCLOB.CreateMarketParams[](1);
    params[0] = _mkParam("Only");
    vm.expectRevert("need >= 2 outcomes");
    adapter.createEvent("Duplicate event", params);
  }

  // =========================================================================
  // Split / Merge
  // =========================================================================

  function testSplitAndMerge() public {
    (bytes32 eventId, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    collateral.mint(alice, amount);

    vm.startPrank(alice);
    collateral.approve(address(adapter), amount);
    adapter.splitPosition(eventId, 0, amount);
    vm.stopPrank();

    uint256 yesTokenId = conditionalTokens.getTokenId(marketIds[0], 0);
    uint256 noTokenId = conditionalTokens.getTokenId(marketIds[0], 1);

    assertEq(conditionalTokens.balanceOf(alice, yesTokenId), amount);
    assertEq(conditionalTokens.balanceOf(alice, noTokenId), amount);
    assertEq(collateral.balanceOf(alice), 0);

    // Merge back
    vm.startPrank(alice);
    conditionalTokens.setApprovalForAll(address(adapter), true);
    adapter.mergePositions(eventId, 0, amount);
    vm.stopPrank();

    assertEq(conditionalTokens.balanceOf(alice, yesTokenId), 0);
    assertEq(conditionalTokens.balanceOf(alice, noTokenId), 0);
    assertEq(collateral.balanceOf(alice), amount);
  }

  // =========================================================================
  // Convert
  // =========================================================================

  function testConvertPositions() public {
    (bytes32 eventId, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 50 ether;

    // Give alice NO tokens for outcome 0 (split, then she only uses the NO side)
    collateral.mint(alice, amount);
    vm.startPrank(alice);
    collateral.approve(address(adapter), amount);
    adapter.splitPosition(eventId, 0, amount);

    // Alice now has YES(0) + NO(0). She converts NO(0) → YES(1) + YES(2)
    conditionalTokens.setApprovalForAll(address(adapter), true);
    adapter.convertPositions(eventId, 0, amount);
    vm.stopPrank();

    // Alice should have YES(0), YES(1), YES(2) — one of each
    for (uint256 i = 0; i < 3; i++) {
      uint256 yesTokenId = conditionalTokens.getTokenId(marketIds[i], 0);
      assertEq(conditionalTokens.balanceOf(alice, yesTokenId), amount, "missing YES token");
    }

    // Alice should have no NO tokens for outcome 0
    uint256 noTokenId0 = conditionalTokens.getTokenId(marketIds[0], 1);
    assertEq(conditionalTokens.balanceOf(alice, noTokenId0), 0);

    // Adapter should hold NO tokens for all 3 markets
    for (uint256 i = 0; i < 3; i++) {
      uint256 noTokenId = conditionalTokens.getTokenId(marketIds[i], 1);
      assertEq(conditionalTokens.balanceOf(address(adapter), noTokenId), amount);
    }

    // Minted wcol should be tracked
    assertEq(adapter.mintedWcolPerEvent(eventId), 2 * amount);
  }

  // =========================================================================
  // MintAllYesTokens (used by exchange for cross-market matching)
  // =========================================================================

  function testMintAllYesTokens() public {
    (bytes32 eventId, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 30 ether;

    // Mint wcol to the exchange (simulating what happens during cross-market match)
    collateral.mint(address(exchange), amount);
    vm.startPrank(address(exchange));
    collateral.approve(address(wcol), amount);
    wcol.wrap(amount);
    IERC20(address(wcol)).approve(address(adapter), amount);

    adapter.mintAllYesTokens(eventId, amount, address(exchange));
    vm.stopPrank();

    // Exchange (recipient) should have YES for all 3 outcomes
    for (uint256 i = 0; i < 3; i++) {
      uint256 yesTokenId = conditionalTokens.getTokenId(marketIds[i], 0);
      assertEq(conditionalTokens.balanceOf(address(exchange), yesTokenId), amount);
    }

    // Adapter holds NO for all 3 outcomes
    for (uint256 i = 0; i < 3; i++) {
      uint256 noTokenId = conditionalTokens.getTokenId(marketIds[i], 1);
      assertEq(conditionalTokens.balanceOf(address(adapter), noTokenId), amount);
    }

    // Minted = (3-1) * 30 = 60 ether
    assertEq(adapter.mintedWcolPerEvent(eventId), 2 * amount);
  }

  // =========================================================================
  // Resolution: named outcome wins
  // =========================================================================

  function testResolveNamedOutcome() public {
    (bytes32 eventId, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    // Alice splits in outcome 0 and converts → YES(0), YES(1), YES(2)
    collateral.mint(alice, amount);
    vm.startPrank(alice);
    collateral.approve(address(adapter), amount);
    adapter.splitPosition(eventId, 0, amount);
    conditionalTokens.setApprovalForAll(address(adapter), true);
    adapter.convertPositions(eventId, 0, amount);
    vm.stopPrank();

    // Fast-forward past market close
    vm.warp(block.timestamp + 2 days);

    // Resolve: outcome 1 wins
    adapter.resolveEvent(eventId, 1);

    (,bool resolved, int256 winningIndex,,) = adapter.getEvent(eventId);
    assertTrue(resolved);
    assertEq(winningIndex, 1);

    // Market 0 should be resolved with outcome 1 (NO wins)
    assertEq(manager.getMarketResolvedOutcome(marketIds[0]), 1);
    // Market 1 should be resolved with outcome 0 (YES wins)
    assertEq(manager.getMarketResolvedOutcome(marketIds[1]), 0);
    // Market 2 should be resolved with outcome 1 (NO wins)
    assertEq(manager.getMarketResolvedOutcome(marketIds[2]), 1);

    // Alice redeems YES(1) → gets collateral
    uint256 yesTokenId1 = conditionalTokens.getTokenId(marketIds[1], 0);
    uint256 aliceYes1Balance = conditionalTokens.balanceOf(alice, yesTokenId1);
    assertEq(aliceYes1Balance, amount);

    vm.prank(alice);
    conditionalTokens.redeemPositions(marketIds[1]);

    // Alice gets wcol, needs to unwrap
    uint256 aliceWcol = wcol.balanceOf(alice);
    assertEq(aliceWcol, amount);
    vm.prank(alice);
    wcol.unwrap(amount);
    assertEq(collateral.balanceOf(alice), amount);

    // Adapter redeems NO positions and cleans up
    adapter.redeemNOPositions(eventId);
    assertEq(adapter.mintedWcolPerEvent(eventId), 0);
  }

  // =========================================================================
  // Resolution: "Other" wins (all resolve NO)
  // =========================================================================

  function testResolveOtherWins() public {
    (bytes32 eventId, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    // Bob splits in outcome 0, keeps YES(0) and NO(0)
    collateral.mint(bob, amount);
    vm.startPrank(bob);
    collateral.approve(address(adapter), amount);
    adapter.splitPosition(eventId, 0, amount);
    vm.stopPrank();

    vm.warp(block.timestamp + 2 days);

    // Resolve: "Other" wins (-1)
    adapter.resolveEvent(eventId, -1);

    // All markets should resolve with outcome 1 (NO wins)
    for (uint256 i = 0; i < 3; i++) {
      assertEq(manager.getMarketResolvedOutcome(marketIds[i]), 1);
    }

    // Bob's YES(0) is worthless, but NO(0) is redeemable
    uint256 noTokenId0 = conditionalTokens.getTokenId(marketIds[0], 1);
    uint256 bobNo0 = conditionalTokens.balanceOf(bob, noTokenId0);
    assertEq(bobNo0, amount);

    vm.prank(bob);
    conditionalTokens.redeemPositions(marketIds[0]);

    uint256 bobWcol = wcol.balanceOf(bob);
    assertEq(bobWcol, amount);
    vm.prank(bob);
    wcol.unwrap(amount);
    assertEq(collateral.balanceOf(bob), amount);
  }

  // =========================================================================
  // Cross-market matching via exchange
  // =========================================================================

  function testCrossMarketMatch() public {
    (bytes32 eventId, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    // Set fees for all markets
    for (uint256 i = 0; i < 3; i++) {
      _setUniformFees(marketIds[i], 100, 200); // 1% maker, 2% taker
    }

    // Give alice, bob, charlie collateral and wcol
    uint256 fundAmount = 500 ether;
    for (uint256 i = 0; i < 3; i++) {
      address user = i == 0 ? alice : (i == 1 ? bob : charlie);
      collateral.mint(user, fundAmount);
      vm.startPrank(user);
      collateral.approve(address(wcol), fundAmount);
      wcol.wrap(fundAmount);
      IERC20(address(wcol)).approve(address(exchange), type(uint256).max);
      conditionalTokens.setApprovalForAll(address(exchange), true);
      vm.stopPrank();
    }

    // Prices: 0.45 + 0.35 + 0.20 = 1.00
    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    MyriadCTFExchange.Order memory order0 = _buildOrder(alice, marketIds[0], 0, MyriadCTFExchange.Side.Buy, amount, price0, 1);
    MyriadCTFExchange.Order memory order1 = _buildOrder(bob, marketIds[1], 0, MyriadCTFExchange.Side.Buy, amount, price1, 2);
    MyriadCTFExchange.Order memory order2 = _buildOrder(charlie, marketIds[2], 0, MyriadCTFExchange.Side.Buy, amount, price2, 3);

    MyriadCTFExchange.Order[] memory orders = new MyriadCTFExchange.Order[](3);
    orders[0] = order0;
    orders[1] = order1;
    orders[2] = order2;

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(order0, alicePk);
    sigs[1] = _signOrder(order1, bobPk);
    sigs[2] = _signOrder(order2, charliePk);

    exchange.matchCrossMarketOrders(orders, sigs, amount);

    // Full shares minted — fees added on top of each party's notional
    assertEq(conditionalTokens.balanceOf(alice, conditionalTokens.getTokenId(marketIds[0], 0)), amount);
    assertEq(conditionalTokens.balanceOf(bob, conditionalTokens.getTokenId(marketIds[1], 0)), amount);
    assertEq(conditionalTokens.balanceOf(charlie, conditionalTokens.getTokenId(marketIds[2], 0)), amount);

    bytes32 hash0 = exchange.hashOrder(order0);
    assertEq(exchange.filledAmounts(hash0), amount);
  }

  function testCrossMarketMatchPriceSumNot1Reverts() public {
    (bytes32 eventId, uint256[] memory marketIds) = _createThreeOutcomeEvent();

    // Prices don't sum to 1
    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (19 * ONE) / 100; // sum = 0.99

    MyriadCTFExchange.Order[] memory orders = new MyriadCTFExchange.Order[](3);
    orders[0] = _buildOrder(alice, marketIds[0], 0, MyriadCTFExchange.Side.Buy, 10 ether, price0, 1);
    orders[1] = _buildOrder(bob, marketIds[1], 0, MyriadCTFExchange.Side.Buy, 10 ether, price1, 2);
    orders[2] = _buildOrder(charlie, marketIds[2], 0, MyriadCTFExchange.Side.Buy, 10 ether, price2, 3);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(orders[0], alicePk);
    sigs[1] = _signOrder(orders[1], bobPk);
    sigs[2] = _signOrder(orders[2], charliePk);

    vm.expectRevert("price sum < 1");
    exchange.matchCrossMarketOrders(orders, sigs, 10 ether);
  }

  // =========================================================================
  // Cross-market maker/taker fee distinction
  // =========================================================================

  function testCrossMarketMakerTakerFees() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    // Set distinct maker/taker fees: 1% maker, 3% taker
    for (uint256 i = 0; i < 3; i++) {
      _setUniformFees(marketIds[i], 100, 300);
    }

    uint256 fundAmount = 500 ether;
    for (uint256 i = 0; i < 3; i++) {
      address user = i == 0 ? alice : (i == 1 ? bob : charlie);
      collateral.mint(user, fundAmount);
      vm.startPrank(user);
      collateral.approve(address(wcol), fundAmount);
      wcol.wrap(fundAmount);
      IERC20(address(wcol)).approve(address(exchange), type(uint256).max);
      conditionalTokens.setApprovalForAll(address(exchange), true);
      vm.stopPrank();
    }

    // Prices: 0.40 + 0.30 + 0.30 = 1.00
    uint256 price0 = (40 * ONE) / 100;
    uint256 price1 = (30 * ONE) / 100;
    uint256 price2 = (30 * ONE) / 100;

    // Last order (charlie) is the taker, charged takerBps (3%)
    // First two (alice, bob) are makers, charged makerBps (1%)
    MyriadCTFExchange.Order[] memory orders = new MyriadCTFExchange.Order[](3);
    orders[0] = _buildOrder(alice, marketIds[0], 0, MyriadCTFExchange.Side.Buy, amount, price0, 10);
    orders[1] = _buildOrder(bob, marketIds[1], 0, MyriadCTFExchange.Side.Buy, amount, price1, 20);
    orders[2] = _buildOrder(charlie, marketIds[2], 0, MyriadCTFExchange.Side.Buy, amount, price2, 30);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(orders[0], alicePk);
    sigs[1] = _signOrder(orders[1], bobPk);
    sigs[2] = _signOrder(orders[2], charliePk);

    uint256 aliceBefore = wcol.balanceOf(alice);
    uint256 bobBefore = wcol.balanceOf(bob);
    uint256 charlieBefore = wcol.balanceOf(charlie);

    exchange.matchCrossMarketOrders(orders, sigs, amount);

    uint256 aliceSpent = aliceBefore - wcol.balanceOf(alice);
    uint256 bobSpent = bobBefore - wcol.balanceOf(bob);
    uint256 charlieSpent = charlieBefore - wcol.balanceOf(charlie);

    uint256 aliceNotional = (amount * price0) / ONE;
    uint256 aliceFee = (aliceNotional * 100) / BPS;
    assertEq(aliceSpent, aliceNotional + aliceFee, "alice pays notional + fee");

    uint256 bobNotional = (amount * price1) / ONE;
    uint256 bobFee = (bobNotional * 100) / BPS;
    assertEq(bobSpent, bobNotional + bobFee, "bob pays notional + fee");

    uint256 charlieNotional = amount - aliceNotional - bobNotional;
    uint256 charlieFee = (charlieNotional * 300) / BPS;
    assertEq(charlieSpent, charlieNotional + charlieFee, "charlie pays notional + fee");

    uint256 totalFees = aliceFee + bobFee + charlieFee;
    assertEq(wcol.balanceOf(address(feeModule)), totalFees, "feeModule received fees");
  }

  // =========================================================================
  // Access control tests
  // =========================================================================

  function testMintAllYesTokensOnlyExchangeReverts() public {
    (bytes32 eventId, ) = _createThreeOutcomeEvent();
    uint256 amount = 10 ether;
    collateral.mint(alice, amount);
    vm.startPrank(alice);
    collateral.approve(address(wcol), amount);
    wcol.wrap(amount);
    IERC20(address(wcol)).approve(address(adapter), amount);
    vm.expectRevert("only exchange");
    adapter.mintAllYesTokens(eventId, amount, alice);
    vm.stopPrank();
  }

  function testRedeemNOPositionsNotAdminReverts() public {
    (bytes32 eventId, ) = _createThreeOutcomeEvent();
    vm.warp(block.timestamp + 2 days);
    adapter.resolveEvent(eventId, 0);

    vm.prank(alice);
    vm.expectRevert("not admin");
    adapter.redeemNOPositions(eventId);
  }

  function testRedeemNOPositionsDoubleCallReverts() public {
    (bytes32 eventId, ) = _createThreeOutcomeEvent();
    vm.warp(block.timestamp + 2 days);
    adapter.resolveEvent(eventId, 0);

    adapter.redeemNOPositions(eventId);

    vm.expectRevert("already redeemed");
    adapter.redeemNOPositions(eventId);
  }

  // =========================================================================
  // WrappedCollateral tests
  // =========================================================================

  function testWrapUnwrap() public {
    uint256 amount = 100 ether;
    collateral.mint(alice, amount);

    vm.startPrank(alice);
    collateral.approve(address(wcol), amount);
    wcol.wrap(amount);
    assertEq(wcol.balanceOf(alice), amount);
    assertEq(collateral.balanceOf(alice), 0);

    wcol.unwrap(amount);
    assertEq(wcol.balanceOf(alice), 0);
    assertEq(collateral.balanceOf(alice), amount);
    vm.stopPrank();
  }

  function testAdapterMintOnlyAdapter() public {
    vm.expectRevert(WrappedCollateral.OnlyAdapter.selector);
    wcol.adapterMint(alice, 100 ether);
  }

  function testAdapterBurnOnlyAdapter() public {
    vm.expectRevert(WrappedCollateral.OnlyAdapter.selector);
    wcol.adapterBurn(alice, 100 ether);
  }

  // =========================================================================
  // Helpers
  // =========================================================================

  function _createThreeOutcomeEvent() internal returns (bytes32 eventId, uint256[] memory marketIds) {
    PredictionMarketV3ManagerCLOB.CreateMarketParams[] memory params =
      new PredictionMarketV3ManagerCLOB.CreateMarketParams[](3);
    params[0] = _mkParam("Trump");
    params[1] = _mkParam("Harris");
    params[2] = _mkParam("Biden");

    eventId = adapter.createEvent("Who will win?", params);
    marketIds = adapter.getEventMarkets(eventId);
  }

  function _mkParam(string memory question) internal view returns (PredictionMarketV3ManagerCLOB.CreateMarketParams memory) {
    return PredictionMarketV3ManagerCLOB.CreateMarketParams({
      closesAt: block.timestamp + 1 days,
      question: question,
      image: "",
      feeModule: address(feeModule),
      oracle: address(0),
      oracleData: ""
    });
  }

  function _buildOrder(
    address trader,
    uint256 marketId_,
    uint8 outcome,
    MyriadCTFExchange.Side side,
    uint256 amount,
    uint256 price,
    uint256 nonce
  ) internal pure returns (MyriadCTFExchange.Order memory) {
    return MyriadCTFExchange.Order({
      trader: trader,
      marketId: marketId_,
      outcome: outcome,
      side: side,
      amount: amount,
      price: price,
      minFillAmount: 0,
      nonce: nonce,
      expiration: 0
    });
  }

  function _signOrder(MyriadCTFExchange.Order memory order, uint256 pk) internal view returns (bytes memory) {
    bytes32 digest = exchange.hashOrder(order);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
    return abi.encodePacked(r, s, v);
  }

  function _setUniformFees(uint256 mktId, uint64 makerBps, uint64 takerBps) internal {
    FeeModule.FeeTier[] memory tiers = new FeeModule.FeeTier[](1);
    tiers[0] = FeeModule.FeeTier({maxPrice: uint128(ONE), makerFeeBps: makerBps, takerFeeBps: takerBps});
    feeModule.setMarketFees(mktId, tiers);
  }
}
