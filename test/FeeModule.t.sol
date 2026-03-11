// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../contracts/AdminRegistry.sol";
import "../contracts/FeeModule.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Collateral", "COL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FeeModuleTest is Test {
    uint256 private constant ONE  = 1e18;
    uint256 private constant BPS  = 10000;

    AdminRegistry internal registry;
    FeeModule     internal feeModule;
    MockERC20     internal collateral;

    address internal admin;
    address internal feeAdmin;
    address internal exchangeAddr;
    address internal treasury;
    address internal other;

    event MarketFeesUpdated(uint256 indexed marketId, uint256 tierCount);
    event FeesAccrued(address indexed token, uint256 amount);
    event FeesWithdrawn(address indexed treasury, address indexed token, uint256 amount);
    event ExchangeUpdated(address indexed newExchange);
    event TreasuryUpdated(address indexed newTreasury);

    function setUp() public {
        admin        = address(this);
        feeAdmin     = address(0xFEE1);
        exchangeAddr = address(0xE1);
        treasury     = address(0xBEEF);
        other        = address(0xBAD);

        collateral = new MockERC20();
        registry   = new AdminRegistry(admin);

        FeeModule impl = new FeeModule();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(FeeModule.initialize, (registry, treasury))
        );
        feeModule = FeeModule(address(proxy));

        feeModule.setExchange(exchangeAddr);

        registry.grantRole(registry.FEE_ADMIN_ROLE(), feeAdmin);
    }

    // =========================================================================
    // initialize
    // =========================================================================

    function testInitializeSetsRegistry() public view {
        assertEq(address(feeModule.registry()), address(registry));
    }

    function testInitializeSetsTreasury() public view {
        assertEq(feeModule.treasury(), treasury);
    }

    function testInitializeSetsExchange() public view {
        assertEq(feeModule.exchange(), exchangeAddr);
    }

    function testInitializeZeroRegistryReverts() public {
        FeeModule impl = new FeeModule();
        vm.expectRevert("registry 0");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(FeeModule.initialize, (AdminRegistry(address(0)), treasury))
        );
    }

    function testInitializeZeroTreasuryReverts() public {
        FeeModule impl = new FeeModule();
        vm.expectRevert("treasury 0");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(FeeModule.initialize, (registry, address(0)))
        );
    }

    // =========================================================================
    // setExchange
    // =========================================================================

    function testSetExchangeEmitsEvent() public {
        address newExchange = address(0xE2);
        vm.expectEmit(true, false, false, false);
        emit ExchangeUpdated(newExchange);
        feeModule.setExchange(newExchange);
    }

    function testSetExchangeUpdatesExchange() public {
        address newExchange = address(0xE3);
        feeModule.setExchange(newExchange);
        assertEq(feeModule.exchange(), newExchange);
    }

    function testSetExchangeNonAdminReverts() public {
        vm.prank(other);
        vm.expectRevert("not admin");
        feeModule.setExchange(address(0xE4));
    }

    function testSetExchangeZeroAddressReverts() public {
        vm.expectRevert("exchange 0");
        feeModule.setExchange(address(0));
    }

    // =========================================================================
    // setTreasury
    // =========================================================================

    function testSetTreasuryEmitsEvent() public {
        address newTreasury = address(0x1234);
        vm.expectEmit(true, false, false, false);
        emit TreasuryUpdated(newTreasury);
        feeModule.setTreasury(newTreasury);
    }

    function testSetTreasuryUpdatesTreasury() public {
        address newTreasury = address(0x5678);
        feeModule.setTreasury(newTreasury);
        assertEq(feeModule.treasury(), newTreasury);
    }

    function testSetTreasuryNonAdminReverts() public {
        vm.prank(other);
        vm.expectRevert("not admin");
        feeModule.setTreasury(address(0x9ABC));
    }

    function testSetTreasuryZeroAddressReverts() public {
        vm.expectRevert("treasury 0");
        feeModule.setTreasury(address(0));
    }

    // =========================================================================
    // setMarketFees
    // =========================================================================

    function _singleTier(uint128 maxPrice, uint64 makerBps, uint64 takerBps)
        internal
        pure
        returns (FeeModule.FeeTier[] memory tiers)
    {
        tiers = new FeeModule.FeeTier[](1);
        tiers[0] = FeeModule.FeeTier({
            maxPrice:    maxPrice,
            makerFeeBps: makerBps,
            takerFeeBps: takerBps
        });
    }

    function testSetMarketFeesSingleTierStoredCorrectly() public {
        uint256 marketId = 1;
        vm.prank(feeAdmin);
        feeModule.setMarketFees(marketId, _singleTier(uint128(ONE), 100, 200));

        FeeModule.FeeTier[] memory stored = feeModule.getMarketFees(marketId);
        assertEq(stored.length, 1);
        assertEq(stored[0].maxPrice,    ONE);
        assertEq(stored[0].makerFeeBps, 100);
        assertEq(stored[0].takerFeeBps, 200);
    }

    function testSetMarketFeesMultipleTiers() public {
        uint256 marketId = 2;
        FeeModule.FeeTier[] memory tiers = new FeeModule.FeeTier[](3);
        tiers[0] = FeeModule.FeeTier({maxPrice: uint128(ONE / 3),   makerFeeBps: 50,  takerFeeBps: 100});
        tiers[1] = FeeModule.FeeTier({maxPrice: uint128(ONE * 2/3), makerFeeBps: 100, takerFeeBps: 150});
        tiers[2] = FeeModule.FeeTier({maxPrice: uint128(ONE),       makerFeeBps: 150, takerFeeBps: 200});

        vm.prank(feeAdmin);
        feeModule.setMarketFees(marketId, tiers);

        FeeModule.FeeTier[] memory stored = feeModule.getMarketFees(marketId);
        assertEq(stored.length, 3);
        assertEq(stored[1].makerFeeBps, 100);
    }

    function testSetMarketFeesReplacesExisting() public {
        uint256 marketId = 3;
        vm.startPrank(feeAdmin);
        feeModule.setMarketFees(marketId, _singleTier(uint128(ONE), 100, 200));
        feeModule.setMarketFees(marketId, _singleTier(uint128(ONE), 300, 400));
        vm.stopPrank();

        FeeModule.FeeTier[] memory stored = feeModule.getMarketFees(marketId);
        assertEq(stored.length, 1);
        assertEq(stored[0].makerFeeBps, 300);
    }

    function testSetMarketFeesEmptyArrayClears() public {
        uint256 marketId = 4;
        vm.startPrank(feeAdmin);
        feeModule.setMarketFees(marketId, _singleTier(uint128(ONE), 100, 200));

        FeeModule.FeeTier[] memory empty = new FeeModule.FeeTier[](0);
        feeModule.setMarketFees(marketId, empty);
        vm.stopPrank();

        FeeModule.FeeTier[] memory stored = feeModule.getMarketFees(marketId);
        assertEq(stored.length, 0);
    }

    function testSetMarketFeesNotSortedReverts() public {
        uint256 marketId = 5;
        FeeModule.FeeTier[] memory tiers = new FeeModule.FeeTier[](2);
        tiers[0] = FeeModule.FeeTier({maxPrice: uint128(ONE),     makerFeeBps: 100, takerFeeBps: 200});
        tiers[1] = FeeModule.FeeTier({maxPrice: uint128(ONE / 2), makerFeeBps: 100, takerFeeBps: 200});

        vm.prank(feeAdmin);
        vm.expectRevert("tiers not sorted");
        feeModule.setMarketFees(marketId, tiers);
    }

    function testSetMarketFeesZeroMaxPriceReverts() public {
        uint256 marketId = 6;
        FeeModule.FeeTier[] memory tiers = new FeeModule.FeeTier[](1);
        tiers[0] = FeeModule.FeeTier({maxPrice: 0, makerFeeBps: 100, takerFeeBps: 200});

        vm.prank(feeAdmin);
        vm.expectRevert("invalid max price");
        feeModule.setMarketFees(marketId, tiers);
    }

    function testSetMarketFeesMaxPriceAboveOneReverts() public {
        uint256 marketId = 7;
        FeeModule.FeeTier[] memory tiers = new FeeModule.FeeTier[](1);
        tiers[0] = FeeModule.FeeTier({maxPrice: uint128(ONE + 1), makerFeeBps: 100, takerFeeBps: 200});

        vm.prank(feeAdmin);
        vm.expectRevert("invalid max price");
        feeModule.setMarketFees(marketId, tiers);
    }

    function testSetMarketFeesMakerFeeTooHighReverts() public {
        uint256 marketId = 8;
        FeeModule.FeeTier[] memory tiers = new FeeModule.FeeTier[](1);
        tiers[0] = FeeModule.FeeTier({maxPrice: uint128(ONE), makerFeeBps: 1001, takerFeeBps: 200});

        vm.prank(feeAdmin);
        vm.expectRevert("fee too high");
        feeModule.setMarketFees(marketId, tiers);
    }

    function testSetMarketFeesTakerFeeTooHighReverts() public {
        uint256 marketId = 9;
        FeeModule.FeeTier[] memory tiers = new FeeModule.FeeTier[](1);
        tiers[0] = FeeModule.FeeTier({maxPrice: uint128(ONE), makerFeeBps: 100, takerFeeBps: 1001});

        vm.prank(feeAdmin);
        vm.expectRevert("fee too high");
        feeModule.setMarketFees(marketId, tiers);
    }

    function testSetMarketFeesAtMaxSucceeds() public {
        uint256 marketId = 99;
        FeeModule.FeeTier[] memory tiers = new FeeModule.FeeTier[](1);
        tiers[0] = FeeModule.FeeTier({maxPrice: uint128(ONE), makerFeeBps: 1000, takerFeeBps: 1000});

        vm.prank(feeAdmin);
        feeModule.setMarketFees(marketId, tiers);

        FeeModule.FeeTier[] memory stored = feeModule.getMarketFees(marketId);
        assertEq(stored[0].makerFeeBps, 1000);
        assertEq(stored[0].takerFeeBps, 1000);
    }

    function testSetMarketFeesNonFeeAdminReverts() public {
        uint256 marketId = 10;
        vm.prank(other);
        vm.expectRevert("not fee admin");
        feeModule.setMarketFees(marketId, _singleTier(uint128(ONE), 100, 200));
    }

    function testSetMarketFees101TiersReverts() public {
        uint256 marketId = 11;
        FeeModule.FeeTier[] memory tiers = new FeeModule.FeeTier[](101);
        for (uint256 i = 0; i < 101; i++) {
            tiers[i] = FeeModule.FeeTier({
                maxPrice:    uint128((ONE * (i + 1)) / 101),
                makerFeeBps: 100,
                takerFeeBps: 200
            });
        }

        vm.prank(feeAdmin);
        vm.expectRevert("too many tiers");
        feeModule.setMarketFees(marketId, tiers);
    }

    function testSetMarketFeesEmitsEvent() public {
        uint256 marketId = 12;
        vm.expectEmit(true, false, false, true);
        emit MarketFeesUpdated(marketId, 1);

        vm.prank(feeAdmin);
        feeModule.setMarketFees(marketId, _singleTier(uint128(ONE), 100, 200));
    }

    // =========================================================================
    // getFeesAtPrice
    // =========================================================================

    function testGetFeesAtPriceSingleTier() public {
        uint256 marketId = 20;
        vm.prank(feeAdmin);
        feeModule.setMarketFees(marketId, _singleTier(uint128(ONE), 100, 200));

        (uint16 makerBps, uint16 takerBps) = feeModule.getFeesAtPrice(marketId, ONE / 2);
        assertEq(makerBps, 100);
        assertEq(takerBps, 200);
    }

    function testGetFeesAtPriceTwoTierBoundary() public {
        uint256 marketId = 21;
        FeeModule.FeeTier[] memory tiers = new FeeModule.FeeTier[](2);
        tiers[0] = FeeModule.FeeTier({maxPrice: uint128(ONE / 2), makerFeeBps: 50,  takerFeeBps: 100});
        tiers[1] = FeeModule.FeeTier({maxPrice: uint128(ONE),     makerFeeBps: 150, takerFeeBps: 250});

        vm.prank(feeAdmin);
        feeModule.setMarketFees(marketId, tiers);

        // price below tier[0].maxPrice => tier[0]
        (uint16 m0, uint16 t0) = feeModule.getFeesAtPrice(marketId, ONE / 2 - 1);
        assertEq(m0, 50);
        assertEq(t0, 100);

        // price == tier[0].maxPrice => matches tier[0] (inclusive boundary)
        (uint16 m1, uint16 t1) = feeModule.getFeesAtPrice(marketId, ONE / 2);
        assertEq(m1, 50);
        assertEq(t1, 100);

        // price above tier[0].maxPrice => falls through to tier[1]
        (uint16 m2, uint16 t2) = feeModule.getFeesAtPrice(marketId, ONE / 2 + 1);
        assertEq(m2, 150);
        assertEq(t2, 250);
    }

    function testGetFeesAtPriceAtOneMatchesHighestTier() public {
        uint256 marketId = 24;
        vm.prank(feeAdmin);
        feeModule.setMarketFees(marketId, _singleTier(uint128(ONE), 100, 200));

        (uint16 makerBps, uint16 takerBps) = feeModule.getFeesAtPrice(marketId, ONE);
        assertEq(makerBps, 100);
        assertEq(takerBps, 200);
    }

    function testGetFeesAtPriceNoTiersReturnsZero() public view {
        uint256 marketId = 22;
        // No tiers set
        (uint16 makerBps, uint16 takerBps) = feeModule.getFeesAtPrice(marketId, ONE / 2);
        assertEq(makerBps, 0);
        assertEq(takerBps, 0);
    }

    function testGetFeesAtPriceAboveAllTiersReturnsZero() public {
        uint256 marketId = 23;
        vm.prank(feeAdmin);
        feeModule.setMarketFees(marketId, _singleTier(uint128(ONE / 2), 100, 200));

        // price = ONE is above maxPrice (ONE/2), so no tier matches
        (uint16 makerBps, uint16 takerBps) = feeModule.getFeesAtPrice(marketId, ONE);
        assertEq(makerBps, 0);
        assertEq(takerBps, 0);
    }

    // =========================================================================
    // accrueFees
    // =========================================================================

    function testAccrueFeesOnlyExchangeCanCall() public {
        vm.prank(other);
        vm.expectRevert("only exchange");
        feeModule.accrueFees(address(collateral), 100);
    }

    function testAccrueFeesUpdatesAccruedFees() public {
        uint256 amount = 500;
        collateral.mint(address(feeModule), amount);

        vm.prank(exchangeAddr);
        vm.expectEmit(true, false, false, true);
        emit FeesAccrued(address(collateral), amount);
        feeModule.accrueFees(address(collateral), amount);

        assertEq(feeModule.accruedFees(address(collateral)), amount);
    }

    function testAccrueFeesInsufficientBalanceReverts() public {
        // Do NOT transfer tokens to feeModule first
        vm.prank(exchangeAddr);
        vm.expectRevert("balance < accrued");
        feeModule.accrueFees(address(collateral), 1000);
    }

    function testAccrueFeesAccumulatesOverMultipleCalls() public {
        collateral.mint(address(feeModule), 1000);

        vm.prank(exchangeAddr);
        feeModule.accrueFees(address(collateral), 400);

        vm.prank(exchangeAddr);
        feeModule.accrueFees(address(collateral), 300);

        assertEq(feeModule.accruedFees(address(collateral)), 700);
    }

    function testAccrueFeesEmitsEvent() public {
        uint256 amount = 250;
        collateral.mint(address(feeModule), amount);

        vm.expectEmit(true, false, false, true);
        emit FeesAccrued(address(collateral), amount);

        vm.prank(exchangeAddr);
        feeModule.accrueFees(address(collateral), amount);
    }

    // =========================================================================
    // withdrawFees
    // =========================================================================

    function _accrueForWithdraw(uint256 amount) internal {
        collateral.mint(address(feeModule), amount);
        vm.prank(exchangeAddr);
        feeModule.accrueFees(address(collateral), amount);
    }

    function testWithdrawFeesTransfersToTreasury() public {
        uint256 amount = 1000;
        _accrueForWithdraw(amount);

        vm.prank(feeAdmin);
        feeModule.withdrawFees(address(collateral), amount);

        assertEq(collateral.balanceOf(treasury), amount);
    }

    function testWithdrawFeesReducesAccruedFees() public {
        _accrueForWithdraw(1000);

        vm.prank(feeAdmin);
        feeModule.withdrawFees(address(collateral), 600);

        assertEq(feeModule.accruedFees(address(collateral)), 400);
    }

    function testWithdrawFeesEmitsEvent() public {
        _accrueForWithdraw(500);

        vm.expectEmit(true, true, false, true);
        emit FeesWithdrawn(treasury, address(collateral), 500);

        vm.prank(feeAdmin);
        feeModule.withdrawFees(address(collateral), 500);
    }

    function testWithdrawFeesPartialWithdrawal() public {
        _accrueForWithdraw(1000);

        vm.prank(feeAdmin);
        feeModule.withdrawFees(address(collateral), 300);
        assertEq(collateral.balanceOf(treasury), 300);
        assertEq(feeModule.accruedFees(address(collateral)), 700);

        vm.prank(feeAdmin);
        feeModule.withdrawFees(address(collateral), 700);
        assertEq(collateral.balanceOf(treasury), 1000);
        assertEq(feeModule.accruedFees(address(collateral)), 0);
    }

    function testWithdrawFeesZeroAmountReverts() public {
        _accrueForWithdraw(100);

        vm.prank(feeAdmin);
        vm.expectRevert("amount 0");
        feeModule.withdrawFees(address(collateral), 0);
    }

    function testWithdrawFeesExceedAccruedReverts() public {
        _accrueForWithdraw(100);

        vm.prank(feeAdmin);
        vm.expectRevert("insufficient fees");
        feeModule.withdrawFees(address(collateral), 101);
    }

    function testWithdrawFeesNonFeeAdminReverts() public {
        _accrueForWithdraw(100);

        vm.prank(other);
        vm.expectRevert("not fee admin");
        feeModule.withdrawFees(address(collateral), 50);
    }
}
