fn main() {
    if clusteryourcodex_desktop_host::run().is_err() {
        // Do not print platform paths, command lines, or inner errors from a
        // failed native-host bootstrap. The fixed code is safe for installer
        // diagnostics and process supervisors.
        eprintln!("ClusterYourCodex desktop host failed: desktop_host_unavailable");
        std::process::exit(1);
    }
}
