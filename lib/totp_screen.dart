import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:otp/otp.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'encryption_helper.dart';
import 'vault_constants.dart';

class TotpScreen extends StatefulWidget {
  final bool isDarkMode;
  final bool isOfflineMode;
  final Uint8List? offlineKey;

  const TotpScreen({
    super.key,
    required this.isDarkMode,
    this.isOfflineMode = false,
    this.offlineKey,
  });

  @override
  State<TotpScreen> createState() => _TotpScreenState();
}

class _TotpScreenState extends State<TotpScreen> {
  late bool _isDarkMode;

  // Offline-mode local entries + stream
  final _storage = const FlutterSecureStorage();
  final _offlineController = StreamController<List<Map<String, dynamic>>>.broadcast();

  Color get bgColor       => _isDarkMode ? const Color(0xFF10131A) : const Color(0xFFF0F2F5);
  Color get cardColor     => _isDarkMode ? const Color(0xFF1E2130) : Colors.white;
  Color get textPrimary   => _isDarkMode ? Colors.white : const Color(0xFF1A237E);
  Color get textSecondary => _isDarkMode ? const Color(0xFFC6C6CC) : Colors.grey;
  Color get accentColor   => const Color(0xFF3D5AFE);

  @override
  void initState() {
    super.initState();
    _isDarkMode = widget.isDarkMode;
    if (widget.isOfflineMode) _emitOfflineEntries();
  }

  @override
  void dispose() {
    _offlineController.close();
    super.dispose();
  }

