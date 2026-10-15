package com.rork.vinetrack.data.spray

import android.content.Context
import android.util.AtomicFile
import com.rork.vinetrack.data.auth.FieldStoreAccess
import java.io.File

/** AtomicFile + fsync-backed finishWrite. Account admission is checked for every read/replacement. */
class SprayPlanningNativeStore(context: Context) {
    private val root = File(context.filesDir, "spray-planning-attempts-v1")
    private val access = FieldStoreAccess(context)
    private val journals = mutableMapOf<SprayPlanningProtocol.Scope, SprayPlanningAttemptJournal>()
    @Synchronized fun journal(scope: SprayPlanningProtocol.Scope): SprayPlanningAttemptJournal {
        require(listOf(scope.actorId, scope.vineyardId, scope.incarnation).all(SprayPlanningProtocol::uuid))
        return journals.getOrPut(scope) {
            val parent = File(root, "${scope.actorId}/${scope.vineyardId}/${scope.incarnation}")
            val file = AtomicFile(File(parent, "attempts.json"))
            SprayPlanningAttemptJournal(object : SprayPlanningAttemptJournal.Storage {
                override fun read(): String? = access.admittedForOwner(scope.actorId) {
                    if (file.baseFile.exists() || File(file.baseFile.path + ".bak").exists())
                        file.openRead().bufferedReader().use { it.readText() } else null
                }
                override fun commit(value: String): Boolean = access.admittedForOwner(scope.actorId) {
                    if (!parent.exists() && !parent.mkdirs()) return@admittedForOwner false
                    val stream = file.startWrite()
                    try { stream.write(value.toByteArray(Charsets.UTF_8)); file.finishWrite(stream); file.openRead().bufferedReader().use { it.readText() } == value }
                    catch (e: Exception) { file.failWrite(stream); false }
                }
            }, scope)
        }
    }
}
