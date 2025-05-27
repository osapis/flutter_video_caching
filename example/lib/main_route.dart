import 'package:flutter/material.dart';
import 'package:flutter_video_caching/flutter_video_caching.dart';

import 'page/download_page.dart';
import 'page/fplayer_page.dart';
import 'page/m3u8_parser_page.dart';
import 'page/storage_cache_page.dart';
import 'page/video_page_view_page.dart';
import 'page/video_play_page.dart';

class MainRoute extends StatefulWidget {
  const MainRoute({super.key});

  @override
  State<MainRoute> createState() => _MainRouteState();
}

class _MainRouteState extends State<MainRoute> {
  final Map<String, Widget> _routes = {
    'Download': const DownloadPage(),
    'M3u8Parser': const M3u8ParserPage(),
    'VideoPlay': const VideoPlayPage(),
    'VideoPageView': const VideoPageViewPage(),
    'StorageCache': const StorageCachePage(),
    'FPlayer': const FPlayerPage(),
  };
  final List<String> urls = [
    'http://mirror.aarnet.edu.au/pub/TED-talks/911Mothers_2010W-480p.mp4',
    'http://vjs.zencdn.net/v/oceans.mp4',
    'https://test-streams.mux.dev/x36xhzz/url_6/193039199_mp4_h264_aac_hq_7.m3u8',
  ];

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < 3; i++) {
      // VideoCaching.precache(urls[i]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('flutter_video_caching'),
      ),
      body: ListView.builder(
        itemCount: _routes.length,
        itemBuilder: (context, index) {
          final String key = _routes.keys.elementAt(index);
          final Widget value = _routes[key]!;
          return ListTile(
            title: Text(key),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => value),
              );
            },
          );
        },
      ),
    );
  }
}
