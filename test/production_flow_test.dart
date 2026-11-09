import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ice_cream_erp/database/app_database.dart';
import 'package:ice_cream_erp/services/accounting_service.dart';
import 'package:ice_cream_erp/services/production_math.dart';
import 'package:ice_cream_erp/services/production_service.dart';
import 'package:ice_cream_erp/services/sales_service.dart';
import 'package:ice_cream_erp/services/stock_service.dart';
import 'package:ice_cream_erp/utils/seed_data.dart';

void main() {
  late AppDatabase db;
  late ProductionService prod;
  late StockService stock;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    prod = ProductionService(db);
    stock = StockService(db);
    await seedDemoData(db);
  });
  tearDown(() => db.close());

  Future<int> recipeId() async => (await db.select(db.recipes).getSingle()).id;
  Future<Tank> tank(String code) =>
      (db.select(db.tanks)..where((t) => t.tankCode.equals(code))).getSingle();

  /// Runs an order up to the Freezing stage.
  Future<int> orderToFreezing({double qty = 1000}) async {
    final id = await prod.createProductionOrder(recipeId: await recipeId(), targetMixQty: qty);
    await prod.issueRecipeMaterials(id);
    await prod.completeMixing(
      orderId: id,
      actualMixQty: qty,
      mixingTankId: (await tank('MIX-01')).id,
      agingTankId: (await tank('AGE-01')).id,
    );
    await prod.startFreezing(id, now: DateTime.now().add(const Duration(hours: 5)));
    return id;
  }

  test('full flow: real FEFO batch cost, overrun, cost/L, ledger reconciles', () async {
    final id = await orderToFreezing();

    var o = await prod.getOrderDetails(id);
    // 656.5 L milk*60 + 180.9 L cream*280 + 140 Kg sugar*90 + 45 Kg powder*450
    expect(o.order.totalMaterialCost, closeTo(122892.00, 0.01));
    expect(o.issues.length, 4);

    await prod.completeProduction(orderId: id, actualFinishedQty: 1900);
    o = await prod.getOrderDetails(id);
    expect(o.order.status, 'Completed');
    expect(o.order.actualOverrun, closeTo(90, 1e-6));
    expect(o.costPerLiterFinished, closeTo(64.68, 0.001));

    final milk = await (db.select(db.items)..where((i) => i.itemCode.equals('RM-MILK'))).getSingle();
    expect(await db.getItemStock(milk.id), closeTo(143.5, 1e-6));
    final fg = await (db.select(db.items)..where((i) => i.itemCode.equals('FG-VANILLA'))).getSingle();
    expect(await db.getItemStock(fg.id), closeTo(1900, 1e-6));

    // finished batch got an auto expiry from shelf life (180d)
    final batch = (await db.getAvailableBatches(fg.id)).single;
    expect(batch.expiryDate, isNotNull);

    expect(await stock.reconcile(), isEmpty);

    // aging tank released for cleaning, then reusable after CIP
    expect((await tank('AGE-01')).status, 'Cleaning');
    await prod.markTankClean((await tank('AGE-01')).id);
    expect((await tank('AGE-01')).status, 'Empty');
  });

  test('state guards: cannot skip steps or complete twice', () async {
    final id = await prod.createProductionOrder(recipeId: await recipeId(), targetMixQty: 1000);
    expect(() => prod.completeMixing(orderId: id, actualMixQty: 1000, mixingTankId: 1),
        throwsA(isA<StateException>()));
    expect(() => prod.completeProduction(orderId: id, actualFinishedQty: 1900),
        throwsA(isA<StateException>()));
    await prod.issueRecipeMaterials(id);
    expect(() => prod.issueRecipeMaterials(id), throwsA(isA<StateException>())); // no double issue

    await prod.cancelOrder(id);
    final id2 = await orderToFreezing();
    await prod.completeProduction(orderId: id2, actualFinishedQty: 1800);
    expect(() => prod.completeProduction(orderId: id2, actualFinishedQty: 1800),
        throwsA(isA<StateException>()));
  });

  test('aging time is enforced unless forced', () async {
    final id = await prod.createProductionOrder(recipeId: await recipeId(), targetMixQty: 1000);
    await prod.issueRecipeMaterials(id);
    await prod.completeMixing(
        orderId: id, actualMixQty: 1000, mixingTankId: (await tank('MIX-01')).id);
    expect(() => prod.startFreezing(id), throwsA(isA<AgingNotCompleteException>()));
    await prod.startFreezing(id, force: true);
    expect((await prod.getOrderDetails(id)).order.status, 'Freezing');
  });

  test('insufficient stock blocks issue and nothing is deducted', () async {
    final id = await prod.createProductionOrder(recipeId: await recipeId(), targetMixQty: 1400);
    expect(() => prod.issueRecipeMaterials(id), throwsA(isA<StateException>()));
    expect(await prod.getOrderDetails(id).then((d) => d.order.status), 'Planned');
    expect(await stock.reconcile(), isEmpty);
    final milk = await (db.select(db.items)..where((i) => i.itemCode.equals('RM-MILK'))).getSingle();
    expect(await db.getItemStock(milk.id), 800);
  });

  test('tank rules: capacity and busy tank', () async {
    expect(
        () => prod.createProductionOrder(
            recipeId: 1, targetMixQty: 1600, mixingTankId: 1), // MIX-01 holds 1500
        throwsA(isA<StateException>()));
    final id = await orderToFreezing(); // leaves MIX-01 in Cleaning
    expect(id, greaterThan(0));
    final id2 = await prod.createProductionOrder(recipeId: await recipeId(), targetMixQty: 100);
    await prod.issueRecipeMaterials(id2);
    final busyTankId = (await tank('MIX-01')).id;
    expect(
        () => prod.completeMixing(orderId: id2, actualMixQty: 100, mixingTankId: busyTankId),
        throwsA(isA<StateException>())); // still Cleaning
  });

  test('implausible finished qty is rejected', () async {
    final id = await orderToFreezing();
    expect(() => prod.completeProduction(orderId: id, actualFinishedQty: 500), throwsArgumentError);
    expect(() => prod.completeProduction(orderId: id, actualFinishedQty: 9000), throwsArgumentError);
  });

  test('cancel restores stock with ledger reversal', () async {
    final id = await prod.createProductionOrder(recipeId: await recipeId(), targetMixQty: 1000);
    await prod.issueRecipeMaterials(id);
    await prod.cancelOrder(id);
    final milk = await (db.select(db.items)..where((i) => i.itemCode.equals('RM-MILK'))).getSingle();
    expect(await db.getItemStock(milk.id), 800);
    expect(await stock.reconcile(), isEmpty);
    expect((await prod.getOrderDetails(id)).order.status, 'Cancelled');
  });

  test('FEFO plan skips expired and uses nearest expiry first', () async {
    final milk = await (db.select(db.items)..where((i) => i.itemCode.equals('RM-MILK'))).getSingle();
    final now = DateTime.now();
    await stock.receivePurchase(itemId: milk.id, qty: 100, unitCost: 50, batchNo: 'EXPIRED',
        mfgDate: now.subtract(const Duration(days: 10)), expiryDate: now.subtract(const Duration(days: 1)), paidNow: true);
    await stock.receivePurchase(itemId: milk.id, qty: 100, unitCost: 55, batchNo: 'SOON',
        expiryDate: now.add(const Duration(days: 1)), paidNow: true);
    final plan = await stock.planIssue(milk, 900);
    // 'MILK-D1' (expires in 3d) is later than 'SOON' (1d); EXPIRED is not touched
    final names = <String>[];
    for (final a in plan) {
      names.add((await (db.select(db.batches)..where((b) => b.id.equals(a.batchId))).getSingle()).batchNo);
    }
    expect(names, ['SOON', 'MILK-D1']);
    expect(() => stock.planIssue(milk, 1001), throwsA(isA<InsufficientStockException>()));
  });

  test('re-receiving same batch gives weighted average cost', () async {
    final sugar = await (db.select(db.items)..where((i) => i.itemCode.equals('RM-SUGAR'))).getSingle();
    await stock.receivePurchase(itemId: sugar.id, qty: 200, unitCost: 110, batchNo: 'SGR-D1', paidNow: true);
    final b = await (db.select(db.batches)..where((x) => x.batchNo.equals('SGR-D1'))).getSingle();
    expect(b.currentQty, 400);
    expect(b.unitCost, closeTo(100, 1e-9));
    expect(() => stock.receivePurchase(itemId: sugar.id, qty: 0, unitCost: 1), throwsArgumentError);
  });

  test('sales: FEFO deduction, P&L and trial balance are consistent', () async {
    final id = await orderToFreezing();
    await prod.completeProduction(orderId: id, actualFinishedQty: 1900);
    final fg = await (db.select(db.items)..where((i) => i.itemCode.equals('FG-VANILLA'))).getSingle();

    final r = await SalesService(db).sell(itemId: fg.id, qty: 100, unitPrice: 180);
    expect(r.revenue, 18000);
    expect(r.cost, closeTo(6468, 0.01));
    expect(await db.getItemStock(fg.id), 1800);
    expect(() => SalesService(db).sell(itemId: fg.id, qty: 5000, unitPrice: 180),
        throwsA(isA<InsufficientStockException>()));
    expect(await stock.reconcile(), isEmpty);

    final acc = AccountingService(db);
    await acc.createVoucher(type: 'Payment', amount: 1000, head: 'Electricity');
    final pl = await acc.profitAndLoss(closingStockValue: await stock.totalStockValue());
    expect(pl.sales, 18000);
    expect(pl.cogs, closeTo(6468, 0.01));
    expect(pl.grossProfit, closeTo(18000 - 6468, 0.01));
    expect(pl.expenses['Electricity'], 1000);
    expect(pl.netProfit, closeTo(18000 - 6468 - 1000, 0.01));

    final tb = await acc.trialBalance();
    final dr = tb.fold<double>(0, (s, x) => s + x.debit);
    final cr = tb.fold<double>(0, (s, x) => s + x.credit);
    expect(dr, closeTo(cr, 0.01));
  });

  test('credit purchase creates supplier payable; credit sale a receivable', () async {
    final sup = await (db.select(db.parties)..where((p) => p.partyCode.equals('SUP-001'))).getSingle();
    final milk = await (db.select(db.items)..where((i) => i.itemCode.equals('RM-MILK'))).getSingle();
    await stock.receivePurchase(itemId: milk.id, qty: 10, unitCost: 60, partyId: sup.id, paidNow: false);
    var bal = (await AccountingService(db).partyBalances()).firstWhere((b) => b.party.id == sup.id);
    expect(bal.payable, 600);

    // paying it off clears the balance
    await AccountingService(db).createVoucher(type: 'Payment', amount: 600, partyId: sup.id);
    bal = (await AccountingService(db).partyBalances()).firstWhere((b) => b.party.id == sup.id);
    expect(bal.payable, 0);
  });

  test('database enforces foreign keys and unique batch per item', () async {
    expect(
        () => db.into(db.recipeLines).insert(RecipeLinesCompanion.insert(
            recipeId: 999, itemId: 999, qty: 1, unit: 'L')),
        throwsA(anything));
    final milk = await (db.select(db.items)..where((i) => i.itemCode.equals('RM-MILK'))).getSingle();
    expect(
        () => db.into(db.batches).insert(BatchesCompanion.insert(
            batchNo: 'MILK-D1', itemId: milk.id, initialQty: 1, currentQty: 1)),
        throwsA(anything));
  });

  test('order numbers and voucher numbers are sequential and unique', () async {
    final a = await prod.createProductionOrder(recipeId: await recipeId(), targetMixQty: 10);
    final b = await prod.createProductionOrder(recipeId: await recipeId(), targetMixQty: 10);
    expect(a, isNot(b));
    final orders = await db.select(db.productionOrders).get();
    expect(orders.map((o) => o.orderNo).toSet().length, 2);
  });
}
