import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'models.dart';

/// Default server address. 10.0.2.2 is how the Android emulator reaches the
/// computer it runs on. For a real phone, build with
///   flutter run --dart-define=API_BASE=http://<your-pc-ip>:8000
/// or change it from the login screen.
const String kDefaultApiBase = String.fromEnvironment('API_BASE', defaultValue: 'http://10.0.2.2:8000');

/// App-wide state: who is signed in, the API client and the server's choices.
class Session extends ChangeNotifier {
  late final ApiClient api;
  AppUser? user;
  AppMeta? meta;
  bool ready = false;

  bool get signedIn => user != null;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    api = ApiClient(prefs.getString('api_base') ?? kDefaultApiBase, token: prefs.getString('token'));
    api.onUnauthorized = _expire;
    if (api.token != null) {
      try {
        user = await api.me();
      } catch (_) {
        // Offline or token expired: show the login screen.
        user = null;
      }
    }
    await loadMeta();
    ready = true;
    notifyListeners();
  }

  Future<void> loadMeta() async {
    try {
      meta = await api.meta();
    } catch (_) {
      meta = null;
    }
  }

  Future<void> setServer(String baseUrl) async {
    api.baseUrl = baseUrl.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_base', api.baseUrl);
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

  Future<void> register(String username, String email, String password, String displayName) async {
    final (token, newUser) =
        await api.register(username: username, email: email, password: password, displayName: displayName);
    await _store(token, newUser);
  }

  Future<void> logout() async {
    await api.logout();
    await _clear();
  }

  void _expire() {
    if (user != null) _clear();
  }

  Future<void> _clear() async {
    api.token = null;
    user = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    notifyListeners();
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
  static Future<Position> current() async {
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
    return Geolocator.getCurrentPosition(
      locationSettings: LocationSettings(accuracy: LocationAccuracy.high, timeLimit: const Duration(seconds: 20)),
    );
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
