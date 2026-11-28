import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parchapp/features/schedule/data/repositories/schedule_repository_impl.dart';
import 'package:parchapp/features/schedule/domain/entities/schedule_block.dart';
import 'package:parchapp/features/schedule/domain/entities/schedule_friend.dart';
import 'package:parchapp/features/schedule/domain/services/availability_service.dart';
import 'package:parchapp/features/schedule/domain/use_cases/authorize_google_calendar.dart';
import 'package:parchapp/features/schedule/domain/use_cases/import_google_calendar.dart';
import 'package:parchapp/features/schedule/domain/use_cases/manage_schedule.dart';
import 'package:parchapp/features/schedule/presentation/view_models/schedule_view_model.dart';
import 'package:parchapp/features/schedule/presentation/views/schedule_view.dart';
import 'planning_handoff_test.dart' show Calendar;

class LayoutSchedule extends MockScheduleRepository {
  @override
  Future<List<ScheduleFriend>> getFriends() async => const [
        ScheduleFriend(
            id: 'friend', name: 'Camila', fullName: 'Camila', initials: 'C')
      ];
  @override
  Future<List<ScheduleBlock>> getMySchedule({required DateTime day}) async => [
        ScheduleBlock(
            id: 'personal',
            start: DateTime(day.year, day.month, day.day, 8, 30),
            end: DateTime(day.year, day.month, day.day, 9, 30),
            type: ScheduleBlockType.personalEvent,
            title: 'Personal block',
            subtitle: 'Class',
            location: 'Campus')
      ];
  @override
  Future<List<ScheduleBlock>> getFriendsBusyBlocks(
          {required DateTime day, required List<String> friendIds}) async =>
      [
        ScheduleBlock(
            id: 'busy',
            ownerId: 'friend',
            start: DateTime(day.year, day.month, day.day, 9, 30),
            end: DateTime(day.year, day.month, day.day, 10, 30),
            type: ScheduleBlockType.friendBusy)
      ];
}

void main() {
  for (final width in [320.0, 390.0, 430.0]) {
    testWidgets('timeline preserves lane geometry at $width px',
        (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final schedule = LayoutSchedule(), calendar = Calendar();
      final model = ScheduleViewModel(
          ManageSchedule(schedule, const AvailabilityService()),
          ImportGoogleCalendar(calendar, schedule),
          authorizeGoogleCalendar: AuthorizeGoogleCalendar(calendar),
          initialDay: DateTime(2030, 10, 1));
      await tester
          .pumpWidget(MaterialApp(home: ScheduleView(viewModel: model)));
      await tester.pumpAndSettle();
      final initialError = tester.takeException();
      if (width == 320) {
        // This same 25 px overflow occurs with the unmodified Schedule screen.
        expect(initialError.toString(), contains('overflowed by 25 pixels'));
      } else {
        expect(initialError, isNull);
      }
      expect(find.text('Personal block'), findsOneWidget);
      expect(find.text('Camila'), findsWidgets);
      final personal = tester.getTopLeft(find.text('Personal block'));
      final friend = tester.getTopLeft(find.text('Camila').last);
      expect(personal.dx, greaterThanOrEqualTo(62));
      expect(friend.dx, greaterThan(personal.dx));
      expect(friend.dy, greaterThan(personal.dy));
      expect(model.value.commonSlots, isNotEmpty);
      model.selectSlot(model.value.commonSlots.first);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    });
  }
}
