import 'package:flutter/material.dart';
import 'offline_auth_manager.dart';

/// Shown when:
///   1. Offline user opens the app for the first time (no session key yet)
///   2. App returns from background and session key was dropped
///
/// Takes master password → calls OfflineAuthManager().unlockWithMasterPassword()
/// → calls onUnlocked() on success.
class OfflineUnlockScreen extends StatefulWidget {
  final VoidCallback onUnlocked;

  const OfflineUnlockScreen({
    super.key,
    required this.onUnlocked,
  });

  @override
  State<OfflineUnlockScreen> createState() => _OfflineUnlockScreenState();
}

class _OfflineUnlockScreenState extends State<OfflineUnlockScreen> {
  final _pwController = TextEditingController();
  final _focusNode    = FocusNode();
  bool _obscure    = true;
  bool _isLoading  = false;
  String? _errorMsg;

  // ── Theme helpers (reads from FlutterSecureStorage via main ThemeLoader)
  // We keep it simple here — the unlock screen always uses dark theme
  // since it appears before the full app theme is accessible.
  static const _bg       = Color(0xFF0D0F14);
  static const _surface  = Color(0xFF141720);
  static const _border   = Color(0xFF252A38);
  static const _accent   = Color(0xFF3B6BFF);
  static const _text     = Color(0xFFECEEF4);
  static const _textSub  = Color(0xFF8892A8);
  static const _textDim  = Color(0xFF555E75);
  static const _errorRed = Color(0xFFFF6B6B);
  static const _errBg    = Color(0x12FF6B6B);
  static const _errBdr   = Color(0x40FF6B6B);

  @override
  void initState() {
    super.initState();
    // Auto-focus the password field on open
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _pwController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final pw = _pwController.text;
    if (pw.isEmpty) {
      setState(() => _errorMsg = 'Please enter your master password');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMsg  = null;
    });

    try {
      // Argon2id derivation — takes ~1–2s on mid-range device
      await OfflineAuthManager().unlockWithMasterPassword(pw);
      if (mounted) widget.onUnlocked();
    } on WrongPasswordException {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMsg  = 'Incorrect master password. Please try again.';
          _pwController.clear();
        });
        _focusNode.requestFocus();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMsg  = 'Failed to unlock vault: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildLockIcon(),
                const SizedBox(height: 28),
                _buildHeader(),
                const SizedBox(height: 36),
                _buildPasswordField(),
                const SizedBox(height: 8),
                _buildErrorBox(),
                const SizedBox(height: 24),
                _buildUnlockButton(),
                const SizedBox(height: 48),
                _buildArgonNote(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Lock icon with subtle glow ─────────────────────────────────────────
  Widget _buildLockIcon() {
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        color: _accent.withOpacity(0.1),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: _accent.withOpacity(0.15),
            blurRadius: 32,
            spreadRadius: 8,
          ),
        ],
      ),
      child: const Icon(
        Icons.lock_rounded,
        size: 36,
        color: _accent,
      ),
    );
  }

  // ── Header ──────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Column(
      children: [
        const Text(
          'Vault Locked',
          style: TextStyle(
            fontFamily: 'DMSans',
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: _text,
            letterSpacing: -.03,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Enter your master password to unlock',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'DMSans',
            fontSize: 13,
            color: _textSub,
            height: 1.5,
          ),
        ),
      ],
    );
  }

  // ── Password field ───────────────────────────────────────────────────────
  Widget _buildPasswordField() {
    final hasError = _errorMsg != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'MASTER PASSWORD',
          style: TextStyle(
            fontFamily: 'DMSans',
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: _textSub,
            letterSpacing: .04,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _pwController,
          focusNode: _focusNode,
          obscureText: _obscure,
          enabled: !_isLoading,
          onSubmitted: (_) => _unlock(),
          style: const TextStyle(
            fontFamily: 'DMSans',
            fontSize: 14,
            color: _text,
          ),
          decoration: InputDecoration(
            hintText: '••••••••••••',
            hintStyle: const TextStyle(
              fontFamily: 'DMSans',
              fontSize: 14,
              color: _textDim,
            ),
            filled: true,
            fillColor: _surface,
            prefixIcon: const Icon(
              Icons.key_rounded,
              size: 18,
              color: _textDim,
            ),
            suffixIcon: IconButton(
              icon: Icon(
                _obscure
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 18,
                color: _textDim,
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14, vertical: 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: _border, width: 1.5),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                color: hasError ? _errorRed : _border,
                width: 1.5,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                color: hasError ? _errorRed : _accent,
                width: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Error box ────────────────────────────────────────────────────────────
  Widget _buildErrorBox() {
    if (_errorMsg == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _errBg,
        border: Border.all(color: _errBdr),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              size: 15, color: _errorRed),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorMsg!,
              style: const TextStyle(
                fontFamily: 'DMSans',
                fontSize: 12,
                color: _errorRed,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Unlock button ────────────────────────────────────────────────────────
  Widget _buildUnlockButton() {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _unlock,
        style: ElevatedButton.styleFrom(
          backgroundColor: _accent,
          foregroundColor: Colors.white,
          disabledBackgroundColor: _accent.withOpacity(0.5),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: _isLoading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              )
            : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_open_rounded, size: 18),
                  SizedBox(width: 8),
                  Text(
                    'Unlock Vault',
                    style: TextStyle(
                      fontFamily: 'DMSans',
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  // ── Argon2id note ────────────────────────────────────────────────────────
  Widget _buildArgonNote() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.shield_outlined, size: 13, color: _textDim),
        const SizedBox(width: 6),
        const Text(
          'Protected with Argon2id key derivation',
          style: TextStyle(
            fontFamily: 'DMSans',
            fontSize: 11,
            color: _textDim,
          ),
        ),
      ],
    );
  }
}
