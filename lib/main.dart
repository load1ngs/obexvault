import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'firebase_options.dart';
import 'signup_screen.dart';
import 'vault_screen.dart';
import 'lockdown_manager.dart';
import 'app_lock_screen.dart';
import 'app_lock_manager.dart';
import 'offline_auth_manager.dart';
import 'offline_unlock_screen.dart';
import 'firestore_vault_repo.dart';
import 'local_vault_repo.dart';
import 'login_screen.dart';
import 'mode_picker_screen.dart';
import 'encryption_helper.dart';
import 'vault_constants.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await LockdownManager().init();
  runApp(const ObexVaultApp());
}

class ObexVaultApp extends StatefulWidget {
  const ObexVaultApp({super.key});
  @override
  State<ObexVaultApp> createState() => _ObexVaultAppState();
}

class _ObexVaultAppState extends State<ObexVaultApp> {
  final _storage  = const FlutterSecureStorage();
  bool _isDarkMode  = false;
  bool _themeLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final saved = await _storage.read(key: VaultKeys.themeDark);
    setState(() {
      _isDarkMode  = saved == 'true';
      _themeLoaded = true;
    });
  }

  Future<void> _saveTheme(bool isDark) async {
    await _storage.write(key: VaultKeys.themeDark, value: isDark.toString());
    setState(() => _isDarkMode = isDark);
  }

  @override
  Widget build(BuildContext context) {
    if (!_themeLoaded) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Color(0xFF0D0F14),
          body: Center(
            child: CircularProgressIndicator(color: Color(0xFF3B6BFF)),
          ),
        ),
      );
    }
    return MaterialApp(
      title: 'ObexVault',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B6BFF)),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0D0F14),
        fontFamily: 'DMSans',
      ),
      home: AuthWrapper(
        isDarkMode: _isDarkMode,
        onThemeToggle: _saveTheme,
      ),
    );
  }
}

// ─── AuthWrapper ──────────────────────────────────────────────────────────────

class AuthWrapper extends StatefulWidget {
  final bool isDarkMode;
  final Function(bool) onThemeToggle;

  const AuthWrapper({
    super.key,
    required this.isDarkMode,
    required this.onThemeToggle,
  });

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> with WidgetsBindingObserver {
  final _manager     = AppLockManager.instance;
  final _offlineAuth = OfflineAuthManager();
  bool _isLocked      = false;
  bool _modeChecked   = false;
  bool _isOfflineMode = false;
  bool _isLoggedIn    = false;
  bool _showingLockScreen = false; // prevents double-push

  // ── Panic Mode ──────────────────────────────────────────────
  bool _isPanicMode   = false; // true = show decoy vault
  // ────────────────────────────────────────────────────────────

  LocalVaultRepo? _offlineRepo;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkVaultMode();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _offlineRepo?.dispose();
    _offlineRepo = null;
    super.dispose();
  }

  Future<void> _checkVaultMode() async {
    final offline   = await _offlineAuth.isOfflineMode();
    final setupDone = await _offlineAuth.isOfflineSetupComplete();

    final lockSetupDone = await _manager.isSetupDone();
    final hasFirebase   = FirebaseAuth.instance.currentUser != null;

    if (mounted) {
      setState(() {
        _isOfflineMode = offline;
        _isLoggedIn    = setupDone || hasFirebase;
        _isLocked      = lockSetupDone && hasFirebase && !offline;
        _modeChecked   = true;
      });
    }

    FirebaseAuth.instance.authStateChanges().listen((user) {
      if (!mounted) return;
      if (!_isOfflineMode) {
        setState(() => _isLoggedIn = user != null);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (_isOfflineMode) {
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.inactive) {
        _offlineAuth.dropSessionKey();
        _offlineRepo?.dispose();
        _offlineRepo = null;
        if (mounted) setState(() => _isLocked = true);
      }
      return;
    }

    if (_manager.isAuthenticating) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final setupDone = await _manager.isSetupDone();
    if (!setupDone) return;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _manager.lastPausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final shouldLock = await _manager.shouldLockNow();
      if (shouldLock && !_isLocked && mounted) {
        setState(() {
          _isLocked          = true;
          _isPanicMode       = false; // always re-verify on re-lock
          _showingLockScreen = false;
        });
      }

      // ── Dead Man's Switch: silently record that the user is alive ──────────
      // Only runs in cloud mode (not offline, not panic/decoy vault).
      // Fire-and-forget — we don't await so it never blocks the UI.
      if (!_isPanicMode) {
        final uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid != null) {
          FirestoreVaultRepo(uid: uid).updateLastSeen();
        }
      }
      // ───────────────────────────────────────────────────────────────────────
    }
  }

