import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/app_database.dart';
import '../../providers/database_provider.dart';
import '../../services/production_math.dart';
import '../../utils/ui.dart';

class ProductionReportScreen extends ConsumerWidget {
  const ProductionReportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Production Cost Report')),
      body: StreamBuilder<List<ProductionOrder>>(
        stream: (db.select(db.productionOrders)
              ..where((o) => o.status.equals('Completed'))
              ..orderBy([(o) => OrderingTerm.desc(o.endDate)]))
            .watch(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final list = snap.data!;
          if (list.isEmpty) return const Center(child: Text('এখনো কোনো সম্পন্ন প্রোডাকশন নেই'));

          final totalFinished = list.fold<double>(0, (s, o) => s + (o.actualFinishedQty ?? 0));
          final totalCost = list.fold<double>(0, (s, o) => s + o.totalMaterialCost + o.otherCost);
          return ListView(
            padding: const EdgeInsets.all(10),
            children: [
              Card(
                color: Colors.deepPurple.shade50,
                child: ListTile(
                  title: Text('মোট উৎপাদন: ${fmtQty(totalFinished)} L'),
                  subtitle: Text('মোট খরচ: ${fmtMoney(totalCost)}'),
                  trailing: Text(
                      totalFinished > 0 ? '${fmtMoney(totalCost / totalFinished)} / L' : '—',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              ...list.map((o) {
                final f = o.actualFinishedQty ?? 0;
                final cpl = costPerFinishedUnit(materialCost: o.totalMaterialCost, otherCost: o.otherCost, finishedQty: f);
                final planned = o.plannedOverrun ?? 0;
                final var_ = (o.actualOverrun ?? 0) - planned;
                return Card(
                  child: ListTile(
                    title: Text(o.orderNo, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(
                      'Mix ${fmtQty(o.actualMixQty ?? 0)} L → Finished ${fmtQty(f)} L\n'
                      'Overrun ${(o.actualOverrun ?? 0).toStringAsFixed(1)}% (লক্ষ্য ${fmtQty(planned)}%, '
                      '${var_ >= 0 ? '+' : ''}${var_.toStringAsFixed(1)})  •  Yield ${(o.actualYield ?? 0).toStringAsFixed(1)}%\n'
                      'Material ${fmtMoney(o.totalMaterialCost)}${o.otherCost > 0 ? ' + Other ${fmtMoney(o.otherCost)}' : ''}',
                    ),
                    isThreeLine: true,
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(fmtMoney(cpl), style: const TextStyle(fontWeight: FontWeight.bold)),
                        const Text('/ লিটার', style: TextStyle(fontSize: 10)),
                      ],
                    ),
                  ),
                );
              }),
            ],
          );
        },
      ),
    );
  }
}
