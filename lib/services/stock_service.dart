import 'package:drift/drift.dart';
import '../database/app_database.dart';
import 'accounting_service.dart';
import 'production_math.dart';

class PurchaseResult {
  PurchaseResult(this.batchId, this.voucherId, this.batchNo);
  final int batchId;
  final int? voucherId;
  final String batchNo;
}

class StockRow {
  StockRow({
    required this.item,
    required this.stock,
    required this.batches,
    required this.value,
    required this.expiredQty,
    required this.nearExpiryQty,
  });
  final Item item;
  final double stock;
  final List<Batch> batches;
  final double value;
  final double expiredQty;
  final double nearExpiryQty; // expires within [StockService.nearExpiryDays]
  bool get isLow => item.minStock > 0 && stock < item.minStock;
}

class LedgerMismatch {
  LedgerMismatch(this.item, this.ledgerQty, this.batchQty);
  final Item item;
  final double ledgerQty;
  final double batchQty;
}

class StockService {
  StockService(this.db);
  final AppDatabase db;

  static const int nearExpiryDays = 30;

  // ====================== PURCHASE RECEIPT ======================

  /// Receives stock into a batch (creating it, or topping up the same
  /// item+batchNo with weighted-average cost) and, when [postVoucher] is true,
  /// books a Purchase voucher in the same transaction so stock and
  /// accounts never drift apart.
  Future<PurchaseResult> receivePurchase({
    required int itemId,
    required double qty,
    required double unitCost,
    String? batchNo,
    DateTime? mfgDate,
    DateTime? expiryDate,
    int? warehouseId,
    int? partyId,
    bool paidNow = false,
    bool postVoucher = true,
    String? narration,
    DateTime? now,
  }) async {
    if (qty <= 0) throw ArgumentError('পরিমাণ ০ এর বেশি হতে হবে');
    if (unitCost < 0) throw ArgumentError('দাম ঋণাত্মক হতে পারে না');
    final today = now ?? DateTime.now();

    return db.transaction(() async {
      final item = await (db.select(db.items)..where((i) => i.id.equals(itemId))).getSingleOrNull();
      if (item == null) throw ArgumentError('আইটেম পাওয়া যায়নি');

      final wh = warehouseId ?? (await db.getDefaultWarehouse())?.id;
      final mfg = mfgDate ?? today;
      final expiry = expiryDate ?? expiryFromShelfLife(mfg, item.shelfLifeDays);
      if (expiry != null && expiry.isBefore(mfg)) {
        throw ArgumentError('মেয়াদ উত্তীর্ণের তারিখ উৎপাদন তারিখের আগে হতে পারে না');
      }

      final bn = (batchNo == null || batchNo.trim().isEmpty)
          ? await db.nextBatchNo('LOT', now: today)
          : batchNo.trim();

      final existing = await (db.select(db.batches)
            ..where((b) => b.batchNo.equals(bn) & b.itemId.equals(itemId)))
          .getSingleOrNull();

      late int batchId;
      if (existing != null) {
        batchId = existing.id;
        final newCost = weightedAverageCost(
          oldQty: existing.currentQty,
          oldCost: existing.unitCost,
          addQty: qty,
          addCost: unitCost,
        );
        await (db.update(db.batches)..where((b) => b.id.equals(batchId))).write(
          BatchesCompanion(
            currentQty: Value(roundQty(existing.currentQty + qty)),
            initialQty: Value(roundQty(existing.initialQty + qty)),
            unitCost: Value(newCost),
          ),
        );
      } else {
        batchId = await db.into(db.batches).insert(BatchesCompanion.insert(
              batchNo: bn,
              itemId: itemId,
              warehouseId: Value(wh),
              mfgDate: Value(mfg),
              expiryDate: Value(expiry),
              initialQty: qty,
              currentQty: qty,
              unitCost: Value(unitCost),
            ));
      }

      int? voucherId;
      if (postVoucher) {
        voucherId = await AccountingService(db).createPurchaseVoucher(
          amount: round2(qty * unitCost),
          partyId: partyId,
          paidNow: paidNow,
          date: today,
          narration: narration ?? 'Purchase: ${item.itemName} $qty ${item.baseUnit} (Batch $bn)',
        );
      }

      await db.into(db.stockLedger).insert(StockLedgerCompanion.insert(
            voucherType: 'Purchase',
            itemId: itemId,
            voucherId: Value(voucherId),
            batchId: Value(batchId),
            warehouseId: Value(wh),
            qtyIn: Value(qty),
            unitCost: Value(unitCost),
            transactionDate: today,
            narration: Value(narration ?? 'Purchase Receipt'),
          ));

      await refreshAverageCost(itemId);
      return PurchaseResult(batchId, voucherId, bn);
    });
  }

