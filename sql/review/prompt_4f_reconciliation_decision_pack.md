# Prompt 4F reconciliation decision pack

Prepared only from Jonathan's returned Prompt 4F export. No new database audit or SQL execution was performed.

## Scope and controls

- The export's **155 vineyard records are the total vineyard inventory** included by Prompt 4F.
- **40 vineyards** contain the **1,603 non-deleted pins** (1,459 active and 144 completed); 115 inventory vineyards contain no non-deleted pins.
- The **82 approved repairs remain preserved and exactly verified**. This pack does not propose rerunning, changing or rolling them back.
- Current polygon structure and containment are evidence only. They do not establish correct physical or historical boundaries.
- No UPDATE or rollback package is permitted until Jonathan reviews the relevant records and confirms the intended correction.
- Historical row/path/side/facing recovery, mobile corrections and Portal adoption remain open and separate.

## 1. Missing blocks — 14 vineyards, 692 pins

All 14 have zero active blocks, zero deleted blocks, zero valid polygons and zero excluded polygons in the export. The database therefore contains **no deleted block definitions or direct migration evidence** for any of them. Unmigrated definitions cannot be inferred from this export.

| Vineyard | Vineyard ID | Non-deleted pins | Existing deleted/migrated-definition evidence |
|---|---|---:|---|
| bffb x cbcdv | `08ced494-1802-448d-b854-e75892d23770` | 55 | No active or deleted block records; no migration evidence in export |
| bmkvjjvjv | `81103160-db06-469f-8497-44da651c666b` | 60 | No active or deleted block records; no migration evidence in export |
| ghmfukfkfy | `2e4508cd-af04-4733-9a55-8446338cd944` | 57 | No active or deleted block records; no migration evidence in export |
| hrzzhrzhfzfjgx | `bae98681-0ac4-4f19-b004-3777dc11d15c` | 56 | No active or deleted block records; no migration evidence in export |
| itxicyixtx | `e97bbdd4-a2f1-43a5-9958-2aa8ebb5c558` | 59 | No active or deleted block records; no migration evidence in export |
| jffhjffgnvf | `0a3e3af5-7f0b-4b2a-a3da-ca754a125644` | 55 | No active or deleted block records; no migration evidence in export |
| jgfjgj | `36f417fa-b343-4e5a-a0dc-224c229792b9` | 57 | No active or deleted block records; no migration evidence in export |
| jtictcit | `f658aff6-1ac7-49c5-a89e-75aa6a4932d3` | 55 | No active or deleted block records; no migration evidence in export |
| jzrjtxjxtx | `eed366fc-a6c3-406c-852e-5b4312fdbf9b` | 60 | No active or deleted block records; no migration evidence in export |
| Le Bonheur Wine Estate | `f40a5246-9c4b-4022-a65b-ff1d4a02ca35` | 1 | No active or deleted block records; no migration evidence in export |
| Sunnyside Farm | `bc34f977-6bd7-4229-b44b-c5ab7b5da8ab` | 6 | No active or deleted block records; no migration evidence in export |
| vyivttvivtu | `7d968f6d-2b5f-4595-a7b5-86290ae77467` | 57 | No active or deleted block records; no migration evidence in export |
| yidfiyyhchc | `fb0f0844-f675-4abf-86b5-177eacf5de68` | 59 | No active or deleted block records; no migration evidence in export |
| yifitduxtuxt | `921d6b01-314f-40e2-adf3-abf91fbbd59b` | 55 | No active or deleted block records; no migration evidence in export |

**Decision required from Jonathan:** for each vineyard, confirm either (a) it intentionally has no blocks, or (b) supply the authoritative block identity, name, owning vineyard, lifecycle state and ordered boundary vertices. If it was migrated, supply the source and destination vineyard/block IDs and whether the 692 pins belong to that destination. Names alone are not sufficient.

## 2. Incomplete boundaries — six active blocks

`vertex_count` and `distinct_vertex_count` are null for all six because their current boundary JSON is empty or structurally unusable. Five contain an empty array; Tohme Valley's Scarlet contains one coordinate only. None currently has an assigned or contained non-deleted pin. One exception at Liebichs Vineyard is affected because its candidate evaluation excluded the malformed block.

