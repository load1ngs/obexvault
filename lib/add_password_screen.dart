import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'encryption_helper.dart';
import 'lockdown_manager.dart';
import 'vault_repository.dart';
import 'firestore_vault_repo.dart';
import 'offline_auth_manager.dart';
import 'vault_constants.dart';
import 'hibp_service.dart';

class AddPasswordScreen extends StatefulWidget {
  final VaultRepository repo;
  final bool isOfflineMode;
  final bool isDarkMode;

  const AddPasswordScreen({
    super.key,
    required this.repo,
    required this.isOfflineMode,
    this.isDarkMode = false,
  });

  @override
  State<AddPasswordScreen> createState() => _AddPasswordScreenState();
}

class _AddPasswordScreenState extends State<AddPasswordScreen> {
  final _titleController    = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _urlController      = TextEditingController();
  bool   _obscurePassword = true;
  bool   _isLoading       = false;
  bool   _isFavorite      = false;
  String _category        = 'Personal';

  // HIBP state
  bool _hibpChecking = false;
  int  _hibpCount    = -1; // -1 = not checked, 0 = safe, >0 = pwned

  @override
  void initState() {
    super.initState();
    _passwordController.addListener(() {
      setState(() {
        _hibpCount = -1; // reset badge when password changes
      });
    });
  }

