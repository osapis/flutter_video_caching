import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_hls_parser/flutter_hls_parser.dart';

import '../cache/lru_cache_singleton.dart';
import '../download/download_status.dart';
import '../download/download_task.dart';
import '../ext/file_ext.dart';
import '../ext/int_ext.dart';
import '../ext/log_ext.dart';
import '../ext/socket_ext.dart';
import '../ext/string_ext.dart';
import '../ext/uri_ext.dart';
import '../proxy/video_proxy.dart';
import 'url_parser.dart';

/// M3U8 URL parser
class UrlParserM3U8 implements UrlParser {
  static final List<HlsSegment> _list = <HlsSegment>[];
  static String _latestUrl = '';

  HlsSegment? findSegmentByUri(Uri uri) {
    return _list.where((task) => task.url == uri.toString()).firstOrNull;
  }

  @override
  bool match(Uri uri) {
    return uri.path.toLowerCase().endsWith('.m3u8') ||
        uri.path.toLowerCase().endsWith('.key') ||
        uri.path.toLowerCase().endsWith('.ts');
  }

  /// Get the cache data from memory or file.
  /// If there is no cache data, return null.
  @override
  Future<Uint8List?> cache(DownloadTask task) async {
    Uint8List? dataMemory = await LruCacheSingleton().memoryGet(task.matchUrl);
    if (dataMemory != null) {
      logD(
        'From memory: ${dataMemory.lengthInBytes.toMemorySize}, '
        'total memory size: ${await LruCacheSingleton().memoryFormatSize()}',
      );
      return dataMemory;
    }
    String filePath =
        '${await FileExt.createCachePath(task.hlsKey)}/${task.saveFileName}';
    Uint8List? dataFile = await LruCacheSingleton().storageGet(filePath);
    if (dataFile != null) {
      logD('From file: ${filePath}');
      await LruCacheSingleton().memoryPut(task.matchUrl, dataFile);
      return dataFile;
    }
    return null;
  }

  /// Download the data from network.
  @override
  Future<Uint8List?> download(DownloadTask task) async {
    logD('From network: ${task.url}');
    Uint8List? dataNetwork;
    task.cacheDir = await FileExt.createCachePath(task.hlsKey);
    await VideoProxy.downloadManager.executeTask(task);
    await for (DownloadTask taskStream in VideoProxy.downloadManager.stream) {
      if (taskStream.status == DownloadStatus.COMPLETED &&
          taskStream.url == task.url) {
        dataNetwork = Uint8List.fromList(taskStream.data);
        break;
      }
    }
    return dataNetwork;
  }

  /// Push the task to the download manager.
  /// If the task is already in the download manager, do nothing.
  @override
  Future<void> push(DownloadTask task) async {
    Uint8List? dataMemory = await LruCacheSingleton().memoryGet(task.matchUrl);
    if (dataMemory != null) return;
    String cachePath = await FileExt.createCachePath(task.hlsKey);
    File file = File('$cachePath/${task.saveFileName}');
    if (await file.exists()) return;
    task.cacheDir = cachePath;
    await VideoProxy.downloadManager.addTask(task);
  }

