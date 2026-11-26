/// Single source of the app version. `scripts/build-app.sh` copies these into Info.plist
/// (CFBundleShortVersionString / CFBundleVersion); the About panel reads them from here.
public enum AppVersion {
    public static let version = "0.1.0"
    public static let build = "1"
    /// Also in Info.plist as NSHumanReadableCopyright. Licensed under MIT (see LICENSE).
    public static let copyright = "Copyright © 2026 Eugene Safronov. MIT License."
}
