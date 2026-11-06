import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 本地 M3U8 去广告过滤服务
///
/// 在本机（127.0.0.1）起一个轻量 HttpServer，播放器播 M3U8 之前先把
/// 地址包一层：http://127.0.0.1:<port>/m3u8?url=<原始地址>。
/// 服务端抓回原始 M3U8，删掉广告片段后再返回给播放器。
/// 只过滤播放列表本身，片段 URL 会解析成绝对地址直接返回（片段不走代理）。
class M3U8AdFilterService {
  M3U8AdFilterService._();

  static final M3U8AdFilterService instance = M3U8AdFilterService._();

  HttpServer? _server;
  int? _port;
  Future<void>? _starting;

  bool get isRunning => _server != null;

  /// 去广告统计（应用运行期间累计）
  /// filteredSegments：累计删掉的广告片段数
  /// filteredPlaylists：累计处理过的播放列表数
  int filteredSegments = 0;
  int filteredPlaylists = 0;

  /// 清零统计（以后用）
  void resetStats() {
    filteredSegments = 0;
    filteredPlaylists = 0;
  }

  /// 确保本地服务已启动，返回实际监听端口
  Future<int> _ensureStarted() async {
    if (_port != null) return _port!;
    // 防止并发调用重复启动
    _starting ??= _start();
    await _starting;
    return _port!;
  }

