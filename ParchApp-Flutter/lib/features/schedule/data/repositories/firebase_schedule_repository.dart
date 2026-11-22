import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../domain/entities/user_location.dart';
import '../../domain/entities/schedule_block.dart';
import '../../domain/entities/schedule_friend.dart';
import '../../domain/repositories/schedule_repository.dart';

class FirebaseScheduleRepository implements ScheduleRepository {
  final FirebaseFirestore firestore;
  final FirebaseAuth auth;

  const FirebaseScheduleRepository({
    required this.firestore,
    required this.auth,
  });

  // CURRENT USER.

  User get _currentUser {
    final user = auth.currentUser;

    if (user == null) {
      throw StateError(
        'No authenticated Firebase user.',
      );
    }

    return user;
  }

  String get _uid => _currentUser.uid;

  DocumentReference<Map<String, dynamic>> get _scheduleDocument => firestore
      .collection(
        'schedules',
      )
      .doc(
        _uid,
      );

  CollectionReference<Map<String, dynamic>> get _slotsCollection =>
      _scheduleDocument.collection(
        'slots',
      );

  DocumentReference<Map<String, dynamic>> get _availabilityDocument => firestore
      .collection(
        'availability',
      )
      .doc(
        _uid,
      );

  CollectionReference<Map<String, dynamic>> get _availabilitySlotsCollection =>
      _availabilityDocument.collection(
        'slots',
      );

  // FRIENDS

  @override
  Future<List<ScheduleFriend>> getFriends() async {
    final currentUid = _uid;

    debugPrint(
      'FRIENDS -> '
      'Loading accepted friends for $currentUid',
    );

    // -----------------------------------------------------------------
    // 1. Read accepted friendships.
    // -----------------------------------------------------------------

    final friendshipSnapshot = await firestore
        .collection(
          'users',
        )
        .doc(
          currentUid,
        )
        .collection(
          'friends',
        )
        .where(
          'status',
          isEqualTo: 'accepted',
        )
        .get();

    debugPrint(
      'FRIENDS -> '
      '${friendshipSnapshot.docs.length} '
      'accepted relationships found',
    );

    if (friendshipSnapshot.docs.isEmpty) {
      return const [];
    }

    final friends = <ScheduleFriend>[];

    // -----------------------------------------------------------------
    // 2. Load each friend's public profile.

    for (final friendshipDocument in friendshipSnapshot.docs) {
      final relationshipData = friendshipDocument.data();

      final rawFriendId = relationshipData['friendId'];

      final friendId = rawFriendId is String && rawFriendId.trim().isNotEmpty
          ? rawFriendId.trim()
          : friendshipDocument.id;

      debugPrint(
        'FRIENDS -> '
        'Reading users/$friendId',
      );

      final friendSnapshot = await firestore
          .collection(
            'users',
          )
          .doc(
            friendId,
          )
          .get();

      if (!friendSnapshot.exists) {
        debugPrint(
          'FRIENDS -> '
          'users/$friendId does not exist',
        );

        continue;
      }

      final data = friendSnapshot.data();

      if (data == null) {
        continue;
      }

      final rawName = data['name'];

      final rawFullName = data['fullName'];

      final rawInitials = data['initials'];

      final name = rawName is String ? rawName.trim() : '';

      final fullName = rawFullName is String ? rawFullName.trim() : '';

      final initials = rawInitials is String ? rawInitials.trim() : '';

      final resolvedName = name.isNotEmpty
          ? name
          : fullName.isNotEmpty
              ? fullName
                  .split(
                    RegExp(
                      r'\s+',
                    ),
                  )
                  .first
              : friendId;

      final resolvedFullName = fullName.isNotEmpty ? fullName : resolvedName;

      final resolvedInitials = initials.isNotEmpty
          ? initials
          : _initials(
              resolvedFullName,
            );

      friends.add(
        ScheduleFriend(
          id: friendId,
          name: resolvedName,
          fullName: resolvedFullName,
          initials: resolvedInitials,
        ),
      );
    }

    // -----------------------------------------------------------------
    // 3. Sort alphabetically.
    // -----------------------------------------------------------------

    friends.sort(
      (a, b) => a.fullName.toLowerCase().compareTo(
            b.fullName.toLowerCase(),
          ),
    );

    debugPrint(
      'FRIENDS -> '
      '${friends.length} friend profiles loaded',
    );

    for (final friend in friends) {
      debugPrint(
        'FRIENDS -> '
        '${friend.id} | '
        '${friend.fullName}',
      );
    }

    return friends;
  }

  // ===================================================================
  // FRIEND LOCATIONS
  // ===================================================================

