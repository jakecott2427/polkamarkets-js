// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../IMarketOracle.sol";
import "../IRealityETH_ERC20.sol";

/// @title RealitioOracle
/// @notice Wraps Reality.eth (Realitio) into the IMarketOracle interface so it can
///         be used as a pluggable oracle for market resolution.
contract RealitioOracle is IMarketOracle {
  uint256 public constant MINIMUM_TIMEOUT = 3600;

  IRealityETH_ERC20 public immutable realitio;
  address public immutable manager;

  struct QuestionConfig {
    bytes32 questionId;
    bool initialized;
  }

  mapping(uint256 => QuestionConfig) public questions;

  event QuestionRegistered(uint256 indexed marketId, bytes32 questionId);

  constructor(IRealityETH_ERC20 _realitio, address _manager) {
    require(address(_realitio) != address(0), "realitio 0");
    require(_manager != address(0), "manager 0");
    realitio = _realitio;
    manager = _manager;
  }

  /// @notice Registers a Reality.eth question for the given market.
  /// @param data ABI-encoded (string question, address arbitrator, uint32 timeout, uint32 closesAt)
  function initialize(uint256 marketId, bytes calldata data) external override {
    require(msg.sender == manager, "!manager");
    require(!questions[marketId].initialized, "already init");

    (
      string memory question,
      address arbitrator,
      uint32 timeout,
      uint32 closesAt
    ) = abi.decode(data, (string, address, uint32, uint32));

    require(arbitrator != address(0), "arbitrator 0");
    require(timeout >= MINIMUM_TIMEOUT, "timeout < 1h");

    bytes32 questionId = realitio.askQuestionERC20(
      2, question, arbitrator, timeout, closesAt, 0, 0
    );

    questions[marketId] = QuestionConfig({
      questionId: questionId,
      initialized: true
    });

    emit QuestionRegistered(marketId, questionId);
  }

  function getResult(uint256 marketId) external view override returns (int256 outcome, bool resolved) {
    QuestionConfig storage q = questions[marketId];
    require(q.initialized, "!init");

    if (!realitio.isFinalized(q.questionId)) {
      return (0, false);
    }

    outcome = int256(uint256(realitio.resultFor(q.questionId)));
    return (outcome, true);
  }
}