| Vineyard (ID) | Block (ID) | Current boundary evidence | Assigned pins | Currently contained | Exception records affected |
|---|---|---|---:|---:|---:|
| Cape May Vineyard (`6a5582ec-debf-4b12-8a56-477753194c11`) | Sandman Pinot Noir (`f79d52a6-829a-4414-bccd-286ca2227cae`) | Empty array | 0 | 0 | 0 |
| Frauengarten (`9324bafb-4f3f-4efe-85e8-56e5db590d83`) | Frauengarten (`19c3c9d9-8221-44de-811d-a6ebee7208d4`) | Empty array | 0 | 0 | 0 |
| Liebichs Vineyard (`c2c2d3db-34d0-4167-a3ef-a3c4cb35b6f0`) | LB - Grafted Shiraz (`5af8fe37-667a-46bf-b5ef-468e7da4a8f6`) | Empty array | 0 | 0 | 1 conflict |
| Rotherwood Vineyard (`15f02e98-8768-4aa9-8ce1-cdfd60c23ada`) | 12 (`08955806-723c-4ade-a14b-4f5262b994e3`) | Empty array | 0 | 0 | 0 |
| Tamburlaine Pokolbin (`2f7e3b19-e958-4227-af95-eb97822ad275`) | 2 (`8b013b37-8de2-40a0-aaf8-05b536f3fe48`) | Empty array | 0 | 0 | 0 |
| Tohme Valley (`40c08ccc-1925-4b71-ba30-8916e370c9ba`) | Scarlet (`0769b4fa-e6fc-4fe2-b32b-85b63ebbd581`) | One point: 33.80715812324916, 35.94918226642242 | 0 | 0 | 0 |

**Decision required from Jonathan:** confirm whether each block is a genuine current block. For every block retained, supply its authoritative ordered boundary vertices and confirm its vineyard ownership. If a block is obsolete or migrated, supply its intended lifecycle state and authoritative successor ID; do not fabricate a polygon to make pins fit.

## 3. Active blocks under archived vineyards — 67 blocks

The only direct archival evidence in this export is each vineyard's non-null deletion timestamp. It contains no reason, operator decision, migration mapping or proof that any corresponding similarly named current vineyard is a successor. Active child blocks do not by themselves prove that the parent vineyard should be restored.

### Bellview — `5885b584-8c81-4c81-ad78-0ef65dbcf93f`

- Vineyard deleted at `2026-08-31T06:57:44.191119+00:00`.
- 22 active blocks; 0 assigned pins and 0 currently contained pins.
- Blocks: Block 1 (`e25e5f39-d034-46d7-a3bd-54fa9c659c06`); Block 10 (`cbd73bc1-9820-41c7-b303-3c8d5b4fb18c`); Block 11 (`fe4db298-325b-4a08-924e-9aaa61543485`); Block 12 (`bf0c7b51-a71a-4f36-bb22-55f5126f20aa`); Block 13 (`71e597e9-534e-40a6-9755-5ff3eef86baa`); Block 14 (`78f6b6f9-cf09-4cc2-8b27-1f75d5211bd4`); Block 15 (`f6e47dce-9e29-4044-bcb1-4aa65c7d94ae`); Block 16 (cl76) (`044eb491-9fae-4c1f-a516-c795b0b3c7ba`); Block 16 Chard (`06fa4ad1-066a-411c-8e14-b53d9ee1de8e`); Block 18 (`9e3a00dd-25cb-4054-89d9-981bf98ead60`); Block 2 (`cd59eef5-b19b-43d5-85bc-9844e28146f9`); Block 3 (`fc207932-0bb2-4cd0-8a10-fe874b680d59`); Block 4 (`4a533011-0a45-480e-8718-44eadacc35de`); Block 5 Chard (`f4233791-1379-412e-93de-65bf85d248cf`); Block 5 PG (`21f805c6-a751-41c1-9834-42ae356d3895`); Block 5 Sav Blanc (`0a554980-9aca-4bfc-8fb4-01539c5eb3a8`); Block 6 (`75aa44a3-f32d-4e39-924c-d457abf15c00`); Block 7 Cab Sav (`ccc11cac-a505-424e-8612-2e5c463d5a3e`); Block 7 Merlot (`f7a89bad-cda6-4c90-a604-98e304bfb1c6`); Block 8 (`7d228f02-af45-405b-a551-6e4c878a6df9`); Block 9 (`6c3d252b-0742-43eb-a17d-239ec09ec4de`); Block17 (`39043ef0-2668-49bc-9fe6-86c9e7839440`).

