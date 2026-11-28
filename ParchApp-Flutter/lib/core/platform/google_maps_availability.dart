import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract final class GoogleMapsAvailability {
  static const channel = MethodChannel('parchapp/google_places');
  static const _iosKey = String.fromEnvironment('GOOGLE_MAPS_IOS_KEY');
  static Future<bool>? _iosReady;

  static Future<bool> isConfigured() async {
    if (kIsWeb) return false;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return _iosReady ??= _configureIos();
    }
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await channel.invokeMethod<bool>('isConfigured') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> _configureIos() async {
    if (_iosKey.isEmpty) return false;
    try {
      return await channel
              .invokeMethod<bool>('configure', {'key': _iosKey}) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }
}