import 'package:drift/drift.dart';
import '../database/app_database.dart';
import 'production_math.dart';
import 'stock_service.dart';

class StateException implements Exception {
  StateException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AgingNotCompleteException implements Exception {
  AgingNotCompleteException(this.hoursLeft);
  final double hoursLeft;
  @override
  String toString() => 'Aging এখনো শেষ হয়নি — আরও ${hoursLeft.toStringAsFixed(1)} ঘণ্টা বাকি';
}

class RequiredMaterial {
  RequiredMaterial({
    required this.item,
    required this.recipeQty,
    required this.recipeUnit,
    required this.requiredQty,
    required this.wastagePercent,
  });
  final Item item;
  final double recipeQty; // as written in the recipe (scaled, with wastage), in recipeUnit
  final String recipeUnit;
  final double requiredQty; // converted to item.baseUnit
  final double wastagePercent;
}

class MaterialAvailability {
  MaterialAvailability({
    required this.material,
    required this.available,
    required this.plan,
  });
  final RequiredMaterial material;
  final double available; // usable (non-expired) stock
  final List<Allocation> plan; // empty when short
  double get shortage {
    final s = material.requiredQty - available;
    return s > kQtyEpsilon ? roundQty(s) : 0;
  }

  bool get isShort => shortage > 0;
  double get estimatedCost =>
      round2(plan.fold<double>(0, (s, a) => s + a.qty * a.unitCost));
}

class IssueLine {
  IssueLine(this.issue, this.item, this.batchNo);
  final ProductionIssue issue;
  final Item? item;
  final String? batchNo;
  double get lineCost => round2(issue.qty * (issue.unitCost ?? 0));
}

class OrderDetails {
  OrderDetails({
    required this.order,
    required this.recipe,
    required this.finishedItem,
    required this.issues,
    required this.mixingTank,
    required this.agingTank,
  });
  final ProductionOrder order;
  final Recipe recipe;
  final Item? finishedItem;
  final List<IssueLine> issues;
  final Tank? mixingTank;
  final Tank? agingTank;

  double get totalCost => round2(order.totalMaterialCost + order.otherCost);

  double? get costPerLiterMix {
    final m = order.actualMixQty;
    if (m == null || m <= 0) return null;
    return totalCost / m;
  }

  double? get costPerLiterFinished {
    final f = order.actualFinishedQty;
    if (f == null || f <= 0) return null;
    return costPerFinishedUnit(
        materialCost: order.totalMaterialCost, otherCost: order.otherCost, finishedQty: f);
  }

  /// Expected finished volume from the planned overrun.
  double? get expectedFinishedQty {
    final m = order.actualMixQty;
    if (m == null) return null;
    return m * (1 + (order.plannedOverrun ?? recipe.targetOverrun) / 100);
  }

  double? get overrunVariance {
    final a = order.actualOverrun;
    if (a == null) return null;
    return a - (order.plannedOverrun ?? recipe.targetOverrun);
  }

  double? get agingElapsed {
    final s = order.agingStartedAt;
    if (s == null) return null;
    final end = order.status == 'Aging' ? DateTime.now() : (order.endDate ?? DateTime.now());
    return agingElapsedHours(s, end);
  }
}

class ProductionService {
  ProductionService(this.db);
  final AppDatabase db;

  Future<ProductionOrder> _order(int id) =>
      (db.select(db.productionOrders)..where((o) => o.id.equals(id))).getSingle();

  void _requireStatus(ProductionOrder o, List<String> allowed, String action) {
    if (!allowed.contains(o.status)) {
      throw StateException(
          '"$action" করা যাবে না — অর্ডার ${o.orderNo} এখন "${o.status}" অবস্থায় (প্রয়োজন: ${allowed.join(' / ')})');
    }
  }

  // ====================== CREATE ======================

  Future<int> createProductionOrder({
    String? orderNo,
    required int recipeId,
    required double targetMixQty,
    String targetUnit = 'L',
    int? mixingTankId,
    int? agingTankId,
    String? notes,
    String sourceType = 'Manual',
    String? operatorName,
    DateTime? plannedDate,
    int priority = 5,
  }) async {
    if (targetMixQty <= 0) throw ArgumentError('Target Mix পরিমাণ ০ এর বেশি হতে হবে');

    return db.transaction(() async {
      final recipe =
          await (db.select(db.recipes)..where((r) => r.id.equals(recipeId))).getSingleOrNull();
      if (recipe == null) throw ArgumentError('Recipe পাওয়া যায়নি');
      if (!recipe.isActive) throw StateException('Recipe নিষ্ক্রিয়');
      if (recipe.approvalStatus != 'Approved') {
        throw StateException('শুধু Approved recipe দিয়ে Production Order বানানো যায় (এখন: ${recipe.approvalStatus})');
      }
      final lines =
          await (db.select(db.recipeLines)..where((l) => l.recipeId.equals(recipeId))).get();
      if (lines.isEmpty) {
        throw StateException('Recipe "${recipe.recipeName}" এ কোনো ইনগ্রিডিয়েন্ট নেই — আগে যোগ করুন');
      }

      if (mixingTankId != null) {
        final t = await (db.select(db.tanks)..where((x) => x.id.equals(mixingTankId))).getSingle();
        if (t.tankType != 'Mixing') throw StateException('${t.tankCode} Mixing ট্যাংক নয়');
        if (targetMixQty > t.capacityLiter) {
          throw StateException(
              '${t.tankCode} এর ক্ষমতা ${t.capacityLiter} L, কিন্তু Target $targetMixQty L');
        }
      }
      if (agingTankId != null) {
        final t = await (db.select(db.tanks)..where((x) => x.id.equals(agingTankId))).getSingle();
        if (t.tankType != 'Aging') throw StateException('${t.tankCode} Aging ট্যাংক নয়');
        if (targetMixQty > t.capacityLiter) {
          throw StateException(
              '${t.tankCode} এর ক্ষমতা ${t.capacityLiter} L, কিন্তু Target $targetMixQty L');
        }
      }

      final no = (orderNo == null || orderNo.trim().isEmpty)
          ? await db.nextProductionOrderNo()
          : orderNo.trim();
      final dup = await (db.select(db.productionOrders)..where((o) => o.orderNo.equals(no))).get();
      if (dup.isNotEmpty) throw StateException('Order No "$no" আগে থেকেই আছে');

      final id = await db.into(db.productionOrders).insert(ProductionOrdersCompanion.insert(
            orderNo: no,
            recipeId: recipeId,
            targetQty: targetMixQty,
            targetUnit: targetUnit,
            plannedOverrun: Value(recipe.targetOverrun),
            mixingTankId: Value(mixingTankId),
            agingTankId: Value(agingTankId),
            notes: Value(notes),
            sourceType: Value(sourceType),
            operatorName: Value(operatorName),
            plannedDate: Value(plannedDate),
            priority: Value(priority),
          ));
      await _logStep(id, 'Planned', 'Production Order তৈরি', operatorName: operatorName,
          notes: notes);
      return id;
    });
  }

  // ====================== MATERIAL REQUIREMENT ======================

  Future<Map<String, double>> _factorsFor(int itemId) async {
    final rows =
        await (db.select(db.unitConversions)..where((c) => c.itemId.equals(itemId))).get();
    return {for (final r in rows) '${r.fromUnit}>${r.toUnit}': r.conversionFactor};
  }

