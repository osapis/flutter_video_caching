import 'dart:convert';

import 'package:crypto/crypto.dart';
import '../ext/log_ext.dart';

extension UriExt on Uri {
  String get pathPrefix {
    if (pathSegments.isEmpty) {
      throw Exception("Path segments are empty");
    }
    final newUri = Uri(
      scheme: scheme,
      host: host,
      port: port,
      pathSegments: pathSegments.take(pathSegments.length - 1).toList(),
    );
    return newUri.toString();
  }

  /// Generate MD5
  String get generateMd5 {
    return md5.convert(utf8.encode(this.toString())).toString();
  }
}
