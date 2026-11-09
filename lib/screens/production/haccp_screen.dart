import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/app_database.dart';
import '../../providers/database_provider.dart';
import '../../services/production_service.dart';
import '../../utils/ui.dart';

/// CCP log + Deviation for a production order.
class HaccpScreen extends ConsumerStatefulWidget {
  const HaccpScreen({super.key, required this.orderId, required this.recipeId});
  final int orderId;
  final int recipeId;

  @override
  ConsumerState<HaccpScreen> createState() => _HaccpScreenState();
}

class _HaccpScreenState extends ConsumerState<HaccpScreen> {
  List<HaccpCcp> _ccps = [];
  List<ProductionCcpLog> _logs = [];
  List<Deviation> _devs = [];
  bool loading = true;

  ProductionService get _svc => ref.read(productionServiceProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _svc.seedDefaultCcps(widget.recipeId);
    final ccps = await _svc.getCcps(recipeId: widget.recipeId);
    final logs = await _svc.getCcpLogs(widget.orderId);
    final devs = await _svc.getDeviations(orderId: widget.orderId);
    if (mounted) {
      setState(() {
        _ccps = ccps;
        _logs = logs;
        _devs = devs;
        loading = false;
      });
    }
  }

  Future<void> _record(HaccpCcp ccp) async {
    final val = TextEditingController();
    final notes = TextEditingController();
    final by = TextEditingController();
    String status = 'WithinLimit';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(ccp.ccpName),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (ccp.minLimit != null || ccp.maxLimit != null)
                Text('Limit: ${ccp.minLimit ?? "—"} … ${ccp.maxLimit ?? "—"} ${ccp.unit ?? ""}'),
              TextField(
                controller: val,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Actual'),
              ),
              DropdownButtonFormField<String>(
                value: status,
                items: const [
                  DropdownMenuItem(value: 'WithinLimit', child: Text('Within Limit')),
                  DropdownMenuItem(value: 'OutOfLimit', child: Text('Out of Limit')),
                  DropdownMenuItem(value: 'N/A', child: Text('N/A')),
                ],
                onChanged: (v) => setD(() => status = v!),
                decoration: const InputDecoration(labelText: 'Status'),
              ),
              TextField(controller: notes, decoration: const InputDecoration(labelText: 'Notes')),
              TextField(controller: by, decoration: const InputDecoration(labelText: 'Recorded By *')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            FilledButton(
              onPressed: () async {
                if (by.text.trim().isEmpty) {
                  showSnack(ctx, 'Recorded By দিন');
                  return;
                }
                final ok = await runGuarded(
                  ctx,
                  () => _svc.recordCcp(
                    orderId: widget.orderId,
                    stage: ccp.stage,
                    ccpName: ccp.ccpName,
                    actualValue: parseNum(val.text),
                    status: status,
                    haccpCcpId: ccp.id,
                    notes: notes.text.trim().isEmpty ? null : notes.text.trim(),
                    recordedBy: by.text.trim(),
                  ),
                );
                if (ok && ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    await _load();
  }

  Future<void> _newDeviation() async {
    final title = TextEditingController();
    final desc = TextEditingController();
    final by = TextEditingController();
    String severity = 'Minor';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('New Deviation'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: title, decoration: const InputDecoration(labelText: 'Title *')),
            TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description')),
            DropdownButtonFormField<String>(
              value: severity,
              items: const [
                DropdownMenuItem(value: 'Minor', child: Text('Minor')),
                DropdownMenuItem(value: 'Major', child: Text('Major')),
                DropdownMenuItem(value: 'Critical', child: Text('Critical')),
              ],
              onChanged: (v) => setD(() => severity = v!),
            ),
            TextField(controller: by, decoration: const InputDecoration(labelText: 'Reported By')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            FilledButton(
              onPressed: () async {
                if (title.text.trim().isEmpty) return;
                final ok = await runGuarded(
                  ctx,
                  () => _svc.createDeviation(
                    orderId: widget.orderId,
                    title: title.text.trim(),
                    description: desc.text.trim().isEmpty ? null : desc.text.trim(),
                    severity: severity,
                    reportedBy: by.text.trim().isEmpty ? null : by.text.trim(),
                  ),
                );
                if (ok && ctx.mounted) Navigator.pop(ctx);
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
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(
        title: const Text('HACCP / CCP & CAPA'),
        actions: [
          IconButton(icon: const Icon(Icons.report_gmailerrorred), onPressed: _newDeviation, tooltip: 'Deviation'),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text('Critical Control Points', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ..._ccps.map((c) => Card(
                child: ListTile(
                  title: Text('${c.stage}: ${c.ccpName}'),
                  subtitle: Text(
                    '${c.hazard ?? ""}\nLimit ${c.minLimit ?? "—"}–${c.maxLimit ?? "—"} ${c.unit ?? ""}',
                  ),
                  isThreeLine: true,
                  trailing: FilledButton(onPressed: () => _record(c), child: const Text('Log')),
                ),
              )),
          const SizedBox(height: 16),
          const Text('CCP Logs', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          if (_logs.isEmpty)
            const Text('এখনো লগ নেই', style: TextStyle(color: Colors.grey))
          else
            ..._logs.map((l) => ListTile(
                  dense: true,
                  leading: Icon(
                    l.status == 'WithinLimit' ? Icons.check_circle : Icons.warning,
                    color: l.status == 'WithinLimit' ? Colors.green : Colors.red,
                  ),
                  title: Text('${l.ccpName}: ${l.status}'),
                  subtitle: Text(
                    '${l.actualValue ?? ""} · ${l.recordedBy ?? ""} · ${l.recordedAt.toString().substring(0, 16)}',
                  ),
                )),
          const SizedBox(height: 16),
          const Text('Deviations', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          if (_devs.isEmpty)
            const Text('কোনো deviation নেই', style: TextStyle(color: Colors.grey))
          else
            ..._devs.map((d) => Card(
                  color: d.severity == 'Critical' ? Colors.red.shade50 : null,
                  child: ListTile(
                    title: Text('${d.deviationNo}: ${d.title}'),
                    subtitle: Text('${d.severity} · ${d.status}\n${d.description ?? ""}'),
                    isThreeLine: true,
                    trailing: d.status != 'Closed'
                        ? TextButton(
                            onPressed: () async {
                              await runGuarded(context, () => _svc.closeDeviation(d.id));
                              await _load();
                            },
                            child: const Text('Close'),
                          )
                        : null,
                  ),
                )),
        ],
      ),
    );
  }
}
