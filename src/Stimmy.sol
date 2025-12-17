// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ERC20} from "solady/tokens/ERC20.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

/**
 * Stimmy: staking token for Grimmy.
 * - Stake GRIMMY => mint 1:1 STIMMY
 * - Request unstake => burn STIMMY, withdraw GRIMMY after 7 days
 * - Accepts ONLY native chain token (ETH) as rewards; pro-rata distribution to stakers
 */
contract Stimmy is ERC20, ReentrancyGuardTransient, Ownable, UUPSUpgradeable, Initializable {
    struct Withdrawal {
        uint216 amount;
        uint40 claimableAt;
    }

    ERC20 public immutable STAKING_TOKEN; // GRIMMY
    uint40 public constant UNSTAKE_DELAY = 7 days;
    uint256 public constant MAX_WITHDRAWALS = 50;

    // native reward accounting
    uint256 public rewardPerShareStored; // scaled by 1e18
    uint256 public lastRewardBalance; // native balance already accounted into rewardPerShareStored

    // user accounting
    mapping(address => uint256) public userRewardPaid; // user => paid index
    mapping(address => uint256) public userRewards; // user => accrued claimable
    mapping(address => Withdrawal[]) public withdrawals; // user => pending withdrawals
    mapping(address => uint256) public withdrawalsCursor; // user => cursor of the withdrawals array

    error TransferNotAllowed();

    uint256[50] private __gap;

    event Staked(address indexed user, uint256 amount);
    event UnstakeRequested(address indexed user, uint256 amount, uint256 claimableAt);
    event UnstakeWithdrawn(address indexed user, uint256 amount, uint256 cursor);
    event RewardsNotified(uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount, address to);

    constructor(address _stakingToken) {
        _disableInitializers();
        require(_stakingToken != address(0), "staking token required");
        STAKING_TOKEN = ERC20(_stakingToken);
    }

    function initialize(address _owner) external initializer {
        _initializeOwner(_owner);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // --------------------------- Public views ---------------------------

    function pendingRewards(address user) public view returns (uint256) {
        uint256 acc = rewardPerShareStored;
        uint256 totalShares = totalSupply();
        if (totalShares > 0) {
            uint256 currentBal = address(this).balance;
            uint256 delta;
            unchecked {
                delta = currentBal > lastRewardBalance ? (currentBal - lastRewardBalance) : 0;
            }
            if (delta > 0) {
                acc += (delta * 1 ether) / totalShares;
            }
        }
        uint256 userShares = balanceOf(user);
        uint256 paid = userRewardPaid[user];
        uint256 accrued = userRewards[user];
        return accrued + ((userShares * acc) / 1 ether) - paid;
    }

    // --------------------------- Staking flow ---------------------------

    function stakeWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external nonReentrant {
        ERC20(address(STAKING_TOKEN)).permit(msg.sender, address(this), amount, deadline, v, r, s);
        _stake(msg.sender, amount);
    }

    function stake(uint256 amount) external nonReentrant {
        _stake(msg.sender, amount);
    }

    function _stake(address user, uint256 amount) internal {
        require(amount > 0, "amount=0");

        // pull principal
        SafeTransferLib.safeTransferFrom(address(STAKING_TOKEN), user, address(this), amount);
        _mint(user, amount);

        emit Staked(user, amount);
    }

    function requestUnstake(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");
        require(balanceOf(msg.sender) >= amount, "insufficient stake");

        _burn(msg.sender, amount);
        uint40 claimableAt;
        unchecked {
            claimableAt = uint40(block.timestamp) + UNSTAKE_DELAY;
        }
        withdrawals[msg.sender].push(Withdrawal({amount: SafeCastLib.toUint216(amount), claimableAt: claimableAt}));

        emit UnstakeRequested(msg.sender, amount, claimableAt);
    }

    function withdrawUnstaked() external nonReentrant {
        uint256 len = withdrawals[msg.sender].length;
        uint256 cursor = withdrawalsCursor[msg.sender];
        require(len > 0 && len > cursor, "nothing pending");
        uint256 totalToWithdraw;

        for (uint256 i = 0; i < MAX_WITHDRAWALS; ++i) {
            Withdrawal memory w = withdrawals[msg.sender][cursor];
            if (w.claimableAt <= block.timestamp) {
                unchecked {
                    totalToWithdraw += uint256(w.amount);
                    ++cursor;
                }
                if (cursor >= len) {
                    break;
                }
            } else {
                break;
            }
        }
        withdrawalsCursor[msg.sender] = cursor;

        require(totalToWithdraw > 0, "not claimable yet");

        SafeTransferLib.safeTransfer(address(STAKING_TOKEN), msg.sender, totalToWithdraw);
        emit UnstakeWithdrawn(msg.sender, totalToWithdraw, cursor);
    }

    // --------------------------- Native Rewards (ETH) ---------------------------

    receive() external payable {
        require(msg.value > 0, "no value");
        _updateRewards();
    }

    function _updateRewards() internal {
        uint256 current = address(this).balance;
        uint256 delta;
        unchecked {
            delta = current > lastRewardBalance ? (current - lastRewardBalance) : 0;
        }
        if (delta > 0) {
            uint256 shares = totalSupply();
            if (shares > 0) {
                rewardPerShareStored += (delta * 1 ether) / shares;
                lastRewardBalance = current;
                emit RewardsNotified(delta);
            }
        } else if (current != lastRewardBalance) {
            // keep lastBalance in sync if external transfers occurred (e.g. manual sends)
            lastRewardBalance = current;
        }
    }

    function claimRewards(address to) public nonReentrant {
        _updateRewards();
        _settleUserRewards(msg.sender);

        uint256 amount = userRewards[msg.sender];
        if (amount > 0) {
            userRewards[msg.sender] = 0;
            // keep lastBalance consistent with accounted funds
            lastRewardBalance -= amount;
        }

        _syncUserPaid(msg.sender);

        if (amount > 0) {
            SafeTransferLib.safeTransferETH(to, amount);
            emit RewardClaimed(msg.sender, amount, to);
        }
    }

    // --------------------------- Internal helpers ---------------------------

    function _settleUserRewards(address user) internal {
        uint256 userShares = balanceOf(user);
        uint256 paid = userRewardPaid[user];
        uint256 accruedDelta = ((userShares * rewardPerShareStored) / 1 ether) - paid;
        if (accruedDelta > 0) {
            userRewards[user] += accruedDelta;
        }
    }

    function _syncUserPaid(address user) internal {
        uint256 userShares = balanceOf(user);
        userRewardPaid[user] = (userShares * rewardPerShareStored) / 1 ether;
    }

    // --------------------------- ERC20 overrides ---------------------------

    function name() public pure override returns (string memory) {
        return "Stimmulus Producing Token";
    }

    function symbol() public pure override returns (string memory) {
        return "STIMMY";
    }

    function transfer(address, uint256) public pure override returns (bool) {
        revert TransferNotAllowed();
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert TransferNotAllowed();
    }

    function _beforeTokenTransfer(address from, address to, uint256) internal override {
        _updateRewards();
        _settleUserRewards(from);
        _settleUserRewards(to);
    }

    function _afterTokenTransfer(address from, address to, uint256) internal override {
        _syncUserPaid(from);
        _syncUserPaid(to);
    }
}
