import 'package:connectivity_plus/connectivity_plus.dart';

class ConnectivityService {
  final Connectivity _connectivity;

  ConnectivityService({
    Connectivity? connectivity,
  }) : _connectivity =
            connectivity ?? Connectivity();

  Future<bool> hasConnection() async {
    final results =
        await _connectivity.checkConnectivity();

    return _hasConnection(
      results,
    );
  }
  // Returns a stream of connectivity changes, emitting true when connected and false when disconnected.

  Stream<bool> get connectionChanges {
    return _connectivity
        .onConnectivityChanged
        .map(_hasConnection)
        .distinct();
  }

  bool _hasConnection(
    List<ConnectivityResult> results,
  ) {
    if (results.isEmpty) {
      return false;
    }

    return results.any(
      (result) =>
          result != ConnectivityResult.none,
    );
  }
}