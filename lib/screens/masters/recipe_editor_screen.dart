import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/app_database.dart';
import '../../providers/database_provider.dart';
import '../../services/production_math.dart';
import '../../utils/ui.dart';
import 'item_list_screen.dart' show kUnits;

/// Create / edit a recipe header and its ingredient lines.
class RecipeEditorScreen extends ConsumerStatefulWidget {
  const RecipeEditorScreen({super.key, this.recipeId});
  final int? recipeId;

  @override
  ConsumerState<RecipeEditorScreen> createState() => _RecipeEditorScreenState();
}

class _RecipeEditorScreenState extends ConsumerState<RecipeEditorScreen> {
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _baseQty = TextEditingController(text: '1000');
  final _overrun = TextEditingController(text: '100');
  final _yield = TextEditingController(text: '98');
  final _aging = TextEditingController(text: '4');
  int? _finishedItemId;
  int? _id;
  bool _active = true;
  bool _loaded = false;

  List<Item> _items = [];

  @override
  void initState() {
    super.initState();
    _id = widget.recipeId;
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(databaseProvider);
    _items = await (db.select(db.items)
          ..where((i) => i.isActive.equals(true))
          ..orderBy([(i) => OrderingTerm.asc(i.itemCode)]))
        .get();
    if (_id != null) {
      final r = await (db.select(db.recipes)..where((x) => x.id.equals(_id!))).getSingle();
      _code.text = r.recipeCode;
      _name.text = r.recipeName;
      _baseQty.text = r.baseQty.toString();
      _overrun.text = r.targetOverrun.toString();
      _yield.text = r.expectedYield.toString();
      _aging.text = r.agingHours.toString();
      _finishedItemId = r.finishedItemId;
      _active = r.isActive;
    }
    if (mounted) setState(() => _loaded = true);
  }

  List<Item> get _finishedChoices =>
      _items.where((i) => i.itemType == 'Finished' || i.itemType == 'Semi' || i.itemType == 'Mix').toList();

  Future<void> _saveHeader() async {
    final code = _code.text.trim();
    final name = _name.text.trim();
    final base = parseNum(_baseQty.text);
    final over = parseNum(_overrun.text);
    final yld = parseNum(_yield.text);
    final aging = parseNum(_aging.text);
    if (code.isEmpty || name.isEmpty) { showSnack(context, 'Code ও Name দিন'); return; }
    if (_finishedItemId == null) { showSnack(context, 'Finished Item সিলেক্ট করুন'); return; }
    if (base == null || base <= 0) { showSnack(context, 'Base Qty ০ এর বেশি হতে হবে'); return; }
    if (over == null || over < 0 || over > 300) { showSnack(context, 'Overrun ০–৩০০% এর মধ্যে দিন'); return; }
    if (yld == null || yld <= 0 || yld > 100) { showSnack(context, 'Yield ০–১০০% এর মধ্যে দিন'); return; }
    if (aging == null || aging < 0) { showSnack(context, 'Aging ঘণ্টা ঠিকভাবে দিন'); return; }

    final db = ref.read(databaseProvider);
    final ok = await runGuarded(context, () async {
      if (_id == null) {
        _id = await db.into(db.recipes).insert(RecipesCompanion.insert(
              recipeCode: code,
              recipeName: name,
              finishedItemId: _finishedItemId!,
              baseQty: base,
              baseUnit: 'L',
              targetOverrun: Value(over),
              expectedYield: Value(yld),
              agingHours: Value(aging),
            ));
      } else {
        await (db.update(db.recipes)..where((r) => r.id.equals(_id!))).write(RecipesCompanion(
          recipeCode: Value(code),
          recipeName: Value(name),
          finishedItemId: Value(_finishedItemId!),
          baseQty: Value(base),
          targetOverrun: Value(over),
          expectedYield: Value(yld),
          agingHours: Value(aging),
          isActive: Value(_active),
        ));
      }
    }, success: 'রেসিপি সেভ হয়েছে');
    if (ok && mounted) setState(() {});
  }

