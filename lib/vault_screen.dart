import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'add_password_screen.dart';
import 'add_note_screen.dart';
import 'add_file_screen.dart';
import 'file_viewer_screen.dart';
import 'secure_file_service.dart';
import 'main.dart';
import 'settings_screen.dart';
import 'encryption_helper.dart';
import 'totp_screen.dart';
import 'vault_repository.dart';
import 'local_vault_repo.dart';
import 'offline_auth_manager.dart';
import 'mode_picker_screen.dart';
import 'vault_constants.dart';
import 'password_generator_screen.dart';
import 'hibp_service.dart';
import 'firestore_vault_repo.dart';
import 'services/dms_pdf_service.dart';

enum _VaultFilter { all, passwords, notes, files, favorites }

// ─── Grade model ──────────────────────────────────────────────────────────────

class _SecurityGrade {
  final String label;
  final Color  color;
  const _SecurityGrade(this.label, this.color);
}

_SecurityGrade _gradeFromScore(int score) {
  if (score <= 20) return const _SecurityGrade('COMPROMISED', Color(0xFFEF5350));
  if (score <= 40) return const _SecurityGrade('AT RISK',     Color(0xFFFF7043));
  if (score <= 60) return const _SecurityGrade('MODERATE',    Color(0xFFFFA726));
  if (score <= 80) return const _SecurityGrade('STRONG',      Color(0xFF26C6DA));
  return             const _SecurityGrade('ELITE',         Color(0xFF3D5AFE));
}

// ─── Password scorer ──────────────────────────────────────────────────────────

int _scorePassword(String p) {
  if (p.isEmpty) return 0;
  int s = 0;
  if (p.length >= 8)  s++;
  if (p.length >= 14) s++;
  if (p.contains(RegExp(r'[A-Z]')) && p.contains(RegExp(r'[a-z]'))) s++;
  if (p.contains(RegExp(r'[0-9]'))) s++;
  if (p.contains(RegExp(r'[!@#\$%^&*(),.?":{}|<>_\-\\\/\[\]~`+=;]'))) s++;
  return s.clamp(0, 4);
}

// ─── Health analysis ──────────────────────────────────────────────────────────

class _VaultHealth {
  final int score;
  final List<String> weakTitles;
  final List<String> dupeTitles;
  final List<String> oldTitles;
  final int total;

  const _VaultHealth({
    required this.score,
    required this.weakTitles,
    required this.dupeTitles,
    required this.oldTitles,
    required this.total,
  });
}

_VaultHealth _analyzePasswords(List<Map<String, dynamic>> passwords) {
  if (passwords.isEmpty) {
    return const _VaultHealth(
        score: 100, weakTitles: [], dupeTitles: [], oldTitles: [], total: 0);
  }

  final weakTitles = <String>[];
  final oldTitles  = <String>[];
  final seen       = <String, List<String>>{}; // decrypted → titles
  final now        = DateTime.now();

  for (final p in passwords) {
    final title     = p['title']?.toString() ?? 'Untitled';
    final encrypted = p['password']?.toString() ?? '';

    // ── Weak check ──────────────────────────────────────────────────────────
    int strength = p['passwordStrength'] as int? ?? -1;
    if (strength == -1) {
      try {
        final decrypted = EncryptionHelper.decrypt(encrypted, keyOverride: null);
        strength = _scorePassword(decrypted);
      } catch (_) {
        strength = 0;
      }
    }
    if (strength > 0 && strength <= 2) weakTitles.add(title);

    // ── Old check ───────────────────────────────────────────────────────────
    final createdAt = p['createdAt'];
    DateTime? created;
    if (createdAt is Timestamp) {
      created = createdAt.toDate();
    } else if (createdAt != null) {
      try { created = DateTime.parse(createdAt.toString()); } catch (_) {}
    }
    if (created != null && now.difference(created).inDays > 90) {
      oldTitles.add(title);
    }

    // ── Duplicate check (compare decrypted plaintext) ───────────────────────
    try {
      final decrypted = EncryptionHelper.decrypt(encrypted, keyOverride: null);
      seen.putIfAbsent(decrypted, () => []).add(title);
    } catch (_) {
      seen.putIfAbsent(encrypted, () => []).add(title);
    }
  }

  final dupeTitles = seen.entries
      .where((e) => e.value.length > 1)
      .expand((e) => e.value)
      .toList();

  int score = 100;
  score -= weakTitles.length * 10;
  score -= dupeTitles.length * 8;
  score -= oldTitles.length  * 5;
  score  = score.clamp(0, 100);

  return _VaultHealth(
    score:      score,
    weakTitles: weakTitles,
    dupeTitles: dupeTitles,
    oldTitles:  oldTitles,
    total:      passwords.length,
  );
}

// ─── VaultScreen ──────────────────────────────────────────────────────────────

class VaultScreen extends StatefulWidget {
  final bool isDarkMode;
  final Function(bool) onThemeToggle;
  final VaultRepository repo;
  final bool isOfflineMode;