  /// Item.standardCost := weighted-average unit cost of batches that still hold stock.
  Future<void> refreshAverageCost(int itemId) async {
    final bs = await (db.select(db.batches)
          ..where((b) => b.itemId.equals(itemId) & b.currentQty.isBiggerThanValue(0)))
        .get();
    if (bs.isEmpty) return;
    final qty = bs.fold<double>(0, (s, b) => s + b.currentQty);
    final value = bs.fold<double>(0, (s, b) => s + b.currentQty * b.unitCost);
    if (qty <= 0) return;
    await (db.update(db.items)..where((i) => i.id.equals(itemId)))
        .write(ItemsCompanion(standardCost: Value(round2(value / qty))));
  }

  // ====================== FEFO ALLOCATION & ISSUE ======================

  /// Plans (does not write) a FEFO issue of [qty] of [item]. Skips expired batches.
  Future<List<Allocation>> planIssue(Item item, double qty, {DateTime? now, int? warehouseId}) async {
    final bs = await db.getAvailableBatches(item.id, warehouseId: warehouseId);
    final lots = bs
        .map((b) => BatchLot(
              batchId: b.id,
              qty: b.currentQty,
              unitCost: b.unitCost,
              expiry: b.expiryDate,
              warehouseId: b.warehouseId,
              potencyValue: b.potencyValue,
            ))
        .toList();
    return allocateFefo(lots, qty,
        now: now ?? DateTime.now(), itemLabel: '${item.itemCode} ${item.itemName}');
  }

  /// Deducts the given allocations from batches and writes ledger rows.
  /// MUST be called inside a transaction (callers wrap their whole operation).
  Future<void> applyIssue({
    required int itemId,
    required List<Allocation> allocations,
    required String voucherType,
    int? voucherId,
    String? narration,
    DateTime? when,
  }) async {
    for (final a in allocations) {
      final batch =
          await (db.select(db.batches)..where((b) => b.id.equals(a.batchId))).getSingle();
      if (batch.currentQty + kQtyEpsilon < a.qty) {
        throw InsufficientStockException(
            'Batch ${batch.batchNo}', a.qty, batch.currentQty);
      }
      await (db.update(db.batches)..where((b) => b.id.equals(a.batchId)))
          .write(BatchesCompanion(currentQty: Value(roundQty(batch.currentQty - a.qty))));
      await db.into(db.stockLedger).insert(StockLedgerCompanion.insert(
            voucherType: voucherType,
            voucherId: Value(voucherId),
            itemId: itemId,
            batchId: Value(a.batchId),
            warehouseId: Value(batch.warehouseId),
            qtyOut: Value(a.qty),
            unitCost: Value(a.unitCost),
            transactionDate: when ?? DateTime.now(),
            narration: Value(narration),
          ));
    }
  }

  /// Manual stock correction on one batch (damage, melt, count difference).
  Future<void> adjustBatch({
    required int batchId,
    required double newQty,
    required String reason,
  }) async {
    if (newQty < 0) throw ArgumentError('পরিমাণ ঋণাত্মক হতে পারে না');
    if (reason.trim().isEmpty) throw ArgumentError('কারণ লিখুন');
    await db.transaction(() async {
      final b = await (db.select(db.batches)..where((x) => x.id.equals(batchId))).getSingle();
      final diff = roundQty(newQty - b.currentQty);
      if (diff.abs() < kQtyEpsilon) return;
      await (db.update(db.batches)..where((x) => x.id.equals(batchId)))
          .write(BatchesCompanion(currentQty: Value(roundQty(newQty))));
      await db.into(db.stockLedger).insert(StockLedgerCompanion.insert(
            voucherType: 'Adjustment',
            itemId: b.itemId,
            batchId: Value(batchId),
            warehouseId: Value(b.warehouseId),
            qtyIn: Value(diff > 0 ? diff : 0),
            qtyOut: Value(diff < 0 ? -diff : 0),
            unitCost: Value(b.unitCost),
            transactionDate: DateTime.now(),
            narration: Value('Adjustment: ${reason.trim()}'),
          ));
    });
  }

