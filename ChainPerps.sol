// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ChainPerps
/// @notice Mock perpetual futures protocol used for local testing, education, and audit practice.
/// @dev This contract is intentionally self-contained and simplified. It is not production ready.
contract ChainPerps is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_BPS = 10_000;
    uint256 public constant FUNDING_PRECISION = 1e18;
    uint256 public constant PRICE_PRECISION = 1e30;
    uint256 public constant POSITION_PRECISION = 1e18;
    uint256 public constant MAX_MARKETS = 64;
    uint256 public constant MIN_POSITION_SIZE = 1e15;
    uint256 public constant MAX_FUNDING_RATE_BPS = 250;
    uint256 public constant MAX_STALE_PRICE_DELAY = 1 days;

    IERC20 public immutable collateralToken;

    address public treasury;
    address public feeReceiver;
    address public insuranceFund;
    address public keeper;

    uint256 public nextMarketId = 1;
    uint256 public totalCollateralDeposited;
    uint256 public totalCollateralReserved;
    uint256 public totalFeesAccrued;
    uint256 public totalFeesClaimed;
    uint256 public totalInsuranceBalance;
    uint256 public globalDepositCap;
    uint256 public liquidationGasReward;

    bool public withdrawalsPaused;
    bool public liquidationsPaused;
    bool public newPositionsPaused;

    enum Side {
        None,
        Long,
        Short
    }

    enum MarketStatus {
        Disabled,
        Active,
        ReduceOnly,
        Settled
    }

    struct RiskParams {
        uint256 maxLeverageBps;
        uint256 maintenanceMarginBps;
        uint256 liquidationFeeBps;
        uint256 takerFeeBps;
        uint256 makerFeeBps;
        uint256 maxOpenInterest;
        uint256 maxSkewBps;
        uint256 fundingFactorBps;
        uint256 stalePriceDelay;
    }

    struct Market {
        string symbol;
        address oracle;
        MarketStatus status;
        RiskParams risk;
        uint256 indexPrice;
        uint256 lastPriceUpdate;
        uint256 longOpenInterest;
        uint256 shortOpenInterest;
        int256 cumulativeFundingLong;
        int256 cumulativeFundingShort;
        uint256 lastFundingTime;
        uint256 settlementPrice;
        uint256 totalVolume;
        uint256 totalLiquidations;
    }

    struct Position {
        Side side;
        uint256 size;
        uint256 collateral;
        uint256 entryPrice;
        int256 entryFunding;
        uint256 lastIncreaseTime;
        uint256 lastDecreaseTime;
        uint256 realizedPnl;
    }

    struct Account {
        uint256 freeCollateral;
        uint256 reservedCollateral;
        uint256 lastDepositTime;
        uint256 nonce;
        bool blocked;
    }

    struct OrderRequest {
        address trader;
        uint256 marketId;
        Side side;
        uint256 sizeDelta;
        uint256 collateralDelta;
        uint256 acceptablePrice;
        bool increase;
        uint256 deadline;
        uint256 nonce;
    }

    struct LiquidationResult {
        uint256 marginValue;
        uint256 maintenanceMargin;
        uint256 liquidationFee;
        int256 pnl;
        int256 fundingPayment;
        bool liquidatable;
    }

    mapping(uint256 => Market) public markets;
    mapping(address => Account) public accounts;
    mapping(address => mapping(uint256 => Position)) public positions;
    mapping(address => mapping(uint256 => bool)) public approvedExecutors;
    mapping(bytes32 => bool) public usedOrderHashes;

    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeeReceiverUpdated(address indexed oldFeeReceiver, address indexed newFeeReceiver);
    event InsuranceFundUpdated(address indexed oldInsuranceFund, address indexed newInsuranceFund);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event Deposit(address indexed trader, uint256 amount, uint256 newFreeCollateral);
    event Withdraw(address indexed trader, uint256 amount, uint256 newFreeCollateral);
    event MarketCreated(uint256 indexed marketId, string symbol, address oracle);
    event MarketStatusUpdated(uint256 indexed marketId, MarketStatus oldStatus, MarketStatus newStatus);
    event RiskParamsUpdated(uint256 indexed marketId);
    event PriceUpdated(uint256 indexed marketId, uint256 price, uint256 timestamp);
    event FundingUpdated(uint256 indexed marketId, int256 fundingLong, int256 fundingShort, uint256 timestamp);
    event PositionIncreased(address indexed trader, uint256 indexed marketId, Side side, uint256 sizeDelta, uint256 collateralDelta, uint256 price, uint256 fee);
    event PositionDecreased(address indexed trader, uint256 indexed marketId, uint256 sizeDelta, uint256 collateralReturned, uint256 price, int256 pnl, uint256 fee);
    event PositionLiquidated(address indexed trader, address indexed liquidator, uint256 indexed marketId, uint256 price, int256 pnl, uint256 fee, uint256 reward);
    event AccountBlocked(address indexed trader, bool blocked);
    event ExecutorApproval(address indexed trader, uint256 indexed marketId, address indexed executor, bool approved);
    event FeesClaimed(address indexed receiver, uint256 amount);
    event InsuranceFunded(address indexed sender, uint256 amount);
    event GlobalDepositCapUpdated(uint256 oldCap, uint256 newCap);
    event PauseFlagsUpdated(bool withdrawalsPaused, bool liquidationsPaused, bool newPositionsPaused);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidMarket();
    error InvalidSide();
    error InvalidPrice();
    error InvalidRiskParams();
    error MarketNotActive();
    error MarketReduceOnly();
    error MarketSettled();
    error StalePrice();
    error Unauthorized();
    error AccountIsBlocked();
    error DeadlineExpired();
    error InvalidNonce();
    error OrderAlreadyUsed();
    error PriceSlippage();
    error InsufficientCollateral();
    error InsufficientLiquidity();
    error MaxLeverageExceeded();
    error MaxOpenInterestExceeded();
    error PositionNotFound();
    error PositionTooSmall();
    error NotLiquidatable();
    error WithdrawalsArePaused();
    error LiquidationsArePaused();
    error NewPositionsArePaused();

    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner()) revert Unauthorized();
        _;
    }

    modifier onlyTraderOrExecutor(address trader, uint256 marketId) {
        if (msg.sender != trader && !approvedExecutors[trader][marketId][msg.sender]) revert Unauthorized();
        _;
    }

    modifier accountAllowed(address trader) {
        if (accounts[trader].blocked) revert AccountIsBlocked();
        _;
    }

    constructor(
        IERC20 collateralToken_,
        address treasury_,
        address feeReceiver_,
        address insuranceFund_
    ) Ownable(msg.sender) {
        if (address(collateralToken_) == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (feeReceiver_ == address(0)) revert ZeroAddress();
        if (insuranceFund_ == address(0)) revert ZeroAddress();
        collateralToken = collateralToken_;
        treasury = treasury_;
        feeReceiver = feeReceiver_;
        insuranceFund = insuranceFund_;
        keeper = msg.sender;
        globalDepositCap = type(uint256).max;
        liquidationGasReward = 5e18;
    }

    function deposit(uint256 amount) external nonReentrant whenNotPaused accountAllowed(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        if (totalCollateralDeposited + amount > globalDepositCap) revert InsufficientLiquidity();
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        Account storage account = accounts[msg.sender];
        account.freeCollateral += amount;
        account.lastDepositTime = block.timestamp;
        totalCollateralDeposited += amount;
        emit Deposit(msg.sender, amount, account.freeCollateral);
    }

    function withdraw(uint256 amount) external nonReentrant whenNotPaused accountAllowed(msg.sender) {
        if (withdrawalsPaused) revert WithdrawalsArePaused();
        if (amount == 0) revert ZeroAmount();
        Account storage account = accounts[msg.sender];
        if (account.freeCollateral < amount) revert InsufficientCollateral();
        account.freeCollateral -= amount;
        totalCollateralDeposited -= amount;
        collateralToken.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount, account.freeCollateral);
    }

    function createMarket(
        string calldata symbol,
        address oracle,
        RiskParams calldata risk,
        uint256 initialPrice
    ) external onlyOwner returns (uint256 marketId) {
        if (bytes(symbol).length == 0) revert InvalidMarket();
        if (oracle == address(0)) revert ZeroAddress();
        if (initialPrice == 0) revert InvalidPrice();
        _validateRiskParams(risk);
        marketId = nextMarketId++;
        if (marketId > MAX_MARKETS) revert InvalidMarket();
        Market storage market = markets[marketId];
        market.symbol = symbol;
        market.oracle = oracle;
        market.status = MarketStatus.Active;
        market.risk = risk;
        market.indexPrice = initialPrice;
        market.lastPriceUpdate = block.timestamp;
        market.lastFundingTime = block.timestamp;
        emit MarketCreated(marketId, symbol, oracle);
        emit PriceUpdated(marketId, initialPrice, block.timestamp);
    }

    function updateRiskParams(uint256 marketId, RiskParams calldata risk) external onlyOwner {
        Market storage market = _market(marketId);
        _validateRiskParams(risk);
        market.risk = risk;
        emit RiskParamsUpdated(marketId);
    }

    function setMarketStatus(uint256 marketId, MarketStatus status) external onlyOwner {
        Market storage market = _market(marketId);
        MarketStatus oldStatus = market.status;
        market.status = status;
        emit MarketStatusUpdated(marketId, oldStatus, status);
    }

    function updatePrice(uint256 marketId, uint256 price) external onlyKeeperOrOwner {
        Market storage market = _market(marketId);
        if (price == 0) revert InvalidPrice();
        market.indexPrice = price;
        market.lastPriceUpdate = block.timestamp;
        emit PriceUpdated(marketId, price, block.timestamp);
    }

    function updateFunding(uint256 marketId) external onlyKeeperOrOwner {
        _updateFunding(marketId);
    }

    function approveExecutor(uint256 marketId, address executor, bool approved) external {
        _market(marketId);
        if (executor == address(0)) revert ZeroAddress();
        approvedExecutors[msg.sender][marketId][executor] = approved;
        emit ExecutorApproval(msg.sender, marketId, executor, approved);
    }

    function increasePosition(
        uint256 marketId,
        Side side,
        uint256 sizeDelta,
        uint256 collateralDelta,
        uint256 acceptablePrice
    ) external nonReentrant whenNotPaused accountAllowed(msg.sender) {
        _increasePosition(msg.sender, marketId, side, sizeDelta, collateralDelta, acceptablePrice);
    }

    function decreasePosition(
        uint256 marketId,
        uint256 sizeDelta,
        uint256 acceptablePrice
    ) external nonReentrant whenNotPaused accountAllowed(msg.sender) {
        _decreasePosition(msg.sender, marketId, sizeDelta, acceptablePrice);
    }

    function executeOrder(OrderRequest calldata order) external nonReentrant whenNotPaused onlyTraderOrExecutor(order.trader, order.marketId) accountAllowed(order.trader) {
        if (block.timestamp > order.deadline) revert DeadlineExpired();
        if (order.nonce != accounts[order.trader].nonce) revert InvalidNonce();
        bytes32 orderHash = keccak256(abi.encode(order));
        if (usedOrderHashes[orderHash]) revert OrderAlreadyUsed();
        usedOrderHashes[orderHash] = true;
        accounts[order.trader].nonce++;
        if (order.increase) {
            _increasePosition(order.trader, order.marketId, order.side, order.sizeDelta, order.collateralDelta, order.acceptablePrice);
        } else {
            _decreasePosition(order.trader, order.marketId, order.sizeDelta, order.acceptablePrice);
        }
    }

    function liquidate(address trader, uint256 marketId) external nonReentrant whenNotPaused {
        if (liquidationsPaused) revert LiquidationsArePaused();
        Market storage market = _market(marketId);
        Position storage position = positions[trader][marketId];
        if (position.size == 0) revert PositionNotFound();
        _assertFreshPrice(market);
        LiquidationResult memory result = getLiquidationResult(trader, marketId);
        if (!result.liquidatable) revert NotLiquidatable();
        uint256 remainingCollateral = position.collateral;
        uint256 fee = _min(result.liquidationFee, remainingCollateral);
        remainingCollateral -= fee;
        uint256 reward = _min(liquidationGasReward, remainingCollateral);
        remainingCollateral -= reward;
        _removeOpenInterest(market, position.side, position.size);
        market.totalLiquidations += 1;
        totalCollateralReserved -= position.collateral;
        accounts[trader].reservedCollateral -= position.collateral;
        totalFeesAccrued += fee;
        if (reward > 0) collateralToken.safeTransfer(msg.sender, reward);
        if (remainingCollateral > 0) {
            totalInsuranceBalance += remainingCollateral;
            collateralToken.safeTransfer(insuranceFund, remainingCollateral);
        }
        uint256 price = market.indexPrice;
        delete positions[trader][marketId];
        emit PositionLiquidated(trader, msg.sender, marketId, price, result.pnl, fee, reward);
    }

    function settleMarket(uint256 marketId, uint256 settlementPrice) external onlyOwner {
        Market storage market = _market(marketId);
        if (settlementPrice == 0) revert InvalidPrice();
        market.status = MarketStatus.Settled;
        market.settlementPrice = settlementPrice;
        market.indexPrice = settlementPrice;
        market.lastPriceUpdate = block.timestamp;
        emit MarketStatusUpdated(marketId, market.status, MarketStatus.Settled);
        emit PriceUpdated(marketId, settlementPrice, block.timestamp);
    }

    function closeSettledPosition(uint256 marketId) external nonReentrant {
        Market storage market = _market(marketId);
        if (market.status != MarketStatus.Settled) revert MarketSettled();
        Position storage position = positions[msg.sender][marketId];
        if (position.size == 0) revert PositionNotFound();
        int256 pnl = _calculatePnl(position.side, position.size, position.entryPrice, market.settlementPrice);
        uint256 payout = _settlePayout(position.collateral, pnl);
        _removeOpenInterest(market, position.side, position.size);
        totalCollateralReserved -= position.collateral;
        accounts[msg.sender].reservedCollateral -= position.collateral;
        delete positions[msg.sender][marketId];
        if (payout > 0) {
            accounts[msg.sender].freeCollateral += payout;
        }
        emit PositionDecreased(msg.sender, marketId, position.size, payout, market.settlementPrice, pnl, 0);
    }

    function addInsurance(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        totalInsuranceBalance += amount;
        emit InsuranceFunded(msg.sender, amount);
    }

    function claimFees(uint256 amount) external nonReentrant {
        if (msg.sender != feeReceiver && msg.sender != treasury && msg.sender != owner()) revert Unauthorized();
        if (amount == 0) revert ZeroAmount();
        uint256 claimable = totalFeesAccrued - totalFeesClaimed;
        if (amount > claimable) revert InsufficientLiquidity();
        totalFeesClaimed += amount;
        collateralToken.safeTransfer(feeReceiver, amount);
        emit FeesClaimed(feeReceiver, amount);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    function setFeeReceiver(address newFeeReceiver) external onlyOwner {
        if (newFeeReceiver == address(0)) revert ZeroAddress();
        address oldFeeReceiver = feeReceiver;
        feeReceiver = newFeeReceiver;
        emit FeeReceiverUpdated(oldFeeReceiver, newFeeReceiver);
    }

    function setInsuranceFund(address newInsuranceFund) external onlyOwner {
        if (newInsuranceFund == address(0)) revert ZeroAddress();
        address oldInsuranceFund = insuranceFund;
        insuranceFund = newInsuranceFund;
        emit InsuranceFundUpdated(oldInsuranceFund, newInsuranceFund);
    }

    function setKeeper(address newKeeper) external onlyOwner {
        if (newKeeper == address(0)) revert ZeroAddress();
        address oldKeeper = keeper;
        keeper = newKeeper;
        emit KeeperUpdated(oldKeeper, newKeeper);
    }

    function setGlobalDepositCap(uint256 newCap) external onlyOwner {
        uint256 oldCap = globalDepositCap;
        globalDepositCap = newCap;
        emit GlobalDepositCapUpdated(oldCap, newCap);
    }

    function setPauseFlags(bool withdrawalsPaused_, bool liquidationsPaused_, bool newPositionsPaused_) external onlyOwner {
        withdrawalsPaused = withdrawalsPaused_;
        liquidationsPaused = liquidationsPaused_;
        newPositionsPaused = newPositionsPaused_;
        emit PauseFlagsUpdated(withdrawalsPaused_, liquidationsPaused_, newPositionsPaused_);
    }

    function blockAccount(address trader, bool blocked) external onlyOwner {
        accounts[trader].blocked = blocked;
        emit AccountBlocked(trader, blocked);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function getAccountValue(address trader) external view returns (int256 value) {
        Account storage account = accounts[trader];
        value = int256(account.freeCollateral);
        for (uint256 marketId = 1; marketId < nextMarketId; marketId++) {
            Position storage position = positions[trader][marketId];
            if (position.size == 0) continue;
            Market storage market = markets[marketId];
            int256 pnl = _calculatePnl(position.side, position.size, position.entryPrice, _effectivePrice(market));
            int256 funding = _pendingFundingPayment(market, position);
            value += int256(position.collateral) + pnl - funding;
        }
    }

    function getLiquidationResult(address trader, uint256 marketId) public view returns (LiquidationResult memory result) {
        Market storage market = markets[marketId];
        Position storage position = positions[trader][marketId];
        if (position.size == 0) return result;
        uint256 price = _effectivePrice(market);
        result.pnl = _calculatePnl(position.side, position.size, position.entryPrice, price);
        result.fundingPayment = _pendingFundingPayment(market, position);
        int256 margin = int256(position.collateral) + result.pnl - result.fundingPayment;
        result.marginValue = margin > 0 ? uint256(margin) : 0;
        result.maintenanceMargin = (position.size * market.risk.maintenanceMarginBps) / BPS;
        result.liquidationFee = (position.size * market.risk.liquidationFeeBps) / BPS;
        result.liquidatable = result.marginValue < result.maintenanceMargin + result.liquidationFee;
    }

    function getPosition(address trader, uint256 marketId) external view returns (Position memory) {
        return positions[trader][marketId];
    }

    function getMarket(uint256 marketId) external view returns (Market memory) {
        return markets[marketId];
    }

    function previewIncrease(
        address trader,
        uint256 marketId,
        Side side,
        uint256 sizeDelta,
        uint256 collateralDelta
    ) external view returns (uint256 nextSize, uint256 nextCollateral, uint256 nextEntryPrice, uint256 fee, uint256 leverageBps) {
        Market storage market = markets[marketId];
        Position storage position = positions[trader][marketId];
        uint256 price = _effectivePrice(market);
        fee = _calculateTradingFee(market, sizeDelta, true);
        nextSize = position.size + sizeDelta;
        nextCollateral = position.collateral + collateralDelta;
        if (position.size == 0) {
            nextEntryPrice = price;
        } else if (position.side == side) {
            nextEntryPrice = ((position.entryPrice * position.size) + (price * sizeDelta)) / nextSize;
        } else {
            nextEntryPrice = price;
        }
        leverageBps = nextCollateral == 0 ? type(uint256).max : (nextSize * BPS) / nextCollateral;
    }

    function previewDecrease(
        address trader,
        uint256 marketId,
        uint256 sizeDelta
    ) external view returns (uint256 collateralOut, int256 pnl, int256 fundingPayment, uint256 fee) {
        Market storage market = markets[marketId];
        Position storage position = positions[trader][marketId];
        if (position.size == 0 || sizeDelta > position.size) revert PositionNotFound();
        uint256 price = _effectivePrice(market);
        pnl = _calculatePnl(position.side, sizeDelta, position.entryPrice, price);
        fundingPayment = (_pendingFundingPayment(market, position) * int256(sizeDelta)) / int256(position.size);
        fee = _calculateTradingFee(market, sizeDelta, false);
        uint256 collateralShare = (position.collateral * sizeDelta) / position.size;
        int256 gross = int256(collateralShare) + pnl - fundingPayment - int256(fee);
        collateralOut = gross > 0 ? uint256(gross) : 0;
    }

    function _increasePosition(
        address trader,
        uint256 marketId,
        Side side,
        uint256 sizeDelta,
        uint256 collateralDelta,
        uint256 acceptablePrice
    ) internal {
        if (newPositionsPaused) revert NewPositionsArePaused();
        if (side == Side.None) revert InvalidSide();
        if (sizeDelta < MIN_POSITION_SIZE) revert PositionTooSmall();
        Market storage market = _market(marketId);
        if (market.status != MarketStatus.Active) {
            if (market.status == MarketStatus.ReduceOnly) revert MarketReduceOnly();
            if (market.status == MarketStatus.Settled) revert MarketSettled();
            revert MarketNotActive();
        }
        _assertFreshPrice(market);
        _updateFunding(marketId);
        uint256 price = market.indexPrice;
        _checkAcceptableIncreasePrice(side, price, acceptablePrice);
        uint256 fee = _calculateTradingFee(market, sizeDelta, true);
        Account storage account = accounts[trader];
        uint256 required = collateralDelta + fee;
        if (account.freeCollateral < required) revert InsufficientCollateral();
        Position storage position = positions[trader][marketId];
        if (position.size != 0 && position.side != side) revert InvalidSide();
        uint256 nextSize = position.size + sizeDelta;
        uint256 nextCollateral = position.collateral + collateralDelta;
        if (nextCollateral == 0) revert InsufficientCollateral();
        uint256 leverageBps = (nextSize * BPS) / nextCollateral;
        if (leverageBps > market.risk.maxLeverageBps) revert MaxLeverageExceeded();
        _addOpenInterest(market, side, sizeDelta);
        _validateOpenInterest(market);
        account.freeCollateral -= required;
        account.reservedCollateral += collateralDelta;
        totalCollateralReserved += collateralDelta;
        totalFeesAccrued += fee;
        if (position.size == 0) {
            position.side = side;
            position.entryPrice = price;
            position.entryFunding = side == Side.Long ? market.cumulativeFundingLong : market.cumulativeFundingShort;
        } else {
            position.entryPrice = ((position.entryPrice * position.size) + (price * sizeDelta)) / nextSize;
        }
        position.size = nextSize;
        position.collateral = nextCollateral;
        position.lastIncreaseTime = block.timestamp;
        market.totalVolume += sizeDelta;
        emit PositionIncreased(trader, marketId, side, sizeDelta, collateralDelta, price, fee);
    }

    function _decreasePosition(address trader, uint256 marketId, uint256 sizeDelta, uint256 acceptablePrice) internal {
        if (sizeDelta == 0) revert ZeroAmount();
        Market storage market = _market(marketId);
        if (market.status == MarketStatus.Disabled) revert MarketNotActive();
        if (market.status == MarketStatus.Settled) revert MarketSettled();
        _assertFreshPrice(market);
        _updateFunding(marketId);
        Position storage position = positions[trader][marketId];
        if (position.size == 0 || sizeDelta > position.size) revert PositionNotFound();
        uint256 price = market.indexPrice;
        _checkAcceptableDecreasePrice(position.side, price, acceptablePrice);
        int256 pnl = _calculatePnl(position.side, sizeDelta, position.entryPrice, price);
        int256 fundingPayment = (_pendingFundingPayment(market, position) * int256(sizeDelta)) / int256(position.size);
        uint256 fee = _calculateTradingFee(market, sizeDelta, false);
        uint256 collateralShare = (position.collateral * sizeDelta) / position.size;
        int256 gross = int256(collateralShare) + pnl - fundingPayment - int256(fee);
        uint256 collateralOut = gross > 0 ? uint256(gross) : 0;
        if (collateralOut > collateralShare) {
            uint256 profit = collateralOut - collateralShare;
            if (profit > totalInsuranceBalance) collateralOut = collateralShare + totalInsuranceBalance;
            totalInsuranceBalance -= collateralOut - collateralShare;
        }
        Account storage account = accounts[trader];
        position.size -= sizeDelta;
        position.collateral -= collateralShare;
        position.lastDecreaseTime = block.timestamp;
        if (pnl > 0) position.realizedPnl += uint256(pnl);
        account.reservedCollateral -= collateralShare;
        account.freeCollateral += collateralOut;
        totalCollateralReserved -= collateralShare;
        totalFeesAccrued += fee;
        _removeOpenInterest(market, position.side, sizeDelta);
        market.totalVolume += sizeDelta;
        if (position.size == 0) {
            delete positions[trader][marketId];
        } else if (position.collateral == 0 || (position.size * BPS) / position.collateral > market.risk.maxLeverageBps) {
            revert MaxLeverageExceeded();
        }
        emit PositionDecreased(trader, marketId, sizeDelta, collateralOut, price, pnl, fee);
    }

    function _updateFunding(uint256 marketId) internal {
        Market storage market = _market(marketId);
        uint256 elapsed = block.timestamp - market.lastFundingTime;
        if (elapsed == 0) return;
        uint256 totalOi = market.longOpenInterest + market.shortOpenInterest;
        if (totalOi == 0) {
            market.lastFundingTime = block.timestamp;
            return;
        }
        int256 skew = int256(market.longOpenInterest) - int256(market.shortOpenInterest);
        int256 skewBps = (skew * int256(BPS)) / int256(totalOi);
        int256 rateBps = (skewBps * int256(market.risk.fundingFactorBps) * int256(elapsed)) / int256(1 days) / int256(BPS);
        if (rateBps > int256(MAX_FUNDING_RATE_BPS)) rateBps = int256(MAX_FUNDING_RATE_BPS);
        if (rateBps < -int256(MAX_FUNDING_RATE_BPS)) rateBps = -int256(MAX_FUNDING_RATE_BPS);
        int256 fundingDelta = (rateBps * int256(FUNDING_PRECISION)) / int256(BPS);
        market.cumulativeFundingLong += fundingDelta;
        market.cumulativeFundingShort -= fundingDelta;
        market.lastFundingTime = block.timestamp;
        emit FundingUpdated(marketId, market.cumulativeFundingLong, market.cumulativeFundingShort, block.timestamp);
    }

    function _calculatePnl(Side side, uint256 size, uint256 entryPrice, uint256 exitPrice) internal pure returns (int256) {
        if (entryPrice == 0 || exitPrice == 0) return 0;
        if (side == Side.Long) {
            if (exitPrice >= entryPrice) return int256((size * (exitPrice - entryPrice)) / entryPrice);
            return -int256((size * (entryPrice - exitPrice)) / entryPrice);
        }
        if (exitPrice <= entryPrice) return int256((size * (entryPrice - exitPrice)) / entryPrice);
        return -int256((size * (exitPrice - entryPrice)) / entryPrice);
    }

    function _pendingFundingPayment(Market storage market, Position storage position) internal view returns (int256) {
        if (position.size == 0) return 0;
        int256 currentFunding = position.side == Side.Long ? market.cumulativeFundingLong : market.cumulativeFundingShort;
        int256 fundingDelta = currentFunding - position.entryFunding;
        return (int256(position.size) * fundingDelta) / int256(FUNDING_PRECISION);
    }

    function _calculateTradingFee(Market storage market, uint256 sizeDelta, bool increase) internal view returns (uint256) {
        uint256 feeBps = increase ? market.risk.takerFeeBps : market.risk.makerFeeBps;
        return (sizeDelta * feeBps) / BPS;
    }

    function _validateRiskParams(RiskParams calldata risk) internal pure {
        if (risk.maxLeverageBps < BPS || risk.maxLeverageBps > 100 * BPS) revert InvalidRiskParams();
        if (risk.maintenanceMarginBps == 0 || risk.maintenanceMarginBps > BPS) revert InvalidRiskParams();
        if (risk.liquidationFeeBps > BPS / 2) revert InvalidRiskParams();
        if (risk.takerFeeBps > BPS / 10 || risk.makerFeeBps > BPS / 10) revert InvalidRiskParams();
        if (risk.maxOpenInterest == 0) revert InvalidRiskParams();
        if (risk.maxSkewBps > BPS) revert InvalidRiskParams();
        if (risk.fundingFactorBps > MAX_FUNDING_RATE_BPS) revert InvalidRiskParams();
        if (risk.stalePriceDelay == 0 || risk.stalePriceDelay > MAX_STALE_PRICE_DELAY) revert InvalidRiskParams();
    }

    function _validateOpenInterest(Market storage market) internal view {
        if (market.longOpenInterest > market.risk.maxOpenInterest) revert MaxOpenInterestExceeded();
        if (market.shortOpenInterest > market.risk.maxOpenInterest) revert MaxOpenInterestExceeded();
        uint256 totalOi = market.longOpenInterest + market.shortOpenInterest;
        if (totalOi == 0) return;
        uint256 skew = market.longOpenInterest > market.shortOpenInterest ? market.longOpenInterest - market.shortOpenInterest : market.shortOpenInterest - market.longOpenInterest;
        uint256 skewBps = (skew * BPS) / totalOi;
        if (skewBps > market.risk.maxSkewBps) revert MaxOpenInterestExceeded();
    }

    function _addOpenInterest(Market storage market, Side side, uint256 amount) internal {
        if (side == Side.Long) market.longOpenInterest += amount;
        else if (side == Side.Short) market.shortOpenInterest += amount;
        else revert InvalidSide();
    }

    function _removeOpenInterest(Market storage market, Side side, uint256 amount) internal {
        if (side == Side.Long) {
            market.longOpenInterest = amount > market.longOpenInterest ? 0 : market.longOpenInterest - amount;
        } else if (side == Side.Short) {
            market.shortOpenInterest = amount > market.shortOpenInterest ? 0 : market.shortOpenInterest - amount;
        } else {
            revert InvalidSide();
        }
    }

    function _assertFreshPrice(Market storage market) internal view {
        if (market.indexPrice == 0) revert InvalidPrice();
        if (block.timestamp > market.lastPriceUpdate + market.risk.stalePriceDelay) revert StalePrice();
    }

    function _effectivePrice(Market storage market) internal view returns (uint256) {
        if (market.status == MarketStatus.Settled) return market.settlementPrice;
        return market.indexPrice;
    }

    function _market(uint256 marketId) internal view returns (Market storage market) {
        market = markets[marketId];
        if (market.status == MarketStatus.Disabled && bytes(market.symbol).length == 0) revert InvalidMarket();
    }

    function _checkAcceptableIncreasePrice(Side side, uint256 price, uint256 acceptablePrice) internal pure {
        if (acceptablePrice == 0) return;
        if (side == Side.Long && price > acceptablePrice) revert PriceSlippage();
        if (side == Side.Short && price < acceptablePrice) revert PriceSlippage();
    }

    function _checkAcceptableDecreasePrice(Side side, uint256 price, uint256 acceptablePrice) internal pure {
        if (acceptablePrice == 0) return;
        if (side == Side.Long && price < acceptablePrice) revert PriceSlippage();
        if (side == Side.Short && price > acceptablePrice) revert PriceSlippage();
    }

    function _settlePayout(uint256 collateral, int256 pnl) internal pure returns (uint256) {
        int256 payout = int256(collateral) + pnl;
        return payout > 0 ? uint256(payout) : 0;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
