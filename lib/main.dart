import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wifi_scan/wifi_scan.dart';

/* ---------- saved Wi-Fi networks ---------- */

class Net {
  final String ssid, pass, type;
  const Net(this.ssid, this.pass, this.type);
  Map<String, String> toJson() => {'s': ssid, 'p': pass, 't': type};
  factory Net.fromJson(Map<String, dynamic> j) =>
      Net(j['s'] as String, j['p'] as String, j['t'] as String);
}

final ValueNotifier<List<Net>> nets = ValueNotifier<List<Net>>([]);

Future<void> loadNets() async {
  final sp = await SharedPreferences.getInstance();
  final raw = sp.getString('nets');
  if (raw != null) {
    nets.value = (jsonDecode(raw) as List)
        .map((e) => Net.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

Future<void> _persistNets() async {
  final sp = await SharedPreferences.getInstance();
  await sp.setString('nets', jsonEncode(nets.value.map((e) => e.toJson()).toList()));
}

Future<void> saveNet(Net n) async {
  nets.value = [n, ...nets.value.where((x) => x.ssid != n.ssid)].take(12).toList();
  await _persistNets();
}

Future<void> removeNet(String ssid) async {
  nets.value = nets.value.where((x) => x.ssid != ssid).toList();
  await _persistNets();
}

String esc(String s) =>
    s.replaceAllMapped(RegExp(r'([\\;,:"])'), (m) => '\\${m[1]}');

String normUrl(String v) {
  v = v.trim();
  if (v.isEmpty) return '';
  return RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(v) ? v : 'https://$v';
}

Net? parseWifi(String t) {
  if (!t.toUpperCase().startsWith('WIFI:')) return null;
  String g(String k) {
    final m = RegExp('(?:^WIFI:|;)$k:((?:\\\\.|[^;])*)', caseSensitive: false).firstMatch(t);
    if (m == null) return '';
    return m[1]!.replaceAllMapped(RegExp(r'\\(.)'), (x) => x[1]!);
  }

  final s = g('S');
  if (s.isEmpty) return null;
  final ty = (g('T').isEmpty ? 'WPA' : g('T')).toUpperCase();
  return Net(s, g('P'), ty == 'NOPASS' ? 'nopass' : (ty == 'WEP' ? 'WEP' : 'WPA'));
}

/* ---------- app ---------- */

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadNets();
  runApp(const QrApp());
}

class QrApp extends StatelessWidget {
  const QrApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF1F4BFF);
    return MaterialApp(
      title: 'QR Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: seed)),
      darkTheme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark)),
      home: const Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('QR Studio')),
      body: SafeArea(
        child: IndexedStack(
          index: _i,
          children: [const CreatePage(), _i == 1 ? const ScanPage() : const SizedBox.shrink()],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _i,
        onDestinationSelected: (i) => setState(() => _i = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.qr_code_2), label: 'Create'),
          NavigationDestination(icon: Icon(Icons.qr_code_scanner), label: 'Scan'),
        ],
      ),
    );
  }
}

void toast(BuildContext c, String m) {
  ScaffoldMessenger.of(c)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m)));
}

/* ---------- create ---------- */

enum Mode { text, link, wifi }

class Ap {
  final String ssid, type;
  const Ap(this.ssid, this.type);
}

class CreatePage extends StatefulWidget {
  const CreatePage({super.key});
  @override
  State<CreatePage> createState() => _CreatePageState();
}

class _CreatePageState extends State<CreatePage> {
  Mode _mode = Mode.text;
  final _text = TextEditingController();
  final _url = TextEditingController();
  final _title = TextEditingController();
  final _ssid = TextEditingController();
  final _pass = TextEditingController();
  String _sec = 'WPA';
  List<Ap> _nearby = [];
  bool _scanning = false;
  final GlobalKey _key = GlobalKey();

  @override
  void dispose() {
    _text.dispose();
    _url.dispose();
    _title.dispose();
    _ssid.dispose();
    _pass.dispose();
    super.dispose();
  }

  String get _data {
    switch (_mode) {
      case Mode.text:
        return _text.text.trim();
      case Mode.link:
        return normUrl(_url.text);
      case Mode.wifi:
        final s = _ssid.text.trim();
        if (s.isEmpty) return '';
        final p = _sec == 'nopass' ? '' : 'P:${esc(_pass.text)};';
        return 'WIFI:T:$_sec;S:${esc(s)};$p;';
    }
  }

  void _pick(String s, String p, String t) {
    setState(() {
      _ssid.text = s;
      _pass.text = p;
      _sec = t;
    });
  }

