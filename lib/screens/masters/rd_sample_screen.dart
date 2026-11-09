import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/app_database.dart';
import '../../providers/database_provider.dart';
import '../../utils/ui.dart';

class RdSampleScreen extends ConsumerStatefulWidget {
  const RdSampleScreen({super.key});

  @override
  ConsumerState<RdSampleScreen> createState() => _RdSampleScreenState();
}

class _RdSampleScreenState extends ConsumerState<RdSampleScreen> {
  List<RdSample> list = [];
  List<Recipe> recipes = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(databaseProvider);
    list = await ref.read(opsServiceProvider).rdSamples();
    recipes = await db.select(db.recipes).get();
    if (mounted) setState(() {});
  }

  Future<void> _create() async {
    final name = TextEditingController();
    final qty = TextEditingController();
    int? recipeId = recipes.isNotEmpty ? recipes.first.id : null;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('R&D Sample / Trial'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Sample name *')),
            if (recipes.isNotEmpty)
              DropdownButtonFormField<int>(
                value: recipeId,
                items: recipes
                    .map((r) => DropdownMenuItem(value: r.id, child: Text(r.recipeCode)))
                    .toList(),
                onChanged: (v) => setD(() => recipeId = v),
                decoration: const InputDecoration(labelText: 'Base recipe'),
              ),
            TextField(
              controller: qty,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Trial qty (L)'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            FilledButton(
              onPressed: () async {
                if (name.text.trim().isEmpty) return;
                await runGuarded(ctx, () => ref.read(opsServiceProvider).createRdSample(
                      sampleName: name.text.trim(),
                      recipeId: recipeId,
                      trialQty: parseNum(qty.text),
                    ));
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('R&D / Lab Samples')),
      floatingActionButton: FloatingActionButton(onPressed: _create, child: const Icon(Icons.add)),
      body: list.isEmpty
          ? const Center(child: Text('কোনো sample নেই'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: list.length,
              itemBuilder: (ctx, i) {
                final s = list[i];
                return Card(
                  child: ListTile(
                    title: Text('${s.sampleNo} — ${s.sampleName}'),
                    subtitle: Text('${s.status} · qty ${s.trialQty ?? "—"} L\n${s.sensoryNotes ?? s.results ?? ""}'),
                    isThreeLine: true,
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) async {
                        await runGuarded(context, () => ref.read(opsServiceProvider).updateRdSample(
                              id: s.id,
                              status: v,
                            ));
                        await _load();
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'Testing', child: Text('Testing')),
                        PopupMenuItem(value: 'Approved', child: Text('Approve')),
                        PopupMenuItem(value: 'Rejected', child: Text('Reject')),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
