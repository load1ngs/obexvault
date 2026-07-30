import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PasswordGeneratorScreen extends StatefulWidget {
  final bool isDarkMode;

  const PasswordGeneratorScreen({super.key, this.isDarkMode = false});

  @override
  State<PasswordGeneratorScreen> createState() =>
      _PasswordGeneratorScreenState();
}

class _PasswordGeneratorScreenState extends State<PasswordGeneratorScreen> {
  // ─── Settings ────────────────────────────────────────────────────────────
  int    _length         = 16;
  bool   _useUppercase   = true;
  bool   _useLowercase   = true;
  bool   _useNumbers     = true;
  bool   _useSymbols     = true;

  String _generated      = '';
  bool   _copied         = false;

  // ─── Theme helpers ────────────────────────────────────────────────────────
  Color get _bg          => widget.isDarkMode ? const Color(0xFF10131A) : const Color(0xFFF0F2F5);
  Color get _card        => widget.isDarkMode ? const Color(0xFF1E2130) : Colors.white;
  Color get _textPrimary => widget.isDarkMode ? Colors.white            : const Color(0xFF1A237E);
  Color get _textHint    => widget.isDarkMode ? const Color(0xFF8892A8) : Colors.grey;
  Color get _accent      => const Color(0xFF3D5AFE);
  Color get _border      => widget.isDarkMode ? const Color(0xFF252A38) : const Color(0xFFDDE1F0);

  // ─── Strength ─────────────────────────────────────────────────────────────
  int get _strengthScore {
    if (_generated.isEmpty) return 0;
    int score = 0;
    if (_generated.length >= 12) score++;
    if (_generated.length >= 16) score++;
    if (_generated.contains(RegExp(r'[A-Z]'))) score++;
    if (_generated.contains(RegExp(r'[a-z]'))) score++;
    if (_generated.contains(RegExp(r'[0-9]'))) score++;
    if (_generated.contains(RegExp(r'[^A-Za-z0-9]'))) score++;
    return score;
  }

  String get _strengthLabel {
    final s = _strengthScore;
    if (s <= 2) return 'Weak';
    if (s <= 3) return 'Fair';
    if (s <= 4) return 'Good';
    if (s <= 5) return 'Strong';
    return 'Excellent';
  }

  Color get _strengthColor {
    switch (_strengthLabel) {
      case 'Weak':      return Colors.red;
      case 'Fair':      return Colors.orange;
      case 'Good':      return Colors.yellow.shade700;
      case 'Strong':    return Colors.lightGreen;
      default:          return Colors.green;
    }
  }

  // ─── Generator ────────────────────────────────────────────────────────────
  void _generate() {
    const upper   = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    const lower   = 'abcdefghijklmnopqrstuvwxyz';
    const numbers = '0123456789';
    const symbols = '!@#\$%^&*()_+-=[]{}|;:,.<>?';

    String pool = '';
    if (_useUppercase) pool += upper;
    if (_useLowercase) pool += lower;
    if (_useNumbers)   pool += numbers;
    if (_useSymbols)   pool += symbols;

    if (pool.isEmpty) {
      setState(() => _generated = '');
      return;
    }

    final rng = Random.secure();
    final buf = StringBuffer();
    for (int i = 0; i < _length; i++) {
      buf.write(pool[rng.nextInt(pool.length)]);
    }
    setState(() {
      _generated = buf.toString();
      _copied    = false;
    });
  }

  void _copyToClipboard() {
    if (_generated.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _generated));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void initState() {
    super.initState();
    _generate(); // generate one on open
  }

  // ─── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: _textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Password Generator',
          style: TextStyle(color: _textPrimary, fontWeight: FontWeight.bold),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildOutputCard(),
            const SizedBox(height: 20),
            _buildStrengthBar(),
            const SizedBox(height: 20),
            _buildOptionsCard(),
            const SizedBox(height: 24),
            SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                onPressed: _generate,
                icon: const Icon(Icons.refresh_rounded, color: Colors.white),
                label: const Text(
                  'Generate New Password',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOutputCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(widget.isDarkMode ? 0.3 : 0.06),
            blurRadius: 12, offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Generated Password',
              style: TextStyle(fontSize: 12, color: _textHint, letterSpacing: 1)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  _generated.isEmpty ? '—' : _generated,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: _textPrimary,
                    letterSpacing: 2,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _copyToClipboard,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: _copied ? Colors.green.withOpacity(0.15) : _accent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _copied ? Colors.green.withOpacity(0.4) : _accent.withOpacity(0.3),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _copied ? Icons.check_rounded : Icons.copy_rounded,
                        size: 16,
                        color: _copied ? Colors.green : _accent,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _copied ? 'Copied!' : 'Copy',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _copied ? Colors.green : _accent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStrengthBar() {
    final score    = _strengthScore;
    final maxScore = 6;
    final ratio    = score / maxScore;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Password Strength',
                  style: TextStyle(fontSize: 13, color: _textHint)),
              Text(
                _strengthLabel,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: _strengthColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 8,
              backgroundColor: _border,
              valueColor: AlwaysStoppedAnimation<Color>(_strengthColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOptionsCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(widget.isDarkMode ? 0.3 : 0.06),
            blurRadius: 12, offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Options',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: _textPrimary)),
          const SizedBox(height: 20),

          // Length slider
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Length', style: TextStyle(color: _textPrimary, fontSize: 14)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: _accent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$_length',
                  style: TextStyle(
                      color: _accent, fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),
            ],
          ),
          Slider(
            value: _length.toDouble(),
            min: 8, max: 32, divisions: 24,
            activeColor: _accent,
            inactiveColor: _border,
            onChanged: (v) => setState(() {
              _length = v.round();
              _generate();
            }),
          ),
          const SizedBox(height: 8),
          Divider(color: _border),
          const SizedBox(height: 8),

          // Toggles
          _buildToggle('Uppercase letters (A–Z)', _useUppercase,
                  (v) => setState(() { _useUppercase = v; _generate(); })),
          _buildToggle('Lowercase letters (a–z)', _useLowercase,
                  (v) => setState(() { _useLowercase = v; _generate(); })),
          _buildToggle('Numbers (0–9)', _useNumbers,
                  (v) => setState(() { _useNumbers = v; _generate(); })),
          _buildToggle('Symbols (!@#\$...)', _useSymbols,
                  (v) => setState(() { _useSymbols = v; _generate(); })),
        ],
      ),
    );
  }

  Widget _buildToggle(String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: _textPrimary, fontSize: 14)),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: _accent,
          ),
        ],
      ),
    );
  }
}