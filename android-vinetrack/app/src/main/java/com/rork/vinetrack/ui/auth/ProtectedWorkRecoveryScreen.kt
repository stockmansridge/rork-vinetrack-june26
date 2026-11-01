package com.rork.vinetrack.ui.auth

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.rork.vinetrack.BuildConfig
import com.rork.vinetrack.data.auth.RecoveryStorageInventory
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Pre-business recovery surface. Never constructs a business ViewModel or reads field stores. */
@Composable
fun ProtectedWorkRecoveryScreen(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val factory = remember(context) {
        object : androidx.lifecycle.ViewModelProvider.Factory {
            override fun <T : androidx.lifecycle.ViewModel> create(modelClass: Class<T>): T {
                require(modelClass == ProtectedWorkRecoveryViewModel::class.java)
                @Suppress("UNCHECKED_CAST")
                return ProtectedWorkRecoveryViewModel(context.applicationContext) as T
            }
        }
    }
    val vm: ProtectedWorkRecoveryViewModel = viewModel(factory = factory)
    val state by vm.state.collectAsStateWithLifecycle()
    var email: String by remember { mutableStateOf("") }
    var password: String by remember { mutableStateOf("") }
    var supportMessage: String? by remember { mutableStateOf(null) }
    var inventoryText: String? by remember { mutableStateOf(null) }
    var inventoryLoading by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    Column(
        modifier = modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Local work protected", style = MaterialTheme.typography.headlineMedium)
        Text("Unfinished or uncertain vineyard work is retained on this installation. Business access is paused to prevent another account from using it.")
        Text("Sign in as the original account to request access restoration. The app checks your server-verified identity, current vineyard access and retained-work evidence before opening business access. Unknown, conflicting or authorless work remains protected; a matching account alone does not unlock it.")
        OutlinedTextField(email, { email = it }, modifier = Modifier.fillMaxWidth(), label = { Text("Account email") }, singleLine = true, enabled = !state.isBusy)
        OutlinedTextField(password, { password = it }, modifier = Modifier.fillMaxWidth(), label = { Text("Password") }, singleLine = true, enabled = !state.isBusy, visualTransformation = PasswordVisualTransformation())
        Button(enabled = !state.isBusy && email.isNotBlank() && password.isNotBlank(), onClick = {
            vm.verify(email, password)
            password = ""
        }) { Text(if (state.isBusy) "Verifying account…" else "Restore original account") }
        state.message?.let { Text(it) }
        TextButton(enabled = !state.isBusy, onClick = {
            vm.copyDiagnostics { text ->
                val clipboard = context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                clipboard.setPrimaryClip(android.content.ClipData.newPlainText("VineTrack recovery diagnostics", text))
                supportMessage = "Recovery diagnostics copied. Only app version, stage, store, validation rule, schema and safe counts are included. Nothing was uploaded."
            }
        }) { Text("Copy recovery diagnostics") }
        TextButton(enabled = !state.isBusy && !inventoryLoading, onClick = {
            inventoryLoading = true
            scope.launch {
                try {
                    inventoryText = withContext(Dispatchers.IO) {
                        RecoveryStorageInventory.capture(context.applicationContext).reviewedText()
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    supportMessage = "Storage metadata could not be inspected. No files were changed."
                } finally {
                    inventoryLoading = false
                }
            }
        }) { Text(if (inventoryLoading) "Reading storage metadata..." else "Review storage inventory") }
        TextButton(onClick = {
            val request = Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:jonathan@stockmansridge.com.au")).apply {
                putExtra(Intent.EXTRA_SUBJECT, "VineTrack Android retained-work recovery")
                putExtra(Intent.EXTRA_TEXT, "VineTrack Android ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}). Local work is protected. Please help review original operation ownership and a safe recovery path. I have kept the installation intact. No field records or credentials are attached.")
            }
            supportMessage = if (runCatching { context.startActivity(request) }.isSuccess) null
                else "Email jonathan@stockmansridge.com.au and request retained-work recovery. No email app is available here."
        }) { Text("Contact recovery support") }
        supportMessage?.let { Text(it) }
        Text("Do not clear app storage or reinstall. Retained work is not deleted, exported or reassigned by this screen. Support contact does not guarantee authorless work can be unlocked.")
    }
    inventoryText?.let { report ->
        AlertDialog(
            onDismissRequest = { inventoryText = null },
            title = { Text("Review storage inventory") },
            text = {
                Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Names may contain personal information. Review them before copying. File contents, passwords and stored records are not included. Nothing is uploaded automatically.")
                    SelectionContainer { Text(report, style = MaterialTheme.typography.bodySmall) }
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    val clipboard = context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                    clipboard.setPrimaryClip(android.content.ClipData.newPlainText("VineTrack reviewed storage inventory", report))
                    supportMessage = "Reviewed storage inventory copied. It includes file and folder names, but no contents or preference values. Nothing was uploaded."
                    inventoryText = null
                }) { Text("Copy reviewed inventory") }
            },
            dismissButton = { TextButton(onClick = { inventoryText = null }) { Text("Close") } },
        )
    }
}
