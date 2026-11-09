import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/database_provider.dart';
import '../../services/production_math.dart';
import '../../services/production_service.dart';
import '../../utils/ui.dart';
import 'production_order_detail_screen.dart';

/// Phase 4: Auto demand from min-stock → create Production Order.
class DemandPlanningScreen extends ConsumerStatefulWidget {
  const DemandPlanningScreen({super.key});

  @override
  ConsumerState<DemandPlanningScreen> createState() => _DemandPlanningScreenState();
}

class _DemandPlanningScreenState extends ConsumerState<DemandPlanningScreen> {
  List<DemandSuggestion>? list;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    final r = await ref.read(productionServiceProvider).suggestDemandOrders();
    if (mounted) setState(() { list = r; loading = false; });
  }

  Future<void> _create(DemandSuggestion s) async {
    final ok = await runGuarded(context, () async {
      final id = await ref.read(productionServiceProvider).createFromDemand(s);
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ProductionOrderDetailScreen(orderId: id)),
        );
      }
    }, success: 'Demand থেকে Production Order তৈরি');
    if (ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Demand → Production'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : (list == null || list!.isEmpty)
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'কোনো demand নেই।\nFinished item-এর Min Stock সেট করুন এবং স্টক কম থাকলে এখানে সাজেশন আসবে।',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: list!.length,
                  itemBuilder: (ctx, i) {
                    final s = list![i];
                    return Card(
                      child: ListTile(
                        title: Text(s.finishedItem.itemName, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text(
                          'Stock ${fmtQty(s.currentStock)} / Min ${fmtQty(s.minStock)}\n'
                          'Recipe: ${s.recipe.recipeCode} v${s.recipe.version}\n'
                          'Suggested Mix: ${fmtQty(s.suggestedMixQty)} L',
                        ),
                        isThreeLine: true,
                        trailing: FilledButton(
                          onPressed: () => _create(s),
                          child: const Text('PO বানান'),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
