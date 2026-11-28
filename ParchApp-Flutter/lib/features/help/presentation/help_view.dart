import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/router/app_routes.dart';
import '../domain/help_faq.dart';
import 'help_view_model.dart';

const _background = Color(0xFFF8FAFE), _blue = Color(0xFF003D9B), _dark = Color(0xFF111827), _slate = Color(0xFF64748B), _lightBlue = Color(0xFFEEF4FF);
class HelpView extends StatefulWidget {
  final String origin;
  final HelpViewModel viewModel;
  const HelpView({super.key, required this.origin, required this.viewModel});
  @override State<HelpView> createState() => _HelpViewState();
}
class _HelpViewState extends State<HelpView> with WidgetsBindingObserver {
  final expanded = <String>{};
  HelpViewModel get vm => widget.viewModel;
  @override void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); vm.load(); }
  @override void dispose() { WidgetsBinding.instance.removeObserver(this); vm.dispose(); super.dispose(); }
  @override void didChangeAppLifecycleState(AppLifecycleState state) { if (state == AppLifecycleState.resumed) vm.refresh(); }
  String _date(DateTime date) { const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec']; return '${months[date.month - 1]} ${date.day}, ${date.year}'; }
  Widget _question(HelpFaq faq) => Container(
    margin: const EdgeInsets.only(top: 8), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: const Color(0xFFE2E8F0))),
    child: Material(color: Colors.transparent, child: InkWell(borderRadius: BorderRadius.circular(24), onTap: () => setState(() { if (!expanded.add(faq.id)) expanded.remove(faq.id); }), child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Expanded(child: Text(faq.question, style: const TextStyle(color: _dark, fontSize: 14, fontWeight: FontWeight.bold))), const SizedBox(width: 8), AnimatedRotation(turns: expanded.contains(faq.id) ? .25 : 0, duration: const Duration(milliseconds: 120), child: const Icon(Icons.chevron_right, size: 22, color: _dark))]),
      if (expanded.contains(faq.id)) Padding(padding: const EdgeInsets.only(top: 8), child: Text(faq.answer, style: const TextStyle(color: _slate, fontSize: 13))),
    ])))));
  @override Widget build(BuildContext context) => Scaffold(
    backgroundColor: _background,
    body: SafeArea(bottom: false, child: AnimatedBuilder(animation: vm, builder: (context, _) {
      final searching = vm.query.trim().isNotEmpty;
      final sections = helpSectionOrder(vm.rows, widget.origin);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(height: 58, color: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
          Material(color: _lightBlue, borderRadius: BorderRadius.circular(14), child: InkWell(borderRadius: BorderRadius.circular(14), onTap: () => context.canPop() ? context.pop() : context.go(AppRoutes.home), child: const SizedBox(width: 38, height: 38, child: Icon(Icons.arrow_back, color: _blue, size: 20)))),
          const SizedBox(width: 10), const Text('Help', style: TextStyle(color: _dark, fontSize: 18, fontWeight: FontWeight.bold)),
        ])),
        if (vm.offline) Container(width: double.infinity, constraints: const BoxConstraints(minHeight: 44), color: const Color(0xFFFEF3C7), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), child: const Row(children: [Text('⚠', style: TextStyle(color: Color(0xFFD97706), fontSize: 16, fontWeight: FontWeight.bold)), SizedBox(width: 10), Expanded(child: Text("You're offline. Saved groups and plans are shown; some actions need an internet connection.", style: TextStyle(color: _dark, fontSize: 12)))])),
        Container(height: 48, margin: const EdgeInsets.fromLTRB(14, 12, 14, 0), decoration: BoxDecoration(color: _lightBlue, borderRadius: BorderRadius.circular(18)), child: TextField(onChanged: vm.search, maxLines: 1, textInputAction: TextInputAction.search, style: const TextStyle(color: _dark, fontSize: 14), decoration: const InputDecoration(border: InputBorder.none, prefixIcon: Icon(Icons.search, color: _slate, size: 22), hintText: 'Search help', hintStyle: TextStyle(color: _slate, fontSize: 14), contentPadding: EdgeInsets.symmetric(vertical: 14)))),
        Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: Text(vm.lastSync == null ? 'Built-in help' : 'Updated on ${_date(vm.lastSync!.toLocal())}', style: const TextStyle(color: _slate, fontSize: 11))),
        if (vm.loading) const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (vm.error != null) Expanded(child: Center(child: Text(vm.error!)))
        else if (searching && vm.rows.isEmpty) const Expanded(child: Padding(padding: EdgeInsets.only(top: 24), child: Align(alignment: Alignment.topCenter, child: Text('No questions match your search.', style: TextStyle(color: _slate, fontSize: 13)))))
        else Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 16), children: [
          if (searching) ...vm.rows.map(_question) else ...[
            for (final section in sections) ...[
              Padding(padding: const EdgeInsets.only(top: 16), child: Text('${helpTitles[section] ?? section}${section == widget.origin ? ' (this screen)' : ''}', style: const TextStyle(color: _dark, fontSize: 16, fontWeight: FontWeight.bold))),
              ...vm.rows.where((f) => f.screen == section).map(_question),
            ],
            const Padding(padding: EdgeInsets.only(top: 24), child: Text('About ParchApp', style: TextStyle(color: _dark, fontSize: 16, fontWeight: FontWeight.bold))),
            const Padding(padding: EdgeInsets.only(top: 4), child: Text('ParchApp 1.0. Help for your groups, schedule and plans, also without internet.', style: TextStyle(color: _slate, fontSize: 12))),
          ],
        ])),
      ]);
    })));
}
