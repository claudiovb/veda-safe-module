// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Enum} from "@safe/libraries/Enum.sol";

/// @dev Minimal interface for Safe module execution.
interface IGnosisSafe {
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation
    ) external returns (bool success);
}

/// @dev Minimal interface for Veda's TellerWithMultiAssetSupport.
interface ITeller {
    function deposit(
        IERC20 depositAsset,
        uint256 depositAmount,
        uint256 minimumMint
    ) external payable returns (uint256 shares);

    function bulkWithdraw(
        IERC20 withdrawAsset,
        uint256 shareAmount,
        uint256 minimumAssets,
        address to
    ) external returns (uint256 assetsOut);

    function vault() external view returns (address);
}

/// @title WhopVaultModule
/// @notice Singleton Safe Module — deployed once, works with any Safe that enables it.
///         Restricts the Whop backend to only deposit/withdraw into whitelisted Veda vaults.
///
/// @dev Security model:
///      - Only `whopBackend` can call depositToVault / withdrawFromVault.
///      - Only whitelisted Teller contracts are accepted.
///      - Withdrawals always return funds to the same Safe that holds the shares.
///        The `safeAddr` passed to each function is used both as the Safe to call
///        execTransactionFromModule on AND as the `to` in the Teller's bulkWithdraw.
///        There is no separate recipient parameter — funds cannot be routed elsewhere.
///      - execTransactionFromModule reverts (GS104) if the Safe hasn't enabled this module,
///        so `safeAddr` can only be a Safe whose owner has consented.
///      - The Safe owner (wdkSigner) does NOT need this module to interact with Veda —
///        they can always sign a normal Safe transaction directly.
///      - This module is compatible with Safes that have the Safe4337Module enabled.
///        Both modules sit in the Safe's module linked list independently.
///        The 4337 module only activates via the fallback handler (UserOp path from EntryPoint),
///        while this module calls execTransactionFromModule directly — separate code paths.
///
/// @dev POC limitations (production would need to address):
///      - `whopBackend` is immutable — no key rotation. If compromised, every Safe must
///        call disableModule and migrate to a redeployed module with a fresh key.
///      - `whitelistedTellers` is set once at construction — no way to add/remove tellers.
///        If a teller is deprecated or a new vault launches, requires redeployment + migration.
///      - No token whitelist — `whopBackend` can pass any address as `token`. If the backend
///        key is compromised, the attacker can make enabled Safes call `approve` on arbitrary
///        contracts. Production should restrict to a set of known tokens (e.g. USDT, USDC).
///      - minimumMint / minimumAssets are hardcoded to 0 (no slippage protection).
///        Production should accept these as parameters to guard against sandwich attacks.
contract WhopVaultModule {
    error NotWhopBackend();
    error TellerNotWhitelisted();

    address public immutable whopBackend;
    mapping(address => bool) public whitelistedTellers;

    constructor(address _whopBackend, address[] memory _whitelistedTellers) {
        whopBackend = _whopBackend;
        for (uint256 i = 0; i < _whitelistedTellers.length; i++) {
            whitelistedTellers[_whitelistedTellers[i]] = true;
        }
    }

    modifier onlyWhopBackend() {
        if (msg.sender != whopBackend) revert NotWhopBackend();
        _;
    }

    /// @notice Deposit tokens from a Safe into a Veda vault via the Teller.
    /// @dev The Safe must have enabled this module via enableModule first.
    ///      execTransactionFromModule will revert with GS104 if not enabled.
    /// @param safeAddr The Safe to act on behalf of.
    /// @param token    ERC20 token to deposit (e.g. USDT).
    /// @param amount   Amount in token decimals.
    /// @param teller   Whitelisted Teller contract address.
    function depositToVault(
        address safeAddr,
        address token,
        uint256 amount,
        address teller
    ) external onlyWhopBackend {
        if (!whitelistedTellers[teller]) revert TellerNotWhitelisted();

        address vault = ITeller(teller).vault();

        // USDT requires resetting approval to 0 first (non-standard ERC20).
        _exec(safeAddr, token, abi.encodeWithSelector(IERC20.approve.selector, vault, 0));
        _exec(safeAddr, token, abi.encodeWithSelector(IERC20.approve.selector, vault, amount));

        // Deposit through the Teller — shares are minted to the Safe.
        _exec(
            safeAddr,
            teller,
            abi.encodeWithSelector(
                ITeller.deposit.selector,
                IERC20(token),
                amount,
                uint256(0)
            )
        );

        // Clear residual approval. If deposit consumed less than `amount` (e.g. vault cap,
        // rounding), leftover approval on the vault would persist. Reset to 0 for safety.
        _exec(safeAddr, token, abi.encodeWithSelector(IERC20.approve.selector, vault, 0));
    }

    /// @notice Withdraw assets from a Veda vault back to the Safe.
    /// @dev Funds always return to `safeAddr` — the same Safe whose shares are burned.
    ///      There is no separate recipient parameter by design.
    /// @param safeAddr The Safe to act on behalf of (also the recipient).
    /// @param token    ERC20 asset to receive (e.g. USDT).
    /// @param teller   Whitelisted Teller contract address.
    /// @param shares   Number of vault shares to redeem.
    function withdrawFromVault(
        address safeAddr,
        address token,
        address teller,
        uint256 shares
    ) external onlyWhopBackend {
        if (!whitelistedTellers[teller]) revert TellerNotWhitelisted();

        // safeAddr is both the caller of bulkWithdraw (via execTransactionFromModule)
        // and the recipient of withdrawn assets — no way to split these.
        _exec(
            safeAddr,
            teller,
            abi.encodeWithSelector(
                ITeller.bulkWithdraw.selector,
                IERC20(token),
                shares,
                uint256(0),
                safeAddr
            )
        );
    }

    /// @dev Execute a call from the given Safe via the module interface.
    function _exec(address safeAddr, address to, bytes memory data) internal {
        bool success = IGnosisSafe(safeAddr).execTransactionFromModule(
            to, 0, data, Enum.Operation.Call
        );
        require(success, "module exec failed");
    }
}
