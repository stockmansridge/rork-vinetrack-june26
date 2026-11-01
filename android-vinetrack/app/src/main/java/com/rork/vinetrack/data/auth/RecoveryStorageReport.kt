package com.rork.vinetrack.data.auth

/** Metadata for user-reviewed support only. Never used as admission or ownership evidence. */
internal data class RecoveryStorageReport(
    val appVersion: String,
    val versionCode: Int,
    val roots: List<Root>,
) {
    enum class Area(val label: String) {
        FILES("files"), PREFERENCES("shared_prefs"), LEGACY_CAMERA("cache/camera-captures"),
    }
    enum class Status { PRESENT, ABSENT, UNREADABLE, NOT_A_DIRECTORY, LINK_OR_ALIAS }
    enum class Kind { REGULAR_FILE, DIRECTORY, SYMBOLIC_LINK, OTHER, METADATA_UNAVAILABLE }
    enum class Category {
        PROFILE_VERIFIER_MARKER, PROFILE_INSTALLER_MARKER, VINEYARD_LOGOS,
        SHARED_REFERENCE_CACHE, KNOWN_RETAINED_PATH, PREFERENCE_FILE,
        LEGACY_CAMERA_ENTRY, UNRECOGNISED_PATH,
    }
    data class Entry(
        val name: String,
        val kind: Kind,
        val bytes: Long? = null,
        val multipleLinks: Boolean = false,
    )
    data class Root(
        val area: Area,
        val status: Status,
        val totalEntries: Int = 0,
        val entries: List<Entry> = emptyList(),
    ) {
        val truncated: Boolean get() = totalEntries > entries.size
    }

    /** No names, paths, hashes, exception text, contents or account identifiers. */
    fun safeSummary(): String = buildString {
        appendLine("Storage metadata summary v1 (no filenames)")
        roots.forEach { root ->
            appendLine("${root.area.name}: ${root.status}; total=${root.totalEntries}; inspected=${root.entries.size}; truncated=${root.truncated}")
            root.entries.groupingBy { category(root.area, it.name) to it.kind }.eachCount()
                .toSortedMap(compareBy<Pair<Category, Kind>>({ it.first.name }, { it.second.name }))
                .forEach { (key, count) -> appendLine("  ${key.first}/${key.second}: $count") }
        }
        append("Names are available only in Review storage inventory. This summary does not grant access or validate file ownership.")
    }

    /** Call only for the local review screen or the user's explicit copy action. */
    fun reviewedText(): String = buildString {
        appendLine("VineTrack Android storage inventory v1")
        appendLine("App version: $appVersion")
        appendLine("Version code: $versionCode")
        appendLine("REVIEW BEFORE SHARING: folder and file names may contain personal information.")
        appendLine("Top-level names and filesystem metadata only. No file contents, preference values, credentials, symlink targets or absolute paths were read for this report.")
        appendLine("All entries are listed, not only failures. Categories identify known names only; they do not validate contents, ownership or safety. No files were changed and no access was granted.")
        roots.forEach { root ->
            appendLine()
            appendLine("${root.area.label}/: ${root.status}; total=${root.totalEntries}; listed=${root.entries.size}; truncated=${root.truncated}")
            root.entries.forEach { entry ->
                appendLine("  ${quoted(root.area.label + "/" + entry.name)} | ${entry.kind} | bytes=${entry.bytes ?: "not_read"} | multiple_links=${entry.multipleLinks} | category=${category(root.area, entry.name)}")
            }
        }
        append("Local snapshot only. Nothing was uploaded. Keep the existing installation and app storage intact.")
    }

    companion object {
        fun category(area: Area, name: String): Category = when {
            area == Area.PREFERENCES -> Category.PREFERENCE_FILE
            area == Area.LEGACY_CAMERA -> Category.LEGACY_CAMERA_ENTRY
            name == "profileInstalled" -> Category.PROFILE_VERIFIER_MARKER
            name == "profileinstaller_profileWrittenFor_lastUpdateTime.dat" -> Category.PROFILE_INSTALLER_MARKER
            name == "vineyard_logos" -> Category.VINEYARD_LOGOS
            name in setOf("canopy_reference_images", "master-label-thumbnails") -> Category.SHARED_REFERENCE_CACHE
            name in retainedNames -> Category.KNOWN_RETAINED_PATH
            else -> Category.UNRECOGNISED_PATH
        }
        private val retainedNames = setOf(
            "pending_pin_photos", "pin_photo_display_cache", "photo-acquisitions",
            "pending_chemical_label_photos", "scout_photos", "ripeness-heatmap",
            "vintage-reports", "vintage-report-exports", "spray-planning-attempts-v1",
            "maintenance-photo-evidence-v1", "pin_capture_evidence_recovery_v2.json",
            "pin_capture_evidence_recovery_v2.json.bak", "pin_capture_evidence_recovery_v2.json.new",
            "field-isolation-v2",
        )
        /** Quote control/bidi characters so a filename cannot forge report lines or UI text. */
        internal fun quoted(value: String): String = buildString {
            append('"')
            value.forEach { ch ->
                when {
                    ch == '"' || ch == '\\' -> { append('\\'); append(ch) }
                    Character.isISOControl(ch) || Character.getType(ch) == Character.FORMAT.toInt() ||
                        ch == '\u2028' || ch == '\u2029' || Character.isSurrogate(ch) ->
                        append("\\u" + ch.code.toString(16).padStart(4, '0'))
                    else -> append(ch)
                }
            }
            append('"')
        }
    }
}
