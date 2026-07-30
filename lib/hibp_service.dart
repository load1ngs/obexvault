import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

class HibpService {
  static Future<int> checkPassword(String password) async {
    // Step 1: SHA-1 hash the password
    final bytes = utf8.encode(password);
    final hash = sha1.convert(bytes).toString().toUpperCase();

    // Step 2: Split — first 5 chars go to API, rest stays local
    final prefix = hash.substring(0, 5);
    final suffix = hash.substring(5);

    // Step 3: Call HIBP API with only the prefix
    final url = Uri.parse('https://api.pwnedpasswords.com/range/$prefix');
    final response = await http.get(url, headers: {
      'Add-Padding': 'true',
    });

    if (response.statusCode != 200) return -1; // error

    // Step 4: Search for our suffix in the response
    final lines = response.body.split('\n');
    for (final line in lines) {
      final parts = line.split(':');
      if (parts[0].trim() == suffix) {
        return int.parse(parts[1].trim()); // return breach count
      }
    }

    return 0; // not found — safe!
  }
}