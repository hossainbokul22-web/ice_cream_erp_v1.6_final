import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/database_provider.dart';
import '../../database/app_database.dart';
import '../../utils/ui.dart';

const kItemTypes = ['Raw', 'Packaging', 'Mix', 'Finished', 'Semi'];
const kUnits = ['L', 'ml', 'Kg', 'g', 'Pcs', 'Cup', 'Cone', 'Tin'];

class ItemListScreen extends ConsumerWidget {
  const ItemListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Item Master')),
      body: StreamBuilder<List<Item>>(
        stream: (db.select(db.items)
              ..orderBy([(i) => OrderingTerm.asc(i.itemType), (i) => OrderingTerm.asc(i.itemCode)]))
            .watch(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final items = snapshot.data!;
          if (items.isEmpty) {
            return const Center(child: Text('কোনো আইটেম নেই। + চাপুন নতুন যোগ করতে।'));
          }
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                color: item.isActive ? null : Colors.grey.shade200,
                child: ListTile(
                  title: Text('${item.itemCode} - ${item.itemName}'),
                  subtitle: Text(
                      '${item.itemType} • ${item.baseUnit} • Avg cost ${item.standardCost.toStringAsFixed(2)}'
                      '${item.salesPrice > 0 ? ' • Price ${item.salesPrice.toStringAsFixed(2)}' : ''}'
                      '${item.shelfLifeDays > 0 ? ' • Shelf ${item.shelfLifeDays}d' : ''}'),
                  trailing: item.isActive
                      ? Chip(label: Text(item.itemType, style: const TextStyle(fontSize: 11)), visualDensity: VisualDensity.compact)
                      : const Chip(label: Text('Inactive', style: TextStyle(fontSize: 11)), visualDensity: VisualDensity.compact),
                  onTap: () => _showItemForm(context, ref, item: item),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showItemForm(context, ref),
        child: const Icon(Icons.add),
      ),
    );
  }

  void _showItemForm(BuildContext context, WidgetRef ref, {Item? item}) {
    final codeCtrl = TextEditingController(text: item?.itemCode ?? '');
    final nameCtrl = TextEditingController(text: item?.itemName ?? '');
    final priceCtrl = TextEditingController(text: (item?.salesPrice ?? 0) == 0 ? '' : item!.salesPrice.toString());
    final minCtrl = TextEditingController(text: (item?.minStock ?? 0) == 0 ? '' : item!.minStock.toString());
    final shelfCtrl = TextEditingController(text: (item?.shelfLifeDays ?? 0) == 0 ? '' : item!.shelfLifeDays.toString());
    String itemType = item?.itemType ?? 'Raw';
    String baseUnit = item?.baseUnit ?? 'L';
    bool active = item?.isActive ?? true;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(left: 16, right: 16, top: 16, bottom: MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: StatefulBuilder(
            builder: (context, setState) {
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(item == null ? 'নতুন আইটেম' : 'আইটেম এডিট',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    TextField(controller: codeCtrl, decoration: const InputDecoration(labelText: 'Item Code *')),
                    const SizedBox(height: 8),
                    TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Item Name *')),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: itemType,
                      decoration: const InputDecoration(labelText: 'Type'),
                      items: kItemTypes.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                      onChanged: (v) => setState(() => itemType = v!),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: baseUnit,
                      decoration: const InputDecoration(labelText: 'Base Unit'),
                      items: kUnits.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                      onChanged: (v) => setState(() => baseUnit = v!),
                    ),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: priceCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'Sales Price'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: minCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'Min Stock (alert)'),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    TextField(
                      controller: shelfCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'Shelf life (দিন)', helperText: 'ফাঁকা = মেয়াদ অজানা। দিলে Batch এ মেয়াদ নিজে বসবে।'),
                    ),
                    if (item != null)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Active'),
                        value: active,
                        onChanged: (v) => setState(() => active = v),
                      ),
                    const SizedBox(height: 8),
                    Text(
                        'Cost: ক্রয়ের Batch থেকে স্বয়ংক্রিয় Weighted-average হিসাব হয়, হাতে বসাতে হয় না।',
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () async {
                        final code = codeCtrl.text.trim();
                        final name = nameCtrl.text.trim();
                        if (code.isEmpty || name.isEmpty) {
                          showSnack(ctx, 'Code ও Name দিন');
                          return;
                        }
                        final price = priceCtrl.text.trim().isEmpty ? 0.0 : parseNum(priceCtrl.text);
                        final min = minCtrl.text.trim().isEmpty ? 0.0 : parseNum(minCtrl.text);
                        final shelf = shelfCtrl.text.trim().isEmpty ? 0 : int.tryParse(shelfCtrl.text.trim());
                        if (price == null || price < 0 || min == null || min < 0 || shelf == null || shelf < 0) {
                          showSnack(ctx, 'সংখ্যা ঠিকভাবে দিন (ঋণাত্মক নয়)');
                          return;
                        }
                        final db = ref.read(databaseProvider);
                        final ok = await runGuarded(ctx, () async {
                          if (item == null) {
                            await db.into(db.items).insert(ItemsCompanion.insert(
                                  itemCode: code,
                                  itemName: name,
                                  itemType: itemType,
                                  baseUnit: baseUnit,
                                  salesPrice: Value(price),
                                  minStock: Value(min),
                                  shelfLifeDays: Value(shelf),
                                ));
                          } else {
                            await (db.update(db.items)..where((t) => t.id.equals(item.id))).write(
                              ItemsCompanion(
                                itemCode: Value(code),
                                itemName: Value(name),
                                itemType: Value(itemType),
                                baseUnit: Value(baseUnit),
                                salesPrice: Value(price),
                                minStock: Value(min),
                                shelfLifeDays: Value(shelf),
                                isActive: Value(active),
                              ),
                            );
                          }
                        });
                        if (ok && ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('সেভ করুন'),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}
