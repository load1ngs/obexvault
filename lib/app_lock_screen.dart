import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'app_lock_manager.dart';

enum LockMode { unlock, setupPin }

class AppLockScreen extends StatefulWidget {
  final LockMode mode;
  final bool isDarkMode;
  final VoidCallback onUnlocked;

  /// Called instead of [onUnlocked] when the user enters the Panic PIN.
  /// The vault screen should open the decoy vault when this fires.
  final VoidCallback? onPanicUnlocked;

  const AppLockScreen({
    super.key,
    required this.mode,
    required this.isDarkMode,
    required this.onUnlocked,
    this.onPanicUnlocked,
  });

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  final _manager = AppLockManager.instance;
  static const _storage = FlutterSecureStorage();

  String _enteredPin          = '';
  String _firstPin            = '';
  bool   _confirmingPin       = false;
  bool   _showPinPad          = false;
  String _statusMsg           = '';
  int    _failedBioAttempts   = 0;

  // Resolved once in initState so the icon doesn't flicker
  BiometricMode _biometricMode = BiometricMode.both;

  @override
  void initState() {
    super.initState();
    if (widget.mode == LockMode.unlock) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _initBiometric());
    } else {
      setState(() => _showPinPad = true);
    }
  }

  Future<void> _initBiometric() async {
    final mode = await _manager.getBiometricMode();
    if (mounted) setState(() => _biometricMode = mode);
    await _tryBiometric();
  }

  Future<void> _tryBiometric() async {
    final fpEnabled   = await _manager.isFingerprintEnabled();
    final fpAvailable = await _manager.isFingerprintAvailable();

    if (!fpEnabled || !fpAvailable) {
      if (mounted) setState(() => _showPinPad = true);
      return;
    }

    final result = await _manager.authenticateFingerprint();
    if (!mounted) return;

    if (result == 'success') {
      widget.onUnlocked();
      if (mounted && Navigator.canPop(context)) Navigator.pop(context, true);
      return;
    }

    if (result == 'unavailable') {
      setState(() {
        _showPinPad = true;
        _statusMsg  = 'Biometrics unavailable. Enter PIN.';
      });
      return;
    }

    if (result == 'locked_out') {
      setState(() {
        _showPinPad = true;
        _statusMsg  = 'Too many attempts. Use PIN.';
      });
      return;
    }

    // 'fail' → user cancelled or scan failed
    _failedBioAttempts++;
    if (_failedBioAttempts >= 3) {
      await _forceLogout();
      return;
    }
    setState(() {
      _showPinPad = true;
      _statusMsg  = 'Biometric failed ($_failedBioAttempts/3). Use PIN.';
    });
  }

  Future<void> _forceLogout() async {
    await FirebaseAuth.instance.signOut();
    await GoogleSignIn().signOut();
  }

  void _onDigit(String d) {
    if (_enteredPin.length >= 4) return;
    setState(() => _enteredPin += d);
    if (_enteredPin.length == 4) {
      Future.delayed(const Duration(milliseconds: 150), _onPinComplete);
    }
  }

  void _onBackspace() {
    if (_enteredPin.isEmpty) return;
    setState(() => _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1));
  }

  Future<void> _onPinComplete() async {
    if (widget.mode == LockMode.unlock) {
      await _verifyUnlockPin();
    } else {
      await _handleSetupPin();
    }
  }

  Future<void> _verifyUnlockPin() async {
    // Capture the PIN immediately before any awaits — prevents async race
    // condition where _enteredPin gets cleared by setState before we finish.
    final pinToCheck = _enteredPin;

    // 1. Check real PIN first
    final ok = await _manager.verifyPin(pinToCheck);
    if (!mounted) return;

    if (ok) {
      widget.onUnlocked();
      if (mounted && Navigator.canPop(context)) Navigator.pop(context, true);
      return;
    }

    // 2. Check if Panic Mode is enabled and this is the panic PIN
    final panicEnabled = await _storage.read(key: 'panic_mode_enabled');
    final panicPin     = await _storage.read(key: 'panic_pin');
    if (!mounted) return;

    if (panicEnabled == 'true' && panicPin != null && pinToCheck == panicPin) {
      // Panic PIN matched — open decoy vault silently (no error shown)
      if (widget.onPanicUnlocked != null) {
        widget.onPanicUnlocked!();
      } else {
        widget.onUnlocked();
      }
      if (mounted && Navigator.canPop(context)) Navigator.pop(context, 'panic');
      return;
    }

    // 3. Wrong PIN
    setState(() {
      _statusMsg  = 'Wrong PIN';
      _enteredPin = '';
    });
  }

  Future<void> _handleSetupPin() async {
    if (!_confirmingPin) {
      setState(() {
        _firstPin      = _enteredPin;
        _enteredPin    = '';
        _confirmingPin = true;
        _statusMsg     = '';
      });
    } else {
      if (_enteredPin == _firstPin) {
        await _manager.setPin(_enteredPin);
        if (!mounted) return;
        Navigator.pop(context, true);
      } else {
        setState(() {
          _statusMsg     = "PINs don't match. Try again.";
          _enteredPin    = '';
          _firstPin      = '';
          _confirmingPin = false;
        });
      }
    }
  }

  String _titleText() {
    if (widget.mode == LockMode.unlock) return 'Enter PIN';
    return _confirmingPin ? 'Confirm PIN' : 'Set a 4-digit PIN';
  }

  IconData get _bioIcon {
    switch (_biometricMode) {
      case BiometricMode.face:        return Icons.face_unlock_rounded;
      case BiometricMode.fingerprint: return Icons.fingerprint;
      case BiometricMode.both:        return Icons.fingerprint;
    }
  }

  String get _bioLabel {
    switch (_biometricMode) {
      case BiometricMode.face:        return 'Look at the camera to unlock';
      case BiometricMode.fingerprint: return 'Touch the fingerprint sensor';
      case BiometricMode.both:        return 'Use fingerprint or face to unlock';
    }
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.isDarkMode
        ? const Color(0xFF121212)
        : const Color(0xFFF0F2F5);
    return WillPopScope(
      onWillPop: () async => widget.mode != LockMode.unlock,
      child: Scaffold(
        backgroundColor: bg,
        body: SafeArea(
          child: !_showPinPad
              ? _buildBiometricScreen()
              : _buildPinPadScreen(),
        ),
      ),
    );
  }

  Widget _buildBiometricScreen() {
    final textColor = widget.isDarkMode ? Colors.white : Colors.black87;
    final subColor  = widget.isDarkMode ? Colors.white54 : Colors.black54;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.lock_rounded, size: 56, color: Color(0xFF1A237E)),
          const SizedBox(height: 16),
          Text(
            'ObexVault',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: textColor,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 60),

          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF1A237E).withOpacity(0.1),
            ),
            child: Icon(_bioIcon, size: 80, color: const Color(0xFF1A237E)),
          ),

          if (_biometricMode == BiometricMode.both) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.fingerprint, size: 20, color: subColor),
                const SizedBox(width: 6),
                Text('or', style: TextStyle(color: subColor, fontSize: 13)),
                const SizedBox(width: 6),
                Icon(Icons.face_unlock_rounded, size: 20, color: subColor),
              ],
            ),
          ],

          const SizedBox(height: 16),
          Text(_bioLabel, style: TextStyle(fontSize: 14, color: subColor)),
          const SizedBox(height: 40),

          TextButton(
            onPressed: () => setState(() => _showPinPad = true),
            child: const Text(
              'Use PIN instead',
              style: TextStyle(color: Color(0xFF1A237E)),
            ),
          ),
          TextButton(
            onPressed: _tryBiometric,
            child: Text('Retry', style: TextStyle(color: subColor)),
          ),
        ],
      ),
    );
  }

  Widget _buildPinPadScreen() {
    final textColor = widget.isDarkMode ? Colors.white : Colors.black87;
    final subColor  = widget.isDarkMode ? Colors.white54 : Colors.black54;

    return Column(
      children: [
        const SizedBox(height: 40),
        const Icon(Icons.lock_rounded, size: 48, color: Color(0xFF1A237E)),
        const SizedBox(height: 16),
        Text(
          _titleText(),
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 20,
          child: _statusMsg.isEmpty
              ? null
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    _statusMsg,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                  ),
                ),
        ),
        const SizedBox(height: 24),
        _buildPinDots(),
        const Spacer(),

        if (widget.mode == LockMode.unlock)
          TextButton.icon(
            onPressed: () {
              setState(() {
                _showPinPad = false;
                _statusMsg  = '';
                _enteredPin = '';
              });
              Future.delayed(
                const Duration(milliseconds: 100),
                _tryBiometric,
              );
            },
            icon: Icon(_bioIcon, size: 18, color: subColor),
            label: Text(
              'Use biometrics instead',
              style: TextStyle(color: subColor, fontSize: 13),
            ),
          ),

        _buildKeypad(),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildPinDots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (i) {
        final filled = i < _enteredPin.length;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 10),
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? const Color(0xFF1A237E) : Colors.transparent,
            border: Border.all(color: const Color(0xFF1A237E), width: 2),
          ),
        );
      }),
    );
  }

  Widget _buildKeypad() {
    final keys = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['', '0', 'del'],
    ];
    final textColor = widget.isDarkMode ? Colors.white : Colors.black87;
    final bgColor   = widget.isDarkMode ? Colors.white10 : Colors.black.withOpacity(0.05);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        children: keys.map((row) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: row.map((k) {
              if (k.isEmpty) return const SizedBox(width: 70, height: 70);
              if (k == 'del') {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(40),
                    onTap: _onBackspace,
                    child: Container(
                      width: 70, height: 70,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: bgColor),
                      child: Icon(Icons.backspace_outlined, size: 24, color: textColor),
                    ),
                  ),
                );
              }
              return _keyButton(k, onTap: () => _onDigit(k));
            }).toList(),
          );
        }).toList(),
      ),
    );
  }

  Widget _keyButton(String label, {required VoidCallback onTap}) {
    final textColor = widget.isDarkMode ? Colors.white : Colors.black87;
    final bgColor   = widget.isDarkMode
        ? Colors.white10
        : Colors.black.withOpacity(0.05);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(40),
        onTap: onTap,
        child: Container(
          width: 70,
          height: 70,
          alignment: Alignment.center,
          decoration: BoxDecoration(shape: BoxShape.circle, color: bgColor),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w500,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }
}