### Borenore — `526ba356-762d-4288-a416-a762a1e86bc4`

- Vineyard deleted at `2026-08-31T06:57:44.191119+00:00`.
- 44 active blocks; 0 assigned pins and 0 currently contained pins.
- Blocks: Block 10 Cabernet Franc (`686c089a-1960-45a8-a2a2-3724255eee24`); Block 10 Pinot Noir (`cb91350c-e815-44a3-8529-ab344c4a9fde`); Block 10 Sauvignon Blanc (`c4b2999c-e0f5-420c-a36c-bac4b354f466`); Block 10 Shiraz (`69c9ba7a-e540-4664-b67f-c2c258aa9465`); Block 11 Sauvignon Blanc (`7e45ce15-4b02-44ad-9720-f38d76919c99`); Block 11 Semillon (`6982a531-5b5c-4b25-b99c-fd0a272c5f08`); Block 12 Merlot (`20eed20f-bc60-4274-948d-ffeca8d49c13`); Block 12 Petit Verdot (`266b544e-87a4-438a-aa9b-1c582221074b`); Block 12 Shiraz (`b0362f99-f34c-4154-91f7-607a8921489a`); Block 14 Grenache (`370acdbe-fc5a-4327-bb75-300a60c97ba7`); Block 14 Malbec (`ccafc7c1-4cc0-4309-b579-69aca879f612`); Block 14 Riesling (`138d9d09-5606-4899-a518-dc777f2f7c6f`); Block 14 Shiraz (`3a9c9f91-4a35-44b9-9dbf-8d3817139278`); Block 15 Chardonnay (`aa8e27a7-91f0-49d8-b7e5-63d994ddd1d0`); Block 15 Riesling (`ee0f9310-ee55-40cc-a390-38223ccd5d91`); Block 15 Shiraz (`62099844-5002-419a-8df1-fb23b69b8e34`); Block 2A Malbec (`491f3ef0-46df-4706-bc56-89b29b7c71fd`); Block 2A Sauvignon Blanc (`d26130db-de02-44e1-9f6c-c66716b2dc48`); Block 2A Shiraz (`5aef3bf1-2a3d-4b47-b2d8-e9a756187b15`); Block 2B Malbec (`9ae93c8d-43c6-47a9-8c57-e2f325cdffec`); Block 2B Sauvignon Blanc (`9ec58ae5-7663-4e62-a1b9-5fb670d99089`); Block 2B Shiraz (`0d869e08-4bc8-4d9c-b313-2230ffb69662`); Block 2CA Pinot Noir (`767c3c6d-8086-4dd8-a780-722f9e780fd0`); Block 2CA Sauvignon Blanc (`62af9005-fee8-4634-a276-c5071342312c`); Block 2CB Pinot Noir (`0612d8a3-e1d2-4e49-af51-8efcc140fa45`); Block 2CB Sauvignon Blanc (`b8aab1c4-045a-4844-b450-9f47eb23040f`); Block 3 Chardonnay (`fed4d465-1621-4068-a623-7062e7ed79d2`); Block 3 Pinot Noir - Grafted (`7bd8bb74-d2ea-4a01-aedb-cd0d03ec1e09`); Block 3 Pinot Noir - Planted (`6115a12f-2cd0-4d42-b91a-937f924cf613`); Block 5 Chenin Blanc (`e637f64c-8bbb-4674-98f9-0d9821fd5be2`); Block 5 Grenache (`3b4ebd11-7be3-49bc-b654-e823ffc49cce`); Block 5 Riesling (`ee20828d-9aaa-4a04-a574-ecf38e62bdc1`); Block 5 Shiraz (`00d3a9b4-33fc-4249-9ebe-36d4d6df2976`); Block 5 Traminer (`2c55f4bf-f01d-4fb5-9cd1-5486d4a9f3d9`); Block 6 Cabernet Franc (`174993f4-5526-4247-bee9-c7a91d024cab`); Block 6 Cabernt Sauvignon (`e524f5f4-1040-4b2b-a1c9-4ac9e8773faf`); Block 6 Shiraz (`612672f6-edcb-41a2-ae80-570440c3c10a`); Block 7 Chardonnay (`7005f50d-2517-4103-b2eb-43405007fd5c`); Block 7 Malbec (`1e1c54a4-ba79-42f8-9a5d-1e9daff0633e`); Block 8 Pinot Gris (`56e2c409-0168-4076-b908-014888811cd2`); Block 8 Pinot Noir (`c88b5a9d-e386-4670-964b-7210c58d8cc8`); Block 8 Sauvignon Blanc (`afcd17ed-ae13-4216-bf84-709e97abf728`); Block 9 Cabernet Sauvignon Blanc (`dfc67c9e-37c7-487c-b338-07bac2204e06`); Block 9 Chardonnay (`da028163-9628-469e-a3a9-7e8947112478`).

