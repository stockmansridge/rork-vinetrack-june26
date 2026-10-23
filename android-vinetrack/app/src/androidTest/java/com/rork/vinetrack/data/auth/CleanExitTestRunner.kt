package com.rork.vinetrack.data.auth

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.ApplicationInfo
import androidx.test.runner.AndroidJUnitRunner
import java.io.File
import java.util.UUID

/** Test-APK-only Application substitution before production Activity/repository construction. */
class CleanExitTestRunner : AndroidJUnitRunner() {
    override fun newApplication(cl: ClassLoader, className: String, context: Context): Application =
        super.newApplication(cl, CleanExitFixtureApplication::class.java.name, context)
}

/** No real installation preferences or private files are read, cleared or replayed. */
class CleanExitFixtureApplication : Application() {
    // Test-only: null manager makes the real ConnectivityObserver emit online on collection.
    var immediateOnlineWithoutNetworkManager = false
    override fun getSystemService(name: String): Any? =
        if (immediateOnlineWithoutNetworkManager && name == Context.CONNECTIVITY_SERVICE) null
        else super.getSystemService(name)

    private val namespace = "clean_exit_fixture_${UUID.randomUUID()}_"
    private val names = linkedSetOf<String>()
    private val fixtureRoot: File by lazy { File(super.getFilesDir(), namespace).also { check(it.mkdirs() || it.isDirectory) } }
    override fun getApplicationContext(): Context = this
    override fun getFilesDir(): File = File(fixtureRoot, "files").also { check(it.mkdirs() || it.isDirectory) }
    override fun getCacheDir(): File = File(fixtureRoot, "cache").also { check(it.mkdirs() || it.isDirectory) }
    override fun getNoBackupFilesDir(): File = File(fixtureRoot, "no_backup").also { check(it.mkdirs() || it.isDirectory) }
    override fun getApplicationInfo(): ApplicationInfo = ApplicationInfo(super.getApplicationInfo()).apply { dataDir = fixtureRoot.absolutePath }
    override fun getSharedPreferences(name: String, mode: Int): SharedPreferences = synchronized(names) {
        names.add(name)
        super.getSharedPreferences(namespace + name, mode)
    }
    fun resetFixture() {
        immediateOnlineWithoutNetworkManager = false
        synchronized(names) { names.forEach { check(super.getSharedPreferences(namespace + it, MODE_PRIVATE).edit().clear().commit()) } }
        listOf(filesDir, cacheDir, noBackupFilesDir).forEach { dir -> dir.listFiles()?.forEach { check(it.deleteRecursively()) } }
    }
}
