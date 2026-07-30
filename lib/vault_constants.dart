/// Single source of truth for all FlutterSecureStorage keys used across the app.
class VaultKeys {
  VaultKeys._();

  // ── Encryption ────────────────────────────────────────────────────────────
  static const String cloudEncKey           = 'cloud_enc_key';
  static const String fileEncKey            = 'file_enc_key';

  // ── Theme ─────────────────────────────────────────────────────────────────
  static const String themeDark             = 'theme_dark';

  // ── Mode ──────────────────────────────────────────────────────────────────
  static const String vaultMode             = 'vault_mode';
  static const String modePickerDone        = 'mode_picker_done';

  // ── Offline auth ──────────────────────────────────────────────────────────
  static const String offlineSalt           = 'offline_argon2_salt';
  static const String offlineVerifier       = 'offline_key_verifier';
  static const String offlineDisplayName    = 'offline_display_name';

  // ── App lock ──────────────────────────────────────────────────────────────
  static const String appLockPin                = 'app_lock_pin';
  static const String appLockFingerprintEnabled = 'app_lock_fingerprint_enabled';
  static const String appLockSetupDone          = 'app_lock_setup_done';
  static const String appLockAutoLockSeconds    = 'app_lock_auto_lock_seconds';

  // ── Lockdown ──────────────────────────────────────────────────────────────
  static const String lockdownActive        = 'lockdown_active';
  static const String lockdownPin           = 'lockdown_pin';
  static const String pendingPasswords      = 'pending_passwords';

  // ── Clipboard ─────────────────────────────────────────────────────────────
  static const String clipboardAutoClear    = 'clipboard_auto_clear';
  static const String clipboardClearSeconds = 'clipboard_clear_seconds';

  // ── Offline TOTP ──────────────────────────────────────────────────────────
  static const String offlineTotpEntries    = 'offline_totp_entries';
}

/// Fixed + custom category labels used across passwords and notes.
class VaultCategories {
  VaultCategories._();

  static const List<String> fixed = [
    'Personal',
    'Work',
    'Banking',
    'Social',
    'Other',
  ];
}