  @override
  Future<Map<String, UserLocation>> getFriendLocations({
    required List<String> friendIds,
  }) async {
    if (friendIds.isEmpty) {
      debugPrint(
        'FRIEND LOCATIONS -> '
        'No friend IDs received',
      );

      return const {};
    }

    debugPrint(
      'FRIEND LOCATIONS -> '
      'Loading ${friendIds.length} locations',
    );

    final result = <String, UserLocation>{};

    for (final friendId in friendIds) {
      debugPrint(
        'FRIEND LOCATIONS -> '
        'Reading locations/$friendId',
      );

      final snapshot = await firestore
          .collection(
            'locations',
          )
          .doc(
            friendId,
          )
          .get();

      if (!snapshot.exists) {
        debugPrint(
          'FRIEND LOCATIONS -> '
          'No location document for $friendId',
        );

        continue;
      }

      final data = snapshot.data();

      if (data == null) {
        continue;
      }

      final rawLocation = data['location'];

      if (rawLocation is! GeoPoint) {
        debugPrint(
          'FRIEND LOCATIONS -> '
          '$friendId does not contain '
          'a valid GeoPoint',
        );

        continue;
      }

      final location = UserLocation(
        latitude: rawLocation.latitude,
        longitude: rawLocation.longitude,
      );

      result[friendId] = location;

      debugPrint(
        'FRIEND LOCATIONS -> '
        '$friendId = '
        '${location.latitude}, '
        '${location.longitude}',
      );
    }

    debugPrint(
      'FRIEND LOCATIONS -> '
      '${result.length} valid locations loaded',
    );

    return result;
  }

  // ===================================================================
  // MY PRIVATE SCHEDULE
  // ===================================================================

  @override
  Future<List<ScheduleBlock>> getMySchedule({
    required DateTime day,
  }) async {
    final dayKey = _dayKey(
      day,
    );

    debugPrint(
      'MY SCHEDULE -> '
      'Reading schedules/$_uid/slots '
      'for $dayKey',
    );

    final snapshot = await _slotsCollection
        .where(
          'dayKey',
          isEqualTo: dayKey,
        )
        .get();

    debugPrint(
      'MY SCHEDULE -> '
      '${snapshot.docs.length} slots found',
    );

    final blocks = <ScheduleBlock>[];

    for (final document in snapshot.docs) {
      final data = document.data();

      final rawStart = data['start'];

      final rawEnd = data['end'];

      if (rawStart is! Timestamp || rawEnd is! Timestamp) {
        debugPrint(
          'MY SCHEDULE -> '
          'Skipping ${document.id}: '
          'invalid timestamps',
        );

        continue;
      }

      final start = rawStart.toDate().toLocal();

      final end = rawEnd.toDate().toLocal();

      if (!end.isAfter(
        start,
      )) {
        debugPrint(
          'MY SCHEDULE -> '
          'Skipping ${document.id}: '
          'end <= start',
        );

        continue;
      }

      final rawTitle = data['title'];

      final rawDescription = data['description'];

      final rawLocation = data['location'];

      blocks.add(
        ScheduleBlock(
          id: document.id,
          start: start,
          end: end,
          type: ScheduleBlockType.personalEvent,
          title: rawTitle is String ? rawTitle : null,
          subtitle: rawDescription is String ? rawDescription : null,
          location: rawLocation is String ? rawLocation : null,
          ownerId: _uid,
        ),
      );
    }

    blocks.sort(
      (a, b) => a.start.compareTo(
        b.start,
      ),
    );

    return blocks;
  }

  // ===================================================================
  // FRIEND BUSY BLOCKS
  // ===================================================================