    /// Explicit stock out for Reject / Wastage (qty to remove).
  Future<void> recordStockOut({
    required int batchId,
    required double qty,
    required String movementType, // Reject | Wastage
    required String reason,
    DateTime? date,
  }) async {
    if (qty <= 0) throw ArgumentError('qty > 0');
    if (movementType != 'Reject' && movementType != 'Wastage') {
      throw ArgumentError('Reject বা Wastage');
    }
    final when = date ?? DateTime.now();
    await db.transaction(() async {
      final b = await (db.select(db.batches)..where((x) => x.id.equals(batchId))).getSingle();
      if (b.currentQty + 0.0001 < qty) {
        throw StateError('স্টক অপর্যাপ্ত: ${b.batchNo}');
      }
      await (db.update(db.batches)..where((x) => x.id.equals(batchId)))
          .write(BatchesCompanion(currentQty: Value(roundQty(b.currentQty - qty))));
      await db.into(db.stockLedger).insert(StockLedgerCompanion.insert(
            voucherType: movementType,
            itemId: b.itemId,
            batchId: Value(batchId),
            warehouseId: Value(b.warehouseId),
            qtyOut: Value(roundQty(qty)),
            unitCost: Value(b.unitCost),
            transactionDate: when,
            narration: Value('$movementType: ${reason.trim()}'),
          ));
    });
  }

  /// Explicit return to stock (qty add back to batch).
  Future<void> recordReturn({
    required int batchId,
    required double qty,
    required String reason,
    DateTime? date,
  }) async {
    if (qty <= 0) throw ArgumentError('qty > 0');
    final when = date ?? DateTime.now();
    await db.transaction(() async {
      final b = await (db.select(db.batches)..where((x) => x.id.equals(batchId))).getSingle();
      await (db.update(db.batches)..where((x) => x.id.equals(batchId)))
          .write(BatchesCompanion(currentQty: Value(roundQty(b.currentQty + qty))));
      await db.into(db.stockLedger).insert(StockLedgerCompanion.insert(
            voucherType: 'Return',
            itemId: b.itemId,
            batchId: Value(batchId),
            warehouseId: Value(b.warehouseId),
            qtyIn: Value(roundQty(qty)),
            unitCost: Value(b.unitCost),
            transactionDate: when,
            narration: Value('Return: ${reason.trim()}'),
          ));
    });
  }

  // ====================== REPORTS ======================

  Future<List<StockRow>> getStockSummary({int? warehouseId, DateTime? now}) async {
    final today = now ?? DateTime.now();
    final items = await (db.select(db.items)
          ..where((i) => i.isActive.equals(true))
          ..orderBy([(i) => OrderingTerm.asc(i.itemType), (i) => OrderingTerm.asc(i.itemCode)]))
        .get();

    final q = db.select(db.batches)..where((b) => b.currentQty.isBiggerThanValue(0));
    if (warehouseId != null) q.where((b) => b.warehouseId.equals(warehouseId));
    final all = await q.get();

    final byItem = <int, List<Batch>>{};
    for (final b in all) {
      byItem.putIfAbsent(b.itemId, () => []).add(b);
    }

    final limit = today.add(const Duration(days: nearExpiryDays));
    final rows = <StockRow>[];
    for (final item in items) {
      final bs = (byItem[item.id] ?? [])
        ..sort((a, b) {
          if (a.expiryDate == null && b.expiryDate == null) return a.id.compareTo(b.id);
          if (a.expiryDate == null) return 1;
          if (b.expiryDate == null) return -1;
          return a.expiryDate!.compareTo(b.expiryDate!);
        });
      var stock = 0.0, value = 0.0, expired = 0.0, near = 0.0;
      for (final b in bs) {
        stock += b.currentQty;
        value += b.currentQty * b.unitCost;
        final e = b.expiryDate;
        if (e != null) {
          if (e.isBefore(today)) {
            expired += b.currentQty;
          } else if (e.isBefore(limit)) {
            near += b.currentQty;
          }
        }
      }
      rows.add(StockRow(
        item: item,
        stock: roundQty(stock),
        batches: bs,
        value: round2(value),
        expiredQty: roundQty(expired),
        nearExpiryQty: roundQty(near),
      ));
    }
    return rows;
  }

