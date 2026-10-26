import Foundation

/// Word lists that drive the field heuristics. All entries are lowercase.
enum Lexicon {
    /// Words that on their own mark a line as a job title.
    static let titleStrong: Set<String> = [
        "president", "vp", "svp", "evp", "avp", "ceo", "cfo", "coo", "cto", "cio", "cmo", "cso", "cro", "cpo",
        "chro", "ciso", "chief", "officer", "director", "manager", "mgr", "head", "lead", "leader", "founder",
        "co-founder", "cofounder", "owner", "partner", "principal", "engineer", "developer", "architect",
        "designer", "consultant", "specialist", "analyst", "advisor", "adviser", "representative", "rep",
        "agent", "broker", "realtor", "realtor®", "attorney", "lawyer", "counsel", "paralegal", "accountant",
        "controller", "comptroller", "treasurer", "secretary", "chairman", "chairwoman", "chairperson", "chair",
        "coordinator", "administrator", "supervisor", "superintendent", "technician", "scientist",
        "researcher", "professor", "lecturer", "instructor", "teacher", "dean", "provost", "physician",
        "surgeon", "dentist", "nurse", "pharmacist", "therapist", "counselor", "editor", "writer",
        "producer", "photographer", "recruiter", "strategist", "planner", "buyer", "trainer", "coach",
        "executive", "associate", "assistant", "intern", "fellow", "underwriter", "banker", "lender",
        "evangelist", "ambassador", "liaison", "inspector", "appraiser", "estimator",
        "foreman", "pastor", "minister", "chef", "steward", "clerk", "receptionist",
        "programmer", "directeur", "gerente", "geschäftsführer", "leiter", "direttore",
    ]

    /// Words common in titles but not decisive alone.
    static let titleWeak: Set<String> = [
        "senior", "sr", "sr.", "junior", "jr", "vice", "managing", "general", "regional", "national",
        "global", "sales", "marketing", "business", "development", "operations", "account", "accounts",
        "project", "product", "program", "customer", "success", "technical", "it", "hr", "finance",
        "financial", "engineering", "research", "strategy", "strategic", "client", "relations", "public",
        "communications", "human", "resources", "legal", "compliance", "risk", "data", "software",
        "executive", "board", "member", "staff", "team", "district", "area", "territory", "key", "new",
        "talent", "acquisition", "procurement", "supply", "chain", "quality", "creative", "art",
        "digital", "brand", "content", "medical", "clinical", "loan", "mortgage", "investment",
        "wealth", "portfolio", "property", "real", "estate", "insurance", "of", "&", "and",
    ]

    /// Legal-form suffixes; strong company signal when they end a line.
    static let legalSuffixes: Set<String> = [
        "inc", "incorporated", "llc", "l.l.c", "llp", "lp", "ltd", "limited", "corp", "corporation",
        "plc", "gmbh", "ag", "kg", "sa", "s.a", "sas", "sarl", "srl", "s.r.l", "spa", "s.p.a", "bv", "b.v",
        "nv", "n.v", "pty", "pte", "kk", "co", "company", "pc", "p.c", "pllc", "lpa", "oy", "ab", "as",
        "aps", "s.l", "sl", "sca", "kft", "zrt", "s.a.s", "ltda", "cia",
    ]

    /// Words that suggest an organization name.
    static let orgWords: Set<String> = [
        "group", "holdings", "partners", "associates", "consulting", "solutions", "technologies",
        "technology", "systems", "enterprises", "industries", "international", "labs", "laboratories",
        "studio", "studios", "agency", "bank", "university", "college", "institute", "foundation",
        "hospital", "clinic", "realty", "capital", "ventures", "media", "services", "networks",
        "logistics", "construction", "insurance", "law", "firm", "offices", "trust", "society",
        "association", "council", "ministry", "department", "school", "academy", "center", "centre",
        "corporate", "global", "worldwide", "america", "americas", "usa", "bancorp", "pharma",
        "pharmaceuticals", "therapeutics", "biosciences", "energy", "motors", "airlines", "hotel",
        "hotels", "resorts", "restaurant", "cafe", "bakery", "dental", "medical", "health",
        "healthcare", "properties", "development", "builders", "homes", "realtors", "advisors",
        "advisory", "management", "investments", "securities", "financial", "credit", "union",
    ]

