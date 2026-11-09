import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' hide Column;
import '../../providers/database_provider.dart';
import '../../database/app_database.dart';
import 'create_production_order_screen.dart';
import 'production_order_detail_screen.dart';
import 'capacity_planning_screen.dart';
import 'demand_planning_screen.dart';
import 'mrp_screen.dart';
import 'mps_screen.dart';

class ProductionOrderListScreen extends ConsumerWidget {
  const ProductionOrderListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Production Orders'),
        actions: [
          IconButton(
            tooltip: 'Demand → PO',
            icon: const Icon(Icons.trending_up),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DemandPlanningScreen())),
          ),
          IconButton(
            tooltip: 'Capacity',
            icon: const Icon(Icons.view_timeline_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CapacityPlanningScreen())),
          ),
          IconButton(
            tooltip: 'MRP Shortage',
            icon: const Icon(Icons.playlist_add_check),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MrpScreen())),
          ),
          IconButton(
            tooltip: 'MPS Schedule',
            icon: const Icon(Icons.calendar_month),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MpsScreen())),
          ),
        ],
      ),
      body: StreamBuilder(
        stream: (db.select(db.productionOrders)..orderBy([(o) => OrderingTerm.desc(o.createdAt)])).watch(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final orders = snapshot.data!;
          if (orders.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.precision_manufacturing, size: 64, color: Colors.grey),
                  const SizedBox(height: 12),
                  const Text('এখনো কোনো প্রোডাকশন অর্ডার নেই'),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateProductionOrderScreen())),
                    icon: const Icon(Icons.add),
                    label: const Text('নতুন প্রোডাকশন শুরু করুন'),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(10),
            itemCount: orders.length,
            itemBuilder: (context, index) {
              final o = orders[index];
              Color statusColor;
              switch (o.status) {
                case 'Planned': statusColor = Colors.blue; break;
                case 'Mixing': statusColor = Colors.orange; break;
                case 'Aging': statusColor = Colors.purple; break;
                case 'Freezing': statusColor = Colors.indigo; break;
                case 'Completed': statusColor = Colors.green; break;
                default: statusColor = Colors.grey;
              }

              return Card(
                child: ListTile(
                  title: Text(o.orderNo, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Target Mix: ${o.targetQty} ${o.targetUnit}'),
                      if (o.actualOverrun != null)
                        Text('Overrun: ${o.actualOverrun!.toStringAsFixed(1)}%'),
                    ],
                  ),
                  trailing: Chip(
                    label: Text(o.status, style: const TextStyle(color: Colors.white, fontSize: 11)),
                    backgroundColor: statusColor,
                    visualDensity: VisualDensity.compact,
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => ProductionOrderDetailScreen(orderId: o.id)),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateProductionOrderScreen()));
        },
        icon: const Icon(Icons.add),
        label: const Text('New Production'),
      ),
    );
  }
}
