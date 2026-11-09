import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'screens/dashboard/home_screen.dart';
import 'screens/production/production_order_list_screen.dart';
import 'screens/masters/item_list_screen.dart';
import 'screens/masters/recipe_list_screen.dart';
import 'screens/masters/tank_list_screen.dart';
import 'screens/inventory/stock_summary_screen.dart';
import 'screens/accounts/voucher_list_screen.dart';
import 'screens/reports/reports_screen.dart';
import 'screens/parties/party_list_screen.dart';
import 'screens/inventory/purchase_receipt_screen.dart';
import 'screens/accounts/sale_screen.dart';
import 'providers/database_provider.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: IceCreamERPApp()));
}

class IceCreamERPApp extends ConsumerWidget {
  const IceCreamERPApp({super.key});

  ThemeData _theme() => ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0D47A1),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(centerTitle: false, elevation: 0),
        cardTheme: CardThemeData(
          elevation: 1,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          isDense: true,
        ),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final init = ref.watch(appInitProvider);
    return init.when(
      loading: () => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
      error: (e, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('ডাটাবেস চালু করা যায়নি:\n$e', textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
      data: (_) => MaterialApp.router(
        title: 'Ice Cream ERP',
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        routerConfig: _router,
      ),
    );
  }
}

final GlobalKey<NavigatorState> _rootKey = GlobalKey<NavigatorState>();
final GlobalKey<NavigatorState> _shellKey = GlobalKey<NavigatorState>();

final _router = GoRouter(
  navigatorKey: _rootKey,
  initialLocation: '/',
  routes: [
    // Five main tabs share the Galaxy bottom navigation bar.
    ShellRoute(
      navigatorKey: _shellKey,
      builder: (context, state, child) =>
          GalaxyNavShell(location: state.uri.path, child: child),
      routes: [
        GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
        GoRoute(path: '/production', builder: (context, state) => const ProductionOrderListScreen()),
        GoRoute(path: '/stock', builder: (context, state) => const StockSummaryScreen()),
        GoRoute(path: '/vouchers', builder: (context, state) => const VoucherListScreen()),
        GoRoute(path: '/reports', builder: (context, state) => const ReportsScreen()),
      ],
    ),
    // Master screens open full screen (opened from Home tiles).
    GoRoute(path: '/items', parentNavigatorKey: _rootKey, builder: (context, state) => const ItemListScreen()),
    GoRoute(path: '/recipes', parentNavigatorKey: _rootKey, builder: (context, state) => const RecipeListScreen()),
    GoRoute(path: '/tanks', parentNavigatorKey: _rootKey, builder: (context, state) => const TankListScreen()),
    GoRoute(path: '/parties', parentNavigatorKey: _rootKey, builder: (context, state) => const PartyListScreen()),
    GoRoute(path: '/purchase', parentNavigatorKey: _rootKey, builder: (context, state) => const PurchaseReceiptScreen()),
    GoRoute(path: '/sale', parentNavigatorKey: _rootKey, builder: (context, state) => const SaleScreen()),
  ],
);

// ============================ GALAXY NAVIGATION ============================

class _NavTab {
  const _NavTab(this.path, this.label, this.icon);
  final String path;
  final String label;
  final IconData icon;
}

class GalaxyNavShell extends StatelessWidget {
  const GalaxyNavShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  static const List<_NavTab> _tabs = [
    _NavTab('/', 'Home', Icons.home_rounded),
    _NavTab('/production', 'Production', Icons.precision_manufacturing),
    _NavTab('/stock', 'Stock', Icons.inventory_2),
    _NavTab('/vouchers', 'Vouchers', Icons.receipt_long),
    _NavTab('/reports', 'Reports', Icons.assessment),
  ];

  int get _index {
    for (var i = _tabs.length - 1; i > 0; i--) {
      if (location.startsWith(_tabs[i].path)) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final index = _index;
    return PopScope(
      canPop: index == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) context.go('/');
      },
      child: Scaffold(
        body: child,
        bottomNavigationBar: _GalaxyBar(
          index: index,
          tabs: _tabs,
          onTap: (i) => context.go(_tabs[i].path),
        ),
      ),
    );
  }
}

class _GalaxyBar extends StatelessWidget {
  const _GalaxyBar({
    required this.index,
    required this.tabs,
    required this.onTap,
  });

  final int index;
  final List<_NavTab> tabs;
  final ValueChanged<int> onTap;

  static const Color _idle = Color(0xFF9AA4C7);

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(8, 8, 8, 8 + bottomInset),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0B1026), Color(0xFF1B1040), Color(0xFF0B1F3F)],
        ),
        border: Border(top: BorderSide(color: Color(0x336EE7F9))),
      ),
      child: CustomPaint(
        painter: _StarsPainter(),
        child: Row(
          children: [
            for (var i = 0; i < tabs.length; i++) Expanded(child: _item(i)),
          ],
        ),
      ),
    );
  }

  Widget _item(int i) {
    final selected = i == index;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onTap(i),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: selected
                  ? const LinearGradient(
                      colors: [Color(0xFF7C3AED), Color(0xFF06B6D4)],
                    )
                  : null,
              boxShadow: selected
                  ? const [
                      BoxShadow(color: Color(0x887C3AED), blurRadius: 14),
                    ]
                  : const [],
            ),
            child: Icon(
              tabs[i].icon,
              size: 22,
              color: selected ? Colors.white : _idle,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            tabs[i].label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? Colors.white : _idle,
            ),
          ),
        ],
      ),
    );
  }
}

// Small fixed "stars" scattered behind the tabs.
class _StarsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(7);
    final paint = Paint();
    for (var i = 0; i < 28; i++) {
      final dx = rnd.nextDouble() * size.width;
      final dy = rnd.nextDouble() * size.height;
      final r = 0.4 + rnd.nextDouble() * 0.9;
      paint.color = Colors.white.withAlpha(60 + rnd.nextInt(140));
      canvas.drawCircle(Offset(dx, dy), r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