    static let departmentPattern = #"(?i)\b(department|dept\.?|division|office of|school of|college of|faculty of|bureau of)\b"#

    static let namePrefixes: Set<String> = ["dr", "mr", "mrs", "ms", "miss", "mx", "prof", "rev", "hon", "sir", "dame"]
    static let nameSuffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv"]
    static let nameParticles: Set<String> = [
        "van", "von", "de", "der", "den", "da", "das", "del", "della", "di", "du", "la", "le", "bin", "ibn",
        "al", "el", "ten", "ter", "st", "dos", "y",
    ]

    /// Post-nominal credentials, uppercased with dots removed.
    static let credentials: Set<String> = [
        "PHD", "MD", "MBA", "CPA", "CFA", "CFP", "ESQ", "JD", "PE", "RN", "NP", "PAC", "DDS", "DMD", "DO",
        "OD", "DVM", "PMP", "SHRMCP", "SHRMSCP", "PHR", "SPHR", "CISSP", "CISM", "CISA", "CCIE", "LEED",
        "LEEDAP", "RA", "AIA", "FAIA", "MS", "MA", "BS", "BA", "MSC", "BSC", "LLM", "LLB", "CPC", "CHFC",
        "CLU", "CIMA", "CPWA", "CRPS", "CRPC", "RICP", "MRICS", "FRICS", "FACHE", "DNP", "LCSW", "LPC",
        "PSYD", "EDD", "DC", "ACCA", "CA", "CMA", "CIA", "CEBS", "AIF", "CLTC", "ABR", "CRS", "GRI",
        "SRES", "MPH", "MSW", "MFA", "MED", "BSN", "MSN", "APRN", "FNP", "PT", "DPT", "OTR", "SLP",
        "CSM", "CPP", "EA", "CFE", "FCA", "ACA", "CPCU", "ARM", "AAMS", "CMT", "CAIA", "FRM", "PA", "PENG", "PGEO", "CENG", "MENG", "BENG", "EIT", "FCPA", "CHRP", "CHRL",
    ]
    /// Credentials that are normally written in mixed case.
    static let mixedCaseCredentials: Set<String> = ["PHD", "ESQ", "MSC", "BSC", "MED", "EDD", "PSYD", "PENG", "PGEO", "CENG", "MENG", "BENG"]

    static let phoneLabels: [String: PhoneKind] = [
        "t": .work, "tel": .work, "tele": .work, "telephone": .work, "p": .work, "ph": .work, "phone": .work,
        "o": .work, "off": .work, "office": .work, "w": .work, "work": .work, "d": .work, "direct": .work,
        "dir": .work, "main": .work, "b": .work, "bus": .work, "business": .work, "v": .work, "voice": .work,
        "dl": .work, "ddi": .work, "fon": .work, "tél": .work, "telefon": .work, "teléfono": .work,
        "m": .mobile, "mob": .mobile, "mobile": .mobile, "cell": .mobile, "c": .mobile, "cel": .mobile,
        "cellular": .mobile, "handy": .mobile, "mb": .mobile, "móvil": .mobile, "movil": .mobile,
        "portable": .mobile, "cellulare": .mobile,
        "f": .fax, "fax": .fax, "fx": .fax, "telefax": .fax,
        "tf": .other, "tollfree": .other, "toll": .other, "pager": .other, "home": .other, "h": .other,
    ]

    /// Tokens that are only labels or icon residue once the value next to them is extracted.
    static let labelWords: Set<String> = Set(phoneLabels.keys).union([
        "e", "em", "email", "mail", "e-mail", "web", "www", "url", "website", "site", "a", "addr", "address",
        "linkedin", "twitter", "x", "ig", "instagram", "facebook", "fb", "in", "ext", "free", "s", "i", "l",
        "skype", "wechat", "whatsapp",
    ])

