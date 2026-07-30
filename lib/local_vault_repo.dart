import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'vault_repository.dart';

/// Offline Mode backend — two Hive boxes (passwords + notes), both encrypted
/// with the same Argon2id-derived key. Custom categories stored in a third box.
/// File metadata stored in a fourth box (actual encrypted bytes live on disk).
class LocalVaultRepo implements VaultRepository {
  static const String _pwBoxName   = 'obexvault_local';
  static const String _noteBoxName = 'obexvault_notes';
  static const String _metaBoxName = 'obexvault_meta'; // categories etc.
  static const String _fileBoxName = 'obexvault_files'; // file metadata only

  final Uint8List _derivedKey;
  Box<String>? _pwBox;
  Box<String>? _noteBox;
  Box<String>? _metaBox;
  Box<String>? _fileBox;

  final _pwController   = StreamController<List<Map<String, dynamic>>>.broadcast();
  final _noteController = StreamController<List<Map<String, dynamic>>>.broadcast();
  final _catController  = StreamController<List<String>>.broadcast();
  final _fileController = StreamController<List<Map<String, dynamic>>>.broadcast();

  LocalVaultRepo({required Uint8List derivedKey}) : _derivedKey = derivedKey;

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> init() async {
    await Hive.initFlutter();
    final cipher = HiveAesCipher(_derivedKey);
    _pwBox   = await Hive.openBox<String>(_pwBoxName,   encryptionCipher: cipher);
    _noteBox = await Hive.openBox<String>(_noteBoxName, encryptionCipher: cipher);
    _metaBox = await Hive.openBox<String>(_metaBoxName, encryptionCipher: cipher);
    _fileBox = await Hive.openBox<String>(_fileBoxName, encryptionCipher: cipher);
    _emitPasswords();
    _emitNotes();
    _emitCategories();
    _emitFiles();
  }

  // ── Emit helpers ──────────────────────────────────────────────────────────

  void _emitPasswords() {
    if (!_pwController.isClosed) _pwController.add(_readBox(_pwBox));
  }

  void _emitNotes() {
    if (!_noteController.isClosed) _noteController.add(_readBox(_noteBox));
  }

  void _emitCategories() {
    if (!_catController.isClosed) _catController.add(_readCategories());
  }

  void _emitFiles() {
    if (!_fileController.isClosed) _fileController.add(_readBox(_fileBox));
  }

  List<Map<String, dynamic>> _readBox(Box<String>? box) {
    if (box == null) return [];
    final entries = box.keys.map((key) {
      final raw = box.get(key as String);
      if (raw == null) return null;
      try {
        final map = Map<String, dynamic>.from(jsonDecode(raw));
        map['id'] = key;
        return map;
      } catch (_) {
        return null;
      }
    }).whereType<Map<String, dynamic>>().toList();

    entries.sort((a, b) {
      final at = a['createdAt'] as String? ?? '';
      final bt = b['createdAt'] as String? ?? '';
      return bt.compareTo(at);
    });
    return entries;
  }

  List<String> _readCategories() {
    final box = _metaBox;
    if (box == null) return [];
    final raw = box.get('custom_categories');
    if (raw == null) return [];
    try {
      return List<String>.from(jsonDecode(raw));
    } catch (_) {
      return [];
    }
  }

  // ── Passwords ─────────────────────────────────────────────────────────────

  @override
  Stream<List<Map<String, dynamic>>> watchPasswords() async* {
    yield _readBox(_pwBox);
    yield* _pwController.stream;
  }

  @override
  Future<void> addPassword(Map<String, dynamic> data) async {
    final box = _pwBox;
    if (box == null) throw StateError('LocalVaultRepo not initialised');
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    await box.put(id, jsonEncode({...data, 'createdAt': DateTime.now().toIso8601String()}));
    _emitPasswords();
  }

  @override
  Future<void> deletePassword(String id) async {
    final box = _pwBox;
    if (box == null) throw StateError('LocalVaultRepo not initialised');
    await box.delete(id);
    _emitPasswords();
  }

