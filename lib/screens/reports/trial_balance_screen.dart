import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/database_provider.dart';
import '../../services/accounting_service.dart';
import '../../services/production_math.dart';
import '../../utils/ui.dart';

class TrialBalanceScreen extends ConsumerWidget {
  const TrialBalanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trial Balance')),
      body: FutureBuilder<List<TrialBalanceRow>>(
        future: ref.read(accountingServiceProvider).trialBalance(),
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final rows = snap.data!;
          if (rows.isEmpty) return const Center(child: Text('কোনো ভাউচার নেই'));
          final dr = round2(rows.fold<double>(0, (s, r) => s + r.debit));
          final cr = round2(rows.fold<double>(0, (s, r) => s + r.credit));
          final ok = (dr - cr).abs() < 0.01;
          return Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    const ListTile(
                      dense: true,
                      title: Text('Ledger', style: TextStyle(fontWeight: FontWeight.bold)),
                      trailing: SizedBox(
                        width: 190,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Debit', style: TextStyle(fontWeight: FontWeight.bold)),
                            Text('Credit', style: TextStyle(fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ),
                    ...rows.map((r) => ListTile(
                          dense: true,
                          title: Text(r.ledger),
                          trailing: SizedBox(
                            width: 190,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [Text(kMoneyFmt.format(r.debit)), Text(kMoneyFmt.format(r.credit))],
                            ),
                          ),
                        )),
                  ],
                ),
              ),
              Container(
                color: ok ? Colors.green.shade50 : Colors.red.shade50,
                padding: const EdgeInsets.all(14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(ok ? 'মিলেছে ✔' : 'অমিল ✖', style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text('Dr ${kMoneyFmt.format(dr)}   Cr ${kMoneyFmt.format(cr)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