### Test Vineyard — `8896a54d-df3e-422e-a9f7-bd749bd3fee2`

- Vineyard deleted at `2026-04-30T11:41:43.684+00:00`.
- One active block: Shiraz A (`b83fcdab-e2d7-4845-9a45-a43a926d58d3`).
- This block has 8 assigned active pins and contains all 8 current pin coordinates. This is evidence of live child data, not evidence that the parent deletion was accidental.

**Decision required from Jonathan:** for Bellview, Borenore and Test Vineyard, supply the authoritative reason for vineyard deletion and whether each active block should remain under the archived vineyard, be archived itself, or has an authoritative successor. If migrated, provide an explicit old vineyard/block ID to new vineyard/block ID mapping. For Test Vineyard, explicitly decide the intended ownership and lifecycle of Shiraz A and its eight pins. Do not restore a vineyard based only on active child records or similar names.

## 4. Assignment conflicts — 10 exact pins

“Candidate none” means no usable current same-vineyard polygon contains the stored base coordinate; it does not identify a nearest alternative.

| Vineyard (ID) | Pin ID; state/type | Current block | Current-polygon candidate | Stored coordinate | Placement evidence |
|---|---|---|---|---|---|
| Ashmore Flats (`166685df-e16f-4b07-aaea-2256f2a9bfd1`) | `0715dc39-6e2b-4c16-8c27-6ff238fb7bca`; completed/Irrigation | Brancott sb (`290dacdb-042a-41e7-b021-410e578d6df7`) | None | -41.5294196811578, 173.844235228341 | Unknown origin; no scope, snap or row segment |
| Ashmore Flats (`166685df-e16f-4b07-aaea-2256f2a9bfd1`) | `70884f55-e76a-478d-946e-9292e4065d19`; active/Broken Post | Brancott sb (`290dacdb-042a-41e7-b021-410e578d6df7`) | None | -41.5282642949817, 173.844142495294 | Unknown origin; no scope, snap or row segment |
| Ashmore Flats (`166685df-e16f-4b07-aaea-2256f2a9bfd1`) | `bf23e4a6-3b45-40c6-94db-2adca234f38a`; active/Irrigation | Brancott sb (`290dacdb-042a-41e7-b021-410e578d6df7`) | None | -41.5294124763102, 173.844156812782 | Unknown origin; no scope, snap or row segment |
| Liebichs Vineyard (`c2c2d3db-34d0-4167-a3ef-a3c4cb35b6f0`) | `114f515f-3880-466d-be9a-be65d9ccd4b4`; completed/Other | LB - Young Shiraz (`a4791fe2-8af2-478f-ad54-6401a5e67bb8`) | None; LB - Grafted Shiraz (`5af8fe37-667a-46bf-b5ef-468e7da4a8f6`) was excluded for malformed geometry | -34.9222268775372, 138.626569328571 | Unknown origin; no scope, snap or row segment |
| Loveblock (`6ceaf3c5-f40d-48aa-aec7-caec6a7b5f99`) | `1a6fb809-1b45-4e78-8525-6054ef49da69`; completed/Vine Issue | Woolshed SB (`4a364cd1-f134-4cb9-a8b5-8d7db574021e`) | None | -44.7051978271712, 169.108694739853 | Unknown origin; no scope, snap or row segment |
| Loveblock (`6ceaf3c5-f40d-48aa-aec7-caec6a7b5f99`) | `58b5c19e-f4df-4f02-9650-d5d62eb59877`; completed/Irrigation | Woolshed SB (`4a364cd1-f134-4cb9-a8b5-8d7db574021e`) | None | -44.7051978271875, 169.108694739833 | Unknown origin; no scope, snap or row segment |
| Milbrodale Farm (`66b47f5b-b159-4333-b099-0203bdbe835f`) | `3eb90949-d59d-4a96-bc1f-586084ceec97`; active/Irrigation | Bottom block (`f2976cf7-0cd0-47d4-a526-b09f33ec19f4`) | None | -32.6961170252241, 151.019496921813 | Unknown origin; no scope, snap or row segment |
| Milbrodale Farm (`66b47f5b-b159-4333-b099-0203bdbe835f`) | `d3414475-1731-4aff-bdc0-18092f558670`; active/Irrigation | Bottom block (`f2976cf7-0cd0-47d4-a526-b09f33ec19f4`) | None | -32.6960764681902, 151.019390285962 | Unknown origin; no scope, snap or row segment |
| San Vittorino (`98d93e49-10e2-4da9-a01e-b3ee0c05ffdb`) | `1b1b4f0c-2fdc-4ede-84ad-8ea1f333937e`; active/Vine Issue | Vineyard (`d0b77d88-0e2f-49a7-b4fb-e0ccece241f7`) | None | 0, 0 | **Intentional manual row/segment placement**, stored scope `row`, two row segments; preserve manual intent and do not overwrite from the placeholder base coordinate |
| Tamburlaine Bellview (`079f7833-bfff-41ee-ba86-29032d4b3d1c`) | `3b26f514-26bf-432a-9ed0-b946725e24bf`; completed/Irrigation | Block 3 (`0d749e28-e338-41d2-83fd-59b36353217d`) | Block 8 (`b85e5ca4-09fe-4d41-bf75-8d6d5b9fe8c6`) | -33.1049465571637, 149.024742244803 | Unknown origin; no scope, snap or row segment; point is 3.45 m from nearest current boundary |