  /// Required materials for [orderQty] of the recipe, converted to each item's base unit.
  /// When [scaleByPotency] is set on a line, qty is adjusted using weighted avg batch potency.
  Future<List<RequiredMaterial>> requirementsFor(int recipeId, double orderQty) async {
    final recipe = await (db.select(db.recipes)..where((r) => r.id.equals(recipeId))).getSingle();
    final lines = await (db.select(db.recipeLines)
          ..where((l) => l.recipeId.equals(recipeId))
          ..orderBy([(l) => OrderingTerm.asc(l.sequence), (l) => OrderingTerm.asc(l.id)]))
        .get();

    final out = <RequiredMaterial>[];
    final now = DateTime.now();
    for (final line in lines) {
      final item = await (db.select(db.items)..where((i) => i.id.equals(line.itemId))).getSingle();
      var inRecipeUnit = scaledRequirement(
        lineQty: line.qty,
        orderQty: orderQty,
        recipeBaseQty: recipe.baseQty,
        wastagePercent: line.wastagePercent,
      );
      // Potency scaling: weaker batch → more qty
      if (line.scaleByPotency && item.potencyStandard != null && item.potencyStandard! > 0) {
        final batches = await db.getAvailableBatches(item.id);
        final usable = batches
            .where((b) => b.currentQty > kQtyEpsilon &&
                (b.expiryDate == null || !b.expiryDate!.isBefore(now)))
            .toList();
        if (usable.isNotEmpty) {
          final totalQty = usable.fold<double>(0, (s, b) => s + b.currentQty);
          final weighted = usable.fold<double>(0, (s, b) {
            final p = b.potencyValue ?? item.potencyStandard!;
            return s + b.currentQty * p;
          });
          final avgPotency = weighted / totalQty;
          inRecipeUnit = scaleByPotency(
            baseQty: inRecipeUnit,
            standard: item.potencyStandard,
            actual: avgPotency,
          );
        }
      }
      final inBase = convertQty(inRecipeUnit, line.unit, item.baseUnit,
          factors: await _factorsFor(item.id));
      out.add(RequiredMaterial(
        item: item,
        recipeQty: inRecipeUnit,
        recipeUnit: line.unit,
        requiredQty: roundQty(inBase),
        wastagePercent: line.wastagePercent,
      ));
    }
    return out;
  }

  Future<List<RequiredMaterial>> getRequiredMaterials(int orderId) async {
    final order = await _order(orderId);
    return requirementsFor(order.recipeId, order.targetQty);
  }

  /// Required vs. available (non-expired) stock, with the FEFO plan and estimated cost.
  Future<List<MaterialAvailability>> previewMaterials(int recipeId, double orderQty) async {
    final stock = StockService(db);
    final reqs = await requirementsFor(recipeId, orderQty);
    final out = <MaterialAvailability>[];
    for (final r in reqs) {
      final batches = await db.getAvailableBatches(r.item.id);
      final now = DateTime.now();
      final avail = batches
          .where((b) => b.expiryDate == null || !b.expiryDate!.isBefore(now))
          .fold<double>(0, (s, b) => s + b.currentQty);
      List<Allocation> plan = const [];
      if (avail + kQtyEpsilon >= r.requiredQty) {
        plan = await stock.planIssue(r.item, r.requiredQty, now: now);
      }
      out.add(MaterialAvailability(material: r, available: roundQty(avail), plan: plan));
    }
    return out;
  }

  // ====================== MATERIAL ISSUE ======================

  /// Issues ALL recipe materials for the order (FEFO, real batch cost).
  /// All-or-nothing: if anything is short nothing is issued.
  Future<void> issueRecipeMaterials(int orderId) async {
    final stock = StockService(db);
    await db.transaction(() async {
      final order = await _order(orderId);
      _requireStatus(order, ['Planned'], 'Material Issue');

      final already = await (db.select(db.productionIssues)
            ..where((i) => i.productionOrderId.equals(orderId)))
          .get();
      if (already.isNotEmpty) {
        throw StateException('এই অর্ডারে আগেই Material Issue হয়েছে');
      }

      final preview = await previewMaterials(order.recipeId, order.targetQty);
      final shorts = preview.where((m) => m.isShort).toList();
      if (shorts.isNotEmpty) {
        throw StateException('স্টক অপর্যাপ্ত:\n${shorts.map((m) => '• ${m.material.item.itemName}: দরকার ${m.material.requiredQty} ${m.material.item.baseUnit}, আছে ${m.available}').join('\n')}');
      }

      for (final m in preview) {
        await _issueAllocations(order, m.material.item, m.plan, stock);
      }

      await _recalcMaterialCost(orderId);
      await (db.update(db.productionOrders)..where((o) => o.id.equals(orderId))).write(
        ProductionOrdersCompanion(
          status: const Value('Mixing'),
          startDate: Value(DateTime.now()),
        ),
      );
      await _logStep(orderId, 'Issued', 'Material Issue সম্পন্ন (FEFO)');
    });
  }

  /// Extra issue (e.g. packaging, flavour top-up) after the order started.
  Future<void> issueExtraMaterial({
    required int orderId,
    required int itemId,
    required double qty,
  }) async {
    if (qty <= 0) throw ArgumentError('পরিমাণ ০ এর বেশি হতে হবে');
    final stock = StockService(db);
    await db.transaction(() async {
      final order = await _order(orderId);
      _requireStatus(order, ['Mixing', 'Aging', 'Freezing'], 'Extra Material Issue');
      final item = await (db.select(db.items)..where((i) => i.id.equals(itemId))).getSingle();
      final plan = await stock.planIssue(item, qty);
      await _issueAllocations(order, item, plan, stock);
      await _recalcMaterialCost(orderId);
    });
  }

  Future<void> _issueAllocations(
      ProductionOrder order, Item item, List<Allocation> plan, StockService stock) async {
    for (final a in plan) {
      await db.into(db.productionIssues).insert(ProductionIssuesCompanion.insert(
            productionOrderId: order.id,
            itemId: item.id,
            batchId: Value(a.batchId),
            qty: a.qty,
            unit: Value(item.baseUnit),
            unitCost: Value(a.unitCost),
            tankId: Value(order.mixingTankId),
          ));
    }
    await stock.applyIssue(
      itemId: item.id,
      allocations: plan,
      voucherType: 'ProductionIssue',
      voucherId: order.id,
      narration: 'Issued to ${order.orderNo}',
    );
    await stock.refreshAverageCost(item.id);
  }

  Future<void> _recalcMaterialCost(int orderId) async {
    final issues = await (db.select(db.productionIssues)
          ..where((i) => i.productionOrderId.equals(orderId)))
        .get();
    final total = issues.fold<double>(0, (s, i) => s + i.qty * (i.unitCost ?? 0));
    await (db.update(db.productionOrders)..where((o) => o.id.equals(orderId)))
        .write(ProductionOrdersCompanion(totalMaterialCost: Value(round2(total))));
  }

  // ====================== TANKS ======================

  Future<Tank> _freeTank(int id, String type, double qty) async {
    final t = await (db.select(db.tanks)..where((x) => x.id.equals(id))).getSingleOrNull();
    if (t == null) throw StateException('ট্যাংক পাওয়া যায়নি');
    if (t.tankType != type) throw StateException('${t.tankCode} একটি $type ট্যাংক নয়');
    if (t.status != 'Empty') {
      throw StateException('${t.tankCode} এখন "${t.status}" — খালি/পরিষ্কার ট্যাংক দরকার');
    }
    if (qty > t.capacityLiter + kQtyEpsilon) {
      throw StateException('${t.tankCode} এর ক্ষমতা ${t.capacityLiter} L, কিন্তু $qty L ঢালা যাবে না');
    }
    return t;
  }