  /// True when the vault was opened via the Panic PIN.
  /// Shows the decoy vault — visually identical but uses a separate data store.
  final bool isPanicMode;

  const VaultScreen({
    super.key,
    this.isDarkMode = false,
    required this.onThemeToggle,
    required this.repo,
    required this.isOfflineMode,
    this.isPanicMode = false,
  });

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  late bool _isDarkMode;
  int  _selectedTab = 0;
  bool _repoReady   = false;

  _VaultFilter _activeFilter         = _VaultFilter.all;
  String       _activeCategoryFilter = '';

  final _searchCtrl = TextEditingController();
  String _searchQuery  = '';
  bool   _searchActive = false;

  bool   _clipboardAutoClear    = true;
  int    _clipboardClearSeconds = 30;
  Timer? _clipboardTimer;

  @override
  void initState() {
    super.initState();
    _isDarkMode = widget.isDarkMode;
    _initRepo();
    _loadClipboardSettings();
  }

  Future<void> _initRepo() async {
    if (widget.repo is LocalVaultRepo) {
      await (widget.repo as LocalVaultRepo).init();
    }
    if (mounted) setState(() => _repoReady = true);
  }

  Future<void> _loadClipboardSettings() async {
    const storage = FlutterSecureStorage();
    final autoClear = await storage.read(key: VaultKeys.clipboardAutoClear);
    final seconds   = await storage.read(key: VaultKeys.clipboardClearSeconds);
    if (mounted) {
      setState(() {
        _clipboardAutoClear    = autoClear != 'false';
        _clipboardClearSeconds = int.tryParse(seconds ?? '30') ?? 30;
      });
    }
  }

