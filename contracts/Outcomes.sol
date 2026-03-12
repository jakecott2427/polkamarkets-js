// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Outcomes
/// @notice Shared constants for binary market outcome indices.
library Outcomes {
  uint256 internal constant YES  = 0;
  uint256 internal constant NO   = 1;
  int256  internal constant VOIDED = -1;
}
