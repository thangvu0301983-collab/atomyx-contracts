// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ATOMYX Reclaim Vault and Recycling Ledger
/// @notice The immutable creator-fee recipient of the $ATMX pool, which runs Programmable's sealed
///         launch-protection hook. Anyone may call the hook fee vault's claimCreator() to push accrued creator
///         fees (ETH) here, and anyone may call distribute().
///
///         Every distribution splits the ETH waiting here in fixed shares:
///           50% Recycling Rewards pool, kept here; it can only leave as payReward() against a ledger batch
///           30% Environment fund wallet
///           20% Buyback wallet ($ATMX is bought back on the pool and burned, by hand, and announced)
///
///         The Recycling Ledger: the attester records each verified batch of waste (batch id, material, grams,
///         hash of the three-checkpoint weighing evidence). A batch can be rewarded only after a 24-hour public
///         review period, only if the guardian has not voided it, and only up to grams x maxWeiPerKg / 1000 in
///         total. maxWeiPerKg can never exceed HARD_MAX_WEI_PER_KG. The ledger records the attester's claims; it
///         does not prove physical recycling.
///
///         The guardian can change the recipients, the attester, the reward cap or itself only through a
///         48-hour public timelock. There is no other way to move ETH out of this contract.
contract ReclaimVault {
    uint16 public constant BPS = 10_000;
    uint16 public constant SHARE_REWARDS_BPS = 5_000;
    uint16 public constant SHARE_ENVIRONMENT_BPS = 3_000;
    uint16 public constant SHARE_BUYBACK_BPS = 2_000;

    uint32 public constant TIMELOCK = 48 hours;
    uint32 public constant REVIEW_PERIOD = 24 hours;
    /// @notice Hard ceiling on the reward cap: 0.001 ETH per kilogram of recorded waste.
    uint256 public constant HARD_MAX_WEI_PER_KG = 0.001 ether;
    /// @notice Materials: 0 PET, 1 HDPE, 2 PP, 3 other plastic, 4 metal, 5 paper, 6 glass, 7 e-waste.
    uint8 public constant MAX_MATERIAL = 7;

    struct Recipients {
        address environment;
        address buyback;
    }

    struct Batch {
        uint128 grams;
        uint128 paidWei;
        uint64 recordedAt;
        uint8 material;
        bool voided;
        bytes32 evidenceHash;
    }

    address public guardian;
    address public attester;
    Recipients public recipients;
    uint256 public maxWeiPerKg;

    uint256 public rewardsPool;
    uint256 public totalDistributed;
    uint256 public totalRewardsPaid;
    uint256 public totalGramsRecorded;
    uint256 public totalGramsVoided;
    uint256 public batchCount;
    mapping(bytes32 batchId => Batch) public batches;

    // ---- timelocked changes
    Recipients public pendingRecipients;
    uint64 public recipientsReadyAt;
    address public pendingAttester;
    uint64 public attesterReadyAt;
    uint256 public pendingMaxWeiPerKg;
    uint64 public rateReadyAt;
    address public pendingGuardian;
    uint64 public guardianReadyAt;

    bool private _locked;

    event Received(address indexed from, uint256 amount);
    event Distributed(uint256 toRewards, uint256 toEnvironment, uint256 toBuyback);
    event BatchRecorded(bytes32 indexed batchId, uint8 material, uint128 grams, bytes32 evidenceHash);
    event BatchVoided(bytes32 indexed batchId, bytes32 reasonHash);
    event RewardPaid(bytes32 indexed batchId, address indexed to, uint256 amount);
    event RecipientsProposed(Recipients next, uint64 readyAt);
    event RecipientsChanged(Recipients next);
    event AttesterProposed(address next, uint64 readyAt);
    event AttesterChanged(address previous, address next);
    event RateProposed(uint256 next, uint64 readyAt);
    event RateChanged(uint256 previous, uint256 next);
    event GuardianProposed(address next, uint64 readyAt);
    event GuardianChanged(address previous, address next);
    event ProposalCancelled(uint8 kind);

    error ZeroAddress();
    error NotGuardian();
    error NotAttester();
    error BadMaterial();
    error BadBatch();
    error BatchExists();
    error UnknownBatch();
    error BatchIsVoided();
    error BatchAlreadyPaid();
    error InReview();
    error OverBatchCap();
    error RewardTooLarge();
    error BadRate();
    error TooEarly();
    error NothingPending();
    error TransferFailed();
    error Reentrant();

    modifier nonReentrant() {
        if (_locked) revert Reentrant();
        _locked = true;
        _;
        _locked = false;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    constructor(address guardian_, address attester_, address environment_, address buyback_, uint256 maxWeiPerKg_) {
        if (guardian_ == address(0) || attester_ == address(0)) revert ZeroAddress();
        _checkRecipients(Recipients(environment_, buyback_));
        _checkRate(maxWeiPerKg_);
        guardian = guardian_;
        attester = attester_;
        recipients = Recipients(environment_, buyback_);
        maxWeiPerKg = maxWeiPerKg_;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    /// @notice ETH waiting to be split (everything except the Recycling Rewards pool).
    function pending() public view returns (uint256) {
        return address(this).balance - rewardsPool;
    }

    /// @notice The most a batch can ever receive in total, at the current cap.
    function batchCap(bytes32 batchId) public view returns (uint256) {
        return uint256(batches[batchId].grams) * maxWeiPerKg / 1000;
    }

    // ================================================================== permissionless
    function distribute() external nonReentrant {
        _distribute();
    }

    // ================================================================== Recycling Ledger
    /// @notice Record one verified batch: the hash commits to its public three-checkpoint weighing evidence.
    function recordBatch(bytes32 batchId, uint8 material, uint128 grams, bytes32 evidenceHash) external {
        if (msg.sender != attester) revert NotAttester();
        if (batchId == bytes32(0) || grams == 0 || evidenceHash == bytes32(0)) revert BadBatch();
        if (material > MAX_MATERIAL) revert BadMaterial();
        if (batches[batchId].recordedAt != 0) revert BatchExists();
        batches[batchId] = Batch({
            grams: grams, paidWei: 0, recordedAt: uint64(block.timestamp), material: material, voided: false,
            evidenceHash: evidenceHash
        });
        totalGramsRecorded += grams;
        batchCount += 1;
        emit BatchRecorded(batchId, material, grams, evidenceHash);
    }

    /// @notice Void a batch that failed review. Only possible before any reward was paid for it.
    function voidBatch(bytes32 batchId, bytes32 reasonHash) external onlyGuardian {
        Batch storage b = batches[batchId];
        if (b.recordedAt == 0) revert UnknownBatch();
        if (b.voided) revert BatchIsVoided();
        if (b.paidWei != 0) revert BatchAlreadyPaid();
        b.voided = true;
        totalGramsVoided += b.grams;
        emit BatchVoided(batchId, reasonHash);
    }

    /// @notice Pay a recycling reward from the Rewards pool for one reviewed batch, within its weight cap.
    function payReward(bytes32 batchId, address to, uint256 amount) external onlyGuardian nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        Batch storage b = batches[batchId];
        if (b.recordedAt == 0) revert UnknownBatch();
        if (b.voided) revert BatchIsVoided();
        if (block.timestamp < uint256(b.recordedAt) + REVIEW_PERIOD) revert InReview();
        if (uint256(b.paidWei) + amount > batchCap(batchId)) revert OverBatchCap();
        if (amount > rewardsPool) revert RewardTooLarge();
        b.paidWei += uint128(amount);
        rewardsPool -= amount;
        totalRewardsPaid += amount;
        _send(to, amount);
        emit RewardPaid(batchId, to, amount);
    }

    // ================================================================== guardian (all timelocked)
    function proposeRecipients(Recipients calldata next) external onlyGuardian {
        _checkRecipients(next);
        pendingRecipients = next;
        recipientsReadyAt = uint64(block.timestamp + TIMELOCK);
        emit RecipientsProposed(next, recipientsReadyAt);
    }

    function executeRecipients() external onlyGuardian nonReentrant {
        if (recipientsReadyAt == 0) revert NothingPending();
        if (block.timestamp < recipientsReadyAt) revert TooEarly();
        _distribute(); // fees earned under the old recipients go to them
        recipients = pendingRecipients;
        delete pendingRecipients;
        recipientsReadyAt = 0;
        emit RecipientsChanged(recipients);
    }

    function proposeAttester(address next) external onlyGuardian {
        if (next == address(0)) revert ZeroAddress();
        pendingAttester = next;
        attesterReadyAt = uint64(block.timestamp + TIMELOCK);
        emit AttesterProposed(next, attesterReadyAt);
    }

    function executeAttester() external onlyGuardian {
        if (attesterReadyAt == 0) revert NothingPending();
        if (block.timestamp < attesterReadyAt) revert TooEarly();
        emit AttesterChanged(attester, pendingAttester);
        attester = pendingAttester;
        pendingAttester = address(0);
        attesterReadyAt = 0;
    }

    function proposeRate(uint256 next) external onlyGuardian {
        _checkRate(next);
        pendingMaxWeiPerKg = next;
        rateReadyAt = uint64(block.timestamp + TIMELOCK);
        emit RateProposed(next, rateReadyAt);
    }

    function executeRate() external onlyGuardian {
        if (rateReadyAt == 0) revert NothingPending();
        if (block.timestamp < rateReadyAt) revert TooEarly();
        emit RateChanged(maxWeiPerKg, pendingMaxWeiPerKg);
        maxWeiPerKg = pendingMaxWeiPerKg;
        pendingMaxWeiPerKg = 0;
        rateReadyAt = 0;
    }

    /// @notice Hand the guardian role to a new wallet, Safe or DAO, or to address(0) to renounce, after the timelock.
    function proposeGuardian(address next) external onlyGuardian {
        pendingGuardian = next;
        guardianReadyAt = uint64(block.timestamp + TIMELOCK);
        emit GuardianProposed(next, guardianReadyAt);
    }

    function executeGuardian() external onlyGuardian {
        if (guardianReadyAt == 0) revert NothingPending();
        if (block.timestamp < guardianReadyAt) revert TooEarly();
        emit GuardianChanged(guardian, pendingGuardian);
        guardian = pendingGuardian;
        pendingGuardian = address(0);
        guardianReadyAt = 0;
    }

    /// @param kind 0 recipients, 1 attester, 2 reward cap, 3 guardian
    function cancelProposal(uint8 kind) external onlyGuardian {
        if (kind == 0) {
            delete pendingRecipients;
            recipientsReadyAt = 0;
        } else if (kind == 1) {
            pendingAttester = address(0);
            attesterReadyAt = 0;
        } else if (kind == 2) {
            pendingMaxWeiPerKg = 0;
            rateReadyAt = 0;
        } else {
            pendingGuardian = address(0);
            guardianReadyAt = 0;
        }
        emit ProposalCancelled(kind);
    }

    // ================================================================== internals
    function _distribute() internal {
        uint256 amount = pending();
        if (amount == 0) return;
        uint256 toEnvironment = amount * SHARE_ENVIRONMENT_BPS / BPS;
        uint256 toBuyback = amount * SHARE_BUYBACK_BPS / BPS;
        uint256 toRewards = amount - toEnvironment - toBuyback;
        // Book the rewards share before any ETH leaves, so pending() can never count it again.
        rewardsPool += toRewards;
        totalDistributed += amount;
        Recipients memory r = recipients;
        _send(r.environment, toEnvironment);
        _send(r.buyback, toBuyback);
        emit Distributed(toRewards, toEnvironment, toBuyback);
    }

    function _checkRecipients(Recipients memory r) private pure {
        if (r.environment == address(0) || r.buyback == address(0)) revert ZeroAddress();
    }

    function _checkRate(uint256 rate) private pure {
        if (rate == 0 || rate > HARD_MAX_WEI_PER_KG) revert BadRate();
    }

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