  // ─── Offline TOTP storage ─────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> _readOfflineEntries() async {
    final raw = await _storage.read(key: VaultKeys.offlineTotpEntries);
    if (raw == null) return [];
    try {
      return List<Map<String, dynamic>>.from(jsonDecode(raw));
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeOfflineEntries(List<Map<String, dynamic>> entries) async {
    await _storage.write(
      key: VaultKeys.offlineTotpEntries,
      value: jsonEncode(entries),
    );
  }

  Future<void> _emitOfflineEntries() async {
    if (_offlineController.isClosed) return;
    final entries = await _readOfflineEntries();
    _offlineController.add(entries);
  }

  Future<void> _addOfflineEntry({
    required String name,
    required String account,
    required String secret,
  }) async {
    final entries = await _readOfflineEntries();
    entries.add({
      'id':        DateTime.now().microsecondsSinceEpoch.toString(),
      'name':      name,
      'account':   account,
      // Encrypt the secret at rest with the offline key
      'secret':    EncryptionHelper.encrypt(secret, keyOverride: widget.offlineKey),
      'createdAt': DateTime.now().toIso8601String(),
    });
    await _writeOfflineEntries(entries);
    await _emitOfflineEntries();
  }

  Future<void> _deleteOfflineEntry(String id) async {
    final entries = await _readOfflineEntries();
    entries.removeWhere((e) => e['id'] == id);
    await _writeOfflineEntries(entries);
    await _emitOfflineEntries();
  }

  /// Decrypts offline secret before passing it to the OTP generator.
  String _resolveSecret(String storedSecret) {
    if (!widget.isOfflineMode) return storedSecret;
    return EncryptionHelper.decrypt(storedSecret, keyOverride: widget.offlineKey);
  }

  // ─── Cloud Firestore helpers ──────────────────────────────────────────────

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  Stream<QuerySnapshot>? get _cloudStream {
    final uid = _uid;
    if (uid == null) return null;
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('totp')
        .orderBy('createdAt', descending: false)
        .snapshots();
  }

  Future<void> _addCloudEntry({
    required String name,
    required String account,
    required String secret,
  }) async {
    final uid = _uid;
    if (uid == null) return;
    await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('totp')
        .add({
      'name':      name,
      'account':   account,
      'secret':    EncryptionHelper.encrypt(secret),
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _deleteCloudEntry(String docId) async {
    final uid = _uid;
    if (uid == null) return;
    await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('totp')
        .doc(docId)
        .delete();
  }

  // ─── OTP helpers ─────────────────────────────────────────────────────────

  String _generateCode(String secret) {
    try {
      return OTP.generateTOTPCodeString(
        secret.toUpperCase(),
        DateTime.now().millisecondsSinceEpoch,
        interval: 30,
        algorithm: Algorithm.SHA1,
        isGoogle: true,
      );
    } catch (e) {
      return '------';
    }
  }

  String _formatCode(String code) {
    if (code.length == 6) return '${code.substring(0, 3)} ${code.substring(3)}';
    return code;
  }

  // ─── Add TOTP dialog ──────────────────────────────────────────────────────

  void _showAddTotpDialog() {
    final secretCtrl  = TextEditingController();
    final nameCtrl    = TextEditingController();
    final accountCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text('Add 2FA Account',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: textPrimary)),
              const SizedBox(height: 4),
              Text('Scan a QR code or enter the secret key manually',
                  style: TextStyle(fontSize: 13, color: textSecondary)),
              const SizedBox(height: 20),

              SizedBox(
                width: double.infinity, height: 50,
                child: OutlinedButton.icon(
                  onPressed: () => _scanQrCode(ctx),
                  icon: Icon(Icons.qr_code_scanner_rounded, color: accentColor),
                  label: Text('Scan QR Code',
                      style: TextStyle(color: accentColor, fontWeight: FontWeight.bold, fontSize: 16)),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: accentColor),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              Row(children: [
                Expanded(child: Divider(color: textSecondary.withOpacity(0.3))),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('or enter manually', style: TextStyle(color: textSecondary, fontSize: 12)),
                ),
                Expanded(child: Divider(color: textSecondary.withOpacity(0.3))),
              ]),
              const SizedBox(height: 16),

              _buildDialogField(nameCtrl,    'Service Name (e.g. Google)',  Icons.label_outline),
              const SizedBox(height: 12),
              _buildDialogField(accountCtrl, 'Account (e.g. user@gmail.com)', Icons.person_outline),
              const SizedBox(height: 12),
              _buildDialogField(secretCtrl,  'Secret Key',                  Icons.key_rounded),
              const SizedBox(height: 20),

              SizedBox(
                width: double.infinity, height: 50,
                child: ElevatedButton(
                  onPressed: () async {
                    if (nameCtrl.text.trim().isEmpty || secretCtrl.text.trim().isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Service name and secret are required'),
                        backgroundColor: Colors.red,
                        behavior: SnackBarBehavior.floating,
                      ));
                      return;
                    }
                    Navigator.pop(ctx);
                    await _saveEntry(
                      name:    nameCtrl.text.trim(),
                      account: accountCtrl.text.trim(),
                      secret:  secretCtrl.text.trim(),
                    );
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('2FA account added!'),
                        backgroundColor: Colors.green,
                        behavior: SnackBarBehavior.floating,
                      ));
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accentColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Add Account',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDialogField(TextEditingController ctrl, String label, IconData icon) {
    return TextField(
      controller: ctrl,
      style: TextStyle(color: textPrimary),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: textSecondary),
        prefixIcon: Icon(icon, color: accentColor),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: textSecondary.withOpacity(0.3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: accentColor, width: 2),
        ),
        filled: true,
        fillColor: _isDarkMode ? const Color(0xFF272A32) : Colors.grey.shade50,
      ),
    );
  }

  // ─── QR scanner ──────────────────────────────────────────────────────────

  void _scanQrCode(BuildContext dialogCtx) async {
    Navigator.pop(dialogCtx); // close add dialog
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => _QrScannerScreen(isDarkMode: _isDarkMode)),
    );
    if (result == null) return;

    try {
      final uri = Uri.parse(result);
      String name = '', account = '', secret = '';

      if (uri.scheme == 'otpauth') {
        secret = uri.queryParameters['secret'] ?? '';
        final issuer   = uri.queryParameters['issuer'] ?? '';
        final pathPart = uri.pathSegments.isNotEmpty
            ? Uri.decodeComponent(uri.pathSegments.first)
            : '';
        if (pathPart.contains(':')) {
          name    = issuer.isNotEmpty ? issuer : pathPart.split(':')[0];
          account = pathPart.split(':')[1];
        } else {
          name    = issuer.isNotEmpty ? issuer : pathPart;
          account = pathPart;
        }
      }

      if (secret.isEmpty) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Invalid QR code — no secret found'),
          backgroundColor: Colors.red, behavior: SnackBarBehavior.floating,
        ));
        return;
      }

      await _saveEntry(
        name:    name.isNotEmpty ? name : 'Unknown',
        account: account,
        secret:  secret,
      );
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${name.isNotEmpty ? name : "Account"} added!'),
        backgroundColor: Colors.green, behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Failed to parse QR: $e'),
        backgroundColor: Colors.red, behavior: SnackBarBehavior.floating,
      ));
    }
  }

  // ─── Unified save / delete ────────────────────────────────────────────────

  Future<void> _saveEntry({required String name, required String account, required String secret}) async {
    if (widget.isOfflineMode) {
      await _addOfflineEntry(name: name, account: account, secret: secret);
    } else {
      await _addCloudEntry(name: name, account: account, secret: secret);
    }
  }

  void _confirmDelete(String id, String name) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete 2FA'),
        content: Text('Remove "$name" from your 2FA accounts?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (widget.isOfflineMode) {
                await _deleteOfflineEntry(id);
              } else {
                await _deleteCloudEntry(id);
              }
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  // ─── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('SECURITY PROTOCOL',
                      style: TextStyle(fontSize: 11, color: accentColor, letterSpacing: 1.5, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text('Active Tokens',
                      style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: textPrimary)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _GlobalTimerWidget(isDarkMode: _isDarkMode),
            ),
            const SizedBox(height: 16),
            Expanded(child: widget.isOfflineMode ? _buildOfflineList() : _buildCloudList()),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddTotpDialog,
        backgroundColor: accentColor,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Widget _buildCloudList() {
    return StreamBuilder<QuerySnapshot>(
      stream: _cloudStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(child: CircularProgressIndicator(color: accentColor));
        }
        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) return _buildEmpty();

        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          itemCount: docs.length,
          itemBuilder: (context, index) {
            final doc  = docs[index];
            final data = doc.data() as Map<String, dynamic>;
            return _TotpCard(
              key:          ValueKey(doc.id),
              name:         data['name']    ?? 'Unknown',
              account:      data['account'] ?? '',
              secret:       EncryptionHelper.decrypt(data['secret'] ?? ''),
              isDarkMode:   _isDarkMode,
              onDelete:     () => _confirmDelete(doc.id, data['name'] ?? 'Unknown'),
              generateCode: _generateCode,
              formatCode:   _formatCode,
            );
          },
        );
      },
    );
  }

  Widget _buildOfflineList() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _offlineController.stream,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return Center(child: CircularProgressIndicator(color: accentColor));
        final entries = snapshot.data!;
        if (entries.isEmpty) return _buildEmpty();

        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final e = entries[index];
            return _TotpCard(
              key:          ValueKey(e['id']),
              name:         e['name']    ?? 'Unknown',
              account:      e['account'] ?? '',
              secret:       _resolveSecret(e['secret'] ?? ''), // decrypted at display time
              isDarkMode:   _isDarkMode,
              onDelete:     () => _confirmDelete(e['id'] ?? '', e['name'] ?? 'Unknown'),
              generateCode: _generateCode,
              formatCode:   _formatCode,
            );
          },
        );
      },
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.security_rounded, size: 64, color: textSecondary.withOpacity(0.4)),
          const SizedBox(height: 16),
          Text('No 2FA accounts yet', style: TextStyle(color: textSecondary, fontSize: 16)),
          const SizedBox(height: 8),
          Text('Tap + to add your first account', style: TextStyle(color: textSecondary, fontSize: 13)),
        ],
      ),
    );
  }
}

