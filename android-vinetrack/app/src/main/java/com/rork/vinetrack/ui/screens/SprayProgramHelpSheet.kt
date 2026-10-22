package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/** Bundled operator help. No repository, persistence or network dependencies. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SprayProgramHelpSheet(onDismiss: () -> Unit) {
    val vine = LocalVineColors.current
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true),
        containerColor = vine.appBackground,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "How the Spray Program Works",
                style = MaterialTheme.typography.titleLarge,
                color = vine.textPrimary,
                modifier = Modifier.weight(1f).semantics { heading() },
            )
            TextButton(onClick = onDismiss) { Text("Done") }
        }
        Column(
            modifier = Modifier.fillMaxWidth().weight(1f, fill = false)
                .verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            HelpCard("How the Spray Program Works") {
                HelpText("Your **Program** is your vineyard’s seasonal application plan. It is built from reusable **Program Steps**.")
            }
            HelpCard("Program Steps") {
                HelpText("Each Program Step describes an application you may want to use during the season, including the products, rates, application method, target and E-L growth stage.")
                HelpText("A Program Step can use one of the supported application methods:")
                HelpText("• **Foliar Spray** — applications to the vine canopy")
                HelpText("• **Banded Spray** — targeted applications such as under-vine spraying")
                HelpText("• **Spreader** — applications made using spreading equipment")
                HelpText("• **Fertigation** — products applied through the irrigation system")
                HelpText("A Program Step is a reusable plan — it is **not** a completed application.")
                HelpText("You can use the **same Program Step more than once during a season**. Each use creates its own application record while the original Program Step remains available to use again.")
            }
            HelpCard("Program tab") {
                HelpText("The **Program** tab contains the reusable Program Steps for the vineyard.")
                HelpText("Program Steps are sorted by **E-L growth stage from lowest to highest by default**, helping operators work through the program in approximate seasonal order.")
                HelpText("The existing sort controls can still be used to change this order.")
                HelpText("Select a Program Step to review it and use **Plan from Program** when preparing an application.")
            }
            HelpCard("Sprays tab") {
                HelpText("The **Sprays** tab shows the actual applications for the season.")
                HelpDefinition("Upcoming", "Applications that have been planned but not yet started, together with the next relevant Program Steps in the seasonal program.")
                HelpDefinition("In Progress", "Applications that have been started but have not yet been completed.")
                HelpDefinition("Completed", "Applications that have been finished and recorded.")
                HelpDefinition("All", "All spray/application records.")
            }
            HelpCard("Program vs Sprays") {
                Column(
                    modifier = Modifier.fillMaxWidth()
                        .background(VineColors.LeafGreen.copy(alpha = 0.1f), RoundedCornerShape(10.dp)).padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text("Program = what you plan to do.", style = MaterialTheme.typography.titleSmall, color = VineColors.LeafGreen)
                    Text("Sprays = what you are doing or have done.", style = MaterialTheme.typography.titleSmall, color = VineColors.LeafGreen)
                }
                HelpText("Your Program Steps remain reusable and can be used multiple times during the season. Each actual application is recorded separately.")
            }
        }
    }
}

@Composable
private fun HelpCard(title: String, content: @Composable () -> Unit) {
    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, color = LocalVineColors.current.textPrimary,
                modifier = Modifier.semantics { heading() })
            content()
        }
    }
}

@Composable
private fun HelpDefinition(title: String, explanation: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title, fontWeight = FontWeight.SemiBold, color = LocalVineColors.current.textPrimary)
        HelpText(explanation)
    }
}

@Composable
private fun HelpText(markdown: String) {
    val text = buildAnnotatedString {
        markdown.split("**").forEachIndexed { index, part ->
            if (index % 2 == 1) withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(part) }
            else append(part)
        }
    }
    Text(text, style = MaterialTheme.typography.bodyLarge, color = LocalVineColors.current.textPrimary)
}
