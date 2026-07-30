import 'package:flutter/material.dart';
import 'lockdown_manager.dart';

class LockdownExitScreen extends StatefulWidget {
  final bool isDarkMode;
  const LockdownExitScreen({super.key, required this.isDarkMode});

  @override
  State<LockdownExitScreen> createState() => _LockdownExitScreenState();
}

class _LockdownExitScreenState extends State<LockdownExitScreen> {
  String _pin = '';
  bool _hasError = false;
  final _lockdown = LockdownManager();

  Color get bgColor =>
      widget.isDarkMode ? const Color(0xFF10131A) : const Color(0xFFF0F2F5);
  Color get cardColor =>
      widget.isDarkMode ? const Color(0xFF1E2130) : Colors.white;
  Color get textPrimary =>
      widget.isDarkMode ? Colors.white : const Color(0xFF1A237E);
  Color get textSecondary =>
      widget.isDarkMode ? const Color(0xFFC6C6CC) : Colors.grey;
  Color get accentColor => const Color(0xFF3D5AFE);

  void _onKeyTap(String value) {
    if (_pin.length < 4) {
      setState(() {
        _pin += value;
        _hasError = false;
      });
      if (_pin.length == 4) {
        _verifyPin();
      }
    }
  }

  void _onDelete() {
    if (_pin.isNotEmpty) {
      setState(() => _pin = _pin.substring(0, _pin.length - 1));
    }
  }

  Future<void> _verifyPin() async {
    try {
      await _lockdown.disableLockdown(_pin);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        _hasError = true;
        _pin = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Column(
          children: [
            // Red lockdown banner
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              color: Colors.red.shade700,
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_rounded, color: Colors.white, size: 16),
                  SizedBox(width: 8),
                  Text(
                    'LOCKDOWN MODE ACTIVE',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.shield_rounded,
                      size: 64,
                      color: _hasError ? Colors.red : accentColor),
                  const SizedBox(height: 16),
                  Text(
                    'Enter PIN to exit lockdown',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _hasError
                        ? 'Incorrect PIN. Try again.'
                        : 'Network access is blocked',
                    style: TextStyle(
                      fontSize: 14,
                      color: _hasError ? Colors.red : textSecondary,
                    ),
                  ),
                  const SizedBox(height: 40),

                  // PIN dots
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(4, (i) {
                      final filled = i < _pin.length;
                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 10),
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _hasError
                              ? Colors.red
                              : filled
                              ? accentColor
                              : Colors.grey.withOpacity(0.3),
                          border: Border.all(
                            color: _hasError
                                ? Colors.red
                                : filled
                                ? accentColor
                                : Colors.grey.withOpacity(0.5),
                            width: 2,
                          ),
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 48),

                  // Number pad
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Column(
                      children: [
                        _buildKeyRow(['1', '2', '3']),
                        const SizedBox(height: 16),
                        _buildKeyRow(['4', '5', '6']),
                        const SizedBox(height: 16),
                        _buildKeyRow(['7', '8', '9']),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            const SizedBox(width: 72),
                            _buildKey('0'),
                            SizedBox(
                              width: 72,
                              height: 72,
                              child: TextButton(
                                onPressed: _onDelete,
                                child: Icon(Icons.backspace_rounded,
                                    color: textPrimary, size: 24),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeyRow(List<String> keys) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: keys.map((k) => _buildKey(k)).toList(),
    );
  }

  Widget _buildKey(String value) {
    return SizedBox(
      width: 72,
      height: 72,
      child: ElevatedButton(
        onPressed: () => _onKeyTap(value),
        style: ElevatedButton.styleFrom(
          backgroundColor: cardColor,
          foregroundColor: textPrimary,
          elevation: 2,
          shape: const CircleBorder(),
        ),
        child: Text(
          value,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w500,
            color: textPrimary,
          ),
        ),
      ),
    );
  }
}