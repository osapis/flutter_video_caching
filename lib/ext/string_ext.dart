import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../global/config.dart';

extension UrlExt on String {
  /// Convert to local http address
  String toLocalUrl() {
    if (!startsWith('http')) return this;
    Uri uri = Uri.parse(this);
    if (uri.host == Config.ip && uri.port == Config.port) return this;
    // String proxy = 'http://${Config.ip}:${Config.port}';
    final proxyUri = Uri(
      scheme: "http",
      host: Config.ip,
      port: Config.port,
      path: uri.path,
      queryParameters: {...uri.queryParameters, 'origin': uri.origin},
    );
    return proxyUri.toString();
  }

  /// Convert to local http address
  Uri toLocalUri() {
    return Uri.parse(toLocalUrl());
  }

  /// Convert to original link
  String toOriginUrl() {
    Uri uri = Uri.parse(this);
    String? origin = uri.queryParameters['origin'];
    if (origin == null) return this;
    final originUri = Uri.parse(origin);
    final originQueryParameters = {...uri.queryParameters};
    originQueryParameters.remove('origin');
    final originUrl =
        Uri(
          scheme: originUri.scheme,
          host: originUri.host,
          port: originUri.port,
          path: uri.path,
          queryParameters: originQueryParameters,
        ).toString();
    print(originQueryParameters);
    print(originUri.queryParameters);
    return originUrl;
  }

  /// Convert to original link
  Uri toOriginUri() {
    return Uri.parse(toOriginUrl());
  }

  /// Generate MD5
  String get generateMd5 {
    return md5.convert(utf8.encode(this)).toString();
  }
}