  Future<void> _scanNearby() async {
    setState(() => _scanning = true);
    try {
      final st = await Permission.locationWhenInUse.request();
      if (!st.isGranted) {
        if (mounted) toast(context, 'Location permission is needed to list nearby networks.');
        return;
      }
      final can = await WiFiScan.instance.canStartScan();
      if (can != CanStartScan.yes) {
        if (mounted) toast(context, 'Can’t scan now. Turn on Wi-Fi and Location, then try again.');
        return;
      }
      await WiFiScan.instance.startScan();
      final cg = await WiFiScan.instance.canGetScannedResults();
      if (cg != CanGetScannedResults.yes) {
        if (mounted) toast(context, 'Couldn’t read scan results.');
        return;
      }
      final res = await WiFiScan.instance.getScannedResults();
      res.sort((a, b) => b.level.compareTo(a.level));
      final seen = <String>{};
      final list = <Ap>[];
      for (final a in res) {
        if (a.ssid.isEmpty || !seen.add(a.ssid)) continue;
        final c = a.capabilities;
        final t = c.contains('WEP')
            ? 'WEP'
            : (c.contains('WPA') || c.contains('SAE') || c.contains('PSK') ? 'WPA' : 'nopass');
        list.add(Ap(a.ssid, t));
      }
      if (mounted) {
        setState(() => _nearby = list);
        if (list.isEmpty) toast(context, 'No networks found.');
      }
    } catch (e) {
      if (mounted) toast(context, 'Wi-Fi scan failed.');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<Uint8List?> _png() async {
    final ctx = _key.currentContext;
    if (ctx == null) return null;
    final b = ctx.findRenderObject() as RenderRepaintBoundary;
    final img = await b.toImage(pixelRatio: 4);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    return bd?.buffer.asUint8List();
  }

  Future<void> _saveToGallery() async {
    final png = await _png();
    if (png == null) return;
    try {
      if (!await Gal.hasAccess()) await Gal.requestAccess();
      await Gal.putImageBytes(png, album: 'QR Studio');
      if (mounted) toast(context, 'Saved to your gallery.');
    } catch (e) {
      if (mounted) toast(context, 'Couldn’t save the image. Check storage permission.');
    }
  }

  Future<void> _share() async {
    final png = await _png();
    if (png == null) return;
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/qr_code.png');
    await f.writeAsBytes(png);
    await Share.shareXFiles([XFile(f.path)]);
  }

  List<Widget> _fields() {
    switch (_mode) {
      case Mode.text:
        return [
          TextField(
            controller: _text,
            minLines: 3,
            maxLines: 6,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Text', border: OutlineInputBorder()),
          ),
        ];
      case Mode.link:
        return [
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Link', hintText: 'example.com', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
                labelText: 'Title (optional)',
                helperText: 'Printed under the code. Not stored inside it.',
                border: OutlineInputBorder()),
          ),
        ];
      case Mode.wifi:
        return [
          FilledButton.tonalIcon(
            onPressed: _scanning ? null : _scanNearby,
            icon: const Icon(Icons.wifi_find),
            label: Text(_scanning ? 'Scanning…' : 'Find nearby networks'),
          ),
          if (_nearby.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Nearby networks', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 4, children: [
              for (final a in _nearby)
                ActionChip(
                  avatar: Icon(a.type == 'nopass' ? Icons.wifi : Icons.wifi_lock, size: 18),
                  label: Text(a.ssid),
                  onPressed: () => _pick(a.ssid, '', a.type),
                ),
            ]),
          ],
          ValueListenableBuilder<List<Net>>(
            valueListenable: nets,
            builder: (c, l, _) => l.isEmpty
                ? const SizedBox.shrink()
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const SizedBox(height: 12),
                    Text('Saved networks', style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 6),
                    Wrap(spacing: 8, runSpacing: 4, children: [
                      for (final n in l)
                        InputChip(
                          label: Text(n.ssid),
                          onPressed: () => _pick(n.ssid, n.pass, n.type),
                          onDeleted: () => removeNet(n.ssid),
                        ),
                    ]),
                  ]),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ssid,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Network name', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          if (_sec != 'nopass') ...[
            TextField(
              controller: _pass,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
          ],
          DropdownButtonFormField<String>(
            value: _sec,
            decoration: const InputDecoration(labelText: 'Security', border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 'WPA', child: Text('WPA/WPA2')),
              DropdownMenuItem(value: 'WEP', child: Text('WEP')),
              DropdownMenuItem(value: 'nopass', child: Text('No password')),
            ],
            onChanged: (v) => setState(() => _sec = v ?? 'WPA'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              final s = _ssid.text.trim();
              if (s.isEmpty) {
                toast(context, 'Enter a network name first.');
                return;
              }
              await saveNet(Net(s, _pass.text, _sec));
              if (mounted) toast(context, 'Saved “$s”.');
            },
            icon: const Icon(Icons.bookmark_add_outlined),
            label: const Text('Save this network'),
          ),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final title = _mode == Mode.link ? _title.text.trim() : '';
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SegmentedButton<Mode>(
          segments: const [
            ButtonSegment(value: Mode.text, label: Text('Text')),
            ButtonSegment(value: Mode.link, label: Text('Link')),
            ButtonSegment(value: Mode.wifi, label: Text('Wi-Fi')),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => setState(() => _mode = s.first),
        ),
        const SizedBox(height: 16),
        ..._fields(),
        const SizedBox(height: 20),
        if (d.isEmpty)
          Container(
            padding: const EdgeInsets.all(32),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant, width: 2),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text('Start typing and your QR code will appear here.', textAlign: TextAlign.center),
          )
        else ...[
          Center(
            child: RepaintBoundary(
              key: _key,
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(20),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  QrImageView(
                    data: d,
                    size: 240,
                    backgroundColor: Colors.white,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                  ),
                  if (title.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: SizedBox(
                        width: 240,
                        child: Text(
                          title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.black, fontSize: 20, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _saveToGallery,
                icon: const Icon(Icons.download),
                label: const Text('Save to gallery'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _share,
                icon: const Icon(Icons.share),
                label: const Text('Share'),
              ),
            ),
          ]),
        ],
      ],
    );
  }
}