  Future<void> _fillTank(int tankId, double qty, int itemId) =>
      (db.update(db.tanks)..where((t) => t.id.equals(tankId))).write(TanksCompanion(
        currentQty: Value(roundQty(qty)),
        status: const Value('InUse'),
        currentItemId: Value(itemId),
      ));

  /// After emptying, a tank needs cleaning (CIP) before reuse.
  Future<void> _releaseTank(int tankId) =>
      (db.update(db.tanks)..where((t) => t.id.equals(tankId))).write(const TanksCompanion(
        currentQty: Value(0),
        status: Value('Cleaning'),
        currentItemId: Value(null),
        currentBatchId: Value(null),
      ));

  Future<void> markTankClean(int tankId) async {
    final t = await (db.select(db.tanks)..where((x) => x.id.equals(tankId))).getSingle();
    if (t.status == 'InUse') throw StateException('${t.tankCode} এ এখনো মিক্স আছে');
    await (db.update(db.tanks)..where((x) => x.id.equals(tankId)))
        .write(const TanksCompanion(status: Value('Empty')));
  }

  // ====================== MIXING → AGING ======================

  /// Records actual mix volume and starts aging. If [agingTankId] (or the order's
  /// aging tank) is set the mix is transferred there and the mixing tank goes to Cleaning;
  /// otherwise the mix ages inside the mixing tank.
  Future<void> completeMixing({
    required int orderId,
    required double actualMixQty,
    int? mixingTankId,
    int? agingTankId,
  }) async {
    if (actualMixQty <= 0) throw ArgumentError('Actual Mix পরিমাণ ০ এর বেশি হতে হবে');
    await db.transaction(() async {
      final order = await _order(orderId);
      _requireStatus(order, ['Mixing'], 'Mixing সম্পন্ন');
      final recipe =
          await (db.select(db.recipes)..where((r) => r.id.equals(order.recipeId))).getSingle();

      final mixId = mixingTankId ?? order.mixingTankId;
      if (mixId == null) throw StateException('Mixing ট্যাংক সিলেক্ট করুন');
      final ageId = agingTankId ?? order.agingTankId;

      await _freeTank(mixId, 'Mixing', actualMixQty);
      final mixItemId = recipe.intermediateItemId ?? recipe.finishedItemId;
      await _fillTank(mixId, actualMixQty, mixItemId);

      if (ageId != null) {
        await _freeTank(ageId, 'Aging', actualMixQty);
        await _releaseTank(mixId);
        await _fillTank(ageId, actualMixQty, mixItemId);
      }

      // Intermediate mix batch (Semi) when recipe defines intermediateItemId
      int? interBatchId;
      if (recipe.intermediateItemId != null) {
        final interItem = await (db.select(db.items)
              ..where((i) => i.id.equals(recipe.intermediateItemId!)))
            .getSingle();
        final batchNo = await db.nextBatchNo('MIX');
        final unitCost = order.totalMaterialCost > 0 && actualMixQty > 0
            ? round2(order.totalMaterialCost / actualMixQty)
            : interItem.standardCost;
        interBatchId = await db.into(db.batches).insert(BatchesCompanion.insert(
              batchNo: batchNo,
              itemId: interItem.id,
              initialQty: roundQty(actualMixQty),
              currentQty: roundQty(actualMixQty),
              unitCost: Value(unitCost),
              mfgDate: Value(DateTime.now()),
              status: const Value('Available'),
            ));
        await db.into(db.stockLedger).insert(StockLedgerCompanion.insert(
              voucherType: 'ProductionReceipt',
              voucherId: Value(orderId),
              itemId: interItem.id,
              batchId: Value(interBatchId),
              qtyIn: Value(roundQty(actualMixQty)),
              unitCost: Value(unitCost),
              transactionDate: DateTime.now(),
              narration: Value('${order.orderNo} intermediate mix'),
            ));
      }

      await (db.update(db.productionOrders)..where((o) => o.id.equals(orderId))).write(
        ProductionOrdersCompanion(
          actualMixQty: Value(roundQty(actualMixQty)),
          mixingTankId: Value(mixId),
          agingTankId: Value(ageId),
          agingStartedAt: Value(DateTime.now()),
          intermediateBatchId: Value(interBatchId),
          status: const Value('Aging'),
        ),
      );
      await _logStep(orderId, 'Mixed',
          'Mixing সম্পন্ন, Aging শুরু (${roundQty(actualMixQty)} L)${interBatchId != null ? " · MIX batch #$interBatchId" : ""}');
    });
  }

  /// Aging → Freezing. Blocks if the recipe's minimum aging time has not passed
  /// (unless [force]).
  Future<void> startFreezing(int orderId, {bool force = false, DateTime? now}) async {
    await db.transaction(() async {
      final order = await _order(orderId);
      _requireStatus(order, ['Aging'], 'Freezing শুরু');
      final recipe =
          await (db.select(db.recipes)..where((r) => r.id.equals(order.recipeId))).getSingle();
      final t = now ?? DateTime.now();
      final start = order.agingStartedAt;
      if (!force && start != null) {
        final elapsed = agingElapsedHours(start, t);
        if (elapsed + 0.0001 < recipe.agingHours) {
          throw AgingNotCompleteException(recipe.agingHours - elapsed);
        }
      }
      final holder = order.agingTankId ?? order.mixingTankId;
      if (holder != null) await _releaseTank(holder);
      await (db.update(db.productionOrders)..where((o) => o.id.equals(orderId)))
          .write(const ProductionOrdersCompanion(status: Value('Freezing')));
      await _logStep(orderId, 'Freezing', 'Freezing শুরু');
    });
  }

  // ====================== COMPLETE ======================