// ── Global timer widget ───────────────────────────────────────────────────────

class _GlobalTimerWidget extends StatefulWidget {
  final bool isDarkMode;
  const _GlobalTimerWidget({required this.isDarkMode});

  @override
  State<_GlobalTimerWidget> createState() => _GlobalTimerWidgetState();
}

class _GlobalTimerWidgetState extends State<_GlobalTimerWidget> {
  late Timer _timer;
  int _secondsRemaining = 30;

  Color get cardColor     => widget.isDarkMode ? const Color(0xFF1E2130) : Colors.white;
  Color get textPrimary   => widget.isDarkMode ? Colors.white : const Color(0xFF1A237E);
  Color get textSecondary => widget.isDarkMode ? const Color(0xFFC6C6CC) : Colors.grey;
  Color get accentColor   => const Color(0xFF3D5AFE);

  @override
  void initState() {
    super.initState();
    _secondsRemaining = 30 - (DateTime.now().second % 30);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _secondsRemaining = 30 - (DateTime.now().second % 30));
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(widget.isDarkMode ? 0.3 : 0.06),
            blurRadius: 8, offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          SizedBox(
            width: 40, height: 40,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CircularProgressIndicator(
                  value: _secondsRemaining / 30,
                  backgroundColor: Colors.grey.withOpacity(0.2),
                  color: _secondsRemaining <= 5 ? Colors.red : accentColor,
                  strokeWidth: 3,
                ),
                Center(
                  child: Text('$_secondsRemaining',
                      style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.bold,
                        color: _secondsRemaining <= 5 ? Colors.red : accentColor,
                      )),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('GLOBAL REFRESH',
                  style: TextStyle(fontSize: 11, color: textSecondary, letterSpacing: 1.2)),
              Text('All codes synchronizing',
                  style: TextStyle(fontSize: 14, color: textPrimary, fontWeight: FontWeight.w500)),
            ],
          ),
        ],
      ),
    );
  }
}

