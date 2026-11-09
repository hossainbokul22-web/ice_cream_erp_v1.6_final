import 'package:drift/drift.dart';
import '../database/app_database.dart';
import 'production_math.dart';

class VoucherLineSpec {
  const VoucherLineSpec(this.ledger, {this.debit = 0, this.credit = 0});
  final String ledger;
  final double debit;
  final double credit;
}

const String kCashBank = 'Cash/Bank';
const String kPurchaseAc = 'Purchase A/c';
const String kSalesAc = 'Sales A/c';
const String kExpensePrefix = 'Expense: ';
const String kIncomePrefix = 'Income: ';

/// Ledger names use the (immutable) party code so renaming a party never orphans its balance.
String payableLedger(Party p) => 'Payable: ${p.partyCode}';
String receivableLedger(Party p) => 'Receivable: ${p.partyCode}';

/// Pure double-entry builder. Always returns balanced lines or throws.
List<VoucherLineSpec> buildVoucherLines({
  required String type,
  required double amount,
  Party? party,
  bool settledNow = true,
  String? head,
  String? debitLedger,
  String? creditLedger,
}) {
  if (amount <= 0) throw ArgumentError('Amount ০ এর বেশি হতে হবে');
  final amt = round2(amount);
  final headTxt = (head ?? '').trim();

  late List<VoucherLineSpec> lines;
  switch (type) {
    case 'Purchase':
      if (!settledNow && party == null) {
        throw ArgumentError('বাকিতে ক্রয়ের জন্য সরবরাহকারী (Party) দিন');
      }
      lines = [
        VoucherLineSpec(kPurchaseAc, debit: amt),
        VoucherLineSpec(settledNow || party == null ? kCashBank : payableLedger(party), credit: amt),
      ];
      break;
    case 'Sales':
      if (!settledNow && party == null) {
        throw ArgumentError('বাকিতে বিক্রয়ের জন্য কাস্টমার (Party) দিন');
      }
      lines = [
        VoucherLineSpec(settledNow || party == null ? kCashBank : receivableLedger(party), debit: amt),
        VoucherLineSpec(kSalesAc, credit: amt),
      ];
      break;
    case 'Payment':
      if (party == null && headTxt.isEmpty) {
        throw ArgumentError('Party অথবা খরচের খাত (Expense head) দিন');
      }
      lines = [
        VoucherLineSpec(party != null ? payableLedger(party) : '$kExpensePrefix$headTxt', debit: amt),
        VoucherLineSpec(kCashBank, credit: amt),
      ];
      break;
    case 'Receipt':
      if (party == null && headTxt.isEmpty) {
        throw ArgumentError('Party অথবা আয়ের খাত (Income head) দিন');
      }
      lines = [
        VoucherLineSpec(kCashBank, debit: amt),
        VoucherLineSpec(party != null ? receivableLedger(party) : '$kIncomePrefix$headTxt', credit: amt),
      ];
      break;
    case 'Journal':
      final dr = (debitLedger ?? '').trim();
      final cr = (creditLedger ?? '').trim();
      if (dr.isEmpty || cr.isEmpty) throw ArgumentError('Debit ও Credit ledger দুটোই দিন');
      if (dr == cr) throw ArgumentError('Debit ও Credit ledger একই হতে পারে না');
      lines = [VoucherLineSpec(dr, debit: amt), VoucherLineSpec(cr, credit: amt)];
      break;
    default:
      throw ArgumentError('অজানা ভাউচার টাইপ: $type');
  }

  final dr = lines.fold<double>(0, (s, l) => s + l.debit);
  final cr = lines.fold<double>(0, (s, l) => s + l.credit);
  if ((dr - cr).abs() > 0.005) throw StateError('Debit ($dr) ≠ Credit ($cr)');
  return lines;
}

class TrialBalanceRow {
  TrialBalanceRow(this.ledger, this.debit, this.credit);
  final String ledger;
  final double debit;
  final double credit;
  double get net => debit - credit;
}

class ProfitLossReport {
  ProfitLossReport({
    required this.sales,
    required this.otherIncome,
    required this.purchases,
    required this.closingStock,
    required this.expenses,
  });
  final double sales;
  final double otherIncome;
  final double purchases;
  final double closingStock;
  final Map<String, double> expenses;

  /// Cost of goods sold (periodic method, opening stock = 0 for "all time").
  double get cogs => round2(purchases - closingStock);
  double get grossProfit => round2(sales - cogs);
  double get totalExpenses => round2(expenses.values.fold<double>(0, (s, v) => s + v));
  double get netProfit => round2(grossProfit + otherIncome - totalExpenses);
}

