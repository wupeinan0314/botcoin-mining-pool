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
    address public immutable miningContract;

    // ============ State ============

    address public operator;
    address public pendingOperator;
    uint256 public operatorFeeBps;

    // Depositor tracking
    struct DepositorInfo {
        uint256 amount;
        uint256 depositEpoch;   // epoch when last deposit was made
        uint256 index;          // index in depositorList (for O(1) removal)
        bool    active;
    }
    mapping(address => DepositorInfo) public depositors;
    address[] public depositorList;
    uint256 public totalDeposits;

    // Epoch
    uint256 public currentEpochId;

    // Rewards
    mapping(address => uint256) public unclaimedRewards;
    uint256 public totalUnclaimedRewards;

    // Cumulative stats
    uint256 public totalRewardsEarned;
    uint256 public totalReceiptsSubmitted;

    // ============ Events ============

    event Deposited(address indexed user, uint256 amount, uint256 epoch);
    event Withdrawn(address indexed user, uint256 amount);
    event ReceiptSubmitted(uint256 indexed receiptNumber);
    event RewardsClaimed(uint256[] epochIds, uint256 totalReward, uint256 operatorFee);
    event RewardsDistributed(uint256 totalReward, uint256 operatorFee, uint256 depositorCount);
    event UserRewardClaimed(address indexed user, uint256 amount);
    event OperatorTransferStarted(address indexed current, address indexed pending);
    event OperatorTransferred(address indexed previous, address indexed current);
    event OperatorFeeChanged(uint256 oldFee, uint256 newFee);
    event EpochAdvanced(uint256 oldEpoch, uint256 newEpoch);

    // ============ Errors ============

    error NotOperator();
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientDeposit();
    error NoRewards();
    error FeeTooHigh();
    error EpochNotAdvanced();
    error NotPendingOperator();
    error MiningCallFailed();
    error ClaimFailed();
    error InvalidSignatureLength();

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
        miningContract = _miningContract;
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

    // ============ Deposits ============

    /**
     * @notice Deposit BOTCOIN into the pool.
     * @param amount Amount of BOTCOIN to deposit (18 decimals).
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        botcoin.safeTransferFrom(msg.sender, address(this), amount);

        DepositorInfo storage info = depositors[msg.sender];
        if (!info.active) {
            info.index = depositorList.length;
            info.active = true;
            depositorList.push(msg.sender);
        }
        info.amount += amount;
        info.depositEpoch = currentEpochId;
        totalDeposits += amount;

        emit Deposited(msg.sender, amount, currentEpochId);
    }

    /**
     * @notice Withdraw BOTCOIN from the pool.
     * @param amount Amount to withdraw.
     */
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        DepositorInfo storage info = depositors[msg.sender];
        if (info.amount < amount) revert InsufficientDeposit();

        info.amount -= amount;
        totalDeposits -= amount;

        if (info.amount == 0) {
            _removeDepositor(msg.sender);
        }

        botcoin.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @notice Withdraw all deposit + unclaimed rewards in one call.
     */
    function withdrawAll() external nonReentrant {
        DepositorInfo storage info = depositors[msg.sender];
        uint256 depositAmt = info.amount;
        uint256 rewardAmt = unclaimedRewards[msg.sender];
        uint256 total = depositAmt + rewardAmt;
        if (total == 0) revert ZeroAmount();

        if (depositAmt > 0) {
            info.amount = 0;
            totalDeposits -= depositAmt;
            _removeDepositor(msg.sender);
        }
        if (rewardAmt > 0) {
            unclaimedRewards[msg.sender] = 0;
            totalUnclaimedRewards -= rewardAmt;
        }

        botcoin.safeTransfer(msg.sender, total);
        emit Withdrawn(msg.sender, depositAmt);
        if (rewardAmt > 0) emit UserRewardClaimed(msg.sender, rewardAmt);
    }

    // ============ Mining Operations (Operator Only) ============

    /**
     * @notice Forward a signed receipt to the mining contract.
     * @dev The coordinator returns calldata that should be forwarded as-is.
     *      msg.sender of the mining contract call will be this pool contract.
     */
    function submitReceiptToMining(bytes calldata data) external onlyOperator whenNotPaused {
        (bool success, ) = miningContract.call(data);
        if (!success) revert MiningCallFailed();
        totalReceiptsSubmitted++;
        emit ReceiptSubmitted(totalReceiptsSubmitted);
    }

    /**
     * @notice Claim mining rewards for given epochs and distribute to depositors.
     * @param epochIds Array of epoch IDs to claim.
     */
    function claimRewards(uint256[] calldata epochIds) external onlyOperator nonReentrant {
        uint256 balBefore = botcoin.balanceOf(address(this));

        (bool success, ) = miningContract.call(
            abi.encodeWithSignature("claim(uint256[])", epochIds)
        );
        if (!success) revert ClaimFailed();

        uint256 balAfter = botcoin.balanceOf(address(this));
        uint256 totalReward = balAfter - balBefore;

        if (totalReward > 0) {
            _distributeRewards(totalReward);
        }

        emit RewardsClaimed(epochIds, totalReward, totalReward > 0 ? (totalReward * operatorFeeBps) / 10000 : 0);
    }

    // ============ Reward Distribution ============

    function _distributeRewards(uint256 totalReward) internal {
        uint256 opFee = (totalReward * operatorFeeBps) / 10000;
        uint256 depositorReward = totalReward - opFee;

        totalRewardsEarned += totalReward;

        // Send operator fee
        if (opFee > 0) {
            botcoin.safeTransfer(operator, opFee);
        }

        // Distribute pro-rata to depositors
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
     * @notice Claim accumulated rewards as a depositor.
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

    function advanceEpoch(uint256 newEpochId) external onlyOperator {
        if (newEpochId <= currentEpochId) revert EpochNotAdvanced();
        emit EpochAdvanced(currentEpochId, newEpochId);
        currentEpochId = newEpochId;
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
        uint256 depositEpoch,
        uint256 pendingRewards,
        bool active
    ) {
        DepositorInfo storage info = depositors[user];
        return (info.amount, info.depositEpoch, unclaimedRewards[user], info.active);
    }

    function getPoolStats() external view returns (
        uint256 _totalDeposits,
        uint256 _totalRewardsEarned,
        uint256 _totalReceipts,
        uint256 _depositorCount,
        uint256 _tierLevel,
        uint256 _currentEpoch,
        uint256 _operatorFeeBps
    ) {
        uint256 bal = botcoin.balanceOf(address(this));
        uint256 tier = bal >= TIER_3 ? 3 : bal >= TIER_2 ? 2 : bal >= TIER_1 ? 1 : 0;
        return (
            totalDeposits,
            totalRewardsEarned,
            totalReceiptsSubmitted,
            depositorList.length,
            tier,
            currentEpochId,
            operatorFeeBps
        );
    }
}
