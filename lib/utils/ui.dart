import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

final DateFormat kDateFmt = DateFormat('dd MMM yyyy');
final DateFormat kDateTimeFmt = DateFormat('dd MMM yyyy, hh:mm a');
final NumberFormat kMoneyFmt = NumberFormat('#,##0.00');

String fmtDate(DateTime? d) => d == null ? '—' : kDateFmt.format(d);
String fmtDateTime(DateTime? d) => d == null ? '—' : kDateTimeFmt.format(d);
String fmtMoney(num v) => '${kMoneyFmt.format(v)} Tk';
String fmtQty(num v) {
  final s = v.toStringAsFixed(3);
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}

/// Converts any thrown error into a message a factory user can understand.
String friendlyError(Object e) {
  if (e is ArgumentError) return e.message?.toString() ?? 'ইনপুট ভুল';
  final s = e.toString();
  if (s.contains('UNIQUE constraint failed')) {
    return 'এই কোড/নম্বর আগে থেকেই আছে — অন্য একটি ব্যবহার করুন';
  }
  if (s.contains('FOREIGN KEY constraint failed')) {
    return 'সম্পর্কিত ডাটা পাওয়া যায়নি বা এটি অন্য জায়গায় ব্যবহৃত';
  }
  return s.replaceFirst('Exception: ', '').replaceFirst('Bad state: ', '');
}

Future<void> showErrorDialog(BuildContext context, Object e) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.error_outline, color: Colors.red),
      title: const Text('সম্ভব হয়নি'),
      content: SingleChildScrollView(child: Text(friendlyError(e))),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ঠিক আছে'))],
    ),
  );
}

void showSnack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

/// Runs [action]; on error shows a dialog, on success an optional snackbar.
/// Returns true when it succeeded.
Future<bool> runGuarded(
  BuildContext context,
  Future<void> Function() action, {
  String? success,
}) async {
  try {
    await action();
    if (context.mounted && success != null) showSnack(context, success);
    return true;
  } catch (e) {
    if (context.mounted) await showErrorDialog(context, e);
    return false;
  }
}

Future<bool> confirm(BuildContext context, String title, String message) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('না')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('হ্যাঁ')),
      ],
    ),
  );
  return r ?? false;
}

double? parseNum(String s) => double.tryParse(s.trim().replaceAll(',', ''));

Future<DateTime?> pickDate(BuildContext context, DateTime? initial, {DateTime? first, DateTime? last}) {
  final now = DateTime.now();
  return showDatePicker(
    context: context,
    initialDate: initial ?? now,
    firstDate: first ?? DateTime(2020),
    lastDate: last ?? DateTime(now.year + 10),
  );
}
