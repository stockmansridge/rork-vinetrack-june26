package com.rork.vinetrack.ui.screens

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import android.graphics.BitmapFactory
import com.rork.vinetrack.data.SupportRequestCategory
import com.rork.vinetrack.data.SupportSubmissionResult
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch

private const val MAX_ATTACHMENTS = 5

/**
 * In-app support / feedback / feature-request form, mirroring the iOS
 * `SupportRequestView`. Submits to the durable `support_requests` table (with
 * optional photo attachments) and triggers the support email edge function, so
 * the user never has to open their own mail app.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SupportRequestScreen(
    vm: AppViewModel,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var category by remember { mutableStateOf(SupportRequestCategory.General) }
    var subject by remember { mutableStateOf("") }
    var message by remember { mutableStateOf("") }
    var name by remember { mutableStateOf(vm.userName ?: "") }
    var email by remember { mutableStateOf(vm.userEmail ?: "") }
    var attachments by remember { mutableStateOf<List<ByteArray>>(emptyList()) }
    var isSubmitting by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var result by remember { mutableStateOf<SupportSubmissionResult?>(null) }
    var categoryMenu by remember { mutableStateOf(false) }

    val photoPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri == null || attachments.size >= MAX_ATTACHMENTS) return@rememberLauncherForActivityResult
        scope.launch {
            runCatching { vm.compressSupportAttachment(uri) }
                .onSuccess { attachments = attachments + it }
        }
    }

    val canSubmit = subject.isNotBlank() && message.isNotBlank() && !isSubmitting

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Contact Support") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        val current = result
        if (current != null) {
            SupportSuccess(current, padding, onBack)
            return@Scaffold
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            // What can we help with?
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("What can we help with?", onLight = true)
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Box {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(10.dp))
                                    .clickable { categoryMenu = true }
                                    .padding(vertical = 6.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text("Category", color = vine.textSecondary, modifier = Modifier.weight(1f))
                                Text(category.label, color = vine.textPrimary, fontWeight = FontWeight.Medium)
                                Icon(Icons.Filled.ExpandMore, contentDescription = null, tint = vine.textSecondary)
                            }
                            DropdownMenu(expanded = categoryMenu, onDismissRequest = { categoryMenu = false }) {
                                SupportRequestCategory.entries.forEach { c ->
                                    DropdownMenuItem(
                                        text = { Text(c.label) },
                                        onClick = { category = c; categoryMenu = false },
                                    )
                                }
                            }
                        }
                        OutlinedTextField(
                            value = subject,
                            onValueChange = { subject = it },
                            label = { Text("Subject") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }

            // Details
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Details", onLight = true)
                VineyardCard {
                    OutlinedTextField(
                        value = message,
                        onValueChange = { message = it },
                        label = { Text("Describe your feedback, request or issue…") },
                        minLines = 5,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }

            // Attachments
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Attachments", onLight = true)
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        if (attachments.isNotEmpty()) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .horizontalScroll(rememberScrollState()),
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                attachments.forEachIndexed { index, bytes ->
                                    AttachmentThumb(bytes) {
                                        attachments = attachments.filterIndexed { i, _ -> i != index }
                                    }
                                }
                            }
                        }
                        if (attachments.size < MAX_ATTACHMENTS) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        photoPicker.launch(
                                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                                        )
                                    }
                                    .padding(vertical = 6.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                Icon(Icons.Filled.AttachFile, contentDescription = null, tint = VineColors.Info)
                                Text("Add attachment", color = VineColors.Info, fontWeight = FontWeight.Medium)
                            }
                        }
                        Text(
                            "Optional. Add up to $MAX_ATTACHMENTS photos or screenshots.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
            }

            // Contact
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Contact", onLight = true)
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        OutlinedTextField(
                            value = name,
                            onValueChange = { name = it },
                            label = { Text("Your name") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        OutlinedTextField(
                            value = email,
                            onValueChange = { email = it },
                            label = { Text("Your email") },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                            modifier = Modifier.fillMaxWidth(),
                        )
                        vm.selectedVineyardName?.let { vineyardName ->
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text("Vineyard", color = vine.textSecondary, modifier = Modifier.weight(1f))
                                Text(
                                    vineyardName.ifBlank { "—" },
                                    color = vine.textPrimary,
                                    fontWeight = FontWeight.Medium,
                                )
                            }
                        }
                        Text(
                            "We'll reply to this email. Your vineyard and app details are included to help us assist you faster.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
            }

            errorMessage?.let { msg ->
                VineyardCard {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Icon(Icons.Filled.WarningAmber, contentDescription = null, tint = VineColors.Destructive)
                        Text(msg, fontSize = 13.sp, color = VineColors.Destructive)
                    }
                }
            }

            // Submit
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(if (canSubmit) VineColors.Primary else VineColors.Stone)
                    .let { m -> if (canSubmit) m.clickable {
                        isSubmitting = true
                        errorMessage = null
                        scope.launch {
                            runCatching {
                                vm.submitSupportRequest(
                                    category = category,
                                    subject = subject.trim(),
                                    message = message.trim(),
                                    submitterName = name,
                                    submitterEmail = email,
                                    attachments = attachments,
                                )
                            }.onSuccess { result = it }
                                .onFailure {
                                    errorMessage = "Could not send your request: ${it.message ?: "unknown error"}. " +
                                        "Please check your connection and try again — your message has not been discarded."
                                }
                            isSubmitting = false
                        }
                    } else m },
                contentAlignment = Alignment.Center,
            ) {
                if (isSubmitting) {
                    CircularProgressIndicator(
                        modifier = Modifier.padding(14.dp).size(22.dp),
                        color = Color.White,
                        strokeWidth = 2.dp,
                    )
                } else {
                    Text(
                        "Send to Support",
                        modifier = Modifier.padding(vertical = 14.dp),
                        color = Color.White,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }

            Text(
                vm.supportInfoFooter,
                fontSize = 11.sp,
                color = vine.textSecondary,
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(8.dp))
        }
    }
}

@Composable
private fun AttachmentThumb(bytes: ByteArray, onRemove: () -> Unit) {
    val bitmap = remember(bytes) {
        runCatching { BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }.getOrNull()
    }
    Box(modifier = Modifier.size(76.dp)) {
        if (bitmap != null) {
            androidx.compose.foundation.Image(
                bitmap = bitmap.asImageBitmap(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.size(76.dp).clip(RoundedCornerShape(10.dp)),
            )
        }
        Box(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(2.dp)
                .clip(CircleShape)
                .clickable { onRemove() },
        ) {
            Icon(
                Icons.Filled.Cancel,
                contentDescription = "Remove",
                tint = Color.White,
                modifier = Modifier.size(22.dp),
            )
        }
    }
}

@Composable
private fun SupportSuccess(
    result: SupportSubmissionResult,
    padding: PaddingValues,
    onBack: (() -> Unit)?,
) {
    val vine = LocalVineColors.current
    val detail = when (result.emailStatus) {
        "sent" -> "Your message has been saved and our team has been notified. We'll be in touch via email soon."
        else -> "Your message has been saved and our team will see it. We'll be in touch via email soon."
    }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(padding)
            .padding(32.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            Icons.Filled.CheckCircle,
            contentDescription = null,
            tint = VineColors.Success,
            modifier = Modifier.size(64.dp),
        )
        Text("Support request sent", fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
        Text(detail, fontSize = 14.sp, color = vine.textSecondary)
        if (onBack != null) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(VineColors.Primary)
                    .clickable { onBack() },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    "Done",
                    modifier = Modifier.padding(vertical = 14.dp),
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}