  /// Total inventory value (all batches with stock).
  Future<double> totalStockValue() async {
    final bs = await (db.select(db.batches)..where((b) => b.currentQty.isBiggerThanValue(0))).get();
    return round2(bs.fold<double>(0, (s, b) => s + b.currentQty * b.unitCost));
  }

  /// Compares ledger totals with batch quantities; any difference means a bug or manual DB edit.
  Future<List<LedgerMismatch>> reconcile() async {
    final items = await db.select(db.items).get();
    final out = <LedgerMismatch>[];
    for (final item in items) {
      final l = db.stockLedger;
      final sIn = l.qtyIn.sum();
      final sOut = l.qtyOut.sum();
      final row = await (db.selectOnly(l)
            ..addColumns([sIn, sOut])
            ..where(l.itemId.equals(item.id)))
          .getSingle();
      final ledgerQty = (row.read(sIn) ?? 0.0) - (row.read(sOut) ?? 0.0);
      final batchQty = await db.getItemStock(item.id);
      if ((ledgerQty - batchQty).abs() > 0.001) {
        out.add(LedgerMismatch(item, ledgerQty, batchQty));
      }
    }
    return out;
  }

  /// Tank status overview
  Future<List<Map<String, dynamic>>> getTankStatus() async {
    final tanks = await db.select(db.tanks).get();
    final result = <Map<String, dynamic>>[];
    for (final tank in tanks) {
      String? itemName;
      if (tank.currentItemId != null) {
        final item = await (db.select(db.items)..where((i) => i.id.equals(tank.currentItemId!)))
            .getSingleOrNull();
        itemName = item?.itemName;
      }
      result.add({
        'tank': tank,
        'itemName': itemName,
        'fillPercent': tank.capacityLiter > 0 ? (tank.currentQty / tank.capacityLiter) * 100 : 0.0,
        'availableCapacity': tank.capacityLiter - tank.currentQty,
      });
    }
    return result;
  }

