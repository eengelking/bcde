import Foundation

/// Column layout shared by the SQLite table and the CSV/XLSX exports.
enum Schema {
    /// Fields extracted from the card itself, in export order.
    static let fields = [
        "full_name", "prefix", "first_name", "middle_name", "last_name", "suffix", "credentials",
        "job_title", "department", "company",
        "email", "email_alt", "website",
        "phone_work", "phone_ext", "phone_mobile", "phone_fax", "phone_other",
        "street", "city", "region", "postal_code", "country", "address_full",
        "linkedin", "twitter", "other_social", "language",
    ]

    /// Every column of the `cards` table (except the rowid), in export order.
    static let columns = ["card_key", "source_files", "sides"] + fields + [
        "confidence", "needs_review", "review_reasons",
        "front_text", "back_text", "error", "content_hash", "ocr_ms", "processed_at",
    ]

    static let integerColumns: Set<String> = ["sides", "needs_review", "ocr_ms"]
    static let realColumns: Set<String> = ["confidence"]
}

/// One row of the `cards` table. Values are kept as strings; the database layer binds by column type.
struct CardRecord {
    var values: [String: String] = [:]

    subscript(_ key: String) -> String? {
        get { values[key] }
        set { values[key] = newValue }
    }
}
