package com.rork.vinetrack.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Agriculture
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.SetupWizardStore
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/**
 * Home Setup Wizard — Android counterpart of the iOS `SetupWizardView`. Walks
 * owners/managers through the three essentials needed before the app is useful:
 * a Block, a Tractor and a Spray Rig. Each step deep-links into the relevant
 * management surface and the wizard recomputes completion live on return, so it
 * auto-advances as items are added. A device-local toggle hides the Home prompt.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SetupWizardScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
) {
    var target by remember { mutableStateOf(WizardTarget.None) }

    AnimatedContent(
        targetState = target,
        transitionSpec = { fadeIn() togetherWith fadeOut() },
        label = "setup-wizard-nav",
        modifier = modifier,
    ) { current ->
        when (current) {
            WizardTarget.None -> WizardSteps(
                vm = vm,
                state = state,
                onBack = onBack,
                onAddBlock = { target = WizardTarget.Blocks },
                onAddTractor = { target = WizardTarget.Tractors },
                onAddRig = { target = WizardTarget.SprayRig },
            )
            WizardTarget.Blocks -> {
                BackHandler { target = WizardTarget.None }
                BlocksScreen(vm, state, onBack = { target = WizardTarget.None })
            }
            WizardTarget.Tractors -> {
                BackHandler { target = WizardTarget.None }
                VineyardMachineList(vm, state, tractorsOnly = true, onBack = { target = WizardTarget.None })
            }
            WizardTarget.SprayRig -> {
                BackHandler { target = WizardTarget.None }
                SprayEquipmentScreen(vm, state, onBack = { target = WizardTarget.None })
            }
        }
    }
}

private enum class WizardTarget { None, Blocks, Tractors, SprayRig }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun WizardSteps(
    vm: AppViewModel,
    state: AppUiState,
    onBack: () -> Unit,
    onAddBlock: () -> Unit,
    onAddTractor: () -> Unit,
    onAddRig: () -> Unit,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val wizardStore = remember { SetupWizardStore(context) }
    var wizardEnabled by remember { mutableStateOf(wizardStore.isEnabled()) }

    val hasBlock = state.paddocks.isNotEmpty()
    val hasTractor = state.machines.any { it.machineType == "tractor" }
    val hasRig = state.sprayEquipment.isNotEmpty()
    val isAllComplete = hasBlock && hasTractor && hasRig

    val totalSteps = 3
    // Jump to the first incomplete step whenever completion state changes.
    var step by remember { mutableIntStateOf(0) }
    remember(hasBlock, hasTractor, hasRig) {
        step = when {
            !hasBlock -> 0
            !hasTractor -> 1
            !hasRig -> 2
            else -> step
        }
        true
    }

    val stepComplete = when (step) {
        0 -> hasBlock
        1 -> hasTractor
        else -> hasRig
    }

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Setup Wizard") },
                navigationIcon = { BackNavIcon(onBack) },
                actions = {
                    TextButton(onClick = onBack) {
                        Text("Done", fontWeight = FontWeight.SemiBold, color = VineColors.LeafGreen)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 20.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            ProgressIndicator(
                step = step,
                totalSteps = totalSteps,
                stepComplete = stepComplete,
                hasBlock = hasBlock,
                hasTractor = hasTractor,
                hasRig = hasRig,
            )

            when (step) {
                0 -> StepCard(
                    icon = Icons.Filled.GridView,
                    tint = VineColors.LeafGreen,
                    title = "Add a Block",
                    description = "Blocks define the sections of your vineyard — boundaries, rows, and varieties. You need at least one block before you can plan sprays, log jobs, or estimate yield.",
                    tip = "Tip: Blocks are mapped from the web portal or iOS app, then sync here with their variety, area and row details.",
                    actionTitle = if (hasBlock) "View Blocks" else "Open Blocks",
                    isComplete = hasBlock,
                    completedMessage = "${state.paddocks.size} block${if (state.paddocks.size == 1) "" else "s"} added",
                    step = step,
                    totalSteps = totalSteps,
                    stepComplete = stepComplete,
                    isAllComplete = isAllComplete,
                    onAction = onAddBlock,
                    onBack = { step = (step - 1).coerceAtLeast(0) },
                    onNext = { step = (step + 1).coerceAtMost(totalSteps - 1) },
                    onFinish = onBack,
                )
                1 -> StepCard(
                    icon = Icons.Filled.Agriculture,
                    tint = VineColors.EarthBrown,
                    title = "Add a Tractor",
                    description = "Tractors are linked to spray records and trips so you can track fuel usage and run-time per job. Add the brand, model, and an estimated fuel use in litres per hour.",
                    tip = "Tip: You can add several tractors and pick the right one when recording a spray or trip.",
                    actionTitle = if (hasTractor) "Add Another Tractor" else "Add Tractor",
                    isComplete = hasTractor,
                    completedMessage = state.machines.count { it.machineType == "tractor" }.let {
                        "$it tractor${if (it == 1) "" else "s"} added"
                    },
                    step = step,
                    totalSteps = totalSteps,
                    stepComplete = stepComplete,
                    isAllComplete = isAllComplete,
                    onAction = onAddTractor,
                    onBack = { step = (step - 1).coerceAtLeast(0) },
                    onNext = { step = (step + 1).coerceAtMost(totalSteps - 1) },
                    onFinish = onBack,
                )
                else -> StepCard(
                    icon = Icons.Filled.WaterDrop,
                    tint = VineColors.Cyan,
                    title = "Add a Spray Rig",
                    description = "Spray rigs (sprayers and tanks) feed the Spray Calculator. Enter a name and tank capacity in litres so the app can work out chemical loads, full tank counts, and water volumes.",
                    tip = "Tip: You can add multiple rigs and switch between them inside the Spray Calculator.",
                    actionTitle = if (hasRig) "Add Another Spray Rig" else "Add Spray Rig",
                    isComplete = hasRig,
                    completedMessage = "${state.sprayEquipment.size} spray rig${if (state.sprayEquipment.size == 1) "" else "s"} added",
                    step = step,
                    totalSteps = totalSteps,
                    stepComplete = stepComplete,
                    isAllComplete = isAllComplete,
                    onAction = onAddRig,
                    onBack = { step = (step - 1).coerceAtLeast(0) },
                    onNext = { step = (step + 1).coerceAtMost(totalSteps - 1) },
                    onFinish = onBack,
                )
            }

            ToggleCard(
                enabled = wizardEnabled,
                isAllComplete = isAllComplete,
                onToggle = {
                    wizardEnabled = it
                    wizardStore.setEnabled(it)
                },
            )
        }
    }
}

@Composable
private fun ProgressIndicator(
    step: Int,
    totalSteps: Int,
    stepComplete: Boolean,
    hasBlock: Boolean,
    hasTractor: Boolean,
    hasRig: Boolean,
) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Step ${step + 1} of $totalSteps",
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                color = vine.textSecondary,
                modifier = Modifier.weight(1f),
            )
            Text(
                if (stepComplete) "Completed" else "Pending",
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                color = if (stepComplete) VineColors.LeafGreen else vine.textSecondary,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
            repeat(totalSteps) { index ->
                val complete = when (index) {
                    0 -> hasBlock
                    1 -> hasTractor
                    else -> hasRig
                }
                val color = when {
                    complete -> VineColors.LeafGreen
                    index == step -> VineColors.Primary
                    else -> vine.cardBorder
                }
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(6.dp)
                        .clip(RoundedCornerShape(3.dp))
                        .background(color),
                )
            }
        }
    }
}

@Composable
private fun StepCard(
    icon: ImageVector,
    tint: Color,
    title: String,
    description: String,
    tip: String,
    actionTitle: String,
    isComplete: Boolean,
    completedMessage: String,
    step: Int,
    totalSteps: Int,
    stepComplete: Boolean,
    isAllComplete: Boolean,
    onAction: () -> Unit,
    onBack: () -> Unit,
    onNext: () -> Unit,
    onFinish: () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(vine.cardBackground)
            .padding(18.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(
                modifier = Modifier.size(56.dp).clip(RoundedCornerShape(14.dp)).background(tint.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(28.dp))
            }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(title, fontSize = 22.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                if (isComplete) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(16.dp))
                        Text(completedMessage, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = VineColors.LeafGreen)
                    }
                } else {
                    Text("Required", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Orange)
                }
            }
        }

        Text(description, fontSize = 15.sp, color = vine.textPrimary, lineHeight = 21.sp)

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(vine.appBackground)
                .padding(12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(Icons.Filled.Lightbulb, contentDescription = null, tint = VineColors.Orange, modifier = Modifier.size(18.dp))
            Text(tip, fontSize = 13.sp, color = vine.textSecondary, lineHeight = 18.sp)
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(tint)
                .clickable { onAction() }
                .padding(vertical = 14.dp),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Add, contentDescription = null, tint = Color.White, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(6.dp))
            Text(actionTitle, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
        }

        // Back / Next / Skip / Finish row
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .then(if (step == 0) Modifier else Modifier.clickable { onBack() })
                    .padding(vertical = 6.dp, horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.KeyboardArrowLeft,
                    contentDescription = null,
                    tint = if (step == 0) vine.textSecondary.copy(alpha = 0.4f) else vine.textPrimary,
                    modifier = Modifier.size(18.dp),
                )
                Text(
                    "Back",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = if (step == 0) vine.textSecondary.copy(alpha = 0.4f) else vine.textPrimary,
                )
            }
            Spacer(Modifier.weight(1f))
            if (step < totalSteps - 1) {
                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .clickable { onNext() }
                        .padding(vertical = 6.dp, horizontal = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        if (stepComplete) "Next" else "Skip",
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textPrimary,
                    )
                    Icon(
                        Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = null,
                        tint = vine.textPrimary,
                        modifier = Modifier.size(18.dp),
                    )
                }
            } else if (isAllComplete) {
                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .clickable { onFinish() }
                        .padding(vertical = 6.dp, horizontal = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Filled.Check, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("Finish", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = VineColors.LeafGreen)
                }
            }
        }
    }
}

@Composable
private fun ToggleCard(enabled: Boolean, isAllComplete: Boolean, onToggle: (Boolean) -> Unit) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .background(vine.cardBackground)
                .padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("Show Setup Wizard", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                Text(
                    "Turn off to hide the wizard button on the home screen.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }
            Switch(
                checked = enabled,
                onCheckedChange = onToggle,
                colors = SwitchDefaults.colors(checkedTrackColor = VineColors.LeafGreen),
            )
        }
        if (isAllComplete) {
            Row(
                modifier = Modifier.padding(horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(Icons.Filled.VerifiedUser, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(16.dp))
                Text(
                    "Setup complete — the wizard will hide automatically.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }
        }
    }
}
