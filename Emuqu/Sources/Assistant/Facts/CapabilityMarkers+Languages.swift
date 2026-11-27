import Foundation

/// The marker patterns for the languages the app ships beside English:
/// Arabic, Danish, Dutch, Finnish, French, German, Icelandic, Italian,
/// Japanese, Korean, Norwegian, Portuguese, Russian, Spanish, Swedish and
/// Chinese. Latin and Cyrillic words are matched whole; Japanese, Korean,
/// Chinese and Arabic forms as written, since those scripts do not mark word
/// boundaries the way the pattern engine expects.
extension CapabilityMarkers {
    static let otherLanguageTools: [String] = [
        #"\b(?:correo|courriel|sähköposti\w*|tölvupóst\w*|письм\w*)\b"#,
        #"\b(?:navega\w*|navigiere\w*|navigu\w*|navigare|navigeer\w*|navigera\w*|naviger\w*|navigoi\w*)\b"#,
        #"\b(?:indicaciones|wegbeschreibung|itinéraire|indicazioni|routebeschrijving|vägbeskrivning|rutevejledning|veibeskrivelse|reittiohje\w*|маршрут\w*)\b"#,
        #"\b(?:recuerda|acuérdate|merk dir|merke dir|vergiss|souviens|retiens|oublie|ricorda|dimentica|lembre|lembra|esqueça|onthoud|vergeet|kom ihåg|glöm|husk|glem|muista|unohda|mundu|gleymdu|запомни|забудь)\b"#,
        #"メール|메일|이메일|邮件|郵件|ナビ|道案内|길 ?안내|导航|带我去|覚えて|忘れて|기억해|잊어|记住|忘记|بريد|تذكر"#
    ]

    /// Words that are also everyday words elsewhere are matched only in the
    /// weather or search sense: Norwegian "vær" is also "be" ("vær så snill",
    /// please), Italian "cerca di" is "try to", Korean "비가" ends "준비가"
    /// (ready).
    static let otherLanguageWeb: [String] = [
        #"\b(?:qué tiempo|que tiempo|clima|llov\w*|lluvia|nieve|nevar\w*|pronóstico|wetter|regnet|regen|schnee|quel temps|météo|meteo|pluie|pleut|pleuvoir|neige)\b"#,
        #"\b(?:che tempo|pioggia|piove|previsão do tempo|chuva|chover|weerbericht|wat voor weer|väder\w*|vädret|vejr\w*|været|værmelding\w*|sää|sään|sataa|sade)\b"#,
        #"\b(?:veður\w*|rigning|regn|погод\w*|дожд\w*|снег\w*)\b"#,
        #"\b(?:busca\w*|en internet|en línea|im internet|im netz|suche im|such nach|suche nach|cherche\w*|en ligne|sur internet|cercami|cerca (?:online|su internet|in rete|sul web)|pesquis\w*|na internet|zoek\w*|op internet|sök\w*|på nätet|søg\w*|søk\w*|etsi\w*|leita|интернет\w*|найди)\b"#,
        #"\b(?:zapatillas|schuhe|chaussures|scarpe|tênis|schoenen|skor|sko|kengät|кроссовк\w*)\b"#,
        #"\b(?:inscripción|anmeldung|inscription|iscrizione|inscrição|inschrijving|anmälan|tilmelding|påmelding|ilmoittautu\w*|регистрац\w*)\b"#,
        #"天気|雨|雪|気温|날씨|(?<!준)비가|눈이|기온|天气|下雨|下雪|气温|طقس|مطر|أمطار|ネット|検索|검색|인터넷|搜索|查一下|网上|报名|エントリー|접수|ابحث|الإنترنت"#
    ]

    static let otherLanguageDepth: [String] = [
        #"\b(?:meses|monaten|monate|derniers mois|des mois|mesi|maanden|månader\w*|måneder\w*|kuukau\w*|mánuð\w*|месяц\w*)\b"#,
        #"\b(?:este año|dieses jahr|cette année|quest'anno|este ano|dit jaar|i år|tänä vuonna|в этом году)\b"#,
        #"\b(?:de siempre|el año pasado|desde que|aller zeiten|jemals|letztes jahr|seit ich|de tous les temps|l'année dernière|depuis que|di sempre|l'anno scorso|da quando|ano passado)\b"#,
        #"\b(?:ooit|vorig jaar|sinds ik|någonsin|förra året|sedan jag|nogensinde|sidste år|siden jeg|noensinne|i fjor|koskaan|viime vuonna|í fyrra|в прошлом году|с тех пор|когда-либо)\b"#,
        #"\bза вс[её] время\b"#,
        #"ヶ月|か月|カ月|개월|个月|個月|今年|올해|去年|これまで|今まで|작년|지금까지|以来|自从|有史以来|أشهر|شهور|العام الماضي|منذ"#
    ]

    static let otherLanguageSpeculation: [String] = [
        #"\b(?:pronostic\w*|vorhersag\w*|prognos\w*|schätz\w*|prédi\w*|prévoi\w*|prevedi|previsione|stima|voorspel\w*|förutsäg\w*|gissa|forudsig\w*|gæt\w*|forutsi\w*|gjett\w*|ennust\w*|spá\w*|предска\w*|прогноз\w*)\b"#,
        #"\b(?:será|seré|estaré|podré|podría|y si|qué pasa si|werde ich|wird mein\w*|würde|was wäre wenn|serai|sera|serais|pourrai|pourrais|et si|sarò|sarà|potrò|riuscirò|e se)\b"#,
        #"\b(?:serei|estarei|vou conseguir|conseguirei|zal ik|word ik|kommer jag att|hinner jag|klarar jag|vil jeg|kan jeg nå|kommer jeg|voinko|pystynkö|ehdinkö|arvaa|mun ég|буду ли|смогу|успею|что будет)\b"#,
        #"予測|予想|間に合う|できるかな|될까|할 수 있을까|예측|예상|会不会|能不能|预测|预计|توقع|هل سأ"#
    ]
}