  @override
  Future<void> togglePasswordFavorite(String id, bool isFavorite) async {
    final box = _pwBox;
    if (box == null) throw StateError('LocalVaultRepo not initialised');
    final raw = box.get(id);
    if (raw == null) return;
    final map = Map<String, dynamic>.from(jsonDecode(raw));
    map['isFavorite'] = isFavorite;
    await box.put(id, jsonEncode(map));
    _emitPasswords();
  }

  @override
  Future<int> getPasswordCount() async => _pwBox?.length ?? 0;

  // ── Notes ─────────────────────────────────────────────────────────────────

  @override
  Stream<List<Map<String, dynamic>>> watchNotes() async* {
    yield _readBox(_noteBox);
    yield* _noteController.stream;
  }

  @override
  Future<void> addNote(Map<String, dynamic> data) async {
    final box = _noteBox;
    if (box == null) throw StateError('LocalVaultRepo not initialised');
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    await box.put(id, jsonEncode({...data, 'createdAt': DateTime.now().toIso8601String()}));
    _emitNotes();
  }

  @override
  Future<void> deleteNote(String id) async {
    final box = _noteBox;
    if (box == null) throw StateError('LocalVaultRepo not initialised');
    await box.delete(id);
    _emitNotes();
  }

  @override
  Future<void> toggleNoteFavorite(String id, bool isFavorite) async {
    final box = _noteBox;
    if (box == null) throw StateError('LocalVaultRepo not initialised');
    final raw = box.get(id);
    if (raw == null) return;
    final map = Map<String, dynamic>.from(jsonDecode(raw));
    map['isFavorite'] = isFavorite;
    await box.put(id, jsonEncode(map));
    _emitNotes();
  }

  // ── Files ─────────────────────────────────────────────────────────────────
  // Only metadata is stored in Hive. Encrypted bytes live at encryptedPath.

  @override
  Stream<List<Map<String, dynamic>>> watchFiles() async* {
    yield _readBox(_fileBox);
    yield* _fileController.stream;
  }

  @override
  Future<void> addFile(Map<String, dynamic> metadata) async {
    final box = _fileBox;
    if (box == null) throw StateError('LocalVaultRepo not initialised');
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    await box.put(id, jsonEncode({...metadata, 'createdAt': DateTime.now().toIso8601String()}));
    _emitFiles();
  }

  @override
  Future<void> deleteFile(String id) async {
    final box = _fileBox;
    if (box == null) throw StateError('LocalVaultRepo not initialised');
    await box.delete(id);
    _emitFiles();
  }

  // ── Categories ────────────────────────────────────────────────────────────

  @override
  Stream<List<String>> watchCustomCategories() async* {
    yield _readCategories();
    yield* _catController.stream;
  }

  @override
  Future<void> addCustomCategory(String name) async {
    final box = _metaBox;
    if (box == null) throw StateError('LocalVaultRepo not initialised');
    final current = _readCategories();
    if (!current.contains(name)) {
      current.add(name);
      await box.put('custom_categories', jsonEncode(current));
      _emitCategories();
    }
  }

  @override
  Future<void> deleteCustomCategory(String name) async {
    final box = _metaBox;
    if (box == null) throw StateError('LocalVaultRepo not initialised');
    final current = _readCategories()..remove(name);
    await box.put('custom_categories', jsonEncode(current));
    _emitCategories();
  }

  // ── Shared ────────────────────────────────────────────────────────────────

  @override
  Future<void> dispose() async {
    await _pwBox?.close();
    await _noteBox?.close();
    await _metaBox?.close();
    await _fileBox?.close();
    _pwBox = _noteBox = _metaBox = _fileBox = null;
    await _pwController.close();
    await _noteController.close();
    await _catController.close();
    await _fileController.close();
    _derivedKey.fillRange(0, _derivedKey.length, 0);
  }
}