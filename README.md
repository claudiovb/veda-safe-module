# WhopVaultModule — Safe Module POC

Proof of concept: a **singleton** Safe Module that restricts the Whop backend to only deposit/withdraw USDT into a [Veda BoringVault](https://docs.veda.tech/) on Ethereum mainnet.

## What this proves

- A single module deployment works with **any number of user Safes** — no per-user deployment needed
- The Whop backend (`whopBackend`) can execute scoped DeFi actions on behalf of users
- The user (`wdkSigner`) must sign `enableModule` once to grant Whop permission — this is the consent step
- The user can always interact with Veda directly via normal Safe transactions without the module
- The module enforces:
  - **Only `whopBackend`** can trigger deposits/withdrawals
  - **Only whitelisted Teller contracts** — unknown addresses revert
  - **Withdrawals only go back to the Safe** — `to` is validated, funds can never be routed elsewhere
  - **No other external functions** exist that can move funds

## Architecture

```
                         ┌─────────────────────┐
  Whop Backend ──call──> │  WhopVaultModule     │ (singleton, deployed once)
                         │  (enabled on Safe)   │
                         └──────────┬───────────┘
                                    │ execTransactionFromModule
                         ┌──────────▼───────────┐
                         │  User's Safe (WDK)    │
                         │  owner = wdkSigner    │
                         └──────────┬───────────┘
                                    │ approve + deposit / bulkWithdraw
                         ┌──────────▼───────────┐
                         │  Veda Teller + Vault  │
                         └──────────────────────┘
```

## Flow

1. **Onboarding**: User's Safe is created via WDK. User signs one `enableModule(whopVaultModule)` transaction.
2. **Deposit**: Whop backend calls `module.depositToVault(safeAddr, USDT, amount, teller)`.
3. **Withdraw**: Whop backend calls `module.withdrawFromVault(safeAddr, USDT, teller, shares, safeAddr)`.

## Mainnet addresses

| Contract | Address |
|---|---|
| Veda BoringVault (PlasmaUSD) | `0xd1074E0AE85610dDBA0147e29eBe0D8E5873a000` |
| Veda Teller (LayerZeroTeller) | `0x4E7d2186eB8B75fBDcA867761636637E05BaeF1E` |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| Safe Singleton v1.4.1 | `0x41675C099F32341bf84BFc5382aF534df5C7461a` |
| Safe ProxyFactory v1.4.1 | `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67` |

## Run

```bash
MAINNET_RPC_URL=<your_rpc> forge test -vvv
```

## Tests

| # | Test | Checks |
|---|---|---|
| 1 | `test_depositToVault_succeeds` | USDT decreases, vault shares received |
| 2 | `test_withdrawFromVault_succeeds` | Shares redeemed, USDT returned to Safe |
| 3 | `test_depositToVault_reverts_notWhopBackend` | Random address cannot deposit |
| 4 | `test_depositToVault_reverts_tellerNotWhitelisted` | Non-whitelisted teller reverts |
| 5 | `test_withdrawFromVault_reverts_notToSafe` | Withdraw to non-Safe address reverts |

## Note on withdrawals

Veda's `bulkWithdraw` is role-gated via their on-chain `RolesAuthority`. In the fork test we grant `SOLVER_ROLE` to the Safe using `vm.prank`. In production the Safe would need this role from Veda, or withdrawals would go through Veda's AtomicQueue instead.
