import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/database_provider.dart';
import '../../services/production_math.dart';
import '../../services/production_service.dart';
import '../../utils/ui.dart';

/// Bi-directional batch genealogy / recall view (BatchMaster style).
class GenealogyScreen extends ConsumerStatefulWidget {
  const GenealogyScreen({super.key, required this.orderId});
  final int orderId;

  @override
  ConsumerState<GenealogyScreen> createState() => _GenealogyScreenState();
}

class _GenealogyScreenState extends ConsumerState<GenealogyScreen> {
  Genealogy? g;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await ref.read(productionServiceProvider).getGenealogy(widget.orderId);
      if (mounted) setState(() { g = data; error = null; });
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Batch Genealogy')),
        body: Center(child: Text(error!)),
      );
    }
    final data = g;
    if (data == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Genealogy · ${data.order.orderNo}'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Status: ${data.order.status} · QC: ${data.order.qcStatus}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (data.order.holdReason != null)
                    Text('Hold: ${data.order.holdReason}', style: const TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text('← Raw Materials (Issue)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 6),
          if (data.rawMaterials.isEmpty)
            const Text('কোনো material issue নেই', style: TextStyle(color: Colors.grey))
          else
            ...data.rawMaterials.map((r) => Card(
                  child: ListTile(
                    dense: true,
                    title: Text(r.itemName),
                    subtitle: Text(
                        'Batch: ${r.batchNo ?? "—"} · ${fmtQty(r.qty)} · ${r.issuedAt.toString().substring(0, 16)}'),
                    trailing: r.unitCost != null ? Text(fmtMoney(r.unitCost! * r.qty)) : null,
                  ),
                )),
          const SizedBox(height: 16),
          const Text('→ Finished Goods + Sales', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 6),
          if (data.finishedGoods.isEmpty)
            const Text('এখনো FG receipt হয়নি', style: TextStyle(color: Colors.grey))
          else
            ...data.finishedGoods.map((fg) {
              return Card(
                child: ExpansionTile(
                  title: Text('FG Batch ${fg.batchNo}'),
                  subtitle: Text('${fmtQty(fg.qty)} L · Cost/L ${fg.unitCost != null ? fmtMoney(fg.unitCost!) : "—"}'),
                  children: [
                    if (fg.mfgDate != null)
                      ListTile(dense: true, title: Text('Mfg: ${fg.mfgDate!.toString().substring(0, 10)}')),
                    if (fg.expiryDate != null)
                      ListTile(dense: true, title: Text('Expiry: ${fg.expiryDate!.toString().substring(0, 10)}')),
                    if (fg.sales.isEmpty)
                      const ListTile(dense: true, title: Text('এখনো কোনো সেল হয়নি', style: TextStyle(color: Colors.grey)))
                    else
                      ...fg.sales.map((s) => ListTile(
                            dense: true,
                            leading: const Icon(Icons.point_of_sale, size: 18),
                            title: Text('${fmtQty(s.qty)} · ${s.partyName ?? "Cash/Unknown"}'),
                            subtitle: Text(s.date.toString().substring(0, 16)),
                          )),
                  ],
                ),
              );
            }),
          const SizedBox(height: 24),
          const Text(
            'এই রিপোর্ট থেকে raw lot → FG → customer ট্রেস করা যায় (recall-ready)।',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
