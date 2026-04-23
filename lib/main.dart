import 'package:flutter/material.dart';
import 'dart:io';

String detectFlatpakType(String id) {
  if (id.contains(".GL.") || id.contains(".Locale") || id.contains(".Debug")) {
    return "Extension";
  }
  if (id.contains("Platform") || id.contains("Sdk")) {
    return "Runtime";
  }
  return "App";

}

String flatpakFamily(String id) {
  final parts = id.split('.');
  if (parts.length >= 3) {
    return '${parts[0]}.${parts[1]}.${parts[2]}';
  }
  return id;
}

void main() {
  runApp(const UpdateAnalyzerApp());
}

class UpdateAnalyzerApp extends StatelessWidget {
  const UpdateAnalyzerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Local Update Analyzer',
      home: const UpdateAnalyzerHome(),
    );
  }
}

class UpdateAnalyzerHome extends StatefulWidget {
  const UpdateAnalyzerHome({super.key});

 @override
  State<UpdateAnalyzerHome> createState() => _UpdateAnalyzerHomeState();

} 

class _UpdateAnalyzerHomeState extends State<UpdateAnalyzerHome> {
 List<FamilySummary> familySummary = [];
 List<UpdateResult> results = [];
  Set<String> installedPkgs = {};
  bool analysisDone = false;

  Future<String> runCommand(String cmd, List<String> args) async {
    final result = await Process.run(cmd, args);
    return result.stdout.toString();
  }

  Future<String> detectFlatpakScope(String id) async {
    final info = await Process.run("flatpak", ["info", id]);
    final out = info.stdout.toString();

    final match = RegExp(r"Installation:\s+(\w+)").firstMatch(out);
    if (match != null) {
      return match.group(1)!.toLowerCase() == "system" ? "System" : "User";
  }

  return "System"; // safe fallback
}
// Detect phased updates using apt full-upgrade -s simulation
bool isDeferredBySimulation(String pkg, String simulationText) {
  // 1) Ubuntu-style: "The following upgrades have been deferred due to phasing:"
  final blockMatch = RegExp(
  r'The following upgrades have been deferred due to phasing:\s+((?:\s+.*\n)+)',
  multiLine: true,
  ).firstMatch(simulationText);


  if (blockMatch != null) {
    final block = blockMatch.group(1)!;
    if (RegExp(r'\b' + RegExp.escape(pkg) + r'\b').hasMatch(block)) {
      return true;
    }
  }

  // 2) Debian-style: "pkgname [held back: phased update]"
  final heldBackPattern = RegExp(
    r'\b' + RegExp.escape(pkg) + r'\b.*held back: phased update',
    multiLine: true,
  );
  if (heldBackPattern.hasMatch(simulationText)) {
    return true;
  }

  return false;
}

  // Normalize package names (strip architecture suffixes)
  String normalize(String pkg) {
    return pkg.replaceAll(RegExp(r':amd64|:i386|:arm64|:armhf'), '');
  }

  // Infer software family from package name
  String inferFamily(String pkg) {
    if (pkg.contains('-locale-')) {
      return pkg.split('-locale-')[0];
    }
    if (pkg.contains('-l10n-')) {
      return pkg.split('-l10n-')[0];
    }
    if (pkg.contains('-lang')) {
      return pkg.split('-lang')[0];
    }
    if (pkg.startsWith('linux-')) {
      return 'linux';
    }
    if (pkg.endsWith('-common') ||
        pkg.endsWith('-data') ||
        pkg.endsWith('-dev')) {
      return pkg.replaceAll(RegExp(r'-(common|data|dev)$'), '');
    }
    return pkg;
  }

  // Check if the software family is actually installed
  bool familyInstalled(String family) {
    final executables = {
      'firefox': '/usr/bin/firefox',
      'thunderbird': '/usr/bin/thunderbird',
      'stacer': '/usr/bin/stacer',
      'linux': '/boot', // kernel always present
    };

    if (executables.containsKey(family)) {
      return FileSystemEntity.typeSync(executables[family]!) !=
          FileSystemEntityType.notFound;
    }

    return installedPkgs.any((p) => p.startsWith(family));
  }

