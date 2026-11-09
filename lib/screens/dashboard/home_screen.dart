import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/database_provider.dart';
import '../../services/stock_service.dart';
import '../../utils/ui.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  late Future<DailyInventoryBrief> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(stockServiceProvider).dailyInventoryBrief();
  }

  void _reload() {
    setState(() => _future = ref.read(stockServiceProvider).dailyInventoryBrief());
  }

  Widget _stat(String label, String value, Color color) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 4),
              Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, IconData icon, String title, String path, Color color) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => context.push(path),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(backgroundColor: color.withAlpha(38), child: Icon(icon, color: color)),
            const SizedBox(height: 8),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ice Cream ERP'),
        actions: [IconButton(onPressed: _reload, icon: const Icon(Icons.refresh))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          FutureBuilder<DailyInventoryBrief>(
            future: _future,
            builder: (context, snap) {
              if (snap.hasError) {
                return Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(friendlyError(snap.error!))));
              }
              if (!snap.hasData) {
                return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
              }
              final b = snap.data!;
              return Column(
                children: [
                  Row(children: [
                    _stat('RM স্টক মূল্য', fmtMoney(b.rawValue), Colors.indigo),
                    _stat('FG স্টক মূল্য', fmtMoney(b.finishedValue), Colors.green.shade700),
                  ]),
                  Row(children: [
                    _stat('Low stock', '${b.lowStockCount}', Colors.orange.shade800),
                    _stat('Near expiry', '${b.nearExpiryCount}', Colors.red.shade700),
                  ]),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1,
            children: [
              _tile(context, Icons.category, 'Items', '/items', Colors.indigo),
              _tile(context, Icons.menu_book, 'Recipes', '/recipes', Colors.deepPurple),
              _tile(context, Icons.propane_tank, 'Tanks', '/tanks', Colors.teal),
              _tile(context, Icons.groups, 'Parties', '/parties', Colors.deepOrange),
              _tile(context, Icons.shopping_cart, 'Purchase', '/purchase', Colors.blue),
              _tile(context, Icons.point_of_sale, 'Sale', '/sale', Colors.green),
            ],
          ),
        ],
      ),
    );
  }
}
