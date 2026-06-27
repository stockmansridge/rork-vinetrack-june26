package com.rork.vinetrack.ui.screens

import com.rork.vinetrack.R

/**
 * App-bundled E-L reference photos, mirroring the 21 imagesets iOS ships in
 * `Assets.xcassets` (`GrowthStage.imageName`). These high-res images install
 * with the app and live on the device, so the picker/confirmation flow always
 * has imagery even before a vineyard uploads its own custom photos.
 *
 * Resolution order matches iOS `resolvedELStageImage(for:)`: a vineyard's custom
 * uploaded image wins; otherwise this bundled drawable is the fallback.
 */
object GrowthStageBundledImages {
    private val byCode: Map<String, Int> = mapOf(
        "EL1" to R.drawable.el1,
        "EL2" to R.drawable.el2,
        "EL3" to R.drawable.el3,
        "EL4" to R.drawable.el4,
        "EL7" to R.drawable.el7,
        "EL9" to R.drawable.el9,
        "EL11" to R.drawable.el11,
        "EL12" to R.drawable.el12,
        "EL17" to R.drawable.el17,
        "EL19" to R.drawable.el19,
        "EL21" to R.drawable.el21,
        "EL23" to R.drawable.el23,
        "EL25" to R.drawable.el25,
        "EL27" to R.drawable.el27,
        "EL29" to R.drawable.el29,
        "EL31" to R.drawable.el31,
        "EL33" to R.drawable.el33,
        "EL35" to R.drawable.el35,
        "EL38" to R.drawable.el38,
        "EL41" to R.drawable.el41,
        "EL47" to R.drawable.el47,
    )

    /** Bundled drawable resource id for an E-L code, or null when none ships. */
    fun resFor(code: String?): Int? = code?.let { byCode[it] }

    /** True when this E-L code has either a bundled photo (custom uploads are checked separately). */
    fun hasBundled(code: String?): Boolean = resFor(code) != null
}
