import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:parchapp/core/connectivity/connectivity_service.dart';
import 'package:parchapp/features/help/data/help_repository.dart';
import 'package:parchapp/features/help/presentation/help_view.dart';
import 'package:parchapp/features/help/presentation/help_view_model.dart';
import 'package:parchapp/shared/widgets/parch_app_bar.dart';

class Offline extends ConnectivityService {
  @override Future<bool> hasConnection() async => false;
  @override Stream<bool> get connectionChanges => const Stream.empty();
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); sqfliteFfiInit();
  late Directory directory; late HelpRepository repository;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('help-ui-'); SharedPreferences.setMockInitialValues({});
    repository = await HelpRepository.open(path: '${directory.path}/help.sqlite', factory: databaseFactoryFfi, preferences: await SharedPreferences.getInstance(), readAsset: () => File('assets/data/help_faq.json').readAsString(), eligible: () async => false);
  });
  tearDown(() async { await repository.database.close(); await directory.delete(recursive: true); });
  for (final origin in ['schedule', 'groups']) {
    testWidgets('$origin Help entry, expansion, offline search and debounce', (tester) async {
      final router = GoRouter(initialLocation: '/$origin', routes: [
        GoRoute(path: '/$origin', builder: (_, __) => const Scaffold(appBar: ParchAppBar())),
        GoRoute(path: '/help', builder: (_, state) => HelpView(origin: state.uri.queryParameters['origin'] ?? 'general', viewModel: HelpViewModel(open: () async => repository, connectivity: Offline()))),
        GoRoute(path: '/home', builder: (_, __) => const Scaffold()),
      ]);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.tap(find.byTooltip('Help')); await tester.pump(); await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 100)); }); await tester.pumpAndSettle();
      expect(find.text('${origin == 'groups' ? 'Groups' : 'Schedule'} (this screen)'), findsOneWidget);
      expect(find.textContaining("You're offline."), findsOneWidget);
      final title = origin == 'groups' ? 'How do I create a group?' : 'How do I import my Google Calendar?';
      await tester.tap(find.text(title)); await tester.pumpAndSettle();
      expect(find.textContaining(origin == 'groups' ? 'Open the Groups tab' : 'Open Schedule and tap'), findsOneWidget);
      await tester.tap(find.text(title)); await tester.pumpAndSettle();
      expect(find.textContaining(origin == 'groups' ? 'Open the Groups tab' : 'Open Schedule and tap'), findsNothing);
      await tester.enterText(find.byType(TextField), 'crea gro'); await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('How do I create a group?'), origin == 'groups' ? findsOneWidget : findsNothing);
      await tester.pump(const Duration(milliseconds: 100)); await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 100)); }); await tester.pumpAndSettle();
      expect(find.text('How do I create a group?'), findsOneWidget); expect(find.text('About ParchApp'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink()); router.dispose();
    });
  }
}
