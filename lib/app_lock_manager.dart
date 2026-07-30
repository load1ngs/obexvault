// lib/app_lock_manager.dart
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth/error_codes.dart' as auth_error;

/// Which biometric type the user has chosen in settings.
enum BiometricMode { fingerprint, face, both }

class AppLockManager {
  AppLockManager._();
  static final AppLockManager instance = AppLockManager._();

  static const _kPinKey                  = 'app_lock_pin';
  static const _kFingerprintEnabledKey   = 'app_lock_fingerprint_enabled';
  static const _kSetupDoneKey            = 'app_lock_setup_done';
  static const _kAutoLockSecondsKey      = 'app_lock_auto_lock_seconds';
  static const _kBiometricModeKey        = 'app_lock_biometric_mode';

  final _storage = const FlutterSecureStorage();
  final _auth    = LocalAuthentication();

  bool isAuthenticating = false;
  DateTime? lastPausedAt;

  // ---------- PIN ----------
  Future<bool> hasPin() async {
    final pin = await _storage.read(key: _kPinKey);
    return pin != null && pin.isNotEmpty;
  }

  Future<void> setPin(String pin) async {
    await _storage.write(key: _kPinKey, value: pin);
  }

  Future<bool> verifyPin(String pin) async {
    final stored = await _storage.read(key: _kPinKey);
    return stored == pin;
  }

  /// Returns the raw stored PIN string (used to prevent panic PIN collision).
  Future<String?> getRawPin() async {
    return await _storage.read(key: _kPinKey);
  }

  Future<void> clearPin() async {
    await _storage.delete(key: _kPinKey);
  }

  // ---------- Biometric availability ----------
  Future<bool> isFingerprintAvailable() async {
    try {
      final canCheck   = await _auth.canCheckBiometrics;
      final isSupported = await _auth.isDeviceSupported();
      if (!canCheck || !isSupported) return false;
      final available = await _auth.getAvailableBiometrics();
      return available.contains(BiometricType.fingerprint) ||
          available.contains(BiometricType.strong) ||
          available.contains(BiometricType.weak);
    } catch (_) {
      return false;
    }
  }

  /// Returns which BiometricTypes are actually enrolled on the device.
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _auth.getAvailableBiometrics();
    } catch (_) {
      return [];
    }
  }

  /// True if device has face biometric enrolled.
  Future<bool> isFaceAvailable() async {
    try {
      final available = await _auth.getAvailableBiometrics();
      return available.contains(BiometricType.face);
    } catch (_) {
      return false;
    }
  }

  // ---------- Fingerprint enabled flag ----------
  Future<bool> isFingerprintEnabled() async {
    final v = await _storage.read(key: _kFingerprintEnabledKey);
    return v == 'true';
  }

  Future<void> setFingerprintEnabled(bool enabled) async {
    await _storage.write(
      key: _kFingerprintEnabledKey,
      value: enabled ? 'true' : 'false',
    );
  }

  // ---------- Biometric Mode ----------
  Future<BiometricMode> getBiometricMode() async {
    final v = await _storage.read(key: _kBiometricModeKey);
    switch (v) {
      case 'face':        return BiometricMode.face;
      case 'fingerprint': return BiometricMode.fingerprint;
      default:            return BiometricMode.both;
    }
  }

  Future<void> setBiometricMode(BiometricMode mode) async {
    final val = switch (mode) {
      BiometricMode.face        => 'face',
      BiometricMode.fingerprint => 'fingerprint',
      BiometricMode.both        => 'both',
    };
    await _storage.write(key: _kBiometricModeKey, value: val);
  }

  // ---------- Authenticate ----------
  /// Returns: 'success', 'fail', 'unavailable', 'locked_out'
  Future<String> authenticateFingerprint() async {
    try {
      isAuthenticating = true;

      final mode      = await getBiometricMode();
      final available = await _auth.getAvailableBiometrics();

      bool modeAvailable = switch (mode) {
        BiometricMode.fingerprint =>
          available.contains(BiometricType.fingerprint) ||
          available.contains(BiometricType.strong),
        BiometricMode.face =>
          available.contains(BiometricType.face),
        BiometricMode.both =>
          available.isNotEmpty,
      };

      if (!modeAvailable) return 'unavailable';

      final reason = switch (mode) {
        BiometricMode.fingerprint => 'Place your finger to unlock ObexVault',
        BiometricMode.face        => 'Look at the camera to unlock ObexVault',
        BiometricMode.both        => 'Use biometrics to unlock ObexVault',
      };

      final ok = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
          useErrorDialogs: false,
        ),
      );
      return ok ? 'success' : 'fail';
    } on PlatformException catch (e) {
      if (e.code == auth_error.notAvailable ||
          e.code == auth_error.notEnrolled ||
          e.code == auth_error.passcodeNotSet) {
        return 'unavailable';
      }
      if (e.code == auth_error.lockedOut ||
          e.code == auth_error.permanentlyLockedOut) {
        return 'locked_out';
      }
      return 'fail';
    } finally {
      await Future.delayed(const Duration(milliseconds: 300));
      isAuthenticating = false;
    }
  }

  // ---------- Setup state ----------
  Future<bool> isSetupDone() async {
    final v = await _storage.read(key: _kSetupDoneKey);
    return v == 'true';
  }

  Future<void> markSetupDone() async {
    await _storage.write(key: _kSetupDoneKey, value: 'true');
  }

  // ---------- Auto-lock grace period ----------
  Future<int> getAutoLockSeconds() async {
    final v = await _storage.read(key: _kAutoLockSecondsKey);
    return int.tryParse(v ?? '60') ?? 60;
  }

  Future<void> setAutoLockSeconds(int seconds) async {
    await _storage.write(key: _kAutoLockSecondsKey, value: seconds.toString());
  }

  Future<bool> shouldLockNow() async {
    if (lastPausedAt == null) return false;
    final secs    = await getAutoLockSeconds();
    final elapsed = DateTime.now().difference(lastPausedAt!).inSeconds;
    return elapsed >= secs;
  }

  // ---------- Reset (called on logout) ----------
  Future<void> resetAll() async {
    await _storage.delete(key: _kPinKey);
    await _storage.delete(key: _kFingerprintEnabledKey);
    await _storage.delete(key: _kSetupDoneKey);
    await _storage.delete(key: _kAutoLockSecondsKey);
    await _storage.delete(key: _kBiometricModeKey);
  }
}
