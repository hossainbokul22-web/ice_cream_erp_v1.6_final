import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/database_provider.dart';
import '../../services/production_service.dart';
import '../../utils/ui.dart';
import '../inventory/purchase_receipt_screen.dart';

class MrpScreen extends ConsumerStatefulWidget {
  const MrpScreen({super.key});

  @override
  ConsumerState<MrpScreen> createState() => _MrpScreenState();
}

class _MrpScreenState extends ConsumerState<MrpScreen> {
  List<MrpLine>? lines;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() => loading = true);
    final r = await ref.read(productionServiceProvider).runMrp();
    if (mounted) setState(() { lines = r; loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MRP — Material Shortage'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _run)],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : (lines == null || lines!.isEmpty)
              ? const Center(child: Text('কোনো raw shortage নেই (Planned/Mixing অর্ডার অনুযায়ী)'))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: lines!.length,
                  itemBuilder: (ctx, i) {
                    final m = lines![i];
                    return Card(
                      color: Colors.red.shade50,
                      child: ListTile(
                        title: Text('${m.itemCode} — ${m.itemName}'),
                        subtitle: Text(
                          'দরকার ${fmtQty(m.requiredQty)} ${m.unit}\n'
                          'আছে ${fmtQty(m.availableQty)} · ঘাটতি ${fmtQty(m.shortageQty)}',
                        ),
                        isThreeLine: true,
                        trailing: FilledButton(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const PurchaseReceiptScreen()),
                          ),
                          child: const Text('Purchase'),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