  /// Called when the real PIN / biometric succeeds → open real vault.
  void _unlock() {
    setState(() {
      _isLocked          = false;
      _isPanicMode       = false;
      _showingLockScreen = false;
      _manager.lastPausedAt = null;
    });
  }

  /// Called when the panic PIN is entered → open decoy vault.
  void _unlockPanic() {
    setState(() {
      _isLocked          = false;
      _isPanicMode       = true;
      _showingLockScreen = false;
      _manager.lastPausedAt = null;
    });
  }

  void _unlockOffline() {
    _offlineRepo = LocalVaultRepo(derivedKey: _offlineAuth.sessionKey);
    setState(() => _isLocked = false);
  }

  Future<void> _recheckOfflineState() async {
    final offline   = await _offlineAuth.isOfflineMode();
    final setupDone = await _offlineAuth.isOfflineSetupComplete();
    if (mounted) {
      setState(() {
        _isOfflineMode = offline;
        _isLoggedIn    = setupDone || _isLoggedIn;
      });
    }
  }

  /// Pushes the lock screen as a full-screen route and waits for result.
  /// Result is either `true` (real unlock) or `'panic'` (panic unlock).
  void _showLockScreen(BuildContext context) {
    if (_showingLockScreen) return;
    _showingLockScreen = true;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AppLockScreen(
          mode: LockMode.unlock,
          isDarkMode: widget.isDarkMode,
          onUnlocked: _unlock,
          onPanicUnlocked: _unlockPanic,
        ),
      ),
    ).then((result) {
      // If the screen was popped without a result (e.g. Android back — which
      // WillPopScope blocks on lock mode, but just in case), keep locked.
      if (result == null && mounted) {
        setState(() => _showingLockScreen = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_modeChecked) {
      return const Scaffold(
        backgroundColor: Color(0xFF0D0F14),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF3B6BFF)),
        ),
      );
    }

    // ── BRANCH 1: Offline Mode ────────────────────────────────────────────
    if (_isOfflineMode) {
      if (!_isLoggedIn) {
        return ModePickerScreen(onOfflineSetupComplete: _recheckOfflineState);
      }
      if (_offlineAuth.hasSessionKey && !_isLocked) {
        return _buildOfflineVault();
      }
      return OfflineUnlockScreen(onUnlocked: _unlockOffline);
    }

    // ── BRANCH 2 & 3: Cloud Mode ──────────────────────────────────────────
    // StreamBuilder is the single source of truth for cloud auth state.
    // No _isLoggedIn pre-check — the stream handles logged-in/out directly,
    // eliminating the race between popUntil() and the async auth listener.
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: Color(0xFF0D0F14),
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_rounded, size: 64, color: Color(0xFF3B6BFF)),
                  SizedBox(height: 16),
                  CircularProgressIndicator(color: Color(0xFF3B6BFF)),
                ],
              ),
            ),
          );
        }

        if (!snapshot.hasData || snapshot.data == null) {
          _isLocked = false;
          return ModePickerScreen(onOfflineSetupComplete: _recheckOfflineState);
        }

        // If locked, push the lock screen and show a plain dark scaffold
        // underneath while waiting for the result.
        if (_isLocked) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _showLockScreen(context);
          });
          return const Scaffold(
            backgroundColor: Color(0xFF0D0F14),
            body: Center(
              child: CircularProgressIndicator(color: Color(0xFF3B6BFF)),
            ),
          );
        }

        // ── Panic Mode: show decoy vault ──────────────────────────────────
        if (_isPanicMode) {
          return _buildDecoyVault();
        }

        // ── Normal: show real vault ───────────────────────────────────────
        return _PostLoginGate(
          isDarkMode: widget.isDarkMode,
          onThemeToggle: widget.onThemeToggle,
        );
      },
    );
  }

  Widget _buildOfflineVault() {
    _offlineRepo ??= LocalVaultRepo(derivedKey: _offlineAuth.sessionKey);
    return VaultScreen(
      isDarkMode: widget.isDarkMode,
      onThemeToggle: widget.onThemeToggle,
      repo: _offlineRepo!,
      isOfflineMode: true,
    );
  }

  /// Builds the decoy vault — uses a separate Firestore collection path
  /// so it's completely isolated from the real vault data.
  Widget _buildDecoyVault() {
    final uid      = FirebaseAuth.instance.currentUser!.uid;
    final decoyRepo = FirestoreVaultRepo(uid: uid, collectionPrefix: 'decoy_');
    return VaultScreen(
      isDarkMode: widget.isDarkMode,
      onThemeToggle: widget.onThemeToggle,
      repo: decoyRepo,
      isOfflineMode: false,
      isPanicMode: true,
    );
  }
}