  /// Freezing → Completed: creates the finished-goods batch, receipt and ledger entry,
  /// with cost = (materials + other cost) / finished liters.
  Future<int> completeProduction({
    required int orderId,
    required double actualFinishedQty,
    String? finishedBatchNo,
    int? warehouseId,
    DateTime? mfgDate,
    DateTime? expiryDate,
    double otherCost = 0,
    double scrapQty = 0,
    String? scrapNotes,
    double byProductQty = 0,
    String? byProductNotes,
  }) async {
    if (actualFinishedQty <= 0) throw ArgumentError('Finished পরিমাণ ০ এর বেশি হতে হবে');
    if (otherCost < 0) throw ArgumentError('Other cost ঋণাত্মক হতে পারে না');
    if (scrapQty < 0) throw ArgumentError('Scrap ঋণাত্মক হতে পারে না');
    final stock = StockService(db);

    return db.transaction(() async {
      final order = await _order(orderId);
      _requireStatus(order, ['Freezing'], 'Production সম্পন্ন');
      final mix = order.actualMixQty;
      if (mix == null || mix <= 0) throw StateException('Actual Mix Qty রেকর্ড করা হয়নি');

      final overrun = calcOverrunPercent(mix, actualFinishedQty);
      if (overrun < 0) {
        throw ArgumentError(
            'Finished ($actualFinishedQty L) Mix ($mix L) এর চেয়ে কম হতে পারে না — Overrun ঋণাত্মক হয়ে যায়। পরিমাণ আবার দেখুন');
      }
      if (overrun > 300) {
        throw ArgumentError(
            'Overrun ${overrun.toStringAsFixed(0)}% অস্বাভাবিক (সর্বোচ্চ ৩০০%)। Finished পরিমাণ আবার দেখুন');
      }

      final recipe =
          await (db.select(db.recipes)..where((r) => r.id.equals(order.recipeId))).getSingle();
      final fg =
          await (db.select(db.items)..where((i) => i.id.equals(recipe.finishedItemId))).getSingle();
      final wh = warehouseId ?? (await db.getDefaultWarehouse())?.id;
      if (wh == null) throw StateException('কোনো Warehouse নেই');

      final mfg = mfgDate ?? DateTime.now();
      final expiry = expiryDate ?? expiryFromShelfLife(mfg, fg.shelfLifeDays);
      if (expiry != null && expiry.isBefore(mfg)) {
        throw ArgumentError('মেয়াদ উত্তীর্ণের তারিখ উৎপাদন তারিখের আগে হতে পারে না');
      }

      final bn = (finishedBatchNo == null || finishedBatchNo.trim().isEmpty)
          ? await db.nextBatchNo('FG', now: mfg)
          : finishedBatchNo.trim();
      final dup = await (db.select(db.batches)
            ..where((b) => b.itemId.equals(fg.id) & b.batchNo.equals(bn)))
          .get();
      if (dup.isNotEmpty) throw StateException('Batch "$bn" এই আইটেমের জন্য আগেই আছে');

      final unitCost = double.parse(costPerFinishedUnit(
        materialCost: order.totalMaterialCost,
        otherCost: otherCost,
        finishedQty: actualFinishedQty,
      ).toStringAsFixed(4));

      final batchId = await db.into(db.batches).insert(BatchesCompanion.insert(
            batchNo: bn,
            itemId: fg.id,
            warehouseId: Value(wh),
            mfgDate: Value(mfg),
            expiryDate: Value(expiry),
            initialQty: actualFinishedQty,
            currentQty: actualFinishedQty,
            unitCost: Value(unitCost),
          ));

      await db.into(db.productionReceipts).insert(ProductionReceiptsCompanion.insert(
            productionOrderId: orderId,
            itemId: fg.id,
            batchNo: bn,
            qty: actualFinishedQty,
            unit: Value(fg.baseUnit),
            overrunPercent: Value(overrun),
            unitCost: Value(unitCost),
            mfgDate: Value(mfg),
            expiryDate: Value(expiry),
            warehouseId: Value(wh),
          ));

      await db.into(db.stockLedger).insert(StockLedgerCompanion.insert(
            voucherType: 'ProductionReceipt',
            voucherId: Value(orderId),
            itemId: fg.id,
            batchId: Value(batchId),
            warehouseId: Value(wh),
            qtyIn: Value(actualFinishedQty),
            unitCost: Value(unitCost),
            transactionDate: DateTime.now(),
            narration: Value('${order.orderNo} completed. Overrun ${overrun.toStringAsFixed(1)}%'),
          ));

      await stock.refreshAverageCost(fg.id);

      await (db.update(db.productionOrders)..where((o) => o.id.equals(orderId))).write(
        ProductionOrdersCompanion(
          actualFinishedQty: Value(roundQty(actualFinishedQty)),
          actualOverrun: Value(overrun),
          actualYield: Value(calcMixYieldPercent(mix, order.targetQty)),
          otherCost: Value(round2(otherCost)),
          scrapQty: Value(roundQty(scrapQty)),
          scrapNotes: Value(scrapNotes),
          byProductQty: Value(roundQty(byProductQty)),
          byProductNotes: Value(byProductNotes),
          status: const Value('Completed'),
          endDate: Value(DateTime.now()),
        ),
      );
      await _logStep(orderId, 'Completed', 'FG Receipt ${roundQty(actualFinishedQty)} L, Overrun ${overrun.toStringAsFixed(1)}%');
      return batchId;
    });
  }

  // ====================== CANCEL ======================

  /// Cancels an order that has not reached Freezing. Issued materials go back
  /// to their batches (with ledger reversal) and tanks are released.
  Future<void> cancelOrder(int orderId) async {
    await db.transaction(() async {
      final order = await _order(orderId);
      _requireStatus(order, ['Planned', 'Mixing', 'Aging'], 'Cancel');

      final issues = await (db.select(db.productionIssues)
            ..where((i) => i.productionOrderId.equals(orderId)))
          .get();
      for (final i in issues) {
        if (i.batchId == null) continue;
        final b = await (db.select(db.batches)..where((x) => x.id.equals(i.batchId!))).getSingle();
        await (db.update(db.batches)..where((x) => x.id.equals(b.id)))
            .write(BatchesCompanion(currentQty: Value(roundQty(b.currentQty + i.qty))));
        await db.into(db.stockLedger).insert(StockLedgerCompanion.insert(
              voucherType: 'ProductionIssueReversal',
              voucherId: Value(orderId),
              itemId: i.itemId,
              batchId: Value(b.id),
              warehouseId: Value(b.warehouseId),
              qtyIn: Value(i.qty),
              unitCost: Value(i.unitCost),
              transactionDate: DateTime.now(),
              narration: Value('Reversal: ${order.orderNo} cancelled'),
            ));
      }
      if (order.status == 'Aging') {
        final holder = order.agingTankId ?? order.mixingTankId;
        if (holder != null) await _releaseTank(holder);
      }
      await (db.update(db.productionOrders)..where((o) => o.id.equals(orderId))).write(
        ProductionOrdersCompanion(
          status: const Value('Cancelled'),
          totalMaterialCost: const Value(0),
          endDate: Value(DateTime.now()),
        ),
      );
      await _logStep(orderId, 'Cancelled', 'Order বাতিল, স্টক ফেরত');
      final stock = StockService(db);
      for (final itemId in issues.map((i) => i.itemId).toSet()) {
        await stock.refreshAverageCost(itemId);
      }
    });
  }

  // ====================== DETAILS ======================

  Future<OrderDetails> getOrderDetails(int orderId) async {
    final order = await _order(orderId);
    final recipe =
        await (db.select(db.recipes)..where((r) => r.id.equals(order.recipeId))).getSingle();
    final fg = await (db.select(db.items)..where((i) => i.id.equals(recipe.finishedItemId)))
        .getSingleOrNull();
    final issues = await (db.select(db.productionIssues)
          ..where((i) => i.productionOrderId.equals(orderId))
          ..orderBy([(i) => OrderingTerm.asc(i.id)]))
        .get();

    final lines = <IssueLine>[];
    for (final i in issues) {
      final item =
          await (db.select(db.items)..where((x) => x.id.equals(i.itemId))).getSingleOrNull();
      String? bn;
      if (i.batchId != null) {
        bn = (await (db.select(db.batches)..where((b) => b.id.equals(i.batchId!))).getSingleOrNull())
            ?.batchNo;
      }
      lines.add(IssueLine(i, item, bn));
    }

    Future<Tank?> tank(int? id) => id == null
        ? Future.value(null)
        : (db.select(db.tanks)..where((t) => t.id.equals(id))).getSingleOrNull();

    return OrderDetails(
      order: order,
      recipe: recipe,
      finishedItem: fg,
      issues: lines,
      mixingTank: await tank(order.mixingTankId),
      agingTank: await tank(order.agingTankId),
    );
  }


  // ====================== PHASE 1/2: EBR, QC, GENEALOGY ======================