  // Classify APT package type
  String classifyAPT(String pkg) {
    if (pkg.contains('-locale-') || pkg.contains('-l10n-') || pkg.contains('-lang')) {
      return 'Language pack. Main application may NOT be installed.';
    }
    if (pkg.startsWith('linux-libc-dev')) {
      return 'Kernel development library. NOT the kernel itself.';
    }
    if (pkg.startsWith('linux-tools')) {
      return 'Kernel tools. NOT the kernel itself.';
    }
    if (pkg.endsWith('-common') || pkg.endsWith('-data') || pkg.endsWith('-dev')) {
      return 'Meta or transitional package.';
    }
    return 'Application or system component.';
  }

  // Classify Flatpak update
  String classifyFlatpak(String id) {
  final lower = id.toLowerCase();

  // Language packs
  if (lower.contains('locale') || lower.contains('lang') || lower.contains('l10n')) {
    return 'Language pack. Main application may NOT be installed.';
  }

  // Freedesktop platform extensions
  if (lower.contains('codecs') || lower.contains('extra')) {
    return 'Freedesktop platform extension (Flatpak).';
  }

  // GNOME platform
  if (lower.contains('org.gnome.platform')) {
    return 'GNOME runtime platform (Flatpak).';
  }

  // Freedesktop platform
  if (lower.contains('org.freedesktop.platform')) {
    return 'Freedesktop runtime platform (Flatpak).';
  }

  // KDE platform
  if (lower.contains('org.kde.platform')) {
    return 'KDE runtime platform (Flatpak).';
  }

  // Meta / transitional
  if (lower.endsWith('.debug') || lower.endsWith('.dev') || lower.endsWith('.data')) {
    return 'Meta or transitional Flatpak component.';
  }

  // Default
  return 'Flatpak application or system component.';
}

  // -------------------------
  // UNIVERSAL FLATPAK DETECTION
  // -------------------------
  Future<List<UpdateResult>> getUniversalFlatpakUpdates() async {
    List<UpdateResult> results = [];

  // Run flatpak update non-interactively
  final raw = await Process.run(
    'bash',
    ['-c', 'printf "n\n" | /usr/bin/flatpak update'],
  );

  final output = raw.stdout.toString().trim().split('\n');

  // Detect numbered-list format (your system)
  final numbered = RegExp(r'^\s*\d+\.\s+');

  for (final line in output) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;

    // Match numbered list entries
    if (numbered.hasMatch(trimmed)) {
      // Remove "1." prefix
      final cleaned = trimmed.replaceFirst(numbered, '').trim();

      // Split into fields
      final parts = cleaned.split(RegExp(r'\s+'));
      if (parts.length < 4) continue;

      final id = parts[0];
      final branch = parts[1];
      final op = parts[2];
      final remote = parts[3];

      final flatpakLabel = "$id $branch $op $remote";
      final classification = classifyFlatpak(id);
      final type = detectFlatpakType(id);
      final scope = await detectFlatpakScope(id);
      final typeScope = "$type/$scope";

      results.add(UpdateResult(
        packageName: id,
        family: flatpakFamily(id),
        installed: true,
        classification: classification,
        source: "flatpak",
        aptGroupLabel: null,
        flatpakLabel: flatpakLabel,
        typeScope: typeScope,
        deferred: false,
      ));
    }
  }

