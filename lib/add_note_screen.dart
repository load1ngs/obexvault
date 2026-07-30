import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'encryption_helper.dart';
import 'vault_repository.dart';
import 'firestore_vault_repo.dart';
import 'offline_auth_manager.dart';
import 'vault_constants.dart';

class AddNoteScreen extends StatefulWidget {
  final VaultRepository repo;
  final bool isOfflineMode;
  final bool isDarkMode;

  const AddNoteScreen({
    super.key,
    required this.repo,
    required this.isOfflineMode,
    this.isDarkMode = false,
  });

  @override
  State<AddNoteScreen> createState() => _AddNoteScreenState();
}

class _AddNoteScreenState extends State<AddNoteScreen> {
  final _titleController = TextEditingController();
  final _bodyController  = TextEditingController();
  bool _isLoading    = false;
  bool _isFavorite   = false;
  String _category   = 'Personal';

  // ─── Theme helpers ───────────────────────────────────────────────────────

  Color get _bgColor     => widget.isDarkMode ? const Color(0xFF10131A) : const Color(0xFFF0F2F5);
  Color get _cardColor   => widget.isDarkMode ? const Color(0xFF1E2130) : Colors.white;
  Color get _textPrimary => widget.isDarkMode ? Colors.white            : const Color(0xFF1A237E);
  Color get _textHint    => widget.isDarkMode ? const Color(0xFF8892A8) : Colors.grey;
  Color get _accent      => const Color(0xFF3D5AFE);
  Color get _borderColor => widget.isDarkMode ? const Color(0xFF252A38) : const Color(0xFFDDE1F0);
  Color get _focusBorder => const Color(0xFF1A237E);
  Color get _inputFill   => widget.isDarkMode ? const Color(0xFF141720) : Colors.white;

  Uint8List? get _encKeyOverride {
    if (!widget.isOfflineMode) return null;
    return OfflineAuthManager().sessionKey;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  Future<void> _saveNote() async {
    if (_titleController.text.trim().isEmpty || _bodyController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Title and Note body are required'),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    setState(() => _isLoading = true);
    try {
      await widget.repo.addNote({
        'title':      _titleController.text.trim(),
        'body':       EncryptionHelper.encrypt(_bodyController.text, keyOverride: _encKeyOverride),
        'category':   _category,
        'isFavorite': _isFavorite,
      });
      // ── DMS: silently regenerate PDF export so it stays current ───────────
      if (!widget.isOfflineMode) {
        final uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid != null) {
          final dmsRepo = FirestoreVaultRepo(uid: uid);
          dmsRepo.fetchAllPasswords().then((e) => dmsRepo.refreshDmsPdf(e))
              .catchError((_) {});
        }
      }
      // ─────────────────────────────────────────────────────────────────────
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Note saved!'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: _bgColor,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: _textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Add Secure Note',
            style: TextStyle(color: _textPrimary, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: Icon(
              _isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
              color: _isFavorite ? Colors.amber : _textHint,
            ),
            onPressed: () => setState(() => _isFavorite = !_isFavorite),
            tooltip: 'Mark as favourite',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: _cardColor,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(widget.isDarkMode ? 0.3 : 0.06),
                blurRadius: 16, offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Title field
              TextField(
                controller: _titleController,
                style: TextStyle(color: _textPrimary, fontSize: 14),
                decoration: InputDecoration(
                  labelText: 'Note title',
                  labelStyle: TextStyle(color: _textHint, fontSize: 14),
                  prefixIcon: Icon(Icons.note_outlined, color: _accent, size: 20),
                  filled: true, fillColor: _inputFill,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: _borderColor)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: _borderColor)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: _focusBorder, width: 2)),
                ),
              ),
              const SizedBox(height: 16),
              // Category picker
              _buildCategoryPicker(),
              const SizedBox(height: 16),
              // Body field
              TextField(
                controller: _bodyController,
                maxLines: 8,
                style: TextStyle(color: _textPrimary, fontSize: 14),
                decoration: InputDecoration(
                  labelText: 'Note body (will be encrypted)',
                  labelStyle: TextStyle(color: _textHint, fontSize: 14),
                  alignLabelWithHint: true,
                  prefixIcon: Padding(
                    padding: const EdgeInsets.only(bottom: 120),
                    child: Icon(Icons.lock_outline, color: _accent, size: 20),
                  ),
                  filled: true, fillColor: _inputFill,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: _borderColor)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: _borderColor)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: _focusBorder, width: 2)),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _saveNote,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: _accent.withOpacity(0.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: _isLoading
                      ? const SizedBox(height: 20, width: 20,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text('Save Note',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryPicker() {
    return StreamBuilder<List<String>>(
      stream: widget.repo.watchCustomCategories(),
      builder: (context, snapshot) {
        final custom = snapshot.data ?? [];
        final all = [...VaultCategories.fixed, ...custom];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Category', style: TextStyle(fontSize: 12, color: _textHint, fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8, runSpacing: 8,
              children: [
                ...all.map((cat) => _categoryChip(cat)),
                _addCategoryChip(),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _categoryChip(String cat) {
    final selected = _category == cat;
    return GestureDetector(
      onTap: () => setState(() => _category = cat),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? _accent : _inputFill,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? _accent : _borderColor),
        ),
        child: Text(cat,
            style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w500,
              color: selected ? Colors.white : _textHint,
            )),
      ),
    );
  }

  Widget _addCategoryChip() {
    return GestureDetector(
      onTap: _showAddCategoryDialog,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: _inputFill,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _borderColor, style: BorderStyle.solid),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.add, size: 14, color: _accent),
          const SizedBox(width: 4),
          Text('New', style: TextStyle(fontSize: 12, color: _accent, fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }

  void _showAddCategoryDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cardColor,
        title: Text('New category', style: TextStyle(color: _textPrimary)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: _textPrimary),
          decoration: InputDecoration(
            hintText: 'e.g. Crypto, Health',
            hintStyle: TextStyle(color: _textHint),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              final name = ctrl.text.trim();
              if (name.isNotEmpty) {
                await widget.repo.addCustomCategory(name);
                setState(() => _category = name);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: Text('Add', style: TextStyle(color: _accent)),
          ),
        ],
      ),
    );
  }
}