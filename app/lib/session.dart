import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'models.dart';

/// Built-in server address. GitHub builds take it from the repository
/// variable API_BASE (Settings > Secrets and variables > Actions > Variables),
/// so a new tunnel address only needs that variable changed and a re-run.
/// Local builds can override it with
///   flutter run --dart-define=API_BASE=https://<your-server>
/// Users never need to change it; a hidden setting exists for testing (tap the
/// logo on the login screen 7 times).
const String kDefaultApiBase = String.fromEnvironment(
  'API_BASE',
  defaultValue: 'https://sunset-offer-ghz-description.trycloudflare.com',
);

/// App-wide state: who is signed in, the API client and the server's choices.
class Session extends ChangeNotifier {
  late final ApiClient api;
  AppUser? user;
  AppMeta? meta;
  bool ready = false;

  bool get signedIn => user != null;

  Future<void> init() async {
    String? savedBase;
    String? savedToken;
    try {
      final prefs = await SharedPreferences.getInstance();
      savedBase = prefs.getString('api_base');
      // A hand-entered address only applies to the build it was entered in.
      // When an update ships a new built-in address, use the new one.
      if (prefs.getString('api_base_build_default') != kDefaultApiBase) {
        savedBase = null;
        await prefs.remove('api_base');
        await prefs.setString('api_base_build_default', kDefaultApiBase);
      }
      savedToken = prefs.getString('token');
    } catch (_) {
      // Storage unavailable: start signed out rather than hang on the splash.
    }
    api = ApiClient(savedBase ?? kDefaultApiBase, token: savedToken);
    api.onUnauthorized = _expire;
    try {
      if (api.token != null) {
        try {
          user = await api.me();
        } catch (_) {
          // Offline, or the token is no longer valid (in which case _expire
          // has already removed it): show the login screen.
          user = null;
        }
      }
      await loadMeta();
    } finally {
      ready = true;
      notifyListeners();
    }
  }

  Future<void> loadMeta() async {
    try {
      meta = await api.meta();
    } catch (_) {
      meta = null;
    }
  }

  Future<void> setServer(String baseUrl) async {
    api.baseUrl = ApiClient.normalizeBase(baseUrl);
    final prefs = await SharedPreferences.getInstance();
    if (api.baseUrl == ApiClient.normalizeBase(kDefaultApiBase)) {
      await prefs.remove('api_base');
    } else {
      await prefs.setString('api_base', api.baseUrl);
    }
    await prefs.setString('api_base_build_default', kDefaultApiBase);
    await loadMeta();
    notifyListeners();
  }

  Future<void> _store(String token, AppUser newUser) async {
    api.token = token;
    user = newUser;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', token);
    if (meta == null) await loadMeta();
    notifyListeners();
  }

  Future<void> login(String username, String password) async {
    final (token, newUser) = await api.login(username, password);
    await _store(token, newUser);
  }

  /// Signs up. Returns null when signed in, or the pending email check.
  Future<PendingVerification?> register(String username, String email, String password, String displayName) async {
    final (token, newUser, pending) = await api.register(
      username: username,
      email: email,
      password: password,
      displayName: displayName,
    );
    if (token != null && newUser != null) {
      await _store(token, newUser);
      return null;
    }
    return pending;
  }

  Future<void> verifyEmail(String username, String code) async {
    final (token, newUser) = await api.verifyEmail(username, code);
    await _store(token, newUser);
  }

  Future<void> logout() async {
    await api.logout();
    await _clear();
  }

  /// The server rejected our saved token (logged out elsewhere, or the
  /// server's data was reset). Forget it so the next log in starts clean.
  void _expire() {
    if (api.token != null || user != null) _clear();
  }

  Future<void> _clear() async {
    api.token = null;
    user = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('token');
    } catch (_) {
      // Nothing more we can do; the in-memory session is already cleared.
    }
    if (ready) notifyListeners();
  }
}

class LocationException implements Exception {
  final String message;
  final bool openSettings;
  LocationException(this.message, {this.openSettings = false});
  @override
  String toString() => message;
}

/// Reads the phone's position only when asked (taking a photo, opening the
/// feed). The app never tracks location in the background.
class LocationService {
  static Future<void>? _permissionCheck;
  static Future<Position>? _fix;

  /// Checks GPS is on and asks for permission if needed. Screens that open
  /// together (feed and map) share one check, because Android refuses a
  /// second permission request while the first dialog is still showing.
  static Future<void> _ensureAllowed() {
    return _permissionCheck ??= _checkAllowed().whenComplete(() {
      _permissionCheck = null;
    });
  }

  static Future<void> _checkAllowed() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw LocationException('Turn on location (GPS) so we can tag where the item is.', openSettings: true);
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw LocationException('Location permission was denied.');
    }
    if (permission == LocationPermission.deniedForever) {
      throw LocationException('Location is blocked for this app. Allow it in Settings.', openSettings: true);
    }
  }

  /// A fresh, precise position. Used when tagging a found item.
  static Future<Position> current() {
    return _fix ??= _fresh().whenComplete(() {
      _fix = null;
    });
  }

  static Future<Position> _fresh() async {
    await _ensureAllowed();
    return Geolocator.getCurrentPosition(
      locationSettings: LocationSettings(accuracy: LocationAccuracy.high, timeLimit: const Duration(seconds: 20)),
    );
  }

  /// A position quickly: the phone's recent one if it has it, otherwise a
  /// fresh fix. Good enough for "posts near me", and doesn't keep the feed
  /// waiting for GPS indoors.
  static Future<Position> quick() async {
    await _ensureAllowed();
    final last = await lastKnown();
    if (last != null && DateTime.now().difference(last.timestamp).inMinutes.abs() < 10) return last;
    return current();
  }

  static Future<Position?> lastKnown() async {
    try {
      return await Geolocator.getLastKnownPosition();
    } catch (_) {
      return null;
    }
  }

  static Future<void> openSettings() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      await Geolocator.openLocationSettings();
    } else {
      await Geolocator.openAppSettings();
    }
  }
}
