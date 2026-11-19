import 'package:url_launcher/url_launcher.dart';

import '../models/device.dart';

/// Opens jezail web surfaces in the system browser.
/// The heavy lifting stays in the existing web UI; the console
/// only needs to deep-link into it.
class AppLinks {
  static Future<bool> _open(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openWebUi(JezailDevice d) => _open(d.webUiUri);
  static Future<bool> openTerminal(JezailDevice d) => _open(d.terminalUri);
  static Future<bool> openMirror(JezailDevice d) => _open(d.mirrorUri);
  static Future<bool> openRefrida(JezailDevice d) => _open(d.refridaUri);
  static Future<bool> openSwagger(JezailDevice d) => _open(d.swaggerUri);
}
