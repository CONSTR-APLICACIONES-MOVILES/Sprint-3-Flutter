import 'package:flutter/material.dart';
import 'firebase_dependencies.dart';
import '../../features/profile/data/repositories/firebase_profile_repository.dart';
import '../../features/auth/domain/repositories/auth_repository.dart';
import '../../features/auth/domain/use_cases/sign_out.dart';
import '../../features/profile/data/repositories/mock_profile_repository.dart';
import '../../features/profile/domain/repositories/profile_repository.dart';
import '../../features/profile/domain/use_cases/manage_profile.dart';
import '../../features/profile/presentation/view_models/profile_view_model.dart';
import '../../features/profile/presentation/views/profile_view.dart';
import '../../features/profile/data/repositories/device_profile_photo_repository.dart';
import '../../features/profile/domain/repositories/profile_photo_repository.dart';
import '../../features/profile/domain/use_cases/change_profile_photo.dart';
import '../../core/connectivity/connectivity_service.dart';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import '../../features/activities/data/data_sources/firebase_activity_data_source.dart';
import '../../features/activities/data/repositories/activity_history_repository.dart';
import '../../features/activities/presentation/views/activity_history_view.dart';

class ProfileDependencies {
  final ProfileRepository repository;
  final AuthRepository? authRepository;
  final ProfilePhotoRepository photos;
  final Future<bool> Function()? isOnline;
  final ActivityHistoryRepository? history;

  const ProfileDependencies(
      {required this.repository,
      this.authRepository,
      required this.photos,
      this.isOnline,
      this.history});

  factory ProfileDependencies.mock({AuthRepository? authRepository}) =>
      ProfileDependencies(
          repository: MockProfileRepository(),
          authRepository: authRepository,
          photos: DeviceProfilePhotoRepository());

  factory ProfileDependencies.firebase(FirebaseDependencies firebase,
      {required AuthRepository authRepository}) {
    final isOnline = ConnectivityService().hasConnection;
    return ProfileDependencies(
        repository: FirebaseProfileRepository(firebase.mobile),
        authRepository: authRepository,
        photos: DeviceProfilePhotoRepository(),
        isOnline: isOnline,
        history: ActivityHistoryRepository(
            remote: FirebaseActivityDataSource(
                    functions: firebase.functions,
                    auth: firebase.auth,
                    firestore: firebase.firestore)
                .listActivities,
            directory: getApplicationDocumentsDirectory,
            userId: () => firebase.auth.currentUser?.uid,
            isOnline: isOnline));
  }

  ProfileViewModel createViewModel() => ProfileViewModel(
        ManageProfile(repository),
        signOut: authRepository == null ? null : SignOut(authRepository!),
        changePhoto: ChangeProfilePhoto(photos, repository, isOnline: isOnline),
      );

  Widget route() => _ProfileEntry(dependencies: this);

  Widget historyRoute() => history == null
      ? const Scaffold(
          body: Center(child: Text('Activity history is unavailable.')))
      : ActivityHistoryView(repository: history!);
}

class _ProfileEntry extends StatefulWidget {
  final ProfileDependencies dependencies;
  const _ProfileEntry({required this.dependencies});

  @override
  State<_ProfileEntry> createState() => _ProfileEntryState();
}

class _ProfileEntryState extends State<_ProfileEntry> {
  late final ProfileViewModel _viewModel =
      widget.dependencies.createViewModel();
      @override
      void initState() {
        super.initState();
        unawaited(widget.dependencies.history?.prefetch());
  }

  @override
  Widget build(BuildContext context) => ProfileView(viewModel: _viewModel);

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }
}
