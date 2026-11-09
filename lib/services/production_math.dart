/// Pure (database-free) business rules. Everything here is unit-testable
/// without SQLite or Flutter.
library;

const double kQtyEpsilon = 0.0001;

/// Rounds money to 2 decimals (avoids floating point dust like 0.30000000000000004).
double round2(double v) => (v * 100).roundToDouble() / 100;

/// Rounds quantities to 4 decimals.
double roundQty(double v) => (v * 10000).roundToDouble() / 10000;

class InsufficientStockException implements Exception {
  InsufficientStockException(this.itemLabel, this.required, this.available);
  final String itemLabel;
  final double required;
  final double available;

  @override
  String toString() =>
      'স্টক অপর্যাপ্ত: $itemLabel — দরকার ${roundQty(required)}, আছে ${roundQty(available)}';
}

class UnitConversionException implements Exception {
  UnitConversionException(this.from, this.to);
  final String from;
  final String to;

  @override
  String toString() => 'ইউনিট কনভার্সন নেই: $from → $to (Item এ conversion যোগ করুন)';
}

class BatchLot {
  const BatchLot({
    required this.batchId,
    required this.qty,
    required this.unitCost,
    this.expiry,
    this.warehouseId,
    this.potencyValue,
  });
  final int batchId;
  final double qty;
  final double unitCost;
  final DateTime? expiry;
  final int? warehouseId;
  final double? potencyValue;
}

class Allocation {
  const Allocation({
    required this.batchId,
    required this.qty,
    required this.unitCost,
    this.warehouseId,
  });
  final int batchId;
  final double qty;
  final double unitCost;
  final int? warehouseId;
}

/// FEFO allocation: earliest expiry first, batches WITHOUT expiry go last
/// (SQLite sorts NULL first, which is wrong for FEFO). Expired batches are
/// never allocated. Throws [InsufficientStockException] if not enough usable stock.
List<Allocation> allocateFefo(
  List<BatchLot> lots,
  double required, {
  required DateTime now,
  String itemLabel = 'Item',
}) {
  if (required <= kQtyEpsilon) return const [];

  final usable = lots
      .where((l) => l.qty > kQtyEpsilon && (l.expiry == null || !l.expiry!.isBefore(now)))
      .toList()
    ..sort((a, b) {
      if (a.expiry == null && b.expiry == null) return a.batchId.compareTo(b.batchId);
      if (a.expiry == null) return 1;
      if (b.expiry == null) return -1;
      final c = a.expiry!.compareTo(b.expiry!);
      return c != 0 ? c : a.batchId.compareTo(b.batchId);
    });

  final available = usable.fold<double>(0, (s, l) => s + l.qty);
  if (available + kQtyEpsilon < required) {
    throw InsufficientStockException(itemLabel, required, available);
  }

  var remaining = required;
  final out = <Allocation>[];
  for (final lot in usable) {
    if (remaining <= kQtyEpsilon) break;
    final take = remaining < lot.qty ? remaining : lot.qty;
    out.add(Allocation(
      batchId: lot.batchId,
      qty: roundQty(take),
      unitCost: lot.unitCost,
      warehouseId: lot.warehouseId,
    ));
    remaining -= take;
  }
  return out;
}

/// Overrun % = (finished volume - mix volume) / mix volume * 100
double calcOverrunPercent(double mixQty, double finishedQty) {
  if (mixQty <= 0) return 0;
  return (finishedQty - mixQty) / mixQty * 100;
}

/// Mix Yield % = actual mix / target mix * 100
double calcMixYieldPercent(double actualMix, double targetMix) {
  if (targetMix <= 0) return 0;
  return actualMix / targetMix * 100;
}

/// Mix needed for a desired finished volume at a given overrun %.
double requiredMixForFinished(double finishedQty, double overrunPercent) =>
    finishedQty / (1 + overrunPercent / 100);

/// Cost per liter of finished ice cream = all absorbed cost / finished liters.
/// (Identical to (cost/mix) / (1+overrun) but numerically simpler.)
double costPerFinishedUnit({
  required double materialCost,
  double otherCost = 0,
  required double finishedQty,
}) {
  if (finishedQty <= 0) return 0;
  return (materialCost + otherCost) / finishedQty;
}

/// Required qty of a recipe line for a production order.
double scaledRequirement({
  required double lineQty,
  required double orderQty,
  required double recipeBaseQty,
  double wastagePercent = 0,
}) {
  if (recipeBaseQty <= 0) return 0;
  return lineQty * (orderQty / recipeBaseQty) * (1 + wastagePercent / 100);
}

/// Converts [qty] between units. Built-in: g<->Kg, ml<->L. Item-specific
/// factors are passed as '{from}>{to}' => factor (qty_to = qty_from * factor);
/// the reverse is derived automatically.
double convertQty(
  double qty,
  String from,
  String to, {
  Map<String, double> factors = const {},
}) {
  if (from == to) return qty;
  const builtin = <String, double>{
    'g>Kg': 0.001,
    'Kg>g': 1000,
    'ml>L': 0.001,
    'L>ml': 1000,
  };
  final direct = factors['$from>$to'] ?? builtin['$from>$to'];
  if (direct != null) return qty * direct;
  final reverse = factors['$to>$from'] ?? builtin['$to>$from'];
  if (reverse != null && reverse != 0) return qty / reverse;
  throw UnitConversionException(from, to);
}

/// Weighted-average unit cost after adding stock.
double weightedAverageCost({
  required double oldQty,
  required double oldCost,
  required double addQty,
  required double addCost,
}) {
  final total = oldQty + addQty;
  if (total <= 0) return addCost;
  if (oldQty <= 0) return addCost;
  return (oldQty * oldCost + addQty * addCost) / total;
}

DateTime? expiryFromShelfLife(DateTime mfg, int shelfLifeDays) =>
    shelfLifeDays > 0 ? mfg.add(Duration(days: shelfLifeDays)) : null;

/// Throws if [aging] has not yet satisfied [minHours]. Returns hours elapsed.
double agingElapsedHours(DateTime start, DateTime now) =>
    now.difference(start).inMinutes / 60.0;

/// Scale required qty by potency: if batch is weaker, need more material.
/// factor = standard / actual. If actual is null or <=0, returns [baseQty].
double scaleByPotency({
  required double baseQty,
  required double? standard,
  required double? actual,
}) {
  if (standard == null || standard <= 0) return baseQty;
  if (actual == null || actual <= 0) return baseQty;
  return roundQty(baseQty * (standard / actual));
}

/// Union of allergen tags from ingredient list (comma-separated on each item).
String aggregateAllergens(Iterable<String?> allergenFields) {
  final set = <String>{};
  for (final raw in allergenFields) {
    if (raw == null || raw.trim().isEmpty) continue;
    for (final p in raw.split(RegExp(r'[,;|/]'))) {
      final t = p.trim();
      if (t.isNotEmpty) set.add(t);
    }
  }
  final list = set.toList()..sort();
  return list.join(', ');
}

/// Simple ingredient statement from names + qtys.
String buildLabelIngredients(List<({String name, double qty, String unit})> lines) {
  final parts = lines.map((l) => '${l.name} (${roundQty(l.qty)} ${l.unit})').toList();
  return parts.join(', ');
}
