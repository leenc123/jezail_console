import 'package:flutter/material.dart';

import '../services/device_store.dart';
import '../services/health_service.dart';

/// Console knobs: which subnets/ports to sweep (M3), how often to poll.
class SettingsPage extends StatefulWidget {
  final DeviceStore store;
  final HealthService health;

  const SettingsPage({super.key, required this.store, required this.health});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _subnetsCtrl = TextEditingController();
  final _portsCtrl = TextEditingController();
  final _pollCtrl = TextEditingController();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final subnets = await widget.store.loadSubnets(const []);
    final ports = await widget.store.loadPorts(const [8080]);
    final poll = await widget.store.loadPollSeconds(widget.health.pollSeconds);
    if (!mounted) return;
    setState(() {
      _subnetsCtrl.text = subnets.join(', ');
      _portsCtrl.text = ports.join(', ');
      _pollCtrl.text = poll.toString();
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _subnetsCtrl.dispose();
    _portsCtrl.dispose();
    _pollCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final subnets = _subnetsCtrl.text
        .split(RegExp(r'[,\s]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final ports = _portsCtrl.text
        .split(RegExp(r'[,\s]+'))
        .map((e) => int.tryParse(e.trim()))
        .whereType<int>()
        .where((p) => p > 0 && p < 65536)
        .toSet()
        .toList();
    final poll = int.tryParse(_pollCtrl.text.trim()) ?? widget.health.pollSeconds;
    await widget.store.saveSubnets(subnets);
    await widget.store.savePorts(ports.isEmpty ? [8080] : ports);
    await widget.store.savePollSeconds(poll.clamp(5, 3600));
    widget.health.restart(pollSeconds: poll.clamp(5, 3600));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text('Discovery subnets (used by subnet scan, M3)'),
                const SizedBox(height: 8),
                TextField(
                  controller: _subnetsCtrl,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'e.g. 192.168.1.0/24 (empty = auto-detect local subnet)',
                  ),
                ),
                const SizedBox(height: 16),
                const Text('HTTP ports to probe'),
                const SizedBox(height: 8),
                TextField(
                  controller: _portsCtrl,
                  decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'e.g. 8080, 8081'),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 16),
                const Text('Health check interval (seconds, 5-3600)'),
                const SizedBox(height: 8),
                TextField(
                  controller: _pollCtrl,
                  decoration: const InputDecoration(border: OutlineInputBorder(), hintText: '30'),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save), label: const Text('Save')),
                const SizedBox(height: 16),
                const Text(
                  'Discovery UDP port on devices is fixed at 8090 for v1. '
                  'Devices answer broadcasts with a jezail-hello JSON payload.',
                ),
              ],
            ),
    );
  }
}
