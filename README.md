# Ice Cream ERP (Offline Android)

অফলাইন Android ERP — আইসক্রিম ফ্যাক্টরির জন্য: Recipe/BOM → Material Issue (FEFO, প্রকৃত Batch দাম) → Mixing → Aging → Freezing → Finished Goods → Sale → Accounts।
Flutter + Drift (SQLite) + Riverpod + GoRouter।

## চালানোর নিয়ম

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # app_database.g.dart তৈরি করে (git এ নেই)
flutter test                                               # business-logic টেস্ট
flutter run
```

প্রথমবার হোম স্ক্রিনে "ডেমো ডাটা লোড করুন" চাপলে ভ্যানিলা রেসিপি, ট্যাংক, সরবরাহকারী ও কাঁচামাল স্টক বসে যায় — সাথে সাথে ১০০০ L প্রোডাকশন চালিয়ে দেখা যায়।

## মডিউল

| মডিউল | কী করে |
|---|---|
| Item Master | Raw/Packaging/Mix/Finished, Shelf life (মেয়াদ নিজে বসে), Min stock alert |
| Recipes / BOM | হেডার + ইনগ্রিডিয়েন্ট এডিটর, Wastage %, ইউনিট কনভার্সন, আনুমানিক খরচ/লিটার |
| Purchase Receipt | Batch + Stock Ledger + Purchase Voucher একই ট্রানজ্যাকশনে; Weighted-average cost |
| Production | Order → Material Issue (FEFO) → Mixing → Aging (ন্যূনতম সময় বাধ্যতামূলক) → Freezing → Receipt; Cancel (স্টক ফেরত); Extra issue (Packaging) |
| QC & EBR (Phase 1/2) | Recipe QC tests, stage-wise Pass/Fail, Hold/Release, Electronic Batch Record step log, Final sign-off |
| Batch Genealogy | Bi-directional: Raw lot → FG batch → Customer (recall-ready); Genealogy screen from Production Order |
| Recipe Versioning | Draft / Approved / Obsolete; New Version copies lines+QC |
| Capacity Planning | Tank occupancy by open production orders |
| Demand → PO | FG min-stock gap → suggested mix qty → one-tap Production Order |
| Scrap | Process loss recorded at FG receipt |
| Potency | Fat%/SNF-style scale on issue (scaleByPotency) |
| Intermediate Mix | Semi batch on Mixing complete |
| Allergen / Label | Item allergens → recipe label statement |
| HACCP CCP + CAPA | CCP log, OOL hold, Deviation/CAPA |
| MRP | Open order material shortage → purchase |
| MPS | 14-day planned production calendar |
| Warehouse Transfer | Batch transfer across warehouses |
| R&D Samples | Lab trial samples approve/reject |
| Compliance checklist | FSSAI/GMP templates + per-order log |
| Nutrition + WI | Recipe targets + shop-floor instructions |
| By-product | Recorded at FG receipt |
| Operators | Operator/QA/Supervisor roster |
| Tanks | ধারণক্ষমতা যাচাই, ব্যবহারের পর Cleaning (CIP) → Empty |
| Stock | Batch/মেয়াদ হাইলাইট, মোট মূল্য, Low/Expiry ফিল্টার, Adjustment (দীর্ঘ চাপ), Ledger Reconcile |
| Sale | FEFO, মেয়াদোত্তীর্ণ বাদ, নগদ/বাকি, মার্জিন দেখায় |
| Accounts | Payment/Receipt/Journal ভাউচার (সবসময় Dr = Cr), Party বকেয়া, Trial Balance |
| Reports | P&L (COGS = ক্রয় − ক্লোজিং স্টক), Production Cost Report, Party Balances |
| Backup | হোম → Backup: পুরো DB এর `.sqlite` কপি শেয়ার |

## প্রজেক্ট স্ট্রাকচার

```
lib/
├── database/    tables.dart, app_database.dart (migration, FK on, index, numbering, backup)
├── services/    production_math.dart (pure rules), stock_service, production_service,
│                sales_service, accounting_service
├── screens/     dashboard, masters, inventory, production, accounts, parties, reports
├── providers/   Riverpod providers
└── utils/       ui.dart (error handling, formats), seed_data.dart
test/            production_math_test (pure), production_flow_test (in-memory DB, end-to-end)
```

## Release APK সাইনিং

`android/key.properties` (git-ignored) বানান: `storePassword, keyPassword, keyAlias, storeFile`।
CI তে GitHub Secrets: `KEYSTORE_B64, KEYSTORE_PASSWORD, KEY_ALIAS, KEY_PASSWORD`। কী না থাকলে debug key (শুধু নিজের পরীক্ষার জন্য)।

আরও: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/PRODUCTION_FLOW.md](docs/PRODUCTION_FLOW.md), [docs/NEXT_STEPS.md](docs/NEXT_STEPS.md), [CHANGELOG.md](CHANGELOG.md)
