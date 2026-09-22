package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.WorkTaskEditorLifecycle
import com.rork.vinetrack.data.model.WorkTaskEditorSaveOperation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkTaskEditorLifecycleTest {
    @Test fun `new task starts unsaved with children unavailable`() {
        val lifecycle = WorkTaskEditorLifecycle()
        assertEquals("Save", lifecycle.saveTitle)
        assertEquals(WorkTaskEditorSaveOperation.CREATE, lifecycle.saveOperation)
        assertFalse(lifecycle.childControlsEnabled)
        assertFalse(lifecycle.shouldCloseAfterAcceptedSave())
    }

    @Test fun `first save retains minted id and keeps editor open`() {
        val beforeSave = WorkTaskEditorLifecycle()
        val afterSave = beforeSave.acceptingFirstSave("stable-parent-id")

        assertEquals("stable-parent-id", afterSave.persistedTaskId)
        assertEquals("Save & Close", afterSave.saveTitle)
        assertEquals(WorkTaskEditorSaveOperation.UPDATE, afterSave.saveOperation)
        assertTrue(afterSave.childControlsEnabled)
        assertFalse(beforeSave.shouldCloseAfterAcceptedSave())
    }

    @Test fun `later save targets same parent and closes`() {
        val lifecycle = WorkTaskEditorLifecycle().acceptingFirstSave("stable-parent-id")
        val afterMetadataEdit = lifecycle.copy()

        assertEquals("stable-parent-id", afterMetadataEdit.persistedTaskId)
        assertTrue(afterMetadataEdit.shouldCloseAfterAcceptedSave())
    }

    @Test fun `existing task opens directly in persisted mode`() {
        val lifecycle = WorkTaskEditorLifecycle("existing-id")
        assertTrue(lifecycle.childControlsEnabled)
        assertEquals("Save & Close", lifecycle.saveTitle)
    }

    @Test fun `rejected first save relocks child controls`() {
        val rejected = WorkTaskEditorLifecycle()
            .acceptingFirstSave("optimistic-id")
            .rejectingFirstSave()
        assertEquals(null, rejected.persistedTaskId)
        assertFalse(rejected.childControlsEnabled)
    }
}