  Future<void> _logStep(
    int orderId,
    String step,
    String action, {
    String? notes,
    String? operatorName,
  }) async {
    await db.into(db.productionStepLogs).insert(ProductionStepLogsCompanion.insert(
          productionOrderId: orderId,
          step: step,
          action: action,
          notes: Value(notes),
          operatorName: Value(operatorName),
        ));
  }

  /// Suggest empty tanks that can hold [qty] liters.
  Future<({List<Tank> mixing, List<Tank> aging})> suggestTanks(double qty) async {
    final tanks = await db.select(db.tanks).get();
    final mixing = tanks
        .where((t) => t.tankType == 'Mixing' && t.status == 'Empty' && t.capacityLiter >= qty)
        .toList()
      ..sort((a, b) => a.capacityLiter.compareTo(b.capacityLiter));
    final aging = tanks
        .where((t) => t.tankType == 'Aging' && t.status == 'Empty' && t.capacityLiter >= qty)
        .toList()
      ..sort((a, b) => a.capacityLiter.compareTo(b.capacityLiter));
    return (mixing: mixing, aging: aging);
  }

  Future<List<ProductionStepLog>> getStepLogs(int orderId) async {
    return (db.select(db.productionStepLogs)
          ..where((l) => l.productionOrderId.equals(orderId))
          ..orderBy([(l) => OrderingTerm.asc(l.createdAt)]))
        .get();
  }

  Future<List<RecipeQcTest>> getRecipeQcTests(int recipeId, {String? stage}) async {
    final q = db.select(db.recipeQcTests)..where((t) => t.recipeId.equals(recipeId));
    if (stage != null) q.where((t) => t.stage.equals(stage));
    q.orderBy([(t) => OrderingTerm.asc(t.sequence), (t) => OrderingTerm.asc(t.id)]);
    return q.get();
  }

  Future<List<ProductionQcResult>> getQcResults(int orderId) async {
    return (db.select(db.productionQcResults)
          ..where((r) => r.productionOrderId.equals(orderId))
          ..orderBy([(r) => OrderingTerm.asc(r.recordedAt)]))
        .get();
  }

  /// Record a QC result. If any test fails, order goes to Held.
  Future<void> recordQcResult({
    required int orderId,
    required String stage,
    required String testName,
    double? actualValue,
    required String result,
    int? recipeQcTestId,
    String? notes,
    String? recordedBy,
  }) async {
    if (!['Pass', 'Fail', 'N/A'].contains(result)) {
      throw ArgumentError('result must be Pass / Fail / N/A');
    }
    await db.transaction(() async {
      final order = await _order(orderId);
      if (order.status == 'Cancelled') {
        throw StateException('Cancelled অর্ডারে QC রেকর্ড করা যাবে না');
      }
      await db.into(db.productionQcResults).insert(ProductionQcResultsCompanion.insert(
            productionOrderId: orderId,
            recipeQcTestId: Value(recipeQcTestId),
            stage: stage,
            testName: testName,
            actualValue: Value(actualValue),
            result: result,
            notes: Value(notes),
            recordedBy: Value(recordedBy),
          ));
      await _logStep(orderId, 'QC', '$stage: $testName = $result',
          notes: notes, operatorName: recordedBy);

      if (result == 'Fail') {
        await (db.update(db.productionOrders)..where((o) => o.id.equals(orderId))).write(
          ProductionOrdersCompanion(
            qcStatus: const Value('Held'),
            holdReason: Value(notes ?? '$testName ব্যর্থ'),
          ),
        );
        await _logStep(orderId, 'Hold', 'QC Fail: $testName',
            notes: notes, operatorName: recordedBy);
      }
    });
  }

  Future<void> finalizeQc(int orderId, {String? operatorName}) async {
    await db.transaction(() async {
      final order = await _order(orderId);
      final tests = await getRecipeQcTests(order.recipeId, stage: 'Final');
      final results = await getQcResults(orderId);
      final finalResults = results.where((r) => r.stage == 'Final').toList();

      for (final t in tests.where((x) => x.isMandatory)) {
        final ok = finalResults.any(
            (r) => (r.recipeQcTestId == t.id || r.testName == t.testName) && r.result == 'Pass');
        if (!ok) {
          throw StateException('বাধ্যতামূলক QC "${t.testName}" এখনো Pass হয়নি');
        }
      }
      if (order.qcStatus == 'Held') {
        throw StateException('অর্ডার Held অবস্থায় — আগে Release করুন');
      }
      await (db.update(db.productionOrders)..where((o) => o.id.equals(orderId))).write(
        ProductionOrdersCompanion(
          qcStatus: const Value('Passed'),
          signedAt: Value(DateTime.now()),
          operatorName: Value(operatorName ?? order.operatorName),
        ),
      );
      await _logStep(orderId, 'QC', 'Final QC Passed + Signed', operatorName: operatorName);
    });
  }

  Future<void> holdOrder(int orderId, String reason, {String? operatorName}) async {
    await db.transaction(() async {
      final order = await _order(orderId);
      if (order.status == 'Cancelled' || order.status == 'Completed') {
        throw StateException('এই স্ট্যাটাসে Hold করা যায় না');
      }
      await (db.update(db.productionOrders)..where((o) => o.id.equals(orderId))).write(
        ProductionOrdersCompanion(
          qcStatus: const Value('Held'),
          holdReason: Value(reason),
        ),
      );
      await _logStep(orderId, 'Hold', reason, operatorName: operatorName);
    });
  }

  Future<void> releaseOrder(int orderId, {String? notes, String? operatorName}) async {
    await db.transaction(() async {
      final order = await _order(orderId);
      if (order.qcStatus != 'Held') throw StateException('অর্ডার Held নয়');
      await (db.update(db.productionOrders)..where((o) => o.id.equals(orderId))).write(
        const ProductionOrdersCompanion(
          qcStatus: Value('Pending'),
          holdReason: Value(null),
        ),
      );
      await _logStep(orderId, 'Release', notes ?? 'Hold মুক্ত', operatorName: operatorName);
    });
  }

  Future<Genealogy> getGenealogy(int orderId) async {
    final order = await _order(orderId);
    final issues = await (db.select(db.productionIssues)
          ..where((i) => i.productionOrderId.equals(orderId)))
        .get();
    final receipts = await (db.select(db.productionReceipts)
          ..where((r) => r.productionOrderId.equals(orderId)))
        .get();

    final rawLines = <GenealogyRawLine>[];
    for (final i in issues) {
      final item = await (db.select(db.items)..where((x) => x.id.equals(i.itemId))).getSingleOrNull();
      Batch? batch;
      if (i.batchId != null) {
        batch = await (db.select(db.batches)..where((b) => b.id.equals(i.batchId!))).getSingleOrNull();
      }
      rawLines.add(GenealogyRawLine(
        itemName: item?.itemName ?? '#${i.itemId}',
        itemCode: item?.itemCode ?? '',
        batchNo: batch?.batchNo,
        batchId: i.batchId,
        qty: i.qty,
        unitCost: i.unitCost,
        issuedAt: i.issuedAt,
      ));
    }

    final fgLines = <GenealogyFgLine>[];
    for (final r in receipts) {
      final batch = await (db.select(db.batches)
            ..where((b) => b.itemId.equals(r.itemId) & b.batchNo.equals(r.batchNo)))
          .getSingleOrNull();
      final sales = <GenealogySaleLine>[];
      if (batch != null) {
        final ledgers = await (db.select(db.stockLedger)
              ..where((l) =>
                  l.batchId.equals(batch.id) &
                  l.voucherType.equals('Sales') &
                  l.qtyOut.isBiggerThanValue(0)))
            .get();
        for (final l in ledgers) {
          String? partyName;
          if (l.voucherId != null) {
            final v = await (db.select(db.vouchers)..where((x) => x.id.equals(l.voucherId!)))
                .getSingleOrNull();
            if (v?.partyId != null) {
              final party = await (db.select(db.parties)..where((x) => x.id.equals(v!.partyId!)))
                  .getSingleOrNull();
              partyName = party?.partyName;
            }
          }
          sales.add(GenealogySaleLine(
            qty: l.qtyOut,
            date: l.transactionDate,
            voucherId: l.voucherId,
            partyName: partyName,
          ));
        }
      }
      fgLines.add(GenealogyFgLine(
        batchNo: r.batchNo,
        qty: r.qty,
        unitCost: r.unitCost,
        mfgDate: r.mfgDate,
        expiryDate: r.expiryDate,
        receivedAt: r.receivedAt,
        sales: sales,
      ));
    }

    return Genealogy(order: order, rawMaterials: rawLines, finishedGoods: fgLines);
  }

