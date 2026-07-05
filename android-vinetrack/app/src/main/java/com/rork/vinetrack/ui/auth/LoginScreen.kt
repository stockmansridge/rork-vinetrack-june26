package com.rork.vinetrack.ui.auth

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Eco
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.foundation.Image
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.SpanStyle
import androidx.compose.foundation.border
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.BuildConfig
import com.rork.vinetrack.R
import com.rork.vinetrack.data.AppConfig
import com.rork.vinetrack.ui.AuthFormState
import com.rork.vinetrack.ui.components.LoginVineyardBackground
import com.rork.vinetrack.ui.theme.VineColors

private enum class Mode(val label: String) { SignIn("Sign In"), SignUp("Sign Up") }

@Composable
fun LoginScreen(
    state: AuthFormState,
    onSignIn: (String, String) -> Unit,
    onSignUp: (String, String, String) -> Unit,
    onGoogleSignIn: (android.content.Context) -> Unit,
    onForgotPassword: (String, (Boolean) -> Unit) -> Unit,
    onResetPassword: (String, String, String, (Boolean, String?) -> Unit) -> Unit,
) {
    val activityContext = LocalContext.current
    var mode by remember { mutableStateOf(Mode.SignIn) }
    var name by remember { mutableStateOf("") }
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var showPassword by remember { mutableStateOf(false) }
    var showReset by remember { mutableStateOf(false) }

    Box(modifier = Modifier.fillMaxSize()) {
        LoginVineyardBackground()
        BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
            val compact = maxHeight < 760.dp
            val minH = maxHeight
            val spacing = if (compact) 8.dp else 12.dp
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .heightIn(min = minH)
                    .padding(horizontal = 18.dp, vertical = if (compact) 12.dp else 22.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(spacing),
                ) {
                    // Logo mark (shared VineTrack logo, iOS parity)
                    val logoSize = if (compact) 84.dp else 102.dp
                    Image(
                        painter = painterResource(R.drawable.vinetrack_logo),
                        contentDescription = "VineTrack",
                        contentScale = ContentScale.Fit,
                        modifier = Modifier
                            .shadow(14.dp, RoundedCornerShape(if (compact) 22.dp else 26.dp), clip = false)
                            .size(logoSize)
                            .clip(RoundedCornerShape(if (compact) 22.dp else 26.dp))
                            .border(1.2.dp, Color.White.copy(alpha = 0.24f), RoundedCornerShape(if (compact) 22.dp else 26.dp)),
                    )

                    BrandWordmark(size = if (compact) 38.sp else 48.sp)

                    Text(
                        "Built by viticulturists to manage\nvineyard work, row by row.",
                        color = Color.White.copy(alpha = 0.94f),
                        textAlign = TextAlign.Center,
                        fontSize = if (compact) 14.sp else 15.sp,
                        fontWeight = FontWeight.Medium,
                    )

                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
                        FeatureChip("GPS Pins", Icons.Filled.LocationOn, Modifier.weight(1f))
                        FeatureChip("Row Tracking", Icons.Filled.FilterList, Modifier.weight(1f))
                        FeatureChip("Spray Records", Icons.Filled.Eco, Modifier.weight(1f))
                    }

                    // Mode toggle
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .shadow(16.dp, RoundedCornerShape(20.dp), clip = false)
                            .clip(RoundedCornerShape(20.dp))
                            .background(Color.White.copy(alpha = 0.94f))
                            .border(1.dp, Color.White.copy(alpha = 0.55f), RoundedCornerShape(20.dp))
                            .padding(5.dp),
                        horizontalArrangement = Arrangement.spacedBy(0.dp),
                    ) {
                        Mode.entries.forEach { m ->
                            val selected = m == mode
                            Box(
                                modifier = Modifier
                                    .weight(1f)
                                    .height(42.dp)
                                    .clip(RoundedCornerShape(15.dp))
                                    .background(if (selected) VineColors.LoginPickerActive else Color.Transparent)
                                    .clickable { mode = m },
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(
                                    m.label,
                                    fontWeight = FontWeight.Bold,
                                    color = if (selected) Color.White else Color(0xFF053A1A),
                                )
                            }
                        }
                    }

                    // Form card
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .shadow(18.dp, RoundedCornerShape(22.dp), clip = false)
                            .clip(RoundedCornerShape(22.dp))
                            .background(Color.White.copy(alpha = 0.96f))
                            .border(1.dp, Color.White.copy(alpha = 0.65f), RoundedCornerShape(22.dp))
                            .padding(if (compact) 10.dp else 12.dp),
                        verticalArrangement = Arrangement.spacedBy(if (compact) 8.dp else 10.dp),
                    ) {
                        if (mode == Mode.SignUp) {
                            LoginField(name, { name = it }, "Name", Icons.Filled.Person)
                        }
                        LoginField(email, { email = it }, "Email", Icons.Filled.Email, keyboardType = KeyboardType.Email)
                        LoginField(
                            password, { password = it }, "Password", Icons.Filled.Lock,
                            keyboardType = KeyboardType.Password,
                            isSecure = true,
                            showSecure = showPassword,
                            onToggleSecure = { showPassword = !showPassword },
                        )
                    }

                    // Action button
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(48.dp)
                            .shadow(14.dp, RoundedCornerShape(15.dp), clip = false)
                            .clip(RoundedCornerShape(15.dp))
                            .background(VineColors.Primary)
                            .clickable(enabled = !state.isLoading && canSubmit(mode, name, email, password)) {
                                when (mode) {
                                    Mode.SignIn -> onSignIn(email, password)
                                    Mode.SignUp -> onSignUp(name, email, password)
                                }
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        if (state.isLoading) {
                            CircularProgressIndicator(color = Color.White, modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
                        } else {
                            Text(
                                if (mode == Mode.SignIn) "Sign In" else "Create Account",
                                color = Color.White, fontWeight = FontWeight.Bold, fontSize = 17.sp,
                            )
                        }
                    }

                    // iOS parity: the "or" divider + federated sign-in button sit
                    // directly below the primary action, above the footer links —
                    // the same slot Sign in with Apple occupies on iOS.
                    if (AppConfig.isGoogleSignInConfigured) {
                        OrDivider()
                        GoogleSignInButton(
                            enabled = !state.isLoading,
                            onClick = { onGoogleSignIn(activityContext) },
                        )
                    }

                    if (mode == Mode.SignIn) {
                        TextButton(onClick = { showReset = true }) {
                            Text("Forgot password?", color = Color(0xFFEFEBB8), fontWeight = FontWeight.Medium)
                        }
                    }

                    state.error?.let { message ->
                        Text(
                            message,
                            color = Color.White,
                            textAlign = TextAlign.Center,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier
                                .clip(RoundedCornerShape(14.dp))
                                .background(VineColors.Destructive.copy(alpha = 0.85f))
                                .padding(horizontal = 12.dp, vertical = 8.dp),
                        )
                    }
                    if (BuildConfig.DEBUG) {
                        DebugConfigPanel()
                    }
                }
            }
        }
    }

    if (showReset) {
        PasswordResetSheet(
            initialEmail = email,
            onSendCode = onForgotPassword,
            onResetPassword = onResetPassword,
            onDismiss = { showReset = false },
            onCompleted = { resetEmail, newPassword ->
                email = resetEmail
                password = newPassword
                showReset = false
            },
        )
    }
}