  Future<void> _start() async {
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _port = _server!.port;
      _server!.listen(_handleRequest);
    } catch (e) {
      _starting = null;
      rethrow;
    }
  }

  /// 把原始 M3U8 地址包一层本地过滤代理后返回。
  /// 如果本地服务启动失败，返回原始地址（不阻断播放）。
  Future<String> wrapUrl(String originalUrl) async {
    try {
      final port = await _ensureStarted();
      final encoded = Uri.encodeComponent(originalUrl);
      return 'http://127.0.0.1:$port/m3u8?url=$encoded';
    } catch (e) {
      return originalUrl;
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.method != 'GET' || request.uri.path != '/m3u8') {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('not found');
        await request.response.close();
        return;
      }

      final target = request.uri.queryParameters['url'];
      if (target == null || target.isEmpty) {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..write('missing url');
        await request.response.close();
        return;
      }

      final filtered = await _fetchAndFilter(target);
      if (filtered == null) {
        // 抓取失败：302 重定向到原始 M3U8，让播放器直接播原片
        // （带广告但能播），不要返回 502 导致播放失败。
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, target);
        await request.response.close();
        return;
      }

      request.response.headers.contentType =
          ContentType.parse('application/vnd.apple.mpegurl');
      request.response.write(filtered);
      await request.response.close();
    } catch (e) {
      try {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('filter error');
        await request.response.close();
      } catch (_) {}
    }
  }

  /// 抓回原始 M3U8 并过滤，失败返回 null
  Future<String?> _fetchAndFilter(String url) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 8);
    try {
      final uri = Uri.parse(url);
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36');
      req.headers.set(HttpHeaders.refererHeader, '${uri.scheme}://${uri.host}/');
      final resp = await req.close().timeout(const Duration(seconds: 12));
      if (resp.statusCode != HttpStatus.ok) return null;
      final body = await resp.transform(utf8.decoder).join();
      if (!body.contains('#EXTM3U')) return body;
      return filterPlaylist(body, url);
    } catch (e) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  // 广告特征（大小写不敏感）。注意：不用裸 "ad" 匹配，会误伤 load/head。
  // 基础规则：常见广告路径/前后缀（/ad/、/ads/、/advert、ad_、-ad-、_ad.、
  //   advertisement）+ 老牌广告平台域名（doubleclick、googlesyndication）。
  // 新增规则（都是广告专用词，不会误伤正常片段）：
  //   广告平台/域名：imasdk（Google IMA）、pubads（Google 广告服务）、
  //     adsystem、adservice、moatads、smartadserver、adnxs（AppNexus）、
  //     freewheel、springserve、taboola、outbrain；
  //   广告位类型：preroll（片头）、midroll（片中）、postroll（片尾）、
  //     adbreak/ad-break（广告插播点）、vast/vmap（视频广告协议）。
  static final RegExp _adPattern = RegExp(
    r'/ad/|/ads/|/advert|ad_|-ad-|_ad\.|doubleclick|googlesyndication|advertisement'
    r'|imasdk|pubads|adsystem|adservice|moatads|smartadserver|adnxs|freewheel|springserve|taboola|outbrain'
    r'|preroll|midroll|postroll|adbreak|ad-break|vast|vmap',
    caseSensitive: false,
  );

  static bool isAdUrl(String url) => _adPattern.hasMatch(url);

  /// 把相对地址解析成基于原始 M3U8 的绝对地址
  static String resolveUrl(String url, String baseUrl) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
    final base = Uri.parse(baseUrl);
    return base.resolve(url).toString();
  }

  /// 过滤播放列表文本：
  /// - 删掉广告片段（连同它前面的 #EXTINF 行）
  /// - #EXT-X-DISCONTINUITY 后面紧跟的片段如果全是广告，把该标记一起删掉
  /// - 主播放列表（#EXT-X-STREAM-INF）的子列表地址改写成走本过滤器
  /// - 其他标签原样保留
  static String filterPlaylist(String content, String baseUrl) {
    // 成功处理一个播放列表，计数 +1
    instance.filteredPlaylists++;
    final lines = content.split('\n');
    // 先解析成逻辑单元，方便处理
    final units = <_Unit>[];
    var i = 0;
    while (i < lines.length) {
      final line = lines[i].trim();
      if (line.isEmpty) {
        i++;
        continue;
      }
      if (line.startsWith('#EXT-X-STREAM-INF')) {
        // 变体流：下一行是子播放列表地址
        final uriLine = (i + 1 < lines.length) ? lines[i + 1].trim() : '';
        units.add(_Unit.variant([line, uriLine]));
        i += 2;
      } else if (line.startsWith('#EXTINF')) {
        // 片段：下一行是片段地址
        final uriLine = (i + 1 < lines.length) ? lines[i + 1].trim() : '';
        units.add(_Unit.segment([line, uriLine]));
        i += 2;
      } else {
        units.add(_Unit.tag([line]));
        i++;
      }
    }

    final out = <String>[];
    for (var idx = 0; idx < units.length; idx++) {
      final unit = units[idx];
      if (unit.kind == _UnitKind.variant) {
        // 子播放列表地址改写成走本过滤器
        final rawUri = unit.lines.length > 1 ? unit.lines[1] : '';
        if (rawUri.isEmpty) continue;
        final absolute = resolveUrl(rawUri, baseUrl);
        final proxied = '/m3u8?url=${Uri.encodeComponent(absolute)}';
        out.add(unit.lines[0]);
        out.add(proxied);
      } else if (unit.kind == _UnitKind.segment) {
        final rawUri = unit.lines.length > 1 ? unit.lines[1] : '';
        if (rawUri.isEmpty) continue;
        final absolute = resolveUrl(rawUri, baseUrl);
        if (isAdUrl(absolute)) {
          // 广告片段：整段删掉，计数 +1
          instance.filteredSegments++;
          continue;
        }
        out.add(unit.lines[0]);
        out.add(absolute);
      } else if (unit.kind == _UnitKind.tag &&
          unit.lines[0].startsWith('#EXT-X-DISCONTINUITY')) {
        // 往后看紧跟的片段是否全是广告
        var j = idx + 1;
        var hasSegment = false;
        var allAd = true;
        while (j < units.length && units[j].kind == _UnitKind.segment) {
          hasSegment = true;
          final rawUri =
              units[j].lines.length > 1 ? units[j].lines[1] : '';
          final absolute =
              rawUri.isEmpty ? '' : resolveUrl(rawUri, baseUrl);
          if (!isAdUrl(absolute)) {
            allAd = false;
            break;
          }
          j++;
        }
        if (hasSegment && allAd) {
          // 后面紧跟的片段全是广告（会被删掉），这个标记也删掉
          continue;
        }
        out.add(unit.lines[0]);
      } else {
        out.addAll(unit.lines);
      }
    }

    return out.join('\n');
  }

  /// 停止本地服务（一般不需要调用，应用退出时自动释放）
  Future<void> dispose() async {
    await _server?.close(force: true);
    _server = null;
    _port = null;
    _starting = null;
  }
}

enum _UnitKind { tag, segment, variant }

class _Unit {
  final _UnitKind kind;
  final List<String> lines;

  _Unit._(this.kind, this.lines);

  factory _Unit.tag(List<String> lines) => _Unit._(_UnitKind.tag, lines);
  factory _Unit.segment(List<String> lines) =>
      _Unit._(_UnitKind.segment, lines);
  factory _Unit.variant(List<String> lines) =>
      _Unit._(_UnitKind.variant, lines);
}
