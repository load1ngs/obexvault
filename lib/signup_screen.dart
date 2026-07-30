import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'offline_auth_manager.dart';

// ─────────────────────────────────────────────
//  Theme constants (matches the rest of the app)
// ─────────────────────────────────────────────
class _C {
  // dark
  static const bgDark        = Color(0xFF0D0F14);
  static const surfaceDark   = Color(0xFF141720);
  static const surface2Dark  = Color(0xFF1A1E28);
  static const borderDark    = Color(0xFF252A38);
  static const textDark      = Color(0xFFECEEF4);
  static const textSubDark   = Color(0xFF8892A8);
  static const textDimDark   = Color(0xFF555E75);
  // light
  static const bgLight       = Color(0xFFF0F2F7);
  static const surfaceLight  = Color(0xFFFFFFFF);
  static const surface2Light = Color(0xFFF5F6FA);
  static const borderLight   = Color(0xFFDDE1EC);
  static const textLight     = Color(0xFF0D0F14);
  static const textSubLight  = Color(0xFF5A6278);
  static const textDimLight  = Color(0xFF9BA3B8);
  // shared
  static const accent        = Color(0xFF3B6BFF);
  static const accentTeal    = Color(0xFF00C896);
  static const warnBorder    = Color(0x40F0B429);
  static const warnText      = Color(0xFFF0B429);
  static const errorRed      = Color(0xFFFF6B6B);
}

// ─────────────────────────────────────────────
//  Widget
// ─────────────────────────────────────────────
class SignupScreen extends StatefulWidget {
  final bool isDarkMode;
  final ValueChanged<bool> onThemeToggle;
  final String? initialMode; // 'cloud' | 'offline' | null (show picker)

  final VoidCallback? onOfflineSetupComplete;

  const SignupScreen({
    super.key,
    this.isDarkMode = false,
    this.onThemeToggle = _noOpToggle,
    this.initialMode, // null = show mode cards (standalone use from LoginScreen)
    this.onOfflineSetupComplete,
  });

  // Default no-op so LoginScreen can call SignupScreen() without params
  static void _noOpToggle(bool _) {}

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

enum _VaultMode { cloud, offline }

class _SignupScreenState extends State<SignupScreen>
    with SingleTickerProviderStateMixin {
  late _VaultMode _mode;

  // Cloud controllers
  final _emailCtrl    = TextEditingController();
  final _cloudPwCtrl  = TextEditingController();
  final _cloudCfmCtrl = TextEditingController();

  // Offline controllers
  final _nameCtrl     = TextEditingController();
  final _offPwCtrl    = TextEditingController();
  final _offCfmCtrl   = TextEditingController();

  bool _obscurePw1  = true;
  bool _obscurePw2  = true;
  bool _obscureOp1  = true;
  bool _obscureOp2  = true;
  bool _isLoading   = false;

  late AnimationController _animCtrl;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();

    // Pre-select mode if coming from ModePickerScreen; default to cloud otherwise
    _mode = widget.initialMode == 'offline'
        ? _VaultMode.offline
        : _VaultMode.cloud;

    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
    _animCtrl.forward();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    _emailCtrl.dispose();
    _cloudPwCtrl.dispose();
    _cloudCfmCtrl.dispose();
    _nameCtrl.dispose();
    _offPwCtrl.dispose();
    _offCfmCtrl.dispose();
    super.dispose();
  }

  // ── helpers ──────────────────────────────────
  bool get _dark => widget.isDarkMode;

  // true when mode was pre-selected by ModePickerScreen
  bool get _modePreSelected => widget.initialMode != null;

  Color get _bg       => _dark ? _C.bgDark       : _C.bgLight;
  Color get _surface  => _dark ? _C.surfaceDark   : _C.surfaceLight;
  Color get _surface2 => _dark ? _C.surface2Dark  : _C.surface2Light;
  Color get _border   => _dark ? _C.borderDark    : _C.borderLight;
  Color get _text     => _dark ? _C.textDark      : _C.textLight;
  Color get _textSub  => _dark ? _C.textSubDark   : _C.textSubLight;
  Color get _textDim  => _dark ? _C.textDimDark   : _C.textDimLight;

