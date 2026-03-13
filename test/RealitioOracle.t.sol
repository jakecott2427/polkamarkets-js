// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../contracts/oracles/RealitioOracle.sol";
import "../contracts/IRealityETH_ERC20.sol";
import "../contracts/IMarketOracle.sol";
import "../contracts/Outcomes.sol";

// Import the real Reality.eth contract. Its IERC20 differs from OZ, so we
// use a low-level call for setToken to avoid type conflicts.
import {RealityETH_ERC20_v3_0} from "../lib/reality-eth-monorepo/packages/contracts/development/contracts/RealityETH_ERC20-3.0.sol";

contract SimpleERC20 is ERC20 {
  constructor() ERC20("Bond Token", "BOND") {
    _mint(msg.sender, 1_000_000 ether);
  }
}

contract RealitioOracleTest is Test {
  RealitioOracle internal oracle;
  RealityETH_ERC20_v3_0 internal realitio;
  SimpleERC20 internal bondToken;

  address internal managerAddr;
  address internal arbitrator;
  address internal answerer;
  address internal other;

  uint32 internal constant TIMEOUT = 7200; // 2 hours

  function setUp() public {
    managerAddr = address(this);
    arbitrator = address(0xA4B);
    answerer = address(0xBEEF);
    other = address(0xBAD);

    bondToken = new SimpleERC20();

    realitio = new RealityETH_ERC20_v3_0();
    // setToken uses Reality.eth's own IERC20 -- call via low-level to avoid type mismatch
    (bool ok, ) = address(realitio).call(abi.encodeWithSignature("setToken(address)", address(bondToken)));
    require(ok, "setToken failed");

    // Create templates 0, 1, 2 (RealitioOracle uses template 2 for bool questions)
    realitio.createTemplate('{"title": "%s", "type": "uint"}');
    realitio.createTemplate('{"title": "%s", "type": "single-select"}');
    realitio.createTemplate('{"title": "%s", "type": "bool"}');

    oracle = new RealitioOracle(IRealityETH_ERC20(address(realitio)), managerAddr);

    // Fund answerer with bond tokens and approve realitio
    bondToken.transfer(answerer, 10_000 ether);
    vm.prank(answerer);
    bondToken.approve(address(realitio), type(uint256).max);
  }

  // =========================================================================
  // Constructor
  // =========================================================================

  function testConstructorSetsImmutables() public view {
    assertEq(address(oracle.realitio()), address(realitio));
    assertEq(oracle.manager(), managerAddr);
  }

  function testConstructorZeroRealitioReverts() public {
    vm.expectRevert("realitio 0");
    new RealitioOracle(IRealityETH_ERC20(address(0)), managerAddr);
  }

  function testConstructorZeroManagerReverts() public {
    vm.expectRevert("manager 0");
    new RealitioOracle(IRealityETH_ERC20(address(realitio)), address(0));
  }

  // =========================================================================
  // initialize
  // =========================================================================

  function testInitializeRegistersQuestion() public {
    uint256 marketId = 1;
    bytes memory data = abi.encode("Will it rain?", arbitrator, TIMEOUT, uint32(block.timestamp + 1 days));

    oracle.initialize(marketId, data);

    bytes32 questionId = oracle.questions(marketId);
    assertTrue(questionId != bytes32(0));
  }

  function testInitializeEmitsEvent() public {
    uint256 marketId = 2;
    bytes memory data = abi.encode("Will it snow?", arbitrator, TIMEOUT, uint32(block.timestamp + 1 days));

    vm.expectEmit(true, false, false, false);
    emit RealitioOracle.QuestionRegistered(marketId, bytes32(0));

    oracle.initialize(marketId, data);
  }

  function testInitializeNotManagerReverts() public {
    uint256 marketId = 3;
    bytes memory data = abi.encode("Q?", arbitrator, TIMEOUT, uint32(block.timestamp + 1 days));

    vm.prank(other);
    vm.expectRevert("!manager");
    oracle.initialize(marketId, data);
  }

  function testInitializeDoubleInitReverts() public {
    uint256 marketId = 4;
    bytes memory data = abi.encode("Q?", arbitrator, TIMEOUT, uint32(block.timestamp + 1 days));

    oracle.initialize(marketId, data);

    vm.expectRevert("already init");
    oracle.initialize(marketId, data);
  }

  function testInitializeZeroArbitratorReverts() public {
    uint256 marketId = 5;
    bytes memory data = abi.encode("Q?", address(0), TIMEOUT, uint32(block.timestamp + 1 days));

    vm.expectRevert("arbitrator 0");
    oracle.initialize(marketId, data);
  }

  function testInitializeTimeoutTooLowReverts() public {
    uint256 marketId = 6;
    bytes memory data = abi.encode("Q?", arbitrator, uint32(3599), uint32(block.timestamp + 1 days));

    vm.expectRevert("timeout < 1h");
    oracle.initialize(marketId, data);
  }

  function testInitializeMinimumTimeoutAllowed() public {
    uint256 marketId = 7;
    bytes memory data = abi.encode("Q?", arbitrator, uint32(3600), uint32(block.timestamp + 1 days));

    oracle.initialize(marketId, data);

    bytes32 questionId = oracle.questions(marketId);
    assertTrue(questionId != bytes32(0));
  }

  // =========================================================================
  // getResult
  // =========================================================================

  function testGetResultNotInitializedReverts() public {
    vm.expectRevert("!init");
    oracle.getResult(999);
  }

  function testGetResultNotFinalizedReturnsUnresolved() public {
    uint256 marketId = 10;
    uint32 openingTs = uint32(block.timestamp + 100);
    bytes memory data = abi.encode("Q?", arbitrator, TIMEOUT, openingTs);
    oracle.initialize(marketId, data);

    (int256 outcome, bool resolved) = oracle.getResult(marketId);
    assertEq(outcome, 0);
    assertFalse(resolved);
  }

  function _initAndOpen(uint256 marketId) internal returns (bytes32 questionId) {
    uint32 openingTs = uint32(block.timestamp + 100);
    bytes memory data = abi.encode("Q?", arbitrator, TIMEOUT, openingTs);
    oracle.initialize(marketId, data);
    questionId = oracle.questions(marketId);
    vm.warp(openingTs);
  }

  function testGetResultFinalizedYes() public {
    uint256 marketId = 11;
    bytes32 questionId = _initAndOpen(marketId);

    vm.prank(answerer);
    realitio.submitAnswerERC20(questionId, bytes32(uint256(1)), 0, 1 ether);

    vm.warp(block.timestamp + TIMEOUT + 1);

    (int256 outcome, bool resolved) = oracle.getResult(marketId);
    assertEq(outcome, int256(Outcomes.YES));
    assertTrue(resolved);
  }

  function testGetResultFinalizedNo() public {
    uint256 marketId = 12;
    bytes32 questionId = _initAndOpen(marketId);

    vm.prank(answerer);
    realitio.submitAnswerERC20(questionId, bytes32(uint256(0)), 0, 1 ether);

    vm.warp(block.timestamp + TIMEOUT + 1);

    (int256 outcome, bool resolved) = oracle.getResult(marketId);
    assertEq(outcome, int256(Outcomes.NO));
    assertTrue(resolved);
  }

  function testGetResultNotFinalizedBeforeTimeout() public {
    uint256 marketId = 13;
    bytes32 questionId = _initAndOpen(marketId);

    vm.prank(answerer);
    realitio.submitAnswerERC20(questionId, bytes32(uint256(1)), 0, 1 ether);

    vm.warp(block.timestamp + TIMEOUT - 1);

    (int256 outcome, bool resolved) = oracle.getResult(marketId);
    assertEq(outcome, 0);
    assertFalse(resolved);
  }

  function testGetResultAnswerOverridden() public {
    uint256 marketId = 14;
    bytes32 questionId = _initAndOpen(marketId);

    vm.prank(answerer);
    realitio.submitAnswerERC20(questionId, bytes32(uint256(1)), 0, 1 ether);

    vm.prank(answerer);
    realitio.submitAnswerERC20(questionId, bytes32(uint256(0)), 0, 2 ether);

    vm.warp(block.timestamp + TIMEOUT + 1);

    (int256 outcome, bool resolved) = oracle.getResult(marketId);
    assertEq(outcome, int256(Outcomes.NO), "overridden to NO");
    assertTrue(resolved);
  }

  function testGetResultInvalidAnswerReturnsVoided() public {
    uint256 marketId = 15;
    bytes32 questionId = _initAndOpen(marketId);

    vm.prank(answerer);
    realitio.submitAnswerERC20(questionId, bytes32(type(uint256).max), 0, 1 ether);

    vm.warp(block.timestamp + TIMEOUT + 1);

    (int256 outcome, bool resolved) = oracle.getResult(marketId);
    assertEq(outcome, Outcomes.VOIDED);
    assertTrue(resolved);
  }

  function testGetResultNonBinaryAnswerReturnsVoided() public {
    uint256 marketId = 16;
    bytes32 questionId = _initAndOpen(marketId);

    vm.prank(answerer);
    realitio.submitAnswerERC20(questionId, bytes32(uint256(42)), 0, 1 ether);

    vm.warp(block.timestamp + TIMEOUT + 1);

    (int256 outcome, bool resolved) = oracle.getResult(marketId);
    assertEq(outcome, Outcomes.VOIDED);
    assertTrue(resolved);
  }

  function testInitializeClosesAtInPastReverts() public {
    uint256 marketId = 17;
    bytes memory data = abi.encode("Q?", arbitrator, TIMEOUT, uint32(block.timestamp - 1));

    vm.expectRevert("closesAt in past");
    oracle.initialize(marketId, data);
  }

  // =========================================================================
  // Integration: multiple markets
  // =========================================================================

  function testMultipleMarketsIndependent() public {
    uint32 openingTs = uint32(block.timestamp + 100);
    bytes memory data1 = abi.encode("Market1?", arbitrator, TIMEOUT, openingTs);
    bytes memory data2 = abi.encode("Market2?", arbitrator, TIMEOUT, openingTs);

    oracle.initialize(1, data1);
    oracle.initialize(2, data2);

    bytes32 qid1 = oracle.questions(1);
    bytes32 qid2 = oracle.questions(2);
    assertTrue(qid1 != qid2, "different questions");

    vm.warp(openingTs);

    // Only finalize market 1 -- Realitio 1 (yes) → Outcomes.YES (0)
    vm.prank(answerer);
    realitio.submitAnswerERC20(qid1, bytes32(uint256(1)), 0, 1 ether);
    vm.warp(block.timestamp + TIMEOUT + 1);

    (int256 outcome1, bool resolved1) = oracle.getResult(1);
    assertTrue(resolved1);
    assertEq(outcome1, int256(Outcomes.YES));

    (, bool resolved2) = oracle.getResult(2);
    assertFalse(resolved2);
  }

  function testMinimumTimeoutConstant() public view {
    assertEq(oracle.MINIMUM_TIMEOUT(), 3600);
  }
}