  /// Parse the data from socket.
  /// If the request is not valid, return false.
  ///
  /// After parsing m3u8 file, it will replace the url with the local url.
  @override
  Future<bool> parse(
    Socket socket,
    Uri uri,
    Map<String, String> headers,
  ) async {
    try {
      DownloadTask task = DownloadTask(uri: uri, hlsKey: uri.generateMd5);
      HlsSegment? hlsSegment = findSegmentByUri(uri);
      if (hlsSegment != null) task.hlsKey = hlsSegment.key;
      Uint8List? data = await cache(task);
      if (data == null) {
        concurrentLoop(hlsSegment);
        task.priority += 10;
        data = await download(task);
      }
      if (data == null) return false;
      String contentType = 'application/octet-stream';
      if (task.uri.path.endsWith('.m3u8')) {
        List<String> lines = readLineFromUint8List(data);
        String lastLine = '';
        StringBuffer buffer = StringBuffer();
        for (String line in lines) {
          String hlsLine = line.trim();
          String? encryptKeyUri;
          if (hlsLine.startsWith("#EXT-X-KEY")) {
            Match? match = RegExp(r'URI="([^"]+)"').firstMatch(hlsLine);
            if (match != null && match.groupCount >= 1) {
              encryptKeyUri = match.group(1);
              if (encryptKeyUri != null) {
                String newUri = encryptKeyUri.startsWith('http')
                    ? encryptKeyUri.toLocalUrl()
                    : (encryptKeyUri.contains("?") == true
                        ? '$encryptKeyUri?origin=${uri.origin}'
                        : '$encryptKeyUri&origin=${uri.origin}');
                line = hlsLine.replaceAll(encryptKeyUri, newUri);
              }
            }
          }
          if (lastLine.startsWith("#EXTINF") ||
              lastLine.startsWith("#EXT-X-STREAM-INF")) {
            line = line.startsWith('http')
                ? line.toLocalUrl()
                : (line.contains("?") == true
                    ? '$line&origin=${uri.origin}'
                    : '$line?origin=${uri.origin}');
          }
          // Setting HLS segment to same key, it will be downloaded in the same directory.
          if (hlsLine.startsWith("#EXT-X-KEY") && encryptKeyUri != null) {
            if (!encryptKeyUri.startsWith('http')) {
              encryptKeyUri = '${uri.pathPrefix}/' + encryptKeyUri;
            }
            concurrentAdd(HlsSegment(url: encryptKeyUri, key: task.hlsKey!));
          }
          if (lastLine.startsWith("#EXTINF") ||
              lastLine.startsWith("#EXT-X-STREAM-INF")) {
            if (!hlsLine.startsWith('http')) {
              hlsLine = '${uri.pathPrefix}/' + hlsLine;
            }
            concurrentAdd(HlsSegment(url: hlsLine, key: task.hlsKey!));
          }
          buffer.write('$line\r\n');
          lastLine = line;
        }
        data = Uint8List.fromList(buffer.toString().codeUnits);
        contentType = 'application/vnd.apple.mpegurl';
      } else if (task.uri.path.endsWith('.key')) {
        contentType = 'application/octet-stream';
        logW(data.length);
      } else if (task.uri.path.endsWith('.ts')) {
        contentType = 'video/MP2T';
      }
      String responseHeaders = <String>[
        'HTTP/1.1 200 OK',
        'Content-Type: $contentType',
        'Connection: keep-alive',
        if (contentType == 'video/MP2T') 'Accept-Ranges: bytes',
      ].join('\r\n');
      await socket.append(responseHeaders);
      await socket.append(data);
      await socket.flush();
      logD('Return request data: $uri');
      return true;
    } catch (e) {
      logE('[UrlParserM3U8] ⚠ ⚠ ⚠ parse error: $e');
      return false;
    } finally {
      await socket.close();
      logD('Connection closed\n');
    }
  }

  /// Read the lines from Uint8List and decode them to String.
  List<String> readLineFromUint8List(Uint8List uint8List) {
    List<String> lines = [];
    Utf8Codec codec = Utf8Codec();
    int startIndex = 0;
    int lastIndex = 0;
    for (var byte in uint8List) {
      if (byte == 0x0A) {
        Uint8List line = uint8List.sublist(startIndex, lastIndex);
        lines.add(codec.decode(line));
        startIndex = lastIndex + 1;
      }
      lastIndex++;
    }
    return lines;
  }

  /// Asynchronous downloading of ts files.
  Future<void> concurrentLoop(HlsSegment? hlsSegment) async {
    if (hlsSegment == null) return;
    _latestUrl = hlsSegment.url;
    Set<String?> hlsKeys = _list.map((e) => e.key).toSet();
    if (hlsKeys.length > 2) {
      _list.where((e) => e.key == hlsKeys.first).forEach((e) {
        VideoProxy.downloadManager.allTasks.removeWhere(
          (task) => task.url == e.url,
        );
      });
      _list.removeWhere((e) => e.key == hlsKeys.first);
    }
    HlsSegment? segment = _list.where((e) => e.url == _latestUrl).firstOrNull;
    if (segment == null) return;
    List<HlsSegment> downloading = _list
        .where((e) => e.key == segment.key)
        .where((e) => e.status == DownloadStatus.DOWNLOADING)
        .toList();
    if (downloading.length >= 4) return;
    Uint8List? cache = await LruCacheSingleton().memoryGet(
      segment.url.generateMd5,
    );
    if (cache != null) {
      concurrentComplete(segment);
      return;
    }
    DownloadTask task = DownloadTask(uri: Uri.parse(segment.url));
    String cachePath = await FileExt.createCachePath(segment.key);
    File file = File('$cachePath/${task.saveFileName}');
    if (await file.exists()) {
      concurrentComplete(segment);
      return;
    }
    bool exitUri = VideoProxy.downloadManager.isUrlExit(segment.url);
    if (exitUri) {
      concurrentComplete(segment, status: DownloadStatus.DOWNLOADING);
      return;
    }
    task.priority += 1;
    task.cacheDir = cachePath;
    await VideoProxy.downloadManager.executeTask(task);
    StreamSubscription? subscription;
    subscription = VideoProxy.downloadManager.stream.listen((downloadTask) {
      if (downloadTask.status == DownloadStatus.COMPLETED &&
          downloadTask.matchUrl == task.matchUrl) {
        logD("Asynchronous download completed： ${task.toString()}");
        subscription?.cancel();
        concurrentComplete(segment);
      }
    });
  }

