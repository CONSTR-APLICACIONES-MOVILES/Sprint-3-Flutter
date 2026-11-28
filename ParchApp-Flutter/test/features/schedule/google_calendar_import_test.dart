import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parchapp/features/schedule/data/adapters/google_calendar_adapter.dart';
import 'package:parchapp/features/schedule/data/data_sources/google_calendar_api_data_source.dart';
import 'package:parchapp/features/schedule/data/data_sources/google_calendar_auth_data_source.dart';

void main() {
  test('imports own details across pages and excludes non-busy events',
      () async {
    final requests = <http.Request>[];
    Map<String, dynamic> event(String id, [String? transparency]) => {
          'id': id,
          'summary': 'Dentist',
          'description': 'Annual checkup',
          'location': 'Clinic',
          'start': {'dateTime': '2030-10-13T10:00:00-05:00'},
          'end': {'dateTime': '2030-10-13T11:00:00-05:00'},
          if (transparency != null) 'transparency': transparency,
        };
    final source = GoogleCalendarApiDataSource(
      authDataSource: GoogleCalendarAuthDataSource(),
      now: () => DateTime.utc(2030, 11, 13, 16),
      createAuthorizedClient: () async => MockClient((request) async {
        requests.add(request);
        return http.Response(
            jsonEncode(requests.length == 1
                ? {
                    'items': [event('own'), event('free', 'transparent')],
                    'nextPageToken': 'page2',
                  }
                : {
                    'items': [
                      {
                        ...event('declined'),
                        'attendees': [
                          {'self': true, 'responseStatus': 'declined'}
                        ],
                      },
                      {
                        'id': 'all-day',
                        'summary': 'Holiday',
                        'start': {'date': '2030-11-14'},
                        'end': {'date': '2030-11-15'},
                      },
                    ],
                  }),
            200,
            headers: {'content-type': 'application/json'});
      }),
    );

    final events = await source.importEvents();
    expect(events.map((event) => event.id), ['own', 'all-day']);
    final block = const GoogleCalendarAdapter().toScheduleBlock(events.first);
    expect(block.title, 'Dentist');
    expect(block.subtitle, 'Annual checkup');
    expect(block.location, 'Clinic');
    expect(block.start.toUtc(), DateTime.utc(2030, 10, 13, 15));
    expect(events.last.start.toUtc(), DateTime.utc(2030, 11, 14, 5));
    expect(events.last.end.toUtc(), DateTime.utc(2030, 11, 15, 5));
    expect(requests.first.url.path, endsWith('/calendars/primary/events'));
    expect(requests.first.url.queryParameters['timeMin'],
        '2029-11-13T05:00:00.000Z');
    expect(
        requests.first.url.queryParameters['timeMax'],
        DateTime.utc(2030, 11, 13, 5)
            .add(const Duration(days: 56))
            .toIso8601String());
    expect(requests.last.url.queryParameters['pageToken'], 'page2');
    expect(GoogleCalendarAuthDataSource.calendarScopes,
        contains('https://www.googleapis.com/auth/calendar.events.readonly'));
  });
}
