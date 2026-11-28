import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/parch_app_bar.dart';
import '../../../../shared/widgets/parch_navigation_bar.dart';
import '../../domain/entities/andes_event.dart';
import '../view_models/andes_events_view_model.dart';

class AndesEventsView extends StatefulWidget {
  final AndesEventsViewModel viewModel;
  const AndesEventsView({super.key, required this.viewModel});
  @override
  State<AndesEventsView> createState() => _AndesEventsViewState();
}

class _AndesEventsViewState extends State<AndesEventsView> with WidgetsBindingObserver {
  AndesEventsViewModel get vm => widget.viewModel;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    vm.load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    vm.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) vm.onResume();
  }

  Widget _statusBanner() {
    if (vm.serverConfirmed && vm.networkAvailable != false) return const SizedBox.shrink();
    if (vm.loading && vm.error == null && vm.networkAvailable != false && !vm.reconnecting) return const SizedBox.shrink();
    final offline = vm.networkAvailable == false;
    final reconnecting = vm.reconnecting && vm.refreshing;
    final title = reconnecting ? 'Connection restored' : offline ? "You're offline" : (vm.error?.contains('Access denied') == true || vm.error?.contains('sign in') == true) ? 'Access to events unavailable' : "Couldn't update events";
    final description = reconnecting ? 'Updating the full event catalog…' : offline ? 'Showing saved event information for the next 15 days. Some details may have changed.' : (vm.error?.contains('Access denied') == true || vm.error?.contains('sign in') == true) ? vm.error! : 'Showing previously saved information. Try again when the service is available.';
    return Container(margin: const EdgeInsets.fromLTRB(16, 8, 16, 0), padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: AppColors.blueTint, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.outlineSoft)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(offline ? Icons.wifi_off : Icons.cloud_off_outlined, color: AppColors.primary, size: 20), const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontWeight: FontWeight.bold)), Text(description),
          if (vm.lastSync != null) Text('Last synced: ${MaterialLocalizations.of(context).formatMediumDate(vm.lastSync!.toLocal())} ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(vm.lastSync!.toLocal()))}', style: const TextStyle(color: AppColors.textSecondary)),
          if (!offline && !reconnecting) TextButton(onPressed: vm.refresh, child: const Text('Retry')),
        ]))]));
  }

  Widget _failedOperations() {
    final failures = vm.failedOperations;
    if (failures.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: TextButton.icon(
        icon: const Icon(Icons.error_outline),
        label: Text("Couldn't add ${failures.length} event${failures.length == 1 ? '' : 's'} · View"),
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          builder: (context) => SafeArea(child: ListView(
            shrinkWrap: true,
            children: failures.map((op) => ListTile(
              title: Text(op.event.title),
              subtitle: Text(op.error ?? "Couldn't add event."),
            )).toList(),
          )),
        ),
      ),
    );
  }

  Future<void> add(AndesEvent e) async {
    final error = await vm.add(e);
    if (mounted && error != null)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(error),
          action: SnackBarAction(label: 'Retry', onPressed: () => add(e))));
  }

  Future<void> remove(AndesEvent event) async {
    final error = await vm.remove(event);
    if (mounted && error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(error),
        action: SnackBarAction(label: 'Retry', onPressed: () => remove(event)),
      ));
    }
  }

  Future<void> toggleSaved(AndesEvent e) async {
    final error = await vm.toggleSaved(e);
    if (mounted && error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Widget bookmark(AndesEvent e) => IconButton(
        tooltip: vm.isSaved(e.id) ? 'Remove from Saved' : 'Save event',
        onPressed: vm.saving.contains(e.id) || vm.savedLoading || (vm.savedError != null && vm.savedError != 'Sign in to access saved events.')
            ? null
            : () => toggleSaved(e),
        color: AppColors.primary,
        icon: Icon(vm.isSaved(e.id) ? Icons.bookmark : Icons.bookmark_border),
      );

  Widget button(AndesEvent e) {
    final op = vm.operation(e.id);
    final added = vm.added.contains(e.id) || op?.status == 'confirmed';
    final busy = vm.adding.contains(e.id);
    if (op?.status == 'pending' || op?.status == 'syncing') {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        OutlinedButton(onPressed: null, child: Text(op!.status == 'syncing' ? 'Syncing…' : 'Pending sync')),
        const Text('This event will be added when your connection is restored.', style: TextStyle(color: AppColors.textSecondary)),
      ]);
    }
    if (op?.status == 'failed') {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        const Text("Couldn't add event"),
        Text(op!.error ?? 'Please try again.', style: const TextStyle(color: AppColors.textSecondary)),
        if (!(op.error?.contains('already ended') ?? false) && !(op.error?.contains('no longer available') ?? false) && (!(op.error?.contains('changed') ?? false) || vm.serverConfirmed))
        TextButton(onPressed: () async {
          final error = await vm.retryOperation(e);
          if (mounted && error != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
        }, child: const Text('Retry')),
      ]);
    }
    return FilledButton(
      onPressed: busy ? null : () => added ? remove(e) : add(e),
      child: Text(busy ? (added ? 'Removing…' : 'Adding…') : added ? 'Remove from Schedule' : 'Add to Schedule'),
    );
  }
  String date(AndesEvent e) =>
      MaterialLocalizations.of(context).formatMediumDate(e.start.toLocal());
  String times(AndesEvent e) =>
      '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(e.start.toLocal()))} – ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(e.end.toLocal()))}';
  String category(AndesEvent e) =>
      '${e.category[0].toUpperCase()}${e.category.substring(1)}';
  void details(AndesEvent e) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => AnimatedBuilder(
          animation: vm,
          builder: (context, _) => SafeArea(
              child: SingleChildScrollView(
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(category(e),
                                style:
                                    const TextStyle(color: AppColors.primary)),
                            const SizedBox(height: 8),
                            Text(e.title,
                                style:
                                    Theme.of(context).textTheme.headlineSmall),
                            const SizedBox(height: 16),
                            if (!vm.serverConfirmed || vm.showSaved) const Text('Saved event information may have changed.', style: TextStyle(color: AppColors.textSecondary)),
                            Text(e.description),
                            const SizedBox(height: 16),
                            Text(date(e)),
                            Text(times(e)),
                            Text(e.location),
                            const SizedBox(height: 20),
                            button(e),
                          ]))))));
  @override
  Widget build(BuildContext context) => PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          if (context.canPop()) {
            context.pop(vm.changed);
          } else {
            context.go('/schedule');
          }
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: ParchAppBar(title: 'Andes Events', showBack: true),
        bottomNavigationBar: const ParchNavigationBar(selectedIndex: 2),
        body: AnimatedBuilder(
            animation: vm,
            builder: (context, _) =>
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _statusBanner(),
                  _failedOperations(),
                  const Padding(
                      padding: EdgeInsets.fromLTRB(16, 16, 16, 12),
                      child: Text(
                          'Discover university events and add them to your Schedule.',
                          style: TextStyle(color: AppColors.textSecondary))),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(children: [
                      Expanded(
                          child: ChoiceChip(
                              label: const Text('All Events'),
                              selected: !vm.showSaved,
                              selectedColor: AppColors.blueTint,
                              onSelected: (_) => vm.selectSaved(false))),
                      const SizedBox(width: 8),
                      Expanded(
                          child: ChoiceChip(
                              label: Text('Saved (${vm.savedEvents.length})'),
                              selected: vm.showSaved,
                              selectedColor: AppColors.blueTint,
                              onSelected: (_) => vm.selectSaved(true))),
                    ]),
                  ),
                  Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                          onChanged: vm.search,
                          decoration: const InputDecoration(
                              prefixIcon: Icon(Icons.search),
                              hintText: 'Search university events',
                              border: OutlineInputBorder()))),
                  SizedBox(
                      height: 64,
                      child: ListView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          children: [
                            'all',
                            'academic',
                            'cultural',
                            'sports',
                            'other'
                          ]
                              .map((c) => Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                      label: Text(
                                          '${c[0].toUpperCase()}${c.substring(1)}'),
                                      selected: vm.category == c,
                                      selectedColor: AppColors.blueTint,
                                      onSelected: (_) => vm.filter(c))))
                              .toList())),
                  if (!vm.showSaved) Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Text(vm.serverConfirmed ? 'All upcoming events' : vm.reconnecting ? 'Cached events · Updating' : 'Cached events · Next 15 days', style: const TextStyle(fontWeight: FontWeight.bold))),
                  Expanded(child: _content()),
                ])),
      ));
  Widget _content() {
    if (vm.showSaved) {
      if (vm.savedLoading)
        return const Center(child: CircularProgressIndicator());
      if (vm.savedError != null)
        return _message(vm.savedError!, retrySaved: true);
      if (vm.savedEvents.isEmpty)
        return _message(
            'No saved events yet. Bookmark an event to keep it on this device.');
    }
    if (!vm.showSaved && vm.loading)
      return const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(),
        SizedBox(height: 12),
        Text('Loading events…')
      ]));

    if (!vm.showSaved && vm.events.isEmpty)
      return _message(
          !vm.serverConfirmed ? 'No offline events available\nConnect to the internet to load university events.' : vm.invalidCount > 0
              ? 'Invalid event data. No valid upcoming events are available.'
              : 'No published upcoming events.',
          retry: vm.serverConfirmed);
    if (vm.filtered.isEmpty) return _message('No matching search results.');
    return ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          if (vm.showSaved)
            const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                    'Saved on this device. Details may not be up to date.',
                    style: TextStyle(color: AppColors.textSecondary))),
          if (!vm.showSaved && vm.invalidCount > 0)
            const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                    'Some events have invalid data and could not be displayed.',
                    style: TextStyle(color: AppColors.textSecondary))),
          ...vm.filtered.map((e) => Card(
              color: AppColors.surface,
              child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => details(e),
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Expanded(
                                  child: Text(category(e),
                                      style: const TextStyle(
                                          color: AppColors.primary,
                                          fontWeight: FontWeight.bold))),
                              bookmark(e)
                            ]),
                            const SizedBox(height: 6),
                            Text(e.title,
                                style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.textPrimary)),
                            const SizedBox(height: 8),
                            Text('${date(e)} • ${times(e)}'),
                            Text(e.location),
                            const SizedBox(height: 8),
                            Text(e.description,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: AppColors.textSecondary)),
                            const SizedBox(height: 8),
                            button(e),
                          ])))))
        ]);
  }

  Widget _message(String text, {bool retry = false, bool retrySaved = false}) =>
      Center(
          child: SingleChildScrollView(child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(text, textAlign: TextAlign.center),
                if (retry)
                  TextButton(onPressed: vm.load, child: const Text('Retry')),
                if (retrySaved &&
                    vm.savedError != 'Sign in to access saved events.')
                  TextButton(
                      onPressed: vm.refreshSaved, child: const Text('Retry'))
              ]))));
}
