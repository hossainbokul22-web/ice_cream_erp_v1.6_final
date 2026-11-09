import 'package:flutter_test/flutter_test.dart';
import 'package:ice_cream_erp/services/accounting_service.dart';
import 'package:ice_cream_erp/services/production_math.dart';

void main() {
  final now = DateTime(2026, 11, 8);

  group('allocateFefo', () {
    test('earliest expiry first, no-expiry batches last', () {
      final lots = [
        const BatchLot(batchId: 1, qty: 50, unitCost: 10), // no expiry
        BatchLot(batchId: 2, qty: 50, unitCost: 11, expiry: DateTime(2026, 12, 20)),
        BatchLot(batchId: 3, qty: 50, unitCost: 12, expiry: DateTime(2026, 11, 20)),
      ];
      final a = allocateFefo(lots, 120, now: now);
      expect(a.map((x) => x.batchId).toList(), [3, 2, 1]);
      expect(a.map((x) => x.qty).toList(), [50, 50, 20]);
    });

    test('expired batches are never used', () {
      final lots = [
        BatchLot(batchId: 1, qty: 100, unitCost: 10, expiry: DateTime(2026, 11, 1)), // expired
        BatchLot(batchId: 2, qty: 30, unitCost: 10, expiry: DateTime(2026, 12, 1)),
      ];
      expect(() => allocateFefo(lots, 50, now: now), throwsA(isA<InsufficientStockException>()));
      final a = allocateFefo(lots, 30, now: now);
      expect(a.single.batchId, 2);
    });

    test('throws with shortage info, zero qty returns empty', () {
      final lots = [const BatchLot(batchId: 1, qty: 10, unitCost: 1)];
      expect(() => allocateFefo(lots, 11, now: now), throwsA(isA<InsufficientStockException>()));
      expect(allocateFefo(lots, 0, now: now), isEmpty);
    });
  });

  group('production formulas', () {
    test('overrun, yield, required mix', () {
      expect(calcOverrunPercent(1000, 1900), closeTo(90, 1e-9));
      expect(calcOverrunPercent(0, 10), 0);
      expect(calcMixYieldPercent(970, 1000), closeTo(97, 1e-9));
      expect(requiredMixForFinished(1900, 90), closeTo(1000, 1e-9));
    });

    test('cost per finished liter includes other cost', () {
      expect(costPerFinishedUnit(materialCost: 122892, finishedQty: 1900), closeTo(64.68, 1e-9));
      expect(costPerFinishedUnit(materialCost: 100, otherCost: 50, finishedQty: 10), 15);
      expect(costPerFinishedUnit(materialCost: 100, finishedQty: 0), 0);
    });

    test('scaled requirement with wastage', () {
      expect(scaledRequirement(lineQty: 650, orderQty: 500, recipeBaseQty: 1000, wastagePercent: 1),
          closeTo(328.25, 1e-9));
    });

    test('unit conversion', () {
      expect(convertQty(500, 'g', 'Kg'), closeTo(0.5, 1e-12));
      expect(convertQty(2, 'Kg', 'g'), 2000);
      expect(convertQty(250, 'ml', 'L'), closeTo(0.25, 1e-12));
      expect(convertQty(3, 'L', 'L'), 3);
      expect(() => convertQty(1, 'Kg', 'L'), throwsA(isA<UnitConversionException>()));
      expect(convertQty(10, 'Pcs', 'Kg', factors: {'Kg>Pcs': 5}), closeTo(2, 1e-12)); // reverse derived
    });

    test('weighted average cost', () {
      expect(weightedAverageCost(oldQty: 100, oldCost: 10, addQty: 100, addCost: 20), 15);
      expect(weightedAverageCost(oldQty: 0, oldCost: 99, addQty: 10, addCost: 5), 5);
    });

    test('expiry from shelf life', () {
      expect(expiryFromShelfLife(DateTime(2026, 1, 1), 30), DateTime(2026, 1, 31));
      expect(expiryFromShelfLife(DateTime(2026, 1, 1), 0), isNull);
    });

    test('rounding helpers', () {
      expect(round2(0.1 + 0.2), 0.3);
      expect(roundQty(1.23456789), 1.2346);
    });
  });

  group('buildVoucherLines', () {
    double dr(List<VoucherLineSpec> l) => l.fold(0, (s, x) => s + x.debit);
    double cr(List<VoucherLineSpec> l) => l.fold(0, (s, x) => s + x.credit);

    test('cash purchase / sale are balanced', () {
      final p = buildVoucherLines(type: 'Purchase', amount: 500);
      expect(p.first.ledger, kPurchaseAc);
      expect(p.last.ledger, kCashBank);
      expect(dr(p), cr(p));
      final s = buildVoucherLines(type: 'Sales', amount: 700);
      expect(s.last.ledger, kSalesAc);
      expect(dr(s), cr(s));
    });

    test('credit sale/purchase need a party', () {
      expect(() => buildVoucherLines(type: 'Sales', amount: 10, settledNow: false), throwsArgumentError);
      expect(() => buildVoucherLines(type: 'Purchase', amount: 10, settledNow: false), throwsArgumentError);
    });

    test('payment/receipt/journal', () {
      final pay = buildVoucherLines(type: 'Payment', amount: 100, head: 'Electricity');
      expect(pay.first.ledger, 'Expense: Electricity');
      expect(pay.last.ledger, kCashBank);
      expect(() => buildVoucherLines(type: 'Payment', amount: 100), throwsArgumentError);
      final rc = buildVoucherLines(type: 'Receipt', amount: 100, head: 'Scrap');
      expect(rc.last.ledger, 'Income: Scrap');
      final j = buildVoucherLines(type: 'Journal', amount: 5, debitLedger: 'A', creditLedger: 'B');
      expect(dr(j), cr(j));
      expect(() => buildVoucherLines(type: 'Journal', amount: 5, debitLedger: 'A', creditLedger: 'A'), throwsArgumentError);
    });

    test('rejects zero/negative amounts and unknown types', () {
      expect(() => buildVoucherLines(type: 'Sales', amount: 0), throwsArgumentError);
      expect(() => buildVoucherLines(type: 'Sales', amount: -5), throwsArgumentError);
      expect(() => buildVoucherLines(type: 'Bogus', amount: 5), throwsArgumentError);
    });
  });
}