/* ---------- scan ---------- */

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final MobileScannerController _c = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
    formats: const [BarcodeFormat.qrCode],
  );
  String? _result;
  Net? _wifi;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  String get _display {
    final w = _wifi;
    if (w == null) return _result ?? '';
    final pw = w.pass.isNotEmpty ? '\nPassword: ${w.pass}' : '';
    return 'Wi-Fi: ${w.ssid}$pw';
  }

  bool get _isLink => RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(_result ?? '');

  void _found(String v) {
    _c.stop();
    HapticFeedback.mediumImpact();
    setState(() {
      _result = v;
      _wifi = parseWifi(v);
    });
  }

  void _onDetect(BarcodeCapture cap) {
    if (_result != null) return;
    for (final b in cap.barcodes) {
      final v = b.rawValue;
      if (v != null && v.isNotEmpty) {
        _found(v);
        break;
      }
    }
  }

  Future<void> _fromImage() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x == null) return;
    final cap = await _c.analyzeImage(x.path);
    String? v;
    if (cap != null) {
      for (final b in cap.barcodes) {
        if (b.rawValue != null && b.rawValue!.isNotEmpty) {
          v = b.rawValue;
          break;
        }
      }
    }
    if (!mounted) return;
    if (v == null) {
      toast(context, 'No QR code found in that image.');
    } else {
      _found(v);
    }
  }

  Future<void> _again() async {
    setState(() {
      _result = null;
      _wifi = null;
    });
    await _c.start();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Stack(fit: StackFit.expand, children: [
              Container(color: Colors.black),
              MobileScanner(
                controller: _c,
                onDetect: _onDetect,
                errorBuilder: (ctx, e, child) => const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Camera unavailable. Allow camera access in Settings, or scan from an image.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
              IgnorePointer(
                child: Center(
                  child: FractionallySizedBox(
                    widthFactor: .7,
                    heightFactor: .7,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: cs.primary, width: 4),
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        if (_result != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Scanned', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 6),
                SelectableText(_display, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      final w = _wifi;
                      final t = w != null ? (w.pass.isNotEmpty ? w.pass : w.ssid) : _result!;
                      await Clipboard.setData(ClipboardData(text: t));
                      if (mounted) toast(context, 'Copied.');
                    },
                    icon: const Icon(Icons.copy),
                    label: Text(_wifi != null ? 'Copy password' : 'Copy'),
                  ),
                  if (_isLink)
                    FilledButton.tonalIcon(
                      onPressed: () => launchUrl(Uri.parse(_result!), mode: LaunchMode.externalApplication),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Open link'),
                    ),
                  if (_wifi != null)
                    FilledButton.tonalIcon(
                      onPressed: () async {
                        await saveNet(_wifi!);
                        if (mounted) toast(context, 'Saved “${_wifi!.ssid}”.');
                      },
                      icon: const Icon(Icons.bookmark_add_outlined),
                      label: const Text('Save Wi-Fi'),
                    ),
                ]),
              ]),
            ),
          ),
        if (_result != null) const SizedBox(height: 12),
        if (_result != null)
          FilledButton.icon(onPressed: _again, icon: const Icon(Icons.refresh), label: const Text('Scan again')),
        if (_result != null) const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _fromImage,
          icon: const Icon(Icons.image_outlined),
          label: const Text('Scan from image'),
        ),
      ],
    );
  }
}