  Future<List<GenealogyUsage>> findUsagesOfBatch(int batchId) async {
    final issues = await (db.select(db.productionIssues)..where((i) => i.batchId.equals(batchId))).get();
    final out = <GenealogyUsage>[];
    for (final i in issues) {
      final order = await _order(i.productionOrderId);
      final receipts = await (db.select(db.productionReceipts)
            ..where((r) => r.productionOrderId.equals(i.productionOrderId)))
          .get();
      out.add(GenealogyUsage(
        orderNo: order.orderNo,
        orderId: order.id,
        status: order.status,
        qtyUsed: i.qty,
        fgBatches: receipts.map((r) => r.batchNo).toList(),
      ));
    }
    return out;
  }

  Future<void> seedDefaultQcTests(int recipeId) async {
    final existing = await getRecipeQcTests(recipeId);
    if (existing.isNotEmpty) return;
    final defaults = <(String, String, double?, double?, double?, String?)>[
      ('Mixing', 'Mix Temperature', 4.0, 2.0, 6.0, '°C'),
      ('Aging', 'Aging Hours', null, 4.0, null, 'hr'),
      ('Freezing', 'Overrun %', 100.0, 80.0, 120.0, '%'),
      ('Final', 'Taste / Sensory', null, null, null, null),
      ('Final', 'Visual Appearance', null, null, null, null),
      ('Final', 'Package Integrity', null, null, null, null),
    ];
    var seq = 0;
    for (final d in defaults) {
      await db.into(db.recipeQcTests).insert(RecipeQcTestsCompanion.insert(
            recipeId: recipeId,
            stage: d.$1,
            testName: d.$2,
            targetValue: Value(d.$3),
            minValue: Value(d.$4),
            maxValue: Value(d.$5),
            unit: Value(d.$6),
            sequence: Value(seq++),
          ));
    }
  }

  // ====================== PHASE 3: RECIPE VERSIONING ======================

  Future<void> approveRecipe(int recipeId, {String? operatorName}) async {
    final r = await (db.select(db.recipes)..where((x) => x.id.equals(recipeId))).getSingle();
    if (r.approvalStatus == 'Obsolete') throw StateException('Obsolete recipe approve করা যায় না');
    await (db.update(db.recipes)..where((x) => x.id.equals(recipeId))).write(
      const RecipesCompanion(approvalStatus: Value('Approved'), isActive: Value(true)),
    );
  }

  Future<void> obsoleteRecipe(int recipeId) async {
    await (db.update(db.recipes)..where((x) => x.id.equals(recipeId))).write(
      const RecipesCompanion(approvalStatus: Value('Obsolete'), isActive: Value(false)),
    );
  }

  /// Creates a new Draft version (version+1) copying lines + QC tests. Old stays Approved until you obsolete it.
  Future<int> createRecipeVersion(int recipeId, {String? notes}) async {
    return db.transaction(() async {
      final r = await (db.select(db.recipes)..where((x) => x.id.equals(recipeId))).getSingle();
      final lines = await (db.select(db.recipeLines)..where((l) => l.recipeId.equals(recipeId))).get();
      final qcs = await (db.select(db.recipeQcTests)..where((t) => t.recipeId.equals(recipeId))).get();

      final newCode = '${r.recipeCode}-v${r.version + 1}';
      final exists = await (db.select(db.recipes)..where((x) => x.recipeCode.equals(newCode))).get();
      final code = exists.isEmpty ? newCode : '${r.recipeCode}-v${r.version + 1}-${DateTime.now().millisecondsSinceEpoch % 1000}';

      final newId = await db.into(db.recipes).insert(RecipesCompanion.insert(
            recipeCode: code,
            recipeName: r.recipeName,
            finishedItemId: r.finishedItemId,
            baseQty: r.baseQty,
            baseUnit: r.baseUnit,
            targetOverrun: Value(r.targetOverrun),
            expectedYield: Value(r.expectedYield),
            agingHours: Value(r.agingHours),
            version: Value(r.version + 1),
            approvalStatus: const Value('Draft'),
            parentRecipeId: Value(r.id),
            isActive: const Value(true),
            notes: Value(notes ?? 'Version ${r.version + 1} of ${r.recipeCode}'),
          ));
      for (final l in lines) {
        await db.into(db.recipeLines).insert(RecipeLinesCompanion.insert(
              recipeId: newId,
              itemId: l.itemId,
              qty: l.qty,
              unit: l.unit,
              wastagePercent: Value(l.wastagePercent),
              sequence: Value(l.sequence),
            ));
      }
      for (final t in qcs) {
        await db.into(db.recipeQcTests).insert(RecipeQcTestsCompanion.insert(
              recipeId: newId,
              stage: t.stage,
              testName: t.testName,
              targetValue: Value(t.targetValue),
              minValue: Value(t.minValue),
              maxValue: Value(t.maxValue),
              unit: Value(t.unit),
              isMandatory: Value(t.isMandatory),
              sequence: Value(t.sequence),
            ));
      }
      return newId;
    });
  }

  // ====================== PHASE 4: CAPACITY + DEMAND ======================

  /// Tanks currently in use or cleaning, plus open production orders occupying capacity.
  Future<List<CapacityRow>> getCapacitySnapshot() async {
    final tanks = await db.select(db.tanks).get();
    final open = await (db.select(db.productionOrders)
          ..where((o) => o.status.isIn(['Planned', 'Mixing', 'Aging', 'Freezing'])))
        .get();
    final rows = <CapacityRow>[];
    for (final t in tanks) {
      ProductionOrder? order;
      for (final o in open) {
        if (o.mixingTankId == t.id || o.agingTankId == t.id) {
          order = o;
          break;
        }
      }
      rows.add(CapacityRow(tank: t, occupyingOrder: order));
    }
    rows.sort((a, b) {
      final c = a.tank.tankType.compareTo(b.tank.tankType);
      return c != 0 ? c : a.tank.tankCode.compareTo(b.tank.tankCode);
    });
    return rows;
  }

