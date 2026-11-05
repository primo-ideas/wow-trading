fn main() {
    // sqlx::migrate! embeds the SQL at compile time: rebuild when a migration changes.
    println!("cargo:rerun-if-changed=migrations");
}