  @override
  Future<List<ScheduleBlock>> getFriendsBusyBlocks({
    required DateTime day,
    required List<String> friendIds,
  }) async {
    if (friendIds.isEmpty) {
      debugPrint(
        'FRIEND BUSY -> '
        'No friends selected',
      );

      return const [];
    }

    final dayKey = _dayKey(
      day,
    );

    debugPrint(
      'FRIEND BUSY -> '
      'Loading $dayKey '
      'for friends=$friendIds',
    );

    // ---------------------------------------------------------------
    // CONCURRENCY STRATEGY
    //
    // OLD FLOW:
    //
    // Friend 1
    //    ↓ await
    // Friend 2
    //    ↓ await
    // Friend 3
    //
    // NEW FLOW:
    //
    //        ┌── Friend 1
    // start ─┼── Friend 2
    //        └── Friend 3
    //
    // Every Firestore query starts before we await the group.
    // ---------------------------------------------------------------

    final stopwatch = Stopwatch()..start();

    final requests = friendIds
        .map(
          (friendId) => _loadFriendBusyBlocks(
            friendId: friendId,
            dayKey: dayKey,
          ),
        )
        .toList();

    debugPrint(
      'FRIEND BUSY CONCURRENCY -> '
      '${requests.length} friend queries started',
    );

    // ---------------------------------------------------------------
    // Wait for ALL friend queries.
    // ---------------------------------------------------------------

    final results = await Future.wait<List<ScheduleBlock>>(
      requests,
    );

    // ---------------------------------------------------------------
    // Flatten:
    //
    // [
    //   [friend1 blocks],
    //   [friend2 blocks],
    //   [friend3 blocks]
    // ]
    //
    // becomes:
    //
    // [
    //   block1,
    //   block2,
    //   block3,
    //   ...
    // ]
    // ---------------------------------------------------------------

    final blocks = results
        .expand(
          (friendBlocks) => friendBlocks,
        )
        .toList();

    // ---------------------------------------------------------------
    // Maintain deterministic ordering for the UI.
    // ---------------------------------------------------------------

    blocks.sort(
      (a, b) {
        final startComparison = a.start.compareTo(
          b.start,
        );

        if (startComparison != 0) {
          return startComparison;
        }

        return (a.ownerId ?? '').compareTo(
          b.ownerId ?? '',
        );
      },
    );

    stopwatch.stop();

    debugPrint(
      'FRIEND BUSY CONCURRENCY -> '
      '${friendIds.length} friends loaded in '
      '${stopwatch.elapsedMilliseconds} ms',
    );

    debugPrint(
      'FRIEND BUSY -> '
      '${blocks.length} total busy blocks loaded',
    );

    return blocks;
  }

  // ===================================================================
  // LOAD ONE FRIEND'S BUSY BLOCKS
  // ===================================================================

  Future<List<ScheduleBlock>> _loadFriendBusyBlocks({
    required String friendId,
    required String dayKey,
  }) async {
    debugPrint(
      'FRIEND BUSY -> '
      'Starting query for $friendId',
    );

    // ---------------------------------------------------------------
    // PRIVACY
    //
    // We NEVER read:
    //
    // schedules/{friendId}/slots
    //
    // because it contains private event information:
    //
    // - title
    // - description
    // - location
    //
    // We only read:
    //
    // availability/{friendId}/slots
    //
    // containing:
    //
    // - start
    // - end
    // - dayKey
    // ---------------------------------------------------------------

    final snapshot = await firestore
        .collection(
          'availability',
        )
        .doc(
          friendId,
        )
        .collection(
          'slots',
        )
        .where(
          'dayKey',
          isEqualTo: dayKey,
        )
        .get();

    debugPrint(
      'FRIEND BUSY -> '
      '$friendId finished: '
      '${snapshot.docs.length} busy slots',
    );

    final blocks = <ScheduleBlock>[];

    for (final document in snapshot.docs) {
      final data = document.data();

      final rawStart = data['start'];

      final rawEnd = data['end'];

      if (rawStart is! Timestamp || rawEnd is! Timestamp) {
        debugPrint(
          'FRIEND BUSY -> '
          'Skipping ${document.id}: '
          'invalid timestamps',
        );

        continue;
      }

      final start = rawStart.toDate().toLocal();

      final end = rawEnd.toDate().toLocal();

      if (!end.isAfter(
        start,
      )) {
        debugPrint(
          'FRIEND BUSY -> '
          'Skipping ${document.id}: '
          'end <= start',
        );

        continue;
      }

      blocks.add(
        ScheduleBlock(
          id: '$friendId-${document.id}',

          start: start,

          end: end,

          type: ScheduleBlockType.friendBusy,

          // ---------------------------------------------------------
          // Privacy-safe representation.
          // ---------------------------------------------------------

          title: 'Busy',

          subtitle: null,

          location: null,

          ownerId: friendId,
        ),
      );
    }

    return blocks;
  }

  // ===================================================================
  // GOOGLE CALENDAR SYNCHRONIZATION
  // ===================================================================

