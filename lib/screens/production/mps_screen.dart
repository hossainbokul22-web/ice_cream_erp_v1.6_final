import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/app_database.dart';
import '../../providers/database_provider.dart';
import '../../utils/ui.dart';
import 'production_order_detail_screen.dart';

class MpsScreen extends ConsumerStatefulWidget {
  const MpsScreen({super.key});

  @override
  ConsumerState<MpsScreen> createState() => _MpsScreenState();
}

class _MpsScreenState extends ConsumerState<MpsScreen> {
  Map<DateTime, List<ProductionOrder>>? cal;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final m = await ref.read(opsServiceProvider).mpsCalendar(days: 14);
    if (mounted) setState(() => cal = m);
  }

  @override
  Widget build(BuildContext context) {
    final map = cal;
    return Scaffold(
      appBar: AppBar(
        title: const Text('MPS — 14 Day Schedule'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: map == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                const Text(
                  'Planned / open production by planned date (priority order)',
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                ),
                const SizedBox(height: 8),
                ...map.entries.map((e) {
                  final day = e.key;
                  final orders = e.value;
                  final label =
                      '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
                  return Card(
                    child: ExpansionTile(
                      title: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text('${orders.length} order(s)'),
                      children: orders.isEmpty
                          ? [const ListTile(dense: true, title: Text('— free —', style: TextStyle(color: Colors.grey)))]
                          : orders
                              .map((o) => ListTile(
                                    dense: true,
                                    title: Text('${o.orderNo} · ${o.status}'),
                                    subtitle: Text(
                                        'Target ${fmtQty(o.targetQty)} L · P${o.priority} · ${o.sourceType}'),
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => ProductionOrderDetailScreen(orderId: o.id),
                                      ),
                                    ).then((_) => _load()),
                                  ))
                              .toList(),
                    ),
                  );
                }),
              ],
            ),
    );
  }
}
