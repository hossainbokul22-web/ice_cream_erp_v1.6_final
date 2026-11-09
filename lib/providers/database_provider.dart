import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/app_database.dart';
import '../services/accounting_service.dart';
import '../services/production_service.dart';
import '../services/sales_service.dart';
import '../services/stock_service.dart';
import '../services/ops_service.dart';
import '../utils/seed_data.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(() => db.close());
  return db;
});

/// Runs once at startup: makes sure units + default warehouse exist.
final appInitProvider = FutureProvider<void>((ref) async {
  final db = ref.watch(databaseProvider);
  await ensureBaseData(db);
  await OpsService(db).seedOperatorsAndCompliance();
});

final productionServiceProvider =
    Provider<ProductionService>((ref) => ProductionService(ref.watch(databaseProvider)));

final stockServiceProvider =
    Provider<StockService>((ref) => StockService(ref.watch(databaseProvider)));

final accountingServiceProvider =
    Provider<AccountingService>((ref) => AccountingService(ref.watch(databaseProvider)));

final salesServiceProvider =
    Provider<SalesService>((ref) => SalesService(ref.watch(databaseProvider)));

final opsServiceProvider =
    Provider<OpsService>((ref) => OpsService(ref.watch(databaseProvider)));
