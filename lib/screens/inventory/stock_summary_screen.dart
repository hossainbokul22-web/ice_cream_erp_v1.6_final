import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/database_provider.dart';
import '../../services/stock_service.dart';
import '../../utils/ui.dart';
import 'purchase_receipt_screen.dart';

class StockSummaryScreen extends ConsumerStatefulWidget {
  const StockSummaryScreen({super.key});

  @override
  ConsumerState<StockSummaryScreen> createState() => _StockSummaryScreenState();
}

class _StockSummaryScreenState extends ConsumerState<StockSummaryScreen> {
  late Future<List<StockRow>> _future;
  String _filter = 'All'; // All, Low, Expiry

  @override
  void initState() {
    super.initState();
    _future = ref.read(stockServiceProvider).getStockSummary();
  }

  void _reload() => setState(() => _future = ref.read(stockServiceProvider).getStockSummary());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stock Summary'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _reload)],
      ),
      body: FutureBuilder<List<StockRow>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          var rows = snapshot.data!;
          if (rows.isEmpty) {
            return const Center(child: Text('স্টক ডাটা নেই। আগে আইটেম ও পারচেজ এন্ট্রি করুন।'));
          }
          final totalValue = rows.fold<double>(0, (s, r) => s + r.value);
          if (_filter == 'Low') rows = rows.where((r) => r.isLow).toList();
          if (_filter == 'Expiry') rows = rows.where((r) => r.expiredQty > 0 || r.nearExpiryQty > 0).toList();

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    Expanded(child: Text('মোট স্টক মূল্য: ${fmtMoney(totalValue)}', style: const TextStyle(fontWeight: FontWeight.bold))),
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      style: const ButtonStyle(visualDensity: VisualDensity.compact),
                      segments: const [
                        ButtonSegment(value: 'All', label: Text('সব')),
                        ButtonSegment(value: 'Low', label: Text('Low')),
                        ButtonSegment(value: 'Expiry', label: Text('Expiry')),
                      ],
                      selected: {_filter},
                      onSelectionChanged: (s) => setState(() => _filter = s.first),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: rows.isEmpty
                    ? const Center(child: Text('এই ফিল্টারে কিছু নেই'))
                    : ListView.builder(
                        padding: const EdgeInsets.all(10),
                        itemCount: rows.length,
                        itemBuilder: (context, index) => _card(rows[index]),
                      ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const PurchaseReceiptScreen()));
          _reload();
        },
        icon: const Icon(Icons.add_shopping_cart),
        label: const Text('Purchase'),
      ),
    );
  }

  Widget _card(StockRow row) {
    final item = row.item;
    final hasExpired = row.expiredQty > 0;
    final hasNear = row.nearExpiryQty > 0;
    return Card(
      color: hasExpired ? Colors.red.shade50 : (row.isLow ? Colors.orange.shade50 : null),
      child: ExpansionTile(
        title: Text('${item.itemCode} - ${item.itemName}'),
        subtitle: Text(
            'Stock: ${fmtQty(row.stock)} ${item.baseUnit}  •  ${fmtMoney(row.value)}'
            '${item.minStock > 0 ? '  •  Min ${fmtQty(item.minStock)}' : ''}'),
        trailing: Wrap(
          spacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (hasExpired) const Icon(Icons.dangerous, color: Colors.red, size: 20),
            if (!hasExpired && hasNear) Icon(Icons.timer, color: Colors.amber.shade800, size: 20),
            if (row.isLow) const Icon(Icons.warning, color: Colors.orange, size: 20),
            Text('${row.batches.length} Batch', style: const TextStyle(fontSize: 12)),
          ],
        ),
        children: row.batches.isEmpty
            ? [const ListTile(title: Text('কোনো ব্যাচ নেই'))]
            : row.batches.map((b) {
                final now = DateTime.now();
                final expired = b.expiryDate != null && b.expiryDate!.isBefore(now);
                final near = !expired &&
                    b.expiryDate != null &&
                    b.expiryDate!.isBefore(now.add(const Duration(days: StockService.nearExpiryDays)));
                return ListTile(
                  dense: true,
                  title: Text('Batch: ${b.batchNo}'),
                  subtitle: Text(
                    'Qty: ${fmtQty(b.currentQty)}  •  Exp: ${fmtDate(b.expiryDate)}'
                    '${expired ? '  (মেয়াদোত্তীর্ণ)' : near ? '  (শীঘ্রই শেষ)' : ''}',
                    style: TextStyle(color: expired ? Colors.red : (near ? Colors.amber.shade900 : null)),
                  ),
                  trailing: Text('Cost ${b.unitCost.toStringAsFixed(2)}'),
                  onLongPress: () => _adjust(b.id, b.batchNo, b.currentQty),
                );
              }).toList(),
      ),
    );
  }

  void _adjust(int batchId, String batchNo, double current) {
    final qty = TextEditingController(text: fmtQty(current));
    final reason = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Stock Adjustment — $batchNo'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: qty,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'সঠিক পরিমাণ (গণনা অনুযায়ী)'),
            ),
            const SizedBox(height: 8),
            TextField(controller: reason, decoration: const InputDecoration(labelText: 'কারণ * (গলে গেছে / ভেঙেছে / গণনা ভুল…)')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
          FilledButton(
            onPressed: () async {
              final q = parseNum(qty.text);
              if (q == null) { showSnack(ctx, 'সংখ্যা দিন'); return; }
              final ok = await runGuarded(ctx, () => ref
                  .read(stockServiceProvider)
                  .adjustBatch(batchId: batchId, newQty: q, reason: reason.text));
              if (ok && ctx.mounted) {
                Navigator.pop(ctx);
                _reload();
              }
            },
            child: const Text('সেভ'),
          ),
        ],
      ),
    );
  }
}
