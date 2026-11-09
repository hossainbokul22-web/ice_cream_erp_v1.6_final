import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/app_database.dart';
import '../../providers/database_provider.dart';
import '../../utils/ui.dart';

class VoucherListScreen extends ConsumerStatefulWidget {
  const VoucherListScreen({super.key});

  @override
  ConsumerState<VoucherListScreen> createState() => _VoucherListScreenState();
}

class _VoucherListScreenState extends ConsumerState<VoucherListScreen> {
  late Future<List<Voucher>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Voucher>> _load() {
    final db = ref.read(databaseProvider);
    return (db.select(db.vouchers)
          ..orderBy([
            (v) => OrderingTerm.desc(v.voucherDate),
            (v) => OrderingTerm.desc(v.id),
          ])
          ..limit(300))
        .get();
  }

  void _reload() => setState(() => _future = _load());

  Color _color(String type) {
    switch (type) {
      case 'Sales':
      case 'Receipt':
        return Colors.green.shade700;
      case 'Purchase':
      case 'Payment':
        return Colors.red.shade700;
      default:
        return Colors.indigo;
    }
  }

  Future<void> _showLines(Voucher v) async {
    final db = ref.read(databaseProvider);
    final lines = await (db.select(db.voucherLines)..where((l) => l.voucherId.equals(v.id))).get();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${v.voucherNo} • ${v.voucherType}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(fmtDate(v.voucherDate)),
              if (v.narration != null && v.narration!.isNotEmpty) Text(v.narration!),
              const Divider(),
              for (final l in lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(child: Text(l.ledgerName)),
                      Text(l.debit > 0 ? 'Dr ${fmtMoney(l.debit)}' : 'Cr ${fmtMoney(l.credit)}'),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বন্ধ'))],
      ),
    );
  }

  Future<void> _newVoucher() async {
    final db = ref.read(databaseProvider);
    final parties = await (db.select(db.parties)
          ..where((p) => p.isActive.equals(true))
          ..orderBy([(p) => OrderingTerm.asc(p.partyName)]))
        .get();
    if (!mounted) return;

    String type = 'Payment';
    int? partyId;
    bool settledNow = true;
    final amount = TextEditingController();
    final head = TextEditingController();
    final dr = TextEditingController();
    final cr = TextEditingController();
    final note = TextEditingController();

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('নতুন ভাউচার'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: type,
                  decoration: const InputDecoration(labelText: 'টাইপ'),
                  items: const ['Payment', 'Receipt', 'Purchase', 'Sales', 'Journal']
                      .map((t) => DropdownMenuItem<String>(value: t, child: Text(t)))
                      .toList(),
                  onChanged: (v) => setS(() => type = v ?? type),
                ),
                TextField(
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Amount (Tk)'),
                ),
                if (type != 'Journal')
                  DropdownButtonFormField<int?>(
                    value: partyId,
                    decoration: const InputDecoration(labelText: 'Party (ঐচ্ছিক)'),
                    items: [
                      const DropdownMenuItem<int?>(value: null, child: Text('— নেই —')),
                      ...parties.map((p) => DropdownMenuItem<int?>(value: p.id, child: Text('${p.partyCode} - ${p.partyName}'))),
                    ],
                    onChanged: (v) => setS(() => partyId = v),
                  ),
                if (type == 'Payment' || type == 'Receipt')
                  TextField(
                    controller: head,
                    decoration: InputDecoration(labelText: type == 'Payment' ? 'খরচের খাত (Party না থাকলে)' : 'আয়ের খাত (Party না থাকলে)'),
                  ),
                if (type == 'Purchase' || type == 'Sales')
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(type == 'Purchase' ? 'এখনই পরিশোধ' : 'এখনই পাওয়া গেছে'),
                    value: settledNow,
                    onChanged: (v) => setS(() => settledNow = v),
                  ),
                if (type == 'Journal') ...[
                  TextField(controller: dr, decoration: const InputDecoration(labelText: 'Debit ledger')),
                  TextField(controller: cr, decoration: const InputDecoration(labelText: 'Credit ledger')),
                ],
                TextField(controller: note, decoration: const InputDecoration(labelText: 'নোট')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('সংরক্ষণ')),
          ],
        ),
      ),
    );

    final amt = parseNum(amount.text);
    final headTxt = head.text;
    final drTxt = dr.text;
    final crTxt = cr.text;
    final noteTxt = note.text.trim();
    amount.dispose();
    head.dispose();
    dr.dispose();
    cr.dispose();
    note.dispose();

    if (go != true) return;
    if (amt == null) {
      if (mounted) showSnack(context, 'সঠিক Amount দিন');
      return;
    }
    if (!mounted) return;
    final ok = await runGuarded(
      context,
      () => ref.read(accountingServiceProvider).createVoucher(
            type: type,
            amount: amt,
            partyId: partyId,
            settledNow: settledNow,
            head: headTxt,
            debitLedger: drTxt,
            creditLedger: crTxt,
            narration: noteTxt.isEmpty ? null : noteTxt,
          ),
      success: 'ভাউচার সংরক্ষিত',
    );
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vouchers'),
        actions: [IconButton(onPressed: _reload, icon: const Icon(Icons.refresh))],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newVoucher,
        icon: const Icon(Icons.add),
        label: const Text('ভাউচার'),
      ),
      body: FutureBuilder<List<Voucher>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text(friendlyError(snap.error!)));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final list = snap.data!;
          if (list.isEmpty) return const Center(child: Text('কোনো ভাউচার নেই। + চাপুন।'));
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 80),
            itemCount: list.length,
            itemBuilder: (context, i) {
              final v = list[i];
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: _color(v.voucherType).withAlpha(38),
                    child: Icon(Icons.receipt_long, color: _color(v.voucherType)),
                  ),
                  title: Text('${v.voucherNo} • ${v.voucherType}'),
                  subtitle: Text('${fmtDate(v.voucherDate)}${v.narration == null || v.narration!.isEmpty ? '' : '\n${v.narration}'}'),
                  isThreeLine: v.narration != null && v.narration!.isNotEmpty,
                  trailing: Text(fmtMoney(v.totalAmount), style: const TextStyle(fontWeight: FontWeight.w600)),
                  onTap: () => _showLines(v),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
