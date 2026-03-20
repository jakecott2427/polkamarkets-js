// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../IMarketOracle.sol";
import "../IRealityETH_ERC20.sol";
import "../Outcomes.sol";

/// @title RealitioOracle
/// @notice Wraps Reality.eth (Realitio) into the IMarketOracle interface so it can
///         be used as a pluggable oracle for market resolution.
contract RealitioOracle is IMarketOracle {
  uint256 public constant MINIMUM_TIMEOUT = 3600;

  IRealityETH_ERC20 public immutable realitio;
  address public immutable manager;

  mapping(uint256 marketId => bytes32 questionId) public questions;

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
    require(questions[marketId] == bytes32(0), "already init");

    (
      string memory question,
      address arbitrator,
      uint32 timeout,
      uint32 closesAt
    ) = abi.decode(data, (string, address, uint32, uint32));

    require(arbitrator != address(0), "arbitrator 0");
    require(timeout >= MINIMUM_TIMEOUT, "timeout < 1h");
    require(closesAt > block.timestamp, "closesAt in past");

    bytes32 questionId = realitio.askQuestionERC20(
      2, question, arbitrator, timeout, closesAt, marketId, 0
    );

    questions[marketId] = questionId;

    emit QuestionRegistered(marketId, questionId);
  }

  /// @notice Returns the resolved outcome mapped to Outcomes constants.
  ///         Reality.eth bool answers: 1 = true/yes → Outcomes.YES (0),
  ///         0 = false/no → Outcomes.NO (1). INVALID (type(uint256).max) and
  ///         any other non-binary answer → Outcomes.VOIDED (-1).
  ///         Returns (-2, false) when the question is not yet finalized.
  function getResult(uint256 marketId) external view override returns (int256 outcome, bool resolved) {
    bytes32 questionId = questions[marketId];
    require(questionId != bytes32(0), "!init");

    if (!realitio.isFinalized(questionId)) {
      return (-2, false);
    }

    bytes32 rawAnswer = realitio.resultFor(questionId);
    uint256 answer = uint256(rawAnswer);

    if (answer == 1) {
      return (int256(Outcomes.YES), true);
    } else if (answer == 0) {
      return (int256(Outcomes.NO), true);
    } else {
      return (Outcomes.VOIDED, true);
    }
  }
}
