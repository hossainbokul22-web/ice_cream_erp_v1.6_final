import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/app_database.dart';
import '../../providers/database_provider.dart';
import '../../utils/ui.dart';

class SaleScreen extends ConsumerStatefulWidget {
  const SaleScreen({super.key});

  @override
  ConsumerState<SaleScreen> createState() => _SaleScreenState();
}

class _SaleScreenState extends ConsumerState<SaleScreen> {
  List<Item> _items = [];
  List<Party> _parties = [];
  int? _itemId;
  int? _partyId;
  bool _receivedNow = true;
  bool _loading = true;
  final _qty = TextEditingController();
  final _price = TextEditingController();
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _qty.dispose();
    _price.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = ref.read(databaseProvider);
    final items = await (db.select(db.items)
          ..where((i) => i.itemType.equals('Finished') & i.isActive.equals(true))
          ..orderBy([(i) => OrderingTerm.asc(i.itemName)]))
        .get();
    final parties = await (db.select(db.parties)
          ..where((p) => p.isActive.equals(true) & p.partyType.isIn(['Customer', 'Both']))
          ..orderBy([(p) => OrderingTerm.asc(p.partyName)]))
        .get();
    if (!mounted) return;
    setState(() {
      _items = items;
      _parties = parties;
      _loading = false;
    });
  }

  Future<void> _save() async {
    final itemId = _itemId;
    final qty = parseNum(_qty.text);
    final price = parseNum(_price.text);
    if (itemId == null || qty == null || price == null) {
      showSnack(context, 'আইটেম, পরিমাণ ও মূল্য দিন');
      return;
    }
    final ok = await runGuarded(context, () async {
      final r = await ref.read(salesServiceProvider).sell(
            itemId: itemId,
            qty: qty,
            unitPrice: price,
            partyId: _partyId,
            receivedNow: _receivedNow,
            narration: _note.text.trim().isEmpty ? null : _note.text.trim(),
          );
      if (!mounted) return;
      showSnack(context, 'বিক্রয় সম্পন্ন: ${fmtMoney(r.revenue)} • লাভ ${fmtMoney(r.margin)}');
    });
    if (ok && mounted) {
      setState(() {
        _qty.clear();
        _note.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sale (বিক্রয়)')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                DropdownButtonFormField<int>(
                  value: _itemId,
                  decoration: const InputDecoration(labelText: 'Finished আইটেম'),
                  items: _items
                      .map((i) => DropdownMenuItem<int>(value: i.id, child: Text('${i.itemCode} - ${i.itemName}')))
                      .toList(),
                  onChanged: (v) {
                    setState(() {
                      _itemId = v;
                      final it = _items.where((i) => i.id == v).toList();
                      if (it.isNotEmpty && it.first.salesPrice > 0) {
                        _price.text = fmtQty(it.first.salesPrice);
                      }
                    });
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _qty,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'পরিমাণ'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _price,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'একক বিক্রয় মূল্য (Tk)'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int?>(
                  value: _partyId,
                  decoration: const InputDecoration(labelText: 'কাস্টমার (ঐচ্ছিক)'),
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('নগদ বিক্রয় (Party নেই)')),
                    ..._parties.map((p) => DropdownMenuItem<int?>(value: p.id, child: Text('${p.partyCode} - ${p.partyName}'))),
                  ],
                  onChanged: (v) => setState(() => _partyId = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('টাকা এখনই পাওয়া গেছে'),
                  subtitle: const Text('বন্ধ করলে বাকি (Receivable) হবে — কাস্টমার লাগবে'),
                  value: _receivedNow,
                  onChanged: (v) => setState(() => _receivedNow = v),
                ),
                TextField(controller: _note, decoration: const InputDecoration(labelText: 'নোট (ঐচ্ছিক)')),
                const SizedBox(height: 20),
                FilledButton.icon(onPressed: _save, icon: const Icon(Icons.check), label: const Text('বিক্রয় সংরক্ষণ')),
              ],
            ),
    );
  }
}
