// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IEntropy} from "@pythnetwork/IEntropy.sol";
import {IEntropyConsumer} from "@pythnetwork/IEntropyConsumer.sol";

import {SignificantBit} from "./libraries/SignificantBit.sol";

contract Flippy is IEntropyConsumer, ReentrancyGuardTransient, Ownable, UUPSUpgradeable, Initializable {
    struct Bet {
        address player;
        uint64 expiresAt;
        uint16 result; // 0 = before settlement, 1 = lose, n = win (n-1 flips)
        uint256 amount;
        bytes32 userData;
        uint256 stimmySnapshot;
    }

    uint256 public constant MAX_TIMEOUT = 1 hours;
    uint256 public constant GAS_STIPEND = 5_000;
    uint256 public constant MIN_GAS_LEFT_FOR_CANCEL = 50_000;
    uint256 public constant FEE_PRECISION = 10_000; // bps
    uint256 public constant PAYOUT_MULTIPLIER = 2;
    IEntropy public immutable ENTROPY;
    ERC20 public immutable GRIMMY;
    ERC20 public immutable STIMMY;
    uint256 public immutable INITIAL_GRIMMY_RESERVE;

    address public provider;
    uint32 public callbackGasLimit;
    uint8 public epoch;
    uint32 public timeout;
    uint24 public fee;

    uint256 public minBet;
    uint256 public maxBet; // 0 = no max
    uint256 public dividendThreshold;
    uint256 public maxPendingPayout;

    mapping(uint256 => Bet) private _pendingBets;
    mapping(uint256 => uint256) public greasedRewards;
    mapping(address => uint256) public pendingEthWithdrawals;

    uint256[50] private __gap;

    event Flip(
        uint256 indexed betKey,
        address indexed player,
        uint256 amount,
        bytes32 userData,
        uint256 stimmySnapshot,
        uint128 entropyFee,
        uint256 houseFee,
        uint256 expiresAt
    );
    event BetSettled(
        uint256 indexed betKey,
        address indexed player,
        bytes32 userData,
        uint256 payout,
        uint256 grimmyBonus,
        uint256 flips
    );
    event EpochAdvanced(uint256 newEpoch);
    event CallbackGasLimitUpdated(uint32 newGasLimit);
    event BetLimitsUpdated(uint256 minBet, uint256 maxBet);
    event FeeUpdated(uint24 fee);
    event DividendThresholdUpdated(uint256 threshold);
    event ProviderUpdated(address provider);
    event DividendPaid(uint256 amount);
    event DonationReceived(uint256 amount);
    event TimeoutUpdated(uint32 timeout);
    event BetCanceled(uint256 betKey);
    event TransferFailed(address indexed user, uint256 amount);
    event Claimed(address indexed user, address indexed to, uint256 amount);

    error InvalidCommitment();
    error InvalidValue();
    error InsufficientHouseLiquidity();
    error StimmyNotInitialized();
    error BetAlreadySettled(uint256 betKey);
    error UnknownBet(uint256 betKey);
    error UnexpectedProvider(address provider);
    error BetOutOfRange();
    error BetNotExpired(uint256 betKey);
    error BetExpired(uint256 betKey);
    error InsufficientGas();

    constructor(address _entropy, address _grimmy, address _stimmy, uint256 _initialReserve) {
        _disableInitializers();
        require(_entropy != address(0), "entropy address zero");
        require(_grimmy != address(0), "grimmy address zero");
        require(_stimmy != address(0), "stimmy address zero");
        require(_initialReserve > 0, "initial reserve zero");

        ENTROPY = IEntropy(_entropy);
        GRIMMY = ERC20(_grimmy);
        STIMMY = ERC20(_stimmy);
        INITIAL_GRIMMY_RESERVE = _initialReserve;
    }

    function initialize(
        address _owner,
        address _provider,
        uint32 _initialCallbackGasLimit,
        uint256 _initialDividendThreshold,
        uint32 _initialTimeout,
        uint256 _initialMinBet,
        uint256 _initialMaxBet
    ) external initializer {
        _initializeOwner(_owner);
        require(_provider != address(0), "provider address zero");
        require(_initialCallbackGasLimit != 0, "callback gas zero");
        require(_initialDividendThreshold > 0, "dividend threshold zero");
        require(_initialTimeout != 0, "timeout zero");

        provider = _provider;
        callbackGasLimit = _initialCallbackGasLimit;
        fee = 350; // 3.5%
        dividendThreshold = _initialDividendThreshold;
        require(GRIMMY.balanceOf(address(this)) >= INITIAL_GRIMMY_RESERVE, "insufficient grimmy reserve");
        _setBetLimits(_initialMinBet, _initialMaxBet);
        _setTimeout(_initialTimeout);

        emit FeeUpdated(fee);
        emit DividendThresholdUpdated(dividendThreshold);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    receive() external payable {
        if (msg.value == 0) {
            revert InvalidValue();
        }
        emit DonationReceived(msg.value);
    }

    function setCallbackGasLimit(uint32 _gasLimit) external onlyOwner {
        require(_gasLimit != 0, "gas limit zero");
        callbackGasLimit = _gasLimit;
        emit CallbackGasLimitUpdated(callbackGasLimit);
    }

    function setBetLimits(uint256 _minBet, uint256 _maxBet) public onlyOwner {
        _setBetLimits(_minBet, _maxBet);
    }

    function setFee(uint24 _fee) external onlyOwner {
        require(_fee <= FEE_PRECISION, "fee too high");
        fee = _fee;
        emit FeeUpdated(fee);
    }

    function setDividendThreshold(uint256 _threshold) external onlyOwner {
        dividendThreshold = _threshold;
        emit DividendThresholdUpdated(dividendThreshold);
    }

    function setProvider(address _provider) external onlyOwner {
        require(_provider != address(0), "provider address zero");
        provider = _provider;
        emit ProviderUpdated(provider);
    }

    function setTimeout(uint32 _timeout) external onlyOwner {
        _setTimeout(_timeout);
    }

    function flip(uint256 betAmount, bytes32 userData, bytes32 commitment)
        external
        payable
        nonReentrant
        returns (uint256 betKey)
    {
        if (commitment != keccak256(abi.encode(callbackGasLimit, timeout, fee))) {
            revert InvalidCommitment();
        }
        if (STIMMY.totalSupply() == 0) revert StimmyNotInitialized();
        if (betAmount == 0) revert InvalidValue();
        if (betAmount < minBet) revert BetOutOfRange();
        if (maxBet != 0 && betAmount > maxBet) revert BetOutOfRange();

        uint128 entropyFee = ENTROPY.getFeeV2(provider, callbackGasLimit);
        uint256 houseFee = (betAmount * uint256(fee)) / FEE_PRECISION;
        uint256 expectedValue = betAmount + houseFee + uint256(entropyFee);
        if (msg.value < expectedValue) {
            revert InvalidValue();
        } else if (msg.value > expectedValue) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - expectedValue);
        }

        uint256 potentialPayout = betAmount * PAYOUT_MULTIPLIER;
        maxPendingPayout += potentialPayout;

        uint256 houseBalance = address(this).balance;
        if (houseBalance < maxPendingPayout + entropyFee) {
            revert InsufficientHouseLiquidity();
        }

        uint64 sequence = ENTROPY.requestV2{value: entropyFee}(provider, callbackGasLimit);
        betKey = encodeBetKey(provider, sequence);

        uint64 expiresAt;
        unchecked {
            // casting to 'uint64' is safe because the timestamp is less than 2^64
            // forge-lint: disable-next-line(unsafe-typecast)
            expiresAt = uint64(block.timestamp + uint256(timeout));
        }
        uint256 stimmySnapshot = STIMMY.balanceOf(msg.sender);
        _pendingBets[betKey] = Bet({
            player: msg.sender,
            expiresAt: expiresAt,
            result: 0,
            amount: betAmount,
            userData: userData,
            stimmySnapshot: stimmySnapshot
        });

        emit Flip(betKey, msg.sender, betAmount, userData, stimmySnapshot, entropyFee, houseFee, expiresAt);

        _payoutDividends();
    }

    /// @notice Can be called if entropyCallback was not called within the timeout window
    function cancel(uint256 betKey) external nonReentrant {
        Bet memory bet = _pendingBets[betKey];
        if (bet.player == address(0)) {
            revert UnknownBet(betKey);
        }
        if (bet.result != 0) {
            revert BetAlreadySettled(betKey);
        }
        if (bet.expiresAt > block.timestamp) {
            revert BetNotExpired(betKey);
        }
        _pendingBets[betKey].result = type(uint16).max; // Mark as cancelled
        maxPendingPayout -= bet.amount * PAYOUT_MULTIPLIER;
        emit BetCanceled(betKey);

        // @dev We should check left gas is sufficient b/c anyone can call this function.
        if (gasleft() < MIN_GAS_LEFT_FOR_CANCEL) {
            revert InsufficientGas();
        }
        _transferNativeOrFallbackToClaim(bet.player, bet.amount);
    }

    function claim(address to) external nonReentrant {
        uint256 amount = pendingEthWithdrawals[msg.sender];
        if (amount > 0) {
            pendingEthWithdrawals[msg.sender] = 0;
            maxPendingPayout -= amount;
            emit Claimed(msg.sender, to, amount);

            SafeTransferLib.safeTransferETH(to, amount);
        }
    }

    function currentEntropyFee() external view returns (uint128) {
        return ENTROPY.getFeeV2(provider, callbackGasLimit);
    }

    function getEntropy() internal view override returns (address) {
        return address(ENTROPY);
    }

    function encodeBetKey(address providerAddress, uint64 sequence) public pure returns (uint256) {
        return uint256(uint160(providerAddress)) << 64 | uint256(sequence);
    }

    function getPendingBet(uint256 betKey) external view returns (Bet memory) {
        return _pendingBets[betKey];
    }

    function entropyCallback(uint64 sequence, address providerAddress, bytes32 randomNumber)
        internal
        override
        nonReentrant
    {
        if (providerAddress != provider) {
            revert UnexpectedProvider(providerAddress);
        }

        uint256 betKey = encodeBetKey(providerAddress, sequence);

        Bet memory bet = _pendingBets[betKey];
        if (bet.player == address(0)) {
            revert UnknownBet(betKey);
        }

        if (bet.expiresAt <= block.timestamp) {
            revert BetExpired(betKey);
        }

        uint256 randomValue = uint256(randomNumber);
        // Counts trailing zeros to get the number of successful flips
        uint256 flips = randomValue == 0 ? 0 : SignificantBit.leastSignificantBit(randomValue);
        uint256 payout = 0;
        uint256 grimmyBonus = 0;
        uint256 potentialPayout = bet.amount * PAYOUT_MULTIPLIER;
        maxPendingPayout -= potentialPayout;
        // Player wins and gets a payout + grimmy reward
        if (flips > 0) {
            payout = potentialPayout;
            uint256 houseBalance = address(this).balance;
            // dev: if there is not enough balance, send the entire balance
            if (houseBalance < payout) {
                payout = houseBalance;
            }
            grimmyBonus = _calculateGrimmyBonus(bet.player, bet.amount, flips - 1, bet.stimmySnapshot);
            uint256 available = GRIMMY.balanceOf(address(this));
            grimmyBonus = grimmyBonus > available ? available : grimmyBonus;
            if (grimmyBonus > 0) {
                SafeTransferLib.safeTransfer(address(GRIMMY), bet.player, grimmyBonus);
            }
        }
        _updateEpoch();

        _pendingBets[betKey].result = SafeCastLib.toUint16(flips + 1);
        emit BetSettled(betKey, bet.player, bet.userData, payout, grimmyBonus, flips);

        if (payout > 0) {
            _transferNativeOrFallbackToClaim(bet.player, payout);
        }
    }

    function _transferNativeOrFallbackToClaim(address player, uint256 amount) internal {
        bool success = SafeTransferLib.trySafeTransferETH(player, amount, GAS_STIPEND);
        if (!success) {
            pendingEthWithdrawals[player] += amount;
            maxPendingPayout += amount;
            emit TransferFailed(player, amount);
        }
    }

    // Bonus is calculated as betAmount * (flips - 1) / divisor for flips >= 2
    // flips = 1: no bonus (flips - 1 = 0)
    // flips = 2: bonus = betAmount * 1 / divisor
    // flips = 3: bonus = betAmount * 2 / divisor, etc.
    // With grease (STIMMY staking), bonus can be up to 4x the base reward
    function _calculateGrimmyBonus(address player, uint256 betAmount, uint256 flips, uint256 stimmySnapshot)
        internal
        returns (uint256)
    {
        if (flips == 0) {
            return 0;
        }

        uint256 divisor = uint256(1) << uint256(epoch);
        uint256 baseReward = (betAmount * flips) / divisor;
        if (baseReward == 0) {
            return 0;
        }

        uint40 currentDay = uint40(block.timestamp / 1 days);
        uint256 key = (uint256(uint160(player)) << 40) | currentDay;
        uint256 used = greasedRewards[key];

        uint256 bonusCapacity = stimmySnapshot / 10;
        if (bonusCapacity <= used) {
            return baseReward;
        }

        uint256 remainingBonusCapacity;
        unchecked {
            remainingBonusCapacity = bonusCapacity - used;
        }
        uint256 potentialBonus = baseReward * 3;
        uint256 bonusReward = potentialBonus > remainingBonusCapacity ? remainingBonusCapacity : potentialBonus;

        greasedRewards[key] = used + bonusReward;
        return baseReward + bonusReward;
    }

    function _payoutDividends() internal {
        uint256 threshold = FixedPointMathLib.max(dividendThreshold, maxPendingPayout);
        uint256 houseBalance = address(this).balance;
        if (houseBalance <= threshold) {
            return;
        }

        uint256 amountToSend = houseBalance - threshold;
        SafeTransferLib.safeTransferETH(address(STIMMY), amountToSend);

        emit DividendPaid(amountToSend);
    }

    function _updateEpoch() internal {
        uint256 balance = GRIMMY.balanceOf(address(this));
        uint256 targetEpoch = epoch;

        // Increase epoch until the current balance rises above the next threshold.
        // Epoch 0: no halving (threshold = INITIAL_GRIMMY_RESERVE)
        // Epoch 1: first halving (threshold = INITIAL_GRIMMY_RESERVE / 2)
        // Epoch 2: second halving (threshold = INITIAL_GRIMMY_RESERVE / 4), etc.
        while (true) {
            unchecked {
                uint256 nextThreshold = INITIAL_GRIMMY_RESERVE >> (targetEpoch + 1);
                if (nextThreshold == 0 || balance > nextThreshold) {
                    break;
                }
                ++targetEpoch;
            }
        }

        if (targetEpoch > epoch) {
            epoch = SafeCastLib.toUint8(targetEpoch);
            emit EpochAdvanced(targetEpoch);
        }
    }

    function _setBetLimits(uint256 _minBet, uint256 _maxBet) internal {
        if (_maxBet != 0 && _maxBet < _minBet) revert InvalidValue();
        minBet = _minBet;
        maxBet = _maxBet;
        emit BetLimitsUpdated(minBet, maxBet);
    }

    function _setTimeout(uint32 _timeout) internal {
        require(_timeout != 0, "timeout zero");
        require(_timeout <= MAX_TIMEOUT, "timeout too long");
        timeout = _timeout;
        emit TimeoutUpdated(timeout);
    }
}
