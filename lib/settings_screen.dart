import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'main.dart';
import 'lockdown_manager.dart';
import 'lockdown_screen.dart';
import 'app_lock_manager.dart';
import 'app_lock_screen.dart';
import 'mode_picker_screen.dart';
import 'offline_auth_manager.dart';
import 'encryption_helper.dart';
import 'vault_constants.dart';
import 'firestore_vault_repo.dart';

class SettingsScreen extends StatefulWidget {
  final bool isDarkMode;
  final Function(bool) onThemeToggle;
  final bool isOfflineMode;

  const SettingsScreen({
    super.key,
    required this.isDarkMode,
    required this.onThemeToggle,
    this.isOfflineMode = false,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late bool _isDarkMode;
  bool _clipboardAutoClear = true;
  int _clipboardClearSeconds = 30;
  bool _lockdownMode = false;
  final _lockdown = LockdownManager();

  final _appLock = AppLockManager.instance;
  bool _hasPin = false;
  bool _fpEnabled = false;
  bool _fpAvailable = false;
  int _autoLockSeconds = 60;
  bool _lockSettingsLoaded = false;

  // ── Panic Mode ──────────────────────────────────────────────
  bool _panicModeEnabled = false;
  bool _hasPanicPin = false;
  static const _storage = FlutterSecureStorage();
  // ────────────────────────────────────────────────────────────

  // ── Dead Man's Switch ────────────────────────────────────────
  bool   _dmsEnabled       = false;
  bool   _dmsLoading       = false; // true while saving/generating PDF
  String _dmsTrustedEmail  = '';
  int    _dmsIntervalDays  = 30;
  final  _dmsEmailCtrl     = TextEditingController();
  // ─────────────────────────────────────────────────────────────

  final user = FirebaseAuth.instance.currentUser;
  String _offlineDisplayName = 'Offline User';

  Color get bgColor =>
      _isDarkMode ? const Color(0xFF10131A) : const Color(0xFFF0F2F5);
  Color get cardColor => _isDarkMode ? const Color(0xFF1E2130) : Colors.white;
  Color get textPrimary =>
      _isDarkMode ? Colors.white : const Color(0xFF1A237E);
  Color get textSecondary =>
      _isDarkMode ? const Color(0xFFC6C6CC) : Colors.grey;
  Color get accentColor => const Color(0xFF3D5AFE);

  @override
  void initState() {
    super.initState();
    _isDarkMode = widget.isDarkMode;
    _lockdownMode = LockdownManager().isLockdown;
    _loadLockSettings();
    _loadClipboardSettings();
    _loadPanicSettings();
    _loadDmsSettings();
    if (widget.isOfflineMode) _loadOfflineDisplayName();
  }

  @override
  void dispose() {
    _dmsEmailCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadClipboardSettings() async {
    final autoClear = await _storage.read(key: VaultKeys.clipboardAutoClear);
    final seconds   = await _storage.read(key: VaultKeys.clipboardClearSeconds);
    if (!mounted) return;
    setState(() {
      _clipboardAutoClear    = autoClear != 'false';
      _clipboardClearSeconds = int.tryParse(seconds ?? '30') ?? 30;
    });
  }

  Future<void> _loadOfflineDisplayName() async {
    final name = await OfflineAuthManager().getDisplayName();
    if (!mounted) return;
    setState(() => _offlineDisplayName = name ?? 'Offline User');
  }

  Future<void> _loadLockSettings() async {
    final hasPin = await _appLock.hasPin();
    final fpEnabled = await _appLock.isFingerprintEnabled();
    final fpAvailable = await _appLock.isFingerprintAvailable();
    final autoLockSecs = await _appLock.getAutoLockSeconds();
    if (!mounted) return;
    setState(() {
      _hasPin = hasPin;
      _fpEnabled = fpEnabled;
      _fpAvailable = fpAvailable;
      _autoLockSeconds = autoLockSecs;
      _lockSettingsLoaded = true;
    });
  }

  // ── Panic Mode helpers ───────────────────────────────────────

  Future<void> _loadPanicSettings() async {
    final enabled  = await _storage.read(key: 'panic_mode_enabled');
    final panicPin = await _storage.read(key: 'panic_pin');
    if (!mounted) return;
    setState(() {
      _panicModeEnabled = enabled == 'true';
      _hasPanicPin      = panicPin != null && panicPin.length == 4;
    });
  }

  // ── Dead Man's Switch methods ────────────────────────────────

  Future<void> _loadDmsSettings() async {
    if (widget.isOfflineMode) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('dms_config')
          .doc('config')
          .get();
      if (!mounted) return;
      if (doc.exists) {
        final data = doc.data()!;
        setState(() {
          _dmsEnabled      = data['isEnabled'] == true;
          _dmsTrustedEmail = data['trustedEmail'] ?? '';
          _dmsIntervalDays = data['intervalDays'] ?? 30;
          _dmsEmailCtrl.text = _dmsTrustedEmail;
        });
      }
    } catch (_) {}
  }

  Future<void> _saveDmsSettings() async {
    final email = _dmsEmailCtrl.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Enter a valid trusted contact email'),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    setState(() => _dmsLoading = true);

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;

      final repo = FirestoreVaultRepo(uid: uid);
      final entries = await repo.fetchAllPasswords();
      await repo.saveDmsConfig(
        trustedEmail: email,
        intervalDays: _dmsIntervalDays,
        entries: entries,
      );

      if (!mounted) return;
      setState(() {
        _dmsEnabled      = true;
        _dmsTrustedEmail = email;
      });

      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Dead Man\'s Switch enabled'),
        backgroundColor: Colors.green,
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error: $e'),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _dmsLoading = false);
    }
  }

