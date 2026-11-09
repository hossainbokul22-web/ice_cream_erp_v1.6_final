import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../providers/database_provider.dart';
import '../../services/stock_service.dart';
import '../../services/pdf_report_service.dart';
import 'package:printing/printing.dart';
import '../../utils/ui.dart';

class MonthlyStockScreen extends ConsumerStatefulWidget {
  const MonthlyStockScreen({super.key});

  @override
  ConsumerState<MonthlyStockScreen> createState() => _MonthlyStockScreenState();
}

class _MonthlyStockScreenState extends ConsumerState<MonthlyStockScreen> {
  late int year;
  late int month;
  String filter = 'All'; // All, RM, FG
  List<MonthlyStockLine>? lines;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    year = n.year;
    month = n.month;
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    List<String>? types;
    if (filter == 'RM') types = ['Raw', 'Packaging'];
    if (filter == 'FG') types = ['Finished'];
    if (filter == 'Mix') types = ['Mix', 'Semi'];
    final list = await ref.read(stockServiceProvider).monthlyStockStatement(
          year: year,
          month: month,
          itemTypes: types,
        );
    if (mounted) setState(() { lines = list; loading = false; });
  }

  Future<void> _share() async {
    final list = lines;
    if (list == null) return;
    final csv = ref.read(stockServiceProvider).monthlyStatementToCsv(list, year, month);
    final dir = await getTemporaryDirectory();
    final name = 'monthly_stock_${year}_${month.toString().padLeft(2, '0')}.csv';
    final file = File(p.join(dir.path, name));
    await file.writeAsString(csv);
    await Share.shareXFiles([XFile(file.path)], text: 'Monthly Stock $year-$month');
  }

  Future<void> _pdf() async {
    final list = lines ?? [];
    final bytes = await PdfReportService.monthlyStockPdf(year: year, month: month, lines: list);
    await Printing.layoutPdf(onLayout: (_) async => bytes);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Monthly Stock Statement'),
        actions: [
          IconButton(icon: const Icon(Icons.picture_as_pdf), onPressed: lines == null ? null : _pdf),
          IconButton(icon: const Icon(Icons.share), onPressed: lines == null ? null : _share),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                DropdownButton<int>(
                  value: month,
                  items: List.generate(
                    12,
                    (i) => DropdownMenuItem(value: i + 1, child: Text('M${i + 1}')),
                  ),
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => month = v);
                      _load();
                    }
                  },
                ),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  value: year,
                  items: [year - 1, year, year + 1]
                      .map((y) => DropdownMenuItem(value: y, child: Text('$y')))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => year = v);
                      _load();
                    }
                  },
                ),
                const Spacer(),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'All', label: Text('All')),
                    ButtonSegment(value: 'RM', label: Text('RM')),
                    ButtonSegment(value: 'FG', label: Text('FG')),
                  ],
                  selected: {filter},
                  onSelectionChanged: (s) {
                    setState(() => filter = s.first);
                    _load();
                  },
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              'Opening → Purchase / ProdIn → Issue / Sales → Closing  |  Share = CSV',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : (lines == null || lines!.isEmpty)
                    ? const Center(child: Text('এই মাসে কোনো মুভমেন্ট/স্টক নেই'))
                    : ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: lines!.length,
                        itemBuilder: (ctx, i) {
                          final l = lines![i];
                          return Card(
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${l.item.itemType} · ${l.item.itemCode} — ${l.item.itemName}',
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Open ${fmtQty(l.opening)}  +Pur ${fmtQty(l.purchase)}  +Prod ${fmtQty(l.productionIn)}\n'
                                    '−Issue ${fmtQty(l.productionIssue)}  −Sales ${fmtQty(l.sales)}  '
                                    'NetXfer ${fmtQty(l.transferNet)}  Adj ${fmtQty(l.adjustmentNet)}\n'
                                    'Close ${fmtQty(l.closing)} ${l.item.baseUnit}',
                                    style: const TextStyle(fontSize: 12, height: 1.35),
                                  ),
                                ],
                              ),
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
