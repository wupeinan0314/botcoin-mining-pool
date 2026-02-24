// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4);
}

interface IMiningContract {
    function submitReceipt(bytes calldata data) external;
    function claim(uint256[] calldata epochIds) external;
}

contract BotcoinPool is IERC1271, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes4 constant EIP1271_MAGIC = 0x1626ba7e;

    IERC20 public immutable botcoin;
    address public immutable miningContract;
    address public operator;
    address public pendingOperator;
    
    uint256 public operatorFeeBps; // basis points (e.g. 500 = 5%)
    uint256 public constant MAX_FEE_BPS = 2000; // max 20%
    
    // Epoch tracking
    uint256 public currentEpochId;
    
    // User deposits
    mapping(address => uint256) public deposits;
    mapping(address => uint256) public depositEpoch; // epoch when deposit was made
    address[] public depositors;
    mapping(address => bool) public isDepositor;
    
    uint256 public totalDeposits;
    uint256 public pendingDeposits; // deposits not yet locked
    uint256 public lockedDeposits; // deposits locked for current epoch
    
    // Rewards tracking
    mapping(address => uint256) public unclaimedRewards;
    uint256 public totalUnclaimedRewards;
    
    // Events
    event Deposited(address indexed user, uint256 amount, uint256 epoch);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardsClaimed(uint256[] epochIds, uint256 totalReward);
    event RewardsDistributed(uint256 epoch, uint256 totalReward, uint256 operatorFee);
    event UserRewardClaimed(address indexed user, uint256 amount);
    event OperatorChanged(address indexed oldOperator, address indexed newOperator);
    event OperatorFeeChanged(uint256 oldFee, uint256 newFee);
    event ReceiptSubmitted(bytes data);

    modifier onlyOperator() {
        require(msg.sender == operator, "Not operator");
        _;
    }

    constructor(
        address _botcoin,
        address _miningContract,
        address _operator,
        uint256 _feeBps
    ) {
        require(_botcoin != address(0), "Invalid token");
        require(_miningContract != address(0), "Invalid mining contract");
        require(_operator != address(0), "Invalid operator");
        require(_feeBps <= MAX_FEE_BPS, "Fee too high");
        
        botcoin = IERC20(_botcoin);
        miningContract = _miningContract;
        operator = _operator;
        operatorFeeBps = _feeBps;
    }

    // ============ EIP-1271 ============
    
    function isValidSignature(bytes32 hash, bytes memory signature) 
        external view override returns (bytes4) 
    {
        require(signature.length == 65, "Invalid sig length");
        
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
        if (recovered == operator) {
            return EIP1271_MAGIC;
        }
        return 0xffffffff;
    }

    // ============ Deposits ============
    
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        
        botcoin.safeTransferFrom(msg.sender, address(this), amount);
        
        if (!isDepositor[msg.sender]) {
            depositors.push(msg.sender);
            isDepositor[msg.sender] = true;
        }
        
        deposits[msg.sender] += amount;
        depositEpoch[msg.sender] = currentEpochId;
        totalDeposits += amount;
        
        emit Deposited(msg.sender, amount, currentEpochId);
    }

    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        require(deposits[msg.sender] >= amount, "Insufficient deposit");
        
        deposits[msg.sender] -= amount;
        totalDeposits -= amount;
        
        if (deposits[msg.sender] == 0) {
            isDepositor[msg.sender] = false;
        }
        
        botcoin.safeTransfer(msg.sender, amount);
        
        emit Withdrawn(msg.sender, amount);
    }

    // ============ Mining Operations (Operator Only) ============
    
    function submitReceiptToMining(bytes calldata data) external onlyOperator {
        (bool success, ) = miningContract.call(data);
        require(success, "Mining call failed");
        emit ReceiptSubmitted(data);
    }

    function claimRewards(uint256[] calldata epochIds) external onlyOperator nonReentrant {
        uint256 balBefore = botcoin.balanceOf(address(this));
        
        (bool success, ) = miningContract.call(
            abi.encodeWithSignature("claim(uint256[])", epochIds)
        );
        require(success, "Claim failed");
        
        uint256 balAfter = botcoin.balanceOf(address(this));
        uint256 totalReward = balAfter - balBefore;
        
        if (totalReward > 0) {
            _distributeRewards(totalReward);
        }
        
        emit RewardsClaimed(epochIds, totalReward);
    }

    function _distributeRewards(uint256 totalReward) internal {
        // Operator fee
        uint256 opFee = (totalReward * operatorFeeBps) / 10000;
        uint256 depositorReward = totalReward - opFee;
        
        // Send operator fee
        if (opFee > 0) {
            botcoin.safeTransfer(operator, opFee);
        }
        
        // Distribute to depositors pro-rata
        if (totalDeposits > 0 && depositorReward > 0) {
            for (uint256 i = 0; i < depositors.length; i++) {
                address user = depositors[i];
                uint256 userDeposit = deposits[user];
                if (userDeposit > 0) {
                    uint256 userReward = (depositorReward * userDeposit) / totalDeposits;
                    unclaimedRewards[user] += userReward;
                    totalUnclaimedRewards += userReward;
                }
            }
        }
        
        emit RewardsDistributed(currentEpochId, totalReward, opFee);
    }

    function claimUserRewards() external nonReentrant {
        uint256 amount = unclaimedRewards[msg.sender];
        require(amount > 0, "No rewards");
        
        unclaimedRewards[msg.sender] = 0;
        totalUnclaimedRewards -= amount;
        
        botcoin.safeTransfer(msg.sender, amount);
        
        emit UserRewardClaimed(msg.sender, amount);
    }

    // ============ Admin ============
    
    function setOperatorFee(uint256 newFeeBps) external onlyOperator {
        require(newFeeBps <= MAX_FEE_BPS, "Fee too high");
        emit OperatorFeeChanged(operatorFeeBps, newFeeBps);
        operatorFeeBps = newFeeBps;
    }

    function transferOperator(address newOperator) external onlyOperator {
        require(newOperator != address(0), "Invalid operator");
        pendingOperator = newOperator;
    }

    function acceptOperator() external {
        require(msg.sender == pendingOperator, "Not pending operator");
        emit OperatorChanged(operator, msg.sender);
        operator = msg.sender;
        pendingOperator = address(0);
    }

    function advanceEpoch(uint256 newEpochId) external onlyOperator {
        require(newEpochId > currentEpochId, "Epoch must increase");
        currentEpochId = newEpochId;
    }

    // ============ View ============
    
    function getDepositorCount() external view returns (uint256) {
        return depositors.length;
    }

    function getPoolBalance() external view returns (uint256) {
        return botcoin.balanceOf(address(this));
    }

    function getTierLevel() external view returns (uint256) {
        uint256 bal = botcoin.balanceOf(address(this));
        if (bal >= 100_000_000 * 1e18) return 3;
        if (bal >= 50_000_000 * 1e18) return 2;
        if (bal >= 25_000_000 * 1e18) return 1;
        return 0;
    }
}
