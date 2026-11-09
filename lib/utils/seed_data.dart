import 'package:drift/drift.dart';
import '../database/app_database.dart';
import '../services/production_service.dart';
import '../services/ops_service.dart';
import '../services/stock_service.dart';

/// Always safe to call. Creates the units and the default warehouse if missing.
/// (Real installs need these; demo items are separate — see [seedDemoData].)
Future<void> ensureBaseData(AppDatabase db) async {
  const units = {
    'L': 'Liter',
    'ml': 'Milliliter',
    'Kg': 'Kilogram',
    'g': 'Gram',
    'Pcs': 'Pieces',
    'Cup': 'Cup',
    'Cone': 'Cone',
    'Tin': 'Tin',
  };
  final have = (await db.select(db.units).get()).map((u) => u.unitCode).toSet();
  for (final e in units.entries) {
    if (!have.contains(e.key)) {
      await db.into(db.units).insert(UnitsCompanion.insert(unitCode: e.key, unitName: e.value));
    }
  }
  if ((await db.select(db.warehouses).get()).isEmpty) {
    await db.into(db.warehouses).insert(WarehousesCompanion.insert(
          warehouseCode: 'MAIN',
          warehouseName: 'Main Store',
          isDefault: const Value(true),
        ));
  }
}

/// True when nothing has been entered yet (so offering demo data makes sense).
Future<bool> isDatabaseEmpty(AppDatabase db) async =>
    (await db.select(db.items).get()).isEmpty && (await db.select(db.recipes).get()).isEmpty;