  @override
  Future<void> replaceImportedCalendarBlocks(
    List<ScheduleBlock> blocks,
  ) async {
    final uid = _uid;

    final now = Timestamp.now();

    debugPrint(
      'FIRESTORE SAVE -> '
      'Synchronizing '
      '${blocks.length} '
      'Google Calendar blocks',
    );

    // -----------------------------------------------------------------
    // 1. DELETE PREVIOUS GOOGLE CALENDAR PRIVATE SLOTS
    // -----------------------------------------------------------------

    final previousPrivate = await _slotsCollection
        .where(
          'source',
          isEqualTo: 'google_calendar',
        )
        .get();

    debugPrint(
      'FIRESTORE SAVE -> '
      'Deleting '
      '${previousPrivate.docs.length} '
      'previous private Google slots',
    );

    // Availability has no source field; the matching private document IDs
    // identify exactly the Google-derived projections to remove.
    for (final document in previousPrivate.docs) {
      final batch = firestore.batch();
      batch.delete(document.reference);
      batch.delete(_availabilitySlotsCollection.doc(document.id));
      await batch.commit();
    }

    // -----------------------------------------------------------------
    // 3. WRITE CURRENT GOOGLE CALENDAR
    // -----------------------------------------------------------------

    var writtenCount = 0;

    for (final block in blocks) {
      if (!block.end.isAfter(
        block.start,
      )) {
        debugPrint(
          'FIRESTORE SAVE -> '
          'Skipping ${block.id}: '
          'invalid interval',
        );

        continue;
      }

      final documentId = _safeDocumentId(
        block.id,
      );

      final privateData = <String, dynamic>{
        'externalId': _externalId(
          block.id,
        ),
        'title': block.title ?? '',
        'start': Timestamp.fromDate(
          block.start,
        ),
        'end': Timestamp.fromDate(
          block.end,
        ),
        'dayKey': _dayKey(
          block.start,
        ),
        'source': 'google_calendar',
        'importedAt': now,
      };

      if (block.subtitle != null && block.subtitle!.trim().isNotEmpty) {
        privateData['description'] = block.subtitle!.trim();
      }

      if (block.location != null && block.location!.trim().isNotEmpty) {
        privateData['location'] = block.location!.trim();
      }

      // ---------------------------------------------------------------
      // PRIVATE SLOT
      // ---------------------------------------------------------------

      await _slotsCollection
          .doc(
            documentId,
          )
          .set(
            privateData,
          );

      // ---------------------------------------------------------------
      // PRIVACY-SAFE AVAILABILITY SLOT
      // ---------------------------------------------------------------

      await _availabilitySlotsCollection
          .doc(
        documentId,
      )
          .set(
        {
          'start': Timestamp.fromDate(
            block.start,
          ),
          'end': Timestamp.fromDate(
            block.end,
          ),
          'dayKey': _dayKey(
            block.start,
          ),
        },
      );

      writtenCount++;

      debugPrint(
        'FIRESTORE SAVE -> '
        'Wrote slot $documentId',
      );
    }

    // -----------------------------------------------------------------
    // 4. PRIVATE SCHEDULE PARENT
    // -----------------------------------------------------------------

    await _scheduleDocument.set(
      {
        'ownerId': uid,
        'source': 'google_calendar',
        'lastImportedAt': now,
        'importedCount': writtenCount,
      },
      SetOptions(
        merge: true,
      ),
    );

    // -----------------------------------------------------------------
    // 5. AVAILABILITY PARENT
    // -----------------------------------------------------------------

    await _availabilityDocument.set(
      {
        'ownerId': uid,
        'slotCount': (await _availabilitySlotsCollection.get()).docs.length,
        'updatedAt': now,
      },
      SetOptions(
        merge: true,
      ),
    );

    debugPrint(
      'FIRESTORE SAVE -> '
      'Synchronization completed',
    );

    debugPrint(
      'FIRESTORE SAVE -> '
      '$writtenCount private slots',
    );

    debugPrint(
      'FIRESTORE SAVE -> '
      '$writtenCount shared '
      'availability slots',
    );
  }

  // ===================================================================
  // HELPERS
  // ===================================================================

  String _dayKey(
    DateTime value,
  ) {
    final local = value.toLocal();

    final year = local.year.toString().padLeft(
          4,
          '0',
        );

    final month = local.month.toString().padLeft(
          2,
          '0',
        );

    final day = local.day.toString().padLeft(
          2,
          '0',
        );

    return '$year-$month-$day';
  }

  String _safeDocumentId(
    String value,
  ) {
    return value
        .replaceAll(
          '/',
          '_',
        )
        .replaceAll(
          '\\',
          '_',
        );
  }

  String _externalId(
    String value,
  ) {
    const prefix = 'google-';

    if (value.startsWith(
      prefix,
    )) {
      return value.substring(
        prefix.length,
      );
    }

    return value;
  }

  String _initials(
    String name,
  ) {
    final words = name
        .trim()
        .split(
          RegExp(
            r'\s+',
          ),
        )
        .where(
          (word) => word.isNotEmpty,
        )
        .toList();

    if (words.isEmpty) {
      return '?';
    }

    if (words.length == 1) {
      return words.first
          .substring(
            0,
            1,
          )
          .toUpperCase();
    }

    return (words.first.substring(
              0,
              1,
            ) +
            words.last.substring(
              0,
              1,
            ))
        .toUpperCase();
  }
}
