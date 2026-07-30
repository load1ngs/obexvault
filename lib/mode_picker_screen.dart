import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'login_screen.dart';
import 'signup_screen.dart';
import 'vault_constants.dart';

/// Shown ONLY on a fresh install — when no vault mode has been set yet.
///
/// Cloud path  → LoginScreen (user can go back to change mode)
/// Offline path → SignupScreen with initialMode: 'offline' (user can go back)
///
/// Uses push (not pushReplacement) so the back button always returns here.
/// Once setup completes, AuthWrapper handles routing and this screen is skipped.

class ModePickerScreen extends StatefulWidget {
  final VoidCallback? onOfflineSetupComplete;

  const ModePickerScreen({super.key, this.onOfflineSetupComplete});

  @override
  State<ModePickerScreen> createState() => _ModePickerScreenState();
}

class _ModePickerScreenState extends State<ModePickerScreen>
    with SingleTickerProviderStateMixin {
  _PickedMode? _selected;

  late AnimationController _ctrl;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  // ── design tokens ─────────────────────────────────────────────────────
  static const _bg      = Color(0xFF0D0F14);
  static const _surface = Color(0xFF141720);
  static const _border  = Color(0xFF252A38);
  static const _accent  = Color(0xFF3B6BFF);
  static const _teal    = Color(0xFF00C896);
  static const _text    = Color(0xFFECEEF4);
  static const _textSub = Color(0xFF8892A8);
  static const _textDim = Color(0xFF555E75);

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500));
    _fadeAnim  = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _proceed() async {
    if (_selected == null) return;
    const storage = FlutterSecureStorage();
    await storage.write(key: VaultKeys.modePickerDone, value: 'true');

    if (!mounted) return;
    if (_selected == _PickedMode.cloud) {
      // push — back arrow on LoginScreen returns here so user can switch mode
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    } else {
      // push — back arrow on SignupScreen returns here so user can switch mode
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SignupScreen(
            initialMode: 'offline',
            isDarkMode: true,
            onOfflineSetupComplete: widget.onOfflineSetupComplete,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: SlideTransition(
            position: _slideAnim,
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 36),
                  _buildHeader(),
                  const SizedBox(height: 28),
                  _buildSectionLabel('CHOOSE STORAGE MODE'),
                  const SizedBox(height: 12),
                  _buildCard(
                    mode: _PickedMode.cloud,
                    icon: Icons.cloud_outlined,
                    title: 'Cloud Mode',
                    description:
                        'Your vault syncs across all your devices via Firebase. '
                        'Requires an email account.',
                    activeColor: _accent,
                    bullets: const [
                      'Access from any device',
                      'Automatic encrypted backups',
                      'Email + Google sign-in',
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildCard(
                    mode: _PickedMode.offline,
                    icon: Icons.wifi_off_rounded,
                    title: 'Offline Mode',
                    description:
                        'Your vault is stored only on this device. '
                        'No internet connection required.',
                    activeColor: _teal,
                    bullets: const [
                      'No account needed',
                      'Works without internet',
                      'Protected by Argon2id master password',
                    ],
                  ),
                  const SizedBox(height: 24),
                  _buildCta(),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── header ────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Icon(Icons.lock_rounded, size: 16, color: _accent),
          const SizedBox(width: 8),
          const Text('OBEX VAULT',
            style: TextStyle(
              fontFamily: 'DMSans',
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: _textSub,
              letterSpacing: .08,
            ),
          ),
        ]),
        const SizedBox(height: 18),
        const Text('How do you want\nto store your vault?',
          style: TextStyle(
            fontFamily: 'DMSans',
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: _text,
            letterSpacing: -.03,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'You can only choose this once. Pick the mode\nthat fits how you use your devices.',
          style: TextStyle(
            fontFamily: 'DMSans',
            fontSize: 13,
            color: _textSub,
            height: 1.6,
          ),
        ),
      ],
    );
  }

  // ── section label ─────────────────────────────────────────────────────
  Widget _buildSectionLabel(String label) {
    return Text(label,
      style: const TextStyle(
        fontFamily: 'DMSans',
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: _textDim,
        letterSpacing: .12,
      ),
    );
  }

  // ── mode card ─────────────────────────────────────────────────────────
  Widget _buildCard({
    required _PickedMode mode,
    required IconData icon,
    required String title,
    required String description,
    required Color activeColor,
    required List<String> bullets,
  }) {
    final isActive = _selected == mode;

    return GestureDetector(
      onTap: () => setState(() => _selected = mode),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: isActive ? activeColor.withOpacity(0.06) : _surface,
          border: Border.all(
            color: isActive ? activeColor : _border,
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: isActive
                        ? activeColor.withOpacity(0.15)
                        : const Color(0xFF1A1E28),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon,
                    size: 18,
                    color: isActive ? activeColor : _textDim,
                  ),
                ),
                const Spacer(),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isActive ? activeColor : Colors.transparent,
                    border: Border.all(
                      color: isActive ? activeColor : _border,
                      width: 1.5,
                    ),
                    boxShadow: isActive
                        ? [BoxShadow(
                            color: activeColor.withOpacity(0.35),
                            blurRadius: 8,
                            spreadRadius: 1,
                          )]
                        : [],
                  ),
                  child: isActive
                      ? const Icon(Icons.check_rounded,
                          size: 12, color: Colors.white)
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(title,
              style: TextStyle(
                fontFamily: 'DMSans',
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: isActive ? activeColor : _text,
              ),
            ),
            const SizedBox(height: 4),
            Text(description,
              style: const TextStyle(
                fontFamily: 'DMSans',
                fontSize: 12,
                color: _textSub,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 12),
            ...bullets.map((b) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 5, height: 5,
                    margin: const EdgeInsets.only(top: 5, right: 10),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isActive ? activeColor : _textDim,
                    ),
                  ),
                  Expanded(
                    child: Text(b,
                      style: TextStyle(
                        fontFamily: 'DMSans',
                        fontSize: 12,
                        color: isActive ? _textSub : _textDim,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            )),
          ],
        ),
      ),
    );
  }

  // ── CTA button ────────────────────────────────────────────────────────
  Widget _buildCta() {
    final isCloud   = _selected == _PickedMode.cloud;
    final isOffline = _selected == _PickedMode.offline;
    final active    = _selected != null;

    final Color btnColor = isOffline ? _teal : _accent;
    final Color txtColor = isOffline
        ? const Color(0xFF051A15)
        : Colors.white;
    final String label = isCloud
        ? 'Continue to Sign In'
        : isOffline
            ? 'Set Up Offline Vault'
            : 'Select a mode to continue';

    return AnimatedOpacity(
      opacity: active ? 1.0 : 0.45,
      duration: const Duration(milliseconds: 200),
      child: SizedBox(
        width: double.infinity,
        height: 54,
        child: ElevatedButton(
          onPressed: active ? _proceed : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: btnColor,
            foregroundColor: txtColor,
            disabledBackgroundColor: btnColor.withOpacity(0.5),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isOffline
                    ? Icons.lock_rounded
                    : Icons.arrow_forward_rounded,
                size: 18,
                color: txtColor,
              ),
              const SizedBox(width: 8),
              Text(label,
                style: TextStyle(
                  fontFamily: 'DMSans',
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: txtColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _PickedMode { cloud, offline }
