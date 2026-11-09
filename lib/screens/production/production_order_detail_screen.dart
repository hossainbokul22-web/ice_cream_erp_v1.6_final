import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/app_database.dart';
import '../../providers/database_provider.dart';
import '../../services/production_math.dart';
import '../../services/production_service.dart';
import '../../utils/ui.dart';
import 'genealogy_screen.dart';
import 'haccp_screen.dart';

class ProductionOrderDetailScreen extends ConsumerStatefulWidget {
  const ProductionOrderDetailScreen({super.key, required this.orderId});
  final int orderId;

  @override
  ConsumerState<ProductionOrderDetailScreen> createState() => _ProductionOrderDetailScreenState();
}

class _ProductionOrderDetailScreenState extends ConsumerState<ProductionOrderDetailScreen> {
  OrderDetails? d;
  List<MaterialAvailability> _preview = [];
  List<ProductionStepLog> _logs = [];
  List<ProductionQcResult> _qc = [];

  ProductionService get _svc => ref.read(productionServiceProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await _svc.getOrderDetails(widget.orderId);
    var preview = <MaterialAvailability>[];
    if (data.order.status == 'Planned') {
      preview = await _svc.previewMaterials(data.order.recipeId, data.order.targetQty);
    }
    final logs = await _svc.getStepLogs(widget.orderId);
    final qc = await _svc.getQcResults(widget.orderId);
    // Auto-seed default QC tests once
    await _svc.seedDefaultQcTests(data.order.recipeId);
    if (mounted) {
      setState(() {
        d = data;
        _preview = preview;
        _logs = logs;
        _qc = qc;
      });
    }
  }

