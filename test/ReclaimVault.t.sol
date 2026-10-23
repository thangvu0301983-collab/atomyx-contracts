// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {ReclaimVault} from "../src/ReclaimVault.sol";

contract Reenterer {
    ReclaimVault public vault;

    function set(ReclaimVault v) external {
        vault = v;
    }

    receive() external payable {
        if (address(vault) != address(0)) vault.distribute(); // re-entry must hit the guard
    }
}

contract ReclaimVaultTest is Test {
    ReclaimVault vault;
    address guardian = makeAddr("atmx-guardian");
    address attester = makeAddr("atmx-attester");
    address treasury = makeAddr("atmx-treasury");
    address collector = makeAddr("atmx-collector");
    uint256 constant RATE = 0.0002 ether; // per kg

    bytes32 constant BATCH = keccak256("batch-0001");
    bytes32 constant EVIDENCE = keccak256("three checkpoint weighing");

    function setUp() public {
        vm.warp(1_800_000_000);
        vault = new ReclaimVault(guardian, attester, treasury, RATE);
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok);
    }

    function _record(bytes32 id, uint128 grams) internal {
        vm.prank(attester);
        vault.recordBatch(id, 0, grams, EVIDENCE);
    }

    function test_split80_20() public {
        _fund(1 ether);
        vault.distribute();
        assertEq(treasury.balance, 0.8 ether, "project treasury");
        assertEq(vault.rewardsPool(), 0.2 ether, "rewards kept");
        assertEq(address(vault).balance, 0.2 ether);
        assertEq(vault.pending(), 0);
        assertEq(vault.totalDistributed(), 1 ether);
    }

    function test_anyoneCanDistribute_repeatedSafely() public {
        _fund(1 ether);
        vm.prank(collector);
        vault.distribute();
        vm.prank(collector);
        vault.distribute(); // nothing pending: no-op
        assertEq(vault.rewardsPool(), 0.2 ether);
        _fund(1 ether);
        vault.distribute();
        assertEq(vault.rewardsPool(), 0.4 ether);
        assertEq(treasury.balance, 1.6 ether);
    }

    function test_recordBatchRules() public {
        vm.expectRevert(ReclaimVault.NotAttester.selector);
        vault.recordBatch(BATCH, 0, 1000, EVIDENCE);
        vm.startPrank(attester);
        vm.expectRevert(ReclaimVault.BadBatch.selector);
        vault.recordBatch(bytes32(0), 0, 1000, EVIDENCE);
        vm.expectRevert(ReclaimVault.BadBatch.selector);
        vault.recordBatch(BATCH, 0, 0, EVIDENCE);
        vm.expectRevert(ReclaimVault.BadBatch.selector);
        vault.recordBatch(BATCH, 0, 1000, bytes32(0));
        vm.expectRevert(ReclaimVault.BadMaterial.selector);
        vault.recordBatch(BATCH, 8, 1000, EVIDENCE);
        vault.recordBatch(BATCH, 7, 250_000, EVIDENCE);
        vm.expectRevert(ReclaimVault.BatchExists.selector);
        vault.recordBatch(BATCH, 7, 1, EVIDENCE);
        vm.stopPrank();
        (uint128 grams,, uint64 at, uint8 material, bool voided, bytes32 ev) = vault.batches(BATCH);
        assertEq(grams, 250_000);
        assertEq(at, block.timestamp);
        assertEq(material, 7);
        assertFalse(voided);
        assertEq(ev, EVIDENCE);
        assertEq(vault.totalGramsRecorded(), 250_000);
        assertEq(vault.batchCount(), 1);
    }

    function test_rewardOnlyAfterReviewWithinWeightCap() public {
        _fund(10 ether);
        vault.distribute(); // 2 ETH in the rewards pool
        _record(BATCH, 500_000); // 500 kg -> cap 0.1 ETH at 0.0002 ETH/kg
        assertEq(vault.batchCap(BATCH), 0.1 ether);
        vm.startPrank(guardian);
        vm.expectRevert(ReclaimVault.InReview.selector);
        vault.payReward(BATCH, collector, 0.05 ether);
        vm.warp(block.timestamp + 24 hours);
        vault.payReward(BATCH, collector, 0.06 ether);
        vm.expectRevert(ReclaimVault.OverBatchCap.selector);
        vault.payReward(BATCH, collector, 0.04 ether + 1);
        vault.payReward(BATCH, collector, 0.04 ether);
        vm.stopPrank();
        assertEq(collector.balance, 0.1 ether);
        assertEq(vault.rewardsPool(), 1.9 ether);
        assertEq(vault.totalRewardsPaid(), 0.1 ether);
        (, uint128 paid,,,,) = vault.batches(BATCH);
        assertEq(paid, 0.1 ether);
    }

    function test_rewardNeverExceedsPool() public {
        _fund(0.01 ether);
        vault.distribute(); // 0.002 ETH in the pool
        _record(BATCH, 1_000_000); // cap 0.2 ETH
        vm.warp(block.timestamp + 24 hours);
        vm.prank(guardian);
        vm.expectRevert(ReclaimVault.RewardTooLarge.selector);
        vault.payReward(BATCH, collector, 0.003 ether);
    }

    function test_onlyGuardianPays_unknownAndVoidedBatchesRejected() public {
        _fund(1 ether);
        vault.distribute();
        _record(BATCH, 100_000);
        vm.warp(block.timestamp + 24 hours);
        vm.prank(attester);
        vm.expectRevert(ReclaimVault.NotGuardian.selector);
        vault.payReward(BATCH, collector, 1);
        vm.startPrank(guardian);
        vm.expectRevert(ReclaimVault.UnknownBatch.selector);
        vault.payReward(keccak256("nope"), collector, 1);
        vm.expectRevert(ReclaimVault.ZeroAddress.selector);
        vault.payReward(BATCH, address(0), 1);
        vault.voidBatch(BATCH, keccak256("weights differ by more than 5%"));
        vm.expectRevert(ReclaimVault.BatchIsVoided.selector);
        vault.payReward(BATCH, collector, 1);
        vm.expectRevert(ReclaimVault.BatchIsVoided.selector);
        vault.voidBatch(BATCH, bytes32(0));
        vm.stopPrank();
        assertEq(vault.totalGramsVoided(), 100_000);
    }

    function test_cannotVoidAfterPayment() public {
        _fund(1 ether);
        vault.distribute();
        _record(BATCH, 100_000);
        vm.warp(block.timestamp + 24 hours);
        vm.startPrank(guardian);
        vault.payReward(BATCH, collector, 0.001 ether);
        vm.expectRevert(ReclaimVault.BatchAlreadyPaid.selector);
        vault.voidBatch(BATCH, bytes32(0));
        vm.stopPrank();
    }

    function test_rewardsPoolCannotLeaveAnyOtherWay() public {
        _fund(2 ether);
        vault.distribute();
        uint256 pool = vault.rewardsPool();
        // distribute never touches the pool, and nothing else sends ETH
        vault.distribute();
        assertEq(address(vault).balance, pool);
        assertEq(vault.pending(), 0);
    }

    function test_rateCapTimelockAndHardMax() public {
        vm.expectRevert(ReclaimVault.BadRate.selector);
        new ReclaimVault(guardian, attester, treasury, 0);
        vm.expectRevert(ReclaimVault.BadRate.selector);
        new ReclaimVault(guardian, attester, treasury, 0.001 ether + 1);
        vm.startPrank(guardian);
        vm.expectRevert(ReclaimVault.BadRate.selector);
        vault.proposeRate(0.002 ether);
        vault.proposeRate(0.001 ether);
        vm.expectRevert(ReclaimVault.TooEarly.selector);
        vault.executeRate();
        vm.warp(block.timestamp + 48 hours);
        vault.executeRate();
        vm.stopPrank();
        assertEq(vault.maxWeiPerKg(), 0.001 ether);
    }

    function test_treasuryTimelock_oldFeesToOldTreasury() public {
        address next = makeAddr("atmx-new-treasury");
        vm.prank(guardian);
        vm.expectRevert(ReclaimVault.ZeroAddress.selector);
        vault.proposeTreasury(address(0));
        vm.prank(guardian);
        vault.proposeTreasury(next);
        _fund(1 ether); // earned before the change
        vm.prank(guardian);
        vm.expectRevert(ReclaimVault.TooEarly.selector);
        vault.executeTreasury();
        vm.warp(block.timestamp + 48 hours);
        vm.prank(guardian);
        vault.executeTreasury();
        assertEq(treasury.balance, 0.8 ether, "old treasury got the old fees");
        assertEq(vault.treasury(), next);
        _fund(1 ether);
        vault.distribute();
        assertEq(next.balance, 0.8 ether, "new fees go to the new treasury");
    }

    function test_attesterAndGuardianTimelocked() public {
        address nextAttester = makeAddr("atmx-next-attester");
        address dao = makeAddr("atmx-dao");
        vm.startPrank(guardian);
        vault.proposeAttester(nextAttester);
        vault.proposeGuardian(dao);
        vm.expectRevert(ReclaimVault.TooEarly.selector);
        vault.executeAttester();
        vm.expectRevert(ReclaimVault.TooEarly.selector);
        vault.executeGuardian();
        vault.cancelProposal(1);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(ReclaimVault.NothingPending.selector);
        vault.executeAttester();
        vault.executeGuardian();
        vm.stopPrank();
        assertEq(vault.attester(), attester);
        assertEq(vault.guardian(), dao);
        vm.prank(guardian);
        vm.expectRevert(ReclaimVault.NotGuardian.selector);
        vault.proposeRate(1);
    }

    function test_reentrantRecipientCannotDoubleDistribute() public {
        Reenterer r = new Reenterer();
        ReclaimVault v = new ReclaimVault(guardian, attester, address(r), RATE);
        r.set(v);
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(v).call{value: 1 ether}("");
        assertTrue(ok);
        vm.expectRevert(ReclaimVault.TransferFailed.selector);
        v.distribute();
    }

    function test_zeroAddressesRejected() public {
        vm.expectRevert(ReclaimVault.ZeroAddress.selector);
        new ReclaimVault(address(0), attester, treasury, RATE);
        vm.expectRevert(ReclaimVault.ZeroAddress.selector);
        new ReclaimVault(guardian, address(0), treasury, RATE);
        vm.expectRevert(ReclaimVault.ZeroAddress.selector);
        new ReclaimVault(guardian, attester, address(0), RATE);
    }

    function testFuzz_splitAlwaysAddsUp(uint96 amount) public {
        vm.assume(amount > 0);
        _fund(amount);
        vault.distribute();
        assertEq(treasury.balance + vault.rewardsPool(), amount);
        assertEq(address(vault).balance, vault.rewardsPool());
    }

    function testFuzz_batchPaymentsNeverExceedCap(uint128 grams, uint96 a, uint96 b) public {
        grams = uint128(bound(grams, 1, 1_000_000_000)); // up to 1,000 t
        _fund(1_000 ether);
        vault.distribute();
        _record(BATCH, grams);
        vm.warp(block.timestamp + 24 hours);
        uint256 cap = vault.batchCap(BATCH);
        vm.startPrank(guardian);
        uint256 first = bound(a, 0, cap);
        vault.payReward(BATCH, collector, first);
        uint256 second = uint256(b);
        if (first + second > cap) vm.expectRevert(ReclaimVault.OverBatchCap.selector);
        vault.payReward(BATCH, collector, second);
        vm.stopPrank();
        (, uint128 paid,,,,) = vault.batches(BATCH);
        assertLe(paid, cap);
    }
}