  /// Move qty of a specific batch from one warehouse to another.
  Future<int> transferBatch({
    required int batchId,
    required int toWarehouseId,
    required double qty,
    String? notes,
    String? createdBy,
    DateTime? date,
  }) async {
    if (qty <= 0) throw ArgumentError('Transfer qty > 0 হতে হবে');
    final when = date ?? DateTime.now();
    return db.transaction(() async {
      final batch = await (db.select(db.batches)..where((b) => b.id.equals(batchId))).getSingle();
      if (batch.currentQty + 0.0001 < qty) {
        throw StateError('Batch ${batch.batchNo}-এ যথেষ্ট স্টক নেই');
      }
      final fromWh = batch.warehouseId;
      if (fromWh == null) throw StateError('Source warehouse নেই');
      if (fromWh == toWarehouseId) throw StateError('একই warehouse-এ transfer নয়');

      final no = await _nextTransferNo();
      final tid = await db.into(db.stockTransfers).insert(StockTransfersCompanion.insert(
            transferNo: no,
            fromWarehouseId: fromWh,
            toWarehouseId: toWarehouseId,
            transferDate: when,
            notes: Value(notes),
            createdBy: Value(createdBy),
          ));
      await db.into(db.stockTransferLines).insert(StockTransferLinesCompanion.insert(
            transferId: tid,
            itemId: batch.itemId,
            batchId: Value(batchId),
            qty: qty,
          ));

      await (db.update(db.batches)..where((b) => b.id.equals(batchId))).write(
        BatchesCompanion(currentQty: Value(batch.currentQty - qty)),
      );
      await db.into(db.stockLedger).insert(StockLedgerCompanion.insert(
            voucherType: 'Transfer',
            voucherId: Value(tid),
            itemId: batch.itemId,
            batchId: Value(batchId),
            warehouseId: Value(fromWh),
            qtyOut: Value(qty),
            unitCost: Value(batch.unitCost),
            transactionDate: when,
            narration: Value(notes ?? 'Transfer out $no'),
          ));

      // Unique is (itemId, batchNo) globally — use WH-qualified no at destination
      final destBatchNo = '${batch.batchNo}-W$toWarehouseId';
      final existing = await (db.select(db.batches)
            ..where((b) =>
                b.itemId.equals(batch.itemId) &
                b.batchNo.equals(destBatchNo)))
          .get();
      int targetBatchId;
      if (existing.isEmpty) {
        targetBatchId = await db.into(db.batches).insert(BatchesCompanion.insert(
              batchNo: destBatchNo,
              itemId: batch.itemId,
              warehouseId: Value(toWarehouseId),
              mfgDate: Value(batch.mfgDate),
              expiryDate: Value(batch.expiryDate),
              initialQty: qty,
              currentQty: qty,
              unitCost: Value(batch.unitCost),
              potencyValue: Value(batch.potencyValue),
              status: const Value('Available'),
            ));
      } else {
        final t = existing.first;
        targetBatchId = t.id;
        await (db.update(db.batches)..where((b) => b.id.equals(t.id))).write(
          BatchesCompanion(currentQty: Value(t.currentQty + qty)),
        );
      }
      await db.into(db.stockLedger).insert(StockLedgerCompanion.insert(
            voucherType: 'Transfer',
            voucherId: Value(tid),
            itemId: batch.itemId,
            batchId: Value(targetBatchId),
            warehouseId: Value(toWarehouseId),
            qtyIn: Value(qty),
            unitCost: Value(batch.unitCost),
            transactionDate: when,
            narration: Value(notes ?? 'Transfer in $no'),
          ));
      return tid;
    });
  }

  Future<String> _nextTransferNo() async {
    final d = DateTime.now();
    final prefix =
        'TR-${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}-';
    final existing =
        await (db.select(db.stockTransfers)..where((t) => t.transferNo.like('$prefix%'))).get();
    var n = existing.length + 1;
    final used = existing.map((e) => e.transferNo).toSet();
    while (used.contains('$prefix${n.toString().padLeft(3, '0')}')) {
      n++;
    }
    return '$prefix${n.toString().padLeft(3, '0')}';
  }

  // ====================== DAILY / MONTHLY INVENTORY REPORTS ======================

  /// Snapshot of RM + FG (+ Mix) for boss daily brief.
  Future<DailyInventoryBrief> dailyInventoryBrief({DateTime? day}) async {
    final d = day ?? DateTime.now();
    final start = DateTime(d.year, d.month, d.day);
    final end = start.add(const Duration(days: 1));
    final rows = await getStockSummary(now: start);
    final rm = rows.where((r) => r.item.itemType == 'Raw' || r.item.itemType == 'Packaging').toList();
    final fg = rows.where((r) => r.item.itemType == 'Finished').toList();
    final mix = rows.where((r) => r.item.itemType == 'Mix' || r.item.itemType == 'Semi').toList();

    final ledgers = await (db.select(db.stockLedger)
          ..where((l) =>
              l.transactionDate.isBiggerOrEqualValue(start) &
              l.transactionDate.isSmallerThanValue(end)))
        .get();

    double sumIn(String type) =>
        ledgers.where((l) => l.voucherType == type).fold(0.0, (s, l) => s + l.qtyIn);
    double sumOut(String type) =>
        ledgers.where((l) => l.voucherType == type).fold(0.0, (s, l) => s + l.qtyOut);

    final completed = await (db.select(db.productionOrders)
          ..where((o) =>
              o.status.equals('Completed') &
              o.endDate.isNotNull() &
              o.endDate.isBiggerOrEqualValue(start) &
              o.endDate.isSmallerThanValue(end)))
        .get();
    final prodQty =
        completed.fold<double>(0, (s, o) => s + (o.actualFinishedQty ?? 0));

    return DailyInventoryBrief(
      date: start,
      rawRows: rm,
      finishedRows: fg,
      mixRows: mix,
      rawValue: round2(rm.fold(0.0, (s, r) => s + r.value)),
      finishedValue: round2(fg.fold(0.0, (s, r) => s + r.value)),
      purchaseIn: roundQty(sumIn('Purchase')),
      productionIssueOut: roundQty(sumOut('ProductionIssue')),
      productionReceiptIn: roundQty(sumIn('ProductionReceipt')),
      salesOut: roundQty(sumOut('Sales')),
      finishedProducedToday: roundQty(prodQty),
      lowStockCount: rows.where((r) => r.isLow).length,
      nearExpiryCount: rows.where((r) => r.nearExpiryQty > 0).length,
    );
  }

