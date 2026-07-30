import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'vault_constants.dart';

class LockdownManager extends ChangeNotifier {
  static final LockdownManager _instance = LockdownManager._internal();
  factory LockdownManager() => _instance;
  LockdownManager._internal();

  final _storage = const FlutterSecureStorage();
  bool _isLockdown = false;
  bool get isLockdown => _isLockdown;

  Future<void> init() async {
    final saved = await _storage.read(key: VaultKeys.lockdownActive);
    if (saved == 'true') {
      await FirebaseFirestore.instance.disableNetwork();
      _isLockdown = true;
      notifyListeners();
    }
  }

  Future<void> enableLockdown() async {
    await FirebaseFirestore.instance.disableNetwork();
    await _storage.write(key: VaultKeys.lockdownActive, value: 'true');
    _isLockdown = true;
    notifyListeners();
  }

  Future<void> disableLockdown(String pin) async {
    final savedPin = await _storage.read(key: VaultKeys.lockdownPin);
    if (savedPin != null && savedPin == pin) {
      await FirebaseFirestore.instance.enableNetwork();
      await _storage.write(key: VaultKeys.lockdownActive, value: 'false');
      _isLockdown = false;
      notifyListeners();
      await _syncPendingPasswords();
      return;
    }
    throw Exception('Incorrect PIN');
  }

  Future<void> setPin(String pin) async {
    await _storage.write(key: VaultKeys.lockdownPin, value: pin);
  }

  Future<bool> hasPin() async {
    final pin = await _storage.read(key: VaultKeys.lockdownPin);
    return pin != null && pin.isNotEmpty;
  }

  Future<void> queuePassword(Map<String, dynamic> passwordData) async {
    final existing = await _storage.read(key: VaultKeys.pendingPasswords);
    List<Map<String, dynamic>> queue = [];
    if (existing != null) {
      queue = List<Map<String, dynamic>>.from(jsonDecode(existing));
    }
    queue.add(passwordData);
    await _storage.write(key: VaultKeys.pendingPasswords, value: jsonEncode(queue));
  }

  Future<int> getPendingCount() async {
    final existing = await _storage.read(key: VaultKeys.pendingPasswords);
    if (existing == null) return 0;
    final queue = List<Map<String, dynamic>>.from(jsonDecode(existing));
    return queue.length;
  }

  Future<int> _syncPendingPasswords() async {
    final existing = await _storage.read(key: VaultKeys.pendingPasswords);
    if (existing == null) return 0;

    final queue = List<Map<String, dynamic>>.from(jsonDecode(existing));
    if (queue.isEmpty) return 0;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return 0;

    int synced = 0;
    for (final password in queue) {
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .collection('passwords')
            .add({
          ...password,
          'createdAt': FieldValue.serverTimestamp(),
        });
        synced++;
      } catch (e) {
        // Skip failed ones
      }
    }

    await _storage.delete(key: VaultKeys.pendingPasswords);
    return synced;
  }
}