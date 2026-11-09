import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/app_database.dart';
import '../../providers/database_provider.dart';
import '../../services/accounting_service.dart';
import '../../utils/ui.dart';

class PartyListScreen extends ConsumerStatefulWidget {
  const PartyListScreen({super.key});

  @override
  ConsumerState<PartyListScreen> createState() => _PartyListScreenState();
}

class _PartyListScreenState extends ConsumerState<PartyListScreen> {
  late Future<List<PartyBalance>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(accountingServiceProvider).partyBalances();
  }

  void _reload() => setState(() => _future = ref.read(accountingServiceProvider).partyBalances());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Parties (Supplier / Customer)')),
      body: FutureBuilder<List<PartyBalance>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final list = snap.data!;
          if (list.isEmpty) return const Center(child: Text('কোনো Party নেই। + চাপুন।'));
          return ListView.builder(
            padding: const EdgeInsets.all(10),
            itemCount: list.length,
            itemBuilder: (context, i) {
              final b = list[i];
              final p = b.party;
              return Card(
                child: ListTile(
                  title: Text('${p.partyCode} - ${p.partyName}'),
                  subtitle: Text('${p.partyType}${p.phone == null || p.phone!.isEmpty ? '' : ' • ${p.phone}'}'),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (b.receivable > 0)
                        Text('পাবো ${fmtMoney(b.receivable)}', style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.w600, fontSize: 12)),
                      if (b.payable > 0)
                        Text('দেবো ${fmtMoney(b.payable)}', style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w600, fontSize: 12)),
                      if (b.receivable == 0 && b.payable == 0) const Text('বকেয়া নেই', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                  onTap: () => _form(p),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(onPressed: () => _form(null), child: const Icon(Icons.add)),
    );
  }

  void _form(Party? p) {
    final code = TextEditingController(text: p?.partyCode ?? '');
    final name = TextEditingController(text: p?.partyName ?? '');
    final phone = TextEditingController(text: p?.phone ?? '');
    final opening = TextEditingController(text: (p?.openingBalance ?? 0) == 0 ? '' : p!.openingBalance.toString());
    String type = p?.partyType ?? 'Supplier';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(left: 16, right: 16, top: 16, bottom: MediaQuery.of(ctx).viewInsets.bottom + 16),
        child: StatefulBuilder(
          builder: (ctx, setS) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(p == null ? 'নতুন Party' : 'Party এডিট', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                TextField(
                  controller: code,
                  enabled: p == null,
                  decoration: InputDecoration(labelText: 'Code *', helperText: p == null ? null : 'Code বদলানো যায় না (হিসাবের সাথে যুক্ত)'),
                ),
                const SizedBox(height: 8),
                TextField(controller: name, decoration: const InputDecoration(labelText: 'Name *')),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: type,
                  decoration: const InputDecoration(labelText: 'Type'),
                  items: const ['Supplier', 'Customer', 'Both'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                  onChanged: (v) => setS(() => type = v!),
                ),
                const SizedBox(height: 8),
                TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone')),
                const SizedBox(height: 8),
                TextField(
                  controller: opening,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  decoration: const InputDecoration(
                      labelText: 'Opening Balance', helperText: '+ = কাস্টমার আমাদের দেবে (পাবো), − = আমরা দেবো'),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () async {
                    final c = code.text.trim(), n = name.text.trim();
                    final ob = opening.text.trim().isEmpty ? 0.0 : parseNum(opening.text);
                    if (c.isEmpty || n.isEmpty) { showSnack(ctx, 'Code ও Name দিন'); return; }
                    if (ob == null) { showSnack(ctx, 'Opening Balance সংখ্যা দিন'); return; }
                    final db = ref.read(databaseProvider);
                    final ok = await runGuarded(ctx, () async {
                      if (p == null) {
                        await db.into(db.parties).insert(PartiesCompanion.insert(
                              partyCode: c,
                              partyName: n,
                              partyType: type,
                              phone: Value(phone.text.trim()),
                              openingBalance: Value(ob),
                            ));
                      } else {
                        await (db.update(db.parties)..where((x) => x.id.equals(p.id))).write(PartiesCompanion(
                          partyName: Value(n),
                          partyType: Value(type),
                          phone: Value(phone.text.trim()),
                          openingBalance: Value(ob),
                        ));
                      }
                    });
                    if (ok && ctx.mounted) {
                      Navigator.pop(ctx);
                      _reload();
                    }
                  },
                  child: const Text('সেভ করুন'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
