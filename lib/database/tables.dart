import 'package:drift/drift.dart';

// ====================== MASTER TABLES ======================

class Items extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get itemCode => text().unique()();
  TextColumn get itemName => text()();
  TextColumn get itemType => text()(); // Raw, Packaging, Mix, Finished, Semi
  TextColumn get baseUnit => text()(); // L, Kg, Pcs, Cup, Cone
  BoolColumn get trackBatch => boolean().withDefault(const Constant(true))();
  BoolColumn get trackExpiry => boolean().withDefault(const Constant(true))();
  BoolColumn get isTankItem => boolean().withDefault(const Constant(false))();
  RealColumn get standardCost => real().withDefault(const Constant(0.0))();
  RealColumn get salesPrice => real().withDefault(const Constant(0.0))();
  RealColumn get minStock => real().withDefault(const Constant(0.0))();
  // Shelf life in days. 0 = unknown. Used to auto-fill expiry on receipts.
  IntColumn get shelfLifeDays => integer().withDefault(const Constant(0))();
  /// e.g. Fat%, SNF%, Protein% — null = not potency-managed
  TextColumn get potencyName => text().nullable()();
  RealColumn get potencyStandard => real().nullable()(); // target/standard potency
  /// Comma-separated allergen codes: Milk,Egg,Nuts,Soy,Gluten,...
  TextColumn get allergens => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class Units extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get unitCode => text().unique()();
  TextColumn get unitName => text()();
}

class UnitConversions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get itemId => integer().references(Items, #id)();
  TextColumn get fromUnit => text()();
  TextColumn get toUnit => text()();
  RealColumn get conversionFactor => real()(); // qty_in_toUnit = qty_in_fromUnit * factor
}

@DataClassName('Warehouse')
class Warehouses extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get warehouseCode => text().unique()();
  TextColumn get warehouseName => text()();
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();
}

