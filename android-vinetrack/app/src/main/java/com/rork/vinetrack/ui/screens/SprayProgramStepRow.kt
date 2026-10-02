package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.spray.SprayProgramLanding
import com.rork.vinetrack.data.spray.SprayProgramTerminology
import com.rork.vinetrack.data.spray.SprayTargetVocabulary
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/** A reusable Program Step, deliberately separate from the operational spray row. */
@Composable
internal fun SprayProgramStepRow(
    record: SprayRecord,
    isPortalManaged: Boolean,
    canEdit: Boolean,
    targetLabels: Map<String, String>,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    val products = remember(record.tanks) { SprayProgramStepPresentation.products(record) }
    val targetLine = remember(record.targets, targetLabels) {
        SprayTargetVocabulary.displayString(SprayTargetVocabulary.tags(record.targets.orEmpty(), null, targetLabels))
    }
    Row(
        modifier = modifier.fillMaxWidth().clickable(onClick = onClick).padding(16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        SprayProgramStageBadge(SprayProgramLanding.elStageLabel(record))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(SprayProgramStepPresentation.name(record), fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            targetLine?.let {
                Text(it, fontSize = 14.sp, color = VineColors.Info, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            products.forEach { product ->
                val rate = SprayProgramStepPresentation.rate(product)
                Text(
                    if (rate == null) product.name else "${product.name} · $rate",
                    fontSize = 13.sp,
                    color = vine.textSecondary,
                )
            }
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                record.operationType?.takeIf { it.isNotBlank() }?.let { method ->
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Icon(Icons.Filled.WaterDrop, contentDescription = null, modifier = Modifier.size(12.dp), tint = vine.textSecondary.copy(alpha = 0.75f))
                        Text(method, fontSize = 11.sp, color = vine.textSecondary.copy(alpha = 0.75f))
                    }
                }
                if (isPortalManaged) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Icon(if (canEdit) Icons.Filled.Sync else Icons.Filled.Lock, contentDescription = null, modifier = Modifier.size(12.dp), tint = vine.textSecondary.copy(alpha = 0.75f))
                        Text(SprayProgramTerminology.SYNCED_WITH_ADMIN_PORTAL, fontSize = 11.sp, color = vine.textSecondary.copy(alpha = 0.75f))
                    }
                }
            }
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary.copy(alpha = 0.6f), modifier = Modifier.size(18.dp).align(Alignment.CenterVertically))
    }
}

@Composable
internal fun SprayProgramStageBadge(label: String?, modifier: Modifier = Modifier, capsule: Boolean = false) {
    val vine = LocalVineColors.current
    Text(
        label ?: "—",
        fontSize = 13.sp,
        fontWeight = FontWeight.Bold,
        color = if (label == null) vine.textSecondary else VineColors.LeafGreen,
        modifier = modifier
            .clip(if (capsule) RoundedCornerShape(50) else RoundedCornerShape(8.dp))
            .background(if (label == null) vine.textSecondary.copy(alpha = 0.08f) else VineColors.LeafGreen.copy(alpha = 0.14f))
            .widthIn(min = 46.dp)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
    )
}
