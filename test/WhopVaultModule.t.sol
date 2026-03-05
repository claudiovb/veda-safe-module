// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WhopVaultModule} from "../src/WhopVaultModule.sol";
import {Enum} from "@safe/libraries/Enum.sol";

// Minimal Safe interface for test setup
interface ISafe {
    function setup(
        address[] calldata _owners,
        uint256 _threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    function enableModule(address module) external;

    function isModuleEnabled(address module) external view returns (bool);

    function getOwners() external view returns (address[] memory);

    function getThreshold() external view returns (uint256);
}

interface IRolesAuthority {
    function owner() external view returns (address);

    function setUserRole(address user, uint8 role, bool enabled) external;

    function setRoleCapability(
        uint8 role,
        address target,
        bytes4 functionSig,
        bool enabled
    ) external;
}

interface IAuth {
    function authority() external view returns (address);
}

contract WhopVaultModuleTest is Test {
    // ── Mainnet addresses ──────────────────────────────────────────────
    address constant BORING_VAULT =
        0xd1074E0AE85610dDBA0147e29eBe0D8E5873a000;
    address constant TELLER = 0x4E7d2186eB8B75fBDcA867761636637E05BaeF1E;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    address constant SAFE_SINGLETON =
        0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address constant SAFE_PROXY_FACTORY =
        0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;

    address constant USDT_WHALE = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    uint8 constant SOLVER_ROLE = 12;

    // ── Test state ─────────────────────────────────────────────────────
    ISafe public safe;
    WhopVaultModule public module;

    // wdkSigner = user's key (Safe owner, created via Whop WDK)
    // whopBackend = Whop's backend signer (calls the module on behalf of user)
    address public wdkSigner;
    address public whopBackend;

    // ── Setup ──────────────────────────────────────────────────────────

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        wdkSigner = makeAddr("wdkSigner");
        whopBackend = makeAddr("whopBackend");

        // ── Deploy Safe proxy (user's wallet) ───────────────────────
        address[] memory owners = new address[](1);
        owners[0] = wdkSigner;

        bytes memory setupData = abi.encodeWithSelector(
            ISafe.setup.selector,
            owners,
            uint256(1),
            address(0),
            "",
            address(0),
            address(0),
            uint256(0),
            payable(address(0))
        );

        (bool ok, bytes memory ret) = SAFE_PROXY_FACTORY.call(
            abi.encodeWithSignature(
                "createProxyWithNonce(address,bytes,uint256)",
                SAFE_SINGLETON,
                setupData,
                block.timestamp
            )
        );
        require(ok, "Safe proxy creation failed");
        safe = ISafe(abi.decode(ret, (address)));

        assertEq(safe.getThreshold(), 1);
        assertEq(safe.getOwners()[0], wdkSigner);

        // ── Deploy the singleton WhopVaultModule ────────────────────
        address[] memory tellers = new address[](1);
        tellers[0] = TELLER;
        module = new WhopVaultModule(whopBackend, tellers);

        // ── User (wdkSigner) enables the module on their Safe ───────
        vm.prank(address(safe));
        safe.enableModule(address(module));
        assertTrue(safe.isModuleEnabled(address(module)));

        // ── Grant Safe the SOLVER_ROLE for bulkWithdraw ─────────────
        _grantBulkWithdrawRole();

        // ── Fund the Safe with USDT ─────────────────────────────────
        uint256 fundAmount = 100_000 * 1e6;
        vm.prank(USDT_WHALE);
        (bool txOk,) = USDT.call(
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                address(safe),
                fundAmount
            )
        );
        require(txOk, "USDT funding failed");
        assertGe(IERC20(USDT).balanceOf(address(safe)), fundAmount);
    }

    // ── Test 1: Successful deposit ─────────────────────────────────────

    function test_depositToVault_succeeds() public {
        uint256 depositAmount = 10_000 * 1e6;
        uint256 usdtBefore = IERC20(USDT).balanceOf(address(safe));
        uint256 sharesBefore = IERC20(BORING_VAULT).balanceOf(address(safe));

        vm.prank(whopBackend);
        module.depositToVault(address(safe), USDT, depositAmount, TELLER);

        uint256 usdtAfter = IERC20(USDT).balanceOf(address(safe));
        uint256 sharesAfter = IERC20(BORING_VAULT).balanceOf(address(safe));

        assertEq(usdtBefore - usdtAfter, depositAmount, "USDT balance should decrease");
        assertGt(sharesAfter, sharesBefore, "Safe should receive vault shares");

        console2.log("Deposited USDT:", depositAmount / 1e6);
        console2.log("Vault shares received:", sharesAfter - sharesBefore);
    }

    // ── Test 2: Successful withdrawal ──────────────────────────────────

    function test_withdrawFromVault_succeeds() public {
        // Deposit first
        uint256 depositAmount = 10_000 * 1e6;
        vm.prank(whopBackend);
        module.depositToVault(address(safe), USDT, depositAmount, TELLER);

        uint256 shares = IERC20(BORING_VAULT).balanceOf(address(safe));
        assertGt(shares, 0, "Should have shares after deposit");

        // Withdraw all shares — funds return to the Safe (hardcoded in module)
        uint256 usdtBefore = IERC20(USDT).balanceOf(address(safe));

        vm.prank(whopBackend);
        module.withdrawFromVault(address(safe), USDT, TELLER, shares);

        uint256 usdtAfter = IERC20(USDT).balanceOf(address(safe));
        uint256 sharesAfter = IERC20(BORING_VAULT).balanceOf(address(safe));

        assertGt(usdtAfter, usdtBefore, "USDT should be returned to Safe");
        assertEq(sharesAfter, 0, "All shares should be redeemed");

        console2.log("USDT recovered:", (usdtAfter - usdtBefore) / 1e6);
    }

    // ── Test 3: Random address cannot call deposit ─────────────────────

    function test_depositToVault_reverts_notWhopBackend() public {
        address randomAddr = makeAddr("random");

        vm.prank(randomAddr);
        vm.expectRevert(WhopVaultModule.NotWhopBackend.selector);
        module.depositToVault(address(safe), USDT, 1_000 * 1e6, TELLER);
    }

    // ── Test 4: Deposit to non-whitelisted teller reverts ──────────────

    function test_depositToVault_reverts_tellerNotWhitelisted() public {
        address fakeTeller = makeAddr("fakeTeller");

        vm.prank(whopBackend);
        vm.expectRevert(WhopVaultModule.TellerNotWhitelisted.selector);
        module.depositToVault(address(safe), USDT, 1_000 * 1e6, fakeTeller);
    }

    // ── Test 5: Module cannot act on a Safe that hasn't enabled it ─────

    function test_reverts_safeNotEnabled() public {
        // Deploy a second Safe that does NOT enable the module
        address secondOwner = makeAddr("secondOwner");
        address[] memory owners = new address[](1);
        owners[0] = secondOwner;

        bytes memory setupData = abi.encodeWithSelector(
            ISafe.setup.selector,
            owners,
            uint256(1),
            address(0),
            "",
            address(0),
            address(0),
            uint256(0),
            payable(address(0))
        );

        (bool ok, bytes memory ret) = SAFE_PROXY_FACTORY.call(
            abi.encodeWithSignature(
                "createProxyWithNonce(address,bytes,uint256)",
                SAFE_SINGLETON,
                setupData,
                uint256(42) // different salt
            )
        );
        require(ok, "Second Safe creation failed");
        address nonEnabledSafe = abi.decode(ret, (address));

        // Module is NOT enabled on this Safe → execTransactionFromModule reverts (GS104)
        vm.prank(whopBackend);
        vm.expectRevert();
        module.depositToVault(nonEnabledSafe, USDT, 1_000 * 1e6, TELLER);
    }

    // ── Helpers ────────────────────────────────────────────────────────

    function _grantBulkWithdrawRole() internal {
        address authority = IAuth(TELLER).authority();
        IRolesAuthority auth = IRolesAuthority(authority);
        address authOwner = auth.owner();

        bytes4 bulkWithdrawSig = bytes4(
            keccak256("bulkWithdraw(address,uint256,uint256,address)")
        );

        vm.startPrank(authOwner);
        auth.setRoleCapability(SOLVER_ROLE, TELLER, bulkWithdrawSig, true);
        auth.setUserRole(address(safe), SOLVER_ROLE, true);
        vm.stopPrank();
    }
}
