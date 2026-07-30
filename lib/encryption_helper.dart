import 'dart:math';
import 'dart:typed_data';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'vault_constants.dart';

/// AES-256 encryption helper.
///
/// Cloud Mode: a random 32-byte key is generated on first login, then
/// stored BOTH in FlutterSecureStorage (local cache) AND in Firestore
/// (encrypted with a key derived from the user's UID) so that any device
/// can retrieve it after sign-in.
///
/// Offline Mode passes the Argon2id-derived key bytes directly as [keyOverride].
///
/// Legacy fallback: entries encrypted before the secure key was introduced
/// (using the old UID-padded key) are still decryptable — no data loss on upgrade.
class EncryptionHelper {
  static const _storage = FlutterSecureStorage();

  // Random 32-byte cloud key, held in memory after initCloudKey().
  static Uint8List? _cloudKeyBytes;

  // ─── Lifecycle ────────────────────────────────────────────────────────────

  /// Call once right after Firebase sign-in is confirmed.
  ///
  /// Strategy:
  /// 1. Check local FlutterSecureStorage first (fast path).
  /// 2. If not found locally, fetch from Firestore and cache locally.
  /// 3. If not in Firestore either (first-ever login), generate a new key,
  ///    store it locally AND upload it to Firestore (wrapped with UID key).
  static Future<void> initCloudKey() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    // 1. Try local cache first
    String? stored = await _storage.read(key: VaultKeys.cloudEncKey);
    if (stored != null) {
      _cloudKeyBytes = Uint8List.fromList(base64Decode(stored));
      return;
    }

    // 2. Try fetching from Firestore
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();

      final wrappedKey = doc.data()?['encryptionKey'] as String?;
      if (wrappedKey != null) {
        // Unwrap: decrypt the stored key using the UID-derived key
        final unwrapped = _unwrapKey(wrappedKey, uid);
        if (unwrapped != null) {
          await _storage.write(key: VaultKeys.cloudEncKey, value: base64Encode(unwrapped));
          _cloudKeyBytes = unwrapped;
          return;
        }
      }
    } catch (_) {
      // Firestore fetch failed — fall through to generate new key
    }

    // 3. First-ever login on any device — generate a new key
    final rng = Random.secure();
    final bytes = Uint8List(32);
    for (int i = 0; i < 32; i++) bytes[i] = rng.nextInt(256);
    final b64 = base64Encode(bytes);

    // Save locally
    await _storage.write(key: VaultKeys.cloudEncKey, value: b64);
    _cloudKeyBytes = bytes;

    // Upload to Firestore wrapped with UID-derived key
    try {
      final wrapped = _wrapKey(bytes, uid);
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .set({'encryptionKey': wrapped}, SetOptions(merge: true));
    } catch (_) {
      // Upload failed — key is still usable locally, will retry on next login
    }
  }

  /// Zero out and drop the in-memory cloud key. Call on logout.
  static void clearCloudKey() {
    final key = _cloudKeyBytes;
    if (key != null) {
      key.fillRange(0, key.length, 0);
      _cloudKeyBytes = null;
    }
  }

  // ─── Encrypt / Decrypt ───────────────────────────────────────────────────

  /// Encrypts [plainText] with AES-256-CBC and a random IV.
  ///
  /// [keyOverride] — raw 32-byte key for Offline Mode.
  ///   Pass null to use the cloud key (Cloud Mode default).
  static String encrypt(String plainText, {Uint8List? keyOverride}) {
    final key       = enc.Key.fromBase64(base64Encode(keyOverride ?? _effectiveCloudKey()));
    final iv        = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(enc.AES(key));
    final encrypted = encrypter.encrypt(plainText, iv: iv);
    return '${iv.base64}:${encrypted.base64}';
  }

  /// Decrypts [encryptedText] produced by [encrypt].
  ///
  /// For Cloud Mode (keyOverride == null), tries the secure random key first,
  /// then falls back to the legacy UID-based key so old entries remain readable.
  static String decrypt(String encryptedText, {Uint8List? keyOverride}) {
    if (!encryptedText.contains(':')) return encryptedText;
    final parts = encryptedText.split(':');
    if (parts.length != 2) return encryptedText;

    if (keyOverride != null) {
      return _tryDecrypt(parts, enc.Key.fromBase64(base64Encode(keyOverride)))
          ?? encryptedText;
    }

    // Cloud mode: try new secure key first
    final primary = _tryDecrypt(
      parts,
      enc.Key.fromBase64(base64Encode(_effectiveCloudKey())),
    );
    if (primary != null) return primary;

    // Legacy fallback for entries created before the secure key was introduced
    return _tryDecrypt(parts, enc.Key.fromUtf8(_legacyUidKey()))
        ?? encryptedText;
  }

  // ─── Key wrapping (for Firestore storage) ────────────────────────────────

  /// Encrypts the 32-byte [keyBytes] using the UID-derived key so it can be
  /// safely stored in Firestore.
  static String _wrapKey(Uint8List keyBytes, String uid) {
    final wrapKey   = enc.Key.fromUtf8(_legacyUidKey(uid: uid));
    final iv        = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(enc.AES(wrapKey));
    final encrypted = encrypter.encryptBytes(keyBytes, iv: iv);
    return '${iv.base64}:${encrypted.base64}';
  }

  /// Decrypts a wrapped key from Firestore. Returns null if it fails.
  static Uint8List? _unwrapKey(String wrapped, String uid) {
    if (!wrapped.contains(':')) return null;
    final parts = wrapped.split(':');
    if (parts.length != 2) return null;
    try {
      final wrapKey   = enc.Key.fromUtf8(_legacyUidKey(uid: uid));
      final iv        = enc.IV.fromBase64(parts[0]);
      final encrypter = enc.Encrypter(enc.AES(wrapKey));
      final bytes     = encrypter.decryptBytes(enc.Encrypted.fromBase64(parts[1]), iv: iv);
      return Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    }
  }

  // ─── Private helpers ─────────────────────────────────────────────────────

  static String? _tryDecrypt(List<String> parts, enc.Key key) {
    try {
      final iv        = enc.IV.fromBase64(parts[0]);
      final encrypter = enc.Encrypter(enc.AES(key));
      return encrypter.decrypt64(parts[1], iv: iv);
    } catch (_) {
      return null;
    }
  }

  /// Returns the secure cloud key bytes, or the legacy key bytes if not yet init'd.
  static Uint8List _effectiveCloudKey() {
    final bytes = _cloudKeyBytes;
    if (bytes != null) return bytes;
    return Uint8List.fromList(utf8.encode(_legacyUidKey()));
  }

  /// Legacy: Firebase UID padded/trimmed to 32 ASCII chars.
  static String _legacyUidKey({String? uid}) {
    final id = uid ?? FirebaseAuth.instance.currentUser?.uid ?? 'defaultkey123456';
    return id.padRight(32, '0').substring(0, 32);
  }
}
