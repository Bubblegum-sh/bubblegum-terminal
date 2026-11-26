/// Single source of the app version. `scripts/build-app.sh` copies these into Info.plist
/// (CFBundleShortVersionString / CFBundleVersion); the About panel reads them from here.
public enum AppVersion {
    public static let version = "0.1.0"
    public static let build = "1"
}
