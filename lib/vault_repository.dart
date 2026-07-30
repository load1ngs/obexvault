abstract class VaultRepository {
  // ── Passwords ──────────────────────────────────────────────────────────

  Stream<List<Map<String, dynamic>>> watchPasswords();
  Future<void> addPassword(Map<String, dynamic> data);
  Future<void> deletePassword(String id);
  Future<void> togglePasswordFavorite(String id, bool isFavorite);
  Future<int> getPasswordCount();

  // ── Notes ──────────────────────────────────────────────────────────────

  Stream<List<Map<String, dynamic>>> watchNotes();
  Future<void> addNote(Map<String, dynamic> data);
  Future<void> deleteNote(String id);
  Future<void> toggleNoteFavorite(String id, bool isFavorite);

  // ── Files ───────────────────────────────────────────────────────────────

  /// Returns a stream of file metadata maps. Each map contains:
  /// id, fileName, fileType, fileSize, encryptedPath, createdAt
  Stream<List<Map<String, dynamic>>> watchFiles();
  Future<void> addFile(Map<String, dynamic> metadata);
  Future<void> deleteFile(String id);

  // ── Categories ─────────────────────────────────────────────────────────

  Stream<List<String>> watchCustomCategories();
  Future<void> addCustomCategory(String name);
  Future<void> deleteCustomCategory(String name);

  // ── Shared ─────────────────────────────────────────────────────────────

  Future<void> dispose();
}