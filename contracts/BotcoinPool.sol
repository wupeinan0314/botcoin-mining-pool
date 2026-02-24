// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title BotcoinPool
 * @notice Combined mining pool for BOTCOIN on Base.
 *         Users deposit BOTCOIN to collectively reach mining tiers.
 *         An operator runs inference, submits receipts, and claims rewards
 *         which are distributed pro-rata to depositors.
 *
 * @dev Implements EIP-1271 so the pool contract address can authenticate
 *      with the BOTCOIN coordinator as a "miner". The operator EOA signs
 *      challenge nonces; the coordinator calls isValidSignature on this
 *      contract to verify.
 *
 *      Credit tiers (determined by pool BOTCOIN balance):
 *        >= 25,000,000  → 1 credit per solve
 *        >= 50,000,000  → 2 credits per solve
 *        >= 100,000,000 → 3 credits per solve
 */

interface IMiningContract {
    function currentEpoch() external view returns (uint64);
    function genesisTimestamp() external view returns (uint64);
}

contract BotcoinPool is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    bytes4 private constant EIP1271_MAGIC = 0x1626ba7e;
    bytes4 private constant EIP1271_INVALID = 0xffffffff;
    uint256 public constant MAX_FEE_BPS = 2000; // 20% max operator fee
    uint256 public constant TIER_1 = 25_000_000 * 1e18;
    uint256 public constant TIER_2 = 50_000_000 * 1e18;
    uint256 public constant TIER_3 = 100_000_000 * 1e18;

    // ============ Immutables ============

    IERC20 public immutable botcoin;
    IMiningContract public immutable miningContract;

    // ============ State ============

    address public operator;
    address public pendingOperator;
    uint256 public operatorFeeBps;

    // Depositor tracking
    struct DepositorInfo {
        uint256 amount;
        uint64  lockEpoch;      // epoch at which deposit becomes active & locked
        uint256 index;          // index in depositorList (for O(1) removal)
        bool    active;
    }
    mapping(address => DepositorInfo) public depositors;
    address[] public depositorList;
    uint256 public totalDeposits;       // total locked deposits (active in mining)
    uint256 public totalPending;        // deposits waiting for next epoch

    // Pending deposits (applied at epoch boundary)
    struct PendingDeposit {
        address user;
        uint256 amount;
        uint64  targetEpoch;    // becomes active at this epoch
    }
    PendingDeposit[] public pendingDeposits;

    // Pending withdrawals
    struct PendingWithdrawal {
        address user;
        uint256 amount;
        uint64  availableEpoch; // can withdraw after this epoch
    }
    PendingWithdrawal[] public pendingWithdrawals;
    mapping(address => uint256) public pendingWithdrawAmount;

    // Rewards
    mapping(address => uint256) public unclaimedRewards;
    uint256 public totalUnclaimedRewards;

    // Epoch tracking
    uint64 public lastProcessedEpoch;

    // Cumulative stats
    uint256 public totalRewardsEarned;
    uint256 public totalReceiptsSubmitted;

    // ============ Events ============

    event Deposited(address indexed user, uint256 amount, uint64 lockEpoch);
    event WithdrawalRequested(address indexed user, uint256 amount, uint64 availableEpoch);
    event WithdrawalCompleted(address indexed user, uint256 amount);
    event ReceiptSubmitted(uint256 indexed receiptNumber);
    event RewardsClaimed(uint64[] epochIds, uint256 totalReward, uint256 operatorFee);
    event RewardsDistributed(uint256 totalReward, uint256 operatorFee, uint256 depositorCount);
    event UserRewardClaimed(address indexed user, uint256 amount);
    event OperatorTransferStarted(address indexed current, address indexed pending);
    event OperatorTransferred(address indexed previous, address indexed current);
    event OperatorFeeChanged(uint256 oldFee, uint256 newFee);
    event EpochProcessed(uint64 epoch);

    // ============ Errors ============

    error NotOperator();
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientDeposit();
    error NoRewards();
    error FeeTooHigh();
    error NotPendingOperator();
    error MiningCallFailed();
    error ClaimFailed();
    error InvalidSignatureLength();
    error WithdrawalNotReady();
    error NoPendingWithdrawal();

    // ============ Modifiers ============

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    // ============ Constructor ============

    constructor(
        address _botcoin,
        address _miningContract,
        address _operator,
        uint256 _feeBps
    ) {
        if (_botcoin == address(0)) revert ZeroAddress();
        if (_miningContract == address(0)) revert ZeroAddress();
        if (_operator == address(0)) revert ZeroAddress();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();

        botcoin = IERC20(_botcoin);
        miningContract = IMiningContract(_miningContract);
        operator = _operator;
        operatorFeeBps = _feeBps;
    }

    // ============ EIP-1271 ============

    /**
     * @notice EIP-1271 signature validation.
     * @dev The coordinator calls this with:
     *      hash = ethers.hashMessage(nonceMessage)  (EIP-191 personal_sign digest)
     *      signature = operator's 65-byte ECDSA signature
     *      We ecrecover and check against the stored operator address.
     */
    function isValidSignature(bytes32 hash, bytes memory signature)
        external view returns (bytes4)
    {
        if (signature.length != 65) revert InvalidSignatureLength();

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        if (v < 27) v += 27;

        address recovered = ecrecover(hash, v, r, s);
        if (recovered != address(0) && recovered == operator) {
            return EIP1271_MAGIC;
        }
        return EIP1271_INVALID;
    }

    // ============ Epoch Helpers ============

    /**
     * @notice Get the current epoch from the mining contract.
     */
    function getCurrentEpoch() public view returns (uint64) {
        return miningContract.currentEpoch();
    }

    /**
     * @notice Process epoch transitions — activate pending deposits,
     *         release pending withdrawals. Anyone can call this.
     */
    function processEpoch() public {
        uint64 epoch = getCurrentEpoch();
        if (epoch <= lastProcessedEpoch) return;

        // Activate pending deposits
        uint256 i = 0;
        while (i < pendingDeposits.length) {
            PendingDeposit storage pd = pendingDeposits[i];
            if (pd.targetEpoch <= epoch) {
                // Activate this deposit
                totalDeposits += pd.amount;
                totalPending -= pd.amount;

                // Swap and pop
                pendingDeposits[i] = pendingDeposits[pendingDeposits.length - 1];
                pendingDeposits.pop();
                // Don't increment i — check swapped element
            } else {
                i++;
            }
        }

        lastProcessedEpoch = epoch;
        emit EpochProcessed(epoch);
    }

    // ============ Deposits ============

    /**
     * @notice Deposit BOTCOIN into the pool.
     *         Deposit is locked starting next epoch.
     * @param amount Amount of BOTCOIN to deposit (18 decimals).
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        processEpoch();

        botcoin.safeTransferFrom(msg.sender, address(this), amount);

        uint64 epoch = getCurrentEpoch();
        uint64 lockEpoch = epoch + 1;

        DepositorInfo storage info = depositors[msg.sender];
        if (!info.active) {
            info.index = depositorList.length;
            info.active = true;
            depositorList.push(msg.sender);
        }
        info.amount += amount;
        info.lockEpoch = lockEpoch;

        // Queue as pending — becomes active next epoch
        pendingDeposits.push(PendingDeposit({
            user: msg.sender,
            amount: amount,
            targetEpoch: lockEpoch
        }));
        totalPending += amount;

        emit Deposited(msg.sender, amount, lockEpoch);
    }

    /**
     * @notice Request withdrawal. Funds become available after current epoch ends.
     *         This immediately removes the deposit from the active mining balance.
     * @param amount Amount to withdraw.
     */
    function requestWithdrawal(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        DepositorInfo storage info = depositors[msg.sender];
        if (info.amount < amount) revert InsufficientDeposit();

        processEpoch();

        uint64 epoch = getCurrentEpoch();
        uint64 availableEpoch = epoch + 1;

        info.amount -= amount;
        
        // Check if any of this was still pending (not yet locked)
        uint256 pendingRemoved = _removePendingDeposit(msg.sender, amount);
        uint256 lockedRemoved = amount - pendingRemoved;
        
        if (pendingRemoved > 0) totalPending -= pendingRemoved;
        if (lockedRemoved > 0) totalDeposits -= lockedRemoved;

        if (info.amount == 0) {
            _removeDepositor(msg.sender);
        }

        pendingWithdrawals.push(PendingWithdrawal({
            user: msg.sender,
            amount: amount,
            availableEpoch: availableEpoch
        }));
        pendingWithdrawAmount[msg.sender] += amount;

        emit WithdrawalRequested(msg.sender, amount, availableEpoch);
    }

    /**
     * @notice Complete pending withdrawals that are past their lock period.
     */
    function completeWithdrawal() external nonReentrant {
        uint64 epoch = getCurrentEpoch();
        uint256 totalToSend = 0;

        uint256 i = 0;
        while (i < pendingWithdrawals.length) {
            PendingWithdrawal storage pw = pendingWithdrawals[i];
            if (pw.user == msg.sender && pw.availableEpoch <= epoch) {
                totalToSend += pw.amount;
                pendingWithdrawAmount[msg.sender] -= pw.amount;
                // Swap and pop
                pendingWithdrawals[i] = pendingWithdrawals[pendingWithdrawals.length - 1];
                pendingWithdrawals.pop();
            } else {
                i++;
            }
        }

        if (totalToSend == 0) revert NoPendingWithdrawal();
        botcoin.safeTransfer(msg.sender, totalToSend);
        emit WithdrawalCompleted(msg.sender, totalToSend);
    }

    /**
     * @notice Emergency withdraw — skip epoch lock, but forfeit any
     *         unclaimed rewards for this epoch. Always available even when paused.
     */
    function emergencyWithdraw() external nonReentrant {
        DepositorInfo storage info = depositors[msg.sender];
        uint256 depositAmt = info.amount;
        uint256 pendingAmt = pendingWithdrawAmount[msg.sender];
        uint256 rewardAmt = unclaimedRewards[msg.sender];
        uint256 total = depositAmt + pendingAmt + rewardAmt;
        if (total == 0) revert ZeroAmount();

        // Clear deposit
        if (depositAmt > 0) {
            uint256 pendingRemoved = _removePendingDeposit(msg.sender, depositAmt);
            if (pendingRemoved > 0) totalPending -= pendingRemoved;
            totalDeposits -= (depositAmt - pendingRemoved);
            info.amount = 0;
            _removeDepositor(msg.sender);
        }

        // Clear pending withdrawals
        if (pendingAmt > 0) {
            _clearPendingWithdrawals(msg.sender);
        }

        // Clear rewards
        if (rewardAmt > 0) {
            unclaimedRewards[msg.sender] = 0;
            totalUnclaimedRewards -= rewardAmt;
        }

        botcoin.safeTransfer(msg.sender, total);
        emit WithdrawalCompleted(msg.sender, total);
    }

    // ============ Mining Operations (Operator Only) ============

    /**
     * @notice Forward a signed receipt to the mining contract.
     * @dev The coordinator returns calldata that should be forwarded as-is.
     *      msg.sender of the mining contract call will be this pool contract.
     */
    function submitReceiptToMining(bytes calldata data) external onlyOperator whenNotPaused {
        (bool success, ) = address(miningContract).call(data);
        if (!success) revert MiningCallFailed();
        totalReceiptsSubmitted++;
        emit ReceiptSubmitted(totalReceiptsSubmitted);
    }

    /**
     * @notice Claim mining rewards for given epochs and distribute to depositors.
     *         Uses uint64[] to match the mining contract's claim(uint64[]) signature.
     *         Anyone can call this — rewards go to depositors, not the caller.
     * @param epochIds Array of epoch IDs to claim.
     */
    function claimRewards(uint64[] calldata epochIds) external nonReentrant {
        processEpoch();

        uint256 balBefore = botcoin.balanceOf(address(this));

        // Mining contract uses claim(uint64[]) — selector 0x35442c43
        (bool success, ) = address(miningContract).call(
            abi.encodeWithSelector(0x35442c43, epochIds)
        );
        if (!success) revert ClaimFailed();

        uint256 balAfter = botcoin.balanceOf(address(this));
        uint256 totalReward = balAfter - balBefore;

        uint256 opFee = 0;
        if (totalReward > 0) {
            opFee = _distributeRewards(totalReward);
        }

        emit RewardsClaimed(epochIds, totalReward, opFee);
    }

    // ============ Reward Distribution ============

    function _distributeRewards(uint256 totalReward) internal returns (uint256 opFee) {
        opFee = (totalReward * operatorFeeBps) / 10000;
        uint256 depositorReward = totalReward - opFee;

        totalRewardsEarned += totalReward;

        // Send operator fee
        if (opFee > 0) {
            botcoin.safeTransfer(operator, opFee);
        }

        // Distribute pro-rata to active depositors
        if (totalDeposits > 0 && depositorReward > 0) {
            uint256 len = depositorList.length;
            for (uint256 i = 0; i < len; i++) {
                address user = depositorList[i];
                uint256 userDeposit = depositors[user].amount;
                if (userDeposit > 0) {
                    uint256 userReward = (depositorReward * userDeposit) / totalDeposits;
                    unclaimedRewards[user] += userReward;
                    totalUnclaimedRewards += userReward;
                }
            }
        }

        emit RewardsDistributed(totalReward, opFee, depositorList.length);
    }

    /**
     * @notice Claim accumulated rewards as a depositor. Anyone can call.
     */
    function claimUserRewards() external nonReentrant {
        uint256 amount = unclaimedRewards[msg.sender];
        if (amount == 0) revert NoRewards();

        unclaimedRewards[msg.sender] = 0;
        totalUnclaimedRewards -= amount;

        botcoin.safeTransfer(msg.sender, amount);
        emit UserRewardClaimed(msg.sender, amount);
    }

    // ============ Admin ============

    function setOperatorFee(uint256 newFeeBps) external onlyOperator {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        emit OperatorFeeChanged(operatorFeeBps, newFeeBps);
        operatorFeeBps = newFeeBps;
    }

    function transferOperator(address newOperator) external onlyOperator {
        if (newOperator == address(0)) revert ZeroAddress();
        pendingOperator = newOperator;
        emit OperatorTransferStarted(operator, newOperator);
    }

    function acceptOperator() external {
        if (msg.sender != pendingOperator) revert NotPendingOperator();
        emit OperatorTransferred(operator, msg.sender);
        operator = msg.sender;
        pendingOperator = address(0);
    }

    /// @notice Operator can pause deposits and mining in emergencies.
    function pause() external onlyOperator { _pause(); }

    /// @notice Operator can unpause.
    function unpause() external onlyOperator { _unpause(); }

    // ============ Internal ============

    function _removeDepositor(address user) internal {
        DepositorInfo storage info = depositors[user];
        if (!info.active) return;

        uint256 lastIdx = depositorList.length - 1;
        if (info.index != lastIdx) {
            address lastUser = depositorList[lastIdx];
            depositorList[info.index] = lastUser;
            depositors[lastUser].index = info.index;
        }
        depositorList.pop();
        info.active = false;
        info.index = 0;
    }

    function _removePendingDeposit(address user, uint256 amount) internal returns (uint256 removed) {
        uint256 remaining = amount;
        uint256 i = 0;
        while (i < pendingDeposits.length && remaining > 0) {
            PendingDeposit storage pd = pendingDeposits[i];
            if (pd.user == user) {
                if (pd.amount <= remaining) {
                    remaining -= pd.amount;
                    removed += pd.amount;
                    pendingDeposits[i] = pendingDeposits[pendingDeposits.length - 1];
                    pendingDeposits.pop();
                } else {
                    pd.amount -= remaining;
                    removed += remaining;
                    remaining = 0;
                    i++;
                }
            } else {
                i++;
            }
        }
    }

    function _clearPendingWithdrawals(address user) internal {
        uint256 i = 0;
        while (i < pendingWithdrawals.length) {
            if (pendingWithdrawals[i].user == user) {
                pendingWithdrawAmount[user] -= pendingWithdrawals[i].amount;
                pendingWithdrawals[i] = pendingWithdrawals[pendingWithdrawals.length - 1];
                pendingWithdrawals.pop();
            } else {
                i++;
            }
        }
    }

    // ============ View ============

    function getDepositorCount() external view returns (uint256) {
        return depositorList.length;
    }

    function getPoolBalance() external view returns (uint256) {
        return botcoin.balanceOf(address(this));
    }

    function getTierLevel() external view returns (uint256) {
        uint256 bal = botcoin.balanceOf(address(this));
        if (bal >= TIER_3) return 3;
        if (bal >= TIER_2) return 2;
        if (bal >= TIER_1) return 1;
        return 0;
    }

    function getDepositorInfo(address user) external view returns (
        uint256 depositAmount,
        uint64  lockEpoch,
        uint256 pendingRewards,
        uint256 pendingWithdraw,
        bool    active
    ) {
        DepositorInfo storage info = depositors[user];
        return (info.amount, info.lockEpoch, unclaimedRewards[user], pendingWithdrawAmount[user], info.active);
    }

    function getPoolStats() external view returns (
        uint256 _totalDeposits,
        uint256 _totalPending,
        uint256 _totalRewardsEarned,
        uint256 _totalReceipts,
        uint256 _depositorCount,
        uint256 _tierLevel,
        uint64  _currentEpoch,
        uint256 _operatorFeeBps
    ) {
        uint256 bal = botcoin.balanceOf(address(this));
        uint256 tier = bal >= TIER_3 ? 3 : bal >= TIER_2 ? 2 : bal >= TIER_1 ? 1 : 0;
        return (
            totalDeposits,
            totalPending,
            totalRewardsEarned,
            totalReceiptsSubmitted,
            depositorList.length,
            tier,
            getCurrentEpoch(),
            operatorFeeBps
        );
    }

    function getPendingDepositsCount() external view returns (uint256) {
        return pendingDeposits.length;
    }

    function getPendingWithdrawalsCount() external view returns (uint256) {
        return pendingWithdrawals.length;
    }
}
