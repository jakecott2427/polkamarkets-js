// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title AdminRegistry
/// @notice Centralized role registry for protocol governance and operations.
///         Supports a two-step admin transfer to reduce the risk of an accidental
///         or malicious one-step hand-off of DEFAULT_ADMIN_ROLE.
contract AdminRegistry is AccessControl {
  bytes32 public constant MARKET_ADMIN_ROLE = keccak256("MARKET_ADMIN_ROLE");
  bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
  bytes32 public constant FEE_ADMIN_ROLE = keccak256("FEE_ADMIN_ROLE");
  bytes32 public constant RESOLUTION_ADMIN_ROLE = keccak256("RESOLUTION_ADMIN_ROLE");

  /// @notice Current holder of DEFAULT_ADMIN_ROLE (tracked separately for revocation).
  address public admin;

  /// @notice Proposed new admin that must call acceptAdmin() to take the role.
  address public pendingAdmin;

  event AdminProposed(address indexed proposed);
  event AdminAccepted(address indexed newAdmin, address indexed oldAdmin);

  constructor(address _admin) {
    require(_admin != address(0), "zero address");
    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    admin = _admin;
  }

  /// @notice Initiate an admin transfer. The current admin proposes a successor;
  ///         the successor must call acceptAdmin() to complete the transfer.
  function proposeAdmin(address newAdmin) external {
    require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "not admin");
    require(newAdmin != address(0), "zero address");
    require(newAdmin != admin, "cannot self-propose");
    pendingAdmin = newAdmin;
    emit AdminProposed(newAdmin);
  }

  /// @notice Complete the admin transfer. Only callable by the pending admin.
  ///         Revokes DEFAULT_ADMIN_ROLE from the previous admin atomically.
  function acceptAdmin() external {
    require(msg.sender == pendingAdmin, "not pending admin");
    address oldAdmin = admin;
    _grantRole(DEFAULT_ADMIN_ROLE, pendingAdmin);
    _revokeRole(DEFAULT_ADMIN_ROLE, oldAdmin);
    _revokeRole(MARKET_ADMIN_ROLE, oldAdmin);
    _revokeRole(OPERATOR_ROLE, oldAdmin);
    _revokeRole(FEE_ADMIN_ROLE, oldAdmin);
    _revokeRole(RESOLUTION_ADMIN_ROLE, oldAdmin);
    admin = pendingAdmin;
    pendingAdmin = address(0);
    emit AdminAccepted(admin, oldAdmin);
  }

  // Block inherited AccessControl functions for DEFAULT_ADMIN_ROLE so that
  // all admin transfers are forced through the two-step proposeAdmin/acceptAdmin path.

  function grantRole(bytes32 role, address account) public override {
    require(role != DEFAULT_ADMIN_ROLE, "use proposeAdmin/acceptAdmin");
    super.grantRole(role, account);
  }

  function revokeRole(bytes32 role, address account) public override {
    require(role != DEFAULT_ADMIN_ROLE, "use proposeAdmin/acceptAdmin");
    super.revokeRole(role, account);
  }

  function renounceRole(bytes32 role, address callerConfirmation) public override {
    require(role != DEFAULT_ADMIN_ROLE, "use proposeAdmin/acceptAdmin");
    super.renounceRole(role, callerConfirmation);
  }
}
