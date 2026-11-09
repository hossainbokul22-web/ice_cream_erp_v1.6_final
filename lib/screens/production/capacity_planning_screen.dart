import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/database_provider.dart';
import '../../services/production_service.dart';
import '../../utils/ui.dart';
import 'production_order_detail_screen.dart';

/// Phase 4: Tank capacity & open order occupancy.
class CapacityPlanningScreen extends ConsumerStatefulWidget {
  const CapacityPlanningScreen({super.key});

  @override
  ConsumerState<CapacityPlanningScreen> createState() => _CapacityPlanningScreenState();
}

class _CapacityPlanningScreenState extends ConsumerState<CapacityPlanningScreen> {
  List<CapacityRow>? rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ref.read(productionServiceProvider).getCapacitySnapshot();
    if (mounted) setState(() => rows = r);
  }

  @override
  Widget build(BuildContext context) {
    final list = rows;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Capacity Planning'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                const Text(
                  'ট্যাংক স্ট্যাটাস + কোন অর্ডার কোন ট্যাংক ব্যবহার করছে',
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                ),
                const SizedBox(height: 8),
                ...list.map((r) {
                  final t = r.tank;
                  final o = r.occupyingOrder;
                  Color color;
                  switch (t.status) {
                    case 'Empty':
                      color = Colors.green.shade50;
                      break;
                    case 'InUse':
                      color = Colors.orange.shade50;
                      break;
                    default:
                      color = Colors.blueGrey.shade50;
                  }
                  return Card(
                    color: color,
                    child: ListTile(
                      title: Text('${t.tankCode} · ${t.tankName}'),
                      subtitle: Text(
                        '${t.tankType} · ${fmtQty(t.capacityLiter)} L · Status: ${t.status}'
                        '${o != null ? '\nOrder: ${o.orderNo} (${o.status}) · Target ${fmtQty(o.targetQty)} L' : ''}',
                      ),
                      isThreeLine: o != null,
                      trailing: o != null
                          ? IconButton(
                              icon: const Icon(Icons.open_in_new),
                              onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ProductionOrderDetailScreen(orderId: o.id),
                                ),
                              ).then((_) => _load()),
                            )
                          : null,
                    ),
                  );
                }),
              ],
            ),
    );
  }
}
