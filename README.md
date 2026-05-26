# ChainPerps
A mock perpetual futures trading protocol written in Solidity for research, testing, local simulations, educational environments, and smart contract auditing practice.

ChainPerps implements a simplified on-chain perpetual exchange architecture with isolated margin positions, configurable market risk parameters, funding rate accounting, liquidation mechanics, and administrative controls.

This repository is intended for development and experimentation purposes only.

Features
Isolated perpetual positions
Long and short market exposure
Collateral management
Configurable leverage limits
Funding rate accounting
Liquidation engine
Open interest tracking
Market skew protection
Insurance fund accounting
Oracle price update hooks
Reduce-only and settled market modes
Executor approvals for delegated order execution
Fee accrual and treasury management
Pause controls and emergency administration

Architecture Overview

The protocol is implemented as a single primary contract:
ChainPerps.sol


The contract manages:

User collateral balances
Market creation and configuration
Position lifecycle management
Funding updates
Margin validation
Liquidation eligibility
Insurance accounting
Trading fee collection


Core Components
Markets

Each market maintains:

Index price
Open interest
Funding state
Market status
Risk parameters
Settlement state

Supported market states:

enum MarketStatus {
    Disabled,
    Active,
    ReduceOnly,
    Settled
}
Positions

Each trader position stores:

Position side
Position size
Collateral backing
Entry price
Funding checkpoint
Realized PnL
Position timestamps

Supported position sides:

enum Side {
    None,
    Long,
    Short
}
Funding

Funding is periodically updated based on market skew between longs and shorts.

The funding mechanism:

Tracks cumulative funding values
Applies directional payments
Encourages balanced open interest
Supports positive and negative funding
Liquidations

Positions become liquidatable when:

Margin Value < Maintenance Margin + Liquidation Fees

Liquidation flow:

Position health validation
Open interest reduction
Fee accounting
Liquidator reward payout
Insurance fund settlement
Risk Engine

Each market exposes configurable risk parameters:

Maximum leverage
Maintenance margin
Liquidation fees
Trading fees
Open interest caps
Maximum skew
Funding factors
Price staleness windows
OpenZeppelin Dependencies

The contract utilizes OpenZeppelin libraries and security modules:

IERC20
SafeERC20
Ownable
Pausable
ReentrancyGuard
Compiler
Solidity 0.8.30
Example Workflow
Deposit Collateral
deposit(uint256 amount)
Open Position
increasePosition(
    marketId,
    side,
    sizeDelta,
    collateralDelta,
    acceptablePrice
)
Reduce Position
decreasePosition(
    marketId,
    sizeDelta,
    acceptablePrice
)
Liquidate Position
liquidate(trader, marketId)
Administrative Functions

Owner and keeper roles can:

Create markets
Update prices
Configure risk limits
Pause protocol actions
Settle markets
Update treasury addresses
Configure fee receivers
Update insurance fund addresses
Security Notes

This repository is intentionally simplified and should not be considered production-ready.

The implementation omits many real-world production requirements, including but not limited to:

Robust oracle integrations
Cross-margin accounting
Advanced liquidation routing
Governance frameworks
Timelock protections
Multi-signature administration
Formal verification
MEV mitigation
Sophisticated funding models
Advanced execution logic
Intended Usage

This project is suitable for:

Smart contract auditing practice
Local EVM testing
Solidity experimentation
Educational demonstrations
Security research
Mock trading simulations
Foundry integration tests
Static analysis tooling
License
MIT
Solidity custom errors
OpenZeppelin security primitives