@Composable
private fun OrDivider() {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.weight(1f).height(1.dp).background(Color.White.copy(alpha = 0.42f)))
        Text("or", color = Color.White.copy(alpha = 0.9f), fontSize = 14.sp, fontWeight = FontWeight.Medium)
        Box(Modifier.weight(1f).height(1.dp).background(Color.White.copy(alpha = 0.42f)))
    }
}

/**
 * "Continue with Google" — Google-branded light button (white surface,
 * multicolour G, dark label), matching the prominence and shape of the
 * primary action buttons on this screen and the iOS Apple sign-in button.
 */
@Composable
private fun GoogleSignInButton(enabled: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(48.dp)
            .shadow(14.dp, RoundedCornerShape(15.dp), clip = false)
            .clip(RoundedCornerShape(15.dp))
            .background(if (enabled) Color.White else Color.White.copy(alpha = 0.7f))
            .clickable(enabled = enabled) { onClick() },
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Image(
            painter = painterResource(R.drawable.ic_google_g),
            contentDescription = null,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(10.dp))
        Text(
            "Continue with Google",
            color = Color(0xFF1F1F1F),
            fontWeight = FontWeight.SemiBold,
            fontSize = 16.sp,
        )
    }
}

private enum class ResetStep { EnterEmail, EnterCode, Completed }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PasswordResetSheet(
    initialEmail: String,
    onSendCode: (String, (Boolean) -> Unit) -> Unit,
    onResetPassword: (String, String, String, (Boolean, String?) -> Unit) -> Unit,
    onDismiss: () -> Unit,
    onCompleted: (String, String) -> Unit,
) {
    var step by remember { mutableStateOf(ResetStep.EnterEmail) }
    var email by remember { mutableStateOf(initialEmail) }
    var pin by remember { mutableStateOf("") }
    var newPassword by remember { mutableStateOf("") }
    var confirmPassword by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var info by remember { mutableStateOf<String?>(null) }
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)

    val canSubmit = pin.trim().length >= 4 && newPassword.length >= 8 && newPassword == confirmPassword

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = Color.White) {
        Column(
            modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(horizontal = 22.dp).padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("Reset Password", fontSize = 22.sp, fontWeight = FontWeight.Bold, color = Color(0xFF053A1A))

            when (step) {
                ResetStep.EnterEmail -> {
                    Text("Step 1 — we'll email you a 6-digit code. No links, codes only.",
                        fontSize = 13.sp, color = Color(0xFF055224).copy(alpha = 0.8f))
                    ResetField(email, { email = it }, "Email", Icons.Filled.Email, KeyboardType.Email)
                    ResetPrimaryButton(if (working) "Sending…" else "Send Code", enabled = !working && email.isNotBlank()) {
                        working = true; error = null
                        onSendCode(email.trim()) { ok ->
                            working = false
                            if (ok) { step = ResetStep.EnterCode; info = "Code sent to ${email.trim()}." }
                            else error = "Couldn't send a code. Check the email and try again."
                        }
                    }
                }
                ResetStep.EnterCode -> {
                    info?.let { Text(it, fontSize = 13.sp, color = VineColors.LeafGreen, fontWeight = FontWeight.Medium) }
                    Text("Step 2 — enter the code and your new password (at least 8 characters).",
                        fontSize = 13.sp, color = Color(0xFF055224).copy(alpha = 0.8f))
                    ResetField(pin, { pin = it }, "6-digit code", Icons.Filled.Lock, KeyboardType.Number)
                    ResetField(newPassword, { newPassword = it }, "New password", Icons.Filled.Lock, KeyboardType.Password, isSecure = true)
                    ResetField(confirmPassword, { confirmPassword = it }, "Confirm new password", Icons.Filled.Lock, KeyboardType.Password, isSecure = true)
                    ResetPrimaryButton(if (working) "Updating…" else "Update Password", enabled = !working && canSubmit) {
                        working = true; error = null
                        onResetPassword(email.trim(), pin.trim(), newPassword) { ok, message ->
                            working = false
                            if (ok) step = ResetStep.Completed else error = message ?: "That code didn't work."
                        }
                    }
                    TextButton(onClick = {
                        working = true; error = null
                        onSendCode(email.trim()) { ok -> working = false; if (!ok) error = "Couldn't resend the code." }
                    }, enabled = !working) { Text("Resend code") }
                }
                ResetStep.Completed -> {
                    Text("Password updated. You can now sign in with your new password.",
                        fontSize = 14.sp, color = VineColors.LeafGreen, fontWeight = FontWeight.Medium)
                    ResetPrimaryButton("Back to Sign In", enabled = true) {
                        onCompleted(email.trim(), newPassword)
                    }
                }
            }

            error?.let {
                Text(it, fontSize = 13.sp, color = VineColors.Destructive, fontWeight = FontWeight.Medium)
            }
        }
    }
}

