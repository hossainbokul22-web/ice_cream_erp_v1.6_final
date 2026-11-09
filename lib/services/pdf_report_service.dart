import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../database/app_database.dart';
import 'stock_service.dart';

/// A4 PDF builders for boss inventory reports.
class PdfReportService {
  static final _date = DateFormat('dd-MMM-yyyy');
  static final _num = NumberFormat('#,##0.###');

  static String n(double v) => _num.format(v);

  /// RM + Packaging daily stock on A4 landscape (fits columns).
  static Future<Uint8List> rmPackDailyPdf({
    required DateTime day,
    required List<RmPackDayLine> lines,
    String plantName = 'Ice Cream Factory',
  }) async {
    final doc = pw.Document();
    final title = 'Daily RM & Packaging Stock Register';
    final dateStr = _date.format(day);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(24),
        header: (c) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(plantName, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
            pw.Text('$title — $dateStr', style: const pw.TextStyle(fontSize: 12)),
            pw.Text(
              'Opening = previous day Closing | Use = Production Issue (formula FEFO) | Closing carries to next day',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 8),
          ],
        ),
        footer: (c) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('Generated offline — Ice Cream ERP', style: const pw.TextStyle(fontSize: 8)),
            pw.Text('Page ${c.pageNumber}/${c.pagesCount}', style: const pw.TextStyle(fontSize: 8)),
          ],
        ),
        build: (c) => [
          pw.TableHelper.fromTextArray(
            headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
            cellStyle: const pw.TextStyle(fontSize: 8),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey100),
            cellAlignments: {
              0: pw.Alignment.centerLeft,
              1: pw.Alignment.centerLeft,
              for (var i = 2; i <= 9; i++) i: pw.Alignment.centerRight,
            },
            headers: const [
              'Type',
              'Item',
              'Unit',
              'Opening',
              'Receive',
              'Use',
              'Reject',
              'Wastage',
              'Return',
              'Closing',
            ],
            data: [
              for (final l in lines)
                [
                  l.item.itemType,
                  '${l.item.itemCode} ${l.item.itemName}',
                  l.item.baseUnit,
                  n(l.opening),
                  n(l.receive),
                  n(l.use),
                  n(l.reject),
                  n(l.wastage),
                  n(l.returned),
                  n(l.closing),
                ],
            ],
          ),
          pw.SizedBox(height: 16),
          pw.Text('Prepared by: _____________    Checked by: _____________    Date: $dateStr',
              style: const pw.TextStyle(fontSize: 9)),
        ],
      ),
    );
    return doc.save();
  }

  static Future<Uint8List> monthlyStockPdf({
    required int year,
    required int month,
    required List<MonthlyStockLine> lines,
    String plantName = 'Ice Cream Factory',
  }) async {
    final doc = pw.Document();
    final label = '$year-${month.toString().padLeft(2, '0')}';
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(24),
        header: (c) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(plantName, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
            pw.Text('Monthly Stock Statement — $label', style: const pw.TextStyle(fontSize: 12)),
            pw.SizedBox(height: 8),
          ],
        ),
        footer: (c) => pw.Text('Page ${c.pageNumber}/${c.pagesCount}', style: const pw.TextStyle(fontSize: 8)),
        build: (c) => [
          pw.TableHelper.fromTextArray(
            headerStyle: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold),
            cellStyle: const pw.TextStyle(fontSize: 7),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.teal100),
            headers: const [
              'Type',
              'Item',
              'Unit',
              'Opening',
              'Purchase',
              'ProdIssue',
              'ProdIn',
              'Sales',
              'XferNet',
              'AdjNet',
              'Closing',
            ],
            data: [
              for (final l in lines)
                [
                  l.item.itemType,
                  '${l.item.itemCode} ${l.item.itemName}',
                  l.item.baseUnit,
                  n(l.opening),
                  n(l.purchase),
                  n(l.productionIssue),
                  n(l.productionIn),
                  n(l.sales),
                  n(l.transferNet),
                  n(l.adjustmentNet),
                  n(l.closing),
                ],
            ],
          ),
        ],
      ),
    );
    return doc.save();
  }
}
