import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/database_provider.dart';
import '../../services/accounting_service.dart';
import '../../utils/ui.dart';

class ProfitLossScreen extends ConsumerWidget {
  const ProfitLossScreen({super.key});

  Future<ProfitLossReport> _load(WidgetRef ref) async {
    final closing = await ref.read(stockServiceProvider).totalStockValue();
    return ref.read(accountingServiceProvider).profitAndLoss(closingStockValue: closing);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profit & Loss')),
      body: FutureBuilder<ProfitLossReport>(
        future: _load(ref),
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final r = snap.data!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('Profit & Loss Statement', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Text('সময়: শুরু থেকে এখন পর্যন্ত', style: TextStyle(color: Colors.grey.shade600)),
              const Divider(height: 24),
              _row('Sales (বিক্রয়)', r.sales, up: true),
              const SizedBox(height: 6),
              const Text('Cost of Goods Sold', style: TextStyle(fontWeight: FontWeight.bold)),
              _row('  ক্রয় (Purchases)', r.purchases),
              _row('  (−) ক্লোজিং স্টক মূল্য', -r.closingStock),
              _row('  COGS', r.cogs, bold: true),
              const Divider(),
              _row('Gross Profit', r.grossProfit, bold: true, up: r.grossProfit >= 0),
              if (r.otherIncome != 0) _row('(+) অন্যান্য আয়', r.otherIncome, up: true),
              if (r.expenses.isNotEmpty) ...[
                const SizedBox(height: 6),
                const Text('খরচ (Expenses)', style: TextStyle(fontWeight: FontWeight.bold)),
                ...r.expenses.entries.map((e) => _row('  ${e.key}', e.value)),
                _row('  মোট খরচ', r.totalExpenses, bold: true),
              ],
              const Divider(),
              _row('Net Profit', r.netProfit, bold: true, up: r.netProfit >= 0),
              const SizedBox(height: 20),
              Text(
                'COGS = ক্রয় − ক্লোজিং স্টক (Batch দামে)। তাই প্রোডাকশনের Labour/বিদ্যুৎ খরচ Payment ভাউচারে "Expense: …" খাতে লিখে রাখুন; '
                'যে অংশ Production Order এ Other Cost হিসেবে ধরা হয়েছে তা স্টক মূল্যে ঢুকে যায়, ফলে খরচ ও স্টক দুই দিকেই মিলে যায়।',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(String label, double amount, {bool bold = false, bool? up}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: Text(label, style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal))),
          Text(
            fmtMoney(amount),
            style: TextStyle(
              fontWeight: bold ? FontWeight.bold : FontWeight.w600,
              color: up == null ? null : (up ? Colors.green.shade700 : Colors.red.shade700),
            ),
          ),
        ],
      ),
    );
  }
}
