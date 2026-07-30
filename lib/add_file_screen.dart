import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'secure_file_service.dart';
import 'vault_repository.dart';

class AddFileScreen extends StatefulWidget {
  final VaultRepository repo;

  const AddFileScreen({super.key, required this.repo});

  @override
  State<AddFileScreen> createState() => _AddFileScreenState();
}

class _AddFileScreenState extends State<AddFileScreen> {
  PlatformFile? _pickedFile;
  String? _pickedAssetId; // MediaStore asset ID resolved at pick time
  bool _isSaving = false;
  bool _deleteOriginal = false;

  // ── File picker ───────────────────────────────────────────────────────────

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'bmp', 'pdf'],
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;

    final picked = result.files.first;
    String? assetId;

    // Resolve the MediaStore asset ID now while we have the path
    if (picked.path != null) {
      try {
        await PhotoManager.requestPermissionExtend();
        // getAssetListRange on "Recent" album is fast — just grab top 500
        final albums = await PhotoManager.getAssetPathList(
          type: RequestType.common,
          filterOption: FilterOptionGroup(
            orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
          ),
        );
        if (albums.isNotEmpty) {
          final recent = albums.first;
          final count = await recent.assetCountAsync;
          final assets = await recent.getAssetListRange(
            start: 0,
            end: count.clamp(0, 500),
          );
          for (final asset in assets) {
            final f = await asset.file;
            if (f?.path == picked.path) {
              assetId = asset.id;
              break;
            }
          }
        }
      } catch (_) {}
    }

    setState(() {
      _pickedFile = picked;
      _pickedAssetId = assetId;
    });
  }

  // ── Save ──────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    final file = _pickedFile;
    if (file == null || file.path == null) return;

    setState(() => _isSaving = true);

    try {
      final fileId = DateTime.now().microsecondsSinceEpoch.toString();
      final sourceFile = File(file.path!);
      final fileType = SecureFileService.fileTypeFromExtension(file.name);
      final fileSize = await sourceFile.length();

      // Encrypt and save to private app directory
      final encryptedPath = await SecureFileService.encryptAndSave(
        sourceFile: sourceFile,
        fileId: fileId,
      );

      // Delete original via MediaStore if user opted in
      if (_deleteOriginal) {
        try {
          if (_pickedAssetId != null) {
            // Use the asset ID we resolved at pick time — fast and reliable
            await PhotoManager.editor.deleteWithIds([_pickedAssetId!]);
          } else {
            // Fallback for non-gallery files (e.g. Downloads folder)
            await sourceFile.delete();
          }
        } catch (_) {
          // Deletion failure is non-fatal — encryption already succeeded
        }
      }

      // Save metadata to repo (Hive or Firestore)
      await widget.repo.addFile({
        'fileName': file.name,
        'fileType': fileType,
        'fileSize': fileSize,
        'encryptedPath': encryptedPath,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File encrypted and saved.')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving file: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Secure File'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Pick file card ──────────────────────────────────────────────
            GestureDetector(
              onTap: _isSaving ? null : _pickFile,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                height: 180,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _pickedFile != null
                        ? colorScheme.primary
                        : colorScheme.outline.withOpacity(0.4),
                    width: _pickedFile != null ? 2 : 1,
                  ),
                ),
                child: _pickedFile == null
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.upload_file_rounded,
                            size: 48,
                            color: colorScheme.primary,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Tap to pick a file',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Images (JPG, PNG, etc.) or PDF',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant.withOpacity(0.7),
                            ),
                          ),
                        ],
                      )
                    : Padding(
                        padding: const EdgeInsets.all(20),
                        child: Row(
                          children: [
                            Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                color: colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Icon(
                                _fileIcon(_pickedFile!.name),
                                color: colorScheme.primary,
                                size: 28,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    _pickedFile!.name,
                                    style: theme.textTheme.titleSmall,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    SecureFileService.formatFileSize(
                                        _pickedFile!.size),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Tap to change',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ),

            const SizedBox(height: 20),

            // ── Encryption info banner ──────────────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: colorScheme.secondaryContainer.withOpacity(0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.lock_outline_rounded,
                      size: 18, color: colorScheme.secondary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'This file will be encrypted with AES-256 and stored privately on your device. It will not be visible in your file manager.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ── Delete original toggle ──────────────────────────────────────
            AnimatedOpacity(
              opacity: _pickedFile != null ? 1.0 : 0.35,
              duration: const Duration(milliseconds: 200),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                decoration: BoxDecoration(
                  color: _deleteOriginal
                      ? Colors.red.withOpacity(0.07)
                      : colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _deleteOriginal
                        ? Colors.red.withOpacity(0.3)
                        : colorScheme.outline.withOpacity(0.2),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.delete_sweep_outlined,
                      size: 18,
                      color: _deleteOriginal ? Colors.red : colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Delete original after saving',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: _deleteOriginal ? Colors.red : colorScheme.onSurface,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Text(
                            'Removes the file from gallery/storage',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: _deleteOriginal,
                      onChanged: _pickedFile == null
                          ? null
                          : (val) async {
                              if (val) {
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('Delete original?'),
                                    content: const Text(
                                      'The original file will be permanently deleted from your gallery or storage after encryption.\n\nYou can export it back from ObexVault at any time.',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx, false),
                                        child: const Text('Cancel'),
                                      ),
                                      FilledButton(
                                        onPressed: () => Navigator.pop(ctx, true),
                                        style: FilledButton.styleFrom(
                                          backgroundColor: Colors.red,
                                        ),
                                        child: const Text('Yes, delete it'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed == true) {
                                  setState(() => _deleteOriginal = true);
                                }
                              } else {
                                setState(() => _deleteOriginal = false);
                              }
                            },
                      activeColor: Colors.red,
                    ),
                  ],
                ),
              ),
            ),

            const Spacer(),

            // ── Save button ─────────────────────────────────────────────────
            FilledButton.icon(
              onPressed: (_pickedFile == null || _isSaving) ? null : _save,
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.lock_rounded),
              label: Text(_isSaving ? 'Encrypting…' : 'Encrypt & Save'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  IconData _fileIcon(String fileName) {
    final type = SecureFileService.fileTypeFromExtension(fileName);
    switch (type) {
      case 'image':
        return Icons.image_rounded;
      case 'pdf':
        return Icons.picture_as_pdf_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }
}