  @override
  void dispose() {
    _titleController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  // ─── Theme ───────────────────────────────────────────────────────────────

  Color get _bgColor     => widget.isDarkMode ? const Color(0xFF10131A) : const Color(0xFFF0F2F5);
  Color get _cardColor   => widget.isDarkMode ? const Color(0xFF1E2130) : Colors.white;
  Color get _textPrimary => widget.isDarkMode ? Colors.white            : const Color(0xFF1A237E);
  Color get _textHint    => widget.isDarkMode ? const Color(0xFF8892A8) : Colors.grey;
  Color get _accent      => const Color(0xFF3D5AFE);
  Color get _borderColor => widget.isDarkMode ? const Color(0xFF252A38) : const Color(0xFFDDE1F0);
  Color get _focusBorder => const Color(0xFF1A237E);
  Color get _inputFill   => widget.isDarkMode ? const Color(0xFF141720) : Colors.white;

  // ─── Strength ────────────────────────────────────────────────────────────

  int _getStrength(String p) {
    if (p.isEmpty) return 0;
    int s = 0;
    if (p.length >= 8)  s++;
    if (p.length >= 14) s++;
    if (p.contains(RegExp(r'[A-Z]')) && p.contains(RegExp(r'[a-z]'))) s++;
    if (p.contains(RegExp(r'[0-9]'))) s++;
    if (p.contains(RegExp(r'[!@#\$%^&*(),.?":{}|<>_\-\\\/\[\]~`+=;]'))) s++;
    return s.clamp(0, 4);
  }

  String _strengthLabel(int s) => ['', 'Weak', 'Fair', 'Strong', 'Excellent'][s];

  Color _strengthColor(int s) => [
    Colors.transparent,
    const Color(0xFFEF5350),
    const Color(0xFFFF9800),
    const Color(0xFF42A5F5),
    const Color(0xFF66BB6A),
  ][s];

  // ─── Key ─────────────────────────────────────────────────────────────────

  Uint8List? get _encKeyOverride =>
      widget.isOfflineMode ? OfflineAuthManager().sessionKey : null;

  // ─── HIBP Check ───────────────────────────────────────────────────────────

  Future<void> _checkHibp() async {
    final password = _passwordController.text;
    if (password.isEmpty) return;

    setState(() {
      _hibpChecking = true;
      _hibpCount = -1;
    });

    final count = await HibpService.checkPassword(password);

    if (mounted) {
      setState(() {
        _hibpChecking = false;
        _hibpCount = count;
      });

      if (count > 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            'This password appeared in $count data breach${count == 1 ? '' : 'es'}! Consider using a different password.',
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
        ));
      } else if (count == 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Great! This password was not found in any known breaches.'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not check — please check your internet connection.'),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  // ─── Save ─────────────────────────────────────────────────────────────────

  Future<void> _savePassword() async {
    if (_titleController.text.trim().isEmpty || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Title and Password are required'),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    // If pwned, show a confirmation dialog before saving
    if (_hibpCount > 0) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _cardColor,
          title: Text('Breached Password',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          content: Text(
            'This password was found in $_hibpCount known data breach${_hibpCount == 1 ? '' : 'es'}.\n\nAre you sure you want to save it?',
            style: TextStyle(color: _textPrimary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save Anyway', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }

    setState(() => _isLoading = true);
    final passwordData = {
      'title':      _titleController.text.trim(),
      'username':   _usernameController.text.trim(),
      'password':   EncryptionHelper.encrypt(_passwordController.text, keyOverride: _encKeyOverride),
      'url':        _urlController.text.trim(),
      'category':   _category,
      'isFavorite': _isFavorite,
    };
    try {
      await widget.repo.addPassword(passwordData);
      if (!widget.isOfflineMode && LockdownManager().isLockdown) {
        await LockdownManager().queuePassword(passwordData);
      }
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
          content: Text('Password saved!'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error: $e'),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ─── Build ────────────────────────────────────────────────────────────────

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
        title: Text('Add Password',
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
            boxShadow: [BoxShadow(
              color: Colors.black.withOpacity(widget.isDarkMode ? 0.3 : 0.06),
              blurRadius: 16, offset: const Offset(0, 4),
            )],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildField(controller: _titleController,
                  label: 'Title (e.g. Google, Netflix)', icon: Icons.label_outline),
              const SizedBox(height: 16),
              _buildField(controller: _usernameController,
                  label: 'Username / Email', icon: Icons.person_outline),
              const SizedBox(height: 16),
              _buildPasswordField(),
              _buildStrengthMeter(),
              const SizedBox(height: 12),

              // ── HIBP Check Button ──
              _buildHibpButton(),
              const SizedBox(height: 16),

              _buildCategoryPicker(),
              const SizedBox(height: 16),
              _buildField(controller: _urlController,
                  label: 'Website URL (optional)', icon: Icons.link),
              const SizedBox(height: 24),
              SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _savePassword,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: _accent.withOpacity(0.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: _isLoading
                      ? const SizedBox(height: 20, width: 20,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text('Save Password',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── HIBP Button Widget ───────────────────────────────────────────────────

  Widget _buildHibpButton() {
    Color badgeColor = Colors.grey;
    String badgeText = '';
    IconData badgeIcon = Icons.shield_outlined;

    if (_hibpCount == 0) {
      badgeColor = Colors.green;
      badgeText  = 'Safe';
      badgeIcon  = Icons.verified_user_outlined;
    } else if (_hibpCount > 0) {
      badgeColor = Colors.red;
      badgeText  = 'Pwned $_hibpCount×';
      badgeIcon  = Icons.gpp_bad_outlined;
    }

    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: (_hibpChecking || _passwordController.text.isEmpty)
                ? null
                : _checkHibp,
            icon: _hibpChecking
                ? const SizedBox(
                height: 16, width: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.security_outlined, size: 18),
            label: Text(_hibpChecking ? 'Checking...' : 'Check for Breaches'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _accent,
              side: BorderSide(color: _borderColor),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),

        // Badge — only shows after a check
        if (_hibpCount >= 0) ...[
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: badgeColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: badgeColor.withOpacity(0.4)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(badgeIcon, color: badgeColor, size: 16),
              const SizedBox(width: 4),
              Text(badgeText,
                  style: TextStyle(color: badgeColor,
                      fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
          ),
        ],
      ],
    );
  }

  // ─── Widgets ──────────────────────────────────────────────────────────────

  Widget _buildStrengthMeter() {
    final password = _passwordController.text;
    final score    = _getStrength(password);
    final label    = _strengthLabel(score);
    final color    = _strengthColor(score);
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      child: password.isEmpty ? const SizedBox.shrink() : Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: List.generate(4, (i) => Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                height: 5,
                margin: EdgeInsets.only(right: i < 3 ? 4 : 0),
                decoration: BoxDecoration(
                  color: i < score ? color
                      : (widget.isDarkMode ? const Color(0xFF252A38) : const Color(0xFFDDE1F0)),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ))),
            const SizedBox(height: 6),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(label, key: ValueKey(label),
                  style: TextStyle(color: color, fontSize: 12,
                      fontWeight: FontWeight.w600, letterSpacing: 0.4)),
            ),
          ],
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
            Text('Category',
                style: TextStyle(fontSize: 12, color: _textHint, fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              ...all.map((cat) => _categoryChip(cat)),
              _addCategoryChip(),
            ]),
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
        child: Text(cat, style: TextStyle(
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
          border: Border.all(color: _borderColor),
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

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
  }) {
    return TextField(
      controller: controller,
      style: TextStyle(color: _textPrimary, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: _textHint, fontSize: 14),
        prefixIcon: Icon(icon, color: _accent, size: 20),
        filled: true, fillColor: _inputFill,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: _borderColor)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: _borderColor)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: _focusBorder, width: 2)),
      ),
    );
  }

  Widget _buildPasswordField() {
    return TextField(
      controller: _passwordController,
      obscureText: _obscurePassword,
      style: TextStyle(color: _textPrimary, fontSize: 14),
      decoration: InputDecoration(
        labelText: 'Password',
        labelStyle: TextStyle(color: _textHint, fontSize: 14),
        prefixIcon: Icon(Icons.lock_outline, color: _accent, size: 20),
        suffixIcon: IconButton(
          icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility,
              color: _textHint, size: 20),
          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
        ),
        filled: true, fillColor: _inputFill,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: _borderColor)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: _borderColor)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: _focusBorder, width: 2)),
      ),
    );
  }
}