  return results;
}


  // -------------------------
  // MAIN ANALYZER
  // -------------------------
  Future<void> analyzeUpdates() async {
    // -------------------------
    // APT INSTALLED PACKAGES
    // -------------------------
    final installed = await Process.run('dpkg', ['-l']);
    final installedList = installed.stdout.toString().split('\n');

    installedPkgs.clear();
    for (var line in installedList) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length > 1) {
        installedPkgs.add(normalize(parts[1].trim()));
      }
    }

    // NEW LIST FOR LOCAL .DEB PACKAGES
    List<UpdateResult> localDebs = [];

    // -------------------------
    // DETECT MANUALLY INSTALLED .DEB PACKAGES
    // -------------------------
    final aptInstalled = await Process.run('apt', ['list', '--installed']);
    final aptInstalledLines = aptInstalled.stdout.toString().split('\n');

    for (var line in aptInstalledLines) {
      line = line.trim();
      if (line.isEmpty) continue;
      if (!line.contains('[installed,local]')) continue;

     // Format: pkgname/version arch [installed,local]
      final parts = line.split(RegExp(r'\s+'));
      if (parts.isEmpty) continue;

      final namePart = parts[0]; // pkgname/version
      final pkgName = namePart.split('/').first;
      final normalized = normalize(pkgName);

      final family = inferFamily(normalized);

      localDebs.add(UpdateResult(
        packageName: normalized,
        family: family,
        installed: true,
        classification: "Manually installed .deb package (not tracked by APT)",
        source: "local-deb",
        aptGroupLabel: null,
        flatpakLabel: null,
        typeScope: "N/A",
        deferred: false,
      ));
   }

    List<UpdateResult> temp = [];
    final simulation = await Process.run('apt', ['full-upgrade', '-s']);
    final simulationText = simulation.stdout.toString();

    // -------------------------
    // APT UPGRADABLE PACKAGES
    // -------------------------

    final upgradable = await Process.run('apt', ['list', '--upgradable']);
    final upgradableList = upgradable.stdout.toString().split('\n');

    for (var line in upgradableList) {
      line = line.trim();
      if (line.isEmpty) continue;
      if (!line.contains('/')) continue; // skip header or noise

      // Typical line:
      // pkgname/ubuntu-version version arch [upgradable from: oldversion]
      final parts = line.split(RegExp(r'\s+'));
      if (parts.isEmpty) continue;

      // First token: "pkgname/whatever"
      final namePart = parts[0];
      final pkgName = namePart.split('/').first;
      final normalized = normalize(pkgName);

      final family = inferFamily(normalized);
      final installedBool = familyInstalled(family);
      final classification = classifyAPT(normalized);

      // Build a simple APT group label: "oldversion newversion" if present
      String? aptLabel;
      final match = RegExp(r'''\[upgradable from: ([^\]]+)\]''').firstMatch(line);

      if (match != null) {
        final fromVer = match.group(1)!.trim();
        // new version is usually the second field
        final newVer = parts.length > 1 ? parts[1].trim() : '?';
        aptLabel = '$fromVer $newVer';
      }

      // For now: no phased logic → not deferred
      final bool deferred = isDeferredBySimulation(normalized, simulationText);

      temp.add(UpdateResult(
        packageName: normalized,
        family: family,
        installed: installedBool,
        classification: classification,
        source: "apt",
        aptGroupLabel: aptLabel,
        flatpakLabel: null,
        typeScope: "App/System",
        deferred: deferred,
      ));
    } 
    // -------------------------
    // UNIVERSAL FLATPAK UPDATES
    // -------------------------
    final flatpakUpdates = await getUniversalFlatpakUpdates();

    for (var u in flatpakUpdates) {
      temp.add(u);

  }

    // -------------------------
    // ADD LOCAL .DEB INSTALLS
    // -------------------------
    for (var d in localDebs) {
     temp.add(d);
    }

// -------------------------
// SUMMARY BY FAMILY
// -------------------------
Map<String, List<UpdateResult>> grouped = {};

for (var r in temp) {
  // EXCLUDE manually installed .deb packages from the summary
  if (r.source == "local-deb") continue;

  grouped.putIfAbsent(r.family, () => []);
  grouped[r.family]!.add(r);
}

List<FamilySummary> summary = [];

