package com.rork.vinetrack.data.model

/**
 * Built-in grape variety optimal-GDD catalog, ported verbatim from the iOS
 * `BuiltInGrapeVarietyCatalog`. Used by the Optimal Ripeness surface to resolve
 * a variety's heat-unit ripening target when the vineyard hasn't set an
 * `optimal_gdd_override`.
 *
 * Targets resolve by stable `variety_key` first, then by canonical display name
 * (including aliases) — mirroring how iOS maps paddock variety allocations back
 * to managed varieties. Slugs MUST stay in sync with iOS; never repurpose one.
 */
object BuiltInGrapeVarietyGDD {

    private data class Entry(
        val key: String,
        val name: String,
        val gdd: Double,
        val aliases: List<String> = emptyList(),
    )

    private val catalog: List<Entry> = listOf(
        Entry("chardonnay", "Chardonnay", 1145.0),
        Entry("pinot_gris", "Pinot Gris / Grigio", 1100.0, listOf("Pinot Gris", "Pinot Grigio", "PG", "Grauburgunder", "Ruländer")),
        Entry("riesling", "Riesling", 1200.0, listOf("Johannisberg Riesling", "White Riesling")),
        Entry("sauvignon_blanc", "Sauvignon Blanc", 1150.0, listOf("Sauv Blanc", "Sav Blanc", "Savvy B", "Fumé Blanc", "Fume Blanc")),
        Entry("semillon", "Semillon", 1200.0, listOf("Sémillon")),
        Entry("chenin_blanc", "Chenin Blanc", 1250.0, listOf("Steen", "Pineau de la Loire")),
        Entry("gewurztraminer", "Gewurztraminer", 1150.0, listOf("Gewürztraminer", "Traminer Aromatico")),
        Entry("viognier", "Viognier", 1260.0),
        Entry("shiraz", "Shiraz / Syrah", 1255.0, listOf("Shiraz", "Syrah")),
        Entry("merlot", "Merlot", 1250.0),
        Entry("cabernet_franc", "Cabernet Franc", 1255.0, listOf("Cab Franc", "Bouchet")),
        Entry("cabernet_sauvignon", "Cabernet Sauvignon", 1310.0, listOf("Cab Sav", "Cab Sauv", "Cab")),
        Entry("pinot_noir", "Pinot Noir", 1145.0, listOf("Spätburgunder", "Pinot Nero", "Blauburgunder")),
        Entry("tempranillo", "Tempranillo", 1230.0, listOf("Tinta Roriz", "Aragonez", "Tinto Fino", "Cencibel")),
        Entry("sangiovese", "Sangiovese", 1285.0, listOf("Brunello")),
        Entry("grenache", "Grenache / Garnacha", 1365.0, listOf("Grenache", "Garnacha", "Cannonau", "Grenache Noir")),
        Entry("mataro_mourvedre", "Mataro / Mourvedre", 1440.0, listOf("Mataro", "Mourvedre", "Mourvèdre", "Monastrell")),
        Entry("barbera", "Barbera", 1285.0),
        Entry("malbec", "Malbec", 1230.0, listOf("Cot", "Côt", "Auxerrois")),
        Entry("colombard", "Colombard", 1300.0, listOf("French Colombard")),
        Entry("muscat_gordo_blanco", "Muscat Gordo Blanco", 1350.0, listOf("Muscat Gordo", "Muscat of Alexandria", "Moscatel de Alejandría")),
        Entry("fiano", "Fiano", 1320.0),
        Entry("prosecco", "Prosecco / Glera", 1410.0, listOf("Prosecco", "Glera")),
        Entry("vermentino", "Vermentino", 1290.0, listOf("Rolle", "Pigato")),
        Entry("gruner_veltliner", "Gruner Veltliner", 1200.0, listOf("Grüner Veltliner", "Gruner", "GV")),
        Entry("primitivo", "Primitivo / Zinfandel", 1200.0, listOf("Primitivo", "Zinfandel", "Zin", "Crljenak Kaštelanski")),
        Entry("albarino", "Albariño", 1250.0, listOf("Albarino", "Alvarinho")),
        Entry("arneis", "Arneis", 1280.0),
        Entry("chasselas", "Chasselas", 1150.0, listOf("Gutedel", "Fendant")),
        Entry("marsanne", "Marsanne", 1290.0),
        Entry("muscadelle", "Muscadelle", 1250.0),
        Entry("muscat_blanc", "Muscat Blanc", 1280.0, listOf("Muscat Blanc à Petits Grains", "Muscat Blanc a Petits Grains", "Moscato Bianco", "Moscato", "Muscat Canelli")),
        Entry("palomino", "Palomino", 1300.0, listOf("Palomino Fino", "Listán Blanco", "Listan Blanco")),
        Entry("pedro_ximenez", "Pedro Ximénez", 1320.0, listOf("PX", "Pedro Ximenez")),
        Entry("picpoul", "Picpoul / Piquepoul", 1250.0, listOf("Piquepoul", "Picpoul Blanc", "Piquepoul Blanc")),
        Entry("pinot_blanc", "Pinot Blanc", 1150.0, listOf("Weissburgunder", "Weißburgunder", "Pinot Bianco")),
        Entry("roussanne", "Roussanne", 1300.0),
        Entry("trebbiano", "Trebbiano / Ugni Blanc", 1290.0, listOf("Ugni Blanc", "Trebbiano Toscano", "St-Emilion")),
        Entry("verdejo", "Verdejo", 1260.0),
        Entry("verdelho", "Verdelho", 1280.0, listOf("Verdello")),
        Entry("aglianico", "Aglianico", 1400.0),
        Entry("carmenere", "Carmenère", 1370.0, listOf("Carmenere", "Grande Vidure")),
        Entry("cinsault", "Cinsault", 1350.0, listOf("Cinsaut")),
        Entry("dolcetto", "Dolcetto", 1230.0),
        Entry("gamay", "Gamay", 1100.0, listOf("Gamay Noir", "Gamay Noir à Jus Blanc")),
        Entry("montepulciano", "Montepulciano", 1380.0),
        Entry("nebbiolo", "Nebbiolo", 1410.0, listOf("Spanna", "Chiavennasca", "Picotendro")),
        Entry("nero_davola", "Nero d'Avola", 1420.0, listOf("Nero dAvola", "Nero d Avola", "Calabrese")),
        Entry("petit_verdot", "Petit Verdot", 1390.0),
        Entry("petite_sirah", "Petite Sirah / Durif", 1390.0, listOf("Durif", "Petite Syrah", "Petite Sirah")),
        Entry("pinot_meunier", "Pinot Meunier", 1100.0, listOf("Meunier", "Schwarzriesling")),
        Entry("touriga_nacional", "Touriga Nacional", 1380.0),
        Entry("zweigelt", "Zweigelt", 1180.0, listOf("Blauer Zweigelt", "Rotburger")),
        Entry("assyrtiko", "Assyrtiko", 1320.0),
        Entry("chambourcin", "Chambourcin", 1280.0),
        Entry("furmint", "Furmint", 1280.0),
        Entry("lagrein", "Lagrein", 1350.0),
        Entry("mencia", "Mencía", 1300.0, listOf("Mencia", "Jaen")),
        Entry("savagnin", "Savagnin", 1200.0, listOf("Traminer", "Heida", "Païen")),
        Entry("tannat", "Tannat", 1430.0),
    )

    private val byKey: Map<String, Double> = catalog.associate { it.key to it.gdd }

    private val byCanonicalName: Map<String, Double> = buildMap {
        catalog.forEach { entry ->
            put(canonicalVarietyName(entry.name), entry.gdd)
            entry.aliases.forEach { alias -> put(canonicalVarietyName(alias), entry.gdd) }
        }
    }

    /** Built-in optimal GDD for a stable variety key, or null when unknown. */
    fun gddForKey(key: String?): Double? = key?.let { byKey[it] }

    /** Built-in optimal GDD resolved from a display name (incl. aliases), or null. */
    fun gddForName(name: String?): Double? =
        name?.let { byCanonicalName[canonicalVarietyName(it)] }

    /**
     * Resolves a variety's optimal GDD target: an explicit override wins,
     * otherwise the built-in catalog (by key, then canonical name). Returns 0
     * when nothing is configured so callers can surface a "set target" hint.
     */
    fun resolveTarget(override: Double?, key: String?, displayName: String?): Double {
        if (override != null && override > 0) return override
        gddForKey(key)?.let { return it }
        gddForName(displayName)?.let { return it }
        return 0.0
    }
}