// ── TOTP card widget ──────────────────────────────────────────────────────────

class _TotpCard extends StatefulWidget {
  final String name;
  final String account;
  final String secret;
  final bool isDarkMode;
  final VoidCallback onDelete;
  final String Function(String) generateCode;
  final String Function(String) formatCode;

  const _TotpCard({
    super.key,
    required this.name,
    required this.account,
    required this.secret,
    required this.isDarkMode,
    required this.onDelete,
    required this.generateCode,
    required this.formatCode,
  });

  @override
  State<_TotpCard> createState() => _TotpCardState();
}

class _TotpCardState extends State<_TotpCard> {
  late Timer _timer;
  int _secondsRemaining = 30;
  late String _code;

  Color get cardColor     => widget.isDarkMode ? const Color(0xFF1E2130) : Colors.white;
  Color get textPrimary   => widget.isDarkMode ? Colors.white : const Color(0xFF1A237E);
  Color get textSecondary => widget.isDarkMode ? const Color(0xFFC6C6CC) : Colors.grey;
  Color get accentColor   => const Color(0xFF3D5AFE);

  @override
  void initState() {
    super.initState();
    _secondsRemaining = 30 - (DateTime.now().second % 30);
    _code  = widget.generateCode(widget.secret);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {
        _secondsRemaining = 30 - (DateTime.now().second % 30);
        _code = widget.generateCode(widget.secret);
      });
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(
                      color: accentColor.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Center(
                      child: Text(
                        widget.name.isNotEmpty ? widget.name[0].toUpperCase() : '?',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: accentColor),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.name,
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: textPrimary)),
                      if (widget.account.isNotEmpty)
                        Text(widget.account,
                            style: TextStyle(fontSize: 12, color: textSecondary)),
                    ],
                  ),
                ],
              ),
              IconButton(
                icon: Icon(Icons.more_vert_rounded, color: textSecondary),
                onPressed: widget.onDelete,
              ),
            ],
          ),
          const SizedBox(height: 16),

          Text(
            widget.formatCode(_code),
            style: TextStyle(
              fontSize: 42, fontWeight: FontWeight.w800,
              color: accentColor, letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 12),

          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _secondsRemaining / 30,
              backgroundColor: Colors.grey.withOpacity(0.15),
              color: _secondsRemaining <= 5 ? Colors.red : accentColor,
              minHeight: 3,
            ),
          ),
          const SizedBox(height: 4),
          Text('EXPIRES IN ${_secondsRemaining}S',
              style: TextStyle(fontSize: 10, color: textSecondary, letterSpacing: 1)),
          const SizedBox(height: 12),

          SizedBox(
            width: double.infinity, height: 44,
            child: ElevatedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _code));
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('${widget.name} code copied!'),
                  behavior: SnackBarBehavior.floating,
                  backgroundColor: Colors.green,
                ));
              },
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: const Text('Copy Code'),
              style: ElevatedButton.styleFrom(
                backgroundColor: accentColor.withOpacity(0.15),
                foregroundColor: accentColor,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── QR Scanner Screen ─────────────────────────────────────────────────────────

class _QrScannerScreen extends StatefulWidget {
  final bool isDarkMode;
  const _QrScannerScreen({required this.isDarkMode});

  @override
  State<_QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<_QrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _scanned = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Scan QR Code', style: TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on, color: Colors.white),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              if (_scanned) return;
              final value = capture.barcodes.firstOrNull?.rawValue;
              if (value != null) {
                _scanned = true;
                Navigator.pop(context, value);
              }
            },
          ),
          Center(
            child: Container(
              width: 250, height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF3D5AFE), width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          Positioned(
            bottom: 60, left: 0, right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text('Point camera at the QR code',
                    style: TextStyle(color: Colors.white, fontSize: 14)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