// ─── _PostLoginGate ───────────────────────────────────────────────────────────

class _PostLoginGate extends StatefulWidget {
  final bool isDarkMode;
  final Function(bool) onThemeToggle;

  const _PostLoginGate({
    required this.isDarkMode,
    required this.onThemeToggle,
  });

  @override
  State<_PostLoginGate> createState() => _PostLoginGateState();
}

class _PostLoginGateState extends State<_PostLoginGate> {
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkSetup());
  }

  Future<void> _checkSetup() async {
    await EncryptionHelper.initCloudKey();
    final mgr  = AppLockManager.instance;
    final done = await mgr.isSetupDone();
    if (!done && mounted) await _showSetupDialog();
    if (mounted) setState(() => _checked = true);
  }

  Future<void> _showSetupDialog() async {
    final mgr          = AppLockManager.instance;
    final fpAvailable  = await mgr.isFingerprintAvailable();
    final faceAvail    = await mgr.isFaceAvailable();
    final bioAvailable = fpAvailable || faceAvail;

    if (!mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _SetupLockDialog(
        bioAvailable: bioAvailable,
        fpAvailable: fpAvailable,
        faceAvailable: faceAvail,
        isDarkMode: widget.isDarkMode,
        onSkip: () async {
          Navigator.pop(ctx);
          await mgr.markSetupDone();
        },
        onPinOnly: () async {
          Navigator.pop(ctx);
          await _setupPin();
        },
        onPinPlusBio: (BiometricMode mode) async {
          Navigator.pop(ctx);
          final pinSet = await _setupPin();
          if (pinSet) {
            await mgr.setFingerprintEnabled(true);
            await mgr.setBiometricMode(mode);
          }
        },
      ),
    );
  }

  Future<bool> _setupPin() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AppLockScreen(
          mode: LockMode.setupPin,
          isDarkMode: widget.isDarkMode,
          onUnlocked: () {},
        ),
      ),
    );
    if (result == true) {
      await AppLockManager.instance.markSetupDone();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked) {
      return const Scaffold(
        backgroundColor: Color(0xFF0D0F14),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF3B6BFF)),
        ),
      );
    }
    final uid  = FirebaseAuth.instance.currentUser!.uid;
    final repo = FirestoreVaultRepo(uid: uid);
    return VaultScreen(
      isDarkMode: widget.isDarkMode,
      onThemeToggle: widget.onThemeToggle,
      repo: repo,
      isOfflineMode: false,
    );
  }
}