  void _switchMode(_VaultMode m) {
    if (_mode == m) return;
    _animCtrl.reset();
    setState(() => _mode = m);
    _animCtrl.forward();
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontFamily: 'DMSans')),
      backgroundColor: _C.errorRed,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(16),
    ));
  }

  // ── Cloud sign-up (email) ─────────────────────
  Future<void> _signUpCloud() async {
    final email = _emailCtrl.text.trim();
    final pw    = _cloudPwCtrl.text;
    final cfm   = _cloudCfmCtrl.text;

    if (email.isEmpty)       return _showError('Please enter your email');
    if (pw.length < 6)       return _showError('Password must be at least 6 characters');
    if (pw != cfm)           return _showError('Passwords do not match');

    setState(() => _isLoading = true);
    try {
      await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email, password: pw,
      );
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
    } on FirebaseAuthException catch (e) {
      final msg = switch (e.code) {
        'weak-password'        => 'Password is too weak',
        'email-already-in-use' => 'An account already exists with this email',
        'invalid-email'        => 'Invalid email address',
        _                      => 'Something went wrong',
      };
      _showError(msg);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── Cloud sign-up (Google) ────────────────────
  Future<void> _signInWithGoogle() async {
    setState(() => _isLoading = true);
    try {
      final googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) { setState(() => _isLoading = false); return; }

      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken:     googleAuth.idToken,
      );
      await FirebaseAuth.instance.signInWithCredential(credential);
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (_) {
      _showError('Google sign-in failed. Please try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── Offline sign-up ───────────────────────────
  Future<void> _signUpOffline() async {
    final name = _nameCtrl.text.trim();
    final pw   = _offPwCtrl.text;
    final cfm  = _offCfmCtrl.text;

    if (name.isEmpty)   return _showError('Please enter your name');
    if (pw.length < 8)  return _showError('Master password must be at least 8 characters');
    if (pw != cfm)      return _showError('Passwords do not match');

    setState(() => _isLoading = true);
    try {
      final manager = OfflineAuthManager();
      // setupOfflineUser returns void — key is held in manager.sessionKey
      await manager.setupOfflineUser(
        displayName: name,
        masterPassword: pw,
      );
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      widget.onOfflineSetupComplete?.call();
    } catch (e) {
      _showError('Failed to create offline vault: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ─────────────────────────────────────────────
  //  Build
  // ─────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildNav(),
              const SizedBox(height: 18),
              _buildHeader(),
              const SizedBox(height: 24),
              // Only show mode cards when NOT pre-selected by ModePickerScreen
              if (!_modePreSelected) ...[
                _buildModeCards(),
                const SizedBox(height: 24),
              ],
              FadeTransition(
                opacity: _fadeAnim,
                child: _mode == _VaultMode.cloud
                    ? _buildCloudForm()
                    : _buildOfflineForm(),
              ),
              const SizedBox(height: 20),
              _buildLoginRow(),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  // ── Nav bar ───────────────────────────────────
  Widget _buildNav() {
    final canGoBack = Navigator.canPop(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(children: [
            // Back arrow — shown when coming from ModePickerScreen or LoginScreen
            if (canGoBack) ...[
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: _dark
                        ? const Color(0xFF1A1E28)
                        : const Color(0xFFF0F2F7),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _border, width: 1.5),
                  ),
                  child: Icon(
                    Icons.arrow_back_rounded,
                    size: 16,
                    color: _textSub,
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Icon(Icons.lock_rounded, size: 15, color: _C.accent),
            const SizedBox(width: 7),
            Text('OBEX VAULT',
              style: TextStyle(
                fontFamily: 'DMSans',
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: _textSub,
                letterSpacing: .08,
              ),
            ),
          ]),
          // "Login" link — only show when no back arrow context
          if (!canGoBack)
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Text('Login',
                style: TextStyle(
                  fontFamily: 'DMSans',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _C.accent,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Header ────────────────────────────────────
  Widget _buildHeader() {
    final subtitle = _modePreSelected
        ? (_mode == _VaultMode.offline
            ? 'Setting up your offline vault.'
            : 'Setting up your cloud vault.')
        : 'Storage mode selection.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Create Account',
          style: TextStyle(
            fontFamily: 'DMSans',
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: _text,
            letterSpacing: -.03,
          ),
        ),
        const SizedBox(height: 4),
        Text(subtitle,
          style: TextStyle(
            fontFamily: 'DMSans',
            fontSize: 13,
            fontWeight: FontWeight.w400,
            color: _textSub,
          ),
        ),
      ],
    );
  }

  // ── Mode cards ────────────────────────────────
  Widget _buildModeCards() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('SELECT MODE',
          style: TextStyle(
            fontFamily: 'DMSans',
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: _textDim,
            letterSpacing: .12,
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _ModeCard(
            label: 'Cloud Mode',
            description: 'Sync across devices via Firebase',
            icon: Icons.cloud_outlined,
            isActive: _mode == _VaultMode.cloud,
            activeColor: _C.accent,
            surface: _surface,
            surface2: _surface2,
            border: _border,
            text: _text,
            textDim: _textDim,
            onTap: () => _switchMode(_VaultMode.cloud),
          )),
          const SizedBox(width: 10),
          Expanded(child: _ModeCard(
            label: 'Offline Mode',
            description: 'Stored only on this device locally',
            icon: Icons.wifi_off_rounded,
            isActive: _mode == _VaultMode.offline,
            activeColor: _C.accentTeal,
            surface: _surface,
            surface2: _surface2,
            border: _border,
            text: _text,
            textDim: _textDim,
            onTap: () => _switchMode(_VaultMode.offline),
          )),
        ]),
      ],
    );
  }

  // ── Cloud form ────────────────────────────────
  Widget _buildCloudForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GoogleButton(
          surface: _surface,
          border: _border,
          text: _text,
          isLoading: _isLoading,
          onTap: _signInWithGoogle,
        ),
        const SizedBox(height: 16),
        _OrDivider(border: _border, textDim: _textDim),
        const SizedBox(height: 16),
        _InputField(
          label: 'Email Address',
          hint: 'name@domain.com',
          controller: _emailCtrl,
          icon: Icons.email_outlined,
          keyboardType: TextInputType.emailAddress,
          accentColor: _C.accent,
          surface: _surface,
          surface2: _surface2,
          border: _border,
          text: _text,
          textSub: _textSub,
          textDim: _textDim,
        ),
        const SizedBox(height: 12),
        _InputField(
          label: 'Master Password',
          hint: '••••••••••••',
          controller: _cloudPwCtrl,
          icon: Icons.lock_outline_rounded,
          obscure: _obscurePw1,
          onToggleObscure: () => setState(() => _obscurePw1 = !_obscurePw1),
          accentColor: _C.accent,
          surface: _surface,
          surface2: _surface2,
          border: _border,
          text: _text,
          textSub: _textSub,
          textDim: _textDim,
        ),
        const SizedBox(height: 12),
        _InputField(
          label: 'Confirm Password',
          hint: '••••••••••••',
          controller: _cloudCfmCtrl,
          icon: Icons.lock_outline_rounded,
          obscure: _obscurePw2,
          onToggleObscure: () => setState(() => _obscurePw2 = !_obscurePw2),
          accentColor: _C.accent,
          surface: _surface,
          surface2: _surface2,
          border: _border,
          text: _text,
          textSub: _textSub,
          textDim: _textDim,
        ),
        const SizedBox(height: 20),
        _CtaButton(
          label: 'Create Cloud Vault',
          icon: Icons.cloud_upload_outlined,
          color: _C.accent,
          textColor: Colors.white,
          isLoading: _isLoading,
          onTap: _signUpCloud,
        ),
      ],
    );
  }

  // ── Offline form ──────────────────────────────
  Widget _buildOfflineForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _InputField(
          label: 'Display Name',
          hint: 'Your name',
          controller: _nameCtrl,
          icon: Icons.person_outline_rounded,
          accentColor: _C.accentTeal,
          surface: _surface,
          surface2: _surface2,
          border: _border,
          text: _text,
          textSub: _textSub,
          textDim: _textDim,
        ),
        const SizedBox(height: 12),
        _InputField(
          label: 'Master Password',
          hint: '••••••••••••',
          controller: _offPwCtrl,
          icon: Icons.key_outlined,
          obscure: _obscureOp1,
          onToggleObscure: () => setState(() => _obscureOp1 = !_obscureOp1),
          accentColor: _C.accentTeal,
          surface: _surface,
          surface2: _surface2,
          border: _border,
          text: _text,
          textSub: _textSub,
          textDim: _textDim,
        ),
        const SizedBox(height: 12),
        _InputField(
          label: 'Confirm Master Password',
          hint: '••••••••••••',
          controller: _offCfmCtrl,
          icon: Icons.key_outlined,
          obscure: _obscureOp2,
          onToggleObscure: () => setState(() => _obscureOp2 = !_obscureOp2),
          accentColor: _C.accentTeal,
          surface: _surface,
          surface2: _surface2,
          border: _border,
          text: _text,
          textSub: _textSub,
          textDim: _textDim,
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: _C.warnBorder.withOpacity(.07),
            border: Border.all(color: _C.warnBorder),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.warning_amber_rounded,
                size: 16, color: _C.warnText),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Vaults cannot be recovered if you forget your master password.',
                  style: const TextStyle(
                    fontFamily: 'DMSans',
                    fontSize: 12,
                    color: _C.warnText,
                    height: 1.6,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _CtaButton(
          label: 'Create Offline Vault',
          icon: Icons.lock_rounded,
          color: _C.accentTeal,
          textColor: const Color(0xFF051A15),
          isLoading: _isLoading,
          onTap: _signUpOffline,
        ),
      ],
    );
  }

  // ── Login row ─────────────────────────────────
  Widget _buildLoginRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('Already have an account?',
          style: TextStyle(
            fontFamily: 'DMSans',
            fontSize: 13,
            color: _textSub,
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(
            foregroundColor: _C.accent,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Login',
            style: TextStyle(
              fontFamily: 'DMSans',
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
//  Sub-widgets
// ─────────────────────────────────────────────

class _ModeCard extends StatelessWidget {
  final String label;
  final String description;
  final IconData icon;
  final bool isActive;
  final Color activeColor;
  final Color surface, surface2, border, text, textDim;
  final VoidCallback onTap;

  const _ModeCard({
    required this.label,
    required this.description,
    required this.icon,
    required this.isActive,
    required this.activeColor,
    required this.surface,
    required this.surface2,
    required this.border,
    required this.text,
    required this.textDim,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isActive ? activeColor.withOpacity(.06) : surface,
          border: Border.all(
            color: isActive ? activeColor : border,
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(
                    color: isActive
                        ? activeColor.withOpacity(.15)
                        : surface2,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon,
                    size: 16,
                    color: isActive ? activeColor : textDim,
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 14, height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isActive ? activeColor : Colors.transparent,
                    border: Border.all(
                      color: isActive ? activeColor : border,
                      width: 1.5,
                    ),
                    boxShadow: isActive ? [
                      BoxShadow(
                        color: activeColor.withOpacity(.3),
                        blurRadius: 6,
                        spreadRadius: 1,
                      ),
                    ] : [],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(label,
              style: TextStyle(
                fontFamily: 'DMSans',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isActive ? activeColor : text,
              ),
            ),
            const SizedBox(height: 3),
            Text(description,
              style: TextStyle(
                fontFamily: 'DMSans',
                fontSize: 11,
                color: textDim,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InputField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final IconData icon;
  final bool? obscure;
  final VoidCallback? onToggleObscure;
  final TextInputType? keyboardType;
  final Color accentColor;
  final Color surface, surface2, border, text, textSub, textDim;

  const _InputField({
    required this.label,
    required this.hint,
    required this.controller,
    required this.icon,
    this.obscure,
    this.onToggleObscure,
    this.keyboardType,
    required this.accentColor,
    required this.surface,
    required this.surface2,
    required this.border,
    required this.text,
    required this.textSub,
    required this.textDim,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(),
          style: TextStyle(
            fontFamily: 'DMSans',
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: textSub,
            letterSpacing: .04,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure ?? false,
          keyboardType: keyboardType,
          style: TextStyle(
            fontFamily: 'DMSans',
            fontSize: 14,
            color: text,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              fontFamily: 'DMSans',
              fontSize: 14,
              color: textDim,
            ),
            filled: true,
            fillColor: surface,
            prefixIcon: Icon(icon, size: 16, color: textDim),
            suffixIcon: onToggleObscure != null
                ? IconButton(
                    icon: Icon(
                      obscure! ? Icons.visibility_off_outlined
                               : Icons.visibility_outlined,
                      size: 16,
                      color: textDim,
                    ),
                    onPressed: onToggleObscure,
                  )
                : null,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: border, width: 1.5),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: border, width: 1.5),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: accentColor, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

class _GoogleButton extends StatelessWidget {
  final Color surface, border, text;
  final bool isLoading;
  final VoidCallback onTap;

  const _GoogleButton({
    required this.surface,
    required this.border,
    required this.text,
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 50,
      child: OutlinedButton(
        onPressed: isLoading ? null : onTap,
        style: OutlinedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF1F1F1F),
          side: const BorderSide(color: Color(0xFFDDE1EC), width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 18, height: 18,
              child: CustomPaint(painter: _GoogleLogoPainter()),
            ),
            const SizedBox(width: 10),
            const Text('Sign in with Google',
              style: TextStyle(
                fontFamily: 'DMSans',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1F1F1F),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GoogleLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final paint = Paint()..style = PaintingStyle.fill;
    paint.color = const Color(0xFF4285F4);
    canvas.drawArc(rect, -1.57, 3.14, true, paint);
    paint.color = const Color(0xFFEA4335);
    canvas.drawArc(rect, -1.57, -1.57, true, paint);
    paint.color = const Color(0xFFFBBC05);
    canvas.drawArc(rect, 1.57, 1.57, true, paint);
    paint.color = const Color(0xFF34A853);
    canvas.drawArc(rect, 0, 1.57, true, paint);
    paint.color = Colors.white;
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      size.width * 0.35,
      paint,
    );
  }

  @override
  bool shouldRepaint(_) => false;
}

class _OrDivider extends StatelessWidget {
  final Color border, textDim;
  const _OrDivider({required this.border, required this.textDim});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(child: Divider(color: border, thickness: 1)),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text('OR',
          style: TextStyle(
            fontFamily: 'DMSans',
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: textDim,
            letterSpacing: .1,
          ),
        ),
      ),
      Expanded(child: Divider(color: border, thickness: 1)),
    ]);
  }
}

class _CtaButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color, textColor;
  final bool isLoading;
  final VoidCallback onTap;

  const _CtaButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.textColor,
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        onPressed: isLoading ? null : onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: textColor,
          disabledBackgroundColor: color.withOpacity(.5),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10)),
        ),
        child: isLoading
            ? SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: textColor,
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 17, color: textColor),
                  const SizedBox(width: 8),
                  Text(label,
                    style: TextStyle(
                      fontFamily: 'DMSans',
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
