import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/app_database.dart';
import '../../providers/database_provider.dart';
import '../../services/production_math.dart';
import '../../services/production_service.dart';
import '../../utils/ui.dart';

class CreateProductionOrderScreen extends ConsumerStatefulWidget {
  const CreateProductionOrderScreen({super.key});

  @override
  ConsumerState<CreateProductionOrderScreen> createState() => _CreateProductionOrderScreenState();
}

class _CreateProductionOrderScreenState extends ConsumerState<CreateProductionOrderScreen> {
  final _orderNo = TextEditingController();
  final _targetQty = TextEditingController(text: '1000');
  final _notes = TextEditingController();

  List<Recipe> _recipes = [];
  List<Tank> _mixTanks = [];
  List<Tank> _ageTanks = [];
  int? _recipeId;
  int? _mixTankId;
  int? _ageTankId;
  bool _loaded = false;
  bool _saving = false;
  List<MaterialAvailability> _preview = [];
  String? _previewError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(databaseProvider);
    _orderNo.text = await db.nextProductionOrderNo();
    _recipes = await (db.select(db.recipes)
          ..where((r) => r.isActive.equals(true) & r.approvalStatus.equals('Approved')))
        .get();
    final tanks = await db.select(db.tanks).get();
    _mixTanks = tanks.where((t) => t.tankType == 'Mixing').toList();
    _ageTanks = tanks.where((t) => t.tankType == 'Aging').toList();
    // Auto-suggest first suitable empty tanks (BatchMaster-style)
    final q = parseNum(_targetQty.text) ?? 1000;
    try {
      final sug = await ref.read(productionServiceProvider).suggestTanks(q);
      if (sug.mixing.isNotEmpty) _mixTankId = sug.mixing.first.id;
      if (sug.aging.isNotEmpty) _ageTankId = sug.aging.first.id;
    } catch (_) {}
    if (mounted) setState(() => _loaded = true);
  }

  Recipe? get _recipe {
    for (final r in _recipes) {
      if (r.id == _recipeId) return r;
    }
    return null;
  }

  Future<void> _refreshPreview() async {
    final q = parseNum(_targetQty.text);
    if (_recipeId == null || q == null || q <= 0) {
      setState(() {
        _preview = [];
        _previewError = null;
      });
      return;
    }
    try {
      final p = await ref.read(productionServiceProvider).previewMaterials(_recipeId!, q);
      if (mounted) setState(() {
        _preview = p;
        _previewError = null;
      });
    } catch (e) {
      if (mounted) setState(() {
        _preview = [];
        _previewError = friendlyError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final recipe = _recipe;
    final qty = parseNum(_targetQty.text) ?? 0;
    final anyShort = _preview.any((m) => m.isShort);
    final estCost = _preview.fold<double>(0, (s, m) => s + m.estimatedCost);

    return Scaffold(
      appBar: AppBar(title: const Text('নতুন Production Order')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _orderNo, decoration: const InputDecoration(labelText: 'Order No')),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            isExpanded: true,
            value: _recipeId,
            decoration: const InputDecoration(labelText: 'Recipe সিলেক্ট করুন *'),
            items: _recipes
                .map((r) => DropdownMenuItem<int>(value: r.id, child: Text('${r.recipeCode} - ${r.recipeName}', overflow: TextOverflow.ellipsis)))
                .toList(),
            onChanged: (v) {
              setState(() => _recipeId = v);
              _refreshPreview();
            },
          ),
          if (_recipes.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('কোনো Active রেসিপি নেই — আগে Recipes থেকে বানান।', style: TextStyle(color: Colors.red, fontSize: 12)),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _targetQty,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Target Mix Quantity (Liter) *'),
            onChanged: (_) => _refreshPreview(),
          ),
          if (recipe != null && qty > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'প্রত্যাশিত Finished: ${fmtQty(qty * (1 + recipe.targetOverrun / 100))} L (Overrun ${fmtQty(recipe.targetOverrun)}%)  •  Aging ≥ ${fmtQty(recipe.agingHours)} ঘণ্টা',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int?>(
            isExpanded: true,
            value: _mixTankId,
            decoration: const InputDecoration(labelText: 'Mixing Tank'),
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('— পরে সিলেক্ট করব —')),
              ..._mixTanks.map((t) => DropdownMenuItem<int?>(
                  value: t.id, child: Text('${t.tankCode} (${fmtQty(t.capacityLiter)}L) • ${t.status}'))),
            ],
            onChanged: (v) => setState(() => _mixTankId = v),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int?>(
            isExpanded: true,
            value: _ageTankId,
            decoration: const InputDecoration(labelText: 'Aging Tank'),
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('— Mixing ট্যাংকেই Aging / পরে —')),
              ..._ageTanks.map((t) => DropdownMenuItem<int?>(
                  value: t.id, child: Text('${t.tankCode} (${fmtQty(t.capacityLiter)}L) • ${t.status}'))),
            ],
            onChanged: (v) => setState(() => _ageTankId = v),
          ),
          const SizedBox(height: 12),
          TextField(controller: _notes, decoration: const InputDecoration(labelText: 'Notes')),
          const SizedBox(height: 16),
          if (_previewError != null)
            Text(_previewError!, style: const TextStyle(color: Colors.red)),
          if (_preview.isNotEmpty) ...[
            const Text('কাঁচামাল (FEFO স্টক যাচাই)', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            ..._preview.map((m) => Card(
                  color: m.isShort ? Colors.red.shade50 : Colors.green.shade50,
                  child: ListTile(
                    dense: true,
                    leading: Icon(m.isShort ? Icons.error : Icons.check_circle,
                        color: m.isShort ? Colors.red : Colors.green),
                    title: Text(m.material.item.itemName),
                    subtitle: Text(
                        'দরকার ${fmtQty(m.material.requiredQty)} ${m.material.item.baseUnit} • আছে ${fmtQty(m.available)}'
                        '${m.isShort ? ' • ঘাটতি ${fmtQty(m.shortage)}' : ''}'),
                    trailing: m.isShort ? null : Text(fmtMoney(m.estimatedCost), style: const TextStyle(fontSize: 12)),
                  ),
                )),
            if (!anyShort)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text('আনুমানিক কাঁচামাল খরচ: ${fmtMoney(estCost)}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            if (anyShort)
              const Text('স্টক ঘাটতি আছে — অর্ডার বানানো যাবে, কিন্তু Material Issue স্টক না আসা পর্যন্ত হবে না।',
                  style: TextStyle(fontSize: 12, color: Colors.red)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: (_recipeId == null || _saving) ? null : _save,
            child: const Text('Production Order তৈরি করুন'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final q = parseNum(_targetQty.text);
    if (q == null || q <= 0) { showSnack(context, 'Target পরিমাণ ০ এর বেশি হতে হবে'); return; }
    setState(() => _saving = true);
    final ok = await runGuarded(context, () async {
      await ref.read(productionServiceProvider).createProductionOrder(
            orderNo: _orderNo.text,
            recipeId: _recipeId!,
            targetMixQty: q,
            mixingTankId: _mixTankId,
            agingTankId: _ageTankId,
            notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
          );
    }, success: 'Production Order তৈরি হয়েছে');
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context);
  }
}
