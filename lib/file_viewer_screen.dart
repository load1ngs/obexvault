import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'secure_file_service.dart';
import 'vault_repository.dart';

class FileViewerScreen extends StatefulWidget {
  final Map<String, dynamic> fileMeta;
  final VaultRepository repo;

  const FileViewerScreen({
    super.key,
    required this.fileMeta,
    required this.repo,
  });

  @override
  State<FileViewerScreen> createState() => _FileViewerScreenState();
}

class _FileViewerScreenState extends State<FileViewerScreen> {
  Uint8List? _decryptedBytes;
  String? _tempPdfPath;
  bool _loading = true;
  String? _error;

  String get _fileName => widget.fileMeta['fileName'] as String? ?? 'File';
  String get _fileType => widget.fileMeta['fileType'] as String? ?? 'other';
  String get _encryptedPath => widget.fileMeta['encryptedPath'] as String? ?? '';
  String get _fileId => widget.fileMeta['id'] as String? ?? '';

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadFile();
  }

  @override
  void dispose() {
    _cleanupTempFile();
    // Zero out decrypted bytes from memory
    if (_decryptedBytes != null) {
      _decryptedBytes!.fillRange(0, _decryptedBytes!.length, 0);
    }
    super.dispose();
  }

  // ── Load & decrypt ────────────────────────────────────────────────────────

  Future<void> _loadFile() async {
    try {
      final bytes = await SecureFileService.decryptToBytes(
        encryptedPath: _encryptedPath,
      );

      if (_fileType == 'pdf') {
        // PDF viewer needs a file path, so write to a temp file
        // This temp file is in the app's cache dir (still private, not visible
        // in file manager) and will be deleted when the viewer closes
        final tempDir = await getTemporaryDirectory();
        final tempFile = File('${tempDir.path}/obx_preview_$_fileId.pdf');
        await tempFile.writeAsBytes(bytes);
        if (mounted) {
          setState(() {
            _tempPdfPath = tempFile.path;
            _loading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _decryptedBytes = bytes;
            _loading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not decrypt file: $e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _cleanupTempFile() async {
    if (_tempPdfPath != null) {
      final f = File(_tempPdfPath!);
      if (await f.exists()) await f.delete();
    }
  }

  // ── Export ────────────────────────────────────────────────────────────────

  Future<void> _exportFile() async {
    try {
      final bytes = await SecureFileService.decryptToBytes(
        encryptedPath: _encryptedPath,
      );

      if (_fileType == 'image') {
        // Save image directly to gallery
        await Gal.putImageBytes(bytes, name: _fileName);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Image saved to gallery.')),
          );
        }
      } else {
        // Save PDF to app's Documents directory (accessible via Files app)
        final dir = await getExternalStorageDirectory();
        final saveDir = dir ?? await getApplicationDocumentsDirectory();
        final outFile = File('${saveDir.path}/$_fileName');
        await outFile.writeAsBytes(bytes);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('PDF saved to: ${outFile.path}')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete File'),
        content: Text('Permanently delete "$_fileName"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    await SecureFileService.deleteEncryptedFile(_encryptedPath);
    await widget.repo.deleteFile(_fileId);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File deleted.')),
      );
      Navigator.pop(context);
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _fileName,
              style: const TextStyle(fontSize: 15, color: Colors.white),
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              SecureFileService.formatFileSize(
                  widget.fileMeta['fileSize'] as int? ?? 0),
              style: TextStyle(
                fontSize: 11,
                color: Colors.white.withOpacity(0.6),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.save_alt_rounded, color: Colors.white70),
            tooltip: 'Export to gallery',
            onPressed: _loading ? null : _exportFile,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
            tooltip: 'Delete file',
            onPressed: _loading ? null : _confirmDelete,
          ),
        ],
      ),
      body: _buildBody(colorScheme),
    );
  }

  Widget _buildBody(ColorScheme colorScheme) {
    // Loading state
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text(
              'Decrypting…',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      );
    }

    // Error state
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: Colors.redAccent, size: 48),
              const SizedBox(height: 16),
              Text(
                _error!,
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    // PDF viewer
    if (_fileType == 'pdf' && _tempPdfPath != null) {
      return SfPdfViewer.file(
        File(_tempPdfPath!),
        canShowScrollHead: true,
        canShowScrollStatus: true,
      );
    }

    // Image viewer
    if (_fileType == 'image' && _decryptedBytes != null) {
      return InteractiveViewer(
        minScale: 0.5,
        maxScale: 5.0,
        child: Center(
          child: Image.memory(
            _decryptedBytes!,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Center(
              child: Text(
                'Could not render image.',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ),
        ),
      );
    }

    // Unsupported type fallback
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.insert_drive_file_rounded,
              color: Colors.white38, size: 64),
          const SizedBox(height: 16),
          Text(
            _fileName,
            style: const TextStyle(color: Colors.white70, fontSize: 16),
          ),
          const SizedBox(height: 8),
          const Text(
            'Preview not available for this file type.',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