  Future<void> _addLine() async {
    if (_id == null) { showSnack(context, 'আগে রেসিপি হেডার সেভ করুন'); return; }
    final db = ref.read(databaseProvider);
    final choices = _items.where((i) => i.itemType != 'Finished').toList();
    if (choices.isEmpty) { showSnack(context, 'আগে Item Master এ কাঁচামাল যোগ করুন'); return; }

    Item sel = choices.first;
    String unit = sel.baseUnit;
    final qty = TextEditingController();
    final waste = TextEditingController(text: '0');

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('ইনগ্রিডিয়েন্ট যোগ'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  isExpanded: true,
                  value: sel.id,
                  decoration: const InputDecoration(labelText: 'Item'),
                  items: choices
                      .map((i) => DropdownMenuItem(value: i.id, child: Text('${i.itemCode} - ${i.itemName}', overflow: TextOverflow.ellipsis)))
                      .toList(),
                  onChanged: (v) => setD(() {
                    sel = choices.firstWhere((i) => i.id == v);
                    unit = sel.baseUnit;
                  }),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: qty,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Qty (Base Qty এর জন্য)'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      value: unit,
                      decoration: const InputDecoration(labelText: 'Unit'),
                      items: {...kUnits, unit}.map((u) => DropdownMenuItem(value: u, child: Text(u))).toList(),
                      onChanged: (v) => setD(() => unit = v!),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                TextField(
                  controller: waste,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Wastage %'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            FilledButton(
              onPressed: () async {
                final q = parseNum(qty.text);
                final w = parseNum(waste.text) ?? 0;
                if (q == null || q <= 0) { showSnack(ctx, 'Qty ০ এর বেশি হতে হবে'); return; }
                if (w < 0 || w > 50) { showSnack(ctx, 'Wastage ০–৫০% এর মধ্যে দিন'); return; }
                final ok = await runGuarded(ctx, () async {
                  // Reject units that cannot be converted to the item's base unit.
                  final rows = await (db.select(db.unitConversions)
                        ..where((c) => c.itemId.equals(sel.id)))
                      .get();
                  convertQty(1, unit, sel.baseUnit, factors: {
                    for (final r in rows) '${r.fromUnit}>${r.toUnit}': r.conversionFactor
                  });
                  final dup = await (db.select(db.recipeLines)
                        ..where((l) => l.recipeId.equals(_id!) & l.itemId.equals(sel.id)))
                      .get();
                  if (dup.isNotEmpty) {
                    throw ArgumentError('${sel.itemName} আগেই যোগ করা আছে — আগেরটি মুছে/এডিট করুন');
                  }
                  final count = (await (db.select(db.recipeLines)..where((l) => l.recipeId.equals(_id!))).get()).length;
                  await db.into(db.recipeLines).insert(RecipeLinesCompanion.insert(
                        recipeId: _id!,
                        itemId: sel.id,
                        qty: q,
                        unit: unit,
                        wastagePercent: Value(w),
                        sequence: Value(count + 1),
                      ));
                });
                if (ok && ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('যোগ করুন'),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _deleteLine(RecipeLine l) async {
    if (!await confirm(context, 'মুছবেন?', 'এই ইনগ্রিডিয়েন্টটি রেসিপি থেকে সরানো হবে।')) return;
    final db = ref.read(databaseProvider);
    await (db.delete(db.recipeLines)..where((x) => x.id.equals(l.id))).go();
    if (mounted) setState(() {});
  }

  /// Cost estimate using each item's current average cost.
  Widget _costSummary(List<RecipeLine> lines) {
    final base = parseNum(_baseQty.text) ?? 0;
    final over = parseNum(_overrun.text) ?? 0;
    final byId = {for (final i in _items) i.id: i};
    var total = 0.0;
    var unknown = false;
    for (final l in lines) {
      final it = byId[l.itemId];
      if (it == null) continue;
      try {
        final q = convertQty(l.qty * (1 + l.wastagePercent / 100), l.unit, it.baseUnit);
        total += q * it.standardCost;
      } on UnitConversionException {
        unknown = true;
      }
    }
    final finished = base * (1 + over / 100);
    return Card(
      color: Colors.indigo.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('আনুমানিক খরচ (বর্তমান Avg cost অনুযায়ী)', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('Mix খরচ: ${fmtMoney(total)}  (প্রতি লিটার ${base > 0 ? fmtMoney(total / base) : '—'})'),
          Text('প্রত্যাশিত Finished: ${fmtQty(finished)} L  →  প্রতি লিটার ${finished > 0 ? fmtMoney(total / finished) : '—'}'),
          if (unknown) const Text('⚠ কিছু ইউনিট কনভার্ট হয়নি, হিসাব অসম্পূর্ণ', style: TextStyle(color: Colors.red, fontSize: 12)),
          const Text('শুধু কাঁচামাল; Labour/Overhead আলাদা যোগ হয়।', style: TextStyle(fontSize: 11, color: Colors.grey)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(databaseProvider);
    if (!_loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final byId = {for (final i in _items) i.id: i};

    return Scaffold(
      appBar: AppBar(title: Text(_id == null ? 'নতুন রেসিপি' : 'রেসিপি: ${_code.text}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _code, decoration: const InputDecoration(labelText: 'Recipe Code *')),
          const SizedBox(height: 8),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Recipe Name *')),
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            isExpanded: true,
            value: _finishedChoices.any((i) => i.id == _finishedItemId) ? _finishedItemId : null,
            decoration: const InputDecoration(
                labelText: 'Finished Item *', helperText: 'Item Master এ Type = Finished/Semi/Mix হতে হবে'),
            items: _finishedChoices
                .map((i) => DropdownMenuItem(value: i.id, child: Text('${i.itemCode} - ${i.itemName}', overflow: TextOverflow.ellipsis)))
                .toList(),
            onChanged: (v) => setState(() => _finishedItemId = v),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _baseQty,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Base Mix Qty (L)'),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _overrun,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Target Overrun %'),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _yield,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Expected Yield %'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _aging,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Min Aging (ঘণ্টা)'),
              ),
            ),
          ]),
          if (_id != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Active'),
              value: _active,
              onChanged: (v) => setState(() => _active = v),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _saveHeader,
            icon: const Icon(Icons.save),
            label: const Text('হেডার সেভ করুন'),
          ),
          const Divider(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Ingredients', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              OutlinedButton.icon(
                onPressed: _addLine,
                icon: const Icon(Icons.add),
                label: const Text('যোগ করুন'),
              ),
            ],
          ),
          if (_id == null)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('হেডার সেভ করার পর ইনগ্রিডিয়েন্ট যোগ করা যাবে।', style: TextStyle(color: Colors.grey)),
            )
          else
            StreamBuilder<List<RecipeLine>>(
              stream: (db.select(db.recipeLines)
                    ..where((l) => l.recipeId.equals(_id!))
                    ..orderBy([(l) => OrderingTerm.asc(l.sequence), (l) => OrderingTerm.asc(l.id)]))
                  .watch(),
              builder: (context, snap) {
                final lines = snap.data ?? [];
                if (lines.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('এখনো কোনো ইনগ্রিডিয়েন্ট নেই — Production Order বানাতে অন্তত একটি দরকার।',
                        style: TextStyle(color: Colors.red)),
                  );
                }
                return Column(
                  children: [
                    ...lines.map((l) {
                      final it = byId[l.itemId];
                      return Card(
                        child: ListTile(
                          dense: true,
                          title: Text(it == null ? 'Item #${l.itemId}' : '${it.itemCode} - ${it.itemName}'),
                          subtitle: Text('${fmtQty(l.qty)} ${l.unit}  •  Wastage ${fmtQty(l.wastagePercent)}%'),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.red),
                            onPressed: () => _deleteLine(l),
                          ),
                        ),
                      );
                    }),
                    _costSummary(lines),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}
