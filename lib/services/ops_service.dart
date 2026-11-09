import 'package:drift/drift.dart';
import '../database/app_database.dart';
import 'production_math.dart';

/// Operators, compliance checklists, R&D samples, MPS helpers.
class OpsService {
  OpsService(this.db);
  final AppDatabase db;

  Future<List<Operator>> operators() =>
      (db.select(db.operators)..where((o) => o.isActive.equals(true))).get();

  Future<int> upsertOperator({
    int? id,
    required String code,
    required String name,
    String role = 'Operator',
    bool canSign = true,
  }) async {
    if (id != null) {
      await (db.update(db.operators)..where((o) => o.id.equals(id))).write(
        OperatorsCompanion(
          operatorCode: Value(code),
          operatorName: Value(name),
          role: Value(role),
          canSign: Value(canSign),
        ),
      );
      return id;
    }
    return db.into(db.operators).insert(OperatorsCompanion.insert(
          operatorCode: code,
          operatorName: name,
          role: Value(role),
          canSign: Value(canSign),
        ));
  }

  Future<void> seedOperatorsAndCompliance() async {
    final ops = await db.select(db.operators).get();
    if (ops.isEmpty) {
      await upsertOperator(code: 'OP-01', name: 'Plant Operator', role: 'Operator');
      await upsertOperator(code: 'QA-01', name: 'QA Supervisor', role: 'QA');
      await upsertOperator(code: 'SUP-01', name: 'Shift Supervisor', role: 'Supervisor');
    }
    final items = await db.select(db.complianceItems).get();
    if (items.isEmpty) {
      final defs = [
        ('FSSAI-HYG', 'Personal hygiene & PPE verified', 'FSSAI'),
        ('FSSAI-CIP', 'CIP / equipment cleanliness verified', 'FSSAI'),
        ('FSSAI-TEMP', 'Cold chain / storage temp checked', 'FSSAI'),
        ('FSSAI-LABEL', 'Label & allergen declaration correct', 'FSSAI'),
        ('GMP-AREA', 'Production area free of foreign material', 'GMP'),
        ('GMP-TRACE', 'Batch records complete & signed', 'GMP'),
      ];
      var seq = 0;
      for (final d in defs) {
        await db.into(db.complianceItems).insert(ComplianceItemsCompanion.insert(
              code: d.$1,
              title: d.$2,
              category: Value(d.$3),
              sequence: Value(seq++),
            ));
      }
    }
  }

  Future<List<ComplianceItem>> complianceTemplates() =>
      (db.select(db.complianceItems)
            ..where((c) => c.isActive.equals(true))
            ..orderBy([(c) => OrderingTerm.asc(c.sequence)]))
          .get();

  Future<List<ProductionComplianceLog>> complianceLogs(int orderId) =>
      (db.select(db.productionComplianceLogs)
            ..where((l) => l.productionOrderId.equals(orderId))
            ..orderBy([(l) => OrderingTerm.asc(l.recordedAt)]))
          .get();

  Future<void> recordCompliance({
    required int orderId,
    required String title,
    required String result,
    int? complianceItemId,
    String? notes,
    String? signedBy,
  }) async {
    if (!['Pass', 'Fail', 'N/A'].contains(result)) {
      throw ArgumentError('result Pass/Fail/N/A');
    }
    await db.into(db.productionComplianceLogs).insert(ProductionComplianceLogsCompanion.insert(
          productionOrderId: orderId,
          complianceItemId: Value(complianceItemId),
          title: title,
          result: result,
          notes: Value(notes),
          signedBy: Value(signedBy),
        ));
  }

  Future<List<RdSample>> rdSamples() =>
      (db.select(db.rdSamples)..orderBy([(s) => OrderingTerm.desc(s.createdAt)])).get();

  Future<int> createRdSample({
    required String sampleName,
    int? recipeId,
    double? trialQty,
    String? createdBy,
  }) async {
    final n = await db.customSelect('SELECT COUNT(*) AS c FROM rd_samples').getSingle();
    final c = n.read<int>('c') + 1;
    final no = 'RD-${c.toString().padLeft(4, '0')}';
    return db.into(db.rdSamples).insert(RdSamplesCompanion.insert(
          sampleNo: no,
          recipeId: Value(recipeId),
          sampleName: sampleName,
          trialQty: Value(trialQty),
          createdBy: Value(createdBy),
        ));
  }

  Future<void> updateRdSample({
    required int id,
    String? status,
    String? results,
    String? sensoryNotes,
  }) async {
    await (db.update(db.rdSamples)..where((s) => s.id.equals(id))).write(RdSamplesCompanion(
          status: status != null ? Value(status) : const Value.absent(),
          results: results != null ? Value(results) : const Value.absent(),
          sensoryNotes: sensoryNotes != null ? Value(sensoryNotes) : const Value.absent(),
          closedAt: (status == 'Approved' || status == 'Rejected')
              ? Value(DateTime.now())
              : const Value.absent(),
        ));
  }

  /// MPS: open orders grouped by plannedDate (or createdAt date).
  Future<Map<DateTime, List<ProductionOrder>>> mpsCalendar({int days = 14}) async {
    final start = DateTime.now();
    final from = DateTime(start.year, start.month, start.day);
    final open = await (db.select(db.productionOrders)
          ..where((o) => o.status.isIn(['Planned', 'Mixing', 'Aging', 'Freezing']))
          ..orderBy([
            (o) => OrderingTerm.asc(o.priority),
            (o) => OrderingTerm.asc(o.plannedDate),
          ]))
        .get();
    final map = <DateTime, List<ProductionOrder>>{};
    for (var i = 0; i < days; i++) {
      map[from.add(Duration(days: i))] = [];
    }
    for (final o in open) {
      final d = o.plannedDate ?? o.createdAt;
      final key = DateTime(d.year, d.month, d.day);
      map.putIfAbsent(key, () => []);
      map[key]!.add(o);
    }
    return map;
  }

  Future<void> setPlannedDate(int orderId, DateTime date, {int? priority}) async {
    await (db.update(db.productionOrders)..where((o) => o.id.equals(orderId))).write(
      ProductionOrdersCompanion(
        plannedDate: Value(date),
        priority: priority != null ? Value(priority) : const Value.absent(),
      ),
    );
  }
}
