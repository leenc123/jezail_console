import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/device.dart';
import '../services/app_links.dart';
import '../services/device_store.dart';
import '../services/discovery_service.dart';
import '../services/health_service.dart';
import 'settings_page.dart';

/// Device inventory: auto-discovered + manually added boxes,
/// live status, quick links into the device web UI.
class HomePage extends StatefulWidget {
  final DeviceStore store;
  final DiscoveryService discovery;
  final HealthService health;

  const HomePage({
    super.key,
    required this.store,
    required this.discovery,
    required this.health,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _query = '';
  bool _discovering = false;
  bool _scanning = false;
  double _scanProgress = 0;
  String _statusLine = 'Idle. Press scan to discover devices on the LAN.';

  @override
  void initState() {
    super.initState();
    widget.health.addListener(_onHealth);
    widget.health.start();
  }

  @override
  void dispose() {
    widget.health.removeListener(_onHealth);
    widget.health.stop();
    super.dispose();
  }

  void _onHealth() {
    if (mounted) setState(() {});
  }

  List<JezailDevice> get _filtered {
    final all = widget.store.devices;
    if (_query.isEmpty) return all;
    final q = _query.toLowerCase();
    return all.where((d) {
      return d.displayName.toLowerCase().contains(q) ||
          d.host.contains(q) ||
          d.model.toLowerCase().contains(q) ||
          (d.alias ?? '').toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _discover() async {
    setState(() {
      _discovering = true;
      _statusLine = 'Broadcasting discovery probe…';
    });
    try {
      final found = await widget.discovery.broadcastDiscover();
      var added = 0;
      for (final dev in found) {
        final isNew = widget.store.byKey(dev.key) == null;
        widget.store.upsert(dev);
        if (isNew) added++;
      }
      await widget.store.save();
      setState(() {
        _statusLine = found.isEmpty
            ? 'No devices answered. Try subnet scan or manual add.'
            : 'Found ${found.length} device(s), $added new.';
      });
    } catch (e) {
      setState(() => _statusLine = 'Discovery failed: $e');
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _scanSubnet() async {
    if (_scanning) {
      widget.discovery.cancelScan();
      return;
    }
    final subnets = await widget.store.loadSubnets([]);
    final ports = await widget.store.loadPorts(const [8080]);
    final targets = subnets.isEmpty ? ['<auto local /24>'] : subnets;
    setState(() {
      _scanning = true;
      _scanProgress = 0;
      _statusLine = 'Scanning ${targets.join(', ')} …';
    });
    try {
      final nets = subnets.isEmpty ? await widget.discovery.localSubnets() : subnets;
      if (nets.isEmpty) {
        setState(() => _statusLine = 'No local subnet found; add one in Settings.');
        return;
      }
      var added = 0;
      var found = 0;
      await for (final prog in widget.discovery.scanSubnets(subnets: nets, ports: ports)) {
        if (!mounted) return;
        setState(() {
          _scanProgress = prog.total == 0 ? 0 : prog.scanned / prog.total;
          if (prog.found != null) {
            final d = prog.found!;
            if (widget.store.byKey(d.key) == null) added++;
            widget.store.upsert(d);
            found++;
          }
          _statusLine = prog.done
              ? (prog.cancelled
                  ? 'Scan cancelled: $found found, $added new.'
                  : 'Scan complete: $found found, $added new.')
              : 'Scanning… ${prog.scanned}/${prog.total} ($found found)';
        });
      }
      await widget.store.save();
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _manualAdd() async {
    final hostCtrl = TextEditingController();
    final portCtrl = TextEditingController(text: '8080');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add device manually'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: hostCtrl, decoration: const InputDecoration(labelText: 'IP address')),
            TextField(
              controller: portCtrl,
              decoration: const InputDecoration(labelText: 'HTTP port'),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final host = hostCtrl.text.trim();
    final port = int.tryParse(portCtrl.text.trim()) ?? 8080;
    if (host.isEmpty) return;
    setState(() => _statusLine = 'Probing $host:$port…');
    final dev = await widget.discovery.probeHost(host, port);
    if (!mounted) return;
    if (dev == null) {
      setState(() => _statusLine = '$host:$port did not answer like a jezail device.');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$host:$port is not reachable as jezail')),
      );
      return;
    }
    dev.source = 'manual';
    widget.store.upsert(dev);
    await widget.store.save();
    setState(() => _statusLine = 'Added ${dev.displayName}.');
  }

  void _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SettingsPage(store: widget.store, health: widget.health)),
    );
    if (mounted) setState(() {});
  }

  Future<void> _refreshOne(JezailDevice dev) async {
    await widget.health.check(dev);
    await widget.store.save();
    if (mounted) setState(() {});
  }

  Future<void> _clearOffline() async {
    final offline = widget.store.devices.where((d) => !d.online).toList();
    if (offline.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No offline devices to clear.')),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear offline devices?'),
        content: Text('Remove ${offline.length} offline device(s) from the inventory?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true) return;
    for (final d in offline) {
      widget.store.remove(d.key);
    }
    await widget.store.save();
    if (mounted) setState(() {});
  }

  void _showDetail(JezailDevice dev) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => _DeviceDetailSheet(
        dev: dev,
        onRename: (alias) async {
          widget.store.setAlias(dev.key, alias);
          await widget.store.save();
          if (mounted) setState(() {});
        },
        onDelete: () async {
          widget.store.remove(dev.key);
          await widget.store.save();
          if (mounted) setState(() {});
        },
        onRefresh: () => _refreshOne(dev),
      ),
    ).then((_) => mounted ? setState(() {}) : null);
  }

  @override
  Widget build(BuildContext context) {
    final devices = _filtered;
    final online = widget.store.devices.where((d) => d.online).length;
    return Scaffold(
      appBar: AppBar(
        title: Text('Jezail Console (${widget.store.devices.length} devices, $online online)'),
        actions: [
          IconButton(
            tooltip: 'Refresh health',
            icon: const Icon(Icons.refresh),
            onPressed: () => widget.health.refreshAll(),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) {
              if (v == 'clear-offline') _clearOffline();
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(value: 'clear-offline', child: Text('Clear offline devices')),
            ],
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search name / IP / model…',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _discovering ? null : _discover,
                  icon: _discovering
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.radar),
                  label: const Text('Scan LAN'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _scanSubnet,
                  icon: _scanning
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.travel_explore),
                  label: Text(_scanning ? 'Stop' : 'Subnet'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _manualAdd,
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Align(alignment: Alignment.centerLeft, child: Text(_statusLine)),
          ),
          if (_scanning)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: LinearProgressIndicator(value: _scanProgress == 0 ? null : _scanProgress),
            ),
          const Divider(height: 1),
          Expanded(
            child: devices.isEmpty
                ? const Center(child: Text('No devices yet. Scan the LAN or add one manually.'))
                : ListView.builder(
                    itemCount: devices.length,
                    itemBuilder: (ctx, i) => _DeviceTile(
                      dev: devices[i],
                      onTap: () => _showDetail(devices[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final JezailDevice dev;
  final VoidCallback onTap;

  const _DeviceTile({required this.dev, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final dot = dev.online ? Colors.green : Colors.grey;
    return ListTile(
      leading: Icon(Icons.smartphone, color: dot),
      title: Text(dev.displayName),
      subtitle: Text(
        '${dev.host}:${dev.port}'
        '${dev.model.isNotEmpty ? ' · ${dev.model}' : ''}'
        '${dev.androidVersion.isNotEmpty ? ' · Android ${dev.androidVersion}' : ''}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dev.root)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Chip(label: Text('root', style: TextStyle(fontSize: 11)), visualDensity: VisualDensity.compact),
            ),
          if (dev.auth)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Chip(label: Text('auth', style: TextStyle(fontSize: 11)), visualDensity: VisualDensity.compact),
            ),
          if (!dev.online)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Chip(label: Text('offline', style: TextStyle(fontSize: 11)), visualDensity: VisualDensity.compact),
            ),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _DeviceDetailSheet extends StatefulWidget {
  final JezailDevice dev;
  final Future<void> Function(String alias) onRename;
  final Future<void> Function() onDelete;
  final Future<void> Function() onRefresh;

  const _DeviceDetailSheet({
    required this.dev,
    required this.onRename,
    required this.onDelete,
    required this.onRefresh,
  });

  @override
  State<_DeviceDetailSheet> createState() => _DeviceDetailSheetState();
}

class _DeviceDetailSheetState extends State<_DeviceDetailSheet> {
  late final TextEditingController _aliasCtrl;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _aliasCtrl = TextEditingController(text: widget.dev.alias ?? '');
  }

  @override
  void dispose() {
    _aliasCtrl.dispose();
    super.dispose();
  }

  Future<void> _open(Future<bool> Function() action, String label) async {
    final ok = await action();
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to open $label.')),
      );
    }
  }

  Future<void> _copyAddress(JezailDevice d) async {
    await Clipboard.setData(ClipboardData(text: '${d.host}:${d.port}'));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied ${d.host}:${d.port}')),
    );
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.dev;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(d.displayName, style: Theme.of(context).textTheme.headlineSmall)),
              IconButton(
                tooltip: 'Re-probe this device',
                onPressed: _refreshing ? null : _refresh,
                icon: _refreshing
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: 'Copy address',
                onPressed: () => _copyAddress(d),
                icon: const Icon(Icons.copy),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('${d.host}:${d.port} · ${d.manufacturer} ${d.model} · Android ${d.androidVersion} (SDK ${d.sdk})'),
          Text('App ${d.appVersion} · Source: ${d.source} · Last seen: ${d.lastSeen?.toLocal().toString().split('.').first ?? '-'}'),
          if (d.lastError != null && d.lastError!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Last error: ${d.lastError}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
                onPressed: () => _open(() => AppLinks.openWebUi(d), 'Web UI'),
                icon: const Icon(Icons.dashboard),
                label: const Text('Web UI')),
            OutlinedButton.icon(
                onPressed: () => _open(() => AppLinks.openTerminal(d), 'Terminal'),
                icon: const Icon(Icons.terminal),
                label: const Text('Terminal')),
            OutlinedButton.icon(
                onPressed: () => _open(() => AppLinks.openMirror(d), 'Mirror'),
                icon: const Icon(Icons.screenshot_monitor),
                label: const Text('Mirror')),
            OutlinedButton.icon(
                onPressed: () => _open(() => AppLinks.openRefrida(d), 'Refrida'),
                icon: const Icon(Icons.bug_report),
                label: const Text('Refrida')),
            OutlinedButton.icon(
                onPressed: () => _open(() => AppLinks.openSwagger(d), 'API docs'),
                icon: const Icon(Icons.api),
                label: const Text('API docs')),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _aliasCtrl,
            decoration: const InputDecoration(labelText: 'Alias / notes', border: OutlineInputBorder(), isDense: true),
            onSubmitted: (v) async {
              await widget.onRename(v.trim());
              if (context.mounted) Navigator.pop(context);
            },
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton.icon(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Remove device?'),
                      content: Text('Remove ${d.displayName} from the inventory?'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
                      ],
                    ),
                  );
                  if (ok == true) {
                    await widget.onDelete();
                    if (context.mounted) Navigator.pop(context);
                  }
                },
                icon: const Icon(Icons.delete, color: Colors.red),
                label: const Text('Remove', style: TextStyle(color: Colors.red)),
              ),
              FilledButton(
                onPressed: () async {
                  await widget.onRename(_aliasCtrl.text.trim());
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('Save alias'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