**Decision required from Jonathan:** confirm the authoritative intended block for each exact pin and whether its current assignment came from deliberate manual placement or a prior boundary version. Supply authoritative boundary history where the decision depends on historical coverage. For Liebichs, first supply the missing LB - Grafted Shiraz boundary. For San Vittorino, confirm the intended block from the manual row/segment record; the `(0,0)` base coordinate must not drive reassignment. For Tamburlaine Bellview, explicitly choose Block 3, Block 8 or another named/ID block and provide the supporting source.

## 5. Boundary cases — 126 pins

There are no records with more than one current containing polygon. The broad classification label covers proximity, assignment/containment mismatch and base/snapped disagreement.

### Actual reasons by vineyard

| Vineyard (ID) | Total | Actual reasons |
|---|---:|---|
| Stockmans Ridge (`fe952afe-437f-4be7-8cbf-fdd8e630411c`) | 59 | 45 assigned to sole containing block within 3 m; 10 unassigned with no containing block within 3 m; 3 base/snapped candidate disagreements; 1 assigned Shiraz but sole containing block is Primitivo |
| Hill Park (`fefcbf2e-29ab-4828-828c-c1035fddfb69`) | 18 | 16 unassigned with one containing block within 3 m; 2 unassigned with no containing block within 3 m |
| Estellar Estate (`00bb9a18-28da-4ba7-9136-b2c5a1b56fb5`) | 12 | 10 assigned to sole containing block within 3 m; 2 unassigned with one containing block within 3 m |
| Mortimers Wines (`d5ece96c-1f6f-4466-a350-158f9bc28ea5`) | 11 | 11 assigned to sole containing block within 3 m |
| Tamburlaine Boomey (`2c1d6be9-b5e4-42ec-a328-5c734ef87bf1`) | 11 | 6 unassigned with no containing block within 3 m; 3 unassigned with one containing block within 3 m; 2 assigned to sole containing block within 3 m |
| Toll farm (`2d12ab89-4c40-42a8-8ea1-4c0fc52ee7ed`) | 9 | 5 assigned to sole containing block within 3 m; 3 unassigned with no containing block within 3 m; 1 assigned to Niagara but no containing block within 3 m |
| Milbrodale Farm (`66b47f5b-b159-4333-b099-0203bdbe835f`) | 2 | 2 assigned to sole containing block within 3 m |
| Tamburlaine Bellview (`079f7833-bfff-41ee-ba86-29032d4b3d1c`) | 2 | 1 assigned to sole containing block within 3 m; 1 unassigned with no containing block within 3 m |
| Shadowfax Little Hampton (`a388556a-cd9a-485a-a12e-edf7137c5927`) | 1 | 1 unassigned with no containing block within 3 m |
| Tamburlaine Borenore (`a18654f6-13ed-4438-998b-7a7e1d89181a`) | 1 | 1 assigned to sole containing block within 3 m |

