import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/database_provider.dart';
import '../../utils/ui.dart';
import '../parties/party_list_screen.dart';
import 'production_report_screen.dart';
import 'profit_loss_screen.dart';
import 'trial_balance_screen.dart';
import '../masters/rd_sample_screen.dart';
import '../inventory/transfer_screen.dart';
import 'daily_inventory_screen.dart';
import 'monthly_stock_screen.dart';
import 'rm_pack_daily_screen.dart';

class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget tile(IconData icon, String title, String sub, Color c, Widget page) => Card(
          child: ListTile(
            leading: CircleAvatar(backgroundColor: c.withAlpha(38), child: Icon(icon, color: c)),
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => page)),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          tile(Icons.inventory_2, 'RM/Pack Daily Stock (Boss)', 'Opening→Receive→Use→Reject→Wastage→Return→Closing · A4 PDF', Colors.indigo, const RmPackDailyScreen()),
          tile(Icons.today, 'Daily Inventory Brief', 'RM+FG স্টক, আজকের purchase/production/sales — CSV Share', Colors.blue, const DailyInventoryScreen()),
          tile(Icons.calendar_view_month, 'Monthly Stock Statement', 'Opening→In→Out→Closing (RM/FG) — CSV/PDF', Colors.cyan, const MonthlyStockScreen()),
          tile(Icons.assessment, 'Profit & Loss', 'বিক্রয়, COGS (ক্লোজিং স্টকসহ), খরচ, নিট লাভ', Colors.green, const ProfitLossScreen()),
          tile(Icons.precision_manufacturing, 'Production Cost Report', 'ব্যাচ অনুযায়ী Overrun, Yield, Cost / লিটার', Colors.deepPurple, const ProductionReportScreen()),
          tile(Icons.balance, 'Trial Balance', 'সব Ledger এর Debit / Credit', Colors.indigo, const TrialBalanceScreen()),
          tile(Icons.groups, 'Party Balances', 'কার কাছে পাবো / কাকে দেবো', Colors.deepOrange, const PartyListScreen()),
          tile(Icons.science, 'R&D / Lab Samples', 'Trial samples, sensory, approve/reject', Colors.teal, const RdSampleScreen()),
          tile(Icons.swap_horiz, 'Warehouse Transfer', 'Batch FEFO warehouse to warehouse', Colors.blueGrey, const TransferScreen()),
          Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.fact_check)),
              title: const Text('Stock Ledger যাচাই'),
              subtitle: const Text('Ledger ও Batch স্টক মিলছে কি না', style: TextStyle(fontSize: 12)),
              onTap: () async {
                final list = await ref.read(stockServiceProvider).reconcile();
                if (!context.mounted) return;
                await showDialog<void>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: Text(list.isEmpty ? 'সব ঠিক আছে ✔' : 'অমিল পাওয়া গেছে'),
                    content: Text(list.isEmpty
                        ? 'সব আইটেমের Ledger ও Batch স্টক মিলেছে।'
                        : list.map((m) => '${m.item.itemName}: ledger ${fmtQty(m.ledgerQty)}, batch ${fmtQty(m.batchQty)}').join('\n')),
                    actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('বন্ধ'))],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
