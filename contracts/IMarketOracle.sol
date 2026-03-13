// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IMarketOracle
/// @notice Universal interface for pluggable market resolution oracles.
///         Each oracle type (Realitio, Chainlink price, etc.) implements this
///         interface so the market manager can delegate resolution generically.
interface IMarketOracle {
  /// @notice Called by the manager during market creation to set up oracle-specific state.
  /// @param marketId The market ID assigned by the manager.
  /// @param data ABI-encoded configuration specific to this oracle type.
  function initialize(uint256 marketId, bytes calldata data) external;

  /// @notice Returns the resolved outcome for a market.
  /// @return outcome 0, 1, or -1 (void).
  /// @return resolved true if the oracle has a final answer.
  function getResult(uint256 marketId) external view returns (int256 outcome, bool resolved);
}
