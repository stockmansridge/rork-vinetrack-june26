package com.rork.vinetrack.data.auth

import org.junit.Assert.*
import org.junit.Test

class RecoveryStorageReportTest {
    private fun report(vararg entries: RecoveryStorageReport.Entry) = RecoveryStorageReport("3.1.9", 123,
        listOf(RecoveryStorageReport.Root(RecoveryStorageReport.Area.FILES,
            RecoveryStorageReport.Status.PRESENT, entries.size, entries.toList())))

    @Test fun safeSummaryNeverIncludesUnknownNames() {
        val value = report(RecoveryStorageReport.Entry("private_customer_name", RecoveryStorageReport.Kind.REGULAR_FILE, 7))
        assertFalse(value.safeSummary().contains("private_customer_name"))
        assertTrue(value.safeSummary().contains("UNRECOGNISED_PATH/REGULAR_FILE: 1"))
        assertTrue(value.reviewedText().contains("files/private_customer_name"))
    }
    @Test fun allEntriesAreReportedInsteadOfOnlyFirstFailure() {
        val value = report(RecoveryStorageReport.Entry("first", RecoveryStorageReport.Kind.REGULAR_FILE, 1),
            RecoveryStorageReport.Entry("second", RecoveryStorageReport.Kind.DIRECTORY))
        assertTrue(value.reviewedText().contains("files/first"))
        assertTrue(value.reviewedText().contains("files/second"))
        assertTrue(value.reviewedText().contains("listed=2"))
    }
    @Test fun filenamesCannotForgeNewReportLines() {
        val text = RecoveryStorageReport.quoted("name\nSIGNED_IN\u202e\"\\")
        assertFalse(text.contains('\n')); assertFalse(text.contains('\u202e'))
        assertTrue(text.contains("\\u000a")); assertTrue(text.contains("\\u202e"))
        assertTrue(text.contains("\\\"")); assertTrue(text.contains("\\\\"))
    }
    @Test fun categoriesAreExactNamesNotPrefixes() {
        val area = RecoveryStorageReport.Area.FILES
        assertEquals(RecoveryStorageReport.Category.PROFILE_VERIFIER_MARKER, RecoveryStorageReport.category(area, "profileInstalled"))
        assertEquals(RecoveryStorageReport.Category.UNRECOGNISED_PATH, RecoveryStorageReport.category(area, "profileInstalled.bak"))
        assertEquals(RecoveryStorageReport.Category.UNRECOGNISED_PATH, RecoveryStorageReport.category(area, "vineyard_logos-private"))
    }
    @Test fun truncationIsExplicitAndDoesNotClaimCompleteListing() {
        val value = RecoveryStorageReport("test", 1, listOf(RecoveryStorageReport.Root(RecoveryStorageReport.Area.FILES,
            RecoveryStorageReport.Status.PRESENT, 257, listOf(RecoveryStorageReport.Entry("entry", RecoveryStorageReport.Kind.DIRECTORY)))))
        assertTrue(value.reviewedText().contains("total=257; listed=1; truncated=true"))
        assertTrue(value.safeSummary().contains("truncated=true"))
    }
    @Test fun absentUnreadableAndUnsafeRootsStayDistinct() {
        val value = RecoveryStorageReport("test", 1, listOf(
            RecoveryStorageReport.Root(RecoveryStorageReport.Area.FILES, RecoveryStorageReport.Status.UNREADABLE),
            RecoveryStorageReport.Root(RecoveryStorageReport.Area.PREFERENCES, RecoveryStorageReport.Status.LINK_OR_ALIAS),
            RecoveryStorageReport.Root(RecoveryStorageReport.Area.LEGACY_CAMERA, RecoveryStorageReport.Status.ABSENT)))
        assertTrue(value.reviewedText().contains("files/: UNREADABLE"))
        assertTrue(value.reviewedText().contains("shared_prefs/: LINK_OR_ALIAS"))
        assertTrue(value.reviewedText().contains("cache/camera-captures/: ABSENT"))
    }
    @Test fun labelsDoNotRepresentContentApproval() {
        val value = report(RecoveryStorageReport.Entry("profileInstalled", RecoveryStorageReport.Kind.REGULAR_FILE, 999))
        assertTrue(value.reviewedText().contains("they do not validate contents, ownership or safety"))
        assertTrue(value.reviewedText().contains("No files were changed and no access was granted"))
    }
    @Test fun defaultSummaryDoesNotDisclosePreferenceNames() {
        val value = RecoveryStorageReport("test", 1, listOf(RecoveryStorageReport.Root(RecoveryStorageReport.Area.PREFERENCES,
            RecoveryStorageReport.Status.PRESENT, 1, listOf(RecoveryStorageReport.Entry("secret_account.xml", RecoveryStorageReport.Kind.REGULAR_FILE, 99)))))
        assertFalse(value.safeSummary().contains("secret_account"))
        assertTrue(value.reviewedText().contains("shared_prefs/secret_account.xml"))
    }
}
