// CMFX sends no usage data anywhere. FMC Companion's Aptabase counts are gone; the calls stay as no-ops, so the
// code taken from it reads the same.
enum Analytics {
    static func start() {}
    static func track(_ name: String, _ props: [String: String] = [:]) {}
}