/// Demo data: items, tanks, a complete Vanilla recipe, suppliers and an opening
/// purchase of raw materials (real batches + vouchers) so a production order can be run immediately.
Future<void> seedDemoData(AppDatabase db) async {
  if (!await isDatabaseEmpty(db)) return;
  await ensureBaseData(db);
  final stock = StockService(db);
  final wh = (await db.getDefaultWarehouse())!.id;

  Future<int> item(String code, String name, String type, String unit,
      {double cost = 0, double price = 0, double min = 0, int shelf = 0}) {
    return db.into(db.items).insert(ItemsCompanion.insert(
          itemCode: code,
          itemName: name,
          itemType: type,
          baseUnit: unit,
          standardCost: Value(cost),
          salesPrice: Value(price),
          minStock: Value(min),
          shelfLifeDays: Value(shelf),
        ));
  }

  final milk = await item('RM-MILK', 'Fresh Milk', 'Raw', 'L', min: 300, shelf: 3);
  final cream = await item('RM-CREAM', 'Fresh Cream', 'Raw', 'L', min: 100, shelf: 7);
  final sugar = await item('RM-SUGAR', 'Sugar', 'Raw', 'Kg', min: 100, shelf: 365);
  final powder = await item('RM-MP', 'Milk Powder', 'Raw', 'Kg', min: 50, shelf: 365);
  await item('PK-CUP', '100ml Cup', 'Packaging', 'Pcs', min: 1000);
  final vanilla = await item('FG-VANILLA', 'Vanilla Ice Cream', 'Finished', 'L',
      price: 180, min: 500, shelf: 180);

  await db.into(db.tanks).insert(TanksCompanion.insert(
      tankCode: 'MIX-01', tankName: 'Mixing Tank 1', tankType: 'Mixing', capacityLiter: 1500));
  await db.into(db.tanks).insert(TanksCompanion.insert(
      tankCode: 'AGE-01', tankName: 'Aging Tank 1', tankType: 'Aging', capacityLiter: 2000));
  await db.into(db.tanks).insert(TanksCompanion.insert(
      tankCode: 'AGE-02', tankName: 'Aging Tank 2', tankType: 'Aging', capacityLiter: 2000));

  final recipeId = await db.into(db.recipes).insert(RecipesCompanion.insert(
        recipeCode: 'RCP-VANILLA',
        recipeName: 'Vanilla Premium',
        finishedItemId: vanilla,
        baseQty: 1000,
        baseUnit: 'L',
        targetOverrun: const Value(90),
        expectedYield: const Value(97),
        agingHours: const Value(4),
      ));
  Future<void> line(int itemId, double qty, String unit, double waste, int seq) =>
      db.into(db.recipeLines).insert(RecipeLinesCompanion.insert(
            recipeId: recipeId,
            itemId: itemId,
            qty: qty,
            unit: unit,
            wastagePercent: Value(waste),
            sequence: Value(seq),
          ));
  await line(milk, 650, 'L', 1, 1);
  await line(cream, 180, 'L', 0.5, 2);
  await line(sugar, 140, 'Kg', 0, 3);
  await line(powder, 45, 'Kg', 0, 4);

  // Default QC tests (HACCP / BatchMaster style)
  Future<void> qc(String stage, String name, double? target, double? minV, double? maxV, String? unit, int seq) =>
      db.into(db.recipeQcTests).insert(RecipeQcTestsCompanion.insert(
            recipeId: recipeId,
            stage: stage,
            testName: name,
            targetValue: Value(target),
            minValue: Value(minV),
            maxValue: Value(maxV),
            unit: Value(unit),
            sequence: Value(seq),
          ));
  await qc('Mixing', 'Mix Temperature', 4.0, 2.0, 6.0, '°C', 0);
  await qc('Aging', 'Aging Hours', null, 4.0, null, 'hr', 1);
  await qc('Freezing', 'Overrun %', 90.0, 80.0, 120.0, '%', 2);
  await qc('Final', 'Taste / Sensory', null, null, null, null, 3);
  await qc('Final', 'Visual Appearance', null, null, null, null, 4);
  await qc('Final', 'Package Integrity', null, null, null, null, 5);

  // Phase A: potency, allergens, intermediate mix
  await (db.update(db.items)..where((i) => i.id.equals(milk))).write(const ItemsCompanion(
        potencyName: Value('Fat%'), potencyStandard: Value(3.5), allergens: Value('Milk')));
  await (db.update(db.items)..where((i) => i.id.equals(cream))).write(const ItemsCompanion(
        potencyName: Value('Fat%'), potencyStandard: Value(35.0), allergens: Value('Milk')));
  await (db.update(db.items)..where((i) => i.id.equals(powder))).write(
        const ItemsCompanion(allergens: Value('Milk')));
  final mixItem = await item('MIX-VANILLA', 'Vanilla Mix (Intermediate)', 'Mix', 'L', cost: 80, shelf: 3);
  await (db.update(db.recipes)..where((r) => r.id.equals(recipeId)))
      .write(RecipesCompanion(intermediateItemId: Value(mixItem)));
  await (db.update(db.recipeLines)
        ..where((l) => l.recipeId.equals(recipeId) & l.itemId.equals(milk)))
      .write(const RecipeLinesCompanion(scaleByPotency: Value(true)));
  await (db.update(db.recipeLines)
        ..where((l) => l.recipeId.equals(recipeId) & l.itemId.equals(cream)))
      .write(const RecipeLinesCompanion(scaleByPotency: Value(true)));
  // Build label text
  await ProductionService(db).buildAndSaveLabel(recipeId);
  await ProductionService(db).seedDefaultCcps(recipeId);

  final supplier = await db.into(db.parties).insert(PartiesCompanion.insert(
      partyCode: 'SUP-001', partyName: 'Dairy Farm Supplier', partyType: 'Supplier'));
  await db.into(db.parties).insert(PartiesCompanion.insert(
      partyCode: 'CUS-001', partyName: 'City Ice Cream Parlour', partyType: 'Customer'));

  Future<void> buy(int itemId, double qty, double cost, String batch) => stock.receivePurchase(
        itemId: itemId,
        qty: qty,
        unitCost: cost,
        batchNo: batch,
        warehouseId: wh,
        partyId: supplier,
        paidNow: true,
        narration: 'Opening purchase (demo)',
      );
  await buy(milk, 800, 60, 'MILK-D1');
  await buy(cream, 220, 280, 'CRM-D1');
  await buy(sugar, 200, 90, 'SGR-D1');
  await buy(powder, 80, 450, 'MP-D1');
  await buy(await _itemId(db, 'PK-CUP'), 5000, 2.5, 'CUP-D1');

  // Demo potency on milk/cream lots (slightly below standard → scale-up)
  await (db.update(db.batches)..where((b) => b.batchNo.equals('MILK-D1')))
      .write(const BatchesCompanion(potencyValue: Value(3.2)));
  await (db.update(db.batches)..where((b) => b.batchNo.equals('CRM-D1')))
      .write(const BatchesCompanion(potencyValue: Value(33.0)));

  // Second warehouse for transfer demo
  final existingWh = await db.select(db.warehouses).get();
  if (existingWh.length < 2) {
    await db.into(db.warehouses).insert(WarehousesCompanion.insert(
          warehouseCode: 'WH-COLD',
          warehouseName: 'Cold Store FG',
          isDefault: const Value(false),
        ));
  }

  // Nutrition + work instructions on recipe
  await (db.update(db.recipes)..where((r) => r.id.equals(recipeId))).write(
    const RecipesCompanion(
      energyKcal: Value(210),
      fatG: Value(12),
      proteinG: Value(4),
      carbG: Value(22),
      sugarG: Value(18),
      workInstructions: Value(
        '1. Pasteurize mix 80°C / 25s\n2. Homogenize 150 bar\n3. Cool to 4°C\n4. Age min 4h\n5. Freeze with target overrun\n6. Harden -25°C',
      ),
    ),
  );

  await OpsService(db).seedOperatorsAndCompliance();
}

Future<int> _itemId(AppDatabase db, String code) async =>
    (await (db.select(db.items)..where((i) => i.itemCode.equals(code))).getSingle()).id;
