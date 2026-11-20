// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PayReceipt} from "../src/PayReceipt.sol";
import {MockTUSD8} from "./MockTUSD8.sol";

/// @dev Minimal hand-rolled cheatcode interface (the well-known Foundry Vm
///      address), so the test suite needs no external dependencies at all.
interface Vm {
    function prank(address msgSender) external;
    function warp(uint256 newTimestamp) external;
    function expectRevert(bytes calldata revertData) external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert() external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData, address emitter)
        external;
}

contract PayReceiptTest {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // Re-declared so expectEmit can compare against them.
    event InvoicePaid(
        uint256 indexed invoiceId, address indexed payer, address indexed payee, uint256 amount, uint64 paidAt
    );
    event InvoiceRefunded(uint256 indexed invoiceId, address indexed merchant, address indexed payer, uint256 amount);

    address internal merchant = address(0x1001);
    address internal payee = address(0x1002);
    address internal payer = address(0x1003);
    address internal stranger = address(0x1004);

    uint256 internal constant AMOUNT = 250_000_000; // 250 tUSD8 (6 decimals)
    uint64 internal constant T0 = 1_700_000_000;
    uint64 internal constant EXPIRY = T0 + 7 days;

    MockTUSD8 internal token;
    PayReceipt internal receipt;

    function setUp() public {
        vm.warp(T0);
        token = new MockTUSD8();
        receipt = new PayReceipt(address(token));
        token.mint(payer, 1_000_000_000); // 1,000 tUSD8
        token.mint(merchant, 1_000_000_000); // merchant funds for refunds
    }

    // --- helpers -------------------------------------------------------------

    function _create() internal returns (uint256 id) {
        vm.prank(merchant);
        id = receipt.createInvoice(payee, "Sari's Bakery", AMOUNT, "INV-2026-001", EXPIRY);
    }

    function _pay(uint256 id) internal {
        vm.prank(payer);
        token.approve(address(receipt), AMOUNT);
        vm.prank(payer);
        receipt.payInvoice(id);
    }

    function _status(uint256 id) internal view returns (PayReceipt.Status status) {
        (,,,,,, status,,,) = receipt.getInvoice(id);
    }

    function assertEq(uint256 a, uint256 b, string memory what) internal pure {
        if (a != b) revert(string.concat("assertEq failed: ", what));
    }

    function assertEq(address a, address b, string memory what) internal pure {
        if (a != b) revert(string.concat("assertEq failed: ", what));
    }

    function assertTrue(bool cond, string memory what) internal pure {
        if (!cond) revert(string.concat("assertTrue failed: ", what));
    }

    // --- creation --------------------------------------------------------------

    function test_CreateInvoice_StoresAllFields() public {
        uint256 id = _create();
        assertEq(id, 1, "first id is 1");
        assertEq(receipt.invoiceCount(), 1, "invoiceCount");

        (
            address m,
            address p,
            string memory payeeName,
            uint256 amount,
            string memory memo,
            uint64 expiry,
            PayReceipt.Status status,
            address recordedPayer,
            uint64 paidAt,
            bool expired
        ) = receipt.getInvoice(id);

        assertEq(m, merchant, "merchant");
        assertEq(p, payee, "payee");
        assertTrue(keccak256(bytes(payeeName)) == keccak256(bytes("Sari's Bakery")), "payeeName (CoP)");
        assertEq(amount, AMOUNT, "amount");
        assertTrue(keccak256(bytes(memo)) == keccak256(bytes("INV-2026-001")), "memo");
        assertEq(expiry, EXPIRY, "expiry");
        assertTrue(status == PayReceipt.Status.Open, "status Open");
        assertEq(recordedPayer, address(0), "payer unset");
        assertEq(paidAt, 0, "paidAt unset");
        assertTrue(!expired, "not expired");
        assertTrue(receipt.isPayable(id), "isPayable");
    }

    function test_CreateInvoice_ZeroAmountReverts() public {
        vm.prank(merchant);
        vm.expectRevert(PayReceipt.ZeroAmount.selector);
        receipt.createInvoice(payee, "Sari's Bakery", 0, "INV-0", EXPIRY);
    }

    function test_CreateInvoice_ZeroPayeeReverts() public {
        vm.prank(merchant);
        vm.expectRevert(PayReceipt.ZeroAddress.selector);
        receipt.createInvoice(address(0), "Nobody", AMOUNT, "INV-0", EXPIRY);
    }

    function test_CreateInvoice_PastExpiryReverts() public {
        vm.prank(merchant);
        vm.expectRevert(PayReceipt.ExpiryNotInFuture.selector);
        receipt.createInvoice(payee, "Sari's Bakery", AMOUNT, "INV-0", T0); // == now, not future
    }

    // --- payment ---------------------------------------------------------------

    function test_PayInvoice_ExactPaymentAndReceipt() public {
        uint256 id = _create();
        uint256 payerBefore = token.balanceOf(payer);
        uint256 payeeBefore = token.balanceOf(payee);

        vm.prank(payer);
        token.approve(address(receipt), AMOUNT);

        vm.expectEmit(true, true, true, true, address(receipt));
        emit InvoicePaid(id, payer, payee, AMOUNT, T0);
        vm.prank(payer);
        receipt.payInvoice(id);

        // Exactly the invoiced amount moved — no more, no less.
        assertEq(token.balanceOf(payer), payerBefore - AMOUNT, "payer debited exactly");
        assertEq(token.balanceOf(payee), payeeBefore + AMOUNT, "payee credited exactly");

        (,,,,,, PayReceipt.Status status, address recordedPayer, uint64 paidAt,) = receipt.getInvoice(id);
        assertTrue(status == PayReceipt.Status.Paid, "status Paid");
        assertEq(recordedPayer, payer, "payer recorded");
        assertEq(paidAt, T0, "paidAt recorded");
        assertTrue(!receipt.isPayable(id), "no longer payable");
    }

    function test_PayInvoice_DoublePaymentReverts() public {
        uint256 id = _create();
        _pay(id);

        // Idempotency: a second payment attempt must revert, funds untouched.
        vm.prank(payer);
        token.approve(address(receipt), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(PayReceipt.NotOpen.selector, id, PayReceipt.Status.Paid));
        vm.prank(payer);
        receipt.payInvoice(id);
    }

    function test_PayInvoice_WithoutApprovalReverts() public {
        uint256 id = _create();
        vm.expectRevert(); // mock token: insufficient allowance
        vm.prank(payer);
        receipt.payInvoice(id);
        assertTrue(_status(id) == PayReceipt.Status.Open, "still Open after failed pay");
    }

    function test_PayInvoice_UnknownIdReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PayReceipt.InvoiceNotFound.selector, 999));
        vm.prank(payer);
        receipt.payInvoice(999);
    }

    function test_PayInvoice_AfterExpiryReverts() public {
        uint256 id = _create();
        vm.warp(EXPIRY + 1);

        (,,,,,,,,, bool expired) = receipt.getInvoice(id);
        assertTrue(expired, "expired flag computed at read time");
        assertTrue(!receipt.isPayable(id), "not payable after expiry");

        vm.prank(payer);
        token.approve(address(receipt), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(PayReceipt.InvoiceExpired.selector, id, EXPIRY));
        vm.prank(payer);
        receipt.payInvoice(id);
    }

    function test_PayInvoice_AtExactExpirySucceeds() public {
        uint256 id = _create();
        vm.warp(EXPIRY); // boundary: expiry is inclusive
        _pay(id);
        assertTrue(_status(id) == PayReceipt.Status.Paid, "paid at expiry boundary");
    }

    // --- cancel ------------------------------------------------------------------

    function test_CancelInvoice_ByMerchant() public {
        uint256 id = _create();
        vm.prank(merchant);
        receipt.cancelInvoice(id);
        assertTrue(_status(id) == PayReceipt.Status.Cancelled, "status Cancelled");
        assertTrue(!receipt.isPayable(id), "cancelled not payable");
    }

    function test_CancelInvoice_NonMerchantReverts() public {
        uint256 id = _create();
        vm.expectRevert(abi.encodeWithSelector(PayReceipt.NotMerchant.selector, id, stranger));
        vm.prank(stranger);
        receipt.cancelInvoice(id);
    }

    function test_PayInvoice_AfterCancelReverts() public {
        uint256 id = _create();
        vm.prank(merchant);
        receipt.cancelInvoice(id);

        vm.prank(payer);
        token.approve(address(receipt), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(PayReceipt.NotOpen.selector, id, PayReceipt.Status.Cancelled));
        vm.prank(payer);
        receipt.payInvoice(id);
    }

    // --- refund ------------------------------------------------------------------

    function test_RefundInvoice_ReturnsFundsToPayerAndLocks() public {
        uint256 id = _create();
        _pay(id);
        uint256 payerAfterPay = token.balanceOf(payer);

        vm.prank(merchant);
        token.approve(address(receipt), AMOUNT);

        vm.expectEmit(true, true, true, true, address(receipt));
        emit InvoiceRefunded(id, merchant, payer, AMOUNT);
        vm.prank(merchant);
        receipt.refundInvoice(id);

        assertEq(token.balanceOf(payer), payerAfterPay + AMOUNT, "payer made whole");
        assertTrue(_status(id) == PayReceipt.Status.Refunded, "status Refunded");

        // Locked: cannot be paid again, cannot be refunded twice.
        vm.prank(payer);
        token.approve(address(receipt), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(PayReceipt.NotOpen.selector, id, PayReceipt.Status.Refunded));
        vm.prank(payer);
        receipt.payInvoice(id);

        vm.expectRevert(abi.encodeWithSelector(PayReceipt.NotPaid.selector, id, PayReceipt.Status.Refunded));
        vm.prank(merchant);
        receipt.refundInvoice(id);
    }

    function test_RefundInvoice_NonMerchantReverts() public {
        uint256 id = _create();
        _pay(id);
        vm.expectRevert(abi.encodeWithSelector(PayReceipt.NotMerchant.selector, id, stranger));
        vm.prank(stranger);
        receipt.refundInvoice(id);
    }

    function test_RefundInvoice_OpenInvoiceReverts() public {
        uint256 id = _create();
        vm.expectRevert(abi.encodeWithSelector(PayReceipt.NotPaid.selector, id, PayReceipt.Status.Open));
        vm.prank(merchant);
        receipt.refundInvoice(id);
    }
}
