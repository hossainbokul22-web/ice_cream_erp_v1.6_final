import '../database/app_database.dart';
import 'accounting_service.dart';
import 'production_math.dart';
import 'stock_service.dart';

class SaleResult {
  SaleResult(this.voucherId, this.revenue, this.cost);
  final int voucherId;
  final double revenue;
  final double cost;
  double get margin => round2(revenue - cost);
}

/// Sells stock (FEFO, never expired batches) and books the Sales voucher atomically.
class SalesService {
  SalesService(this.db);
  final AppDatabase db;

  Future<SaleResult> sell({
    required int itemId,
    required double qty,
    required double unitPrice,
    int? partyId,
    bool receivedNow = true,
    DateTime? date,
    String? narration,
  }) async {
    if (qty <= 0) throw ArgumentError('পরিমাণ ০ এর বেশি হতে হবে');
    if (unitPrice <= 0) throw ArgumentError('বিক্রয় মূল্য ০ এর বেশি হতে হবে');
    final stock = StockService(db);
    final when = date ?? DateTime.now();

    return db.transaction(() async {
      final item = await (db.select(db.items)..where((i) => i.id.equals(itemId))).getSingleOrNull();
      if (item == null) throw ArgumentError('আইটেম পাওয়া যায়নি');

      final allocs = await stock.planIssue(item, qty, now: when);
      final revenue = round2(qty * unitPrice);
      final cost = round2(allocs.fold<double>(0, (s, a) => s + a.qty * a.unitCost));

      final voucherId = await AccountingService(db).createSalesVoucher(
        amount: revenue,
        partyId: partyId,
        receivedNow: receivedNow,
        date: when,
        narration: narration ?? 'Sale: ${item.itemName} $qty ${item.baseUnit}',
      );
      await stock.applyIssue(
        itemId: itemId,
        allocations: allocs,
        voucherType: 'Sales',
        voucherId: voucherId,
        narration: narration ?? 'Sale',
        when: when,
      );
      return SaleResult(voucherId, revenue, cost);
    });
  }
}
