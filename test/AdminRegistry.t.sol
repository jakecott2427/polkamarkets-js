// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";
import "../contracts/AdminRegistry.sol";

contract AdminRegistryTest is Test {
    AdminRegistry internal registry;

    address internal admin;
    address internal alice;
    address internal bob;
    address internal carol;

    uint256 internal alicePk = 0xA11CE;
    uint256 internal bobPk   = 0xB0B;
    uint256 internal carolPk = 0xCA401;

    event AdminProposed(address indexed proposed);
    event AdminAccepted(address indexed newAdmin, address indexed oldAdmin);

    function setUp() public {
        admin = address(this);
        alice = vm.addr(alicePk);
        bob   = vm.addr(bobPk);
        carol = vm.addr(carolPk);

        registry = new AdminRegistry(admin);
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    function testConstructorSetsAdmin() public view {
        assertEq(registry.admin(), admin);
    }

    function testConstructorGrantsDefaultAdminRole() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
    }

    function testConstructorRejectsZeroAddress() public {
        vm.expectRevert("zero address");
        new AdminRegistry(address(0));
    }

    // =========================================================================
    // Initial state
    // =========================================================================

    function testPendingAdminIsZeroOnDeploy() public view {
        assertEq(registry.pendingAdmin(), address(0));
    }

    // =========================================================================
    // Role constant uniqueness
    // =========================================================================

    function testRoleConstantsAreUnique() public view {
        bytes32 marketAdmin     = registry.MARKET_ADMIN_ROLE();
        bytes32 operatorRole    = registry.OPERATOR_ROLE();
        bytes32 feeAdmin        = registry.FEE_ADMIN_ROLE();
        bytes32 resolutionAdmin = registry.RESOLUTION_ADMIN_ROLE();
        bytes32 defaultAdmin    = registry.DEFAULT_ADMIN_ROLE();

        assertTrue(marketAdmin     != operatorRole);
        assertTrue(marketAdmin     != feeAdmin);
        assertTrue(marketAdmin     != resolutionAdmin);
        assertTrue(marketAdmin     != defaultAdmin);
        assertTrue(operatorRole    != feeAdmin);
        assertTrue(operatorRole    != resolutionAdmin);
        assertTrue(operatorRole    != defaultAdmin);
        assertTrue(feeAdmin        != resolutionAdmin);
        assertTrue(feeAdmin        != defaultAdmin);
        assertTrue(resolutionAdmin != defaultAdmin);
    }

    // =========================================================================
    // grantRole / revokeRole
    // =========================================================================

    function testGrantRoleByAdminSucceeds() public {
        registry.grantRole(registry.OPERATOR_ROLE(), alice);
        assertTrue(registry.hasRole(registry.OPERATOR_ROLE(), alice));
    }

    function testGrantRoleByNonAdminReverts() public {
        bytes32 role = registry.OPERATOR_ROLE();
        // OZ v5 AccessControl uses custom error AccessControlUnauthorizedAccount
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                alice,
                registry.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        registry.grantRole(role, bob);
    }

    function testRevokeRoleByAdminSucceeds() public {
        registry.grantRole(registry.OPERATOR_ROLE(), alice);
        registry.revokeRole(registry.OPERATOR_ROLE(), alice);
        assertFalse(registry.hasRole(registry.OPERATOR_ROLE(), alice));
    }

    function testGrantMarketAdminRole() public {
        registry.grantRole(registry.MARKET_ADMIN_ROLE(), alice);
        assertTrue(registry.hasRole(registry.MARKET_ADMIN_ROLE(), alice));
    }

    function testGrantOperatorRole() public {
        registry.grantRole(registry.OPERATOR_ROLE(), alice);
        assertTrue(registry.hasRole(registry.OPERATOR_ROLE(), alice));
    }

    function testGrantFeeAdminRole() public {
        registry.grantRole(registry.FEE_ADMIN_ROLE(), alice);
        assertTrue(registry.hasRole(registry.FEE_ADMIN_ROLE(), alice));
    }

    function testGrantResolutionAdminRole() public {
        registry.grantRole(registry.RESOLUTION_ADMIN_ROLE(), alice);
        assertTrue(registry.hasRole(registry.RESOLUTION_ADMIN_ROLE(), alice));
    }

    // =========================================================================
    // proposeAdmin
    // =========================================================================

    function testProposeAdminEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit AdminProposed(alice);
        registry.proposeAdmin(alice);
    }

    function testProposeAdminSetsPendingAdmin() public {
        registry.proposeAdmin(alice);
        assertEq(registry.pendingAdmin(), alice);
    }

    function testProposeAdminRejectsZeroAddress() public {
        vm.expectRevert("zero address");
        registry.proposeAdmin(address(0));
    }

    function testProposeAdminRejectsNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert("not admin");
        registry.proposeAdmin(bob);
    }

    function testProposeAdminRejectsSelfProposal() public {
        vm.expectRevert("cannot self-propose");
        registry.proposeAdmin(admin);
    }

    function testProposeAdminCanRepropose() public {
        registry.proposeAdmin(alice);
        assertEq(registry.pendingAdmin(), alice);

        // Override with a different candidate
        registry.proposeAdmin(bob);
        assertEq(registry.pendingAdmin(), bob);
    }

    // =========================================================================
    // acceptAdmin
    // =========================================================================

    function testAcceptAdminEmitsEvent() public {
        registry.proposeAdmin(alice);

        vm.expectEmit(true, true, false, false);
        emit AdminAccepted(alice, admin);

        vm.prank(alice);
        registry.acceptAdmin();
    }

    function testAcceptAdminNewAdminGainsDefaultAdminRole() public {
        registry.proposeAdmin(alice);
        vm.prank(alice);
        registry.acceptAdmin();

        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), alice));
    }

    function testAcceptAdminOldAdminLosesDefaultAdminRole() public {
        registry.proposeAdmin(alice);
        vm.prank(alice);
        registry.acceptAdmin();

        assertFalse(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
    }

    function testAcceptAdminUpdatesAdminField() public {
        registry.proposeAdmin(alice);
        vm.prank(alice);
        registry.acceptAdmin();

        assertEq(registry.admin(), alice);
    }

    function testAcceptAdminClearsPendingAdmin() public {
        registry.proposeAdmin(alice);
        vm.prank(alice);
        registry.acceptAdmin();

        assertEq(registry.pendingAdmin(), address(0));
    }

    function testAcceptAdminNonPendingReverts() public {
        registry.proposeAdmin(alice);

        vm.prank(bob);
        vm.expectRevert("not pending admin");
        registry.acceptAdmin();
    }

    function testAcceptAdminWithoutProposalReverts() public {
        vm.prank(alice);
        vm.expectRevert("not pending admin");
        registry.acceptAdmin();
    }

    // =========================================================================
    // Post-transfer role management
    // =========================================================================

    function testAfterTransferOldAdminCannotGrantRoles() public {
        registry.proposeAdmin(alice);
        vm.prank(alice);
        registry.acceptAdmin();

        // address(this) no longer has DEFAULT_ADMIN_ROLE — grantRole should revert
        bytes32 role = registry.OPERATOR_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(this),
                registry.DEFAULT_ADMIN_ROLE()
            )
        );
        registry.grantRole(role, bob);
    }

    function testAfterTransferNewAdminCanGrantRoles() public {
        registry.proposeAdmin(alice);
        vm.prank(alice);
        registry.acceptAdmin();

        bytes32 role = registry.OPERATOR_ROLE();
        vm.prank(alice);
        registry.grantRole(role, bob);
        assertTrue(registry.hasRole(role, bob));
    }

    // =========================================================================
    // Chained transfer (A -> B -> C)
    // =========================================================================

    function testChainedTransfer() public {
        // A (address(this)) -> B (alice)
        registry.proposeAdmin(alice);
        vm.prank(alice);
        registry.acceptAdmin();

        assertEq(registry.admin(), alice);
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), alice));
        assertFalse(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));

        // B (alice) -> C (bob)
        vm.prank(alice);
        registry.proposeAdmin(bob);

        vm.prank(bob);
        registry.acceptAdmin();

        assertEq(registry.admin(), bob);
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), bob));
        assertFalse(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), alice));
        assertFalse(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
    }
}