Reason totals: 77 assigned to the sole containing block near a boundary; 23 unassigned and outside all current polygons but within 3 m; 21 unassigned and inside one current polygon but within 3 m; 3 base/snapped disagreements; 1 assigned to a different sole containing block; 1 assigned but not contained by any current polygon. The three disagreement records are already assigned to their base-point block, bringing the broader “assigned to containing block” population to 80.

### The 21 unassigned pins inside one current polygon but within 3 m

| Vineyard (ID) | Pin ID; type | Stored coordinate | Candidate block (ID) | Boundary distance |
|---|---|---|---|---:|
| Estellar Estate (`00bb9a18-28da-4ba7-9136-b2c5a1b56fb5`) | `094b8ba4-4f47-4d3f-9733-4d0a24fafc46`; Irrigation | -37.6116001041674, 145.420827915755 | G1 Pinot Noir (`2fb055a3-76e6-4ec4-ae81-c1fa9fcdc1ae`) | 1.30 m |
| Estellar Estate (`00bb9a18-28da-4ba7-9136-b2c5a1b56fb5`) | `cf7b73b1-0c7b-4235-bef5-8b28fb00b4f4`; Irrigation | -37.6116085294041, 145.420899319158 | G1 Pinot Noir (`2fb055a3-76e6-4ec4-ae81-c1fa9fcdc1ae`) | 1.24 m |
| Hill Park (`fefcbf2e-29ab-4828-828c-c1035fddfb69`) | `090693c4-2514-4023-95fb-e24e4a95f2ba`; Broken Post | -33.2752859580434, 149.034739567680 | Block 6b - Pinot Noir (115) (`188c0cf9-ea68-429e-9ab3-5fb87a629359`) | 0.96 m |
| Hill Park (`fefcbf2e-29ab-4828-828c-c1035fddfb69`) | `15357895-de24-428c-a906-a11facddb193`; Broken Post | -33.2757655998847, 149.034649366592 | Block 6b - Pinot Noir (115) (`188c0cf9-ea68-429e-9ab3-5fb87a629359`) | 1.19 m |
| Hill Park (`fefcbf2e-29ab-4828-828c-c1035fddfb69`) | `1d8d1f42-1507-4dc5-a9ef-3bf37e34c972`; Broken Post | -33.2742506711218, 149.033818417354 | Block 4b - Pinot Noir (667) (`41fb2d0d-07e2-4d27-bbee-3a5739bb57a9`) | 1.88 m |
| Hill Park (`fefcbf2e-29ab-4828-828c-c1035fddfb69`) | `225fc7c0-076c-4c7a-9dd1-9c28fb09a443`; Broken Post | -33.2741653248274, 149.033597416797 | Block 4a - Pinot Noir (Abel) (`21a08ff9-fbbe-4aef-9c48-058ccf668162`) | 1.97 m |
| Hill Park (`fefcbf2e-29ab-4828-828c-c1035fddfb69`) | `2ffce9da-cc9c-45a6-860b-918d64cb7856`; Broken Post | -33.2748401047267, 149.033665263654 | Block 4a - Pinot Noir (Abel) (`21a08ff9-fbbe-4aef-9c48-058ccf668162`) | 1.70 m |
| Hill Park (`fefcbf2e-29ab-4828-828c-c1035fddfb69`) | `5ad35bde-8b78-46dc-b642-b73a889e020e`; Vine Issue | -33.2739704840395, 149.032693348466 | Block 2 - Chardonnay (`65ccdf13-3b33-44e9-ae25-58a72fe9da73`) | 0.36 m |
| Hill Park (`fefcbf2e-29ab-4828-828c-c1035fddfb69`) | `5b85aa7e-009b-4fd0-8fee-abb1d301ecda`; Broken Post | -33.2756673220503, 149.034233540056 | Block 5b - Pinot Noir (777) (`02050c43-f38b-4a60-a9a3-1f33ed93d659`) | 1.91 m |
| Hill Park (`fefcbf2e-29ab-4828-828c-c1035fddfb69`) | `753bcafc-9033-4f39-a7a1-e67ac2f0e696`; Other | -33.2743886563990, 149.033779742575 | Block 4b - Pinot Noir (667) (`41fb2d0d-07e2-4d27-bbee-3a5739bb57a9`) | 0.72 m |
| Hill Park (`fefcbf2e-29ab-4828-828c-c1035fddfb69`) | `8d90e348-01a3-47f9-8ada-49c1d5e36fa9`; Other | -33.2744015315419, 149.034225489786 | Block 5b - Pinot Noir (777) (`02050c43-f38b-4a60-a9a3-1f33ed93d659`) | 2.39 m |
| Hill Park (`fefcbf2e-29ab-4828-828c-c1035fddfb69`) | `b03f25dd-83da-4044-978d-e21a0ea86d0f`; Other | -33.2742481020361, 149.034011216836 | Block 4c - Cab Franc (`c6fa370c-b6d1-4a5e-b977-ea12ac40766f`) | 2.61 m |
| Hill Park (`fefcbf2e-29ab-4828-828c-c1035fddfb69`) | `b125731d-cb13-4b5a-85f3-d2156357af1f`; Broken Post | -33.2754936188447, 149.035129544053 | Block 6b - Pinot Noir (115) (`188c0cf9-ea68-429e-9ab3-5fb87a629359`) | 0.71 m |
| Hill Park (`fefcbf2e-29ab-4828-828c-c1035fddfb69`) | `b1e10618-a4ad-48b9-b0e1-7e6a479ee5c8`; Broken Post | -33.2744643709346, 149.033781280976 | Block 4b - Pinot Noir (667) (`41fb2d0d-07e2-4d27-bbee-3a5739bb57a9`) | 2.17 m |
| Hill Park (`fefcbf2e-29ab-4828-828c-c1035fddfb69`) | `badc4335-e293-4d8b-8014-78541e171e4e`; Broken Post | -33.2755445200492, 149.033334560016 | Block 4a - Pinot Noir (Abel) (`21a08ff9-fbbe-4aef-9c48-058ccf668162`) | 2.80 m |
| Hill Park (`fefcbf2e-29ab-4828-828c-c1035fddfb69`) | `c1e6a5b2-bbd3-4e2f-916f-52d49c3ab315`; Broken Post | -33.2756297911346, 149.033510952610 | Block 4a - Pinot Noir (Abel) (`21a08ff9-fbbe-4aef-9c48-058ccf668162`) | 2.11 m |
| Hill Park (`fefcbf2e-29ab-4828-828c-c1035fddfb69`) | `d7862efc-897e-43ff-931f-392f5ea9c0db`; Other | -33.2738323073889, 149.032738835846 | Block 1 - Chardonnay (`6678a81f-457d-4cf4-ba3b-229d7446c178`) | 1.04 m |
| Hill Park (`fefcbf2e-29ab-4828-828c-c1035fddfb69`) | `f02b8400-1ab1-4cbe-be72-53f2e4a447ab`; Other | -33.2742702127068, 149.034251021106 | Block 5b - Pinot Noir (777) (`02050c43-f38b-4a60-a9a3-1f33ed93d659`) | 2.36 m |
| Tamburlaine Boomey (`2c1d6be9-b5e4-42ec-a328-5c734ef87bf1`) | `10fb785d-eb4a-4a51-889a-c97afd11b593`; Growth Stage EL1 | -32.9821323294846, 148.979159777727 | Block 8 (`949b7423-6afb-4cc2-97c1-8537b54216f4`) | 0.25 m |
| Tamburlaine Boomey (`2c1d6be9-b5e4-42ec-a328-5c734ef87bf1`) | `57594bbd-280b-4754-bdb1-65de67e190d2`; Growth Stage EL1 | -32.9797676572994, 148.976388065581 | Block 7 (`90c9d26e-0f48-4be6-ac23-92707b56d367`) | 2.91 m |
| Tamburlaine Boomey (`2c1d6be9-b5e4-42ec-a328-5c734ef87bf1`) | `5a6e5d75-e72a-4bba-bd40-c50bb2024d87`; Growth Stage EL1 | -32.9820383273516, 148.979180731295 | Block 7 (`90c9d26e-0f48-4be6-ac23-92707b56d367`) | 0.55 m |