// ─── Setup Lock Dialog ────────────────────────────────────────────────────────

class _SetupLockDialog extends StatefulWidget {
  final bool bioAvailable;
  final bool fpAvailable;
  final bool faceAvailable;
  final bool isDarkMode;
  final VoidCallback onSkip;
  final VoidCallback onPinOnly;
  final Function(BiometricMode) onPinPlusBio;

  const _SetupLockDialog({
    required this.bioAvailable,
    required this.fpAvailable,
    required this.faceAvailable,
    required this.isDarkMode,
    required this.onSkip,
    required this.onPinOnly,
    required this.onPinPlusBio,
  });

  @override
  State<_SetupLockDialog> createState() => _SetupLockDialogState();
}

class _SetupLockDialogState extends State<_SetupLockDialog> {
  late BiometricMode _selectedMode;

  @override
  void initState() {
    super.initState();
    if (widget.fpAvailable && widget.faceAvailable) {
      _selectedMode = BiometricMode.both;
    } else if (widget.faceAvailable) {
      _selectedMode = BiometricMode.face;
    } else {
      _selectedMode = BiometricMode.fingerprint;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Row(children: [
        Icon(Icons.security, color: Color(0xFF3B6BFF)),
        SizedBox(width: 12),
        Text('Secure your vault'),
      ]),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Add a lock so only you can open ObexVault. '
            'You can change this later in Settings.',
          ),

          if (widget.bioAvailable) ...[
            const SizedBox(height: 20),
            const Text(
              'Biometric type',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: Color(0xFF3B6BFF),
              ),
            ),
            const SizedBox(height: 8),

            if (widget.fpAvailable)
              _bioOption(
                mode: BiometricMode.fingerprint,
                icon: Icons.fingerprint,
                label: 'Fingerprint',
              ),

            if (widget.faceAvailable)
              _bioOption(
                mode: BiometricMode.face,
                icon: Icons.face_unlock_rounded,
                label: 'Face',
              ),

            if (widget.fpAvailable && widget.faceAvailable)
              _bioOption(
                mode: BiometricMode.both,
                icon: Icons.shield_rounded,
                label: 'Both (whichever works first)',
              ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: widget.onSkip,
          child: const Text('Skip', style: TextStyle(color: Colors.grey)),
        ),
        TextButton(
          onPressed: widget.onPinOnly,
          child: const Text('PIN only',
              style: TextStyle(color: Color(0xFF3B6BFF))),
        ),
        if (widget.bioAvailable)
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF3B6BFF),
              foregroundColor: Colors.white,
            ),
            onPressed: () => widget.onPinPlusBio(_selectedMode),
            child: const Text('PIN + Biometrics'),
          ),
      ],
    );
  }

  Widget _bioOption({
    required BiometricMode mode,
    required IconData icon,
    required String label,
  }) {
    final selected = _selectedMode == mode;
    return GestureDetector(
      onTap: () => setState(() => _selectedMode = mode),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? const Color(0xFF3B6BFF) : Colors.grey.shade300,
            width: selected ? 2 : 1,
          ),
          color: selected
              ? const Color(0xFF3B6BFF).withOpacity(0.07)
              : Colors.transparent,
        ),
        child: Row(
          children: [
            Icon(icon,
                size: 22,
                color: selected
                    ? const Color(0xFF3B6BFF)
                    : Colors.grey.shade600),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                fontWeight:
                    selected ? FontWeight.w600 : FontWeight.normal,
                color: selected
                    ? const Color(0xFF3B6BFF)
                    : Colors.grey.shade700,
              ),
            ),
            const Spacer(),
            if (selected)
              const Icon(Icons.check_circle_rounded,
                  size: 18, color: Color(0xFF3B6BFF)),
          ],
        ),
      ),
    );
  }
}
