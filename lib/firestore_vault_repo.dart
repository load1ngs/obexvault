import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'vault_repository.dart';
import 'services/dms_pdf_service.dart';

class FirestoreVaultRepo implements VaultRepository {
  final String _uid;
  final String _prefix;

  FirestoreVaultRepo({required String uid, String collectionPrefix = ''})
      : _uid = uid,
        _prefix = collectionPrefix;

  // ── Collection shortcuts ──────────────────────────────────────────────────

  CollectionReference<Map<String, dynamic>> get _passwords =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(_uid)
          .collection('${_prefix}passwords');

  CollectionReference<Map<String, dynamic>> get _notes =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(_uid)
          .collection('${_prefix}notes');

  CollectionReference<Map<String, dynamic>> get _files =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(_uid)
          .collection('${_prefix}files');

  DocumentReference<Map<String, dynamic>> get _userDoc =>
      FirebaseFirestore.instance.collection('users').doc(_uid);

  // ── Passwords ─────────────────────────────────────────────────────────────

  @override
  Stream<List<Map<String, dynamic>>> watchPasswords() {
    return _passwords
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) =>
            snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList());
  }

  @override
  Future<void> addPassword(Map<String, dynamic> data) async {
    await _passwords.add({...data, 'createdAt': FieldValue.serverTimestamp()});
  }

  @override
  Future<void> deletePassword(String id) async {
    await _passwords.doc(id).delete();
  }

  @override
  Future<void> togglePasswordFavorite(String id, bool isFavorite) async {
    await _passwords.doc(id).update({'isFavorite': isFavorite});
  }

  @override
  Future<int> getPasswordCount() async {
    final snap = await _passwords.get();
    return snap.docs.length;
  }

  // ── Notes ─────────────────────────────────────────────────────────────────

  @override
  Stream<List<Map<String, dynamic>>> watchNotes() {
    return _notes
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) =>
            snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList());
  }

  @override
  Future<void> addNote(Map<String, dynamic> data) async {
    await _notes.add({...data, 'createdAt': FieldValue.serverTimestamp()});
  }

  @override
  Future<void> deleteNote(String id) async {
    await _notes.doc(id).delete();
  }

  @override
  Future<void> toggleNoteFavorite(String id, bool isFavorite) async {
    await _notes.doc(id).update({'isFavorite': isFavorite});
  }

  // ── Files ─────────────────────────────────────────────────────────────────

  @override
  Stream<List<Map<String, dynamic>>> watchFiles() {
    return _files
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) =>
            snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList());
  }

  @override
  Future<void> addFile(Map<String, dynamic> metadata) async {
    await _files.add({...metadata, 'createdAt': FieldValue.serverTimestamp()});
  }

  @override
  Future<void> deleteFile(String id) async {
    await _files.doc(id).delete();
  }

  // ── Dead Man's Switch ─────────────────────────────────────────────────────

  /// Called silently every time the app is resumed.
  Future<void> updateLastSeen() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(_uid)
          .collection('dms_config')
          .doc('config')
          .get();
      if (doc.exists && doc.data()?['isEnabled'] == true) {
        await doc.reference.update({'lastSeen': FieldValue.serverTimestamp()});
      }
    } catch (_) {}
  }

  /// Fetches all passwords for PDF generation.
  Future<List<Map<String, dynamic>>> fetchAllPasswords() async {
    final snap = await _passwords.get();
    return snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
  }

  /// Saves DMS config + generates PDF as base64 + stores in Firestore.
  Future<void> saveDmsConfig({
    required String trustedEmail,
    required int intervalDays,
    required List<Map<String, dynamic>> entries,
  }) async {
    final pdfBase64 = await DmsPdfService.generateBase64(entries);

    await FirebaseFirestore.instance
        .collection('users')
        .doc(_uid)
        .collection('dms_config')
        .doc('config')
        .set({
      'trustedEmail': trustedEmail,
      'intervalDays': intervalDays,
      'isEnabled': true,
      'lastSeen': FieldValue.serverTimestamp(),
      'pdfBase64': pdfBase64,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Silently regenerates PDF after every vault change.
  Future<void> refreshDmsPdf(List<Map<String, dynamic>> entries) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(_uid)
          .collection('dms_config')
          .doc('config')
          .get();
      if (!doc.exists || doc.data()?['isEnabled'] != true) return;
      final pdfBase64 = await DmsPdfService.generateBase64(entries);
      await doc.reference.update({'pdfBase64': pdfBase64});
    } catch (_) {}
  }

  // ── Categories ────────────────────────────────────────────────────────────

  @override
  Stream<List<String>> watchCustomCategories() {
    return _userDoc.snapshots().map((doc) {
      final data = doc.data();
      if (data == null) return <String>[];
      return List<String>.from(data['${_prefix}customCategories'] ?? []);
    });
  }

  @override
  Future<void> addCustomCategory(String name) async {
    await _userDoc.set(
      {'${_prefix}customCategories': FieldValue.arrayUnion([name])},
      SetOptions(merge: true),
    );
  }

  @override
  Future<void> deleteCustomCategory(String name) async {
    await _userDoc.update({
      '${_prefix}customCategories': FieldValue.arrayRemove([name])
    });
  }

  // ── Shared ────────────────────────────────────────────────────────────────

  @override
  Future<void> dispose() async {}
}