class Tanks extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get tankCode => text().unique()();
  TextColumn get tankName => text()();
  TextColumn get tankType => text()(); // Mixing, Aging, Storage
  RealColumn get capacityLiter => real()();
  IntColumn get currentItemId => integer().nullable().references(Items, #id)();
  IntColumn get currentBatchId => integer().nullable()();
  RealColumn get currentQty => real().withDefault(const Constant(0.0))();
  TextColumn get status => text().withDefault(const Constant('Empty'))(); // Empty, InUse, Cleaning
  IntColumn get warehouseId => integer().nullable().references(Warehouses, #id)();
}

@DataClassName('Party')
class Parties extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get partyCode => text().unique()();
  TextColumn get partyName => text()();
  TextColumn get partyType => text()(); // Supplier, Customer, Both
  TextColumn get phone => text().nullable()();
  TextColumn get address => text().nullable()();
  RealColumn get openingBalance => real().withDefault(const Constant(0.0))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

class Recipes extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get recipeCode => text().unique()();
  TextColumn get recipeName => text()();
  IntColumn get finishedItemId => integer().references(Items, #id)();
  RealColumn get baseQty => real()(); // Recipe defined for this mix qty (L)
  TextColumn get baseUnit => text()();
  RealColumn get targetOverrun => real().withDefault(const Constant(100.0))();
  RealColumn get expectedYield => real().withDefault(const Constant(98.0))();
  // Minimum aging time (hours) before freezing. Typical: 4-12.
  RealColumn get agingHours => real().withDefault(const Constant(4.0))();
  IntColumn get version => integer().withDefault(const Constant(1))();
  /// Draft, Approved, Obsolete
  TextColumn get approvalStatus => text().withDefault(const Constant('Approved'))();
  /// Previous version recipe id (lineage)
  IntColumn get parentRecipeId => integer().nullable()();
  /// Optional intermediate Mix item (Semi/Mix) created after mixing
  IntColumn get intermediateItemId => integer().nullable().references(Items, #id)();
  /// Ingredient statement for labels (auto or manual)
  TextColumn get labelIngredients => text().nullable()();
  TextColumn get labelClaims => text().nullable()();
  /// Approx nutrition per 100g / 100ml (simple R&D targets)
  RealColumn get energyKcal => real().nullable()();
  RealColumn get fatG => real().nullable()();
  RealColumn get proteinG => real().nullable()();
  RealColumn get carbG => real().nullable()();
  RealColumn get sugarG => real().nullable()();
  /// Shop-floor work instructions (multiline)
  TextColumn get workInstructions => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get notes => text().nullable()();
}

class RecipeLines extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get recipeId => integer().references(Recipes, #id)();
  IntColumn get itemId => integer().references(Items, #id)();
  RealColumn get qty => real()();
  TextColumn get unit => text()();
  RealColumn get wastagePercent => real().withDefault(const Constant(0.0))();
  /// If true, qty is adjusted by batch potency vs item.potencyStandard
  BoolColumn get scaleByPotency => boolean().withDefault(const Constant(false))();
  IntColumn get sequence => integer().withDefault(const Constant(0))();
}

// ====================== BATCH & STOCK ======================

@DataClassName('Batch')
class Batches extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get batchNo => text()();
  IntColumn get itemId => integer().references(Items, #id)();
  IntColumn get warehouseId => integer().nullable().references(Warehouses, #id)();
  DateTimeColumn get mfgDate => dateTime().nullable()();
  DateTimeColumn get expiryDate => dateTime().nullable()();
  RealColumn get initialQty => real()();
  RealColumn get currentQty => real()();
  RealColumn get unitCost => real().withDefault(const Constant(0.0))();
  /// Actual potency of this lot (e.g. measured fat%)
  RealColumn get potencyValue => real().nullable()();
  TextColumn get status => text().withDefault(const Constant('Available'))();

  @override
  List<Set<Column>> get uniqueKeys => [
        {itemId, batchNo},
      ];
}

class StockLedger extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get voucherId => integer().nullable()();
  // Purchase, ProductionIssue, ProductionIssueReversal, ProductionReceipt, Sales, Adjustment, Transfer
  TextColumn get voucherType => text()();
  IntColumn get itemId => integer().references(Items, #id)();
  IntColumn get batchId => integer().nullable().references(Batches, #id)();
  IntColumn get warehouseId => integer().nullable().references(Warehouses, #id)();
  IntColumn get tankId => integer().nullable().references(Tanks, #id)();
  RealColumn get qtyIn => real().withDefault(const Constant(0.0))();
  RealColumn get qtyOut => real().withDefault(const Constant(0.0))();
  RealColumn get unitCost => real().nullable()();
  DateTimeColumn get transactionDate => dateTime()();
  TextColumn get narration => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

// ====================== PRODUCTION ======================

class ProductionOrders extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get orderNo => text().unique()();
  IntColumn get recipeId => integer().references(Recipes, #id)();
  RealColumn get targetQty => real()(); // Target Mix Qty in Liters
  TextColumn get targetUnit => text()();
  RealColumn get plannedOverrun => real().nullable()();
  TextColumn get status => text().withDefault(const Constant('Planned'))();
  // Planned, Mixing, Aging, Freezing, Completed, Cancelled
  IntColumn get mixingTankId => integer().nullable().references(Tanks, #id)();
  IntColumn get agingTankId => integer().nullable().references(Tanks, #id)();
  DateTimeColumn get startDate => dateTime().nullable()();
  DateTimeColumn get agingStartedAt => dateTime().nullable()();
  DateTimeColumn get endDate => dateTime().nullable()();
  RealColumn get actualMixQty => real().nullable()();
  RealColumn get actualFinishedQty => real().nullable()();
  RealColumn get actualOverrun => real().nullable()();
  RealColumn get actualYield => real().nullable()();
  RealColumn get totalMaterialCost => real().withDefault(const Constant(0.0))();
  // Labour / electricity / gas / depreciation absorbed into this batch
  RealColumn get otherCost => real().withDefault(const Constant(0.0))();
  TextColumn get notes => text().nullable()();
  // Phase 1/2 BatchMaster-style fields
  TextColumn get sourceType => text().withDefault(const Constant('Manual'))(); // Manual, Demand, Sales
  TextColumn get operatorName => text().nullable()();
  TextColumn get qcStatus => text().withDefault(const Constant('Pending'))(); // Pending, Passed, Failed, Held
  TextColumn get holdReason => text().nullable()();
  DateTimeColumn get signedAt => dateTime().nullable()();
  /// Scrap / process loss (L) recorded at completion
  RealColumn get scrapQty => real().withDefault(const Constant(0.0))();
  TextColumn get scrapNotes => text().nullable()();
  /// Intermediate mix batch created at mixing complete
  IntColumn get intermediateBatchId => integer().nullable()();
  TextColumn get signedBy => text().nullable()();
  /// MPS planned start date (calendar scheduling)
  DateTimeColumn get plannedDate => dateTime().nullable()();
  IntColumn get priority => integer().withDefault(const Constant(5))(); // 1 high .. 9 low
  RealColumn get byProductQty => real().withDefault(const Constant(0.0))();
  TextColumn get byProductNotes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class ProductionIssues extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get productionOrderId => integer().references(ProductionOrders, #id)();
  IntColumn get itemId => integer().references(Items, #id)();
  IntColumn get batchId => integer().nullable().references(Batches, #id)();
  RealColumn get qty => real()();
  TextColumn get unit => text().nullable()();
  RealColumn get unitCost => real().nullable()();
  IntColumn get tankId => integer().nullable().references(Tanks, #id)();
  DateTimeColumn get issuedAt => dateTime().withDefault(currentDateAndTime)();
}

class ProductionReceipts extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get productionOrderId => integer().references(ProductionOrders, #id)();
  IntColumn get itemId => integer().references(Items, #id)();
  TextColumn get batchNo => text()();
  RealColumn get qty => real()();
  TextColumn get unit => text().nullable()();
  RealColumn get overrunPercent => real().nullable()();
  RealColumn get unitCost => real().nullable()();
  DateTimeColumn get mfgDate => dateTime().nullable()();
  DateTimeColumn get expiryDate => dateTime().nullable()();
  IntColumn get warehouseId => integer().nullable().references(Warehouses, #id)();
  DateTimeColumn get receivedAt => dateTime().withDefault(currentDateAndTime)();
}

// ====================== QC & ELECTRONIC BATCH RECORD (Phase 1/2) ======================

/// Recipe-level QC test definitions (HACCP / BatchMaster style).
class RecipeQcTests extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get recipeId => integer().references(Recipes, #id)();
  /// Issue, Mixing, Aging, Freezing, Final
  TextColumn get stage => text()();
  TextColumn get testName => text()();
  RealColumn get targetValue => real().nullable()();
  RealColumn get minValue => real().nullable()();
  RealColumn get maxValue => real().nullable()();
  TextColumn get unit => text().nullable()();
  BoolColumn get isMandatory => boolean().withDefault(const Constant(true))();
  IntColumn get sequence => integer().withDefault(const Constant(0))();
}

/// Actual QC results recorded during / after a production order.
class ProductionQcResults extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get productionOrderId => integer().references(ProductionOrders, #id)();
  IntColumn get recipeQcTestId => integer().nullable().references(RecipeQcTests, #id)();
  TextColumn get stage => text()();
  TextColumn get testName => text()();
  RealColumn get actualValue => real().nullable()();
  /// Pass, Fail, N/A
  TextColumn get result => text()();
  TextColumn get notes => text().nullable()();
  TextColumn get recordedBy => text().nullable()();
  DateTimeColumn get recordedAt => dateTime().withDefault(currentDateAndTime)();
}

/// Electronic Batch Record step log (operator actions, sign-offs, deviations).
class ProductionStepLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get productionOrderId => integer().references(ProductionOrders, #id)();
  /// Planned, Issued, Mixed, Aged, Freezing, Completed, QC, Hold, Release, Cancelled, Note
  TextColumn get step => text()();
  TextColumn get action => text()();
  TextColumn get notes => text().nullable()();
  TextColumn get operatorName => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

// ====================== HACCP / CCP / DEVIATION / CAPA ======================

/// Critical Control Points defined per recipe (or global stage).
class HaccpCcps extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get recipeId => integer().nullable().references(Recipes, #id)();
  TextColumn get stage => text()(); // Mixing, Aging, Freezing, Final, Packaging
  TextColumn get ccpName => text()();
  TextColumn get hazard => text().nullable()();
  RealColumn get minLimit => real().nullable()();
  RealColumn get maxLimit => real().nullable()();
  TextColumn get unit => text().nullable()();
  TextColumn get monitoringMethod => text().nullable()();
  TextColumn get correctiveAction => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  IntColumn get sequence => integer().withDefault(const Constant(0))();
}

class ProductionCcpLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get productionOrderId => integer().references(ProductionOrders, #id)();
  IntColumn get haccpCcpId => integer().nullable().references(HaccpCcps, #id)();
  TextColumn get stage => text()();
  TextColumn get ccpName => text()();
  RealColumn get actualValue => real().nullable()();
  /// WithinLimit, OutOfLimit, N/A
  TextColumn get status => text()();
  TextColumn get notes => text().nullable()();
  TextColumn get recordedBy => text().nullable()();
  DateTimeColumn get recordedAt => dateTime().withDefault(currentDateAndTime)();
}

class Deviations extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get productionOrderId => integer().nullable().references(ProductionOrders, #id)();
  TextColumn get deviationNo => text().unique()();
  TextColumn get title => text()();
  TextColumn get description => text().nullable()();
  TextColumn get severity => text().withDefault(const Constant('Minor'))(); // Minor, Major, Critical
  TextColumn get status => text().withDefault(const Constant('Open'))(); // Open, Investigating, Closed
  TextColumn get reportedBy => text().nullable()();
  DateTimeColumn get reportedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get closedAt => dateTime().nullable()();
}

class Capas extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get deviationId => integer().references(Deviations, #id)();
  TextColumn get capaNo => text().unique()();
  TextColumn get actionType => text()(); // Corrective, Preventive
  TextColumn get action => text()();
  TextColumn get owner => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('Open'))(); // Open, Done, Verified
  DateTimeColumn get dueDate => dateTime().nullable()();
  DateTimeColumn get completedAt => dateTime().nullable()();
  TextColumn get verificationNotes => text().nullable()();
}

// ====================== OPERATORS / COMPLIANCE / R&D / TRANSFER ======================

class Operators extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get operatorCode => text().unique()();
  TextColumn get operatorName => text()();
  TextColumn get role => text().withDefault(const Constant('Operator'))(); // Operator, Supervisor, QA
  BoolColumn get canSign => boolean().withDefault(const Constant(true))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

/// FSSAI / internal compliance checklist items (template).
class ComplianceItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get code => text().unique()();
  TextColumn get title => text()();
  TextColumn get category => text().withDefault(const Constant('FSSAI'))(); // FSSAI, GMP, Internal
  BoolColumn get isMandatory => boolean().withDefault(const Constant(true))();
  IntColumn get sequence => integer().withDefault(const Constant(0))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

class ProductionComplianceLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get productionOrderId => integer().references(ProductionOrders, #id)();
  IntColumn get complianceItemId => integer().nullable().references(ComplianceItems, #id)();
  TextColumn get title => text()();
  /// Pass, Fail, N/A
  TextColumn get result => text()();
  TextColumn get notes => text().nullable()();
  TextColumn get signedBy => text().nullable()();
  DateTimeColumn get recordedAt => dateTime().withDefault(currentDateAndTime)();
}

/// R&D / lab trial samples (BatchMaster lab lite).
class RdSamples extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get sampleNo => text().unique()();
  IntColumn get recipeId => integer().nullable().references(Recipes, #id)();
  TextColumn get sampleName => text()();
  TextColumn get status => text().withDefault(const Constant('Open'))(); // Open, Testing, Approved, Rejected
  RealColumn get trialQty => real().nullable()();
  TextColumn get results => text().nullable()();
  TextColumn get sensoryNotes => text().nullable()();
  TextColumn get createdBy => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get closedAt => dateTime().nullable()();
}

/// Inter-warehouse stock transfer header.
class StockTransfers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get transferNo => text().unique()();
  IntColumn get fromWarehouseId => integer().references(Warehouses, #id)();
  IntColumn get toWarehouseId => integer().references(Warehouses, #id)();
  DateTimeColumn get transferDate => dateTime()();
  TextColumn get notes => text().nullable()();
  TextColumn get createdBy => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class StockTransferLines extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get transferId => integer().references(StockTransfers, #id)();
  IntColumn get itemId => integer().references(Items, #id)();
  IntColumn get batchId => integer().nullable().references(Batches, #id)();
  RealColumn get qty => real()();
}

// ====================== ACCOUNTING ======================

class Vouchers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get voucherNo => text().unique()();
  TextColumn get voucherType => text()(); // Purchase, Sales, Payment, Receipt, Journal, Contra
  IntColumn get partyId => integer().nullable().references(Parties, #id)();
  DateTimeColumn get voucherDate => dateTime()();
  RealColumn get totalAmount => real()();
  TextColumn get narration => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class VoucherLines extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get voucherId => integer().references(Vouchers, #id)();
  TextColumn get ledgerName => text()();
  RealColumn get debit => real().withDefault(const Constant(0.0))();
  RealColumn get credit => real().withDefault(const Constant(0.0))();
}