@Composable
private fun ResetField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    icon: ImageVector,
    keyboardType: KeyboardType,
    isSecure: Boolean = false,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        leadingIcon = { Icon(icon, contentDescription = null, tint = Color(0xFF055224)) },
        singleLine = true,
        visualTransformation = if (isSecure) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
        colors = loginFieldColors(),
        modifier = Modifier.fillMaxWidth(),
    )
}

/**
 * Explicit light-surface colors for the login/reset text fields.
 * These fields always sit on a white card, so they must not inherit
 * dark-theme defaults (white text on white = unreadable).
 */
@Composable
private fun loginFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Color(0xFF111111),
    unfocusedTextColor = Color(0xFF111111),
    disabledTextColor = Color(0xFF111111).copy(alpha = 0.6f),
    cursorColor = VineColors.Primary,
    focusedContainerColor = Color.Transparent,
    unfocusedContainerColor = Color.Transparent,
    focusedBorderColor = VineColors.Primary,
    unfocusedBorderColor = Color(0xFF055224).copy(alpha = 0.35f),
    focusedLabelColor = VineColors.Primary,
    unfocusedLabelColor = Color(0xFF055224).copy(alpha = 0.75f),
    focusedPlaceholderColor = Color(0xFF111111).copy(alpha = 0.4f),
    unfocusedPlaceholderColor = Color(0xFF111111).copy(alpha = 0.4f),
    selectionColors = androidx.compose.foundation.text.selection.TextSelectionColors(
        handleColor = VineColors.Primary,
        backgroundColor = VineColors.Primary.copy(alpha = 0.3f),
    ),
)

