package com.rork.vinetrack.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import com.rork.vinetrack.R

/**
 * Offline transparent tractor-and-vines artwork shared in appearance with iOS.
 * Decorative only: no network request or change to Trip behaviour.
 */
@Composable
fun TripStartHeroArtwork(modifier: Modifier = Modifier) {
    Image(
        painter = painterResource(id = R.drawable.trip_start_hero),
        contentDescription = null,
        modifier = modifier.fillMaxWidth(),
        contentScale = ContentScale.Fit,
    )
}