    static let freemailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "yahoo.com", "ymail.com", "hotmail.com", "outlook.com", "live.com",
        "msn.com", "aol.com", "icloud.com", "me.com", "mac.com", "protonmail.com", "proton.me", "gmx.com",
        "gmx.de", "gmx.net", "mail.com", "yandex.com", "yandex.ru", "qq.com", "163.com", "126.com",
        "comcast.net", "verizon.net", "att.net", "sbcglobal.net", "bellsouth.net", "earthlink.net",
        "web.de", "t-online.de", "orange.fr", "free.fr", "btinternet.com", "yahoo.co.uk", "hotmail.co.uk",
    ]

    static let knownTLDs: Set<String> = [
        "com", "net", "org", "edu", "gov", "mil", "int", "io", "co", "ai", "app", "dev", "tech", "biz", "info",
        "me", "us", "uk", "ca", "au", "de", "fr", "es", "it", "nl", "be", "ch", "at", "se", "no", "dk", "fi",
        "pl", "pt", "ie", "nz", "jp", "cn", "in", "kr", "sg", "hk", "tw", "br", "mx", "ar", "cl", "za", "il",
        "ae", "ru", "tr", "gr", "cz", "hu", "ro", "law", "legal", "agency", "studio", "design", "media",
        "digital", "consulting", "group", "global", "online", "site", "store", "shop", "solutions",
        "services", "partners", "capital", "health", "tv", "fm", "ly", "to", "cc", "ws", "xyz", "pro",
        "name", "mobi", "asia", "eu", "lu", "is", "my", "ph", "th", "vn", "id", "sa", "qa", "eg", "ng", "ke",
        "co.uk", "realty", "properties", "energy", "finance", "financial", "money", "bank", "insurance",
        "attorney", "dental", "clinic", "care", "systems", "software", "network", "cloud", "inc",
        "llc", "company", "management", "ventures", "works", "world", "today", "life", "live", "team",
    ]

    static let socialHosts: [String: String] = [
        "facebook.com": "Facebook", "fb.com": "Facebook", "instagram.com": "Instagram",
        "youtube.com": "YouTube", "youtu.be": "YouTube", "tiktok.com": "TikTok", "github.com": "GitHub",
        "threads.net": "Threads", "pinterest.com": "Pinterest", "behance.net": "Behance",
        "dribbble.com": "Dribbble", "medium.com": "Medium", "wa.me": "WhatsApp", "t.me": "Telegram",
        "bsky.app": "Bluesky", "mastodon.social": "Mastodon", "calendly.com": "Calendly",
    ]

    static let countries: Set<String> = [
        "united states", "united states of america", "usa", "us", "u s a", "u s", "canada", "mexico",
        "méxico", "united kingdom", "uk", "u k", "england", "scotland", "wales", "northern ireland",
        "ireland", "germany", "deutschland", "france", "spain", "españa", "italy", "italia",
        "netherlands", "the netherlands", "nederland", "belgium", "belgique", "belgië", "switzerland",
        "schweiz", "suisse", "svizzera", "austria", "österreich", "sweden", "sverige", "norway", "norge",
        "denmark", "danmark", "finland", "suomi", "poland", "polska", "portugal", "greece", "czech republic",
        "czechia", "hungary", "romania", "israel", "uae", "united arab emirates", "saudi arabia", "qatar",
        "india", "china", "prc", "japan", "korea", "south korea", "republic of korea", "singapore",
        "hong kong", "taiwan", "australia", "new zealand", "brazil", "brasil", "argentina", "chile",
        "colombia", "peru", "perú", "south africa", "nigeria", "kenya", "egypt", "turkey", "türkiye",
        "philippines", "indonesia", "malaysia", "thailand", "vietnam", "luxembourg", "iceland", "estonia",
        "latvia", "lithuania", "slovakia", "slovenia", "croatia", "serbia", "bulgaria", "ukraine",
        "russia", "pakistan", "bangladesh", "sri lanka", "puerto rico", "costa rica", "panama",
        "dominican republic", "jamaica", "bahamas", "bermuda", "cayman islands", "monaco", "malta", "cyprus",
    ]
}

enum PhoneKind { case work, mobile, fax, other, unlabeled }
