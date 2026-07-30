import 'dart:io';
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'vault_constants.dart';

/// Handles AES-256-CBC encryption and decryption of files stored in the
/// app's private directory. The encryption key is generated once and stored
/// in FlutterSecureStorage (same pattern as the cloud enc key).
///
/// Encrypted file layout on disk:
///   [16 bytes IV] + [N bytes AES-256-CBC encrypted data]
///
/// Files are stored at:
///   <appDocDir>/secure_files/<fileId>.obx
///
/// The .obx extension is meaningless to the OS — it cannot be opened by
/// any app. The file is invisible to the file manager (private sandbox).
class SecureFileService {
  static const _storage = FlutterSecureStorage();
  static const _fileDir = 'secure_files';

  // ── Key management ────────────────────────────────────────────────────────

  /// Returns the AES-256 key, generating and storing it if it doesn't exist yet.
  static Future<enc.Key> _getOrCreateKey() async {
    String? stored = await _storage.read(key: VaultKeys.fileEncKey);
    if (stored == null) {
      final key = enc.Key.fromSecureRandom(32); // 256 bits
      await _storage.write(key: VaultKeys.fileEncKey, value: key.base64);
      return key;
    }
    return enc.Key.fromBase64(stored);
  }

  // ── Directory ─────────────────────────────────────────────────────────────

  /// Returns (and creates if needed) the secure_files directory inside
  /// the app's private documents directory.
  static Future<Directory> _getSecureDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final secureDir = Directory('${appDir.path}/$_fileDir');
    if (!await secureDir.exists()) {
      await secureDir.create(recursive: true);
    }
    return secureDir;
  }

  /// Returns the full path where an encrypted file should be stored.
  static Future<String> _encryptedPath(String fileId) async {
    final dir = await _getSecureDir();
    return '${dir.path}/$fileId.obx';
  }

  // ── Encrypt & save ────────────────────────────────────────────────────────

  /// Reads [sourceFile], encrypts it, saves to private storage.
  /// Returns the encrypted file path to store in metadata.
  ///
  /// Throws if the file cannot be read or written.
  static Future<String> encryptAndSave({
    required File sourceFile,
    required String fileId,
  }) async {
    final key = await _getOrCreateKey();

    // Generate a fresh random IV for every file
    final iv = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));

    // Read source bytes
    final plainBytes = await sourceFile.readAsBytes();

    // Encrypt
    final encrypted = encrypter.encryptBytes(plainBytes, iv: iv);

    // Write [IV (16 bytes)] + [ciphertext] to .obx file
    final outPath = await _encryptedPath(fileId);
    final outFile = File(outPath);
    final sink = outFile.openWrite();
    sink.add(iv.bytes);          // first 16 bytes = IV
    sink.add(encrypted.bytes);   // rest = ciphertext
    await sink.flush();
    await sink.close();

    return outPath;
  }

  // ── Decrypt & read ────────────────────────────────────────────────────────

  /// Decrypts the file at [encryptedPath] and returns the plain bytes.
  /// The decrypted bytes are only ever in memory — never written to disk.
  ///
  /// Throws if the file is missing or the key is unavailable.
  static Future<Uint8List> decryptToBytes({
    required String encryptedPath,
  }) async {
    final key = await _getOrCreateKey();

    final encFile = File(encryptedPath);
    if (!await encFile.exists()) {
      throw FileSystemException('Encrypted file not found', encryptedPath);
    }

    final allBytes = await encFile.readAsBytes();

    // Split IV and ciphertext
    final ivBytes = Uint8List.fromList(allBytes.sublist(0, 16));
    final cipherBytes = Uint8List.fromList(allBytes.sublist(16));

    final iv = enc.IV(ivBytes);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));

    final decrypted = encrypter.decryptBytes(enc.Encrypted(cipherBytes), iv: iv);
    return Uint8List.fromList(decrypted);
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  /// Permanently deletes the encrypted file from disk.
  /// Safe to call even if the file no longer exists.
  static Future<void> deleteEncryptedFile(String encryptedPath) async {
    final file = File(encryptedPath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Returns a human-readable file size string (e.g. "2.4 MB").
  static String formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Returns 'image' or 'pdf' based on file extension.
  /// Returns 'other' for anything else.
  static String fileTypeFromExtension(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    const imageExts = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'bmp'];
    const pdfExts = ['pdf'];
    if (imageExts.contains(ext)) return 'image';
    if (pdfExts.contains(ext)) return 'pdf';
    return 'other';
  }
}
