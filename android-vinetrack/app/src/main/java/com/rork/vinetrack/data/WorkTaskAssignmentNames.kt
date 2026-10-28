package com.rork.vinetrack.data

import android.content.SharedPreferences
import com.rork.vinetrack.data.model.VineyardMember

/** Presentation only: no task IDs, membership or labour authority are modified. */
class WorkTaskAssignmentNames(private val preferences: SharedPreferences) {
    fun resolve(account: String?, vineyard: String?, member: String?, external: String?, label: String? = null): String {
        val id = member ?: external ?: return ""
        val fallback = if (member != null) "Assigned vineyard member" else "Assigned external resource"
        if (account == null || vineyard == null) return fallback
        val kind = if (member != null) "member" else "external"
        val key = "v1.$account.$vineyard.$kind.$id"
        humanName(label)?.let { preferences.edit().putString(key, it).apply(); return it }
        return humanName(preferences.getString(key, null)) ?: fallback
    }
    companion object {
        fun humanName(value: String?): String? = value?.trim()?.takeIf { name ->
            name.isNotEmpty() && name !in setOf("Assigned vineyard member", "Assigned external resource", "Vineyard member", "Unassigned") &&
                !name.startsWith("Vineyard member (") && !name.startsWith("External resource (") &&
                !Regex("(?i)^(?:user )?[0-9a-f]{8}(?:-[0-9a-f-]+)?$").matches(name)
        }
        fun memberName(member: VineyardMember): String? = listOf(member.fullName, member.displayName, member.email).firstNotNullOfOrNull(::humanName)
    }
}