**Decision required from Jonathan:** supply authoritative shared boundary vertices for the affected blocks and confirm the intended block for the exceptional mismatch records. For the 21 listed pins, explicitly approve or reject the named candidate after checking field truth; current containment inside 3 m is not approval. For the three Stockmans Ridge base/snapped disagreements, identify which coordinate is original and which is derived and confirm the intended block. Do not move coordinates or redraw boundaries to produce a desired assignment.

## 6. Outside all current blocks — 235 pins

| Vineyard (ID) | Total | Pin types |
|---|---:|---|
| Tamburlaine Boomey (`2c1d6be9-b5e4-42ec-a328-5c734ef87bf1`) | 178 | Blackberries 1; Broken Post 147; Growth Stage EL1 2; Irrigation 8; Powdery 1; Vine Issue 15; broken wire 4 |
| Stockmans Ridge (`fe952afe-437f-4be7-8cbf-fdd8e630411c`) | 16 | Blackberries 16 |
| Tamburlaine Borenore (`a18654f6-13ed-4438-998b-7a7e1d89181a`) | 7 | Growth Stage EL1 2; Irrigation 5 |
| Ashmore Hills (`322eb17b-fec5-4678-91f1-41a59f4537e9`) | 5 | Broken Post 1; Downy 1; Growth Stage EL3 1; Irrigation 1; Powdery 1 |
| JH Testing (`59973ced-1fb9-42ec-a66d-9eaad3172824`) | 5 | Missing pin type 2; Broken Post 1; Irrigation 2 |
| Tamburlaine Bellview (`079f7833-bfff-41ee-ba86-29032d4b3d1c`) | 5 | Broken Post 1; Growth Stage EL3 1; Other 1; Vine Issue 1; Wire 1 |
| Blue Metal (`b29ea60a-9c66-4561-8524-f814dd5de30f`) | 4 | Downy 1; Growth Stage EL13 1; Powdery 2 |
| Moddervlei 6034002 (`1ea7eb41-b967-4f68-a4b3-6561bf86a401`) | 3 | Blackberries 1; Growth Stage EL4 1; Powdery 1 |
| Glen Devlin (`24a9caaa-891c-4f6c-9c85-c731096f13ba`) | 2 | Blackberries 1; Downy 1 |
| Hill Park (`fefcbf2e-29ab-4828-828c-c1035fddfb69`) | 2 | Broken Post 1; Other 1 |
| Toll farm (`2d12ab89-4c40-42a8-8ea1-4c0fc52ee7ed`) | 2 | Broken Post 1; No vine 1 |
| De Hoop (`ff954eaa-95bc-4cd4-a04c-d79eb85d4102`) | 1 | Irrigation 1 |
| Juniper (`5ff753de-7f04-4fdd-92d5-1bc8eb23e6f4`) | 1 | Blackberries 1 |
| Loveblock (`6ceaf3c5-f40d-48aa-aec7-caec6a7b5f99`) | 1 | Irrigation 1 |
| Marnong estate (`4700033b-eb4b-4b3d-ad5a-c40e6e923e54`) | 1 | Vine Issue 1 |
| Neuperk (`fd19cd13-7b71-482f-be65-abb17d46fbe8`) | 1 | Broken Post 1 |
| San Vittorino (`98d93e49-10e2-4da9-a01e-b3ee0c05ffdb`) | 1 | Powdery 1 |

