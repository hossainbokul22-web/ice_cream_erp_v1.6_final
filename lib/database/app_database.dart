import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [
  Items,
  Units,
  UnitConversions,
  Warehouses,
  Tanks,
  Parties,
  Recipes,
  RecipeLines,
  Batches,
  StockLedger,
  ProductionOrders,
  ProductionIssues,
  ProductionReceipts,
  RecipeQcTests,
  ProductionQcResults,
  ProductionStepLogs,
  HaccpCcps,
  ProductionCcpLogs,
  Deviations,
  Capas,
  Operators,
  ComplianceItems,
  ProductionComplianceLogs,
  RdSamples,
  StockTransfers,
  StockTransferLines,
  Vouchers,
  VoucherLines,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  /// For unit tests: `AppDatabase.forTesting(NativeDatabase.memory())`.
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createIndexes();
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(items, items.shelfLifeDays);
            await m.addColumn(recipes, recipes.agingHours);
            await m.addColumn(productionOrders, productionOrders.agingStartedAt);
            await m.addColumn(productionOrders, productionOrders.otherCost);
            try {
              await customStatement(
                  'CREATE UNIQUE INDEX IF NOT EXISTS ux_batches_item_batch ON batches(item_id, batch_no)');
            } catch (_) {
              // Old data may contain duplicate (item, batch) pairs; keep going.
            }
            await _createIndexes();
          }
          if (from < 3) {
            await m.addColumn(productionOrders, productionOrders.sourceType);
            await m.addColumn(productionOrders, productionOrders.operatorName);
            await m.addColumn(productionOrders, productionOrders.qcStatus);
            await m.addColumn(productionOrders, productionOrders.holdReason);
            await m.addColumn(productionOrders, productionOrders.signedAt);
            await m.createTable(recipeQcTests);
            await m.createTable(productionQcResults);
            await m.createTable(productionStepLogs);
            await customStatement(
                'CREATE INDEX IF NOT EXISTS ix_step_logs_order ON production_step_logs(production_order_id)');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS ix_qc_results_order ON production_qc_results(production_order_id)');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS ix_recipe_qc_recipe ON recipe_qc_tests(recipe_id)');
          }
          if (from < 4) {
            await m.addColumn(recipes, recipes.approvalStatus);
            await m.addColumn(recipes, recipes.parentRecipeId);
            await m.addColumn(productionOrders, productionOrders.scrapQty);
            await m.addColumn(productionOrders, productionOrders.scrapNotes);
          }
          if (from < 5) {
            await m.addColumn(items, items.potencyName);
            await m.addColumn(items, items.potencyStandard);
            await m.addColumn(items, items.allergens);
            await m.addColumn(batches, batches.potencyValue);
            await m.addColumn(recipes, recipes.intermediateItemId);
            await m.addColumn(recipes, recipes.labelIngredients);
            await m.addColumn(recipes, recipes.labelClaims);
            await m.addColumn(recipeLines, recipeLines.scaleByPotency);
            await m.addColumn(productionOrders, productionOrders.intermediateBatchId);
            await m.addColumn(productionOrders, productionOrders.signedBy);
            await m.createTable(haccpCcps);
            await m.createTable(productionCcpLogs);
            await m.createTable(deviations);
            await m.createTable(capas);
            await customStatement(
                'CREATE INDEX IF NOT EXISTS ix_ccp_logs_order ON production_ccp_logs(production_order_id)');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS ix_deviations_order ON deviations(production_order_id)');
          }
          if (from < 6) {
            await m.addColumn(recipes, recipes.energyKcal);
            await m.addColumn(recipes, recipes.fatG);
            await m.addColumn(recipes, recipes.proteinG);
            await m.addColumn(recipes, recipes.carbG);
            await m.addColumn(recipes, recipes.sugarG);
            await m.addColumn(recipes, recipes.workInstructions);
            await m.addColumn(productionOrders, productionOrders.plannedDate);
            await m.addColumn(productionOrders, productionOrders.priority);
            await m.addColumn(productionOrders, productionOrders.byProductQty);
            await m.addColumn(productionOrders, productionOrders.byProductNotes);
            await m.createTable(operators);
            await m.createTable(complianceItems);
            await m.createTable(productionComplianceLogs);
            await m.createTable(rdSamples);
            await m.createTable(stockTransfers);
            await m.createTable(stockTransferLines);
          }
        },
        beforeOpen: (details) async {
          // SQLite ignores REFERENCES unless this is switched on per connection.
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  Future<void> _createIndexes() async {
    const stmts = [
      'CREATE INDEX IF NOT EXISTS ix_batches_item ON batches(item_id)',
      'CREATE INDEX IF NOT EXISTS ix_ledger_item ON stock_ledger(item_id)',
      'CREATE INDEX IF NOT EXISTS ix_ledger_batch ON stock_ledger(batch_id)',
      'CREATE INDEX IF NOT EXISTS ix_issues_order ON production_issues(production_order_id)',
      'CREATE INDEX IF NOT EXISTS ix_vlines_voucher ON voucher_lines(voucher_id)',
      'CREATE INDEX IF NOT EXISTS ix_vouchers_type ON vouchers(voucher_type)',
    ];
    for (final s in stmts) {
      await customStatement(s);
    }
  }

  // ====================== HELPER QUERIES ======================

  /// Current stock of an item. Batches are the single source of truth;
  /// StockLedger is the audit trail (see StockService.reconcile()).
  Future<double> getItemStock(int itemId, {int? warehouseId}) async {
    final sum = batches.currentQty.sum();
    final query = selectOnly(batches)
      ..addColumns([sum])
      ..where(batches.itemId.equals(itemId) & batches.currentQty.isBiggerThanValue(0));
    if (warehouseId != null) {
      query.where(batches.warehouseId.equals(warehouseId));
    }
    final row = await query.getSingle();
    return row.read(sum) ?? 0.0;
  }

  /// Batches with stock, FEFO order. Batches without expiry are last.
  Future<List<Batch>> getAvailableBatches(int itemId, {int? warehouseId}) async {
    final q = select(batches)
      ..where((b) => b.itemId.equals(itemId) & b.currentQty.isBiggerThanValue(0));
    if (warehouseId != null) {
      q.where((b) => b.warehouseId.equals(warehouseId));
    }
    final list = await q.get();
    list.sort((a, b) {
      if (a.expiryDate == null && b.expiryDate == null) return a.id.compareTo(b.id);
      if (a.expiryDate == null) return 1;
      if (b.expiryDate == null) return -1;
      final c = a.expiryDate!.compareTo(b.expiryDate!);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    return list;
  }

  Future<Warehouse?> getDefaultWarehouse() async {
    final def = await (select(warehouses)..where((w) => w.isDefault.equals(true))).get();
    if (def.isNotEmpty) return def.first;
    final any = await (select(warehouses)..limit(1)).get();
    return any.isEmpty ? null : any.first;
  }

  // ====================== NUMBERING ======================

  static String _ymd(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  Future<String> nextProductionOrderNo({DateTime? now}) async {
    final prefix = 'PO-${_ymd(now ?? DateTime.now())}-';
    final existing = await (select(productionOrders)
          ..where((o) => o.orderNo.like('$prefix%')))
        .get();
    var n = existing.length + 1;
    final used = existing.map((e) => e.orderNo).toSet();
    while (used.contains('$prefix${n.toString().padLeft(3, '0')}')) {
      n++;
    }
    return '$prefix${n.toString().padLeft(3, '0')}';
  }

  static const _voucherPrefix = {
    'Purchase': 'PUR',
    'Sales': 'SAL',
    'Payment': 'PAY',
    'Receipt': 'RCT',
    'Journal': 'JRN',
    'Contra': 'CTR',
  };

  Future<String> nextVoucherNo(String type) async {
    final prefix = '${_voucherPrefix[type] ?? 'VCH'}-';
    final existing =
        await (select(vouchers)..where((v) => v.voucherNo.like('$prefix%'))).get();
    final used = existing.map((e) => e.voucherNo).toSet();
    var n = existing.length + 1;
    while (used.contains('$prefix${n.toString().padLeft(5, '0')}')) {
      n++;
    }
    return '$prefix${n.toString().padLeft(5, '0')}';
  }

  Future<String> nextBatchNo(String prefix, {DateTime? now}) async {
    final d = now ?? DateTime.now();
    final base = '$prefix-${_ymd(d)}-';
    final existing = await (select(batches)..where((b) => b.batchNo.like('$base%'))).get();
    final used = existing.map((e) => e.batchNo).toSet();
    var n = existing.length + 1;
    while (used.contains('$base${n.toString().padLeft(2, '0')}')) {
      n++;
    }
    return '$base${n.toString().padLeft(2, '0')}';
  }

  // ====================== BACKUP ======================

  /// Writes a consistent snapshot of the database and returns its path.
  Future<String> exportBackup() async {
    final dir = await getTemporaryDirectory();
    final d = DateTime.now();
    final name =
        'ice_cream_erp_backup_${_ymd(d)}_${d.hour.toString().padLeft(2, '0')}${d.minute.toString().padLeft(2, '0')}.sqlite';
    final path = p.join(dir.path, name);
    final f = File(path);
    if (await f.exists()) await f.delete();
    await customStatement("VACUUM INTO '${path.replaceAll("'", "''")}'");
    return path;
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'ice_cream_erp.sqlite'));
    return NativeDatabase(file);
  });
}
