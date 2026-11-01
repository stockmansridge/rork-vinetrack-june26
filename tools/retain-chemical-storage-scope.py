from pathlib import Path

root = Path(__file__).resolve().parents[1]
p = root / 'android-vinetrack/app/src/main/java/com/rork/vinetrack/data/auth/CleanExitCacheContract.kt'
s = p.read_text()
replacements = {
    'chemical("CHEMICAL_ORIGINAL_ACCOUNT_MISMATCH") { check(sameIdentity(scope[0], original)) }': 'chemical("CHEMICAL_ORIGINAL_ACCOUNT_MISMATCH") { check(scope[0] == original) }',
    '            identityKey(scope[1])': '            scope[1]',
    'check(rows.map { identityKey(it.id) }.distinct().size == rows.size)': 'check(rows.map { it.id }.distinct().size == rows.size)',
    'row.id == row.id.trim() && sameIdentity(row.vineyardId, scope[1])': 'row.id == row.id.trim() && row.vineyardId == scope[1]',
}
for old, new in replacements.items():
    assert s.count(old) == 1, old
    s = s.replace(old, new)
p.write_text(s)

p = root / 'android-vinetrack/app/src/test/java/com/rork/vinetrack/data/auth/SavedChemicalRecoveryContractTest.kt'
s = p.read_text()
old = '''    @Test fun uuidCaseDoesNotCreateADifferentAccountOrVineyard() {
        val input = values(row(vineyard.uppercase()), "${owner.uppercase()}|$vineyard")
        val before = input.toMap()
        assertEquals(setOf(vineyard), recover(input)); assertEquals(before, input)
    }
    @Test fun uppercaseKeyScopeReturnsCanonicalMembershipIdentity() {
        assertEquals(setOf(vineyard), recover(values(row(), "$owner|${vineyard.uppercase()}")))
    }'''
new = '''    @Test fun storageAccountNamespaceIsNotSilentlyRedirected() {
        // The store's load/save keys are exact. Do not admit an alias namespace
        // without separately proving that ordinary reads address that namespace.
        denied("CHEMICAL_ORIGINAL_ACCOUNT_MISMATCH") {
            recover(values(row(), "${owner.uppercase()}|$vineyard"))
        }
    }
    @Test fun storageVineyardNamespaceRemainsExact() {
        denied("CHEMICAL_RECORD_SCOPE") {
            recover(values(row(), "$owner|${vineyard.uppercase()}"))
        }
    }'''
assert s.count(old) == 1
s = s.replace(old, new)
s = s.replace('fun duplicateIdsAndUuidAliasesAreRefused()', 'fun duplicateRecordIdsAreRefused()')
s = s.replace('val alias = JsonObject(row() + ("id" to JsonPrimitive(id.uppercase())))', 'val alias = row()')
p.write_text(s)
print('Kept original account, vineyard and exact storage-key checks unchanged.')
