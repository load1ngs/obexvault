import 'dart:convert';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

class DmsPdfService {
  /// Generates a PDF from the vault entries and returns it as a base64 string.
  /// The base64 string is stored in Firestore — no Firebase Storage needed.
  static Future<String> generateBase64(
      List<Map<String, dynamic>> entries) async {
    final pdf = pw.Document();

    final headerStyle = pw.TextStyle(
      fontSize: 20,
      fontWeight: pw.FontWeight.bold,
      color: PdfColors.deepPurple,
    );
    final subHeaderStyle = pw.TextStyle(
      fontSize: 11,
      color: PdfColors.grey700,
    );
    final labelStyle = pw.TextStyle(
      fontSize: 10,
      fontWeight: pw.FontWeight.bold,
      color: PdfColors.grey800,
    );
    final valueStyle = pw.TextStyle(
      fontSize: 10,
      color: PdfColors.black,
    );

    final now = DateTime.now();
    final dateStr =
        '${now.day} ${_monthName(now.month)} ${now.year}  •  '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        header: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('ObexVault — Emergency Credential Export',
                style: headerStyle),
            pw.SizedBox(height: 4),
            pw.Text('Generated: $dateStr', style: subHeaderStyle),
            pw.Text(
              "This file was automatically shared by ObexVault's Dead Man's Switch.",
              style: subHeaderStyle,
            ),
            pw.Divider(color: PdfColors.deepPurple200, thickness: 1),
            pw.SizedBox(height: 8),
          ],
        ),
        build: (context) {
          final widgets = <pw.Widget>[];
          for (int i = 0; i < entries.length; i++) {
            final e = entries[i];
            widgets.add(
              pw.Container(
                margin: const pw.EdgeInsets.only(bottom: 12),
                padding: const pw.EdgeInsets.all(10),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey300),
                  borderRadius: pw.BorderRadius.circular(6),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      '${i + 1}. ${e['title'] ?? 'Untitled'}',
                      style: pw.TextStyle(
                          fontSize: 12, fontWeight: pw.FontWeight.bold),
                    ),
                    pw.SizedBox(height: 6),
                    if ((e['username'] ?? '').toString().isNotEmpty)
                      _row('Username', e['username'].toString(), labelStyle, valueStyle),
                    if ((e['password'] ?? '').toString().isNotEmpty)
                      _row('Password', e['password'].toString(), labelStyle, valueStyle),
                    if ((e['url'] ?? '').toString().isNotEmpty)
                      _row('URL', e['url'].toString(), labelStyle, valueStyle),
                    if ((e['notes'] ?? '').toString().isNotEmpty)
                      _row('Notes', e['notes'].toString(), labelStyle, valueStyle),
                  ],
                ),
              ),
            );
          }
          if (widgets.isEmpty) {
            widgets.add(pw.Text('No vault entries found.', style: valueStyle));
          }
          return widgets;
        },
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: pw.TextStyle(fontSize: 9, color: PdfColors.grey500),
          ),
        ),
      ),
    );

    final bytes = await pdf.save();
    return base64Encode(bytes);
  }

  static pw.Widget _row(String label, String value,
      pw.TextStyle labelStyle, pw.TextStyle valueStyle) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 3),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(width: 72, child: pw.Text('$label:', style: labelStyle)),
          pw.Expanded(child: pw.Text(value, style: valueStyle)),
        ],
      ),
    );
  }

  static String _monthName(int month) {
    const months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return months[month];
  }
}
