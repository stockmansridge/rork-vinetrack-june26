package com.rork.vinetrack.ui.screens

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.AddPhotoAlternate
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.rork.vinetrack.data.model.GrowthStage
import com.rork.vinetrack.data.model.GrowthStageImage
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/**
 * Owner/manager curation of per-vineyard custom E-L reference images, mirroring
 * the iOS `GrowthStageImagesSettingsView`. Each E-L stage can have one custom
 * reference photo stored in the shared `vineyard-el-stage-images` bucket so iOS,
 * the Lovable portal and Android all show the same imagery. Non-managers see the
 * images read-only.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GrowthStageImagesScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val canManage = state.currentRole == "owner" || state.currentRole == "manager"
    var selected by remember { mutableStateOf<GrowthStage?>(null) }

    val imagesByCode = remember(state.growthStageImages) {
        state.growthStageImages.associateBy { it.stageCode }
    }
    // Mirror iOS: a stage counts as "with image" when it has either a vineyard
    // custom upload or an app-bundled reference photo.
    val withImages = remember(imagesByCode) {
        GrowthStage.allStages.filter { imagesByCode.containsKey(it.code) || GrowthStageBundledImages.hasBundled(it.code) }
    }
    val withoutImages = remember(imagesByCode) {
        GrowthStage.allStages.filter { !imagesByCode.containsKey(it.code) && !GrowthStageBundledImages.hasBundled(it.code) }
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Growth Stage Images") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = vine.cardBackground,
                    titleContentColor = vine.textPrimary,
                ),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            item {
                Text(
                    "Add a reference photo for each E-L stage. Images are shared with everyone who has access to this vineyard.",
                    color = vine.textSecondary,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(bottom = 4.dp),
                )
            }

            if (withImages.isNotEmpty()) {
                item { SectionHeader("Stages with Images", onLight = true) }
                items(withImages, key = { it.code }) { stage ->
                    StageRow(
                        vm = vm,
                        stage = stage,
                        image = imagesByCode[stage.code],
                        busy = state.growthStageImageBusyCode == stage.code,
                        onClick = { selected = stage },
                    )
                }
            }

            if (canManage && withoutImages.isNotEmpty()) {
                item { SectionHeader("Stages without Images", onLight = true) }
                items(withoutImages, key = { it.code }) { stage ->
                    StageRow(
                        vm = vm,
                        stage = stage,
                        image = null,
                        busy = state.growthStageImageBusyCode == stage.code,
                        onClick = { selected = stage },
                    )
                }
            }
        }
    }

    selected?.let { stage ->
        StageImageDetailSheet(
            vm = vm,
            state = state,
            stage = stage,
            image = imagesByCode[stage.code],
            canManage = canManage,
            onDismiss = { selected = null },
        )
    }
}

@Composable
private fun StageRow(
    vm: AppViewModel,
    stage: GrowthStage,
    image: GrowthStageImage?,
    busy: Boolean,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    var url by remember(image?.imagePath) { mutableStateOf<String?>(null) }
    LaunchedEffect(image?.imagePath) {
        url = null
        val path = image?.imagePath
        if (!path.isNullOrBlank()) vm.requestGrowthStageImageUrl(path) { url = it }
    }
    val bundledRes = remember(stage.code) { GrowthStageBundledImages.resFor(stage.code) }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(vine.cardBackground)
            .clickable(onClick = onClick)
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier
                .size(width = 56.dp, height = 42.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(VineColors.LeafGreen.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) {
            // Custom upload wins; otherwise fall back to the app-bundled photo.
            val model: Any? = url ?: bundledRes
            when {
                busy -> CircularProgressIndicator(color = VineColors.LeafGreen, modifier = Modifier.size(18.dp))
                model != null -> AsyncImage(
                    model = model,
                    contentDescription = "${stage.code} reference image",
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
                image != null -> CircularProgressIndicator(color = VineColors.LeafGreen, modifier = Modifier.size(18.dp))
                else -> Icon(
                    Icons.Filled.AddPhotoAlternate,
                    contentDescription = null,
                    tint = vine.textSecondary,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
        Column(Modifier.weight(1f)) {
            Text(stage.code, color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.Bold)
            Text(stage.description, color = vine.textSecondary, fontSize = 12.sp, maxLines = 2)
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = vine.textSecondary,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun StageImageDetailSheet(
    vm: AppViewModel,
    state: AppUiState,
    stage: GrowthStage,
    image: GrowthStageImage?,
    canManage: Boolean,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val busy = state.growthStageImageBusyCode == stage.code
    var showRemove by remember { mutableStateOf(false) }

    var url by remember(image?.imagePath) { mutableStateOf<String?>(null) }
    LaunchedEffect(image?.imagePath) {
        url = null
        val path = image?.imagePath
        if (!path.isNullOrBlank()) vm.requestGrowthStageImageUrl(path) { url = it }
    }
    val bundledRes = remember(stage.code) { GrowthStageBundledImages.resFor(stage.code) }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) vm.uploadGrowthStageImage(stage.code, uri) {}
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = vine.cardBackground) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(200.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(VineColors.LeafGreen.copy(alpha = 0.10f)),
                contentAlignment = Alignment.Center,
            ) {
                val model: Any? = url ?: bundledRes
                when {
                    model != null -> AsyncImage(
                        model = model,
                        contentDescription = "${stage.code} reference image",
                        contentScale = ContentScale.Fit,
                        modifier = Modifier.fillMaxSize(),
                    )
                    image != null -> CircularProgressIndicator(color = VineColors.LeafGreen)
                    else -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Icon(Icons.Filled.PhotoCamera, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(36.dp))
                        Text("No image available", color = vine.textSecondary, fontSize = 13.sp)
                    }
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(stage.code, color = VineColors.LeafGreen, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                Text(stage.description, color = vine.textSecondary, fontSize = 14.sp)
            }

            if (canManage) {
                OutlinedButton(
                    onClick = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !busy,
                ) {
                    if (busy) {
                        CircularProgressIndicator(modifier = Modifier.size(18.dp), color = VineColors.LeafGreen)
                    } else {
                        Icon(Icons.Filled.AddPhotoAlternate, contentDescription = null, modifier = Modifier.size(18.dp))
                        Text(if (image != null) "  Replace Image" else "  Add Custom Image")
                    }
                }
                if (image != null) {
                    OutlinedButton(
                        onClick = { showRemove = true },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = !busy,
                    ) {
                        Text("Remove Image", color = VineColors.Destructive)
                    }
                }
            } else {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                        .background(vine.appBackground).padding(14.dp),
                ) {
                    Icon(Icons.Filled.Lock, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(18.dp))
                    Text(
                        "Reference images are managed by vineyard owners and managers.",
                        color = vine.textSecondary,
                        fontSize = 13.sp,
                    )
                }
            }
        }
    }

    if (showRemove) {
        AlertDialog(
            onDismissRequest = { showRemove = false },
            title = { Text("Remove Image?") },
            text = { Text("This will remove the reference image for ${stage.code} for everyone in this vineyard.") },
            confirmButton = {
                TextButton(onClick = {
                    showRemove = false
                    vm.removeGrowthStageImage(stage.code) {}
                }) { Text("Remove", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { showRemove = false }) { Text("Cancel") } },
        )
    }
}
