import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import 'vault_constants.dart';

/// Manages the Offline Mode user lifecycle:
///   - First-time setup: derive key from master password, store salt only
///   - Subsequent unlocks: re-derive key from master password + stored salt
///   - Session end: zero out key bytes and drop from memory
///
/// The master password is NEVER stored anywhere.
/// Only the 16-byte Argon2id salt is persisted (in FlutterSecureStorage).
class OfflineAuthManager {
  static final OfflineAuthManager _instance = OfflineAuthManager._internal();
  factory OfflineAuthManager() => _instance;
  OfflineAuthManager._internal();

  static const String _saltKey        = VaultKeys.offlineSalt;
  static const String _verifierKey    = VaultKeys.offlineVerifier;
  static const String _modeKey        = VaultKeys.vaultMode;
  static const String _offlineNameKey = VaultKeys.offlineDisplayName;

  final _storage = const FlutterSecureStorage();
  final _rng     = Random.secure();

  // In-memory session key — never written to disk
  Uint8List? _sessionKey;

  bool get hasSessionKey => _sessionKey != null;

  /// Returns a defensive copy of the in-memory key.
  /// Throws [StateError] if the user hasn't unlocked yet.
  Uint8List get sessionKey {
    final key = _sessionKey;
    if (key == null) {
      throw StateError(
          'No active session key. Call unlockWithMasterPassword() first.');
    }
    return Uint8List.fromList(key);
  }

  // ─── Mode helpers ────────────────────────────────────────────────────────

  Future<void> setMode(String mode) =>
      _storage.write(key: _modeKey, value: mode);

  Future<String> getMode() async =>
      (await _storage.read(key: _modeKey)) ?? 'cloud';

  Future<bool> isOfflineMode() async => (await getMode()) == 'offline';

  Future<bool> isOfflineSetupComplete() async =>
      (await _storage.read(key: _saltKey)) != null;

  // ─── First-time setup (called once at signup) ────────────────────────────

  /// 1. Generates a random 16-byte Argon2id salt via CSPRNG.
  /// 2. Derives a 32-byte AES key from [masterPassword] + salt.
  /// 3. Stores only the salt + an HMAC verifier for wrong-password detection.
  /// 4. Holds the derived key in memory for the current session.
  Future<void> setupOfflineUser({
    required String masterPassword,
    required String displayName,
  }) async {
    final saltBytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      saltBytes[i] = _rng.nextInt(256);
    }

    final key      = await _deriveKey(masterPassword, saltBytes);
    final verifier = await _computeVerifier(key, saltBytes);

    await _storage.write(key: _saltKey,        value: base64Encode(saltBytes));
    await _storage.write(key: _verifierKey,    value: verifier);
    await _storage.write(key: _offlineNameKey, value: displayName);
    await setMode('offline');

    _sessionKey = key;
  }

  // ─── Unlock (called on app open or resume) ───────────────────────────────

  /// Re-derives the key from [masterPassword] + stored salt.
  /// Throws [WrongPasswordException] if the HMAC verifier doesn't match.
  Future<void> unlockWithMasterPassword(String masterPassword) async {
    final saltB64 = await _storage.read(key: _saltKey);
    if (saltB64 == null) {
      throw StateError('No offline user found on this device.');
    }

    final saltBytes = Uint8List.fromList(base64Decode(saltB64));
    final key       = await _deriveKey(masterPassword, saltBytes);
    final computed  = await _computeVerifier(key, saltBytes);
    final stored    = await _storage.read(key: _verifierKey) ?? '';

    if (computed != stored) {
      key.fillRange(0, key.length, 0); // zero out wrong key
      throw WrongPasswordException();
    }

    _sessionKey = key;
  }

  // ─── Session teardown ────────────────────────────────────────────────────

  /// Zero out and drop the in-memory key.
  /// Call when the app backgrounds or the user explicitly locks the vault.
  void dropSessionKey() {
    final key = _sessionKey;
    if (key != null) {
      key.fillRange(0, key.length, 0);
      _sessionKey = null;
    }
  }

  Future<String?> getDisplayName() => _storage.read(key: _offlineNameKey);

  /// Full wipe — call if user resets the vault from settings.
  Future<void> deleteOfflineUser() async {
    dropSessionKey();
    await _storage.delete(key: _saltKey);
    await _storage.delete(key: _verifierKey);
    await _storage.delete(key: _offlineNameKey);
    await _storage.delete(key: _modeKey);
  }

  // ─── Private helpers ─────────────────────────────────────────────────────

  Future<Uint8List> _deriveKey(String password, Uint8List salt) async {
    final argon2 = Argon2id(
      memory:      65536, // 64 MB — ~1–2 s on mid-range Android, strong against GPU
      parallelism: 2,
      iterations:  3,
      hashLength:  32,    // 256-bit key for AES-256
    );

    final secretKey = await argon2.deriveKeyFromPassword(
      password: password,
      nonce:    salt,
    );

    final keyBytes = await secretKey.extractBytes();
    return Uint8List.fromList(keyBytes);
  }

  /// HMAC-SHA256(salt, key) — proves key + salt match without storing the key.
  Future<String> _computeVerifier(Uint8List key, Uint8List salt) async {
    final hmac = Hmac.sha256();
    final mac  = await hmac.calculateMac(
      salt,
      secretKey: SecretKey(key),
    );
    return base64Encode(mac.bytes);
  }
}

// ─── Exception ───────────────────────────────────────────────────────────────

class WrongPasswordException implements Exception {
  final String message;
  const WrongPasswordException([this.message = 'Incorrect master password']);

  @override
  String toString() => message;
}
