import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/database_provider.dart';
import '../../database/app_database.dart';
import '../../utils/ui.dart';

class TankListScreen extends ConsumerWidget {
  const TankListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tanks (Mixing / Aging)'),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: () => _showTankForm(context, ref)),
        ],
      ),
      body: StreamBuilder(
        stream: db.select(db.tanks).watch(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final tanks = snapshot.data!;
          if (tanks.isEmpty) {
            return const Center(child: Text('কোনো ট্যাংক নেই। + চাপুন নতুন ট্যাংক যোগ করতে।'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(10),
            itemCount: tanks.length,
            itemBuilder: (context, index) {
              final tank = tanks[index];
              final fillPercent = tank.capacityLiter > 0 ? (tank.currentQty / tank.capacityLiter) * 100 : 0.0;
              Color statusColor = tank.status == 'Empty' ? Colors.green : (tank.status == 'InUse' ? Colors.orange : Colors.blue);

              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('${tank.tankCode} - ${tank.tankName}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          Chip(
                            label: Text(tank.status, style: const TextStyle(fontSize: 11, color: Colors.white)),
                            backgroundColor: statusColor,
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text('Type: ${tank.tankType}  •  Capacity: ${tank.capacityLiter} L'),
                      Text('Current: ${tank.currentQty.toStringAsFixed(1)} L'),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: (fillPercent / 100).clamp(0.0, 1.0).toDouble(),
                        backgroundColor: Colors.grey.shade200,
                        color: statusColor,
                        minHeight: 8,
                      ),
                      const SizedBox(height: 4),
                      Text('${fillPercent.toStringAsFixed(1)}% filled', style: const TextStyle(fontSize: 12)),
                      if (tank.status == 'Cleaning')
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.tonalIcon(
                            onPressed: () => runGuarded(
                              context,
                              () => ref.read(productionServiceProvider).markTankClean(tank.id),
                              success: '${tank.tankCode} পরিষ্কার — ব্যবহারযোগ্য',
                            ),
                            icon: const Icon(Icons.cleaning_services),
                            label: const Text('পরিষ্কার সম্পন্ন (CIP)'),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showTankForm(context, ref),
        child: const Icon(Icons.add),
      ),
    );
  }

  void _showTankForm(BuildContext context, WidgetRef ref) {
    final codeCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final capacityCtrl = TextEditingController(text: '1000');
    String tankType = 'Mixing';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(left: 16, right: 16, top: 16, bottom: MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('নতুন ট্যাংক', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  TextField(controller: codeCtrl, decoration: const InputDecoration(labelText: 'Tank Code')),
                  const SizedBox(height: 8),
                  TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Tank Name')),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: tankType,
                    decoration: const InputDecoration(labelText: 'Type'),
                    items: ['Mixing', 'Aging', 'Storage'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                    onChanged: (v) => setState(() => tankType = v!),
                  ),
                  const SizedBox(height: 8),
                  TextField(controller: capacityCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Capacity (Liter)')),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () async {
                      final code = codeCtrl.text.trim();
                      final name = nameCtrl.text.trim();
                      final cap = parseNum(capacityCtrl.text);
                      if (code.isEmpty || name.isEmpty) {
                        showSnack(ctx, 'Code ও Name দিন');
                        return;
                      }
                      if (cap == null || cap <= 0) {
                        showSnack(ctx, 'Capacity ০ এর বেশি হতে হবে');
                        return;
                      }
                      final db = ref.read(databaseProvider);
                      final ok = await runGuarded(ctx, () async {
                        await db.into(db.tanks).insert(TanksCompanion.insert(
                              tankCode: code,
                              tankName: name,
                              tankType: tankType,
                              capacityLiter: cap,
                            ));
                      });
                      if (ok && ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('সেভ করুন'),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}
