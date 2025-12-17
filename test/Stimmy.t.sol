// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Stimmy} from "../src/Stimmy.sol";
import {Grimmy} from "../src/Grimmy.sol";

contract StimmyTest is Test {
    Stimmy internal stimmy;
    Grimmy internal grimmy;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant REWARDER = address(0xBEEF);

    uint256 internal constant ALICE_STAKE = 1_000 ether;
    uint256 internal constant BOB_STAKE = 3_000 ether;

    function setUp() public {
        grimmy = new Grimmy();
        address stimmyTemplate = address(new Stimmy(address(grimmy)));
        stimmy = Stimmy(
            payable(new ERC1967Proxy(
                    address(stimmyTemplate), abi.encodeWithSelector(Stimmy.initialize.selector, address(this))
                ))
        );

        assertTrue(grimmy.transfer(ALICE, ALICE_STAKE), "mint transfer to alice failed");
        assertTrue(grimmy.transfer(BOB, BOB_STAKE), "mint transfer to bob failed");

        vm.deal(ALICE, 0);
        vm.deal(BOB, 0);
        vm.deal(REWARDER, 100 ether);
    }

    function testStakeMintsSharesAndTransfers() public {
        uint256 stakeAmount = 250 ether;
        _stake(ALICE, stakeAmount);

        assertEq(stimmy.balanceOf(ALICE), stakeAmount, "shares not minted 1:1");
        assertEq(grimmy.balanceOf(address(stimmy)), stakeAmount, "staking token not transferred");
        assertEq(grimmy.balanceOf(ALICE), ALICE_STAKE - stakeAmount, "staker token balance incorrect");
    }

    function testRewardAccrualSingleStaker() public {
        uint256 stakeAmount = 500 ether;
        _stake(ALICE, stakeAmount);

        uint256 rewardAmount = 5 ether;
        _sendReward(rewardAmount);

        assertEq(stimmy.pendingRewards(ALICE), rewardAmount, "pending reward should match deposit");

        vm.prank(ALICE);
        stimmy.claimRewards(ALICE);

        assertEq(ALICE.balance, rewardAmount, "staker did not receive rewards");
        assertEq(stimmy.pendingRewards(ALICE), 0, "pending rewards not cleared");
        assertEq(address(stimmy).balance, 0, "contract should not retain rewards");
    }

    function testRewardsSplitProRata() public {
        uint256 aliceStake = 100 ether;
        uint256 bobStake = 300 ether;

        _stake(ALICE, aliceStake);
        _stake(BOB, bobStake);

        uint256 rewardAmount = 4 ether;
        _sendReward(rewardAmount);

        uint256 expectedAlice = rewardAmount * aliceStake / (aliceStake + bobStake);
        uint256 expectedBob = rewardAmount - expectedAlice;

        vm.prank(ALICE);
        stimmy.claimRewards(ALICE);
        vm.prank(BOB);
        stimmy.claimRewards(BOB);

        assertEq(ALICE.balance, expectedAlice, "alice reward incorrect");
        assertEq(BOB.balance, expectedBob, "bob reward incorrect");
    }

    function testUnstakeRequiresDelay() public {
        _stake(ALICE, ALICE_STAKE);

        vm.prank(ALICE);
        stimmy.requestUnstake(ALICE_STAKE);

        assertEq(stimmy.balanceOf(ALICE), 0, "shares should burn on request");

        vm.expectRevert(bytes("not claimable yet"));
        vm.prank(ALICE);
        stimmy.withdrawUnstaked();

        vm.warp(block.timestamp + stimmy.UNSTAKE_DELAY());
        vm.prank(ALICE);
        stimmy.withdrawUnstaked();

        assertEq(grimmy.balanceOf(ALICE), ALICE_STAKE, "principal not returned");
        assertEq(grimmy.balanceOf(address(stimmy)), 0, "staking contract should release tokens");
    }

    function testMultipleStakesAccumulateRewards() public {
        uint256 firstStake = 200 ether;
        uint256 secondStake = 300 ether;
        uint256 rewardAmount = 2 ether;

        _stake(ALICE, firstStake);
        _sendReward(rewardAmount);

        assertEq(stimmy.pendingRewards(ALICE), rewardAmount, "initial reward mismatch");

        _stake(ALICE, secondStake);

        assertEq(stimmy.balanceOf(ALICE), firstStake + secondStake, "share balance incorrect after second stake");
        assertEq(stimmy.pendingRewards(ALICE), rewardAmount, "restaking should not forfeit accrued rewards");

        vm.prank(ALICE);
        stimmy.claimRewards(ALICE);

        assertEq(ALICE.balance, rewardAmount, "accrued rewards not paid out");
        assertEq(stimmy.pendingRewards(ALICE), 0, "pending should reset after claim");
    }

    function testStakeAfterRewardsKeepsLateStakerClean() public {
        uint256 aliceStake = 150 ether;
        uint256 bobStake = 350 ether;
        uint256 initialReward = 1 ether;
        uint256 secondReward = 3 ether;

        _stake(ALICE, aliceStake);
        _sendReward(initialReward);

        _stake(BOB, bobStake);

        assertApproxEqAbs(stimmy.pendingRewards(ALICE), initialReward, 100, "early staker should keep initial reward");
        assertEq(stimmy.pendingRewards(BOB), 0, "late staker should not get past rewards");

        _sendReward(secondReward);

        uint256 totalStake = aliceStake + bobStake;
        uint256 aliceSecondShare = (secondReward * aliceStake) / totalStake;
        uint256 bobSecondShare = secondReward - aliceSecondShare;

        assertApproxEqAbs(
            stimmy.pendingRewards(ALICE),
            initialReward + aliceSecondShare,
            100,
            "alice pending rewards incorrect after second deposit"
        );
        assertApproxEqAbs(
            stimmy.pendingRewards(BOB), bobSecondShare, 100, "bob pending rewards incorrect after second deposit"
        );

        vm.prank(ALICE);
        stimmy.claimRewards(ALICE);
        vm.prank(BOB);
        stimmy.claimRewards(BOB);

        assertApproxEqAbs(ALICE.balance, initialReward + aliceSecondShare, 100, "alice payout incorrect");
        assertApproxEqAbs(BOB.balance, bobSecondShare, 100, "bob payout incorrect");
    }

    function testRewardIncreaseDistributesAdditionalShares() public {
        uint256 aliceStake = 200 ether;
        uint256 bobStake = 200 ether;
        _stake(ALICE, aliceStake);
        _stake(BOB, bobStake);

        uint256 totalStake = aliceStake + bobStake;
        uint256 firstReward = 8 ether;
        _sendReward(firstReward);

        uint256 expectedRpsAfterFirst = (firstReward * 1 ether) / totalStake;
        assertEq(
            stimmy.rewardPerShareStored(), expectedRpsAfterFirst, "rewardPerShare should increase after first reward"
        );

        uint256 expectedShare = firstReward / 2;
        assertApproxEqAbs(stimmy.pendingRewards(ALICE), expectedShare, 1, "alice first reward pending mismatch");
        assertApproxEqAbs(stimmy.pendingRewards(BOB), expectedShare, 1, "bob first reward pending mismatch");

        uint256 secondReward = 2 ether;
        _sendReward(secondReward);

        uint256 expectedRpsAfterSecond = ((firstReward + secondReward) * 1 ether) / totalStake;
        assertEq(
            stimmy.rewardPerShareStored(), expectedRpsAfterSecond, "rewardPerShare should reflect cumulative rewards"
        );

        uint256 totalExpected = (firstReward + secondReward) / 2;
        assertApproxEqAbs(stimmy.pendingRewards(ALICE), totalExpected, 1, "alice total pending mismatch");
        assertApproxEqAbs(stimmy.pendingRewards(BOB), totalExpected, 1, "bob total pending mismatch");

        vm.prank(ALICE);
        stimmy.claimRewards(ALICE);
        vm.prank(BOB);
        stimmy.claimRewards(BOB);

        assertApproxEqAbs(ALICE.balance, totalExpected, 1, "alice payout mismatch");
        assertApproxEqAbs(BOB.balance, totalExpected, 1, "bob payout mismatch");
        assertEq(address(stimmy).balance, 0, "contract should not retain rewards");
    }

    function testShareTransferBetweenExternallyOwnedAccountsReverts() public {
        _stake(ALICE, 500 ether);

        vm.prank(ALICE);
        vm.expectRevert(Stimmy.TransferNotAllowed.selector);
        stimmy.transfer(BOB, 200 ether);
    }

    function testTransferFromRevertsEvenWithAllowance() public {
        _stake(ALICE, 100 ether);

        vm.prank(ALICE);
        stimmy.approve(BOB, 50 ether);

        vm.prank(BOB);
        vm.expectRevert(Stimmy.TransferNotAllowed.selector);
        stimmy.transferFrom(ALICE, BOB, 10 ether);
    }

    function testUnstakeMultipleRequestsPartialWithdrawOnlyMatured() public {
        uint256 stakeAmount = 1_000 ether;
        _stake(ALICE, stakeAmount);

        // Two separate unstake requests at different times
        vm.startPrank(ALICE);
        stimmy.requestUnstake(300 ether);
        uint256 t1 = vm.getBlockTimestamp();
        // STIMMY burned immediately for requested amount
        assertEq(stimmy.balanceOf(ALICE), stakeAmount - 300 ether, "first request should burn shares");

        vm.warp(t1 + 1 hours);
        stimmy.requestUnstake(200 ether);
        // Shares burned again on second request
        assertEq(stimmy.balanceOf(ALICE), stakeAmount - 300 ether - 200 ether, "second request should burn shares");
        vm.stopPrank();

        uint256 beforeAliceGrimmy = grimmy.balanceOf(ALICE);
        uint256 beforeContractGrimmy = grimmy.balanceOf(address(stimmy));

        // Warp so only the first withdrawal is matured
        vm.warp(t1 + stimmy.UNSTAKE_DELAY());
        vm.prank(ALICE);
        stimmy.withdrawUnstaked();

        // Only first 300 ETH should be withdrawn
        assertEq(
            grimmy.balanceOf(ALICE),
            beforeAliceGrimmy + 300 ether,
            "alice GRIMMY after first matured withdraw incorrect"
        );
        assertEq(
            grimmy.balanceOf(address(stimmy)),
            beforeContractGrimmy - 300 ether,
            "contract GRIMMY after first matured withdraw incorrect"
        );

        // With only the second request pending and not yet matured, withdraw should revert
        vm.expectRevert(bytes("not claimable yet"));
        vm.prank(ALICE);
        stimmy.withdrawUnstaked();

        // Warp until second request matures and withdraw remaining 200 ETH
        vm.warp(t1 + 1 hours + stimmy.UNSTAKE_DELAY());
        beforeAliceGrimmy = grimmy.balanceOf(ALICE);
        beforeContractGrimmy = grimmy.balanceOf(address(stimmy));
        vm.prank(ALICE);
        stimmy.withdrawUnstaked();

        assertEq(
            grimmy.balanceOf(ALICE),
            beforeAliceGrimmy + 200 ether,
            "alice GRIMMY after second matured withdraw incorrect"
        );
        assertEq(
            grimmy.balanceOf(address(stimmy)),
            beforeContractGrimmy - 200 ether,
            "contract GRIMMY after second matured withdraw incorrect"
        );
    }

    function testWithdrawWithoutRequestsReverts() public {
        vm.expectRevert(bytes("nothing pending"));
        vm.prank(ALICE);
        stimmy.withdrawUnstaked();
    }

    function _stake(address staker, uint256 amount) internal {
        vm.startPrank(staker);
        grimmy.approve(address(stimmy), amount);
        stimmy.stake(amount);
        vm.stopPrank();
    }

    function _sendReward(uint256 amount) internal {
        vm.prank(REWARDER);
        (bool success,) = address(stimmy).call{value: amount}("");
        assertTrue(success, "reward deposit failed");
    }
}
