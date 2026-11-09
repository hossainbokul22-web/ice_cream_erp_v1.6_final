import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/app_database.dart';
import '../../providers/database_provider.dart';
import '../../services/production_math.dart';
import '../../utils/ui.dart';

/// Receive raw / packaging material: creates the Batch, Stock Ledger entry and the
/// Purchase voucher together (one transaction).
class PurchaseReceiptScreen extends ConsumerStatefulWidget {
  const PurchaseReceiptScreen({super.key, this.initialItemId});
  final int? initialItemId;

  @override
  ConsumerState<PurchaseReceiptScreen> createState() => _PurchaseReceiptScreenState();
}

class _PurchaseReceiptScreenState extends ConsumerState<PurchaseReceiptScreen> {
  final _qty = TextEditingController();
  final _cost = TextEditingController();
  final _batch = TextEditingController();
  final _note = TextEditingController();

  List<Item> _items = [];
  List<Party> _suppliers = [];
  List<Warehouse> _warehouses = [];
  int? _itemId;
  int? _partyId;
  int? _warehouseId;
  bool _paidNow = false;
  DateTime _mfg = DateTime.now();
  DateTime? _expiry; // null = auto from shelf life
  bool _loaded = false;
  bool _saving = false;

  Item? get _item {
    for (final i in _items) {
      if (i.id == _itemId) return i;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(databaseProvider);
    _items = await (db.select(db.items)
          ..where((i) => i.isActive.equals(true) & i.itemType.isNotValue('Finished'))
          ..orderBy([(i) => OrderingTerm.asc(i.itemCode)]))
        .get();
    _suppliers = await (db.select(db.parties)
          ..where((p) => p.isActive.equals(true) & p.partyType.isIn(['Supplier', 'Both'])))
        .get();
    _warehouses = await db.select(db.warehouses).get();
    final def = await db.getDefaultWarehouse();
    _warehouseId = def?.id;
    _itemId = widget.initialItemId ?? (_items.isEmpty ? null : _items.first.id);
    _applyItemDefaults();
    if (mounted) setState(() => _loaded = true);
  }

  void _applyItemDefaults() {
    final it = _item;
    if (it != null && _cost.text.isEmpty && it.standardCost > 0) {
      _cost.text = it.standardCost.toString();
    }
  }

  DateTime? get _effectiveExpiry => _expiry ?? (_item == null ? null : expiryFromShelfLife(_mfg, _item!.shelfLifeDays));

  double get _total => round2((parseNum(_qty.text) ?? 0) * (parseNum(_cost.text) ?? 0));

  Future<void> _save() async {
    final qty = parseNum(_qty.text);
    final cost = parseNum(_cost.text);
    if (_itemId == null) { showSnack(context, 'আইটেম সিলেক্ট করুন'); return; }
    if (qty == null || qty <= 0) { showSnack(context, 'পরিমাণ ০ এর বেশি হতে হবে'); return; }
    if (cost == null || cost <= 0) { showSnack(context, 'ইউনিট দাম ০ এর বেশি হতে হবে'); return; }
    if (!_paidNow && _partyId == null) {
      showSnack(context, 'বাকিতে কিনলে সরবরাহকারী সিলেক্ট করুন (অথবা "নগদ পরিশোধ" অন করুন)');
      return;
    }
    setState(() => _saving = true);
    final ok = await runGuarded(context, () async {
      final r = await ref.read(stockServiceProvider).receivePurchase(
            itemId: _itemId!,
            qty: qty,
            unitCost: cost,
            batchNo: _batch.text,
            mfgDate: _mfg,
            expiryDate: _expiry,
            warehouseId: _warehouseId,
            partyId: _partyId,
            paidNow: _paidNow,
            narration: _note.text.trim().isEmpty ? null : _note.text.trim(),
          );
      if (mounted) showSnack(context, 'গ্রহণ সম্পন্ন — Batch ${r.batchNo}, ${fmtMoney(_total)}');
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      _qty.clear();
      _batch.clear();
      _note.clear();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final it = _item;
    final exp = _effectiveExpiry;

    return Scaffold(
      appBar: AppBar(title: const Text('Purchase Receipt (মাল গ্রহণ)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_items.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('আগে Item Master এ কাঁচামাল যোগ করুন।', style: TextStyle(color: Colors.red)),
            ),
          DropdownButtonFormField<int>(
            isExpanded: true,
            value: _itemId,
            decoration: const InputDecoration(labelText: 'Item *'),
            items: _items
                .map((i) => DropdownMenuItem(value: i.id, child: Text('${i.itemCode} - ${i.itemName} (${i.baseUnit})', overflow: TextOverflow.ellipsis)))
                .toList(),
            onChanged: (v) => setState(() {
              _itemId = v;
              _cost.clear();
              _expiry = null;
              _applyItemDefaults();
            }),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _qty,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: 'Quantity * ${it == null ? '' : '(${it.baseUnit})'}'),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _cost,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Unit Cost (Tk) *'),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          TextField(
            controller: _batch,
            decoration: const InputDecoration(
                labelText: 'Batch / Lot No', helperText: 'ফাঁকা রাখলে নিজে তৈরি হবে। একই Batch আবার দিলে স্টক যোগ হবে (গড় দামসহ)।'),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.factory),
                label: Text('Mfg: ${fmtDate(_mfg)}'),
                onPressed: () async {
                  final d = await pickDate(context, _mfg, last: DateTime.now());
                  if (d != null) setState(() => _mfg = d);
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.event_busy),
                label: Text('Exp: ${fmtDate(exp)}${_expiry == null && exp != null ? ' (auto)' : ''}'),
                onPressed: () async {
                  final d = await pickDate(context, exp ?? _mfg, first: _mfg);
                  if (d != null) setState(() => _expiry = d);
                },
              ),
            ),
          ]),
          if (exp == null)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('⚠ মেয়াদ নেই — FEFO তে এই Batch সবার শেষে ব্যবহার হবে।', style: TextStyle(fontSize: 12, color: Colors.orange)),
            ),
          const SizedBox(height: 10),
          DropdownButtonFormField<int>(
            isExpanded: true,
            value: _warehouseId,
            decoration: const InputDecoration(labelText: 'Warehouse'),
            items: _warehouses.map((w) => DropdownMenuItem(value: w.id, child: Text(w.warehouseName))).toList(),
            onChanged: (v) => setState(() => _warehouseId = v),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<int?>(
            isExpanded: true,
            value: _partyId,
            decoration: const InputDecoration(labelText: 'Supplier'),
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('— নেই (খোলা বাজার) —')),
              ..._suppliers.map((p) => DropdownMenuItem<int?>(value: p.id, child: Text('${p.partyCode} - ${p.partyName}'))),
            ],
            onChanged: (v) => setState(() => _partyId = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('নগদ পরিশোধ'),
            subtitle: Text(_paidNow ? 'Cash/Bank থেকে কাটা হবে' : 'সরবরাহকারীর কাছে বাকি (Payable) হবে'),
            value: _paidNow,
            onChanged: (v) => setState(() => _paidNow = v),
          ),
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note')),
          const SizedBox(height: 16),
          Card(
            color: Colors.teal.shade50,
            child: ListTile(
              title: const Text('মোট মূল্য'),
              trailing: Text(fmtMoney(_total), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.check),
            label: const Text('গ্রহণ নিশ্চিত করুন'),
          ),
        ],
      ),
    );
  }
}
