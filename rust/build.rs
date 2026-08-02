fn main() {
    cfg_aliases::cfg_aliases! {
        wasm: { all(target_family = "wasm", target_os = "unknown") },
        native: { not(wasm) }
    }
}