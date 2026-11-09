import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/app_database.dart';
import '../../providers/database_provider.dart';
import '../../utils/ui.dart';
import 'recipe_editor_screen.dart';

class RecipeListScreen extends ConsumerWidget {
  const RecipeListScreen({super.key});

  Color? _statusColor(String s) {
    switch (s) {
      case 'Approved':
        return Colors.green.shade50;
      case 'Draft':
        return Colors.amber.shade50;
      case 'Obsolete':
        return Colors.grey.shade200;
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    final svc = ref.watch(productionServiceProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Recipes / BOM')),
      body: StreamBuilder<List<Recipe>>(
        stream: (db.select(db.recipes)..orderBy([(r) => OrderingTerm.asc(r.recipeCode)])).watch(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final recipes = snapshot.data!;
          if (recipes.isEmpty) {
            return const Center(child: Text('কোনো রেসিপি নেই। + চাপুন নতুন রেসিপি বানাতে।'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(10),
            itemCount: recipes.length,
            itemBuilder: (context, i) {
              final r = recipes[i];
              return Card(
                color: _statusColor(r.approvalStatus),
                child: ListTile(
                  leading: CircleAvatar(
                    child: Text('v${r.version}', style: const TextStyle(fontSize: 12)),
                  ),
                  title: Text('${r.recipeCode} - ${r.recipeName}'),
                  subtitle: Text(
                    '${r.approvalStatus} · Base ${r.baseQty} ${r.baseUnit} · Overrun ${r.targetOverrun}% · Aging ${r.agingHours}h',
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'edit') {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => RecipeEditorScreen(recipeId: r.id)),
                        );
                        return;
                      }
                      await runGuarded(context, () async {
                        if (v == 'approve') await svc.approveRecipe(r.id);
                        if (v == 'obsolete') await svc.obsoleteRecipe(r.id);
                        if (v == 'version') {
                          final id = await svc.createRecipeVersion(r.id);
                          if (context.mounted) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => RecipeEditorScreen(recipeId: id)),
                            );
                          }
                        }
                      }, success: v == 'version' ? 'নতুন Draft version তৈরি' : 'আপডেট হয়েছে');
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'edit', child: Text('Edit')),
                      if (r.approvalStatus != 'Approved')
                        const PopupMenuItem(value: 'approve', child: Text('Approve')),
                      const PopupMenuItem(value: 'version', child: Text('New Version (Draft)')),
                      if (r.approvalStatus != 'Obsolete')
                        const PopupMenuItem(value: 'obsolete', child: Text('Mark Obsolete')),
                    ],
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => RecipeEditorScreen(recipeId: r.id)),
                  ),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const RecipeEditorScreen()),
        ),
        child: const Icon(Icons.add),
      ),
    );
  }
}
