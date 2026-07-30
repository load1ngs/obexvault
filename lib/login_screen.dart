import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'signup_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailCtrl    = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscure    = true;
  bool _isLoading  = false;

  // ── colours (dark — matches signup / unlock screens) ──────────────────
  static const _bg       = Color(0xFF0D0F14);
  static const _surface  = Color(0xFF141720);
  static const _surface2 = Color(0xFF1A1E28);
  static const _border   = Color(0xFF252A38);
  static const _accent   = Color(0xFF3B6BFF);
  static const _text     = Color(0xFFECEEF4);
  static const _textSub  = Color(0xFF8892A8);
  static const _textDim  = Color(0xFF555E75);
  static const _errorRed = Color(0xFFFF6B6B);

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  // ── actions ──────────────────────────────────────────────────────────
  Future<void> _signIn() async {
    if (_emailCtrl.text.trim().isEmpty || _passwordCtrl.text.isEmpty) {
      _showError('Please enter your email and password');
      return;
    }
    setState(() => _isLoading = true);
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email:    _emailCtrl.text.trim(),
        password: _passwordCtrl.text,
      );
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on FirebaseAuthException catch (e) {
      final msg = switch (e.code) {
        'user-not-found'      => 'No account found with this email',
        'wrong-password'      => 'Incorrect password',
        'invalid-email'       => 'Invalid email address',
        'invalid-credential'  => 'Invalid email or password',
        _                     => 'Login failed. Please try again.',
      };
      if (mounted) _showError(msg);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    setState(() => _isLoading = true);
    try {
      // serverClientId (web OAuth client from google-services.json client_type:3)
      // is required on Android so that authentication.idToken is non-null.
      const webClientId =
          '923664715542-6ar2oqcp2pv0gkcbkpuj4sjrgbniper2.apps.googleusercontent.com';
      final googleSignIn = GoogleSignIn(serverClientId: webClientId);
      await googleSignIn.disconnect().catchError((_) {});
      final googleUser = await googleSignIn.signIn();
      if (googleUser == null) { setState(() => _isLoading = false); return; }
      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken:     googleAuth.idToken,
      );
      await FirebaseAuth.instance.signInWithCredential(credential);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) {
        // Surface the actual error code so misconfiguration is diagnosable.
        // Most common cause on Android: SHA-1 fingerprint not registered in
        // Firebase Console → Project Settings → Android app → Add fingerprint.
        // Run: keytool -list -v -keystore ~/.android/debug.keystore
        //      -alias androiddebugkey -storepass android -keypass android
        // Then re-download google-services.json and replace android/app/google-services.json
        final detail = e is Exception ? e.toString() : '$e';
        _showError('Google sign-in failed: $detail');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg,
        style: const TextStyle(fontFamily: 'DMSans')),
      backgroundColor: _errorRed,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(16),
    ));
  }

  // ── build ─────────────────────────────────────────────────────────────
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
              const SizedBox(height: 32),
              _buildGoogleButton(),
              const SizedBox(height: 16),
              _buildOrDivider(),
              const SizedBox(height: 16),
              _buildEmailField(),
              const SizedBox(height: 12),
              _buildPasswordField(),
              const SizedBox(height: 4),
              _buildForgotPassword(),
              const SizedBox(height: 20),
              _buildLoginButton(),
              const SizedBox(height: 20),
              _buildSignupRow(),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  // ── nav ───────────────────────────────────────────────────────────────
  Widget _buildNav() {
    final canGoBack = Navigator.canPop(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Row(
        children: [
          // Back arrow — shown when coming from ModePickerScreen
          if (canGoBack) ...[
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1E28),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _border, width: 1.5),
                ),
                child: const Icon(
                  Icons.arrow_back_rounded,
                  size: 16,
                  color: _textSub,
                ),
              ),
            ),
            const SizedBox(width: 12),
          ],
          const Icon(Icons.lock_rounded, size: 15, color: _accent),
          const SizedBox(width: 7),
          const Text('OBEX VAULT',
            style: TextStyle(
              fontFamily: 'DMSans',
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: _textSub,
              letterSpacing: .08,
            ),
          ),
        ],
      ),
    );
  }

  // ── header ────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Welcome back',
          style: TextStyle(
            fontFamily: 'DMSans',
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: _text,
            letterSpacing: -.03,
          ),
        ),
        SizedBox(height: 4),
        Text('Sign in to access your vault',
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

  // ── google button ─────────────────────────────────────────────────────
  Widget _buildGoogleButton() {
    return SizedBox(
      height: 50,
      width: double.infinity,
      child: OutlinedButton(
        onPressed: _isLoading ? null : _signInWithGoogle,
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
            const Text('Continue with Google',
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

  // ── or divider ────────────────────────────────────────────────────────
  Widget _buildOrDivider() {
    return Row(children: [
      const Expanded(child: Divider(color: _border, thickness: 1)),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: Text('OR',
          style: TextStyle(
            fontFamily: 'DMSans',
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: _textDim,
            letterSpacing: .1,
          ),
        ),
      ),
      const Expanded(child: Divider(color: _border, thickness: 1)),
    ]);
  }

  // ── email field ───────────────────────────────────────────────────────
  Widget _buildEmailField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('EMAIL ADDRESS',
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
          controller: _emailCtrl,
          keyboardType: TextInputType.emailAddress,
          style: const TextStyle(
            fontFamily: 'DMSans', fontSize: 14, color: _text),
          decoration: InputDecoration(
            hintText: 'name@domain.com',
            hintStyle: const TextStyle(
              fontFamily: 'DMSans', fontSize: 14, color: _textDim),
            filled: true,
            fillColor: _surface,
            prefixIcon: const Icon(
              Icons.email_outlined, size: 16, color: _textDim),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: _border, width: 1.5),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: _border, width: 1.5),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: _accent, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }

  // ── password field ────────────────────────────────────────────────────
  Widget _buildPasswordField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('PASSWORD',
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
          controller: _passwordCtrl,
          obscureText: _obscure,
          onSubmitted: (_) => _signIn(),
          style: const TextStyle(
            fontFamily: 'DMSans', fontSize: 14, color: _text),
          decoration: InputDecoration(
            hintText: '••••••••••••',
            hintStyle: const TextStyle(
              fontFamily: 'DMSans', fontSize: 14, color: _textDim),
            filled: true,
            fillColor: _surface,
            prefixIcon: const Icon(
              Icons.lock_outline_rounded, size: 16, color: _textDim),
            suffixIcon: IconButton(
              icon: Icon(
                _obscure
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 16,
                color: _textDim,
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: _border, width: 1.5),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: _border, width: 1.5),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: _accent, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }

  // ── forgot password ───────────────────────────────────────────────────
  Widget _buildForgotPassword() {
    return Align(
      alignment: Alignment.centerRight,
      child: TextButton(
        onPressed: () {},
        style: TextButton.styleFrom(
          foregroundColor: _textSub,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: const Text('Forgot password?',
          style: TextStyle(
            fontFamily: 'DMSans',
            fontSize: 12,
            color: _textSub,
          ),
        ),
      ),
    );
  }

  // ── login button ──────────────────────────────────────────────────────
  Widget _buildLoginButton() {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _signIn,
        style: ElevatedButton.styleFrom(
          backgroundColor: _accent,
          foregroundColor: Colors.white,
          disabledBackgroundColor: _accent.withOpacity(0.5),
          elevation: 0,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ),
        child: _isLoading
            ? const SizedBox(
                width: 22, height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5, color: Colors.white),
              )
            : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.login_rounded, size: 18),
                  SizedBox(width: 8),
                  Text('Sign In',
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

  // ── signup row ────────────────────────────────────────────────────────
  Widget _buildSignupRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text("Don't have an account?",
          style: TextStyle(
            fontFamily: 'DMSans',
            fontSize: 13,
            color: _textSub,
          ),
        ),
        TextButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SignupScreen()),
          ),
          style: TextButton.styleFrom(
            foregroundColor: _accent,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Sign Up',
            style: TextStyle(
              fontFamily: 'DMSans',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: _accent,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Google G logo painter ──────────────────────────────────────────────────
class _GoogleLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect  = Rect.fromLTWH(0, 0, size.width, size.height);
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