  void concurrentAdd(HlsSegment hlsSegment) {
    bool match = _list.where((e) => e.url == hlsSegment.url).isNotEmpty;
    if (!match) _list.add(hlsSegment);
  }

  void concurrentComplete(HlsSegment hlsSegment, {DownloadStatus? status}) {
    int index = _list.indexWhere((e) => e.url == hlsSegment.url);
    if (index == -1) return;
    _list[index].status = status ?? DownloadStatus.COMPLETED;
    HlsSegment? latest = _list.where((e) => e.url == _latestUrl).firstOrNull;
    if (latest != null) {
      List<HlsSegment> list = _list.where((e) => e.key == latest.key).toList();
      int index = list.indexWhere((e) => e.url == latest.url);
      if (index != -1 && index + 1 < list.length) {
        concurrentLoop(list[index + 1]);
        return;
      }
    }
    Set<String?> keys = _list.map((e) => e.key).toSet();
    String? key = keys.elementAt(Random().nextInt(keys.length));
    HlsSegment? idleSegment = _list
        .where((e) => e.key == key)
        .where((e) => e.status == DownloadStatus.IDLE)
        .firstOrNull;
    if (idleSegment == null) {
      _list.removeWhere((e) => e.key == key);
      concurrentComplete(hlsSegment);
      return;
    }
    concurrentLoop(idleSegment);
  }

  /// Pre-cache the data from network.
  ///
  /// [cacheSegments] is the number of segments to cache.
  /// [downloadNow] is whether to download the data now or just push the task to the queue.
  @override
  void precache(String url, int cacheSegments, bool downloadNow) async {
    List<String> mediaList = await parseSegment(Uri.parse(url));
    if (mediaList.isEmpty) return;
    final List<String> segments = mediaList.take(cacheSegments).toList();
    for (final String segment in segments) {
      DownloadTask task = DownloadTask(
        uri: Uri.parse(segment),
        hlsKey: url.generateMd5,
      );
      if (downloadNow) {
        Uint8List? data = await cache(task);
        if (data != null) continue;
        download(task);
      } else {
        push(task);
      }
    }
  }

  /// Parsing M3U8 ts files
  Future<List<String>> parseSegment(Uri uri) async {
    final HlsMediaPlaylist? playList = await parseMediaPlaylist(uri);
    if (playList == null) return <String>[];
    List<String> segments = <String>[];
    for (final Segment segment in playList.segments) {
      String segmentUrl = segment.url ?? '';
      if (!segmentUrl.startsWith('http')) {
        segmentUrl = '${uri.pathPrefix}/$segmentUrl';
      }
      segments.add(segmentUrl);
    }
    return segments;
  }

  /// Parsing M3U8 media playlist
  Future<HlsMediaPlaylist?> parseMediaPlaylist(
    Uri uri, {
    String? hlsKey,
  }) async {
    final HlsPlaylist? playList = await parsePlaylist(uri, hlsKey: hlsKey);
    if (playList is HlsMasterPlaylist) {
      for (final Uri? _uri in playList.mediaPlaylistUrls) {
        if (_uri == null) continue;
        Uri masterUri = Uri.parse('${uri.pathPrefix}${_uri.path}');
        HlsMediaPlaylist? mediaPlayList = await parseMediaPlaylist(
          masterUri,
          hlsKey: uri.generateMd5,
        );
        return mediaPlayList;
      }
    } else if (playList is HlsMediaPlaylist) {
      return playList;
    }
    return null;
  }

  /// Parsing M3U8 resolution list
  Future<HlsPlaylist?> parsePlaylist(Uri uri, {String? hlsKey}) async {
    DownloadTask task = DownloadTask(
      uri: uri,
      hlsKey: hlsKey ?? uri.generateMd5,
    );
    Uint8List? uint8List = await cache(task);
    if (uint8List == null) uint8List = await download(task);
    if (uint8List == null) return null;
    List<String> lines = readLineFromUint8List(uint8List);
    final HlsPlaylist? playList = await parseLines(lines);
    return playList;
  }

  /// Parsing M3U8 data lines
  Future<HlsPlaylist?> parseLines(List<String> lines) async {
    HlsPlaylist? playList;
    try {
      playList = await VideoProxy.hlsPlaylistParser.parse(Uri.base, lines);
    } catch (e) {
      logE('Exception: ${e}');
    }
    return playList;
  }
}

class HlsSegment {
  final String key;
  final String url;
  DownloadStatus status;

  HlsSegment({
    required this.key,
    required this.url,
    this.status = DownloadStatus.IDLE,
  });
}
