// broken-rust - a deliberate type error so the gate build (cargo build) fails.
fn main() {
    // Cannot add an integer to a &str: type mismatch, does not compile.
    let total: i64 = 1 + "two";
    println!("{total}");
}
