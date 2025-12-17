// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {MockEntropy} from "@pythnetwork/MockEntropy.sol";

import {Flippy} from "../src/Flippy.sol";
import {Grimmy} from "../src/Grimmy.sol";
import {Stimmy} from "../src/Stimmy.sol";

contract FlippyTest is Test {
    address internal constant PLAYER = address(0xCAFE);
    address internal constant MINER = address(0xB0B);
    uint256 internal constant INITIAL_GRIMMY_RESERVE = 690_000_000 ether;
    uint32 internal constant INITIAL_CALLBACK_GAS_LIMIT = 200_000;
    uint256 internal constant HOUSE_ETH = 200_000 ether;
    uint256 internal constant DIVIDEND_THRESHOLD = HOUSE_ETH * 2;
    bytes32 internal constant USER_DATA_HEADS = keccak256("HEADS");
    bytes32 internal constant USER_DATA_TAILS = keccak256("TAILS");
    bytes32 internal constant BET_SETTLED_SIG =
        keccak256("BetSettled(uint256,address,bytes32,uint256,uint256,uint256)");
    bytes32 internal constant EPOCH_ADVANCED_SIG = keccak256("EpochAdvanced(uint256)");

    struct BetSettlement {
        uint256 betKey;
        address player;
        bytes32 userData;
        uint256 payout;
        uint256 grimmyBonus;
        uint256 flips;
    }

    struct BetPlacement {
        uint256 betKey;
        uint256 houseFee;
        uint128 entropyFee;
    }

    uint256 internal constant PAYOUT_MULTIPLIER = 2;

    Grimmy internal grimmy;
    Stimmy internal stimmy;
    MockEntropy internal mockEntropy;
    Flippy internal flippy;
    address internal provider;

    uint256 internal lastPlayerEthAfterBet;
    uint256 internal lastPlayerGrimmyBefore;

    function setUp() public {
        grimmy = new Grimmy();
        address stimmyTemplate = address(new Stimmy(address(grimmy)));
        stimmy = Stimmy(
            payable(new ERC1967Proxy(
                    address(stimmyTemplate), abi.encodeWithSelector(Stimmy.initialize.selector, address(this))
                ))
        );

        provider = address(0xBEEF);
        mockEntropy = new MockEntropy(provider);

        address flippyTemplate =
            address(new Flippy(address(mockEntropy), address(grimmy), address(stimmy), INITIAL_GRIMMY_RESERVE));
        address predictedFlippy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        SafeTransferLib.safeTransfer(address(grimmy), predictedFlippy, INITIAL_GRIMMY_RESERVE);

        flippy = Flippy(
            payable(new ERC1967Proxy(
                    flippyTemplate,
                    abi.encodeWithSelector(
                        Flippy.initialize.selector,
                        address(this),
                        provider,
                        INITIAL_CALLBACK_GAS_LIMIT,
                        DIVIDEND_THRESHOLD,
                        60,
                        100 ether,
                        10000 ether
                    )
                ))
        );

        vm.deal(address(flippy), HOUSE_ETH);
        SafeTransferLib.safeTransfer(address(grimmy), PLAYER, 10_000 ether);
        vm.deal(PLAYER, 50_000 ether); // Enough for multiple bets

        vm.prank(PLAYER);
        grimmy.approve(address(stimmy), type(uint256).max);
        vm.prank(PLAYER);
        stimmy.stake(1 ether);
    }

    // ============ Basic Flip Tests ============

    function testFlipWinTransfersRewards() public {
        // Default threshold (DIVIDEND_THRESHOLD = 400k) is already high enough to prevent dividends
        // House balance (200k) is below threshold, so no dividends will be paid
        BetSettlement memory settlement =
            _flipAndGetSettlement(200 ether, bytes32(uint256(1) << 255), USER_DATA_HEADS, _commitment());

        uint256 expectedEth = _expectedPayout(200 ether);
        assertEq(settlement.payout, expectedEth, "payout mismatch");
        assertEq(PLAYER.balance, lastPlayerEthAfterBet + settlement.payout, "player balance mismatch");
        assertGt(grimmy.balanceOf(PLAYER), lastPlayerGrimmyBefore, "player should receive Grimmy reward");
        assertEq(settlement.userData, USER_DATA_HEADS, "userData should be HEADS");
    }

    function testFlipLoseNoRewards() public {
        BetSettlement memory settlement = _flipAndGetSettlement(200 ether, bytes32(uint256(1)), USER_DATA_TAILS);

        assertEq(settlement.flips, 0, "expected loss (no flips)");
        assertEq(settlement.payout, 0, "no ETH payout on loss");
        assertEq(settlement.grimmyBonus, 0, "no Grimmy reward on loss");
        assertEq(PLAYER.balance, lastPlayerEthAfterBet, "player balance unchanged on loss");
        assertEq(settlement.userData, USER_DATA_TAILS, "userData should be TAILS");
    }

    function testFlipRevertsWithStaleCommitment() public {
        uint256 betAmount = 200 ether;
        uint128 entropyFee = flippy.currentEntropyFee();
        uint256 houseFee = _houseFee(betAmount);

        bytes32 staleCommitment = keccak256(abi.encode(flippy.callbackGasLimit() + 1, flippy.timeout(), flippy.fee()));

        vm.prank(PLAYER);
        vm.expectRevert(Flippy.InvalidCommitment.selector);
        flippy.flip{value: betAmount + houseFee + entropyFee}(betAmount, USER_DATA_HEADS, staleCommitment);
    }

    function testFlipRefundsExcessEth() public {
        uint256 betAmount = 200 ether;
        uint128 entropyFee = flippy.currentEntropyFee();
        uint256 houseFee = _houseFee(betAmount);
        uint256 extraValue = 5 ether;
        uint256 totalValue = betAmount + houseFee + entropyFee + extraValue;

        // Compute commitment before pranking since _commitment() makes external calls
        bytes32 commitment = _commitment();

        uint256 playerBalanceBefore = PLAYER.balance;
        uint256 houseBalanceBefore = address(flippy).balance;

        vm.prank(PLAYER);
        uint256 betKey = flippy.flip{value: totalValue}(betAmount, USER_DATA_HEADS, commitment);

        uint256 playerBalanceAfter = PLAYER.balance;
        uint256 houseBalanceAfter = address(flippy).balance;

        // Player should receive the excess back immediately
        assertEq(
            playerBalanceAfter, playerBalanceBefore - (betAmount + houseFee + entropyFee), "excess ETH not refunded"
        );
        assertEq(
            houseBalanceAfter - houseBalanceBefore,
            betAmount + houseFee,
            "house balance should increase by bet plus house fee only"
        );
        assertEq(flippy.pendingEthWithdrawals(PLAYER), 0, "no pending withdrawals on immediate refund");

        Flippy.Bet memory storedBet = flippy.getPendingBet(betKey);
        assertEq(storedBet.player, PLAYER, "bet player should match caller");
        assertEq(storedBet.amount, betAmount, "bet amount stored correctly after refund");
    }

    // ============ Dividend Tests ============

    function testPayoutRewardsSendsSurplusEthToStimmy() public {
        uint256 houseEthBefore = address(flippy).balance;
        uint256 threshold = houseEthBefore - 5000 ether;
        vm.prank(address(this));
        flippy.setDividendThreshold(threshold);

        uint256 stimmyEthBefore = address(stimmy).balance;

        // Make a flip that will trigger dividend payout
        // Flow: flip() receives betAmount + houseFee + entropyFee, pays entropy fee, then calls _payoutDividends
        // When _payoutDividends is called: house balance = houseEthBefore + betAmount + houseFee
        // Later, entropyCallback may pay out to player if they win
        BetSettlement memory settlement = _flipAndGetSettlement(200 ether, bytes32(uint256(1) << 255), USER_DATA_HEADS);

        // Calculate expected dividend (paid during flip, before player payout)
        // House balance when dividends are paid = houseEthBefore + betAmount + houseFee
        uint256 houseBalanceWhenDividendsPaid = houseEthBefore + _totalBetCost(200 ether);
        uint256 expectedDividend =
            houseBalanceWhenDividendsPaid > threshold ? houseBalanceWhenDividendsPaid - threshold : 0;

        // Final house balance = houseEthBefore + betAmount - dividend - playerPayout
        uint256 expectedHouseBalance = houseBalanceWhenDividendsPaid - expectedDividend - settlement.payout;

        assertEq(address(flippy).balance, expectedHouseBalance, "house balance mismatch");
        assertEq(address(stimmy).balance, stimmyEthBefore + expectedDividend, "Stimmy receives surplus");
    }

    function testDividendThresholdNoPayoutWhenBelowThreshold() public {
        // Default setup: HOUSE_ETH = 200k, DIVIDEND_THRESHOLD = 400k
        // House balance (200k) is below threshold (400k), so no dividends should be paid
        uint256 stimmyEthBefore = address(stimmy).balance;
        uint256 houseEthBefore = address(flippy).balance;

        assertEq(flippy.dividendThreshold(), DIVIDEND_THRESHOLD, "threshold should be 400k");
        assertLt(houseEthBefore, DIVIDEND_THRESHOLD, "house balance should be below threshold");

        // Make a flip - dividends should NOT be paid
        _flipAndGetSettlement(200 ether, bytes32(uint256(1) << 255), USER_DATA_HEADS);

        // Stimmy should not receive any dividends
        assertEq(address(stimmy).balance, stimmyEthBefore, "Stimmy should not receive dividends when below threshold");
    }

    function testDividendThresholdPayoutWhenAboveThreshold() public {
        // Set threshold lower so we can test dividend payout
        uint256 threshold = HOUSE_ETH - 10_000 ether; // 190k threshold
        vm.prank(address(this));
        flippy.setDividendThreshold(threshold);

        uint256 stimmyEthBefore = address(stimmy).balance;
        uint256 houseEthBefore = address(flippy).balance;

        // Make a flip that will push balance above threshold
        // House starts at 200k, threshold is 190k
        // After receiving 200 ether bet + house fee, balance > threshold
        _flipAndGetSettlement(200 ether, bytes32(uint256(1) << 255), USER_DATA_HEADS);

        // Calculate expected dividend
        uint256 houseBalanceWhenDividendsPaid = houseEthBefore + _totalBetCost(200 ether);
        uint256 expectedDividend =
            houseBalanceWhenDividendsPaid > threshold ? houseBalanceWhenDividendsPaid - threshold : 0;

        // Verify dividend was paid
        assertGt(expectedDividend, 0, "dividend should be paid when above threshold");
        assertEq(address(stimmy).balance, stimmyEthBefore + expectedDividend, "Stimmy should receive dividends");
    }

    function testFlipDistributesDividendsWhenHouseAlreadyAboveThreshold() public {
        uint256 betAmount = 200 ether;
        uint256 threshold = flippy.dividendThreshold();
        uint256 initialHouse = threshold + 10_000 ether;
        vm.deal(address(flippy), initialHouse);

        uint256 stimmyEthBefore = address(stimmy).balance;

        BetSettlement memory settlement = _flipAndGetSettlement(betAmount, bytes32(uint256(1) << 255), USER_DATA_HEADS);

        uint256 expectedDividend = initialHouse + _totalBetCost(betAmount) - threshold;
        assertEq(
            address(stimmy).balance, stimmyEthBefore + expectedDividend, "Stimmy should receive surplus above threshold"
        );
        assertGt(settlement.payout, 0, "flip should still settle successfully");
    }

    function testDividendThresholdRespectsMaxPendingPayout() public {
        vm.prank(address(this));
        flippy.setDividendThreshold(0);

        uint256 betAmount = 10_000 ether;
        uint256 houseBalanceBefore = address(flippy).balance;
        uint256 stimmyBalanceBefore = address(stimmy).balance;

        BetPlacement memory placement = _placeBet(betAmount, USER_DATA_HEADS, _commitment());

        uint256 expectedThreshold = betAmount * flippy.PAYOUT_MULTIPLIER();
        uint256 expectedHouseAfterFlip = houseBalanceBefore + betAmount + placement.houseFee;
        uint256 expectedDividend =
            expectedHouseAfterFlip > expectedThreshold ? expectedHouseAfterFlip - expectedThreshold : 0;

        assertEq(
            address(stimmy).balance,
            stimmyBalanceBefore + expectedDividend,
            "dividends should leave enough to cover pending payouts"
        );

        mockEntropy.mockReveal(provider, _betKeyToSequence(placement.betKey), bytes32(uint256(1)));
    }

    // ============ Greased Reward Tests ============

    function testGreasedRewardWithinCapacity() public {
        uint256 stimmyBalance = 40_000 ether;
        _mockStimmyBalance(stimmyBalance);

        uint256 betAmount = 200 ether;
        BetSettlement memory settlement = _flipAndGetSettlement(betAmount, bytes32(uint256(1) << 255), USER_DATA_HEADS);

        uint256 capacity = stimmyBalance / 10;
        uint256 baseReward = (betAmount * (settlement.flips - 1)) / (uint256(1) << flippy.epoch());
        uint256 expectedBonus = baseReward * 3;
        if (expectedBonus > capacity) expectedBonus = capacity;

        assertEq(settlement.grimmyBonus, baseReward + expectedBonus, "bonus should be fully applied");

        uint40 day = uint40(block.timestamp / 1 days);
        uint256 key = (uint256(uint160(PLAYER)) << 40) | day;
        assertEq(flippy.greasedRewards(key), expectedBonus, "bonus tracking incorrect");

        vm.clearMockedCalls();
    }

    function testGreasedRewardPartialCapacity() public {
        uint256 stimmyBalance = 5 ether;
        _mockStimmyBalance(stimmyBalance);

        uint256 betAmount = 300 ether;
        BetSettlement memory settlement = _flipAndGetSettlement(betAmount, bytes32(uint256(1) << 255), USER_DATA_HEADS);

        uint256 capacity = stimmyBalance / 10;
        uint256 baseReward = (betAmount * (settlement.flips - 1)) / (uint256(1) << flippy.epoch());
        uint256 expectedBonus = baseReward * 3;
        if (expectedBonus > capacity) expectedBonus = capacity;

        assertEq(settlement.grimmyBonus, baseReward + expectedBonus, "bonus capped by capacity");

        uint40 day = uint40(block.timestamp / 1 days);
        uint256 key = (uint256(uint160(PLAYER)) << 40) | day;
        assertEq(flippy.greasedRewards(key), expectedBonus, "bonus tracking incorrect");

        vm.clearMockedCalls();
    }

    // ============ Epoch Tests ============

    function testEpochIncreasesByOne() public {
        // Initial epoch is 0, threshold for epoch 0 is 690_000_000 >> (0+1) = 690_000_000 >> 1 = 345_000_000 ether
        // Threshold for epoch 1 is 690_000_000 >> (1+1) = 690_000_000 >> 2 = 172_500_000 ether
        // We need to mine enough to get below 345_000_000 to trigger epoch 1

        uint16 initialEpoch = flippy.epoch();
        assertEq(initialEpoch, 0, "initial epoch should be 0");

        uint256 thresholdEpoch1 = _epochThreshold(0); // 345_000_000 ether (epoch 0 threshold)
        uint256 currentBalance = grimmy.balanceOf(address(flippy));
        assertGt(currentBalance, thresholdEpoch1, "should be above epoch 1 threshold initially");

        // Mine enough to get just below epoch 1 threshold
        uint256 amountToMine = currentBalance - thresholdEpoch1 + 1 ether;
        _mineGrimmy(amountToMine);

        uint256 balanceAfterMining = grimmy.balanceOf(address(flippy));
        assertLe(balanceAfterMining, thresholdEpoch1, "balance should be at or below epoch 1 threshold");

        // Make a flip - this should trigger epoch update when the bet settles
        vm.recordLogs();
        BetPlacement memory placement = _placeBet(200 ether, USER_DATA_HEADS);
        uint256 betKey = placement.betKey;
        mockEntropy.mockReveal(provider, _betKeyToSequence(betKey), bytes32(uint256(1) << 255));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Check for EpochAdvanced event
        // EpochAdvanced(uint256 newEpoch) - newEpoch is non-indexed, so it's in data, not topics
        bool epochAdvanced = false;
        uint256 newEpoch = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory entry = logs[i];
            if (entry.topics.length > 0 && entry.topics[0] == EPOCH_ADVANCED_SIG) {
                epochAdvanced = true;
                newEpoch = abi.decode(entry.data, (uint256));
                break;
            }
        }

        assertTrue(epochAdvanced, "EpochAdvanced event should be emitted");
        assertEq(newEpoch, 1, "epoch should advance to 1");
        assertEq(flippy.epoch(), 1, "epoch should be 1");
    }

    function testEpochIncreasesByMultiple() public {
        // Test epoch jumping by multiple levels
        // Epoch 0 threshold: 690_000_000 >> (0+1) = 345_000_000
        // Epoch 1 threshold: 690_000_000 >> (1+1) = 172_500_000
        // Epoch 2 threshold: 690_000_000 >> (2+1) = 86_250_000
        // Epoch 3 threshold: 690_000_000 >> (3+1) = 43_125_000

        uint16 initialEpoch = flippy.epoch();
        assertEq(initialEpoch, 0, "initial epoch should be 0");

        // Mine enough to get below epoch 3 threshold (43_125_000)
        uint256 thresholdEpoch3 = _epochThreshold(2); // 43_125_000 ether
        uint256 currentBalance = grimmy.balanceOf(address(flippy));
        uint256 amountToMine = currentBalance - thresholdEpoch3 + 1 ether;
        _mineGrimmy(amountToMine);

        uint256 balanceAfterMining = grimmy.balanceOf(address(flippy));
        assertLe(balanceAfterMining, thresholdEpoch3, "balance should be at or below epoch 3 threshold");

        // Make a flip - this should trigger epoch to jump to 3 once settled
        vm.recordLogs();
        BetPlacement memory placement = _placeBet(200 ether, USER_DATA_HEADS);
        uint256 betKey = placement.betKey;
        mockEntropy.mockReveal(provider, _betKeyToSequence(betKey), bytes32(uint256(1) << 255));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Check for EpochAdvanced event
        // EpochAdvanced(uint256 newEpoch) - newEpoch is non-indexed, so it's in data, not topics
        bool epochAdvanced = false;
        uint256 newEpoch = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory entry = logs[i];
            if (entry.topics.length > 0 && entry.topics[0] == EPOCH_ADVANCED_SIG) {
                epochAdvanced = true;
                newEpoch = abi.decode(entry.data, (uint256));
                break;
            }
        }

        assertTrue(epochAdvanced, "EpochAdvanced event should be emitted");
        assertEq(newEpoch, 3, "epoch should advance to 3");
        assertEq(flippy.epoch(), 3, "epoch should be 3");
    }

    function testEpochAtEndOfLifecycle() public {
        // Test what happens when GRIMMY runs out
        // Keep mining and flipping until GRIMMY is exhausted

        uint16 initialEpoch = flippy.epoch();
        uint256 initialBalance = grimmy.balanceOf(address(flippy));

        // Mine most of the GRIMMY, leaving just a small amount
        uint256 amountToMine = initialBalance - 1000 ether; // Leave 1000 ether
        _mineGrimmy(amountToMine);

        uint256 balanceAfterMining = grimmy.balanceOf(address(flippy));
        assertEq(balanceAfterMining, 1000 ether, "should have 1000 ether left");

        // Calculate what epoch this should trigger
        // Find the epoch where threshold > 1000
        uint256 targetEpoch = initialEpoch;
        while (true) {
            uint256 threshold = _epochThreshold(targetEpoch);
            if (threshold == 0 || balanceAfterMining > threshold) {
                break;
            }
            targetEpoch++;
        }

        // Make a flip - epoch should update during settlement
        _flipAndGetSettlement(200 ether, bytes32(uint256(1) << 255), USER_DATA_HEADS);

        // Check epoch advanced
        uint256 finalEpoch = flippy.epoch();
        assertGe(finalEpoch, targetEpoch, "epoch should be at least at target");

        // Now mine the remaining GRIMMY
        _mineGrimmy(0); // Mine all remaining

        uint256 balanceAfterFullMining = grimmy.balanceOf(address(flippy));
        assertEq(balanceAfterFullMining, 0, "all GRIMMY should be mined");

        // Make another flip - epoch update happens during settlement, rewards should be 0
        BetSettlement memory settlement2 = _flipAndGetSettlement(200 ether, bytes32(uint256(1) << 255), USER_DATA_HEADS);

        // Check epoch advanced again
        uint256 finalEpoch2 = flippy.epoch();
        assertGe(finalEpoch2, finalEpoch, "epoch should not decrease once GRIMMY depleted");

        // With balance at 0, rewards should be 0 (or very small due to high epoch divisor)
        // The reward calculation: (betAmount * flips) / (1 << epoch)
        // With high epoch, this will be 0 or very small
        assertEq(settlement2.grimmyBonus, 0, "grimmy bonus should be 0 when balance is 0");

        // Continue flipping until epoch stabilizes
        // Keep track of epoch progression
        uint256 previousEpoch = finalEpoch2;
        for (uint256 i = 0; i < 10; i++) {
            _flipAndGetSettlement(200 ether, bytes32(uint256(1) << 255), USER_DATA_HEADS);
            uint256 currentEpoch = flippy.epoch();

            // Epoch should keep increasing or stay the same (can't decrease)
            assertGe(currentEpoch, previousEpoch, "epoch should not decrease");

            // If epoch didn't change, we've reached the maximum for balance = 0
            if (currentEpoch == previousEpoch) {
                break;
            }
            previousEpoch = currentEpoch;
        }

        // Final check: rewards should be 0 with very high epoch
        BetSettlement memory finalSettlement =
            _flipAndGetSettlement(200 ether, bytes32(uint256(1) << 255), USER_DATA_HEADS);
        assertEq(finalSettlement.grimmyBonus, 0, "grimmy bonus should be 0 at end of lifecycle");
    }

    // ============ Mining GRIMMY Tests ============

    function testMiningGrimmyWithFullBonus() public {
        // Test mining GRIMMY when user has STIMMY and gets full bonus
        // Bonus capacity = STIMMY balance / 10
        // Bonus = baseReward * 3 (capped by capacity)

        uint256 stimmyBalance = 100_000 ether;
        _mockStimmyBalance(stimmyBalance);

        uint256 betAmount = 200 ether;
        uint256 epoch = flippy.epoch();
        // Rewards divisor scales as 2^epoch
        uint256 divisor = uint256(1) << epoch;

        // Use random number with trailingZeros = 10 to get a good base reward
        // baseReward = (betAmount * 9) / divisor (flips - 1 = 10 - 1 = 9)
        // Bonus = baseReward * 3 (capped by capacity)
        bytes32 randomNumber = bytes32(uint256(1) << 255 | (uint256(1) << 10)); // MSB=1 (win), trailingZeros=10

        BetSettlement memory settlement = _flipAndGetSettlement(betAmount, randomNumber, USER_DATA_HEADS);

        uint256 expectedBaseReward = (betAmount * 9) / divisor; // flips - 1 = 10 - 1
        uint256 expectedBonus = expectedBaseReward * 3;
        uint256 expectedTotalReward = expectedBaseReward + expectedBonus;

        assertEq(settlement.grimmyBonus, expectedTotalReward, "should get base reward + full bonus");
        assertGt(settlement.grimmyBonus, expectedBaseReward, "bonus should be applied");

        // Check that greasedRewards tracking is correct
        uint40 day = uint40(block.timestamp / 1 days);
        uint256 key = (uint256(uint160(PLAYER)) << 40) | day;
        assertEq(flippy.greasedRewards(key), expectedBonus, "greasedRewards should track bonus amount");

        vm.clearMockedCalls();
    }

    function testMiningGrimmyWithPartialBonus() public {
        // Test mining GRIMMY when bonus is partially used up
        // First, use up some of the bonus capacity
        // Then mine more and verify partial bonus applies

        uint256 stimmyBalance = 100_000 ether;
        _mockStimmyBalance(stimmyBalance);

        uint256 betAmount = 200 ether;
        // Rewards divisor scales as 2^epoch
        uint256 divisor = uint256(1) << flippy.epoch();
        uint256 bonusCapacity = stimmyBalance / 10;

        // First bet: use up most (but not all) of the bonus capacity
        uint256 firstTrailingZeros = 15;
        bytes32 randomNumber = bytes32(uint256(1) << 255 | (uint256(1) << firstTrailingZeros));
        _flipAndGetSettlement(betAmount, randomNumber, USER_DATA_HEADS);

        // Verify first bet used up bonus
        uint40 day = uint40(block.timestamp / 1 days);
        uint256 key = (uint256(uint160(PLAYER)) << 40) | day;
        uint256 firstBonus = (betAmount * (firstTrailingZeros - 1)) / divisor;
        firstBonus = firstBonus * 3; // flips - 1
        assertEq(flippy.greasedRewards(key), firstBonus, "first bet should use bonus");

        // Second bet: should get partial bonus (remaining capacity)
        bonusCapacity -= firstBonus;
        uint256 secondTrailingZeros = 13;
        randomNumber = bytes32(uint256(1) << 255 | (uint256(1) << secondTrailingZeros));
        BetSettlement memory secondSettlement = _flipAndGetSettlement(betAmount, randomNumber, USER_DATA_HEADS);

        uint256 secondBaseReward = (betAmount * (secondTrailingZeros - 1)) / divisor; // flips - 1
        uint256 expectedSecondBonus = (secondBaseReward * 3 > bonusCapacity) ? bonusCapacity : secondBaseReward * 3;

        assertEq(
            secondSettlement.grimmyBonus,
            secondBaseReward + expectedSecondBonus,
            "should get base reward + partial bonus"
        );
        assertEq(flippy.greasedRewards(key), firstBonus + expectedSecondBonus, "greasedRewards should accumulate");

        vm.clearMockedCalls();
    }

    function testMiningGrimmyAfterBonusExhausted() public {
        // Test mining GRIMMY after all bonus capacity is used up
        // Should only get base reward, no bonus

        uint256 stimmyBalance = 100_000 ether;
        _mockStimmyBalance(stimmyBalance);

        uint256 betAmount = 200 ether;
        uint256 epoch = flippy.epoch();
        // Rewards divisor scales as 2^epoch
        uint256 divisor = uint256(1) << epoch;

        // First, exhaust all bonus capacity with a large bet
        uint256 firstTrailingZeros = 100;
        bytes32 firstRandom = bytes32(uint256(1) << 255 | (uint256(1) << firstTrailingZeros));
        _flipAndGetSettlement(betAmount, firstRandom, USER_DATA_HEADS);

        // Verify bonus is exhausted
        uint40 day = uint40(block.timestamp / 1 days);
        uint256 key = (uint256(uint160(PLAYER)) << 40) | day;
        uint256 bonusCapacity = stimmyBalance / 10;
        assertEq(flippy.greasedRewards(key), bonusCapacity, "bonus capacity should be exhausted");

        // Second bet: should only get base reward, no bonus
        uint256 secondTrailingZeros = 20;
        bytes32 secondRandom = bytes32(uint256(1) << 255 | (uint256(1) << secondTrailingZeros));
        BetSettlement memory secondSettlement = _flipAndGetSettlement(betAmount, secondRandom, USER_DATA_HEADS);

        assertEq(
            secondSettlement.grimmyBonus,
            (betAmount * (secondTrailingZeros - 1)) / divisor,
            "should only get base reward"
        );
        assertEq(flippy.greasedRewards(key), bonusCapacity, "greasedRewards should remain at capacity");

        vm.clearMockedCalls();
    }

    function testMiningGrimmyWithoutStimmy() public {
        // Test mining GRIMMY when user has no STIMMY
        // Should only get base reward, no bonus

        uint256 stimmyBalance = 0;
        _mockStimmyBalance(stimmyBalance);

        uint256 betAmount = 200 ether;
        uint256 epoch = flippy.epoch();
        // Rewards divisor scales as 2^epoch
        uint256 divisor = uint256(1) << epoch;
        uint256 trailingZeros = 10;

        bytes32 randomNumber = bytes32(uint256(1) << 255 | (uint256(1) << trailingZeros));
        BetSettlement memory settlement = _flipAndGetSettlement(betAmount, randomNumber, USER_DATA_HEADS);

        uint256 expectedBaseReward = (betAmount * (trailingZeros - 1)) / divisor; // flips - 1

        assertEq(settlement.grimmyBonus, expectedBaseReward, "should only get base reward without STIMMY");

        // Verify no bonus was tracked
        uint40 day = uint40(block.timestamp / 1 days);
        uint256 key = (uint256(uint160(PLAYER)) << 40) | day;
        assertEq(flippy.greasedRewards(key), 0, "no bonus should be tracked without STIMMY");

        vm.clearMockedCalls();
    }

    // ============ Helper Functions ============

    function _flipAndGetSettlement(uint256 betAmount, bytes32 randomNumber, bytes32 userData)
        internal
        returns (BetSettlement memory)
    {
        return _flipAndGetSettlement(betAmount, randomNumber, userData, _commitment());
    }

    function _flipAndGetSettlement(uint256 betAmount, bytes32 randomNumber, bytes32 userData, bytes32 commitment)
        internal
        returns (BetSettlement memory settlement)
    {
        lastPlayerGrimmyBefore = grimmy.balanceOf(PLAYER);
        BetPlacement memory placement = _placeBet(betAmount, userData, commitment);
        uint256 betKey = placement.betKey;

        vm.recordLogs();
        mockEntropy.mockReveal(provider, _betKeyToSequence(betKey), randomNumber);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory entry = logs[i];
            if (entry.topics.length == 0 || entry.topics[0] != BET_SETTLED_SIG) continue;
            settlement.betKey = uint256(entry.topics[1]);
            settlement.player = address(uint160(uint256(entry.topics[2])));
            (settlement.userData, settlement.payout, settlement.grimmyBonus, settlement.flips) =
                abi.decode(entry.data, (bytes32, uint256, uint256, uint256));
            break;
        }

        require(settlement.player != address(0), "BetSettled event not found");

        Flippy.Bet memory storedBet = flippy.getPendingBet(betKey);
        assertEq(storedBet.player, PLAYER, "stored bet player mismatch");
        assertEq(storedBet.userData, userData, "stored bet user data mismatch");
        assertEq(storedBet.amount, betAmount, "stored bet amount mismatch");
        assertEq(storedBet.result, settlement.flips + 1, "stored bet result mismatch");
    }

    function _decodeSettlementFromLogs(Vm.Log[] memory logs) internal pure returns (BetSettlement memory settlement) {
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory entry = logs[i];
            if (entry.topics.length == 0 || entry.topics[0] != BET_SETTLED_SIG) continue;
            settlement.betKey = uint256(entry.topics[1]);
            settlement.player = address(uint160(uint256(entry.topics[2])));
            (settlement.userData, settlement.payout, settlement.grimmyBonus, settlement.flips) =
                abi.decode(entry.data, (bytes32, uint256, uint256, uint256));
            break;
        }
        require(settlement.player != address(0), "BetSettled event not found in logs");
    }

    function _betKeyToSequence(uint256 betKey) internal pure returns (uint64 sequence) {
        assembly {
            sequence := and(betKey, 0xFFFFFFFFFFFFFFFF)
        }
    }

    function _expectedPayout(uint256 betAmount) internal pure returns (uint256) {
        return betAmount * PAYOUT_MULTIPLIER;
    }

    function _houseFee(uint256 betAmount) internal view returns (uint256) {
        return (betAmount * uint256(flippy.fee())) / flippy.FEE_PRECISION();
    }

    function _totalBetCost(uint256 betAmount) internal view returns (uint256) {
        return betAmount + _houseFee(betAmount);
    }

    function _commitment() internal view returns (bytes32) {
        return keccak256(abi.encode(flippy.callbackGasLimit(), flippy.timeout(), flippy.fee()));
    }

    function _placeBet(uint256 betAmount, bytes32 userData) internal returns (BetPlacement memory placement) {
        return _placeBet(betAmount, userData, _commitment());
    }

    function _placeBet(uint256 betAmount, bytes32 userData, bytes32 commitment)
        internal
        returns (BetPlacement memory placement)
    {
        uint128 entropyFee = flippy.currentEntropyFee();
        uint256 houseFee = _houseFee(betAmount);

        vm.prank(PLAYER);
        uint256 betKey = flippy.flip{value: betAmount + houseFee + entropyFee}(betAmount, userData, commitment);
        lastPlayerEthAfterBet = PLAYER.balance;

        placement = BetPlacement({betKey: betKey, houseFee: houseFee, entropyFee: entropyFee});
    }

    function _mockStimmyBalance(uint256 balance) internal {
        vm.mockCall(address(stimmy), abi.encodeWithSelector(ERC20.balanceOf.selector, PLAYER), abi.encode(balance));
    }

    /// @notice Helper function to mine GRIMMY by reducing Flippy's balance
    /// @param amount Amount of GRIMMY to mine (0 = mine all)
    function _mineGrimmy(uint256 amount) internal {
        uint256 balance = grimmy.balanceOf(address(flippy));
        uint256 amountToMine = amount == 0 ? balance : amount;
        if (amountToMine > balance) {
            amountToMine = balance;
        }
        if (amountToMine > 0) {
            // Use deal to reduce Flippy's balance and increase MINER's balance
            uint256 newBalance = balance - amountToMine;
            deal(address(grimmy), address(flippy), newBalance);
            deal(address(grimmy), MINER, grimmy.balanceOf(MINER) + amountToMine);
        }
    }

    /// @notice Calculate the threshold for a given epoch
    /// Epoch 0: no halving (threshold = INITIAL_GRIMMY_RESERVE)
    /// Epoch 1: first halving (threshold = INITIAL_GRIMMY_RESERVE / 2)
    /// Epoch 2: second halving (threshold = INITIAL_GRIMMY_RESERVE / 4), etc.
    function _epochThreshold(uint256 epochNum) internal pure returns (uint256) {
        return INITIAL_GRIMMY_RESERVE >> (epochNum + 1);
    }

    // ============ Cancel/Timeout Tests ============

    function testCancelBetAfterTimeout() public {
        uint256 betAmount = 200 ether;
        uint256 playerBalanceBefore = PLAYER.balance;

        // Place a bet
        BetPlacement memory placement = _placeBet(betAmount, USER_DATA_HEADS);
        uint256 betKey = placement.betKey;

        // Verify bet is pending
        Flippy.Bet memory bet = flippy.getPendingBet(betKey);
        assertEq(bet.player, PLAYER, "player should match");
        assertEq(bet.amount, betAmount, "bet amount should match");
        assertEq(bet.userData, USER_DATA_HEADS, "user data should match");
        assertGt(bet.expiresAt, block.timestamp, "bet should not be expired yet");
        assertEq(bet.result, 0, "bet should not be settled yet");

        // Fast forward time past expiration
        uint256 timeoutDuration = uint256(flippy.timeout());
        vm.warp(block.timestamp + timeoutDuration + 1);

        // Cancel the bet - expect BetCanceled event
        vm.expectEmit(true, false, false, false);
        emit Flippy.BetCanceled(betKey);
        vm.prank(PLAYER);
        flippy.cancel(betKey);

        // Verify bet was marked as cancelled
        bet = flippy.getPendingBet(betKey);
        assertEq(bet.player, PLAYER, "bet record should persist for auditing");
        assertEq(bet.result, type(uint16).max, "bet should be marked cancelled");

        // Verify player received refund
        assertEq(
            PLAYER.balance,
            playerBalanceBefore - placement.houseFee - placement.entropyFee,
            "player should only lose fees"
        );
    }

    function testCancelBetBeforeTimeoutReverts() public {
        uint256 betAmount = 200 ether;

        // Place a bet
        BetPlacement memory placement = _placeBet(betAmount, USER_DATA_HEADS);
        uint256 betKey = placement.betKey;

        // Try to cancel immediately (before timeout)
        vm.prank(PLAYER);
        vm.expectRevert(abi.encodeWithSelector(Flippy.BetNotExpired.selector, betKey));
        flippy.cancel(betKey);

        // Verify bet is still pending
        Flippy.Bet memory bet = flippy.getPendingBet(betKey);
        assertEq(bet.player, PLAYER, "bet should still exist");
        assertEq(bet.amount, betAmount, "bet amount should still be set");
        assertEq(bet.userData, USER_DATA_HEADS, "user data should be stored");
        assertGt(bet.expiresAt, block.timestamp, "bet should not be expired");
        assertEq(bet.result, 0, "result should remain unset");
    }

    function testCancelAlreadySettledBetReverts() public {
        uint256 betAmount = 200 ether;

        // Place a bet and settle it
        BetPlacement memory placement = _placeBet(betAmount, USER_DATA_HEADS);
        uint256 betKey = placement.betKey;

        // Settle the bet
        mockEntropy.mockReveal(provider, _betKeyToSequence(betKey), bytes32(uint256(1) << 255));

        // Fast forward time past expiration
        uint256 timeoutDuration = uint256(flippy.timeout());
        vm.warp(block.timestamp + timeoutDuration + 1);

        // Try to cancel - should revert because bet is already deleted
        vm.prank(PLAYER);
        vm.expectRevert(abi.encodeWithSelector(Flippy.BetAlreadySettled.selector, betKey));
        flippy.cancel(betKey);
    }

    function testCancelNonExistentBetReverts() public {
        uint256 nonExistentBetKey = 999;

        vm.prank(PLAYER);
        vm.expectRevert(abi.encodeWithSelector(Flippy.UnknownBet.selector, nonExistentBetKey));
        flippy.cancel(nonExistentBetKey);
    }

    function testCancelMultipleBets() public {
        uint256 betAmount1 = 200 ether;
        uint256 betAmount2 = 300 ether;

        uint256 playerBalanceBefore = PLAYER.balance;

        // Place two bets
        BetPlacement memory placement1 = _placeBet(betAmount1, USER_DATA_HEADS);
        uint256 betKey1 = placement1.betKey;

        BetPlacement memory placement2 = _placeBet(betAmount2, USER_DATA_HEADS);
        uint256 betKey2 = placement2.betKey;

        // Fast forward time past expiration
        uint256 timeoutDuration = uint256(flippy.timeout());
        vm.warp(block.timestamp + timeoutDuration + 1);

        // Cancel first bet
        vm.prank(PLAYER);
        flippy.cancel(betKey1);

        // Verify first bet is marked cancelled
        Flippy.Bet memory bet1 = flippy.getPendingBet(betKey1);
        assertEq(bet1.player, PLAYER, "first bet record should persist");
        assertEq(bet1.result, type(uint16).max, "first bet should be marked cancelled");

        // Verify second bet still exists
        Flippy.Bet memory bet2 = flippy.getPendingBet(betKey2);
        assertEq(bet2.player, PLAYER, "second bet should still exist");
        assertEq(bet2.amount, betAmount2, "second bet amount should match");
        assertEq(bet2.userData, USER_DATA_HEADS, "user data should match for second bet");
        assertEq(bet2.result, 0, "second bet should still be pending");

        // Cancel second bet
        vm.prank(PLAYER);
        flippy.cancel(betKey2);

        // Verify second bet is marked cancelled
        bet2 = flippy.getPendingBet(betKey2);
        assertEq(bet2.player, PLAYER, "second bet record should persist");
        assertEq(bet2.result, type(uint16).max, "second bet should be marked cancelled");

        // Verify total refund (fees are kept by the house)
        uint256 totalFees = placement1.houseFee + placement1.entropyFee + placement2.houseFee + placement2.entropyFee;
        assertEq(PLAYER.balance, playerBalanceBefore - totalFees, "player should only lose fees");
    }

    function testCancelBetAtExactExpirationTime() public {
        uint256 betAmount = 200 ether;

        // Place a bet
        BetPlacement memory placement = _placeBet(betAmount, USER_DATA_HEADS);
        uint256 betKey = placement.betKey;

        // Get expiration time
        uint64 expiresAt = flippy.getPendingBet(betKey).expiresAt;

        // Fast forward to exact expiration time
        vm.warp(expiresAt);

        // At exact expiration time, expiresAt == block.timestamp, so expiresAt > block.timestamp is false
        // This means cancel should succeed (not revert)
        vm.prank(PLAYER);
        flippy.cancel(betKey);

        // Verify bet was canceled
        Flippy.Bet memory betAfter = flippy.getPendingBet(betKey);
        assertEq(betAfter.player, PLAYER, "bet record should persist for auditing");
        assertEq(betAfter.result, type(uint16).max, "bet result should mark cancellation");

        // Test that canceling before expiration still reverts
        // Place a new bet
        placement = _placeBet(betAmount, USER_DATA_HEADS);
        uint256 betKey2 = placement.betKey;

        // Get expiration time
        uint64 expiresAt2 = flippy.getPendingBet(betKey2).expiresAt;

        // Fast forward to 1 second before expiration
        vm.warp(expiresAt2 - 1);

        // Should revert because expiresAt > block.timestamp
        vm.prank(PLAYER);
        vm.expectRevert(abi.encodeWithSelector(Flippy.BetNotExpired.selector, betKey2));
        flippy.cancel(betKey2);
    }

    // ============ Expired Bet Callback Tests ============

    function testCallbackRevertsWhenBetExpired() public {
        uint256 betAmount = 200 ether;

        // Place a bet
        BetPlacement memory placement = _placeBet(betAmount, USER_DATA_HEADS);
        uint256 betKey = placement.betKey;

        // Verify bet is pending
        Flippy.Bet memory bet = flippy.getPendingBet(betKey);
        assertEq(bet.player, PLAYER, "player should match");
        assertEq(bet.amount, betAmount, "bet amount should match");
        assertEq(bet.userData, USER_DATA_HEADS, "user data should match");
        assertGt(bet.expiresAt, block.timestamp, "bet should not be expired yet");
        assertEq(bet.result, 0, "bet should not be settled yet");

        // Fast forward time past expiration
        uint256 timeoutDuration = uint256(flippy.timeout());
        vm.warp(block.timestamp + timeoutDuration + 1);

        // Try to reveal - should revert with BetExpired error
        vm.expectRevert(abi.encodeWithSelector(Flippy.BetExpired.selector, betKey));
        mockEntropy.mockReveal(provider, _betKeyToSequence(betKey), bytes32(uint256(1) << 255));

        // Verify bet is still pending (not deleted by callback)
        bet = flippy.getPendingBet(betKey);
        assertEq(bet.player, PLAYER, "bet should still exist after expired callback revert");
        assertEq(bet.amount, betAmount, "bet amount should still be set");
        assertEq(bet.result, 0, "bet result should remain unset");
    }

    function testCallbackRevertsAtExactExpirationTime() public {
        uint256 betAmount = 200 ether;

        // Place a bet
        BetPlacement memory placement = _placeBet(betAmount, USER_DATA_HEADS);
        uint256 betKey = placement.betKey;

        // Get expiration time
        uint64 expiresAt = flippy.getPendingBet(betKey).expiresAt;

        // Fast forward to exact expiration time
        vm.warp(expiresAt);

        // At exact expiration time, expiresAt <= block.timestamp is true, so should revert
        vm.expectRevert(abi.encodeWithSelector(Flippy.BetExpired.selector, betKey));
        mockEntropy.mockReveal(provider, _betKeyToSequence(betKey), bytes32(uint256(1) << 255));

        // Verify bet is still pending
        Flippy.Bet memory betAfter = flippy.getPendingBet(betKey);
        assertEq(betAfter.player, PLAYER, "bet should still exist after expired callback revert");
    }

    function testExpiredBetCanBeCanceledAfterFailedCallback() public {
        uint256 betAmount = 200 ether;
        uint256 playerBalanceBefore = PLAYER.balance;

        // Place a bet
        BetPlacement memory placement = _placeBet(betAmount, USER_DATA_HEADS);
        uint256 betKey = placement.betKey;

        // Fast forward time past expiration
        uint256 timeoutDuration = uint256(flippy.timeout());
        vm.warp(block.timestamp + timeoutDuration + 1);

        // Try to reveal - should revert with BetExpired error
        vm.expectRevert(abi.encodeWithSelector(Flippy.BetExpired.selector, betKey));
        mockEntropy.mockReveal(provider, _betKeyToSequence(betKey), bytes32(uint256(1) << 255));

        // Verify bet is still pending
        Flippy.Bet memory betPending = flippy.getPendingBet(betKey);
        assertEq(betPending.player, PLAYER, "bet should still exist");

        // Now cancel the bet - should succeed
        vm.prank(PLAYER);
        flippy.cancel(betKey);

        // Verify bet was marked as cancelled
        Flippy.Bet memory betAfter = flippy.getPendingBet(betKey);
        assertEq(betAfter.player, PLAYER, "bet record should persist after cancel");
        assertEq(betAfter.result, type(uint16).max, "bet should be marked cancelled");

        // Verify player received refund
        assertEq(
            PLAYER.balance,
            playerBalanceBefore - placement.houseFee - placement.entropyFee,
            "player should only lose fees after cancel"
        );
    }

    // ============ Payout Edge Case Tests ============

    function testCallbackPaysRemainingHouseBalanceWhenInsufficient() public {
        uint256 betAmount = 200 ether;

        BetPlacement memory placement = _placeBet(betAmount, USER_DATA_HEADS);
        uint256 betKey = placement.betKey;

        // Drain house balance so it cannot cover the theoretical payout
        uint256 reducedHouseBalance = 50 ether;
        vm.deal(address(flippy), reducedHouseBalance);
        uint256 playerBalanceBefore = PLAYER.balance;

        vm.recordLogs();
        mockEntropy.mockReveal(provider, _betKeyToSequence(betKey), bytes32(uint256(1) << 255));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        BetSettlement memory settlement = _decodeSettlementFromLogs(logs);
        assertEq(settlement.payout, reducedHouseBalance, "payout should be capped to remaining house balance");
        assertEq(
            PLAYER.balance,
            playerBalanceBefore + reducedHouseBalance,
            "player should only receive available house balance"
        );
    }

    function testPayoutFailureBecomesClaimable() public {
        uint256 betAmount = 200 ether;
        BetPlacement memory placement = _placeBet(betAmount, USER_DATA_HEADS, _commitment());
        uint256 betKey = placement.betKey;
        uint64 sequence = _betKeyToSequence(betKey);

        vm.mockCallRevert(address(PLAYER), new bytes(0), abi.encodePacked("fail"));
        mockEntropy.mockReveal(provider, sequence, bytes32(uint256(1) << 255));
        vm.clearMockedCalls();

        uint256 claimable = flippy.pendingEthWithdrawals(PLAYER);
        uint256 expected = _expectedPayout(betAmount);
        assertEq(claimable, expected, "winnings should become claimable");

        uint256 balanceBefore = PLAYER.balance;
        vm.prank(PLAYER);
        flippy.claim(PLAYER);

        assertEq(PLAYER.balance, balanceBefore + expected, "claim should transfer pending funds");
        assertEq(flippy.pendingEthWithdrawals(PLAYER), 0, "claimable should be cleared");
    }

    function testCancelFailureBecomesClaimable() public {
        uint256 betAmount = 200 ether;
        BetPlacement memory placement = _placeBet(betAmount, USER_DATA_HEADS, _commitment());
        uint256 betKey = placement.betKey;

        uint256 timeoutDuration = uint256(flippy.timeout());
        vm.warp(block.timestamp + timeoutDuration + 1);

        vm.mockCallRevert(address(PLAYER), new bytes(0), abi.encodePacked("fail"));
        vm.prank(PLAYER);
        flippy.cancel(betKey);
        vm.clearMockedCalls();

        uint256 claimable = flippy.pendingEthWithdrawals(PLAYER);
        assertEq(claimable, betAmount, "refund should become claimable");

        uint256 balanceBefore = PLAYER.balance;
        vm.prank(PLAYER);
        flippy.claim(PLAYER);

        assertEq(PLAYER.balance, balanceBefore + betAmount, "claim should payout refund");
        assertEq(flippy.pendingEthWithdrawals(PLAYER), 0, "claimable should reset");
    }

    function testClaimNoopWhenNothingPending() public {
        assertEq(flippy.pendingEthWithdrawals(PLAYER), 0, "precondition");

        uint256 balanceBefore = PLAYER.balance;
        vm.prank(PLAYER);
        flippy.claim(PLAYER);

        assertEq(flippy.pendingEthWithdrawals(PLAYER), 0, "still zero");
        assertEq(PLAYER.balance, balanceBefore, "balance unchanged");
    }

    function testCancelBetGasRequirements() public {
        uint256 betAmount = 200 ether;
        BetPlacement memory placement = _placeBet(betAmount, USER_DATA_HEADS);
        uint256 betKey = placement.betKey;

        // expire the bet so cancel can run
        uint256 timeoutDuration = uint256(flippy.timeout());
        vm.warp(block.timestamp + timeoutDuration + 1);

        uint256 minGasLeftForCancel = flippy.MIN_GAS_LEFT_FOR_CANCEL();
        vm.prank(PLAYER);
        vm.expectRevert(Flippy.InsufficientGas.selector);
        // supply less gas than MIN_GAS_LEFT_FOR_CANCEL
        flippy.cancel{gas: minGasLeftForCancel - 1}(betKey);
    }
}