@Composable
private fun ResetPrimaryButton(label: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(48.dp)
            .clip(RoundedCornerShape(15.dp))
            .background(if (enabled) VineColors.Primary else VineColors.Primary.copy(alpha = 0.5f))
            .clickable(enabled = enabled) { onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp)
    }
}

@Composable
private fun BrandWordmark(size: androidx.compose.ui.unit.TextUnit) {
    Text(
        buildAnnotatedString {
            withStyle(SpanStyle(color = Color.White)) { append("Vine") }
            withStyle(SpanStyle(color = VineColors.BrandTrack)) { append("Track") }
        },
        fontSize = size,
        fontWeight = FontWeight.Black,
        maxLines = 1,
    )
}

@Composable
private fun DebugConfigPanel() {
    val d = remember { AppConfig.diagnostics() }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color.Black.copy(alpha = 0.55f))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            "DEBUG · Supabase config",
            color = Color(0xFFEFEBB8),
            fontWeight = FontWeight.Bold,
            fontSize = 12.sp,
        )
        DebugRow("Supabase URL present", d.supabaseUrlPresent.toString())
        DebugRow("Supabase URL", d.supabaseUrl)
        DebugRow("Config.kt key present", d.rorkConfigAnonKeyPresent.toString())
        DebugRow("Config.kt key length", d.rorkConfigAnonKeyLength.toString())
        DebugRow("BuildConfig key present", d.buildConfigAnonKeyPresent.toString())
        DebugRow("BuildConfig key length", d.buildConfigAnonKeyLength.toString())
        DebugRow("Fallback key present", d.fallbackAnonKeyPresent.toString())
        DebugRow("Fallback key length", d.fallbackAnonKeyLength.toString())
        DebugRow("Final key present", d.finalAnonKeyPresent.toString())
        DebugRow("Final key length", d.finalAnonKeyLength.toString())
    }
}

@Composable
private fun DebugRow(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, color = Color.White.copy(alpha = 0.85f), fontSize = 11.sp)
        Text(
            value,
            color = Color.White,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            maxLines = 1,
        )
    }
}

private fun canSubmit(mode: Mode, name: String, email: String, password: String): Boolean {
    val base = email.isNotBlank() && password.isNotBlank()
    return if (mode == Mode.SignUp) base && name.isNotBlank() else base
}

@Composable
private fun FeatureChip(title: String, icon: ImageVector, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .height(34.dp)
            .clip(CircleShape)
            .background(Color.White.copy(alpha = 0.10f))
            .border(1.dp, Color.White.copy(alpha = 0.22f), CircleShape)
            .padding(horizontal = 7.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(4.dp))
        Text(
            title,
            color = Color.White,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            maxLines = 1,
        )
    }
}

@Composable
private fun LoginField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    keyboardType: KeyboardType = KeyboardType.Text,
    isSecure: Boolean = false,
    showSecure: Boolean = false,
    onToggleSecure: (() -> Unit)? = null,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        leadingIcon = { Icon(icon, contentDescription = null, tint = Color(0xFF055224)) },
        trailingIcon = if (isSecure && onToggleSecure != null) {
            {
                IconButton(onClick = onToggleSecure) {
                    Icon(
                        if (showSecure) Icons.Filled.VisibilityOff else Icons.Filled.Visibility,
                        contentDescription = null,
                        tint = Color(0xFF055224).copy(alpha = 0.7f),
                    )
                }
            }
        } else null,
        singleLine = true,
        visualTransformation = if (isSecure && !showSecure) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
        colors = loginFieldColors(),
        modifier = Modifier.fillMaxWidth(),
    )
}