  /// Opening / In / Out / Closing per item for a calendar month.
  Future<List<MonthlyStockLine>> monthlyStockStatement({
    required int year,
    required int month,
    List<String>? itemTypes,
  }) async {
    final from = DateTime(year, month, 1);
    final to = (month == 12) ? DateTime(year + 1, 1, 1) : DateTime(year, month + 1, 1);

    final items = await (db.select(db.items)
          ..where((i) => i.isActive.equals(true))
          ..orderBy([(i) => OrderingTerm.asc(i.itemType), (i) => OrderingTerm.asc(i.itemCode)]))
        .get();

    final allLedger = await (db.select(db.stockLedger)
          ..where((l) => l.transactionDate.isSmallerThanValue(to)))
        .get();

    final out = <MonthlyStockLine>[];
    for (final item in items) {
      if (itemTypes != null && !itemTypes.contains(item.itemType)) continue;
      final led = allLedger.where((l) => l.itemId == item.id).toList();

      double opening = 0, purchase = 0, issue = 0, prodIn = 0, sales = 0, adjustIn = 0, adjustOut = 0, transferIn = 0, transferOut = 0;
      for (final l in led) {
        final before = l.transactionDate.isBefore(from);
        final inPeriod = !before && l.transactionDate.isBefore(to);
        if (before) {
          opening += l.qtyIn - l.qtyOut;
        } else if (inPeriod) {
          switch (l.voucherType) {
            case 'Purchase':
              purchase += l.qtyIn;
              break;
            case 'ProductionIssue':
            case 'ProductionIssueReversal':
              issue += l.qtyOut;
              opening += l.qtyIn; // reversal restores
              break;
            case 'ProductionReceipt':
              prodIn += l.qtyIn;
              break;
            case 'Sales':
              sales += l.qtyOut;
              break;
            case 'Transfer':
              transferIn += l.qtyIn;
              transferOut += l.qtyOut;
              break;
            default:
              adjustIn += l.qtyIn;
              adjustOut += l.qtyOut;
          }
        }
      }
      final closing = opening + purchase + prodIn + transferIn + adjustIn - issue - sales - transferOut - adjustOut;
      if (opening.abs() < kQtyEpsilon &&
          purchase < kQtyEpsilon &&
          issue < kQtyEpsilon &&
          prodIn < kQtyEpsilon &&
          sales < kQtyEpsilon &&
          closing.abs() < kQtyEpsilon) {
        continue; // skip idle items
      }
      out.add(MonthlyStockLine(
        item: item,
        opening: roundQty(opening),
        purchase: roundQty(purchase),
        productionIssue: roundQty(issue),
        productionIn: roundQty(prodIn),
        sales: roundQty(sales),
        transferNet: roundQty(transferIn - transferOut),
        adjustmentNet: roundQty(adjustIn - adjustOut),
        closing: roundQty(closing),
      ));
    }
    return out;
  }