  /// Suggest production for finished items below min stock (simple demand).
  Future<List<DemandSuggestion>> suggestDemandOrders() async {
    final items = await (db.select(db.items)
          ..where((i) => i.itemType.equals('Finished') & i.isActive.equals(true)))
        .get();
    final out = <DemandSuggestion>[];
    for (final item in items) {
      final batches = await db.getAvailableBatches(item.id);
      final stock = batches.fold<double>(0, (s, b) => s + b.currentQty);
      if (stock >= item.minStock && item.minStock > 0) continue;
      if (item.minStock <= 0 && stock > 0) continue;
      // Find approved recipe for this FG
      final recipes = await (db.select(db.recipes)
            ..where((r) =>
                r.finishedItemId.equals(item.id) &
                r.isActive.equals(true) &
                r.approvalStatus.equals('Approved')))
          .get();
      if (recipes.isEmpty) continue;
      final recipe = recipes.first;
      final need = item.minStock > 0 ? (item.minStock - stock).clamp(0, double.infinity) : 500.0;
      // Scale to mix qty roughly: need finished / (1 + overrun/100)
      final overrun = recipe.targetOverrun;
      final mixNeed = need / (1 + overrun / 100);
      final target = mixNeed < 100 ? 100.0 : (mixNeed / 50).ceil() * 50.0;
      out.add(DemandSuggestion(
        finishedItem: item,
        recipe: recipe,
        currentStock: stock,
        minStock: item.minStock,
        suggestedMixQty: target,
      ));
    }
    return out;
  }

  /// Create PO from a demand suggestion (auto tank assign).
  Future<int> createFromDemand(DemandSuggestion s, {String? operatorName}) async {
    final tanks = await suggestTanks(s.suggestedMixQty);
    return createProductionOrder(
      recipeId: s.recipe.id,
      targetMixQty: s.suggestedMixQty,
      mixingTankId: tanks.mixing.isNotEmpty ? tanks.mixing.first.id : null,
      agingTankId: tanks.aging.isNotEmpty ? tanks.aging.first.id : null,
      sourceType: 'Demand',
      operatorName: operatorName,
      notes: 'Auto from demand: ${s.finishedItem.itemName} stock ${s.currentStock} < min ${s.minStock}',
    );
  }

  // ====================== PHASE A/B: ALLERGEN, LABEL, CCP, CAPA, MRP, E-SIGN ======================

  Future<String> recipeAllergens(int recipeId) async {
    final lines = await (db.select(db.recipeLines)..where((l) => l.recipeId.equals(recipeId))).get();
    final fields = <String?>[];
    for (final l in lines) {
      final item = await (db.select(db.items)..where((i) => i.id.equals(l.itemId))).getSingleOrNull();
      fields.add(item?.allergens);
    }
    return aggregateAllergens(fields);
  }

  Future<String> buildAndSaveLabel(int recipeId) async {
    final recipe = await (db.select(db.recipes)..where((r) => r.id.equals(recipeId))).getSingle();
    final lines = await (db.select(db.recipeLines)
          ..where((l) => l.recipeId.equals(recipeId))
          ..orderBy([(l) => OrderingTerm.asc(l.sequence)]))
        .get();
    final parts = <({String name, double qty, String unit})>[];
    for (final l in lines) {
      final item = await (db.select(db.items)..where((i) => i.id.equals(l.itemId))).getSingle();
      parts.add((name: item.itemName, qty: l.qty, unit: l.unit));
    }
    final ingredients = buildLabelIngredients(parts);
    final allergens = await recipeAllergens(recipeId);
    final claims = allergens.isEmpty ? recipe.labelClaims : 'Contains: $allergens';
    await (db.update(db.recipes)..where((r) => r.id.equals(recipeId))).write(
      RecipesCompanion(
        labelIngredients: Value(ingredients),
        labelClaims: Value(claims),
      ),
    );
    return ingredients;
  }

  Future<void> requireESign(int orderId, String signedBy, {String step = 'Sign'}) async {
    final name = signedBy.trim();
    if (name.isEmpty) throw StateException('e-Signature: অপারেটর নাম আবশ্যক');
    await (db.update(db.productionOrders)..where((o) => o.id.equals(orderId))).write(
      ProductionOrdersCompanion(
        signedBy: Value(name),
        signedAt: Value(DateTime.now()),
        operatorName: Value(name),
      ),
    );
    await _logStep(orderId, step, 'e-Sign: $name', operatorName: name);
  }

  Future<List<HaccpCcp>> getCcps({int? recipeId, String? stage}) async {
    final q = db.select(db.haccpCcps)..where((c) => c.isActive.equals(true));
    if (recipeId != null) {
      q.where((c) => c.recipeId.equals(recipeId) | c.recipeId.isNull());
    }
    if (stage != null) q.where((c) => c.stage.equals(stage));
    q.orderBy([(c) => OrderingTerm.asc(c.sequence)]);
    return q.get();
  }

  Future<void> seedDefaultCcps(int recipeId) async {
    final existing = await (db.select(db.haccpCcps)..where((c) => c.recipeId.equals(recipeId))).get();
    if (existing.isNotEmpty) return;
    final defs = [
      ('Mixing', 'Mix Temperature CCP', 'Biological growth', 2.0, 6.0, '°C', 'Thermometer every 30 min', 'Hold batch, adjust temp, recheck'),
      ('Aging', 'Aging Time CCP', 'Incomplete hydration', 4.0, null, 'hr', 'Timer log', 'Extend aging until min hours'),
      ('Freezing', 'Overrun CCP', 'Texture defect', 80.0, 120.0, '%', 'Overrun gauge', 'Adjust air, reprocess if critical'),
      ('Final', 'Metal / Foreign body', 'Physical hazard', null, null, null, 'Visual + magnet', 'Segregate, investigate source'),
    ];
    var seq = 0;
    for (final d in defs) {
      await db.into(db.haccpCcps).insert(HaccpCcpsCompanion.insert(
            recipeId: Value(recipeId),
            stage: d.$1,
            ccpName: d.$2,
            hazard: Value(d.$3),
            minLimit: Value(d.$4),
            maxLimit: Value(d.$5),
            unit: Value(d.$6),
            monitoringMethod: Value(d.$7),
            correctiveAction: Value(d.$8),
            sequence: Value(seq++),
          ));
    }
  }

  Future<void> recordCcp({
    required int orderId,
    required String stage,
    required String ccpName,
    double? actualValue,
    required String status, // WithinLimit, OutOfLimit, N/A
    int? haccpCcpId,
    String? notes,
    String? recordedBy,
    bool autoDeviationOnOol = true,
  }) async {
    if (!['WithinLimit', 'OutOfLimit', 'N/A'].contains(status)) {
      throw ArgumentError('CCP status invalid');
    }
    await db.transaction(() async {
      await db.into(db.productionCcpLogs).insert(ProductionCcpLogsCompanion.insert(
            productionOrderId: orderId,
            haccpCcpId: Value(haccpCcpId),
            stage: stage,
            ccpName: ccpName,
            actualValue: Value(actualValue),
            status: status,
            notes: Value(notes),
            recordedBy: Value(recordedBy),
          ));
      await _logStep(orderId, 'CCP', '$stage/$ccpName = $status',
          notes: notes, operatorName: recordedBy);
      if (status == 'OutOfLimit' && autoDeviationOnOol) {
        await _createDeviationInternal(
          orderId: orderId,
          title: 'CCP OOL: $ccpName',
          description: notes ?? 'Actual: $actualValue',
          severity: 'Major',
          reportedBy: recordedBy,
        );
        await holdOrder(orderId, 'CCP OutOfLimit: $ccpName', operatorName: recordedBy);
      }
    });
  }

