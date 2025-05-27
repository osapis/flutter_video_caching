import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../cache/lru_cache_singleton.dart';
import '../download/download_status.dart';
import '../download/download_task.dart';
import '../ext/file_ext.dart';
import '../ext/int_ext.dart';
import '../ext/log_ext.dart';
import '../ext/socket_ext.dart';
import '../ext/uri_ext.dart';
import '../global/config.dart';
import '../proxy/video_proxy.dart';
import 'url_parser.dart';

/// MP4 URL parser
class UrlParserDefault implements UrlParser {
  /// Get the cache data from memory or file.
  /// If there is no cache data, return null.
  @override
  Future<Uint8List?> cache(DownloadTask task) async {
    Uint8List? dataMemory = await LruCacheSingleton().memoryGet(task.matchUrl);
    if (dataMemory != null) {
      logD('From memory: ${dataMemory.lengthInBytes.toMemorySize}');
      return dataMemory;
    }
    String filePath = '${await FileExt.createCachePath(task.uri.generateMd5)}'
        '/${task.saveFileName}';
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
    String cachePath = await FileExt.createCachePath(task.uri.generateMd5);
    task.cacheDir = cachePath;
    await VideoProxy.downloadManager.executeTask(task);
    await for (DownloadTask taskStream in VideoProxy.downloadManager.stream) {
      if (taskStream.status == DownloadStatus.COMPLETED &&
          taskStream.matchUrl == task.matchUrl) {
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
    String cachePath = await FileExt.createCachePath(task.uri.generateMd5);
    File file = File('$cachePath/${task.saveFileName}');
    if (await file.exists()) return;
    task.cacheDir = cachePath;
    await VideoProxy.downloadManager.addTask(task);
  }

  /// Parse the request and return the data.
  /// If the request is not valid, return false.
  ///
  /// Large file download is divided into segments, and each segment is 2Mb by default.
  /// The segment size can be changed by modifying the `Config.segmentSize` value.
  @override
  Future<bool> parse(
    Socket socket,
    Uri uri,
    Map<String, String> headers,
  ) async {
    try {
      RegExp exp = RegExp(r'bytes=(\d+)-(\d*)');
      RegExpMatch? rangeMatch = exp.firstMatch(headers['range'] ?? '');
      int requestRangeStart = int.tryParse(rangeMatch?.group(1) ?? '0') ?? 0;
      int requestRangeEnd = int.tryParse(rangeMatch?.group(2) ?? '0') ?? -1;
      bool partial = requestRangeStart > 0 || requestRangeEnd > 0;
      List<String> responseHeaders = <String>[
        partial ? 'HTTP/1.1 206 Partial Content' : 'HTTP/1.1 200 OK',
        'Accept-Ranges: bytes',
        'Content-Type: video/mp4',
        'Connection: keep-alive',
      ];

      if (Platform.isAndroid) {
        await parseAndroid(
          socket,
          uri,
          responseHeaders,
          requestRangeStart,
          requestRangeEnd,
        );
      } else {
        await parseIOS(
          socket,
          uri,
          responseHeaders,
          requestRangeStart,
          requestRangeEnd,
        );
      }
      await socket.flush();
      return true;
    } catch (e) {
      logW('[UrlParserDefault] ⚠ ⚠ ⚠ parse error: $e');
      return false;
    } finally {
      await socket.close();
      logD('Connection closed\n');
    }
  }

  Future<void> parseAndroid(
    Socket socket,
    Uri uri,
    List<String> responseHeaders,
    int requestRangeStart,
    int requestRangeEnd,
  ) async {
    int contentLength = await head(uri);
    requestRangeEnd = contentLength - 1;
    responseHeaders.add('content-length: ${contentLength - requestRangeStart}');
    await socket.append(responseHeaders.join('\r\n'));

    bool downloading = true;
    int startRange =
        requestRangeStart - (requestRangeStart % Config.segmentSize);
    int endRange = startRange + Config.segmentSize - 1;
    int retry = 3;
    while (downloading) {
      DownloadTask task = DownloadTask(
        uri: uri,
        startRange: startRange,
        endRange: endRange,
      );
      logD('Request range：${task.startRange}-${task.endRange}');

      Uint8List? data = await cache(task);
      if (data == null) {
        concurrent(task);
        task.priority += 10;
        data = await download(task);
      }
      if (data == null) {
        retry--;
        if (retry == 0) {
          downloading = false;
          break;
        }
        continue;
      }

      int startIndex = 0;
      int? endIndex;
      if (startRange < requestRangeStart) {
        startIndex = requestRangeStart - startRange;
      }
      if (endRange > requestRangeEnd) {
        endIndex = requestRangeEnd - startRange + 1;
      }
      data = data.sublist(startIndex, endIndex);
      socket.done.then((value) {
        downloading = false;
      }).catchError((e) {
        downloading = false;
      });
      bool success = await socket.append(data);
      if (!success) downloading = false;
      startRange += Config.segmentSize;
      endRange = startRange + Config.segmentSize - 1;
      if (startRange > requestRangeEnd) {
        downloading = false;
      }
    }
  }

  Future<void> parseIOS(
    Socket socket,
    Uri uri,
    List<String> responseHeaders,
    int requestRangeStart,
    int requestRangeEnd,
  ) async {
    if ((requestRangeStart == 0 && requestRangeEnd == 1) ||
        requestRangeEnd == -1) {
      DownloadTask task = DownloadTask(uri: uri, startRange: 0, endRange: 1);
      Uint8List? data = await cache(task);
      int contentLength = 0;
      if (data != null) {
        contentLength = int.tryParse(Utf8Codec().decode(data)) ?? 0;
      }
      if (contentLength == 0) {
        contentLength = await head(uri);
        String filePath =
            '${await FileExt.createCachePath(task.uri.generateMd5)}'
            '/${task.saveFileName}';
        File file = File(filePath);
        file.writeAsString(contentLength.toString());
        LruCacheSingleton().storagePut(file.path, file);
      }
      if (requestRangeStart == 0 && requestRangeEnd == 1) {
        responseHeaders.add('content-range: bytes 0-1/$contentLength');
        await socket.append(responseHeaders.join('\r\n'));
        await socket.append([0]);
        await socket.close();
        return;
      } else if (requestRangeEnd == -1) {
        requestRangeEnd = contentLength - 1;
      }
    }

    int contentLength = requestRangeEnd - requestRangeStart + 1;
    responseHeaders.add('content-length: $contentLength');
    await socket.append(responseHeaders.join('\r\n'));
    logD('content-range：$requestRangeStart-$requestRangeEnd');
    logD('content-length：$contentLength');

    bool downloading = true;
    int startRange =
        requestRangeStart - (requestRangeStart % Config.segmentSize);
    int endRange = startRange + Config.segmentSize - 1;
    int retry = 3;
    while (downloading) {
      DownloadTask task = DownloadTask(
        uri: uri,
        startRange: startRange,
        endRange: endRange,
      );
      logD('Request range：${task.startRange}-${task.endRange}');

      Uint8List? data = await cache(task);
      if (data == null) {
        concurrent(task);
        task.priority += 10;
        data = await download(task);
      }
      if (data == null) {
        retry--;
        if (retry == 0) {
          downloading = false;
          break;
        }
        continue;
      }

      int startIndex = 0;
      int? endIndex;
      if (startRange < requestRangeStart) {
        startIndex = requestRangeStart - startRange;
      }
      if (endRange > requestRangeEnd) {
        endIndex = requestRangeEnd - startRange + 1;
      }
      data = data.sublist(startIndex, endIndex);
      socket.done.then((value) {
        downloading = false;
      }).catchError((e) {
        downloading = false;
      });
      bool success = await socket.append(data);
      if (!success) downloading = false;
      startRange += Config.segmentSize;
      endRange = startRange + Config.segmentSize - 1;
      if (startRange > requestRangeEnd) {
        downloading = false;
      }
    }
  }

  Future<int> head(Uri uri) async {
    HttpClient client = HttpClient();
    HttpClientRequest request = await client.headUrl(uri);
    HttpClientResponse response = await request.close();
    client.close();
    return response.contentLength;
  }

  /// Delete the file if it exceeds the size limit.
  /// Sometimes because network problem, the download file size is larger than
  /// the segment size, so we need to delete and re-download the file.
  /// Or it may lead to source error.
  Future<void> deleteExceedSizeFile(DownloadTask task) async {
    String cachePath = await FileExt.createCachePath(task.uri.generateMd5);
    File file = File('$cachePath/${task.saveFileName}');
    if (await file.exists()) await file.delete();
  }

  /// Download task concurrently.<br>
  /// The maximum number of concurrent downloads is 3. Too many concurrent
  /// connections will result in long waiting times.<br>
  /// If the number of concurrent downloads is less than 3, create a new task and
  /// add it to the download queue.<br>
  Future<void> concurrent(DownloadTask task) async {
    int activeSize = VideoProxy.downloadManager.allTasks
        .where((e) => e.url == task.url)
        .length;
    DownloadTask newTask = task;
    while (activeSize < 3) {
      newTask = DownloadTask(
        uri: newTask.uri,
        startRange: newTask.startRange + Config.segmentSize,
        endRange: newTask.startRange + Config.segmentSize * 2 - 1,
      );
      bool isExit = VideoProxy.downloadManager.allTasks
          .where((e) => e.matchUrl == newTask.matchUrl)
          .isNotEmpty;
      Uint8List? dataMemory =
          await LruCacheSingleton().memoryGet(newTask.matchUrl);
      if (dataMemory != null) isExit = true;
      String cachePath = await FileExt.createCachePath(task.uri.generateMd5);
      File file = File('$cachePath/${task.saveFileName}');
      if (await file.exists()) isExit = true;
      if (isExit) continue;
      logD("Asynchronous download start： ${newTask.toString()}");
      newTask.cacheDir = cachePath;
      await VideoProxy.downloadManager.executeTask(newTask);
      activeSize = VideoProxy.downloadManager.allTasks
          .where((e) => e.url == task.url)
          .length;
    }
  }

  /// Pre-cache the data from network.
  ///
  /// [cacheSegments] is the number of segments to cache.
  /// [downloadNow] is whether to download the data now or just push the task to the queue.
  @override
  void precache(String url, int cacheSegments, bool downloadNow) async {
    int count = 0;
    while (count < cacheSegments) {
      DownloadTask task = DownloadTask(uri: Uri.parse(url));
      task.startRange += Config.segmentSize * count;
      task.endRange = task.startRange + Config.segmentSize - 1;
      if (downloadNow) {
        Uint8List? data = await cache(task);
        if (data == null) download(task);
      } else {
        push(task);
      }
      count++;
    }
  }
}
