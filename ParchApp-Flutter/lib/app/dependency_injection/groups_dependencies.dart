import '../../features/groups/domain/repositories/community_repository.dart';
import '../../features/groups/data/repositories/firebase_community_repository.dart';
import '../../features/groups/presentation/views/community_views.dart';
import '../../shared/widgets/unavailable_feature_view.dart';
import 'package:flutter/material.dart';
import 'firebase_dependencies.dart';
import '../../features/groups/data/data_sources/firestore_groups_data_source.dart';
import '../../features/groups/data/repositories/firebase_active_groups_repository.dart';
import '../../features/groups/data/repositories/firestore_response_time_insights_repository.dart';
import '../../features/groups/data/repositories/open_meteo_weather_repository.dart';
import '../../core/analytics/analytics_service.dart';
import '../../core/analytics/debug_analytics_service.dart';
import '../../features/groups/data/repositories/mock_active_groups_repository.dart';
import '../../features/groups/data/repositories/mock_response_time_insights_repository.dart';
import '../../features/groups/domain/repositories/active_groups_repository.dart';
import '../../features/groups/domain/repositories/response_time_insights_repository.dart';
import '../../features/groups/domain/repositories/weather_repository.dart';
import '../../features/groups/domain/use_cases/estimate_response_time.dart';
import '../../features/groups/domain/use_cases/forecast_activity_weather.dart';
import '../../features/groups/domain/use_cases/manage_active_groups.dart';
import '../../features/groups/presentation/view_models/active_groups_view_model.dart';
import '../../features/groups/presentation/views/active_groups_view.dart';
import '../../features/groups/data/repositories/cached_weather_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../features/groups/domain/repositories/group_chat.dart';
import '../../features/groups/data/repositories/firestore_group_chat_repository.dart';
import '../../features/groups/presentation/views/group_chat_view.dart';

class GroupsDependencies {
  final ActiveGroupsRepository repository;
  final CommunityRepository? community;
  final ResponseTimeInsightsRepository insights;
  final WeatherRepository? weather;
  final AnalyticsService analytics;
  final String? Function()? currentUserId;
  final GroupChat? chat;

  const GroupsDependencies({
    required this.repository,
    this.community,
    required this.insights,
    this.weather,
    required this.analytics,
    this.currentUserId,
    this.chat,
  });

  factory GroupsDependencies.mock({
    ResponseTimeInsightsRepository? insights,
    AnalyticsService? analytics,
  }) =>
      GroupsDependencies(
        repository: MockActiveGroupsRepository(),
        insights: insights ?? MockResponseTimeInsightsRepository(),
        analytics: analytics ?? DebugAnalyticsService(),
      );

  factory GroupsDependencies.firebase(FirebaseDependencies firebase,
          {required AnalyticsService analytics}) =>
      GroupsDependencies(
        community: FirebaseCommunityRepository(firebase.mobile,
            project: firebase.auth.app.options.projectId,
            currentUserId: () => firebase.auth.currentUser?.uid),
        repository: FirebaseActiveGroupsRepository(FirestoreGroupsDataSource(
            firebase.firestore, firebase.auth,
            api: firebase.mobile,
            canAttemptRemote: () => firebase.mobile.canAttemptRemote)),
        insights: FirestoreResponseTimeInsightsRepository(firebase.mobile),
        weather: CachedWeatherRepository(
            OpenMeteoWeatherRepository(), SharedPreferences.getInstance),
        analytics: analytics,
        currentUserId: () => firebase.auth.currentUser?.uid,
        chat: FirestoreGroupChatRepository(firebase.firestore, firebase.auth),
      );

  ActiveGroupsViewModel createViewModel() => ActiveGroupsViewModel(
        ManageActiveGroups(repository,
            analytics: analytics, currentUserId: currentUserId),
        estimate: EstimateResponseTime(insights),
        weather: weather == null ? null : ForecastActivityWeather(weather!),
      );

  Widget detailsRoute(String id) => community == null
      ? const UnavailableFeatureView(title: 'Group Details', selectedIndex: 1)
      : GroupDetailsView(
          key: ValueKey(id), groupId: id, repository: community!);
  Widget createRoute() => community == null
      ? const UnavailableFeatureView(title: 'Create Group', selectedIndex: 1)
      : CreateGroupView(repository: community!);
  Widget invitationsRoute() => community == null
      ? const UnavailableFeatureView(
          title: 'Group invitations', selectedIndex: 1)
      : GroupInvitationsView(repository: community!);
  Widget chatRoute(String groupId, {String? friendId, String? title}) =>
      chat == null
          ? const UnavailableFeatureView(title: 'Group Chat', selectedIndex: 1)
          : GroupChatView(
              key: ValueKey('$groupId/$friendId'),
              chat: chat!,
              groupId: groupId,
              friendId: friendId,
              title: title ?? 'House Chat');
  Widget activeGroupsRoute() => _ActiveGroupsEntry(dependencies: this);
}

class _ActiveGroupsEntry extends StatefulWidget {
  final GroupsDependencies dependencies;
  const _ActiveGroupsEntry({required this.dependencies});

  @override
  State<_ActiveGroupsEntry> createState() => _ActiveGroupsEntryState();
}

class _ActiveGroupsEntryState extends State<_ActiveGroupsEntry> {
  late final ActiveGroupsViewModel _viewModel =
      widget.dependencies.createViewModel();

  @override
  Widget build(BuildContext context) => ActiveGroupsView(viewModel: _viewModel);

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }
}
