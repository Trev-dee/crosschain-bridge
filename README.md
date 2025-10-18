# CrossChain BTC-STX Bridge

A secure and efficient cross-chain bridge implementation for Bitcoin-Stacks using Clarity v2.

## Overview

This smart contract enables trustless bridging between Bitcoin and Stacks chains through a wrapped BTC (wBTC) token implementation. The bridge uses an oracle-based architecture for secure minting and burning operations.

## Features

- **Wrapped BTC Token**: Native fungible token implementation (wBTC)
- **Secure Minting**: Controlled by authorized oracle with replay protection
- **Burn Mechanism**: User-initiated burns for BTC redemption
- **Fee System**: Configurable burn fees in basis points
- **Security Features**:
  - Unique request ID validation
  - Single trusted oracle architecture
  - Emergency pause mechanism
  - Treasury integration for fee collection

## Contract Functions

### Admin Operations
- `set-oracle`: Update authorized oracle address
- `set-treasury`: Set fee collection address
- `set-burn-fee-bps`: Configure burn fee (max 1000 bps/10%)
- `pause/unpause`: Emergency controls

### Core Bridge Operations
- `mint`: Oracle-controlled minting of wBTC
- `burn`: User-initiated burning for BTC redemption
- `confirm-burn`: Oracle confirmation of BTC release

### View Functions
- `get-burn-request`: Retrieve burn request details
- `is-request-processed`: Check request processing status
- `get-wbtc-balance`: Query token balances
- `bridge-stats`: Get bridge configuration and state

## Security Considerations

- Single oracle design for controlled minting
- Unique request IDs prevent replay attacks
- Configurable fee mechanism
- Emergency pause functionality
- Clear state transitions for burn requests

## Testing

Run tests using Clarinet:
```bash
clarinet test
```
