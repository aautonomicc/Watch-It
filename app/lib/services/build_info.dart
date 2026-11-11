/// What this binary was built as. Test builds published as GitHub
/// prereleases are cut from main WITHOUT a version bump, so Settings →
/// About still names the last release; the build script
/// (scripts/build_appimage.sh with WATCHIT_PRERELEASE set) passes these
/// defines so a test build can say exactly what it is. All empty on a
/// normal release or dev build.
class BuildInfo {
  const BuildInfo({
    this.prerelease = '',
    this.baseVersion = '',
    this.commit = '',
    this.built = '',
  });

  static const current = BuildInfo(
    prerelease: String.fromEnvironment('WATCHIT_PRERELEASE'),
    baseVersion: String.fromEnvironment('WATCHIT_BASE_VERSION'),
    commit: String.fromEnvironment('WATCHIT_COMMIT'),
    built: String.fromEnvironment('WATCHIT_BUILT'),
  );

  /// The prerelease's own name, e.g. `v0.1.0-alpha.130-test2`.
  final String prerelease;

  /// The released version the pubspec still carries, e.g.
  /// `v0.1.0-alpha.129`.
  final String baseVersion;

  /// Short git commit the build was cut from.
  final String commit;

  /// Build time, e.g. `2026-11-11 14:02 UTC`.
  final String built;

  bool get isPrerelease => prerelease.isNotEmpty;

  /// Everything known about the build, for the bar and bug reports.
  String get details => [
        prerelease,
        if (baseVersion.isNotEmpty) 'on top of $baseVersion',
        if (commit.isNotEmpty) 'commit $commit',
        if (built.isNotEmpty) 'built $built',
      ].join(' · ');
}