class PartyBalance {
  PartyBalance(this.party, this.receivable, this.payable);
  final Party party;
  final double receivable; // they owe us
  final double payable; // we owe them
  double get net => receivable - payable; // + = receivable
}

class AccountingService {
  AccountingService(this.db);
  final AppDatabase db;

  Future<int> createVoucher({
    required String type,
    required double amount,
    DateTime? date,
    int? partyId,
    bool settledNow = true,
    String? head,
    String? debitLedger,
    String? creditLedger,
    String? narration,
  }) {
    return db.transaction(() async {
      Party? party;
      if (partyId != null) {
        party = await (db.select(db.parties)..where((p) => p.id.equals(partyId))).getSingleOrNull();
        if (party == null) throw ArgumentError('Party পাওয়া যায়নি');
      }
      final lines = buildVoucherLines(
        type: type,
        amount: amount,
        party: party,
        settledNow: settledNow,
        head: head,
        debitLedger: debitLedger,
        creditLedger: creditLedger,
      );
      final no = await db.nextVoucherNo(type);
      final id = await db.into(db.vouchers).insert(VouchersCompanion.insert(
            voucherNo: no,
            voucherType: type,
            partyId: Value(partyId),
            voucherDate: date ?? DateTime.now(),
            totalAmount: round2(amount),
            narration: Value(narration),
          ));
      for (final l in lines) {
        await db.into(db.voucherLines).insert(VoucherLinesCompanion.insert(
              voucherId: id,
              ledgerName: l.ledger,
              debit: Value(l.debit),
              credit: Value(l.credit),
            ));
      }
      return id;
    });
  }

  Future<int> createPurchaseVoucher({
    required double amount,
    int? partyId,
    bool paidNow = false,
    DateTime? date,
    String? narration,
  }) =>
      createVoucher(
        type: 'Purchase',
        amount: amount,
        partyId: partyId,
        // Without a supplier we can only record it as cash.
        settledNow: partyId == null ? true : paidNow,
        date: date,
        narration: narration,
      );

  Future<int> createSalesVoucher({
    required double amount,
    int? partyId,
    bool receivedNow = true,
    DateTime? date,
    String? narration,
  }) =>
      createVoucher(
        type: 'Sales',
        amount: amount,
        partyId: partyId,
        settledNow: partyId == null ? true : receivedNow,
        date: date,
        narration: narration,
      );

  // ====================== REPORTS ======================

  Future<List<TrialBalanceRow>> trialBalance() async {
    final l = db.voucherLines;
    final d = l.debit.sum();
    final c = l.credit.sum();
    final rows = await (db.selectOnly(l)
          ..addColumns([l.ledgerName, d, c])
          ..groupBy([l.ledgerName])
          ..orderBy([OrderingTerm.asc(l.ledgerName)]))
        .get();
    return rows
        .map((r) => TrialBalanceRow(
              r.read(l.ledgerName)!,
              round2(r.read(d) ?? 0),
              round2(r.read(c) ?? 0),
            ))
        .toList();
  }

  Future<ProfitLossReport> profitAndLoss({required double closingStockValue}) async {
    final tb = await trialBalance();
    double sales = 0, purchases = 0, income = 0;
    final expenses = <String, double>{};
    for (final r in tb) {
      if (r.ledger == kSalesAc) sales += r.credit - r.debit;
      if (r.ledger == kPurchaseAc) purchases += r.debit - r.credit;
      if (r.ledger.startsWith(kIncomePrefix)) income += r.credit - r.debit;
      if (r.ledger.startsWith(kExpensePrefix)) {
        expenses[r.ledger.substring(kExpensePrefix.length)] = round2(r.debit - r.credit);
      }
    }
    return ProfitLossReport(
      sales: round2(sales),
      otherIncome: round2(income),
      purchases: round2(purchases),
      closingStock: round2(closingStockValue),
      expenses: expenses,
    );
  }

  /// Opening balance convention: positive = customer owes us, negative = we owe them.
  Future<List<PartyBalance>> partyBalances() async {
    final parties = await (db.select(db.parties)..orderBy([(p) => OrderingTerm.asc(p.partyName)])).get();
    final tb = {for (final r in await trialBalance()) r.ledger: r};
    return parties.map((p) {
      final rec = tb[receivableLedger(p)];
      final pay = tb[payableLedger(p)];
      var receivable = rec?.net ?? 0;
      var payable = pay == null ? 0.0 : -pay.net;
      if (p.openingBalance >= 0) {
        receivable += p.openingBalance;
      } else {
        payable += -p.openingBalance;
      }
      return PartyBalance(p, round2(receivable), round2(payable));
    }).toList();
  }
}
