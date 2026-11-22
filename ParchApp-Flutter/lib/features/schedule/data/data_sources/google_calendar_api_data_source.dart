import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:googleapis/calendar/v3.dart' as google_calendar;
import 'package:http/http.dart' as http;

import '../models/google_calendar_event_model.dart';
import 'google_calendar_auth_data_source.dart';
import 'google_calendar_data_source.dart';

class GoogleCalendarApiDataSource implements GoogleCalendarDataSource {
  final GoogleCalendarAuthDataSource authDataSource;
  final Future<http.Client> Function()? createAuthorizedClient;
  final DateTime Function()? now;

  const GoogleCalendarApiDataSource({
    required this.authDataSource,
    this.createAuthorizedClient,
    this.now,
  });

  @override
  Future<List<GoogleCalendarEventModel>> importEvents() async {
    final client = await _authorizedClient();

    try {
      final calendarApi = google_calendar.CalendarApi(client);

      final importedEvents = <GoogleCalendarEventModel>[];

      String? pageToken;

      final today = (now ?? DateTime.now)().toUtc().subtract(
            const Duration(hours: 5),
          );
      final startOfToday = DateTime.utc(today.year, today.month, today.day, 5);
      // Keep history available when navigating to previous schedule days.
      final timeMin = DateTime.utc(today.year - 1, today.month, today.day, 5);
      final timeMax = startOfToday.add(const Duration(days: 56));

      do {
        final response = await calendarApi.events.list(
          'primary',
          timeMin: timeMin,
          timeMax: timeMax,
          singleEvents: true,
          orderBy: 'startTime',
          showDeleted: false,
          maxResults: 2500,
          pageToken: pageToken,
          timeZone: 'America/Bogota',
        );

        final events = response.items ?? const <google_calendar.Event>[];

        debugPrint(
          'GOOGLE API REAL: ${events.length} events received',
        );

        for (final event in events) {
          final converted = _toModel(event);

          if (converted != null) {
            importedEvents.add(
              converted,
            );
          }
        }

        pageToken = response.nextPageToken;
      } while (pageToken != null && pageToken.isNotEmpty);

      importedEvents.sort(
        (first, second) => first.start.compareTo(
          second.start,
        ),
      );

      debugPrint(
        'GOOGLE API REAL TOTAL: '
        '${importedEvents.length} valid events imported',
      );

      return importedEvents;
    } finally {
      client.close();
    }
  }

  Future<http.Client> _authorizedClient() async {
    final factory = createAuthorizedClient;
    if (factory != null) return factory();
    final authorization = await authDataSource.getCalendarAuthorization();
    return authorization.authClient(
      scopes: GoogleCalendarAuthDataSource.calendarScopes,
    );
  }

  GoogleCalendarEventModel? _toModel(
    google_calendar.Event event,
  ) {
    if (event.status == 'cancelled' ||
        event.transparency == 'transparent' ||
        (event.attendees ?? const <google_calendar.EventAttendee>[]).any(
            (attendee) =>
                attendee.self == true &&
                attendee.responseStatus == 'declined')) {
      return null;
    }

    final id = event.id;

    if (id == null || id.trim().isEmpty) {
      return null;
    }

    // Date-only events occupy the full day in the schedule's Bogota timezone.
    final start = _eventTime(event.start);
    final end = _eventTime(event.end);

    if (start == null || end == null) {
      return null;
    }

    if (!end.isAfter(start)) {
      return null;
    }

    final rawTitle = event.summary?.trim();

    final title =
        rawTitle == null || rawTitle.isEmpty ? 'Untitled event' : rawTitle;

    return GoogleCalendarEventModel(
      id: id,
      title: title,
      description: _cleanOptionalText(
        event.description,
      ),
      location: _cleanOptionalText(
        event.location,
      ),
      start: start.toLocal(),
      end: end.toLocal(),
    );
  }

  DateTime? _eventTime(google_calendar.EventDateTime? value) {
    if (value?.dateTime != null) return value!.dateTime;
    final date = value?.date;
    return date == null
        ? null
        : DateTime.utc(date.year, date.month, date.day, 5);
  }

  String? _cleanOptionalText(
    String? value,
  ) {
    final cleaned = value?.trim();

    if (cleaned == null || cleaned.isEmpty) {
      return null;
    }

    return cleaned;
  }
}