Tamburlaine Boomey's 178 pins are all active. Their distance from the nearest current block boundary ranges from 3.92 m to 34.01 m, with a 32.16 m median. This large, concentrated group is evidence that authoritative coverage should be checked, but it does not prove which boundary is missing or that any existing polygon should be enlarged. Stockmans Ridge's 16 pins are all completed Blackberries records, 143.38–427.39 m from the nearest boundary (353.79 m median), so proximity provides no assignment basis.

**Decision required from Jonathan:** for each vineyard, confirm whether these coordinates are (a) legitimately outside planted blocks, (b) covered by an omitted authoritative block, or (c) covered by a historical boundary version. For (b) or (c), supply the exact block name/ID, vineyard owner ID, lifecycle state and ordered authoritative boundary vertices or historical effective boundary evidence. Prioritize Tamburlaine Boomey. Do not assign nearest blocks.

## Required response format before any correction package

Jonathan should return decisions keyed by vineyard ID and, where applicable, block ID and pin ID:

1. authoritative vineyard and block names plus IDs;
2. intended ownership and lifecycle state;
3. ordered authoritative boundary vertices and source/effective date;
4. exact intended block for each reviewed conflict or approved boundary pin;
5. confirmation when a vineyard intentionally has no blocks or a pin legitimately lies outside all blocks;
6. explicit preservation of manual-placement and coordinate provenance.

Only records with an exact reviewed decision can enter a future guarded correction preview. This pack does not authorize an UPDATE, rollback or boundary rewrite.