grouped.forEach((family, items) {
  List<String> installedVersions = [];
  List<String> availableVersions = [];

  for (var item in items) {
    if (item.source == "apt" && item.aptGroupLabel != null) {
      final parts = item.aptGroupLabel!.split(' ');
      if (parts.length >= 2) {
        installedVersions.add(parts[0]);
        availableVersions.add(parts[1]);
      }
    }

    if (item.source == "flatpak" && item.flatpakLabel != null) {
      final parts = item.flatpakLabel!.split(' ');
      if (parts.length >= 4) {
        installedVersions.add(parts[1]);
        availableVersions.add(parts[1]);
      }
    }
  }

  String fromV = installedVersions.isNotEmpty ? installedVersions.first : "?";
  String toV = availableVersions.isNotEmpty ? availableVersions.last : "?";

  summary.add(FamilySummary(
    family: family,
    count: items.length,
    fromVersion: fromV,
    toVersion: toV,
  ));
});

  summary.sort((a, b) => a.family.compareTo(b.family));
 

    setState(() {
      results = temp;
      familySummary = summary;
      analysisDone = true;
    });
  }

  @override
  Widget build(BuildContext context) {

        // -------------------------
        // SHOW MANUALLY INSTALLED .DEB PACKAGES
        // -------------------------
        final localDebList = results.where((r) => r.source == "local-deb").toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Local Update Analyzer')),
      body: Column(
        children: [
          ElevatedButton(
            onPressed: analyzeUpdates,
            child: const Text('Analyze Updates'),
          ),

  if (analysisDone)
  Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Update Summary (by Family)",
            textAlign: TextAlign.left,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),

          for (var s in familySummary)
            Text(
              "${s.family} — ${s.count} update(s)",
              style: const TextStyle(fontSize: 14),
            ),

      
        if (localDebList.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            "Manually Installed .deb Packages (Not Tracked by APT)",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),

          for (var d in localDebList)
            Text(
              "${d.packageName} (${d.family})",
              style: const TextStyle(fontSize: 14),
          ),
        ],
          const SizedBox(height: 16),
          const SizedBox(height: 8),

          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                "Detailed Updates",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                textAlign: TextAlign.left,
              ),
            ),
          ),
        ],
      ),
    ),
  ),     
    
      Expanded(
            child: ListView.builder(
              itemCount: results.length,
              itemBuilder: (context, index) {
                final r = results[index];
                return ListTile(
                  leading: Icon(
                    r.source == "local-deb"
                        ? Icons.help_outline
                        : r.deferred
                             ? Icons.access_time
                             : r.installed
                                   ? Icons.check_circle
                                   : Icons.cancel,
                    color: r.source == "local-deb"
                        ? Colors.grey
                        : r.deferred
                            ? Colors.amber
                            : r.installed
                                ? Colors.green
                                : Colors.red,
               
                  ),
                  title: Text('${r.packageName}  →  Family: ${r.family}'),
                  subtitle: Text(
                     '${r.classification}\n'
                     '${r.source == "apt" && r.aptGroupLabel != null ? "APT group label: ${r.aptGroupLabel}\n" : ""}'
                     '${r.source == "flatpak" && r.flatpakLabel != null ? "Flatpak label: ${r.flatpakLabel}\n" : ""}'
                     'Type/Scope: ${r.typeScope}\n'
                     '${r.source == "local-deb"
                         ? "Installed → Not tracked by APT – user must manually check for an update"
                         : r.deferred
                             ? "Installed → Update deferred (phased rollout)"
                             : r.installed
                                 ? "Installed → Update is relevant"
                                 : "NOT installed → Update NOT needed"}',
                  ),
                );
              },
            ),
          ),

          if (analysisDone)
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: Text(
                "Note: Your GUI software updater may or may not show every update listed here. "
                "Different Linux distributions only display updates for software they track or manage directly. "
                "If you want to confirm visibility, check your GUI updater manually.",
                style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }
}

class UpdateResult {
  final String packageName;
  final String family;
  final bool installed;
  final String classification;

  final String source; // "apt" or "flatpak"
  final String? aptGroupLabel;
  final String? flatpakLabel;
  final String typeScope; //e.g. "App/System"
  
  final bool deferred; // NEW — phased update indicator

  UpdateResult({
    required this.packageName,
    required this.family,
    required this.installed,
    required this.classification,
    required this.source,
    this.aptGroupLabel,
    this.flatpakLabel,
    required this.typeScope,
    required this.deferred, // NEW
  });
}
class FamilySummary {
  final String family;
  final int count;
  final String fromVersion;
  final String toVersion;

  FamilySummary({
    required this.family,
    required this.count,
    required this.fromVersion,
    required this.toVersion,
  });
}

