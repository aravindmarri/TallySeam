import Foundation
import XCTest
@testable import TallySeam

/// Statement layouts seen in real bank PDFs, rebuilt with made-up merchants and amounts.
final class StatementLayoutTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    private func preview(_ lines: [String]) -> StatementPreview {
        StatementImportService.preview(text: DocumentText(pages: [DocumentPage(index: 0, lines: lines, source: .plainText)]),
                                       format: .text, defaultCurrency: "USD", calendar: cal)
    }

    func testMinusSpaceDollarIsANegativeAmount() {
        let t = MoneyText.tokens(in: "Sep 22 Sep 22 SAMPLE BANK MOBILE PYMT - $360.02")
        XCTAssertEqual(t.last?.value, -36_002)
        XCTAssertEqual(MoneyText.tokens(in: "Something - 12.50").last?.value, 1_250, "a dash without $ stays a separator")
    }

    /// Card statement where payments and credits print as "- $12.34" and the table has cardholder headings.
    func testCardPaymentsWithSpacedMinusAreMoneyIn() {
        let p = preview([
            "Account Summary",
            "Previous Balance $200.00",
            "Payments - $150.00",
            "New Balance = $95.00",
            "Credit Limit $1,000.00",
            "Payment Due Date",
            "Nov 07, 2026",
            "Minimum Payment Due $25.00",
            "Sep 13, 2026 - Oct 13, 2026   |  31 days in Billing Cycle",
            "Trans Date Post Date Description Amount",
            "Sep 22 Sep 22 SAMPLE BANK MOBILE PYMT - $150.00",
            "Oct 1 Oct 2 GADGET MART ONLINE AR - $5.00",
            "JANE DOE #1234: Transactions",
            "Trans Date Post Date Description Amount",
            "Sep 15 Sep 17 TOWN SPORTS CLUB TX $20.00",
            "Sep 23 Sep 24 CORNER GROCERY TX $30.00",
            "JANE DOE #1234: Total Transactions $50.00",
        ])
        XCTAssertEqual(p.kind, .creditCardStatement)
        let lines = p.parse.lines
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(p.parse.totalIn, 15_500)
        XCTAssertEqual(p.parse.totalOut, 5_000)
        XCTAssertEqual(lines[0].kind, .cardPayment)
        XCTAssertEqual(lines[1].kind, .refund)
        XCTAssertEqual(lines[1].description, "GADGET MART ONLINE AR", "headings never join a description")
        XCTAssertTrue(p.parse.issues.isEmpty, "date-only lines are not flagged: \(p.parse.issues.map(\.text))")
    }

    /// Card statement that prints each purchase over several lines with the amount last.
    func testAmountTwoLinesBelowTheDescription() {
        let p = preview([
            "Closing Date 11/03/26",
            "Payment Due Date 11/28/26",
            "New Balance $60.00",
            "Minimum Payment Due $40.00",
            "Credit Limit $5,000.00",
            "Payments Amount",
            "10/04/26* MOBILE PAYMENT - THANK YOU -$100.00",
            "New Charges",
            "10/05/26 AplPay SAMPLE SUPERCENTER 1111 DENTON TX",
            "DISCOUNT STORE",
            "$45.10",
            "10/10/26 AplPay TOWN BAKERY LLC DENTON TX",
            "5550001111",
            "$6.40",
            "10/11/26 SAMPLE STREAMING SUBSCR SAN FRANCISCO CA",
            "$9.99",
        ])
        let lines = p.parse.lines
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0].direction, .moneyIn)
        XCTAssertEqual(lines.dropFirst().map(\.amountMinorUnits), [4_510, 640, 999])
        XCTAssertTrue(lines.dropFirst().allSatisfy { $0.direction == .moneyOut })
        XCTAssertTrue(lines[1].description.contains("DISCOUNT STORE"))
        XCTAssertTrue(p.parse.issues.isEmpty, "\(p.parse.issues.map(\.text))")
    }

    /// Checking statement with separate deposit and withdrawal columns: no signs, only the
    /// daily balance after the last line of each day. The balance decides in or out.
    func testRunningBalanceDecidesDepositsAndWithdrawals() {
        let p = preview([
            "Sample Bank Everyday Checking",
            "November 6, 2026         Page 1 of 2",
            "Statement period activity summary",
            "Beginning balance on 10/8 $1,000.00",
            "Deposits/Additions         2,050.00",
            "Withdrawals/Subtractions -  1,230.00",
            "Ending balance on 11/6  $1,820.00",
            "Transaction history",
            "Deposits/",
            "Additions",
            "Withdrawals/",
            "Subtractions",
            "Ending daily",
            "balance",
            "10/08   Zelle From Sample Friend on 10/08 Ref # AAA111     50.00",
            "10/08   Sample Utility Billpay     200.00     850.00",
            "10/20   Zelle From Other Friend on 10/20 Ref # BBB222     300.00",
            "10/20   Zelle to Roommate on 10/20 Ref # CCC333     300.00",
            "10/20   ATM Withdrawal authorized on 10/20 100 Main St",
            "Springfield IL ATM ID 0001 Card",
            "1111",
            "   100.00",
            "10/20   ATM Transaction Fee     3.00     747.00",
            "10/26   Sample Employer Payroll 261026 000111",
            "Doe,Jane",
            "1,700.00",
            "10/26   Online Savings Transfer     627.00     1,820.00",
        ])
        XCTAssertEqual(p.kind, .bankStatement)
        XCTAssertEqual(p.header.totalDeposits, 205_000)
        XCTAssertEqual(p.header.totalWithdrawals, 123_000)
        let lines = p.parse.lines
        XCTAssertEqual(lines.count, 8)
        XCTAssertEqual(p.parse.totalIn, 205_000)
        XCTAssertEqual(p.parse.totalOut, 123_000)
        func dir(_ prefix: String) -> StatementDirection? { lines.first { $0.description.hasPrefix(prefix) }?.direction }
        XCTAssertEqual(dir("Zelle From Sample"), .moneyIn)
        XCTAssertEqual(dir("Zelle From Other"), .moneyIn)
        XCTAssertEqual(dir("Zelle to Roommate"), .moneyOut)
        XCTAssertEqual(dir("ATM Withdrawal"), .moneyOut)
        XCTAssertEqual(dir("Sample Employer Payroll"), .moneyIn)
        XCTAssertEqual(lines.first { $0.description.hasPrefix("ATM Withdrawal") }?.amountMinorUnits, 10_000)
        XCTAssertTrue(p.parse.issues.isEmpty, "page headers are not flagged: \(p.parse.issues.map(\.text))")
    }

    func testBalanceTieBreakNeedsAClearWinner() {
        // Two equal amounts with no hint either way: left as read, not guessed.
        var lines = [
            ParsedStatementLine(page: 1, line: 1, transactionDate: .now, description: "ALPHA", amountMinorUnits: 500,
                                direction: .moneyOut, kind: .withdrawal, isPending: false, confidence: .low),
            ParsedStatementLine(page: 1, line: 2, transactionDate: .now, description: "BETA", amountMinorUnits: 500,
                                direction: .moneyOut, runningBalance: 1_000, kind: .withdrawal, isPending: false, confidence: .low),
        ]
        StatementLineParser.applyRunningBalances(&lines, openingBalance: 1_000)
        XCTAssertEqual(lines.map(\.confidence), [.low, .low])
    }
}
