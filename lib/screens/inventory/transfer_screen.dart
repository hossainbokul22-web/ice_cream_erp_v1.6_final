import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/app_database.dart';
import '../../providers/database_provider.dart';
import '../../utils/ui.dart';

class TransferScreen extends ConsumerStatefulWidget {
  const TransferScreen({super.key});

  @override
  ConsumerState<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends ConsumerState<TransferScreen> {
  List<Batch> batches = [];
  List<Warehouse> warehouses = [];
  int? batchId;
  int? toWh;
  final qty = TextEditingController();
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(databaseProvider);
    batches = await (db.select(db.batches)
          ..where((b) => b.currentQty.isBiggerThanValue(0))
          ..orderBy([(b) => OrderingTerm.desc(b.id)]))
        .get();
    warehouses = await db.select(db.warehouses).get();
    if (mounted) setState(() => loading = false);
  }

  Future<void> _save() async {
    if (batchId == null || toWh == null) {
      showSnack(context, 'Batch ও destination warehouse বাছুন');
      return;
    }
    final q = parseNum(qty.text);
    if (q == null || q <= 0) {
      showSnack(context, 'Qty দিন');
      return;
    }
    final ok = await runGuarded(context, () async {
      await ref.read(stockServiceProvider).transferBatch(
            batchId: batchId!,
            toWarehouseId: toWh!,
            qty: q,
          );
    }, success: 'Transfer সম্পন্ন');
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: const Text('Warehouse Transfer')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<int>(
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Source Batch'),
            value: batchId,
            items: batches.map((b) {
              return DropdownMenuItem(
                value: b.id,
                child: Text('${b.batchNo} · qty ${fmtQty(b.currentQty)} · WH#${b.warehouseId}',
                    overflow: TextOverflow.ellipsis),
              );
            }).toList(),
            onChanged: (v) => setState(() => batchId = v),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'To Warehouse'),
            value: toWh,
            items: warehouses
                .map((w) => DropdownMenuItem(value: w.id, child: Text('${w.warehouseCode} — ${w.warehouseName}')))
                .toList(),
            onChanged: (v) => setState(() => toWh = v),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: qty,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Quantity'),
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: _save, child: const Text('Transfer')),
        ],
      ),
    );
  }
}