  Future<void> _disableDms() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cardColor,
        title: Text('Disable Dead Man\'s Switch?',
            style: TextStyle(color: textPrimary)),
        content: Text(
          'Your trusted contact will no longer receive your vault if you become inactive.',
          style: TextStyle(color: textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Disable', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('dms_config')
          .doc('config')
          .update({'isEnabled': false});

      if (!mounted) return;
      setState(() => _dmsEnabled = false);

      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Dead Man\'s Switch disabled'),
        backgroundColor: Colors.orange,
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error: $e'),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  // ─────────────────────────────────────────────────────────────

  Future<void> _togglePanicMode(bool value) async {
    if (value && !_hasPin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Set up an App Lock PIN first before enabling Panic Mode'),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (value && !_hasPanicPin) {
      // Ask them to set a panic PIN before enabling
      await _setupPanicPin();
      // Re-check: if they cancelled, don't enable
      if (!_hasPanicPin) return;
    }

    await _storage.write(key: 'panic_mode_enabled', value: value.toString());
    if (!mounted) return;
    setState(() => _panicModeEnabled = value);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(value ? 'Panic Mode enabled' : 'Panic Mode disabled'),
        backgroundColor: value ? Colors.deepOrange : Colors.grey.shade700,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Shows a two-step dialog to set/change the panic PIN.
  Future<void> _setupPanicPin() async {
    String firstPin  = '';
    String secondPin = '';

    // Step 1 — enter new panic PIN
    final step1 = await _showPinInputDialog(
      title: 'Set Panic PIN',
      message: 'Enter a 4-digit PIN that opens the decoy vault.\n'
          'Make it different from your real PIN!',
    );
    if (step1 == null || step1.length != 4) return;
    firstPin = step1;

    // Step 2 — confirm
    final step2 = await _showPinInputDialog(
      title: 'Confirm Panic PIN',
      message: 'Re-enter the same 4-digit panic PIN to confirm.',
    );
    if (step2 == null) return;
    secondPin = step2;

    if (firstPin != secondPin) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("PINs don't match. Try again."),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // Prevent same PIN as real app lock PIN
    final realPin = await _appLock.getRawPin(); // see note below
    if (realPin != null && firstPin == realPin) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Panic PIN cannot be the same as your real PIN!'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    await _storage.write(key: 'panic_pin', value: firstPin);
    if (!mounted) return;
    setState(() => _hasPanicPin = true);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Panic PIN set successfully'),
        backgroundColor: Colors.green,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _changePanicPin() async {
    // First verify real app lock PIN so a stranger can't change it
    final verified = await Navigator.push<dynamic>(
      context,
      MaterialPageRoute(
        builder: (_) => AppLockScreen(
          mode: LockMode.unlock,
          isDarkMode: _isDarkMode,
          onUnlocked: () {},
        ),
      ),
    );
    // 'panic' result means they used the panic PIN — don't allow changing from decoy vault
    if (verified != true) return;

    await _setupPanicPin();
  }

  Future<void> _removePanicPin() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Panic PIN?'),
        content: const Text(
            'This will delete the Panic PIN and disable Panic Mode.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    await _storage.delete(key: 'panic_pin');
    await _storage.write(key: 'panic_mode_enabled', value: 'false');
    if (!mounted) return;
    setState(() {
      _hasPanicPin      = false;
      _panicModeEnabled = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Panic PIN removed'),
        backgroundColor: Colors.orange,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Simple dialog that shows a text field for a 4-digit PIN.
  /// Returns the entered PIN string, or null if cancelled.
  Future<String?> _showPinInputDialog({
    required String title,
    required String message,
  }) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title, style: TextStyle(color: textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message,
                style: TextStyle(color: textSecondary, fontSize: 13)),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              maxLength: 4,
              obscureText: true,
              autofocus: true,
              style: TextStyle(color: textPrimary),
              decoration: InputDecoration(
                labelText: '4-digit PIN',
                labelStyle: TextStyle(color: textSecondary),
                border: const OutlineInputBorder(),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: accentColor),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: textSecondary)),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.length == 4) {
                Navigator.pop(ctx, controller.text);
              }
            },
            child: Text('Confirm', style: TextStyle(color: accentColor)),
          ),
        ],
      ),
    );
  }

  // ────────────────────────────────────────────────────────────

  void _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Logout', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      EncryptionHelper.clearCloudKey();
      await FirebaseAuth.instance.signOut();
      await GoogleSignIn().signOut();
      await OfflineAuthManager().deleteOfflineUser();
      await _storage.delete(key: VaultKeys.modePickerDone);

      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const ModePickerScreen()),
              (route) => false,
        );
      }
    }
  }

  void _changePassword() {
    final newPasswordController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change Password'),
        content: TextField(
          controller: newPasswordController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'New Password',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              if (newPasswordController.text.length < 6) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Password must be at least 6 characters'),
                    backgroundColor: Colors.red,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
                return;
              }
              try {
                await FirebaseAuth.instance.currentUser
                    ?.updatePassword(newPasswordController.text);
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Password updated successfully!'),
                    backgroundColor: Colors.green,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Error: $e'),
                    backgroundColor: Colors.red,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }

  void _toggleLockdown() async {
    if (!_lockdownMode) {
      final hasPin = await _lockdown.hasPin();
      if (!hasPin) {
        _showSetPinDialog();
      } else {
        await _lockdown.enableLockdown();
        setState(() => _lockdownMode = true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Lockdown mode enabled'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } else {
      final pending = await _lockdown.getPendingCount();
      final result = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (context) => LockdownExitScreen(isDarkMode: _isDarkMode),
        ),
      );
      if (result == true) {
        setState(() => _lockdownMode = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(pending > 0
                ? 'Lockdown disabled — syncing $pending saved password(s)...'
                : 'Lockdown mode disabled'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void _showSetPinDialog() {
    final pinController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set Lockdown PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Set a 4-digit PIN to exit lockdown mode'),
            const SizedBox(height: 16),
            TextField(
              controller: pinController,
              keyboardType: TextInputType.number,
              maxLength: 4,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '4-digit PIN',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              if (pinController.text.length == 4) {
                await _lockdown.setPin(pinController.text);
                Navigator.pop(ctx);
                _toggleLockdown();
              }
            },
            child: const Text('Set PIN'),
          ),
        ],
      ),
    );
  }

  Future<void> _setupAppLockPin() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AppLockScreen(
          mode: LockMode.setupPin,
          isDarkMode: _isDarkMode,
          onUnlocked: () {},
        ),
      ),
    );
    if (result == true) {
      await _appLock.markSetupDone();
      await _loadLockSettings();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('App lock PIN set successfully'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _changeAppLockPin() async {
    final verified = await Navigator.push<dynamic>(
      context,
      MaterialPageRoute(
        builder: (_) => AppLockScreen(
          mode: LockMode.unlock,
          isDarkMode: _isDarkMode,
          onUnlocked: () {},
        ),
      ),
    );
    if (verified != true) return;
    if (!mounted) return;

    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AppLockScreen(
          mode: LockMode.setupPin,
          isDarkMode: _isDarkMode,
          onUnlocked: () {},
        ),
      ),
    );
    if (result == true) {
      await _loadLockSettings();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('PIN updated successfully'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _removeAppLockPin() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove App Lock?'),
        content: const Text(
            'This will disable both the PIN and fingerprint lock. Your vault will open without any extra protection.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final verified = await Navigator.push<dynamic>(
      context,
      MaterialPageRoute(
        builder: (_) => AppLockScreen(
          mode: LockMode.unlock,
          isDarkMode: _isDarkMode,
          onUnlocked: () {},
        ),
      ),
    );
    if (verified != true) return;

    await _appLock.clearPin();
    await _appLock.setFingerprintEnabled(false);
    await _loadLockSettings();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('App lock removed'),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _toggleFingerprint(bool value) async {
    if (value && !_hasPin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Set up a PIN first as fingerprint fallback'),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    await _appLock.setFingerprintEnabled(value);
    await _loadLockSettings();
  }

  Future<void> _pickAutoLock() async {
    final choice = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Auto-lock after', style: TextStyle(color: textPrimary)),
        children: [
          for (final secs in [0, 30, 60, 300])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, secs),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      _autoLockSeconds == secs
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: accentColor,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Text(_autoLockLabel(secs),
                        style: TextStyle(color: textPrimary, fontSize: 15)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (choice != null) {
      await _appLock.setAutoLockSeconds(choice);
      await _loadLockSettings();
    }
  }

  String _autoLockLabel(int s) {
    if (s == 0) return 'Immediately';
    if (s < 60) return '$s seconds';
    if (s == 60) return '1 minute';
    return '${s ~/ 60} minutes';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_lockdownMode)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade700,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.lock_rounded, color: Colors.white, size: 16),
                      SizedBox(width: 8),
                      Text('LOCKDOWN MODE ACTIVE',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 2,
                            fontSize: 12,
                          )),
                    ],
                  ),
                ),
              Text('Settings',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: textPrimary,
                  )),
              const SizedBox(height: 24),

              // ── Account ──────────────────────────────────────
              _buildSectionTitle('Account'),
              _buildCard([
                _buildAccountTile(),
                if (!widget.isOfflineMode) ...[
                  _buildDivider(),
                  _buildTappableTile(
                    icon: Icons.lock_reset_rounded,
                    title: 'Change Password',
                    subtitle: 'Update your account password',
                    onTap: _changePassword,
                  ),
                ],
              ]),
              const SizedBox(height: 20),

              // ── App Lock ─────────────────────────────────────
              _buildSectionTitle('App Lock'),
              _buildCard([
                if (!_lockSettingsLoaded)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  if (!_hasPin)
                    _buildTappableTile(
                      icon: Icons.lock_rounded,
                      title: 'Set up App Lock',
                      subtitle: 'Add a PIN to protect your vault',
                      onTap: _setupAppLockPin,
                    )
                  else ...[
                    _buildTappableTile(
                      icon: Icons.pin_rounded,
                      title: 'Change PIN',
                      subtitle: 'Update your 4-digit PIN',
                      onTap: _changeAppLockPin,
                    ),
                    _buildDivider(),
                    _buildSwitchTile(
                      icon: Icons.fingerprint_rounded,
                      title: 'Biometric Unlock',
                      subtitle: _fpAvailable
                          ? 'Use fingerprint or face to unlock the app'
                          : 'Not available on this device',
                      value: _fpEnabled,
                      onChanged: _fpAvailable ? _toggleFingerprint : (_) {},
                    ),
                    _buildDivider(),
                    _buildTappableTile(
                      icon: Icons.timer_rounded,
                      title: 'Auto-Lock',
                      subtitle:
                      'Lock after ${_autoLockLabel(_autoLockSeconds).toLowerCase()} in background',
                      onTap: _pickAutoLock,
                    ),
                    _buildDivider(),
                    _buildTappableTile(
                      icon: Icons.lock_open_rounded,
                      title: 'Remove App Lock',
                      subtitle: 'Disable PIN and fingerprint',
                      onTap: _removeAppLockPin,
                    ),
                  ],
                ],
              ]),
              const SizedBox(height: 20),

              // ── Panic Mode ───────────────────────────────────
              _buildSectionTitle('Panic Mode'),
              _buildCard([
                _buildSwitchTile(
                  icon: Icons.crisis_alert_rounded,
                  title: 'Enable Panic Mode',
                  subtitle: _panicModeEnabled
                      ? 'Active — panic PIN opens decoy vault'
                      : 'Enter a secret PIN to open a fake vault',
                  value: _panicModeEnabled,
                  onChanged: _hasPin ? _togglePanicMode : (_) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Set up an App Lock PIN first'),
                        backgroundColor: Colors.orange,
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                ),
                if (_panicModeEnabled) ...[
                  _buildDivider(),
                  _buildTappableTile(
                    icon: Icons.edit_rounded,
                    title: 'Change Panic PIN',
                    subtitle: 'Update the PIN that opens the decoy vault',
                    onTap: _changePanicPin,
                  ),
                  _buildDivider(),
                  _buildTappableTile(
                    icon: Icons.delete_outline_rounded,
                    title: 'Remove Panic PIN',
                    subtitle: 'Disable Panic Mode entirely',
                    onTap: _removePanicPin,
                  ),
                  _buildDivider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline_rounded,
                            size: 16, color: textSecondary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'When the panic PIN is entered on the lock screen, '
                                'the decoy vault opens instead of your real vault. '
                                'Add fake entries to the decoy vault to make it look convincing.',
                            style: TextStyle(
                                fontSize: 12, color: textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ]),
              const SizedBox(height: 20),

              // ── Dead Man's Switch ─────────────────────────────
              if (!widget.isOfflineMode) ...[
                _buildSectionTitle("Dead Man's Switch"),
                _buildCard([
                  // ── Status row ────────────────────────────────
                  _buildSwitchTile(
                    icon: Icons.running_with_errors_rounded,
                    title: "Dead Man's Switch",
                    subtitle: _dmsEnabled
                        ? 'Armed — vault will be shared after $_dmsIntervalDays days of inactivity'
                        : 'Share your vault if you stop using the app',
                    value: _dmsEnabled,
                    onChanged: (_dmsLoading)
                        ? (_) {}
                        : (val) {
                      if (!val) {
                        _disableDms();
                      } else {
                        // Scroll down so the form is visible
                        setState(() {});
                      }
                    },
                  ),

                  // ── Setup form — shown when not yet enabled ───
                  if (!_dmsEnabled) ...[
                    _buildDivider(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Email field
                          TextField(
                            controller: _dmsEmailCtrl,
                            keyboardType: TextInputType.emailAddress,
                            style: TextStyle(color: textPrimary, fontSize: 14),
                            decoration: InputDecoration(
                              labelText: 'Trusted contact email',
                              labelStyle: TextStyle(color: textSecondary, fontSize: 13),
                              prefixIcon: Icon(Icons.email_outlined,
                                  color: accentColor, size: 20),
                              filled: true,
                              fillColor: _isDarkMode
                                  ? const Color(0xFF141720)
                                  : const Color(0xFFF7F8FC),
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide(
                                      color: _isDarkMode
                                          ? const Color(0xFF252A38)
                                          : const Color(0xFFDDE1F0))),
                              enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide(
                                      color: _isDarkMode
                                          ? const Color(0xFF252A38)
                                          : const Color(0xFFDDE1F0))),
                              focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide(
                                      color: accentColor, width: 2)),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Interval picker
                          Row(children: [
                            Icon(Icons.calendar_today_rounded,
                                size: 18, color: accentColor),
                            const SizedBox(width: 10),
                            Text('Trigger after',
                                style: TextStyle(
                                    color: textPrimary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500)),
                              Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  for (final days in [14, 30, 60, 90])
                                    Padding(
                                      padding: const EdgeInsets.only(left: 6),
                                      child: GestureDetector(
                                        onTap: () => setState(
                                                () => _dmsIntervalDays = days),
                                        child: AnimatedContainer(
                                          duration: const Duration(
                                              milliseconds: 150),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: _dmsIntervalDays == days
                                                ? accentColor
                                                : accentColor.withOpacity(0.08),
                                            borderRadius:
                                            BorderRadius.circular(20),
                                            border: Border.all(
                                                color: _dmsIntervalDays == days
                                                    ? accentColor
                                                    : accentColor
                                                    .withOpacity(0.25)),
                                          ),
                                          child: Text('${days}d',
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                                color: _dmsIntervalDays == days
                                                    ? Colors.white
                                                    : accentColor,
                                              )),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            ),
                          ]),
                          const SizedBox(height: 16),

                          // Enable button
                          SizedBox(
                            width: double.infinity,
                            height: 46,
                            child: ElevatedButton.icon(
                              onPressed: _dmsLoading ? null : _saveDmsSettings,
                              icon: _dmsLoading
                                  ? const SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2))
                                  : const Icon(Icons.check_rounded, size: 18),
                              label: Text(
                                  _dmsLoading
                                      ? 'Generating vault export...'
                                      : 'Enable Dead Man\'s Switch',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: accentColor,
                                foregroundColor: Colors.white,
                                disabledBackgroundColor:
                                accentColor.withOpacity(0.5),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],

                  // ── Enabled state — show summary ──────────────
                  if (_dmsEnabled) ...[
                    _buildDivider(),
                    _buildInfoTile(
                      icon: Icons.email_outlined,
                      title: 'Trusted contact',
                      trailing: _dmsTrustedEmail.length > 22
                          ? '${_dmsTrustedEmail.substring(0, 20)}…'
                          : _dmsTrustedEmail,
                    ),
                    _buildDivider(),
                    _buildInfoTile(
                      icon: Icons.timer_outlined,
                      title: 'Trigger after',
                      trailing: '$_dmsIntervalDays days inactive',
                    ),
                    _buildDivider(),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline_rounded,
                              size: 16, color: textSecondary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Every time you open ObexVault, the timer resets. '
                                  'If you stop opening the app for $_dmsIntervalDays days, '
                                  'your vault export is automatically emailed to '
                                  '$_dmsTrustedEmail.',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: textSecondary,
                                  height: 1.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ]),
                const SizedBox(height: 20),
              ],

              // ── Security ─────────────────────────────────────
              _buildSectionTitle('Security'),
              _buildCard([
                if (!widget.isOfflineMode) ...[
                  _buildSwitchTile(
                    icon: Icons.language_rounded,
                    title: 'Offline Lockdown',
                    subtitle: _lockdownMode
                        ? 'Network blocked — tap to exit'
                        : 'Block all network access',
                    value: _lockdownMode,
                    onChanged: (_) => _toggleLockdown(),
                  ),
                  _buildDivider(),
                ],
                _buildSwitchTile(
                  icon: Icons.content_paste_off_rounded,
                  title: 'Clipboard Auto-Clear',
                  subtitle:
                  'Clear copied passwords after $_clipboardClearSeconds seconds',
                  value: _clipboardAutoClear,
                  onChanged: (val) async {
                    setState(() => _clipboardAutoClear = val);
                    await _storage.write(
                      key: VaultKeys.clipboardAutoClear,
                      value: val.toString(),
                    );
                  },
                ),
                if (_clipboardAutoClear) ...[
                  _buildDivider(),
                  _buildSliderTile(
                    icon: Icons.timer_rounded,
                    title: 'Clear After',
                    value: _clipboardClearSeconds.toDouble(),
                    min: 10,
                    max: 120,
                    divisions: 11,
                    label: '$_clipboardClearSeconds sec',
                    onChanged: (val) async {
                      setState(() => _clipboardClearSeconds = val.toInt());
                      await _storage.write(
                        key: VaultKeys.clipboardClearSeconds,
                        value: val.toInt().toString(),
                      );
                    },
                  ),
                ],
              ]),
              const SizedBox(height: 20),

              // ── Appearance ───────────────────────────────────
              _buildSectionTitle('Appearance'),
              _buildCard([
                _buildSwitchTile(
                  icon: Icons.dark_mode_rounded,
                  title: 'Dark Mode',
                  subtitle: 'Switch between light and dark theme',
                  value: _isDarkMode,
                  onChanged: (val) {
                    setState(() => _isDarkMode = val);
                    widget.onThemeToggle(val);
                  },
                ),
              ]),
              const SizedBox(height: 20),

              // ── About ────────────────────────────────────────
              _buildSectionTitle('About'),
              _buildCard([
                _buildInfoTile(
                  icon: Icons.info_outline_rounded,
                  title: 'Version',
                  trailing: '1.0.0',
                ),
                _buildDivider(),
                _buildInfoTile(
                  icon: Icons.security_rounded,
                  title: 'Encryption',
                  trailing: 'AES-256',
                ),
              ]),
              const SizedBox(height: 20),

              // ── Logout ───────────────────────────────────────
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton.icon(
                  onPressed: _logout,
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('Logout',
                      style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade600,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 4),
      child: Text(title.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: textSecondary,
            letterSpacing: 1.5,
          )),
    );
  }

  Widget _buildCard(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(_isDarkMode ? 0.3 : 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(children: children),
    );
  }

  Widget _buildAccountTile() {
    final displayName =
    _offlineDisplayName.isNotEmpty && widget.isOfflineMode
        ? _offlineDisplayName
        : (user?.displayName ?? 'User');
    final email = widget.isOfflineMode
        ? 'Local vault — no account'
        : (user?.email ?? '');
    final initial =
    displayName.isNotEmpty ? displayName[0].toUpperCase() : 'U';

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: accentColor.withOpacity(0.15),
            child: Text(initial,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: accentColor,
                )),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(displayName,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: textPrimary,
                    )),
                Text(email,
                    style: TextStyle(fontSize: 13, color: textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTappableTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: accentColor.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: accentColor, size: 20),
      ),
      title: Text(title,
          style: TextStyle(
              fontWeight: FontWeight.w500, color: textPrimary, fontSize: 15)),
      subtitle:
      Text(subtitle, style: TextStyle(color: textSecondary, fontSize: 12)),
      trailing: Icon(Icons.chevron_right, color: textSecondary),
      onTap: onTap,
    );
  }

  Widget _buildSwitchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required Function(bool) onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: accentColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: accentColor, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontWeight: FontWeight.w500,
                        color: textPrimary,
                        fontSize: 15)),
                Text(subtitle,
                    style: TextStyle(color: textSecondary, fontSize: 12)),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged, activeColor: accentColor),
        ],
      ),
    );
  }

  Widget _buildSliderTile({
    required IconData icon,
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    required Function(double) onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: accentColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: accentColor, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontWeight: FontWeight.w500,
                            color: textPrimary,
                            fontSize: 15)),
                    Text(label,
                        style: TextStyle(
                            color: accentColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 13)),
                  ],
                ),
                Slider(
                  value: value,
                  min: min,
                  max: max,
                  divisions: divisions,
                  activeColor: accentColor,
                  onChanged: onChanged,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoTile({
    required IconData icon,
    required String title,
    required String trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: accentColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: accentColor, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(title,
                style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: textPrimary,
                    fontSize: 15)),
          ),
          Text(trailing,
              style: TextStyle(
                  color: textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _buildDivider() {
    return Divider(
      height: 1,
      indent: 56,
      color: _isDarkMode
          ? Colors.white.withOpacity(0.05)
          : Colors.grey.withOpacity(0.15),
    );
  }
}