  /// RM + Packaging daily register: Opening, Receive, Use, Reject, Wastage, Return, Closing.
  /// Previous day closing = this day opening (from ledger before day start).
  Future<List<RmPackDayLine>> rmPackDailyRegister({DateTime? day}) async {
    final d = day ?? DateTime.now();
    final start = DateTime(d.year, d.month, d.day);
    final end = start.add(const Duration(days: 1));

    final items = await (db.select(db.items)
          ..where((i) =>
              i.isActive.equals(true) &
              (i.itemType.equals('Raw') | i.itemType.equals('Packaging')))
          ..orderBy([(i) => OrderingTerm.asc(i.itemType), (i) => OrderingTerm.asc(i.itemCode)]))
        .get();

    final allLedger = await (db.select(db.stockLedger)
          ..where((l) => l.transactionDate.isSmallerThanValue(end)))
        .get();

    final out = <RmPackDayLine>[];
    for (final item in items) {
      final led = allLedger.where((l) => l.itemId == item.id).toList();
      double opening = 0, receive = 0, use = 0, reject = 0, wastage = 0, ret = 0;
      for (final l in led) {
        final before = l.transactionDate.isBefore(start);
        final inDay = !before && l.transactionDate.isBefore(end);
        if (before) {
          opening += l.qtyIn - l.qtyOut;
        } else if (inDay) {
          switch (l.voucherType) {
            case 'Purchase':
            case 'Transfer':
              receive += l.qtyIn;
              // transfer out is not receive
              use += l.qtyOut; // transfer out treated as movement out — better split:
              break;
            case 'ProductionIssue':
              use += l.qtyOut;
              break;
            case 'ProductionIssueReversal':
              ret += l.qtyIn;
              break;
            case 'Reject':
              reject += l.qtyOut;
              break;
            case 'Wastage':
              wastage += l.qtyOut;
              break;
            case 'Return':
              ret += l.qtyIn;
              break;
            case 'Sales':
              use += l.qtyOut; // rare for RM
              break;
            case 'Adjustment':
              if (l.qtyIn > 0) ret += l.qtyIn;
              if (l.qtyOut > 0) wastage += l.qtyOut;
              break;
            default:
              receive += l.qtyIn;
              use += l.qtyOut;
          }
        }
      }
      // Fix Transfer double-count: recalculate transfer separately
      // Simpler second pass for Transfer only on this day
      receive = 0;
      use = 0;
      reject = 0;
      wastage = 0;
      ret = 0;
      opening = 0;
      for (final l in led) {
        final before = l.transactionDate.isBefore(start);
        final inDay = !before && l.transactionDate.isBefore(end);
        if (before) {
          opening += l.qtyIn - l.qtyOut;
          continue;
        }
        if (!inDay) continue;
        switch (l.voucherType) {
          case 'Purchase':
            receive += l.qtyIn;
            break;
          case 'Transfer':
            receive += l.qtyIn;
            // transfer out from this item's batch reduces stock — count as use for register simplicity
            // or ignore warehouse moves for plant RM sheet — count out as use
            use += l.qtyOut;
            break;
          case 'ProductionIssue':
            use += l.qtyOut;
            break;
          case 'ProductionIssueReversal':
            ret += l.qtyIn;
            break;
          case 'Reject':
            reject += l.qtyOut;
            break;
          case 'Wastage':
            wastage += l.qtyOut;
            break;
          case 'Return':
            ret += l.qtyIn;
            break;
          case 'Adjustment':
            if (l.qtyIn > 0) ret += l.qtyIn;
            if (l.qtyOut > 0) wastage += l.qtyOut;
            break;
          case 'Sales':
            use += l.qtyOut;
            break;
          default:
            receive += l.qtyIn;
            use += l.qtyOut;
        }
      }
      final closing = opening + receive + ret - use - reject - wastage;
      if (opening.abs() < kQtyEpsilon &&
          receive < kQtyEpsilon &&
          use < kQtyEpsilon &&
          reject < kQtyEpsilon &&
          wastage < kQtyEpsilon &&
          ret < kQtyEpsilon) {
        continue;
      }
      out.add(RmPackDayLine(
        item: item,
        opening: roundQty(opening),
        receive: roundQty(receive),
        use: roundQty(use),
        reject: roundQty(reject),
        wastage: roundQty(wastage),
        returned: roundQty(ret),
        closing: roundQty(closing),
      ));
    }
    return out;
  }