  Future<List<ProductionCcpLog>> getCcpLogs(int orderId) async {
    return (db.select(db.productionCcpLogs)
          ..where((l) => l.productionOrderId.equals(orderId))
          ..orderBy([(l) => OrderingTerm.asc(l.recordedAt)]))
        .get();
  }

  Future<String> _nextDeviationNo() async {
    final n = await db.customSelect('SELECT COUNT(*) AS c FROM deviations').getSingle();
    final c = n.read<int>('c') + 1;
    return 'DEV-${c.toString().padLeft(4, '0')}';
  }

  Future<String> _nextCapaNo() async {
    final n = await db.customSelect('SELECT COUNT(*) AS c FROM capas').getSingle();
    final c = n.read<int>('c') + 1;
    return 'CAPA-${c.toString().padLeft(4, '0')}';
  }

  Future<int> _createDeviationInternal({
    required int orderId,
    required String title,
    String? description,
    String severity = 'Minor',
    String? reportedBy,
  }) async {
    final no = await _nextDeviationNo();
    return db.into(db.deviations).insert(DeviationsCompanion.insert(
          productionOrderId: Value(orderId),
          deviationNo: no,
          title: title,
          description: Value(description),
          severity: Value(severity),
          reportedBy: Value(reportedBy),
        ));
  }

  Future<int> createDeviation({
    required int orderId,
    required String title,
    String? description,
    String severity = 'Minor',
    String? reportedBy,
  }) async {
    final id = await _createDeviationInternal(
      orderId: orderId,
      title: title,
      description: description,
      severity: severity,
      reportedBy: reportedBy,
    );
    await _logStep(orderId, 'Deviation', '$title [$severity]', operatorName: reportedBy);
    return id;
  }

  Future<int> createCapa({
    required int deviationId,
    required String action,
    String actionType = 'Corrective',
    String? owner,
    DateTime? dueDate,
  }) async {
    final no = await _nextCapaNo();
    return db.into(db.capas).insert(CapasCompanion.insert(
          deviationId: deviationId,
          capaNo: no,
          actionType: actionType,
          action: action,
          owner: Value(owner),
          dueDate: Value(dueDate),
        ));
  }

  Future<void> closeDeviation(int deviationId, {String? notes}) async {
    await (db.update(db.deviations)..where((d) => d.id.equals(deviationId))).write(
      DeviationsCompanion(
        status: const Value('Closed'),
        closedAt: Value(DateTime.now()),
        description: notes != null ? Value(notes) : const Value.absent(),
      ),
    );
  }

  Future<List<Deviation>> getDeviations({int? orderId}) async {
    final q = db.select(db.deviations);
    if (orderId != null) q.where((d) => d.productionOrderId.equals(orderId));
    q.orderBy([(d) => OrderingTerm.desc(d.reportedAt)]);
    return q.get();
  }

  Future<List<Capa>> getCapas(int deviationId) async {
    return (db.select(db.capas)..where((c) => c.deviationId.equals(deviationId))).get();
  }

  /// Simple MRP: materials short for open Planned/Mixing orders + FG demand gaps.
  Future<List<MrpLine>> runMrp() async {
    final open = await (db.select(db.productionOrders)
          ..where((o) => o.status.isIn(['Planned', 'Mixing'])))
        .get();
    final need = <int, double>{}; // itemId -> qty
    final names = <int, String>{};
    for (final o in open) {
      final reqs = await requirementsFor(o.recipeId, o.targetQty);
      // subtract already issued
      final issued = await (db.select(db.productionIssues)
            ..where((i) => i.productionOrderId.equals(o.id)))
          .get();
      final issuedMap = <int, double>{};
      for (final i in issued) {
        issuedMap[i.itemId] = (issuedMap[i.itemId] ?? 0) + i.qty;
      }
      for (final r in reqs) {
        final left = r.requiredQty - (issuedMap[r.item.id] ?? 0);
        if (left > kQtyEpsilon) {
          need[r.item.id] = (need[r.item.id] ?? 0) + left;
          names[r.item.id] = r.item.itemName;
        }
      }
    }
    // Also FG min stock gaps as finished demand (informational raw roll-up skipped for simplicity)
    final out = <MrpLine>[];
    final now = DateTime.now();
    for (final e in need.entries) {
      final batches = await db.getAvailableBatches(e.key);
      final avail = batches
          .where((b) => b.expiryDate == null || !b.expiryDate!.isBefore(now))
          .fold<double>(0, (s, b) => s + b.currentQty);
      final short = e.value - avail;
      if (short > kQtyEpsilon) {
        final item = await (db.select(db.items)..where((i) => i.id.equals(e.key))).getSingle();
        out.add(MrpLine(
          itemId: e.key,
          itemCode: item.itemCode,
          itemName: item.itemName,
          requiredQty: roundQty(e.value),
          availableQty: roundQty(avail),
          shortageQty: roundQty(short),
          unit: item.baseUnit,
        ));
      }
    }
    out.sort((a, b) => b.shortageQty.compareTo(a.shortageQty));
    return out;
  }
}

class MrpLine {
  MrpLine({
    required this.itemId,
    required this.itemCode,
    required this.itemName,
    required this.requiredQty,
    required this.availableQty,
    required this.shortageQty,
    required this.unit,
  });
  final int itemId;
  final String itemCode;
  final String itemName;
  final double requiredQty;
  final double availableQty;
  final double shortageQty;
  final String unit;
}

class CapacityRow {
  CapacityRow({required this.tank, this.occupyingOrder});
  final Tank tank;
  final ProductionOrder? occupyingOrder;
}

class DemandSuggestion {
  DemandSuggestion({
    required this.finishedItem,
    required this.recipe,
    required this.currentStock,
    required this.minStock,
    required this.suggestedMixQty,
  });
  final Item finishedItem;
  final Recipe recipe;
  final double currentStock;
  final double minStock;
  final double suggestedMixQty;
}

class GenealogyRawLine {
  GenealogyRawLine({
    required this.itemName,
    required this.itemCode,
    this.batchNo,
    this.batchId,
    required this.qty,
    this.unitCost,
    required this.issuedAt,
  });
  final String itemName;
  final String itemCode;
  final String? batchNo;
  final int? batchId;
  final double qty;
  final double? unitCost;
  final DateTime issuedAt;
}

class GenealogyFgLine {
  GenealogyFgLine({
    required this.batchNo,
    required this.qty,
    this.unitCost,
    this.mfgDate,
    this.expiryDate,
    required this.receivedAt,
    required this.sales,
  });
  final String batchNo;
  final double qty;
  final double? unitCost;
  final DateTime? mfgDate;
  final DateTime? expiryDate;
  final DateTime receivedAt;
  final List<GenealogySaleLine> sales;
}

class GenealogySaleLine {
  GenealogySaleLine({
    required this.qty,
    required this.date,
    this.voucherId,
    this.partyName,
  });
  final double qty;
  final DateTime date;
  final int? voucherId;
  final String? partyName;
}

class Genealogy {
  Genealogy({required this.order, required this.rawMaterials, required this.finishedGoods});
  final ProductionOrder order;
  final List<GenealogyRawLine> rawMaterials;
  final List<GenealogyFgLine> finishedGoods;
}

class GenealogyUsage {
  GenealogyUsage({
    required this.orderNo,
    required this.orderId,
    required this.status,
    required this.qtyUsed,
    required this.fgBatches,
  });
  final String orderNo;
  final int orderId;
  final String status;
  final double qtyUsed;
  final List<String> fgBatches;
}
