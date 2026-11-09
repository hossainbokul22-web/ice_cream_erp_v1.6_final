import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../providers/database_provider.dart';
import '../../services/pdf_report_service.dart';
import '../../services/stock_service.dart';
import '../../utils/ui.dart';

/// Boss format: Opening | Receive | Use | Reject | Wastage | Return | Closing (RM + Packaging)
class RmPackDailyScreen extends ConsumerStatefulWidget {
  const RmPackDailyScreen({super.key});

  @override
  ConsumerState<RmPackDailyScreen> createState() => _RmPackDailyScreenState();
}

class _RmPackDailyScreenState extends ConsumerState<RmPackDailyScreen> {
  DateTime day = DateTime.now();
  List<RmPackDayLine>? lines;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    final list = await ref.read(stockServiceProvider).rmPackDailyRegister(day: day);
    if (mounted) setState(() { lines = list; loading = false; });
  }

  Future<void> _pdf({bool share = false}) async {
    final list = lines ?? [];
    final bytes = await PdfReportService.rmPackDailyPdf(day: day, lines: list);
    if (share) {
      final dir = await getTemporaryDirectory();
      final name = 'rm_pack_daily_${day.toIso8601String().substring(0, 10)}.pdf';
      final f = File(p.join(dir.path, name));
      await f.writeAsBytes(bytes);
      await Share.shareXFiles([XFile(f.path, mimeType: 'application/pdf')]);
    } else {
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RM/Pack Daily Stock'),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today),
            onPressed: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: day,
                firstDate: DateTime(2020),
                lastDate: DateTime.now().add(const Duration(days: 1)),
              );
              if (d != null) {
                setState(() => day = d);
                await _load();
              }
            },
          ),
          IconButton(icon: const Icon(Icons.picture_as_pdf), tooltip: 'A4 PDF Print', onPressed: () => _pdf()),
          IconButton(icon: const Icon(Icons.share), tooltip: 'Share PDF', onPressed: () => _pdf(share: true)),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(
                    'তারিখ: ${day.toIso8601String().substring(0, 10)}\n'
                    'Opening = আগের দিনের Closing · Use = ফর্মুলা অনুযায়ী Production Issue (FEFO অটো)\n'
                    'PDF = A4 ল্যান্ডস্কেপ',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ),
                Expanded(
                  child: (lines == null || lines!.isEmpty)
                      ? const Center(child: Text('এই তারিখে কোনো RM/Pack মুভমেন্ট নেই'))
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
                                      '${l.item.itemType} · ${l.item.itemCode} — ${l.item.itemName} (${l.item.baseUnit})',
                                      style: const TextStyle(fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(height: 6),
                                    Wrap(
                                      spacing: 10,
                                      runSpacing: 4,
                                      children: [
                                        _chip('Open', l.opening),
                                        _chip('Receive', l.receive),
                                        _chip('Use', l.use),
                                        _chip('Reject', l.reject),
                                        _chip('Wastage', l.wastage),
                                        _chip('Return', l.returned),
                                        _chip('Close', l.closing, bold: true),
                                      ],
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

  Widget _chip(String k, double v, {bool bold = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: bold ? Colors.indigo.shade50 : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text('$k: ${fmtQty(v)}',
            style: TextStyle(fontSize: 12, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
      );
}