  String rmPackDayToCsv(List<RmPackDayLine> lines, DateTime day) {
    final buf = StringBuffer();
    buf.writeln('RM Packaging Daily Stock,${day.toIso8601String().substring(0, 10)}');
    buf.writeln('Type,Code,Name,Unit,Opening,Receive,Use,Reject,Wastage,Return,Closing');
    for (final l in lines) {
      buf.writeln(
          '${l.item.itemType},${l.item.itemCode},"${l.item.itemName}",${l.item.baseUnit},${l.opening},${l.receive},${l.use},${l.reject},${l.wastage},${l.returned},${l.closing}');
    }
    return buf.toString();
  }

    String dailyBriefToCsv(DailyInventoryBrief b) {
    final buf = StringBuffer();
    buf.writeln('Daily Inventory Brief,${b.date.toIso8601String().substring(0, 10)}');
    buf.writeln('Metric,Value');
    buf.writeln('RM+Pack Value,${b.rawValue}');
    buf.writeln('FG Value,${b.finishedValue}');
    buf.writeln('Purchase In,${b.purchaseIn}');
    buf.writeln('Production Issue Out,${b.productionIssueOut}');
    buf.writeln('FG Receipt In,${b.productionReceiptIn}');
    buf.writeln('Sales Out,${b.salesOut}');
    buf.writeln('FG Produced Today,${b.finishedProducedToday}');
    buf.writeln('Low Stock Items,${b.lowStockCount}');
    buf.writeln('Near Expiry Items,${b.nearExpiryCount}');
    buf.writeln();
    buf.writeln('Type,Code,Name,Stock,Unit,Value,Low,NearExpiry');
    for (final r in [...b.rawRows, ...b.mixRows, ...b.finishedRows]) {
      buf.writeln(
          '${r.item.itemType},${r.item.itemCode},"${r.item.itemName}",${r.stock},${r.item.baseUnit},${r.value},${r.isLow},${r.nearExpiryQty}');
    }
    return buf.toString();
  }

  String monthlyStatementToCsv(List<MonthlyStockLine> lines, int year, int month) {
    final buf = StringBuffer();
    buf.writeln('Monthly Stock Statement,$year-${month.toString().padLeft(2, '0')}');
    buf.writeln('Type,Code,Name,Unit,Opening,Purchase,ProdIssue,ProdIn,Sales,TransferNet,AdjNet,Closing');
    for (final l in lines) {
      buf.writeln(
          '${l.item.itemType},${l.item.itemCode},"${l.item.itemName}",${l.item.baseUnit},${l.opening},${l.purchase},${l.productionIssue},${l.productionIn},${l.sales},${l.transferNet},${l.adjustmentNet},${l.closing}');
    }
    return buf.toString();
  }
}

class DailyInventoryBrief {
  DailyInventoryBrief({
    required this.date,
    required this.rawRows,
    required this.finishedRows,
    required this.mixRows,
    required this.rawValue,
    required this.finishedValue,
    required this.purchaseIn,
    required this.productionIssueOut,
    required this.productionReceiptIn,
    required this.salesOut,
    required this.finishedProducedToday,
    required this.lowStockCount,
    required this.nearExpiryCount,
  });
  final DateTime date;
  final List<StockRow> rawRows;
  final List<StockRow> finishedRows;
  final List<StockRow> mixRows;
  final double rawValue;
  final double finishedValue;
  final double purchaseIn;
  final double productionIssueOut;
  final double productionReceiptIn;
  final double salesOut;
  final double finishedProducedToday;
  final int lowStockCount;
  final int nearExpiryCount;
}

class MonthlyStockLine {
  MonthlyStockLine({
    required this.item,
    required this.opening,
    required this.purchase,
    required this.productionIssue,
    required this.productionIn,
    required this.sales,
    required this.transferNet,
    required this.adjustmentNet,
    required this.closing,
  });
  final Item item;
  final double opening;
  final double purchase;
  final double productionIssue;
  final double productionIn;
  final double sales;
  final double transferNet;
  final double adjustmentNet;
  final double closing;
}


class RmPackDayLine {
  RmPackDayLine({
    required this.item,
    required this.opening,
    required this.receive,
    required this.use,
    required this.reject,
    required this.wastage,
    required this.returned,
    required this.closing,
  });
  final Item item;
  final double opening;
  final double receive;
  final double use;
  final double reject;
  final double wastage;
  final double returned;
  final double closing;
}
