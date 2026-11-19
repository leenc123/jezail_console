/// A jezail device on the LAN, either auto-discovered or added manually.
class JezailDevice {
  /// Stable id, preferably ANDROID_ID reported by the device.
  /// Mutable on purpose: HTTP-only probes (/api/device carries no androidId)
  /// start out empty and adopt the stable id when a broadcast reply for the
  /// same endpoint arrives. See [updateFromDiscovery].
  String id;
  String host;
  int port;
  String name;
  String manufacturer;
  String model;
  String androidVersion;
  int sdk;
  bool auth;
  bool root;
  String appVersion;

  /// Where this entry came from: 'broadcast', 'scan' or 'manual'.
  String source;

  /// User-assigned display name / notes.
  String? alias;

  // ---- live health state (not persisted, except lastSeen) ----
  bool online;
  DateTime? lastSeen;
  DateTime? lastCheck;
  String? lastError;

  JezailDevice({
    required this.id,
    required this.host,
    required this.port,
    this.name = '',
    this.manufacturer = '',
    this.model = '',
    this.androidVersion = '',
    this.sdk = 0,
    this.auth = false,
    this.root = false,
    this.appVersion = '',
    this.source = 'manual',
    this.alias,
    this.online = false,
    this.lastSeen,
    this.lastCheck,
    this.lastError,
  });

  /// Identity key used for dedup: stable id when known, else host:port.
  String get key => id.isNotEmpty ? id : '$host:$port';

  String get displayName =>
      (alias != null && alias!.isNotEmpty) ? alias! : (name.isNotEmpty ? name : '$host:$port');

  Uri get baseUri => Uri(scheme: 'http', host: host, port: port);

  Uri get webUiUri => baseUri.replace(path: '/');
  Uri get terminalUri => baseUri.replace(path: '/terminal');
  Uri get mirrorUri => baseUri.replace(path: '/mirror');
  Uri get refridaUri => baseUri.replace(path: '/refrida');
  Uri get swaggerUri => baseUri.replace(path: '/api/swagger');

  factory JezailDevice.fromDiscovery(Map<String, dynamic> json, String host, int port) {
    String s(Object? v) => v?.toString() ?? '';
    int i(Object? v) => v is int ? v : int.tryParse(v?.toString() ?? '') ?? 0;
    bool b(Object? v) => v == true || v?.toString().toLowerCase() == 'true';
    return JezailDevice(
      id: s(json['id']),
      host: host,
      port: (json['http'] is int) ? json['http'] as int : port,
      name: s(json['name']),
      manufacturer: s(json['manufacturer']),
      model: s(json['model']),
      androidVersion: s(json['android']),
      sdk: i(json['sdk']),
      auth: b(json['auth']),
      root: b(json['root']),
      appVersion: s(json['app']),
      source: 'broadcast',
      online: true,
      lastSeen: DateTime.now(),
    );
  }

  /// Enrich mutable fields from a fresh discovery payload (keeps alias).
  void updateFromDiscovery(JezailDevice other) {
    // Adopt the stable id when we only knew host:port (scan/manual path).
    // Never clobber a known id with an empty one.
    if (other.id.isNotEmpty) id = other.id;
    host = other.host;
    port = other.port;
    if (other.name.isNotEmpty) name = other.name;
    if (other.manufacturer.isNotEmpty) manufacturer = other.manufacturer;
    if (other.model.isNotEmpty) model = other.model;
    if (other.androidVersion.isNotEmpty) androidVersion = other.androidVersion;
    if (other.sdk != 0) sdk = other.sdk;
    auth = other.auth;
    root = other.root;
    if (other.appVersion.isNotEmpty) appVersion = other.appVersion;
    source = other.source;
    online = true;
    lastSeen = DateTime.now();
    lastError = null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'host': host,
        'port': port,
        'name': name,
        'manufacturer': manufacturer,
        'model': model,
        'androidVersion': androidVersion,
        'sdk': sdk,
        'auth': auth,
        'root': root,
        'appVersion': appVersion,
        'source': source,
        'alias': alias,
        'lastSeen': lastSeen?.toIso8601String(),
      };

  factory JezailDevice.fromJson(Map<String, dynamic> json) {
    String s(Object? v) => v?.toString() ?? '';
    DateTime? dt(Object? v) => v == null ? null : DateTime.tryParse(v.toString());
    return JezailDevice(
      id: s(json['id']),
      host: s(json['host']),
      port: (json['port'] is int) ? json['port'] as int : 8080,
      name: s(json['name']),
      manufacturer: s(json['manufacturer']),
      model: s(json['model']),
      androidVersion: s(json['androidVersion']),
      sdk: (json['sdk'] is int) ? json['sdk'] as int : 0,
      auth: json['auth'] == true,
      root: json['root'] == true,
      appVersion: s(json['appVersion']),
      source: s(json['source']).isEmpty ? 'manual' : s(json['source']),
      alias: json['alias']?.toString(),
      lastSeen: dt(json['lastSeen']),
    );
  }
}
