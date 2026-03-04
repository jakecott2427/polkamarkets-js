// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../contracts/AdminRegistry.sol";
import "../contracts/PredictionMarketV3ManagerCLOB.sol";
import "../contracts/ConditionalTokens.sol";
import "../contracts/IMyriadMarketManager.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Collateral", "COL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ConditionalTokensTest is Test {
    uint256 private constant ONE = 1e18;

    AdminRegistry                  internal registry;
    PredictionMarketV3ManagerCLOB  internal manager;
    ConditionalTokens              internal ct;
    MockERC20                      internal collateral;

    address internal admin;
    address internal alice;
    address internal bob;

    uint256 internal marketId;

    function setUp() public {
        admin = address(this);
        alice = address(0xA11CE);
        bob   = address(0xB0B);

        collateral = new MockERC20();
        registry   = new AdminRegistry(admin);

        // Deploy Manager via UUPS proxy
        PredictionMarketV3ManagerCLOB managerImpl = new PredictionMarketV3ManagerCLOB();
        ERC1967Proxy managerProxy = new ERC1967Proxy(
            address(managerImpl),
            abi.encodeCall(
                PredictionMarketV3ManagerCLOB.initialize,
                (registry, IERC20(address(collateral)))
            )
        );
        manager = PredictionMarketV3ManagerCLOB(address(managerProxy));

        ct = new ConditionalTokens(registry, IMyriadMarketManager(address(manager)));

        // Grant roles
        registry.grantRole(registry.MARKET_ADMIN_ROLE(),      admin);
        registry.grantRole(registry.RESOLUTION_ADMIN_ROLE(),  admin);

        // Create one market
        PredictionMarketV3ManagerCLOB.CreateMarketParams memory params =
            PredictionMarketV3ManagerCLOB.CreateMarketParams({
                closesAt:   block.timestamp + 1 days,
                question:   "Will it rain?",
                image:      "ipfs://img",
                feeModule:  address(0),
                oracle:     address(0),
                oracleData: ""
            });
        marketId = manager.createMarket(params);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _approveAndSplit(address user, uint256 amount) internal {
        vm.startPrank(user);
        collateral.approve(address(ct), type(uint256).max);
        ct.splitPosition(marketId, amount);
        vm.stopPrank();
    }

    function _tokenId(uint256 mid, uint256 outcome) internal pure returns (uint256) {
        return (mid << 1) | outcome;
    }

    // =========================================================================
    // getTokenId
    // =========================================================================

    function testGetTokenIdOutcome0() public view {
        uint256 expected = (marketId << 1) | 0;
        assertEq(ct.getTokenId(marketId, 0), expected);
    }

    function testGetTokenIdOutcome1() public view {
        uint256 expected = (marketId << 1) | 1;
        assertEq(ct.getTokenId(marketId, 1), expected);
    }

    function testGetTokenIdDifferentOutcomesDiffer() public view {
        assertTrue(ct.getTokenId(marketId, 0) != ct.getTokenId(marketId, 1));
    }

    function testGetTokenIdDifferentMarketsDiffer() public view {
        assertTrue(ct.getTokenId(1, 0) != ct.getTokenId(2, 0));
    }

    // =========================================================================
    // splitPosition
    // =========================================================================

    function testSplitPositionMintsBothTokens() public {
        uint256 amount = 100 ether;
        collateral.mint(alice, amount);
        _approveAndSplit(alice, amount);

        assertEq(ct.balanceOf(alice, _tokenId(marketId, 0)), amount);
        assertEq(ct.balanceOf(alice, _tokenId(marketId, 1)), amount);
    }

    function testSplitPositionPullsCollateral() public {
        uint256 amount = 50 ether;
        collateral.mint(alice, amount);

        uint256 before = collateral.balanceOf(alice);
        _approveAndSplit(alice, amount);

        assertEq(collateral.balanceOf(alice), before - amount);
        assertEq(collateral.balanceOf(address(ct)), amount);
    }

    function testSplitPositionZeroAmountReverts() public {
        vm.prank(alice);
        vm.expectRevert("amount 0");
        ct.splitPosition(marketId, 0);
    }

    function testSplitPositionClosedMarketReverts() public {
        // Warp past closesAt so market transitions to closed
        vm.warp(block.timestamp + 2 days);

        collateral.mint(alice, 100 ether);
        vm.startPrank(alice);
        collateral.approve(address(ct), type(uint256).max);
        vm.expectRevert("market not open");
        ct.splitPosition(marketId, 100 ether);
        vm.stopPrank();
    }

    function testSplitPositionResolvedMarketReverts() public {
        // Warp past closesAt, then resolve
        vm.warp(block.timestamp + 2 days);
        manager.adminResolveMarket(marketId, 0);

        collateral.mint(alice, 100 ether);
        vm.startPrank(alice);
        collateral.approve(address(ct), type(uint256).max);
        vm.expectRevert("market not open");
        ct.splitPosition(marketId, 100 ether);
        vm.stopPrank();
    }

    function testSplitPositionMultipleUsersIndependent() public {
        uint256 aliceAmt = 80 ether;
        uint256 bobAmt   = 40 ether;

        collateral.mint(alice, aliceAmt);
        collateral.mint(bob,   bobAmt);

        _approveAndSplit(alice, aliceAmt);
        _approveAndSplit(bob,   bobAmt);

        assertEq(ct.balanceOf(alice, _tokenId(marketId, 0)), aliceAmt);
        assertEq(ct.balanceOf(alice, _tokenId(marketId, 1)), aliceAmt);
        assertEq(ct.balanceOf(bob,   _tokenId(marketId, 0)), bobAmt);
        assertEq(ct.balanceOf(bob,   _tokenId(marketId, 1)), bobAmt);
    }

    // =========================================================================
    // mergePositions
    // =========================================================================

    function testMergePositionsBurnsBothTokens() public {
        uint256 amount = 100 ether;
        collateral.mint(alice, amount);
        _approveAndSplit(alice, amount);

        vm.prank(alice);
        ct.mergePositions(marketId, amount);

        assertEq(ct.balanceOf(alice, _tokenId(marketId, 0)), 0);
        assertEq(ct.balanceOf(alice, _tokenId(marketId, 1)), 0);
    }

    function testMergePositionsReturnsCollateral() public {
        uint256 amount = 100 ether;
        collateral.mint(alice, amount);
        _approveAndSplit(alice, amount);

        uint256 before = collateral.balanceOf(alice);
        vm.prank(alice);
        ct.mergePositions(marketId, amount);

        assertEq(collateral.balanceOf(alice), before + amount);
    }

    function testMergePositionsZeroAmountReverts() public {
        vm.prank(alice);
        vm.expectRevert("amount 0");
        ct.mergePositions(marketId, 0);
    }

    function testMergePositionsPartialMerge() public {
        uint256 amount = 100 ether;
        uint256 mergeAmt = 40 ether;

        collateral.mint(alice, amount);
        _approveAndSplit(alice, amount);

        vm.prank(alice);
        ct.mergePositions(marketId, mergeAmt);

        assertEq(ct.balanceOf(alice, _tokenId(marketId, 0)), amount - mergeAmt);
        assertEq(ct.balanceOf(alice, _tokenId(marketId, 1)), amount - mergeAmt);
    }

    function testMergePositionsRoundTrip() public {
        uint256 amount = 100 ether;
        collateral.mint(alice, amount);

        uint256 before = collateral.balanceOf(alice);

        _approveAndSplit(alice, amount);

        vm.prank(alice);
        ct.mergePositions(marketId, amount);

        assertEq(collateral.balanceOf(alice), before);
    }

    // =========================================================================
    // redeemPositions
    // =========================================================================

    function testRedeemPositionsOutcome0Winner() public {
        uint256 amount = 100 ether;
        collateral.mint(alice, amount);
        _approveAndSplit(alice, amount);

        // Resolve with outcome 0 winning
        vm.warp(block.timestamp + 2 days);
        manager.adminResolveMarket(marketId, 0);

        uint256 before = collateral.balanceOf(alice);
        vm.prank(alice);
        ct.redeemPositions(marketId);

        assertEq(collateral.balanceOf(alice), before + amount);
        // Losing token stays (outcome 1)
        assertEq(ct.balanceOf(alice, _tokenId(marketId, 1)), amount);
        // Winning token burned
        assertEq(ct.balanceOf(alice, _tokenId(marketId, 0)), 0);
    }

    function testRedeemPositionsOutcome1Winner() public {
        uint256 amount = 100 ether;
        collateral.mint(alice, amount);
        _approveAndSplit(alice, amount);

        // Resolve with outcome 1 winning
        vm.warp(block.timestamp + 2 days);
        manager.adminResolveMarket(marketId, 1);

        uint256 before = collateral.balanceOf(alice);
        vm.prank(alice);
        ct.redeemPositions(marketId);

        assertEq(collateral.balanceOf(alice), before + amount);
        // Losing token stays (outcome 0)
        assertEq(ct.balanceOf(alice, _tokenId(marketId, 0)), amount);
        // Winning token burned
        assertEq(ct.balanceOf(alice, _tokenId(marketId, 1)), 0);
    }

    function testRedeemPositionsNotResolvedReverts() public {
        vm.prank(alice);
        vm.expectRevert("not resolved");
        ct.redeemPositions(marketId);
    }

    function testRedeemPositionsNoBalanceReverts() public {
        vm.warp(block.timestamp + 2 days);
        manager.adminResolveMarket(marketId, 0);

        vm.prank(alice);
        vm.expectRevert("no balance");
        ct.redeemPositions(marketId);
    }

    function testRedeemPositionsDoubleRedeemReverts() public {
        uint256 amount = 100 ether;
        collateral.mint(alice, amount);
        _approveAndSplit(alice, amount);

        vm.warp(block.timestamp + 2 days);
        manager.adminResolveMarket(marketId, 0);

        vm.prank(alice);
        ct.redeemPositions(marketId);

        vm.prank(alice);
        vm.expectRevert("no balance");
        ct.redeemPositions(marketId);
    }

    // =========================================================================
    // redeemVoided
    // =========================================================================

    function _voidMarketSymmetric() internal {
        vm.warp(block.timestamp + 2 days);
        manager.adminVoidMarket(marketId, ONE / 2, ONE / 2);
    }

    function testRedeemVoidedSymmetric50_50() public {
        uint256 amount = 100 ether;
        collateral.mint(alice, amount);
        _approveAndSplit(alice, amount);

        _voidMarketSymmetric();

        uint256 before = collateral.balanceOf(alice);
        vm.prank(alice);
        ct.redeemVoided(marketId);

        // 50% of outcome0Balance + 50% of outcome1Balance = 100% of amount
        assertEq(collateral.balanceOf(alice), before + amount);
    }

    function testRedeemVoidedAsymmetric() public {
        // 70% to outcome0, 30% to outcome1
        uint256 outcome0Payout = (70 * ONE) / 100;
        uint256 outcome1Payout = (30 * ONE) / 100;

        uint256 amount = 100 ether;
        collateral.mint(alice, amount);
        _approveAndSplit(alice, amount);

        vm.warp(block.timestamp + 2 days);
        manager.adminVoidMarket(marketId, outcome0Payout, outcome1Payout);

        uint256 before = collateral.balanceOf(alice);
        vm.prank(alice);
        ct.redeemVoided(marketId);

        // alice holds both outcome tokens: 70% + 30% = 100%
        assertEq(collateral.balanceOf(alice), before + amount);
    }

    function testRedeemVoidedSingleOutcomeTokenHolder() public {
        // alice splits, then transfers outcome 1 to bob; each redeems their own token
        uint256 amount = 100 ether;
        collateral.mint(alice, amount);
        _approveAndSplit(alice, amount);

        // alice transfers outcome 1 to bob
        vm.prank(alice);
        ct.safeTransferFrom(alice, bob, _tokenId(marketId, 1), amount, "");

        _voidMarketSymmetric();

        // alice redeems outcome0 -> 50%
        uint256 aliceBefore = collateral.balanceOf(alice);
        vm.prank(alice);
        ct.redeemVoided(marketId);
        assertEq(collateral.balanceOf(alice), aliceBefore + amount / 2);

        // bob redeems outcome1 -> 50%
        uint256 bobBefore = collateral.balanceOf(bob);
        vm.prank(bob);
        ct.redeemVoided(marketId);
        assertEq(collateral.balanceOf(bob), bobBefore + amount / 2);
    }

    function testRedeemVoidedNotVoidedReverts() public {
        vm.warp(block.timestamp + 2 days);
        manager.adminResolveMarket(marketId, 0);

        vm.prank(alice);
        vm.expectRevert("not voided");
        ct.redeemVoided(marketId);
    }

    function testRedeemVoidedNoBalanceReverts() public {
        _voidMarketSymmetric();

        vm.prank(alice);
        vm.expectRevert("no balance");
        ct.redeemVoided(marketId);
    }

    function testRedeemVoidedDoubleRedeemReverts() public {
        uint256 amount = 100 ether;
        collateral.mint(alice, amount);
        _approveAndSplit(alice, amount);

        _voidMarketSymmetric();

        vm.prank(alice);
        ct.redeemVoided(marketId);

        vm.prank(alice);
        vm.expectRevert("no balance");
        ct.redeemVoided(marketId);
    }
}