  /// Runs a service action, then reloads.
  Future<void> _do(Future<void> Function() action, String ok) async {
    final success = await runGuarded(context, action, success: ok);
    if (success) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final det = d;
    if (det == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final o = det.order;

    return Scaffold(
      appBar: AppBar(
        title: Text(o.orderNo),
        actions: [
          IconButton(
            tooltip: 'Batch Genealogy / Recall',
            icon: const Icon(Icons.account_tree_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => GenealogyScreen(orderId: widget.orderId)),
            ),
          ),
          IconButton(
            tooltip: 'HACCP / CCP',
            icon: const Icon(Icons.health_and_safety_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => HaccpScreen(orderId: widget.orderId, recipeId: o.recipeId),
              ),
            ),
          ),
          if (['Planned', 'Mixing', 'Aging'].contains(o.status))
            IconButton(
              tooltip: 'Cancel Order',
              icon: const Icon(Icons.cancel_outlined),
              onPressed: _cancel,
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _stepper(o.status),
            const SizedBox(height: 8),
            _row('Status', o.status),
            _row('QC Status', o.qcStatus + (o.holdReason != null ? ' — ${o.holdReason}' : '')),
            _row('Recipe', '${det.recipe.recipeCode} - ${det.recipe.recipeName}'),
            if (det.recipe.workInstructions != null && det.recipe.workInstructions!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Card(
                  color: Colors.blue.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Work Instructions', style: TextStyle(fontWeight: FontWeight.bold)),
                        Text(det.recipe.workInstructions!, style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ),
            _row('Target Mix', '${fmtQty(o.targetQty)} L'),
            if (o.actualMixQty != null)
              _row('Actual Mix', '${fmtQty(o.actualMixQty!)} L (Yield ${fmtQty(o.actualYield ?? (o.actualMixQty! / o.targetQty * 100))}%)'),
            if (det.mixingTank != null) _row('Mixing Tank', det.mixingTank!.tankCode),
            if (det.agingTank != null) _row('Aging Tank', det.agingTank!.tankCode),
            if (o.agingStartedAt != null)
              _row('Aging', '${fmtQty(det.agingElapsed ?? 0)} / ${fmtQty(det.recipe.agingHours)} ঘণ্টা'),
            if (o.actualFinishedQty != null) _row('Finished', '${fmtQty(o.actualFinishedQty!)} L'),
            if (o.actualOverrun != null)
              _row('Overrun', '${o.actualOverrun!.toStringAsFixed(1)}% (লক্ষ্য ${fmtQty(o.plannedOverrun ?? det.recipe.targetOverrun)}%, পার্থক্য ${det.overrunVariance!.toStringAsFixed(1)})'),
            if (o.totalMaterialCost > 0) _row('Material Cost', fmtMoney(o.totalMaterialCost)),
            if (o.otherCost > 0) _row('Other Cost', fmtMoney(o.otherCost)),
            if (det.costPerLiterMix != null) _row('Cost / L (Mix)', fmtMoney(det.costPerLiterMix!)),
            if (det.costPerLiterFinished != null) _row('Cost / L (Finished)', fmtMoney(det.costPerLiterFinished!)),
            if (det.finishedItem != null && det.costPerLiterFinished != null && det.finishedItem!.salesPrice > 0)
              _row('Margin / L', fmtMoney(det.finishedItem!.salesPrice - det.costPerLiterFinished!)),
            const SizedBox(height: 16),
            _actions(det),
            if (_preview.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('Material Issue এর আগে যাচাই', style: TextStyle(fontWeight: FontWeight.bold)),
              ..._preview.map((m) => ListTile(
                    dense: true,
                    leading: Icon(m.isShort ? Icons.error : Icons.check_circle, color: m.isShort ? Colors.red : Colors.green),
                    title: Text(m.material.item.itemName),
                    subtitle: Text('দরকার ${fmtQty(m.material.requiredQty)} ${m.material.item.baseUnit} • আছে ${fmtQty(m.available)}'
                        '${m.isShort ? ' • ঘাটতি ${fmtQty(m.shortage)}' : ''}'),
                  )),
            ],
            if (det.issues.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('ইস্যু করা মালামাল', style: TextStyle(fontWeight: FontWeight.bold)),
              ...det.issues.map((l) => ListTile(
                    dense: true,
                    title: Text(l.item?.itemName ?? 'Item #${l.issue.itemId}'),
                    subtitle: Text('Batch ${l.batchNo ?? '-'} • ${fmtQty(l.issue.qty)} ${l.issue.unit ?? ''} × ${(l.issue.unitCost ?? 0).toStringAsFixed(2)}'),
                    trailing: Text(fmtMoney(l.lineCost)),
                  )),
            ],
            // ===== Phase 2: QC =====
            const SizedBox(height: 20),
            Row(
              children: [
                const Text('Quality Control', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const Spacer(),
                if (o.qcStatus == 'Held')
                  TextButton(onPressed: _release, child: const Text('Release Hold')),
                if (o.status != 'Cancelled' && o.qcStatus != 'Held')
                  TextButton(onPressed: _hold, child: const Text('Hold')),
                TextButton.icon(
                  onPressed: _recordQc,
                  icon: const Icon(Icons.science, size: 18),
                  label: const Text('QC এন্ট্রি'),
                ),
              ],
            ),
            if (_qc.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('এখনো কোনো QC রেকর্ড নেই', style: TextStyle(color: Colors.grey, fontSize: 13)),
              )
            else
              ..._qc.map((q) => ListTile(
                    dense: true,
                    leading: Icon(
                      q.result == 'Pass' ? Icons.check_circle : (q.result == 'Fail' ? Icons.error : Icons.help),
                      color: q.result == 'Pass' ? Colors.green : (q.result == 'Fail' ? Colors.red : Colors.grey),
                      size: 20,
                    ),
                    title: Text('${q.stage}: ${q.testName}'),
                    subtitle: Text(
                        '${q.actualValue != null ? q.actualValue.toString() : ""} ${q.notes ?? ""} · ${q.recordedBy ?? ""}'),
                    trailing: Text(q.result, style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: q.result == 'Pass' ? Colors.green : (q.result == 'Fail' ? Colors.red : Colors.grey),
                    )),
                  )),
            if (o.status == 'Completed' || o.status == 'Freezing')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton.icon(
                  onPressed: () => _do(() => _svc.finalizeQc(o.id), 'Final QC Signed'),
                  icon: const Icon(Icons.verified),
                  label: const Text('Final QC Pass + Sign-off'),
                ),
              ),
            // ===== Phase 1: EBR Step Log =====
            const SizedBox(height: 20),
            const Text('Electronic Batch Record (Step Log)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 6),
            if (_logs.isEmpty)
              const Text('কোনো লগ নেই', style: TextStyle(color: Colors.grey, fontSize: 13))
            else
              ..._logs.map((l) => ListTile(
                    dense: true,
                    leading: const Icon(Icons.timeline, size: 18),
                    title: Text('${l.step}: ${l.action}'),
                    subtitle: Text(
                        '${l.createdAt.toString().substring(0, 16)}${l.operatorName != null ? " · ${l.operatorName}" : ""}${l.notes != null ? " · ${l.notes}" : ""}'),
                  )),
          ],
        ),
      ),
    );
  }

  Widget _stepper(String status) {
    const steps = ['Planned', 'Mixing', 'Aging', 'Freezing', 'Completed'];
    final idx = steps.indexOf(status);
    if (status == 'Cancelled') {
      return const Chip(label: Text('Cancelled'), backgroundColor: Color(0xFFE0E0E0));
    }
    return Row(
      children: [
        for (var i = 0; i < steps.length; i++) ...[
          Expanded(
            child: Column(children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: i <= idx ? Colors.indigo : Colors.grey.shade300,
                child: i < idx
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : Text('${i + 1}', style: TextStyle(fontSize: 11, color: i == idx ? Colors.white : Colors.black54)),
              ),
              const SizedBox(height: 2),
              Text(steps[i], style: TextStyle(fontSize: 9, fontWeight: i == idx ? FontWeight.bold : FontWeight.normal)),
            ]),
          ),
        ],
      ],
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 120, child: Text(label, style: const TextStyle(fontSize: 13, color: Colors.grey))),
          Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }

  Widget _actions(OrderDetails det) {
    final o = det.order;
    switch (o.status) {
      case 'Planned':
        final short = _preview.any((m) => m.isShort);
        return FilledButton.icon(
          onPressed: short ? null : () => _do(() => _svc.issueRecipeMaterials(o.id), 'Material Issued (FEFO, প্রকৃত Batch দাম)'),
          icon: const Icon(Icons.outbox),
          label: Text(short ? '1. স্টক ঘাটতি — Purchase করুন' : '1. Material Issue করুন'),
        );
      case 'Mixing':
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          FilledButton.icon(
            onPressed: () => _completeMixing(det),
            icon: const Icon(Icons.blender),
            label: const Text('2. Mixing সম্পন্ন + Actual Mix Qty'),
          ),
          OutlinedButton.icon(onPressed: _extraIssue, icon: const Icon(Icons.add), label: const Text('অতিরিক্ত Material Issue')),
        ]);
      case 'Aging':
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          FilledButton.icon(
            onPressed: () => _startFreezing(det),
            icon: const Icon(Icons.ac_unit),
            label: const Text('3. Freezing শুরু করুন'),
          ),
          OutlinedButton.icon(onPressed: _extraIssue, icon: const Icon(Icons.add), label: const Text('অতিরিক্ত Material Issue (Flavour/Packaging)')),
        ]);
      case 'Freezing':
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          FilledButton.icon(
            onPressed: () => _completeProduction(det),
            icon: const Icon(Icons.inventory),
            label: const Text('4. Finished Goods Receipt'),
          ),
          OutlinedButton.icon(onPressed: _extraIssue, icon: const Icon(Icons.add), label: const Text('অতিরিক্ত Material Issue (Packaging)')),
        ]);
      case 'Completed':
        return const Card(
          color: Colors.green,
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Text('প্রোডাকশন সম্পন্ন হয়েছে', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Future<void> _cancel() async {
    final ok = await confirm(context, 'অর্ডার বাতিল?',
        'ইস্যু করা মালামাল নিজ নিজ Batch এ ফেরত যাবে এবং ট্যাংক ছেড়ে দেওয়া হবে। আর ফেরানো যাবে না।');
    if (ok) await _do(() => _svc.cancelOrder(widget.orderId), 'অর্ডার বাতিল হয়েছে');
  }

  Future<void> _completeMixing(OrderDetails det) async {
    final db = ref.read(databaseProvider);
    final tanks = await db.select(db.tanks).get();
    final mix = tanks.where((t) => t.tankType == 'Mixing' && (t.status == 'Empty' || t.id == det.order.mixingTankId)).toList();
    final age = tanks.where((t) => t.tankType == 'Aging' && (t.status == 'Empty' || t.id == det.order.agingTankId)).toList();
    final qty = TextEditingController(text: fmtQty(det.order.targetQty));
    int? mixId = mix.any((t) => t.id == det.order.mixingTankId) ? det.order.mixingTankId : (mix.isEmpty ? null : mix.first.id);
    int? ageId = age.any((t) => t.id == det.order.agingTankId) ? det.order.agingTankId : null;
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Mixing সম্পন্ন'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: qty,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Actual Mix Qty (L) *'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                isExpanded: true,
                value: mixId,
                decoration: const InputDecoration(labelText: 'Mixing Tank (খালি) *'),
                items: mix.map((t) => DropdownMenuItem(value: t.id, child: Text('${t.tankCode} (${fmtQty(t.capacityLiter)}L)'))).toList(),
                onChanged: (v) => setD(() => mixId = v),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<int?>(
                isExpanded: true,
                value: ageId,
                decoration: const InputDecoration(labelText: 'Aging Tank'),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('— Mixing ট্যাংকেই Aging —')),
                  ...age.map((t) => DropdownMenuItem<int?>(value: t.id, child: Text('${t.tankCode} (${fmtQty(t.capacityLiter)}L)'))),
                ],
                onChanged: (v) => setD(() => ageId = v),
              ),
              if (mix.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('কোনো খালি Mixing ট্যাংক নেই — Tanks থেকে পরিষ্কার সম্পন্ন চিহ্নিত করুন।',
                      style: TextStyle(color: Colors.red, fontSize: 12)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            FilledButton(
              onPressed: () async {
                final q = parseNum(qty.text);
                if (q == null || q <= 0) { showSnack(ctx, 'পরিমাণ ০ এর বেশি হতে হবে'); return; }
                final ok = await runGuarded(ctx, () => _svc.completeMixing(
                    orderId: widget.orderId, actualMixQty: q, mixingTankId: mixId, agingTankId: ageId));
                if (ok && ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('সেভ'),
            ),
          ],
        ),
      ),
    );
    await _load();
  }

  Future<void> _startFreezing(OrderDetails det) async {
    try {
      await _svc.startFreezing(widget.orderId);
      showSnack(context, 'Freezing শুরু হয়েছে');
    } on AgingNotCompleteException catch (e) {
      if (!mounted) return;
      final force = await confirm(context, 'Aging সম্পূর্ণ হয়নি', '${e.toString()}।\nতবুও Freezing শুরু করবেন? (ফুড সেফটি/টেক্সচার ঝুঁকি)');
      if (force) {
        await runGuarded(context, () => _svc.startFreezing(widget.orderId, force: true), success: 'Freezing শুরু হয়েছে (Aging override)');
      }
    } catch (e) {
      if (mounted) await showErrorDialog(context, e);
    }
    await _load();
  }

  Future<void> _completeProduction(OrderDetails det) async {
    final db = ref.read(databaseProvider);
    final warehouses = await db.select(db.warehouses).get();
    final finished = TextEditingController();
    final batch = TextEditingController(text: await db.nextBatchNo('FG'));
    final other = TextEditingController(text: '0');
    final scrap = TextEditingController(text: '0');
    final scrapNotes = TextEditingController();
    final byProd = TextEditingController(text: '0');
    final byNotes = TextEditingController();
    int? whId = (await db.getDefaultWarehouse())?.id;
    DateTime mfg = DateTime.now();
    DateTime? expiry;
    final shelf = det.finishedItem?.shelfLifeDays ?? 0;
    final mix = det.order.actualMixQty ?? 0;
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final f = parseNum(finished.text) ?? 0;
          final ov = mix > 0 && f > 0 ? calcOverrunPercent(mix, f) : null;
          final auto = expiry ?? expiryFromShelfLife(mfg, shelf);
          final oc = parseNum(other.text) ?? 0;
          final cpl = f > 0 ? costPerFinishedUnit(materialCost: det.order.totalMaterialCost, otherCost: oc, finishedQty: f) : null;
          return AlertDialog(
            title: const Text('Finished Goods Receipt'),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: finished,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: 'Actual Finished Qty (L) *', helperText: 'Mix: ${fmtQty(mix)} L'),
                  onChanged: (_) => setD(() {}),
                ),
                const SizedBox(height: 8),
                TextField(controller: batch, decoration: const InputDecoration(labelText: 'Finished Batch No')),
                const SizedBox(height: 8),
                TextField(
                  controller: other,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Labour / বিদ্যুৎ / গ্যাস খরচ (Tk)', helperText: 'এই ব্যাচে ধরা Overhead'),
                  onChanged: (_) => setD(() {}),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: scrap,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Scrap / Process Loss (L)'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: scrapNotes,
                  decoration: const InputDecoration(labelText: 'Scrap Notes (ঐচ্ছিক)'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: byProd,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'By-product qty (L)'),
                ),
                TextField(
                  controller: byNotes,
                  decoration: const InputDecoration(labelText: 'By-product notes'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<int>(
                  isExpanded: true,
                  value: whId,
                  decoration: const InputDecoration(labelText: 'Warehouse'),
                  items: warehouses.map((w) => DropdownMenuItem(value: w.id, child: Text(w.warehouseName))).toList(),
                  onChanged: (v) => setD(() => whId = v),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        final x = await pickDate(ctx, mfg, last: DateTime.now());
                        if (x != null) setD(() => mfg = x);
                      },
                      child: Text('Mfg ${fmtDate(mfg)}', style: const TextStyle(fontSize: 12)),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        final x = await pickDate(ctx, auto ?? mfg, first: mfg);
                        if (x != null) setD(() => expiry = x);
                      },
                      child: Text('Exp ${fmtDate(auto)}', style: const TextStyle(fontSize: 12)),
                    ),
                  ),
                ]),
                if (auto == null)
                  const Text('⚠ মেয়াদ নেই (Finished Item এ Shelf life দিন)', style: TextStyle(fontSize: 11, color: Colors.orange)),
                const SizedBox(height: 10),
                if (ov != null)
                  Card(
                    color: Colors.indigo.shade50,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        'Overrun: ${ov.toStringAsFixed(1)}%  (লক্ষ্য ${fmtQty(det.order.plannedOverrun ?? det.recipe.targetOverrun)}%)\n'
                        'Cost / L: ${cpl == null ? '—' : fmtMoney(cpl)}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
              FilledButton(
                onPressed: () async {
                  final q = parseNum(finished.text);
                  if (q == null || q <= 0) { showSnack(ctx, 'Finished পরিমাণ দিন'); return; }
                  final ok = await runGuarded(ctx, () async {
                    await _svc.completeProduction(
                      orderId: widget.orderId,
                      actualFinishedQty: q,
                      finishedBatchNo: batch.text,
                      warehouseId: whId,
                      mfgDate: mfg,
                      expiryDate: expiry,
                      otherCost: parseNum(other.text) ?? 0,
                      scrapQty: parseNum(scrap.text) ?? 0,
                      scrapNotes: scrapNotes.text.trim().isEmpty ? null : scrapNotes.text.trim(),
                      byProductQty: parseNum(byProd.text) ?? 0,
                      byProductNotes: byNotes.text.trim().isEmpty ? null : byNotes.text.trim(),
                    );
                  });
                  if (ok && ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('Complete'),
              ),
            ],
          );
        },
      ),
    );
    await _load();
  }

  Future<void> _extraIssue() async {
    final db = ref.read(databaseProvider);
    final items = await (db.select(db.items)..where((i) => i.isActive.equals(true) & i.itemType.isNotValue('Finished'))).get();
    if (items.isEmpty || !mounted) return;
    int itemId = items.first.id;
    final qty = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('অতিরিক্ত Material Issue'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<int>(
              isExpanded: true,
              value: itemId,
              decoration: const InputDecoration(labelText: 'Item'),
              items: items.map((i) => DropdownMenuItem(value: i.id, child: Text('${i.itemCode} - ${i.itemName} (${i.baseUnit})', overflow: TextOverflow.ellipsis))).toList(),
              onChanged: (v) => setD(() => itemId = v!),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: qty,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Quantity'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            FilledButton(
              onPressed: () async {
                final q = parseNum(qty.text);
                if (q == null || q <= 0) { showSnack(ctx, 'পরিমাণ দিন'); return; }
                final ok = await runGuarded(ctx, () => _svc.issueExtraMaterial(orderId: widget.orderId, itemId: itemId, qty: q));
                if (ok && ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Issue'),
            ),
          ],
        ),
      ),
    );
    await _load();
  }

  Future<void> _hold() async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hold Order'),
        content: TextField(controller: reason, decoration: const InputDecoration(labelText: 'কারণ'), autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          FilledButton(
            onPressed: () {
              if (reason.text.trim().isEmpty) { showSnack(ctx, 'কারণ লিখুন'); return; }
              Navigator.pop(ctx, true);
            },
            child: const Text('Hold'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _do(() => _svc.holdOrder(widget.orderId, reason.text.trim()), 'Order Held');
    }
  }

  Future<void> _release() async {
    await _do(() => _svc.releaseOrder(widget.orderId), 'Hold মুক্ত করা হয়েছে');
  }

  Future<void> _recordQc() async {
    final det = d;
    if (det == null) return;
    final tests = await _svc.getRecipeQcTests(det.order.recipeId);
    String stage = det.order.status == 'Completed' ? 'Final' : det.order.status;
    if (stage == 'Planned') stage = 'Mixing';
    String testName = tests.isNotEmpty ? tests.first.testName : 'Custom';
    int? testId = tests.isNotEmpty ? tests.first.id : null;
    final stages = ['Mixing', 'Aging', 'Freezing', 'Final'];
    final valueCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    final byCtrl = TextEditingController(text: det.order.operatorName ?? '');
    String result = 'Pass';

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final stageTests = tests.where((t) => t.stage == stage).toList();
          return AlertDialog(
            title: const Text('QC Result এন্ট্রি'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    value: stage,
                    decoration: const InputDecoration(labelText: 'Stage'),
                    items: stages.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                    onChanged: (v) => setD(() {
                      stage = v!;
                      final st = tests.where((t) => t.stage == stage).toList();
                      if (st.isNotEmpty) {
                        testName = st.first.testName;
                        testId = st.first.id;
                      }
                    }),
                  ),
                  const SizedBox(height: 8),
                  if (stageTests.isNotEmpty)
                    DropdownButtonFormField<String>(
                      value: testName,
                      decoration: const InputDecoration(labelText: 'Test'),
                      items: stageTests
                          .map((t) => DropdownMenuItem(value: t.testName, child: Text(t.testName)))
                          .toList(),
                      onChanged: (v) => setD(() {
                        testName = v!;
                        testId = stageTests.firstWhere((t) => t.testName == v).id;
                      }),
                    )
                  else
                    TextField(
                      decoration: const InputDecoration(labelText: 'Test Name'),
                      onChanged: (v) => testName = v,
                    ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: valueCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Actual Value (ঐচ্ছিক)'),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: result,
                    decoration: const InputDecoration(labelText: 'Result'),
                    items: const [
                      DropdownMenuItem(value: 'Pass', child: Text('Pass')),
                      DropdownMenuItem(value: 'Fail', child: Text('Fail')),
                      DropdownMenuItem(value: 'N/A', child: Text('N/A')),
                    ],
                    onChanged: (v) => setD(() => result = v!),
                  ),
                  const SizedBox(height: 8),
                  TextField(controller: notesCtrl, decoration: const InputDecoration(labelText: 'Notes')),
                  const SizedBox(height: 8),
                  TextField(controller: byCtrl, decoration: const InputDecoration(labelText: 'Recorded By')),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
              FilledButton(
                onPressed: () async {
                  final ok = await runGuarded(ctx, () => _svc.recordQcResult(
                        orderId: widget.orderId,
                        stage: stage,
                        testName: testName,
                        actualValue: parseNum(valueCtrl.text),
                        result: result,
                        recipeQcTestId: testId,
                        notes: notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim(),
                        recordedBy: byCtrl.text.trim().isEmpty ? null : byCtrl.text.trim(),
                      ));
                  if (ok && ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
    await _load();
  }
}