  void _scheduleClearClipboard() {
    if (!_clipboardAutoClear) return;
    _clipboardTimer?.cancel();
    _clipboardTimer = Timer(Duration(seconds: _clipboardClearSeconds), () {
      Clipboard.setData(const ClipboardData(text: ''));
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _clipboardTimer?.cancel();
    widget.repo.dispose();
    super.dispose();
  }

  // ─── Theme ────────────────────────────────────────────────────────────────

  Color get bgColor       => _isDarkMode ? const Color(0xFF10131A) : const Color(0xFFF0F2F5);
  Color get cardColor     => _isDarkMode ? const Color(0xFF1E2130) : Colors.white;
  Color get listCardColor => _isDarkMode ? const Color(0xFF272A32) : Colors.white;
  Color get textPrimary   => _isDarkMode ? Colors.white            : const Color(0xFF1A237E);
  Color get textSecondary => _isDarkMode ? const Color(0xFFC6C6CC) : Colors.grey;
  Color get accentColor   => const Color(0xFF3D5AFE);

  Uint8List? get _encKeyOverride =>
      widget.isOfflineMode ? OfflineAuthManager().sessionKey : null;

  // ─── Actions ──────────────────────────────────────────────────────────────

  void _logout() async {
    _clipboardTimer?.cancel();
    if (widget.isPanicMode) {
      // In panic mode, "logout" just returns to the login screen without
      // touching real auth — the real vault remains intact.
      EncryptionHelper.clearCloudKey();
      await FirebaseAuth.instance.signOut();
      await GoogleSignIn().signOut();
      const storage = FlutterSecureStorage();
      await storage.delete(key: VaultKeys.modePickerDone);
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const ModePickerScreen()),
          (route) => false,
        );
      }
      return;
    }
    EncryptionHelper.clearCloudKey();
    await OfflineAuthManager().deleteOfflineUser();
    await FirebaseAuth.instance.signOut();
    await GoogleSignIn().signOut();
    const storage = FlutterSecureStorage();
    await storage.delete(key: VaultKeys.modePickerDone);
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const ModePickerScreen()),
            (route) => false,
      );
    }
  }

  void _toggleSearch() {
    setState(() {
      _searchActive = !_searchActive;
      if (!_searchActive) { _searchCtrl.clear(); _searchQuery = ''; }
    });
  }

  // ─── FAB menu ─────────────────────────────────────────────────────────────

  void _showAddMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 4,
                decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 20),
            Text('Add new entry',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textPrimary)),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(child: _addMenuTile(
                icon: Icons.lock_outline, label: 'Password', sub: 'Login credentials',
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => AddPasswordScreen(
                      repo: widget.repo, isOfflineMode: widget.isOfflineMode, isDarkMode: _isDarkMode)));
                },
              )),
              const SizedBox(width: 12),
              Expanded(child: _addMenuTile(
                icon: Icons.note_outlined, label: 'Secure Note', sub: 'Encrypted text',
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => AddNoteScreen(
                      repo: widget.repo, isOfflineMode: widget.isOfflineMode, isDarkMode: _isDarkMode)));
                },
              )),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _addMenuTile(
                icon: Icons.lock_person_outlined, label: 'Secure File', sub: 'Encrypted file',
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => AddFileScreen(
                      repo: widget.repo)));
                },
              )),
              const SizedBox(width: 12),
              Expanded(child: const SizedBox()),
            ]),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _addMenuTile({required IconData icon, required String label,
    required String sub, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        decoration: BoxDecoration(
          color: accentColor.withOpacity(0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accentColor.withOpacity(0.2)),
        ),
        child: Column(children: [
          Icon(icon, color: accentColor, size: 28),
          const SizedBox(height: 10),
          Text(label, style: TextStyle(color: textPrimary, fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 2),
          Text(sub, style: TextStyle(color: textSecondary, fontSize: 11)),
        ]),
      ),
    );
  }

  // ─── Delete dialogs ───────────────────────────────────────────────────────

  void _confirmDeletePassword(BuildContext context, String docId, String title) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete Password'),
      content: Text('Delete "$title"?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(
          onPressed: () async {
            Navigator.pop(ctx);
            await widget.repo.deletePassword(docId);
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Password deleted'), backgroundColor: Colors.red,
                behavior: SnackBarBehavior.floating));
            // ── DMS: keep PDF export current after deletion ────────────────
            if (!widget.isPanicMode && !widget.isOfflineMode) {
              _triggerDmsRefresh();
            }
          },
          child: const Text('Delete', style: TextStyle(color: Colors.red)),
        ),
      ],
    ));
  }

  void _confirmDeleteNote(BuildContext context, String docId, String title) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete Note'),
      content: Text('Delete "$title"?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(
          onPressed: () async {
            Navigator.pop(ctx);
            await widget.repo.deleteNote(docId);
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Note deleted'), backgroundColor: Colors.red,
                behavior: SnackBarBehavior.floating));
            // ── DMS: keep PDF export current after deletion ────────────────
            if (!widget.isPanicMode && !widget.isOfflineMode) {
              _triggerDmsRefresh();
            }
          },
          child: const Text('Delete', style: TextStyle(color: Colors.red)),
        ),
      ],
    ));
  }

  // ─── Dead Man's Switch helpers ───────────────────────────────────────────

  /// Silently regenerates and re-uploads the DMS PDF export.
  /// Fire-and-forget — never awaited so it never blocks the UI.
  /// Only runs in cloud mode on the real vault (not panic/decoy, not offline).
  void _triggerDmsRefresh() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final repo = FirestoreVaultRepo(uid: uid);
    // Fetch latest entries then regenerate PDF — all in background
    repo.fetchAllPasswords().then((entries) {
      repo.refreshDmsPdf(entries);
    }).catchError((_) {
      // Silently swallow — DMS refresh is best-effort, never critical path
    });
  }

  // ─── Health detail sheet ──────────────────────────────────────────────────

  void _showHealthDetail(_VaultHealth health, _SecurityGrade grade) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scrollCtrl) => Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: ListView(
            controller: scrollCtrl,
            padding: const EdgeInsets.all(24),
            children: [
              Center(child: Container(width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 20),
              Row(children: [
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    color: grade.color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.shield_rounded, color: grade.color, size: 24),
                ),
                const SizedBox(width: 14),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Vault Health Report',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textPrimary)),
                  Text('${health.total} password${health.total == 1 ? '' : 's'} analyzed',
                      style: TextStyle(fontSize: 12, color: textSecondary)),
                ]),
              ]),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: grade.color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: grade.color.withOpacity(0.3)),
                ),
                child: Row(children: [
                  Text(grade.label,
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900,
                          color: grade.color, letterSpacing: 1.5)),
                  const Spacer(),
                  Text(
                    health.weakTitles.isEmpty && health.dupeTitles.isEmpty && health.oldTitles.isEmpty
                        ? 'No issues found'
                        : '${health.weakTitles.length + health.dupeTitles.length + health.oldTitles.length} issue(s)',
                    style: TextStyle(fontSize: 12, color: grade.color.withOpacity(0.8)),
                  ),
                ]),
              ),
              const SizedBox(height: 20),
              _healthSection(
                icon: Icons.lock_open_rounded, color: const Color(0xFFEF5350),
                title: 'Weak passwords', items: health.weakTitles,
                emptyMsg: 'All passwords are strong',
              ),
              const SizedBox(height: 16),
              _healthSection(
                icon: Icons.copy_rounded, color: const Color(0xFFFF9800),
                title: 'Duplicate passwords', items: health.dupeTitles,
                emptyMsg: 'No duplicates found',
              ),
              const SizedBox(height: 16),
              _healthSection(
                icon: Icons.schedule_rounded, color: const Color(0xFF42A5F5),
                title: 'Passwords older than 90 days', items: health.oldTitles,
                emptyMsg: 'All passwords are recent',
              ),
              const SizedBox(height: 16),
              if (health.weakTitles.isNotEmpty || health.dupeTitles.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: accentColor.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: accentColor.withOpacity(0.2)),
                  ),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.tips_and_updates_outlined, color: accentColor, size: 18),
                    const SizedBox(width: 10),
                    Expanded(child: Text(
                      'Use the Generator tab to create strong unique passwords for flagged entries.',
                      style: TextStyle(fontSize: 12, color: textSecondary, height: 1.5),
                    )),
                  ]),
                ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _healthSection({
    required IconData icon, required Color color,
    required String title, required List<String> items, required String emptyMsg,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 8),
        Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: textPrimary)),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: items.isEmpty ? Colors.green.withOpacity(0.1) : color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text('${items.length}',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                  color: items.isEmpty ? Colors.green : color)),
        ),
      ]),
      const SizedBox(height: 8),
      if (items.isEmpty)
        Text(emptyMsg, style: TextStyle(fontSize: 12, color: textSecondary))
      else
        ...items.map((name) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            Container(width: 6, height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 10),
            Text(name, style: TextStyle(fontSize: 13, color: textPrimary)),
          ]),
        )),
    ]);
  }

  // ─── Password detail sheet ────────────────────────────────────────────────

  void _showPasswordDetail(BuildContext context, Map<String, dynamic> data, String docId) {
    bool obscure      = true;
    bool isFav        = data['isFavorite'] == true;
    bool hibpChecking = false;
    int  hibpCount    = -1; // -1 = not checked, 0 = safe, >0 = pwned

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 20),
              Row(children: [
                Expanded(child: Text(data['title'] ?? '',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: textPrimary))),
                IconButton(
                  icon: Icon(isFav ? Icons.star_rounded : Icons.star_border_rounded,
                      color: isFav ? Colors.amber : textSecondary),
                  onPressed: () async {
                    await widget.repo.togglePasswordFavorite(docId, !isFav);
                    setModal(() => isFav = !isFav);
                  },
                ),
              ]),
              if ((data['category'] ?? '').isNotEmpty) ...[
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                      color: accentColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20)),
                  child: Text(data['category'],
                      style: TextStyle(fontSize: 11, color: accentColor,
                          fontWeight: FontWeight.w500)),
                ),
              ],
              const SizedBox(height: 20),
              if ((data['username'] ?? '').isNotEmpty) ...[
                Text('Username / Email', style: TextStyle(fontSize: 12, color: textSecondary)),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(child: Text(data['username'],
                      style: TextStyle(fontSize: 16, color: textPrimary))),
                  IconButton(
                    icon: Icon(Icons.copy, color: accentColor, size: 20),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: data['username']));
                      _scheduleClearClipboard();
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(_clipboardAutoClear
                            ? 'Username copied! Clears in ${_clipboardClearSeconds}s'
                            : 'Username copied!'),
                        behavior: SnackBarBehavior.floating,
                      ));
                    },
                  ),
                ]),
                const SizedBox(height: 16),
              ],
              Text('Password', style: TextStyle(fontSize: 12, color: textSecondary)),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(child: Text(
                  obscure ? '••••••••••••' : EncryptionHelper.decrypt(
                      data['password'] ?? '', keyOverride: _encKeyOverride),
                  style: TextStyle(fontSize: 16, color: textPrimary),
                )),
                IconButton(
                  icon: Icon(obscure ? Icons.visibility_off : Icons.visibility,
                      color: accentColor, size: 20),
                  onPressed: () => setModal(() => obscure = !obscure),
                ),
                IconButton(
                  icon: Icon(Icons.copy, color: accentColor, size: 20),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: EncryptionHelper.decrypt(
                        data['password'] ?? '', keyOverride: _encKeyOverride)));
                    _scheduleClearClipboard();
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(_clipboardAutoClear
                          ? 'Password copied! Clears in ${_clipboardClearSeconds}s'
                          : 'Password copied!'),
                      behavior: SnackBarBehavior.floating,
                    ));
                    Navigator.pop(ctx);
                  },
                ),
              ]),
              const SizedBox(height: 16),

              // ── HIBP Check ────────────────────────────────────────────────
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: hibpChecking ? null : () async {
                      setModal(() => hibpChecking = true);
                      final decrypted = EncryptionHelper.decrypt(
                          data['password'] ?? '', keyOverride: _encKeyOverride);
                      final count = await HibpService.checkPassword(decrypted);
                      setModal(() {
                        hibpChecking = false;
                        hibpCount = count;
                      });
                      if (context.mounted) {
                        if (count > 0) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(
                                'Found in $count breach${count == 1 ? '' : 'es'}! Change this password.'),
                            backgroundColor: Colors.red,
                            behavior: SnackBarBehavior.floating,
                            duration: const Duration(seconds: 5),
                          ));
                        } else if (count == 0) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text('Not found in any known breaches.'),
                            backgroundColor: Colors.green,
                            behavior: SnackBarBehavior.floating,
                          ));
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text('Could not check — check your internet connection.'),
                            backgroundColor: Colors.orange,
                            behavior: SnackBarBehavior.floating,
                          ));
                        }
                      }
                    },
                    icon: hibpChecking
                        ? const SizedBox(height: 16, width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.security_outlined, size: 18),
                    label: Text(hibpChecking ? 'Checking...' : 'Check for Breaches'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: accentColor,
                      side: BorderSide(color: accentColor.withOpacity(0.4)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                // Badge after check
                if (hibpCount >= 0) ...[
                  const SizedBox(width: 10),
                  Builder(builder: (_) {
                    final safe  = hibpCount == 0;
                    final color = safe ? Colors.green : Colors.red;
                    final icon  = safe ? Icons.verified_user_outlined : Icons.gpp_bad_outlined;
                    final label = safe ? 'Safe' : 'Pwned ${hibpCount}×';
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: color.withOpacity(0.4)),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(icon, color: color, size: 16),
                        const SizedBox(width: 4),
                        Text(label, style: TextStyle(color: color, fontSize: 12,
                            fontWeight: FontWeight.w600)),
                      ]),
                    );
                  }),
                ],
              ]),
              // ─────────────────────────────────────────────────────────────

              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity, height: 50,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _confirmDeletePassword(context, docId, data['title']);
                  },
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  label: const Text('Delete Password', style: TextStyle(color: Colors.red)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.red),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Note detail sheet ────────────────────────────────────────────────────

  void _showNoteDetail(BuildContext context, Map<String, dynamic> data, String docId) {
    bool isFav = data['isFavorite'] == true;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.4,
          maxChildSize: 0.92,
          expand: false,
          builder: (_, scrollCtrl) => Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: ListView(
              controller: scrollCtrl,
              children: [
                Center(child: Container(width: 40, height: 4,
                    decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(2)))),
                const SizedBox(height: 20),
                Row(children: [
                  Expanded(child: Text(data['title'] ?? '',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: textPrimary))),
                  IconButton(
                    icon: Icon(isFav ? Icons.star_rounded : Icons.star_border_rounded,
                        color: isFav ? Colors.amber : textSecondary),
                    onPressed: () async {
                      await widget.repo.toggleNoteFavorite(docId, !isFav);
                      setModal(() => isFav = !isFav);
                    },
                  ),
                ]),
                if ((data['category'] ?? '').isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                        color: Colors.teal.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20)),
                    child: Text(data['category'],
                        style: const TextStyle(fontSize: 11, color: Colors.teal,
                            fontWeight: FontWeight.w500)),
                  ),
                ],
                const SizedBox(height: 20),
                Text('Note content', style: TextStyle(fontSize: 12, color: textSecondary)),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _isDarkMode ? const Color(0xFF141720) : const Color(0xFFF7F8FC),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    EncryptionHelper.decrypt(data['body'] ?? '', keyOverride: _encKeyOverride),
                    style: TextStyle(fontSize: 15, color: textPrimary, height: 1.6),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 50,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _confirmDeleteNote(context, docId, data['title']);
                    },
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    label: const Text('Delete Note', style: TextStyle(color: Colors.red)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_repoReady) {
      return Scaffold(
        backgroundColor: bgColor,
        body: Center(child: CircularProgressIndicator(color: accentColor)),
      );
    }
    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            _buildSearchBar(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 16),
                    _buildHeroCard(),
                    const SizedBox(height: 20),
                    _buildFilterChips(),
                    const SizedBox(height: 16),
                    _buildVaultList(),
                    const SizedBox(height: 100),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddMenu,
        backgroundColor: accentColor,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  // ─── Hero card ────────────────────────────────────────────────────────────

  Widget _buildHeroCard() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: widget.repo.watchPasswords(),
      builder: (context, snapshot) {
        final passwords  = snapshot.data ?? [];
        final count      = passwords.length;
        final health     = _analyzePasswords(passwords);
        final grade      = _gradeFromScore(health.score);
        final issueCount = health.weakTitles.length +
            health.dupeTitles.length + health.oldTitles.length;

        return GestureDetector(
          onTap: () => _showHealthDetail(health, grade),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: grade.color,
              boxShadow: [BoxShadow(
                color: grade.color.withOpacity(0.45),
                blurRadius: 20, offset: const Offset(0, 8),
              )],
            ),
            child: Stack(children: [
              Positioned(
                right: -10, top: -10,
                child: Icon(Icons.shield_rounded, size: 100,
                    color: Colors.white.withOpacity(0.15)),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('CURRENT SECURITY POSTURE',
                    style: TextStyle(fontSize: 11, color: Colors.white70, letterSpacing: 1.5)),
                const SizedBox(height: 6),
                Text(grade.label,
                    style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w900,
                        color: Colors.white, letterSpacing: 2)),
                const SizedBox(height: 16),
                Text('$count password${count == 1 ? '' : 's'} stored',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold,
                        color: Colors.white)),
                const SizedBox(height: 4),
                Row(children: [
                  Expanded(child: Text(
                    widget.isOfflineMode ? 'Local encrypted storage' : 'All systems encrypted',
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  )),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(
                        issueCount == 0 ? 'All clear' : '$issueCount issue${issueCount == 1 ? '' : 's'}',
                        style: const TextStyle(fontSize: 11, color: Colors.white,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right, color: Colors.white, size: 14),
                    ]),
                  ),
                ]),
              ]),
            ]),
          ),
        );
      },
    );
  }

  // ─── Filter chips ─────────────────────────────────────────────────────────

  Widget _buildFilterChips() {
    return StreamBuilder<List<String>>(
      stream: widget.repo.watchCustomCategories(),
      builder: (context, snapshot) {
        final custom        = snapshot.data ?? [];
        final allCategories = [...VaultCategories.fixed, ...custom];
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            _filterChip('All', _activeFilter == _VaultFilter.all && _activeCategoryFilter.isEmpty,
                onTap: () => setState(() { _activeFilter = _VaultFilter.all; _activeCategoryFilter = ''; })),
            const SizedBox(width: 8),
            _filterChip('Passwords', _activeFilter == _VaultFilter.passwords && _activeCategoryFilter.isEmpty,
                icon: Icons.lock_outline,
                onTap: () => setState(() { _activeFilter = _VaultFilter.passwords; _activeCategoryFilter = ''; })),
            const SizedBox(width: 8),
            _filterChip('Notes', _activeFilter == _VaultFilter.notes && _activeCategoryFilter.isEmpty,
                icon: Icons.note_outlined,
                onTap: () => setState(() { _activeFilter = _VaultFilter.notes; _activeCategoryFilter = ''; })),
            const SizedBox(width: 8),
            _filterChip('Files', _activeFilter == _VaultFilter.files && _activeCategoryFilter.isEmpty,
                icon: Icons.lock_person_outlined,
                activeColor: Colors.deepPurple,
                onTap: () => setState(() { _activeFilter = _VaultFilter.files; _activeCategoryFilter = ''; })),
            const SizedBox(width: 8),
            _filterChip('Favorites', _activeFilter == _VaultFilter.favorites && _activeCategoryFilter.isEmpty,
                icon: Icons.star_rounded,
                activeColor: Colors.amber,
                onTap: () => setState(() { _activeFilter = _VaultFilter.favorites; _activeCategoryFilter = ''; })),
            const SizedBox(width: 8),
            Container(width: 1, height: 20, color: textSecondary.withOpacity(0.2)),
            const SizedBox(width: 8),
            ...allCategories.map((cat) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _filterChip(cat, _activeCategoryFilter == cat,
                  activeColor: Colors.teal,
                  onTap: () => setState(() {
                    _activeCategoryFilter = _activeCategoryFilter == cat ? '' : cat;
                    _activeFilter = _VaultFilter.all;
                  })),
            )),
          ]),
        );
      },
    );
  }

  Widget _filterChip(String label, bool active,
      {IconData? icon, Color? activeColor, required VoidCallback onTap}) {
    final color = activeColor ?? accentColor;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active ? color.withOpacity(0.15) : (_isDarkMode ? const Color(0xFF1E2130) : Colors.white),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: active ? color : (_isDarkMode ? const Color(0xFF252A38) : const Color(0xFFDDE1F0))),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: active ? color : textSecondary),
            const SizedBox(width: 4),
          ],
          Text(label, style: TextStyle(fontSize: 12,
              fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              color: active ? color : textSecondary)),
        ]),
      ),
    );
  }

  // ─── Mixed vault list ─────────────────────────────────────────────────────

  Widget _buildVaultList() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: widget.repo.watchPasswords(),
      builder: (context, pwSnap) {
        return StreamBuilder<List<Map<String, dynamic>>>(
          stream: widget.repo.watchNotes(),
          builder: (context, noteSnap) {
            return StreamBuilder<List<Map<String, dynamic>>>(
              stream: widget.repo.watchFiles(),
              builder: (context, fileSnap) {
                if (pwSnap.connectionState == ConnectionState.waiting ||
                    noteSnap.connectionState == ConnectionState.waiting ||
                    fileSnap.connectionState == ConnectionState.waiting) {
                  return Center(child: CircularProgressIndicator(color: accentColor));
                }

                final passwords = (pwSnap.data ?? []).map((d) => {...d, '_type': 'password'}).toList();
                final notes     = (noteSnap.data ?? []).map((d) => {...d, '_type': 'note'}).toList();
                final files     = (fileSnap.data ?? []).map((d) => {...d, '_type': 'file'}).toList();
                final all       = [...passwords, ...notes, ...files];

                all.sort((a, b) {
                  final ta = a['createdAt']; final tb = b['createdAt'];
                  if (ta == null && tb == null) return 0;
                  if (ta == null) return 1;
                  if (tb == null) return -1;
                  return tb.compareTo(ta);
                });

                List<Map<String, dynamic>> filtered = all;
                if (_activeFilter == _VaultFilter.passwords) {
                  filtered = all.where((d) => d['_type'] == 'password').toList();
                } else if (_activeFilter == _VaultFilter.notes) {
                  filtered = all.where((d) => d['_type'] == 'note').toList();
                } else if (_activeFilter == _VaultFilter.files) {
                  filtered = all.where((d) => d['_type'] == 'file').toList();
                } else if (_activeFilter == _VaultFilter.favorites) {
                  filtered = all.where((d) => d['isFavorite'] == true).toList();
                }

                if (_activeCategoryFilter.isNotEmpty) {
                  filtered = filtered.where((d) => d['category'] == _activeCategoryFilter).toList();
                }

                if (_searchQuery.isNotEmpty) {
                  filtered = filtered.where((d) {
                    final title = d['_type'] == 'file'
                        ? (d['fileName'] ?? '')
                        : (d['title'] ?? '');
                    return title.toString().toLowerCase().contains(_searchQuery);
                  }).toList();
                }

                if (filtered.isEmpty) {
                  return Container(
                    padding: const EdgeInsets.all(40),
                    decoration: BoxDecoration(color: listCardColor, borderRadius: BorderRadius.circular(16)),
                    child: Center(child: Column(children: [
                      Icon(Icons.lock_open_rounded, size: 48, color: textSecondary),
                      const SizedBox(height: 12),
                      Text(_searchQuery.isNotEmpty ? 'No results found' : 'Nothing here yet',
                          style: TextStyle(color: textSecondary, fontSize: 16)),
                      const SizedBox(height: 4),
                      Text('Tap + to add a password, note or file',
                          style: TextStyle(color: textSecondary.withOpacity(0.6), fontSize: 13)),
                    ])),
                  );
                }

                return Container(
                  decoration: BoxDecoration(
                    color: listCardColor,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [BoxShadow(
                      color: Colors.black.withOpacity(_isDarkMode ? 0.3 : 0.06),
                      blurRadius: 12, offset: const Offset(0, 4),
                    )],
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => Divider(height: 1,
                        color: _isDarkMode
                            ? Colors.white.withOpacity(0.05)
                            : Colors.grey.withOpacity(0.15)),
                    itemBuilder: (context, index) {
                      final item   = filtered[index];
                      final type   = item['_type'] as String;
                      final isNote = type == 'note';
                      final isFile = type == 'file';
                      final id     = item['id'] as String;

                      if (isFile) return _buildFileListTile(item, id);

                      final title  = item['title'] ?? 'Untitled';
                      final sub    = isNote ? (item['category'] ?? 'Note') : (item['username'] ?? '');
                      final isFav  = item['isFavorite'] == true;

                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        leading: Container(
                          width: 44, height: 44,
                          decoration: BoxDecoration(
                            color: isNote
                                ? Colors.teal.withOpacity(0.15)
                                : accentColor.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(isNote ? Icons.note_outlined : Icons.lock_outline,
                              color: isNote ? Colors.teal : accentColor, size: 22),
                        ),
                        title: Text(title.toString(),
                            style: TextStyle(fontWeight: FontWeight.w600, color: textPrimary, fontSize: 15)),
                        subtitle: Text(sub.isNotEmpty ? sub : (isNote ? 'Note' : 'No username'),
                            style: TextStyle(color: textSecondary, fontSize: 12)),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          if (isFav) Icon(Icons.star_rounded, color: Colors.amber, size: 16),
                          const SizedBox(width: 4),
                          Icon(Icons.chevron_right, color: textSecondary, size: 20),
                        ]),
                        onTap: () => isNote
                            ? _showNoteDetail(context, item, id)
                            : _showPasswordDetail(context, item, id),
                      );
                    },
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildFileListTile(Map<String, dynamic> item, String id) {
    final fileName = item['fileName'] as String? ?? 'Unknown file';
    final fileType = item['fileType'] as String? ?? 'other';
    final fileSize = item['fileSize'] as int? ?? 0;

    final IconData fileIcon;
    final Color fileColor;
    switch (fileType) {
      case 'image':
        fileIcon  = Icons.image_rounded;
        fileColor = Colors.blue;
        break;
      case 'pdf':
        fileIcon  = Icons.picture_as_pdf_rounded;
        fileColor = Colors.deepOrange;
        break;
      default:
        fileIcon  = Icons.insert_drive_file_rounded;
        fileColor = Colors.blueGrey;
    }

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: Container(
        width: 44, height: 44,
        decoration: BoxDecoration(
          color: fileColor.withOpacity(0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(fileIcon, color: fileColor, size: 22),
      ),
      title: Text(
        fileName,
        style: TextStyle(fontWeight: FontWeight.w600, color: textPrimary, fontSize: 15),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${fileType.toUpperCase()} · ${SecureFileService.formatFileSize(fileSize)}',
        style: TextStyle(color: textSecondary, fontSize: 12),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: fileColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_rounded, size: 10, color: fileColor),
            const SizedBox(width: 4),
            Text('encrypted', style: TextStyle(fontSize: 10, color: fileColor,
                fontWeight: FontWeight.w500)),
          ]),
        ),
        const SizedBox(width: 4),
        Icon(Icons.chevron_right, color: textSecondary, size: 20),
      ]),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => FileViewerScreen(
          fileMeta: item,
          repo: widget.repo,
        )),
      ),
    );
  }

  // ─── Top bar ──────────────────────────────────────────────────────────────

  Widget _buildTopBar() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(children: [
                Icon(Icons.lock_rounded, color: accentColor, size: 22),
                const SizedBox(width: 8),
                Text('THE VAULT', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold,
                    color: textPrimary, letterSpacing: 2)),
                if (widget.isOfflineMode) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.orange.shade300),
                    ),
                    child: const Text('OFFLINE', style: TextStyle(fontSize: 10,
                        fontWeight: FontWeight.bold, color: Colors.orange, letterSpacing: 1)),
                  ),
                ],
              ]),
              Row(children: [
                GestureDetector(
                  onTap: _toggleSearch,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: _searchActive
                          ? accentColor.withOpacity(0.18)
                          : accentColor.withOpacity(0.08),
                      border: Border.all(
                          color: _searchActive ? accentColor.withOpacity(0.6) : Colors.transparent,
                          width: 1.5),
                    ),
                    child: Icon(_searchActive ? Icons.search_off_rounded : Icons.search_rounded,
                        size: 18, color: _searchActive ? accentColor : textSecondary),
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: () {
                    setState(() => _isDarkMode = !_isDarkMode);
                    widget.onThemeToggle(_isDarkMode);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    width: 52, height: 28,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: _isDarkMode ? accentColor : Colors.grey.shade300,
                    ),
                    child: AnimatedAlign(
                      duration: const Duration(milliseconds: 300),
                      alignment: _isDarkMode ? Alignment.centerRight : Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: Icon(_isDarkMode ? Icons.dark_mode : Icons.light_mode,
                            size: 20, color: _isDarkMode ? Colors.white : Colors.orange),
                      ),
                    ),
                  ),
                ),
              ]),
            ],
          ),
        ),
        // ── Panic Mode decoy banner — only visible during a panic session ──
        // This is intentionally NOT shown to the coercer. It is only visible
        // in this source code. The banner is omitted on purpose so the UI
        // looks completely normal. If you want a subtle reminder for testing,
        // uncomment the block below.
        //
        // if (widget.isPanicMode)
        //   Container(
        //     color: Colors.deepOrange.shade900,
        //     padding: const EdgeInsets.symmetric(vertical: 4),
        //     child: const Center(child: Text('DECOY VAULT',
        //         style: TextStyle(color: Colors.white, fontSize: 11,
        //             fontWeight: FontWeight.bold, letterSpacing: 2))),
        //   ),
      ],
    );
  }

  Widget _buildSearchBar() {
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      child: _searchActive
          ? Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: TextField(
          controller: _searchCtrl,
          autofocus: true,
          onChanged: (v) => setState(() => _searchQuery = v.toLowerCase().trim()),
          style: TextStyle(fontSize: 14, color: textPrimary),
          decoration: InputDecoration(
            hintText: 'Search by title…',
            hintStyle: TextStyle(fontSize: 14, color: textSecondary),
            prefixIcon: Icon(Icons.search_rounded, color: accentColor, size: 20),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
              icon: Icon(Icons.close_rounded, color: textSecondary, size: 18),
              onPressed: () => setState(() { _searchCtrl.clear(); _searchQuery = ''; }),
            )
                : null,
            filled: true, fillColor: cardColor,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: accentColor, width: 1.5)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                    color: _isDarkMode
                        ? Colors.white.withOpacity(0.06)
                        : Colors.grey.withOpacity(0.18),
                    width: 1)),
          ),
        ),
      )
          : const SizedBox.shrink(),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: cardColor,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1),
            blurRadius: 10, offset: const Offset(0, -2))],
      ),
      child: BottomNavigationBar(
        currentIndex: _selectedTab,
        type: BottomNavigationBarType.fixed,
        onTap: (i) {
          setState(() => _selectedTab = i);
          if (i == 1) {
            Navigator.push(context, MaterialPageRoute(builder: (_) => TotpScreen(
              isDarkMode: _isDarkMode, isOfflineMode: widget.isOfflineMode,
              offlineKey: widget.isOfflineMode ? _encKeyOverride : null,
            ))).then((_) => setState(() => _selectedTab = 0));
          }
          if (i == 2) {
            Navigator.push(context, MaterialPageRoute(
              builder: (_) => PasswordGeneratorScreen(isDarkMode: _isDarkMode),
            )).then((_) => setState(() => _selectedTab = 0));
          }
          if (i == 3) {
            Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen(
              isDarkMode: _isDarkMode,
              onThemeToggle: (val) {
                setState(() => _isDarkMode = val);
                widget.onThemeToggle(val);
              },
              isOfflineMode: widget.isOfflineMode,
            ))).then((_) {
              setState(() => _selectedTab = 0);
              _loadClipboardSettings();
            });
          }
        },
        backgroundColor: Colors.transparent,
        elevation: 0,
        selectedItemColor: accentColor,
        unselectedItemColor: textSecondary,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.wallet_rounded), label: 'Vault'),
          BottomNavigationBarItem(icon: Icon(Icons.shield_rounded), label: 'Security'),
          BottomNavigationBarItem(icon: Icon(Icons.password_rounded), label: 'Generator'),
          BottomNavigationBarItem(icon: Icon(Icons.settings_rounded), label: 'Settings'),
        ],
      ),
    );
  }
}
