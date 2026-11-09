import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../providers/database_provider.dart';
import '../../services/stock_service.dart';
import '../../utils/ui.dart';

class DailyInventoryScreen extends ConsumerStatefulWidget {
  const DailyInventoryScreen({super.key});

  @override
  ConsumerState<DailyInventoryScreen> createState() => _DailyInventoryScreenState();
}

class _DailyInventoryScreenState extends ConsumerState<DailyInventoryScreen> {
  DailyInventoryBrief? brief;
  bool loading = true;
  DateTime day = DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    final b = await ref.read(stockServiceProvider).dailyInventoryBrief(day: day);
    if (mounted) setState(() { brief = b; loading = false; });
  }

  Future<void> _shareCsv() async {
    final b = brief;
    if (b == null) return;
    final csv = ref.read(stockServiceProvider).dailyBriefToCsv(b);
    final dir = await getTemporaryDirectory();
    final name = 'daily_inventory_${b.date.toIso8601String().substring(0, 10)}.csv';
    final file = File(p.join(dir.path, name));
    await file.writeAsString(csv);
    await Share.shareXFiles([XFile(file.path)], text: 'Daily Inventory ${b.date.toIso8601String().substring(0, 10)}');
  }

  Widget _kpi(String label, String value, {Color? color}) => Expanded(
        child: Card(
          color: color,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
                const SizedBox(height: 4),
                Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ],
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final b = brief;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Daily Inventory Brief'),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today),
            onPressed: () async {
              final p = await showDatePicker(
                context: context,
                initialDate: day,
                firstDate: DateTime(2020),
                lastDate: DateTime.now().add(const Duration(days: 1)),
              );
              if (p != null) {
                setState(() => day = p);
                await _load();
              }
            },
          ),
          IconButton(icon: const Icon(Icons.share), onPressed: brief == null ? null : _shareCsv),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: loading || b == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Text(
                  'তারিখ: ${b.date.toIso8601String().substring(0, 10)} — বসকে পাঠানোর জন্য Share চাপুন',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  _kpi('RM+Pack Value', fmtMoney(b.rawValue), color: Colors.orange.shade50),
                  _kpi('FG Value', fmtMoney(b.finishedValue), color: Colors.green.shade50),
                ]),
                Row(children: [
                  _kpi('আজ Purchase', fmtQty(b.purchaseIn)),
                  _kpi('আজ FG উৎপাদন', fmtQty(b.finishedProducedToday)),
                ]),
                Row(children: [
                  _kpi('Issue (RM)', fmtQty(b.productionIssueOut)),
                  _kpi('Sales Out', fmtQty(b.salesOut)),
                ]),
                Row(children: [
                  _kpi('Low Stock', '${b.lowStockCount}', color: b.lowStockCount > 0 ? Colors.red.shade50 : null),
                  _kpi('Near Expiry', '${b.nearExpiryCount}', color: b.nearExpiryCount > 0 ? Colors.amber.shade50 : null),
                ]),
                const SizedBox(height: 12),
                const Text('Raw + Packaging', style: TextStyle(fontWeight: FontWeight.bold)),
                ...b.rawRows.map((r) => ListTile(
                      dense: true,
                      title: Text('${r.item.itemCode} ${r.item.itemName}'),
                      subtitle: Text('${fmtQty(r.stock)} ${r.item.baseUnit}${r.isLow ? " · LOW" : ""}'),
                      trailing: Text(fmtMoney(r.value)),
                    )),
                const SizedBox(height: 8),
                const Text('Finished Goods', style: TextStyle(fontWeight: FontWeight.bold)),
                ...b.finishedRows.map((r) => ListTile(
                      dense: true,
                      title: Text('${r.item.itemCode} ${r.item.itemName}'),
                      subtitle: Text('${fmtQty(r.stock)} ${r.item.baseUnit}'),
                      trailing: Text(fmtMoney(r.value)),
                    )),
                if (b.mixRows.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('Mix / Semi', style: TextStyle(fontWeight: FontWeight.bold)),
                  ...b.mixRows.map((r) => ListTile(
                        dense: true,
                        title: Text('${r.item.itemCode} ${r.item.itemName}'),
                        subtitle: Text('${fmtQty(r.stock)} ${r.item.baseUnit}'),
                        trailing: Text(fmtMoney(r.value)),
                      )),
                ],
              ],
            ),
    );
  }
}
