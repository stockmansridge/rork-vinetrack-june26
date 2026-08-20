#!/usr/bin/env python3
"""AWRI 'Dog Book' 2026/27 seed-manifest extractor (Stage 5).

Produces the DETERMINISTIC seed manifest for the Master Chemical Catalogue
AWRI seeding process:

    python3 extract_awri_dogbook.py --text /tmp/dogbook.txt \
        --pdf /tmp/dogbook.pdf --out awri_dogbook_2026_27.json

Source: AWRI "Agrochemicals registered for use in Australian viticulture
2026/27" (the 'Dog Book'), compiled 1 June 2026, downloaded from
https://www.awri.com.au/wp-content/uploads/agrochemical_booklet.pdf
Text extracted with pypdf.

The booklet publishes NO APVMA registration numbers, so every manifest entry
carries `apvma_registration_number: null`; registration identity is resolved
later against the APVMA PubCRIS register by the seed module using the
ingestion pipeline's deterministic name discipline (never fuzzy).

DESIGN — curated transcription + mechanical verification
  PDF column extraction merges the 'active constituent' and 'products'
  table cells unpredictably (mid-word spaces, wraps, duplicated spread
  pages), so a generic parser cannot be trusted for a seed of record.
  Table 2 rows are instead TRANSCRIBED below (ROWS/CANCELLED), and this
  script mechanically verifies every transcribed product string against the
  squashed source text — a transcription typo fails the build. Cleanups
  applied during transcription (PDF artefact repairs) are listed in
  REPAIRS_ALLOWLIST with the artefact they repair.

AWRI is a viticulture coverage/reference source ONLY (viticulture_reference).
It never supplies registration facts, WHP, re-entry hours, or rates to the
catalogue — the APVMA register/label remain the sole authority. The booklet's
re-entry CODES and activity groups are carried as reference metadata for the
import report, nothing else.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys

SOURCE = {
    "id": "awri_dogbook_2026_27",
    "kind": "viticulture_reference",
    "title": "Agrochemicals registered for use in Australian viticulture 2026/27",
    "publisher": "The Australian Wine Research Institute",
    "edition": "2026/27",
    "compiled": "2026-06-01",
    "url": "https://www.awri.com.au/wp-content/uploads/agrochemical_booklet.pdf",
    "table": "Table 2 (booklet pp. 20-26) + cancelled products (booklet p. 29)",
    "note": (
        "Coverage/reference source only. The booklet publishes no APVMA "
        "registration numbers; identity resolution happens against the APVMA "
        "PubCRIS register. Table 1 (export harvest intervals) is winery/export "
        "advice, not registration data, and is deliberately not seeded."
    ),
}

# --------------------------------------------------------------------------
# Table 2 transcription. Each row: (section, active, products_cell, re_entry,
# activity_group). products_cell keeps the booklet's parenthesised variant
# compression verbatim (modulo the repairs listed in REPAIRS_ALLOWLIST);
# expansion happens deterministically below.
# re_entry/activity_group are AWRI reference metadata only; None = the
# booklet cell was empty/ambiguous in extraction (never guessed).
# --------------------------------------------------------------------------

F = "fungicide"
H = "herbicide"
I = "insecticide"
P = "plant_growth_regulator"

ROWS: list[tuple[str, str, str, str | None, str | None]] = [
    # ---- FUNGICIDE (booklet p. 20) ----
    (F, "ametoctradin + dimethomorph", "Zampro", "a", "45 + 40"),
    (F, "amisulbrom", "Amishield", "j", "21"),
    (F, "Aureobasidium pullulans", "Botector", "a", "BM02"),
    (F, "azoxystrobin",
     "Accolade 250 SC, Affix 250 SC, Agristar 250SC, Amistar 250 SC, "
     "A-Star 250 SC, Avior 250 SC, Azoxy 250, AzoxyGuard 250 SC, "
     "Azoxystrobin (250, 250 SC, 500 WG), Spartacus (250, 250 SC, 500WG), "
     "Surefire Stellar",
     "a", "11"),
    (F, "azoxystrobin", "Avior 800 WG, Connect 800 WG", "q", "11"),
    (F, "Bacillus amyloliquefaciens", "Serenade Opti, Serifel", None, "44"),
    (F, "BLAD", "ProBlad, ProBlad Verde", "a", "BM01"),
    (F, "boscalid",
     "Boscalid 500 WG, Boscolan 500WG, Certify 800 WG, Filan, "
     "Rascasse 500 WG, Rinkals",
     "a", "7"),
    (F, "captan", "Captan (800 WG, 900 WG), Lectern 800 VeripHy WG", "a", "M4"),
    (F, "chlorothalonil",
     "Barrack Betterstick, Barrow (900 WG, Stick 720SC), Bravo Weather Stik, "
     "Castor 900WG, Cavalry Weatherguard, Cheers 720 (Holdfast, Weathershield), "
     "Cheers 900WG, Chlornil 720 SC, Chloro 900 WG, Chloronil Pro, "
     "Chlorostar 900 WG, Chlorostick 720 SC, Chlorothalonil (720, 720SC, 900 WG), "
     "Surefire Chlortan 720, Clash (Dry 900 WG, Storm Guard 720 SC), "
     "Conan Sticks 720SC, Echo (720, 900 WDG), Mueso (720, 900WG, Stick 720), "
     "Whack (720, 900 WG)",
     "a", "M5"),
    (F, "copper as ammonium complex", "Copperguard", "a", "M1"),
    (F, "copper as cuprous oxide", "Ag Copp 750 WG, Nordox 750 WG", "a", "M1"),
    (F, "copper as hydroxide",
     "Blue Shield DF, Champ DP, Copper Hydroxide (400 WG, 500), "
     "Flowcop 500WG, Hydrocop WG, Kocide (Blue Xtra, Opti), Vitra 400 WG",
     "a", "M1"),
    (F, "copper as octanoate", "Tricop", "a", "M1"),
    (F, "copper as oxychloride",
     "Copper Oxychloride (WP), Coppox (WG, WP), Cupro 375WG, "
     "EcoCopper 375WG, Isacop 500WP, Neoram 375 WG, Oxydul DF",
     "a", "M1"),
    (F, "copper as oxychloride + hydroxide", "Airone WG", "l", "M1 + M1"),
    (F, "copper as sulfate tribasic",
     "Bordeaux WG, Tri-Base Blue, Tribasic (Copper Flowable, Flowable, Liquid)",
     "a", "M1"),
    (F, "copper sulfate tribasic + mancozeb", "Copman DF", "c", "M1 + M3"),
    (F, "cyflufenamid", "Flute 50 EW, Cyflamid 50EW", "a", "U6"),
    (F, "cyproconazole + iodocarb", "Garrison Rapid Pruning Wound Dressing", "a", "3 + 28"),
    (F, "cyprodinil", "Solaris 300 EC", "a", "9"),
    (F, "cyprodinil + fludioxonil",
     "Cyprofludox WG, Missile, Rot-nil, Snatch WG, Surefire Crossover WG, "
     "Swap WG, Switch",
     "a", "9 + 12"),
    # ---- FUNGICIDE (booklet p. 21) ----
    (F, "difenoconazole", "Digger EW, Kingfisher", "a", "3"),
    (F, "dimethomorph", "Acrobat SC, Sphinx", "a", "40"),
    (F, "dimethomorph", "MetaMorph 500 SC", "n", "40"),
    (F, "dithianon",
     "Delan 700 WG, Dialon 700WG, Dinon 700 WG, Dithianon 700 WG, Dragon, "
     "Dungeon 700 WG, Wrath 700WG",
     "a", "M9"),
    (F, "eugenol, geraniol, thymol", "Novellus", "a", "46"),
    (F, "fenhexamid", "Altivo 500SC, Jigsaw 800 WG, Teldor 500 SC", "a", "17"),
    (F, "fenpropidin + difenoconazole", "Seeker Duo", "a", "5 + 3"),
    (F, "fenpyrazamine", "Prolectus", "a", "17"),
    (F, "florylpicoxamid", "Verpixo", "a", "21"),
    (F, "fluazinam", "Emblem, Fluaza-Stick 500 SC, Peridot 500SC", "m", "29"),
    (F, "fluazinam", "Gem, Surefire Zinam 500 SC", "s", "29"),
    (F, "fluopyram + tebuconazole", "Luna Experience", "a", "7 + 3"),
    (F, "fluoxapiprolin", "Xivana Prime 20 SC", "a", "49"),
    (F, "folpet", "Folpan 800 WG", "a", "M4"),
    (F, "hydrogen peroxide + peroxyacetic acid",
     "Peracetic Acid, PeraCrop Max, Peratec PLUS, Peroxy Treat",
     "a", "M + M"),
    (F, "ipflufenoquin", "Migiwa Kinoprol Active", "a", "52"),
    (F, "iprodione",
     "Aquaflow 500 SC, Chief Aquaflo, Drover Guard 500 SC, Ipral 250, "
     "Iprine (250, 500), Iprodex 250, Iprodione (250, 500, 500 SC, Aquaflow 500), "
     "Lavor 250, Rovral (Aquaflo, Liquid), Transact",
     "a", "2"),
    (F, "mancozeb",
     "Dithane Rainshield Neo Tec, Fortuna Globe 750WG, Greenshield 750WG, "
     "Kencozeb (750DF, Endure), Mancozeb (750 DF, 750 WG, 800 WP, WG), "
     "Manic WG, Manzate (750 WG, DF), Manzeb, Penncozeb 750DF, "
     "Sinozeb 750 WG, Unizeb 420 SC",
     "a", "M3"),
    (F, "mandipropamid", "Bremex 250SC, Mandiva 250SC, Revus", "a", "40"),
    (F, "mandipropamid + oxathiapiprolin", "Keybri Ultra", "a", "40 + 49"),
    (F, "mefentrifluconazole", "Belanty", "a", "3"),
    (F, "metalaxyl-M", "Axiom Flexi", "a", "4"),
    (F, "metalaxyl-M + copper hydroxide", "Ridomil Gold Plus", "a", "4 + M1"),
    (F, "metalaxyl-M + mancozeb", "Ridomil Gold MZ WG", "a", "4 + M3"),
    (F, "metalaxyl + copper oxychloride",
     "Axiom Plus, Metalaxyl + Copper Oxychloride WP, Zeemil Plus",
     "a", "4 + M1"),
    (F, "metalaxyl + mancozeb",
     "Metal-man MZ 720, Metman 720 WG, Zeemil 720 WG", "a", "4 + M3"),
    (F, "metiram", "Fruitcote, Polyram DF", "a", "M3"),
    (F, "metrafenone", "Vivando", "a", "50 (U8)"),
    (F, "myclobutanil", "Myclonil WG, Mycloss Xtra", "h", "3"),
    (F, "orange oil", "Prev-Am", "a", None),
    # ---- FUNGICIDE (booklet p. 22) ----
    (F, "oxadixyl + propineb", "Rebound WP", "a", "4 + M3"),
    (F, "paraffinic oil", "BioPest, CropCover, isoCLEAR HPO, Trump Spray Oil", "a", None),
    (F, "penconazole", "Azotic, Delos 100EC, Pearl, Topas 100 EC", "a", "3"),
    (F, "petroleum oil", "JMS Stylet-Oil", "a", None),
    (F, "phosphorous acid",
     "Agri-Fos 600, Crop Doc 600, Dominator 600, Fungi-Fos (400, 400 pH 7.2), "
     "Ken-Fos 600, Phos Phyt 400, Phospot (400 pH 7.2, 600), "
     "Sprayphos (400, 600, 620), Throw Down",
     "a", "33"),
    (F, "polyoxin D zinc salt", "Intervene", "a", "19"),
    (F, "potassium bicarbonate / potassium bicarbonate + silicate",
     "ecocarb, ecocarb PLUS", "a", "M2"),
    (F, "potassium salts of fatty acids", "Ecoprotector, Hitman", "a", "U1"),
    (F, "procymidone",
     "Kondone 500 SC, Metapris 500 SC, Nosclex 800 WG, Procymidone (500, 500SL), "
     "Proflex 500, Sporex, Sumisclex 500",
     "p", "2"),
    (F, "proquinazid", "Talendo", "a", "13"),
    (F, "pydiflumetofen", "Miravis", "a", "7"),
    (F, "pydiflumetofen + fludioxonil", "Miravis Prime", "a", "7 + 12"),
    (F, "pyraclostrobin",
     "Cabretta 250EC, Cabrio, Pavo 250 EC, Pyraclostrobin 250 EC, "
     "Roadster 500 EC, Symbio 250 EC, Vipyr 250 EC",
     "a", "11"),
    (F, "pyrimethanil", "Pyper 600 SC, Pyrimethanil 600 SC, Scala 600 SC", "a", "9"),
    (F, "pyriofenone", "Kusabi 300 SC", "a", "50"),
    (F, "quinoxyfen", "Legend, Quinfen 250 SC, Vitae", "a", "13"),
    (F, "spiroxamine", "Prosper 500 EC", "e", "5"),
    (F, "spiroxamine", "Anaconda 500 EC, Spire 500 EC", "f", "5"),
    (F, "sulfur (elemental or crystalline)",
     "Cosamil, Dusting Sulphur (900), ecosulfur 800 WG, InnoSulph 800 WG, "
     "Kumulus DF, Microsul WG Elite, Microthiol Disperss, Nimbus WG, "
     "Sulfur (800 WG), Thiopron, Thiovit Jet, Top Wettable Sulphur 800 WG, "
     "Yellowstone 800WG",
     "a", "M2"),
    (F, "tebuconazole",
     "Greenseal, Orius 430 SC, Sprayseal, Tebucon 430 SC, Tebuconazole 430 SC, "
     "Vistaseal, Zolo 430 SC",
     "a", "3"),
    (F, "tebuconazole", "Tebugran 750 WG", "a", "3"),
    (F, "tebuconazole + azoxystrobin", "Azlan, Custodia (Forte)", "a", "3 + 11"),
    (F, "tetraconazole", "Domark 40ME, Mettle 40ME", "a", "3"),
    (F, "thiram", "Thiram (DG, 800 WG)", "a", "M3"),
    (F, "triadimefon", "Triadimefon 125", "a", "3"),
    (F, "triadimenol", "Allitron, Cougar 250 EC, Tridim 250 EC", "a", "3"),
    (F, "Trichoderma harzianum", "Vinevax (Bio-Implants, Wound Dressing)", "a", None),
    (F, "trifloxystrobin", "Flint 500 WG, Invictus 500 WG", "a", "11"),
    (F, "ziram", "Ziram WG", "a", "M3"),
    # ---- HERBICIDE (booklet p. 23) ----
    (H, "2,2-DPA-sodium (dalapon-sodium)", "Dalapon 740", "a", "0"),
    (H, "amitrole + ammonium thiocyanate",
     "Amitat, Amitrole (250, 250 SL, 47T, T 250), Kentrole 250, Weedwarden",
     "a", "34"),
    (H, "amitrole + paraquat", "Guerrilla", "a", "34 + 22"),
    (H, "bromoxynil + diflufenican",
     "Colt, Kelpie DFF + Brom MX, Jagged, Lobak, Meerkat, Ruger",
     "a", "6 + 12"),
    (H, "carfentrazone-ethyl",
     "Carfentrazone (240 EC, 400 EC), Carfentrazone-ethyl 240 EC, "
     "Elevate 400 EC, Hammer 400 EC, Knocker 240 EC, Nail 600EC, Rage 400 EC, "
     "Spike, Spotlight Plus, Squatter 400 EC",
     "a", "14"),
    (H, "dichlobenil", "Sierraron 4G", "a", "29"),
    (H, "diquat",
     "Desiquat, Dia-Kill 200, Diquat (200, 200 SL), Reglone, Sanction 200",
     "a", "22"),
    (H, "diquat + paraquat",
     "Blowout, Brown Out 250, Combik 250, Di-Par 250, EOS, Paradat, "
     "Scorcher 250, Speedy 250, Spray Seed 250, Squadron 250",
     "a", "22 + 22"),
    (H, "flazasulfuron", "Katana 250 WG", "a", "2"),
    (H, "fluazifop-P",
     "Fluazaway 212, Fluazifop (212), Fusilade Forte, Fuzilier, Rootout 212, "
     "Surefire Cannonade 212 EC",
     "a", "1"),
    (H, "flumioxazin", "Chateau, Spektrum 500 WG", "a", "14"),
    (H, "glufosinate-ammonium",
     "Basta, Beast 200, Biffo, Cease, Commando 200, Fascinate (280SL, Dry), "
     "Faster-TG 200, Fiestar, Fosinate 200 SL, Glufonium 200 SL, Glufos, "
     "Glufosinate (200, 400, 800 SG), Glufosinate-Ammonium 200, G-FOS 200, "
     "Muster, Surefire Gamma",
     "a", "10"),
    (H, "glufosinate-ammonium + carfentrazone-ethyl", "Hellcat", "a", "10 + 14"),
    (H, "glufosinate-P-ammonium", "Basta Ultra", "t", "10"),
    (H, "glyphosate acid", "Moonshine", "a", "9"),
    (H, "glyphosate-ipa",
     "AllOut 450, Cropmaster 450, Eraze (360 Bi-aquatic, 510 Bi-aquatic), "
     "Glister 450, Gly 360, Glypho 450, Glyphosate (360, 450, 450 CT, 450 SL, 510), "
     "Kelpie Chisel 450, Ken-Up (450 CT, 500 Flexi, Aquatic 360), Knockout 450, "
     "Panzer 450, Pestmaster (Aqua-Tech 360, Glyphosate CT), Raze, Rico 450 GLY, "
     "Roundup (Biactive), SixGun (360, 510), Weedpro (540 Bio, BioAqua 360)",
     "a", "9"),
    (H, "glyphosate-ipa + mas", "Weedmaster Duo", "a", "9"),
    (H, "glyphosate-mas",
     "Bazooka Dry 800 SG, Glister 680 SG, Dry GLY (680, 680 WG, 700), "
     "GLY 680 Dry, Glyphosate (700, 700 SG, 875), Ken-Up Dry 680 WG, "
     "Knockout Dry 700 SG, Roundup Ready Plantshield",
     "a", "9"),
    (H, "glyphosate-mea", "Glyphosate 450 SL", "a", "9"),
    # ---- HERBICIDE (booklet p. 24) ----
    (H, "glyphosate-potassium salt",
     "Cropmaster Ultra 540, Glyphosate (540, 540 K, 570), GLY 540 SL, "
     "Gold TX 540 GLY, Ken-Up Dry Super K, Knockout Extreme, Max Out 540, "
     "Rico HPS 540 GLY, Roundup (Ready PL, Ultra MAX, Ultramax with Plantshield), "
     "Titanium 570, Warlord 540 Hi-Load",
     "a", "9"),
    (H, "glyphosate-potassium salt + mas", "Weedmaster DST", "a", "9"),
    (H, "glyphosate-potassium salt + mea",
     "Glyphosate 550 Twin Salt, Max Out 600 Duo, Promix 550 GLY", "a", "9"),
    (H, "glyphosate-potassium, mea + mas", "Crucial, Glyphosate 450 SL", "a", "9"),
    (H, "glyphosate-potassium, mma", "Boonta", "a", "9"),
    (H, "haloxyfop-P methyl ester", "Hallotop 520EC, Haloxyfop 900EC", "a", "1"),
    (H, "haloxyfop-R methyl ester",
     "Dictum 520EC, Feathertop 520, Firepower 900, Halox-F 520, "
     "Haloxyfop (520, 520 EC), Haloxyken 520, Hermes 520, Jasper 520 EC, Recon 520",
     "a", "1"),
    (H, "indaziflam", "Alion 500 SC", "a", "29"),
    (H, "isoxaben", "Gallery 750 DF", "a", "29"),
    (H, "napropamide", "Devrinol-C 500WG", "a", "0"),
    (H, "nonanoic acid",
     "Basher, Beloukha, Brut, Neo, Slasher, Slayer Organic, "
     "FireHawk Bioherbicide Super Concentrate",
     "a", "0"),
    (H, "norflurazon", "Zoliar (DF, 800 DF)", "a", "12"),
    (H, "oryzalin", "Oryzalin 500, Prolan 500", "a", "3"),
    (H, "oxyfluorfen",
     "Cavalier (500SC), Encore 240, Gowel 240 EC, Ory-Ken 500 SC, Ox 240, "
     "Oxen 240EC, Oxy-F 240, Oxyfan 240 EC, Oxyfluorfen 240 EC, Point",
     "a", "14"),
    (H, "paraquat",
     "Explode (250, 360), Gramoxone 360 Pro, P-Quat (250 SL, 300 SL), "
     "Par-Q 250, Para-Ken (250, 334), Paradox 250, "
     "Paraquat (250, 250 SL, 300, 360, 360 SL), Parashot (250, Plus 360), "
     "Powerquat 300 SL, Shirquat 250, Sinmosa 250, Sprayquat 250, "
     "Spraytop (250SL, 330)",
     "a", "22"),
    (H, "pendimethalin",
     "Charger 330 EC, Cronos 440EC, Pendimethalin (330, 330EC), Pendi-M 330",
     "a", "3"),
    (H, "pendimethalin",
     "Cyclone 330 EC, Panda 435, Pendimethalin (440, 440 EC)", "c", "3"),
    (H, "pine oil", "BioWeed", "a", "0"),
    (H, "quizalofop-P-ethyl",
     "Atomic 200 Selective, Elantra Xtreme, Leopard 200, Quiz, "
     "Quizalofop 200EC, Quizalofop-P-ethyl (200, 200 EC), Sextant",
     "a", "1"),
    (H, "quizalofop-P-ethyl", "Tiger Gold 250", "n", "1"),
    (H, "simazine",
     "Simanex 900 WG, Simaquest 900 WG, "
     "Simazine (500 Flowable, 900 DF, 900 WDG, 900 WG), S-Zine (600 SC, 900)",
     "a", "5"),
    (H, "trifluralin",
     "Trampoline 480, Treflan (480, 480 Selective, 600), Tricon Flexi 480, "
     "Tri-F 480, TriflurX, Trifluralin (480, 480 EC, Max 480), "
     "Trifluralinx (480, 580)",
     "a", "3"),
    # ---- INSECTICIDE (booklet p. 25) ----
    (I, "abamectin + chlorantraniliprole", "Voliam Targo", "a", "6 + 28"),
    (I, "acetamiprid + pyriproxyfen", "Fulcrum Veriphy DC, Kimura, Trivor", "a", "4A + 7C"),
    (I, "afidopyropen", "Versys", "a", "9D"),
    (I, "alpha-cypermethrin",
     "AlphaCy 100, Alpha Cyper 300SC, Alpha-Cypermethrin (100 EC, 300SC), "
     "Alpha Duo 100, Alphanex 100EC, Alpha-Scud 300 SC, Chieftain Duo 100EC, "
     "Cropro Buzzard, Ellias Plus 400 EC, Ken-Tac 100",
     "a", "3A"),
    (I, "alpha-cypermethrin",
     "Alpha Cypermethrin 250SC, Alpha Forte 250 SC", "c", "3A"),
    (I, "Bacillus thuringiensis subsp. aizawai", "Bacchus WG", "a", "11"),
    (I, "Bacillus thuringiensis subsp. kurstaki", "Delfin WG, DiPel DF", "a", "11"),
    (I, "bifenthrin",
     "Arrow 100 EC, Bifenthrin (100, 100 EC, 250 EC, 300 EC, Ultra 300 EC), "
     "Bifentin 100EC, Bi-Thrin 100EC, Cropro Zeus, Tal-Ken 100, Talstar 250 EC",
     "a", "3A"),
    (I, "bifenthrin", "Venom 240 SC", "o", "3A"),
    (I, "buprofezin",
     "Applaud, Buprofezin 440, Scale & Bug Insecticide, Uptown", "a", "16"),
    (I, "carbaryl", "Bugmaster Flowable, Carbaryl (500 SC, WG)", "d", "1A"),
    (I, "chlorantraniliprole",
     "Altacor X-Force, Shenzi, Solace Hort 700WG, Surefire Prynova 350 WG",
     "a", "28"),
    (I, "clothianidin", "Samurai", "a", "4A"),
    (I, "copper complex", "Escar-Go, Socusil", "a", None),
    (I, "cyflumetofen", "Danisaraba", "a", "25A"),
    (I, "emamectin",
     "Chicane, Clama 50SC, Oracle EC, Proclaim Opti, Surefire Exclaim 44 SG, "
     "Warlock",
     "b", "6"),
    (I, "esfenvalerate", "Sumi-Alpha Flex", "a", "3A"),
    (I, "etoxazole", "ParaMite", "a", "10B"),
    (I, "etoxazole + piperonyl butoxide", "Motto RMR", "a", "10B"),
    (I, "fipronil",
     "Albatross 200SC, Cannonball 200SC, Fipronil (200, 200 SC, 800 WG), "
     "Fiptron 200, Regal 800 WG, Region 200 SC, Seeker 200 SC, "
     "Surefire Vista 200SC",
     "a", "2B"),
    (I, "indoxacarb",
     "Avatar eVo, Indostar 300WG, Indoxacarb 300 WG, Spymaster 300 WG",
     "a", "22A"),
    (I, "iron EDTA complex",
     "Eradicate Snail and Slug Killer, Iron Chelate, "
     "Multiguard Snail and Slug Killer",
     "a", None),
    (I, "iron phosphate anhydrous", "Ironmax Pro", "a", None),
    (I, "iron powder", "Eradicate Eco Snail and Slug Bait, eco-shield", "a", None),
    (I, "metaldehyde",
     "Axcela Slug and Snail, Metakill, Metaldehyde Snail and Slug, "
     "Metarex Inov Snail + Slug, Snail + Slug, Pestmaster Snail + Slug, "
     "Slug Out, Snailex, Snail Trail",
     None, None),
    (I, "metaldehyde + fipronil", "Transcend", None, "2B"),
    # ---- INSECTICIDE (booklet p. 26) ----
    (I, "Metarhizium anisopliae var. acridum", "Green Guard SC Premium", "d", None),
    (I, "methiocarb", "Mesurol", None, "1A"),
    (I, "methomyl",
     "Activist 900 VeripHy SP, KDpc Metho, Electra 225, Landrin 225, "
     "Lannomyl 225, Lymo 225, Methomyl (225, 225 SL), Pirate, "
     "Seneca (Ultra 400SP), Sinmas 225",
     "d", "1A"),
    (I, "methoxyfenozide",
     "Caribou, Enigma 240 SC, Peregrine, Prodigy, Slate 240, Venturi Max",
     "a", "18"),
    (I, "orange oil", "Prev-Am", "a", None),
    (I, "paraffinic oil",
     "BioPest Paraffinic Oil, D-C-Maxx nC24, isoCLEAR HPO, Trump Spray Oil",
     "a", None),
    (I, "petroleum oil",
     "All Seasons White Oil, JMS Stylet-Oil, Summer Insecticidal Spray Oil, "
     "Stifle Dormant Spray Oil, Vicol (Summer Oil, Winter Oil)",
     "a", None),
    (I, "pyrethrins", "PyGanic", "a", "3A"),
    (I, "pyrethrins + piperonyl butoxide", "Py-Bo Natural Pyrethrum", "a", "3A"),
    (I, "pyriproxyfen", "Distance Plus", "a", "7C"),
    (I, "spinetoram", "Delegate", "a", "5"),
    (I, "spinosad",
     "Entrust Organic, Kobus 480SC, Naturalure, Preserve 120 SC", "a", "5"),
    (I, "spirotetramat",
     "Engaze 240 SC, Kersel 850 VeripHy WG, Movento 240 SC, SpiroSec 240 SC, "
     "Spirosure 240SC, Spirotetramat 240 SC, Viento 240 SC",
     "a", "23"),
    (I, "sulfoxaflor", "Transform", "a", "4C"),
    (I, "sulfur (elemental or crystalline)",
     "Cosamil, ecosulfur 800WG, InnoSulph 800 WG, Kumulus DF, "
     "Microsul WG Elite, Microthiol Disperss, Nimbus WG, Sulfur (800 WG), "
     "Thiovit Jet, Top Wettable Sulphur, Yellowstone 800 WG",
     "a", "M2"),
    (I, "sulfur as polysulfide", "Lime Sulphur", "a", "M2"),
    (I, "tebufenozide", "Ecdypro 700 WP", "a", "18"),
    (I, "trichlorfon", "Trepidex 500, Tyranex (500 SL, 500 VeripHy SL)", "a", "1B"),
    (I, "Trichogrammanza carverae", "Trichogramma parasitic wasp", None, None),
    # ---- PLANT GROWTH REGULATORS (booklet p. 26) ----
    (P, "chlormequat", "CC-77", "a", None),
    (P, "cyanamide", "Cyan, Dormex, Duomax HC520, Evenbloom", "a", None),
    (P, "ethephon",
     "Ethephon (720, 720 SL, 900), Ethon 720, K-Ethephon, Promote (Opti, Plus 900)",
     "g", None),
    (P, "gibberellic acid",
     "Gibberellic Acid 100 SL, Gibberellic Acid Growth Regulant, ProGibb SG, "
     "Windfall 800 SG",
     "a", None),
    (P, "methyl esters of fatty acids", "Waiken", "c", None),
]

# Cancelled products and last use date (booklet p. 29). These are AWRI's
# notice of cancellation/changed use patterns — they classify into the
# conflict/cancelled/lapsed bucket regardless of how their names resolve.
CANCELLED: list[dict[str, str]] = [
    {"awri_product_name": "Sumitomo Sumithion 1000EC",
     "active_constituent": "fenitrothion",
     "status": "Use quickly", "last_use_date": "2026-08-14"},
    {"awri_product_name": "Sumitomo Sumithion ULV premium grade",
     "active_constituent": "fenitrothion",
     "status": "Use quickly", "last_use_date": "2026-08-14"},
    {"awri_product_name": "Kenso Agcare Copper Hydroxide 350 WG",
     "active_constituent": "copper hydroxide",
     "status": "Use quickly", "last_use_date": "2026-08-25"},
    {"awri_product_name": "Jasper 520 EC",
     "active_constituent": "haloxyfop-R methyl ester",
     "status": "Use quickly", "last_use_date": "2026-08-25"},
    {"awri_product_name": "Fyfanon 440 EW",
     "active_constituent": "malathion",
     "status": "DO NOT USE", "last_use_date": "2026-05-01"},
]

# Transcription repairs: squashed strings that intentionally differ from a
# squashed-source hit because the PDF text carries a typo the booklet's print
# layout does not. Each entry maps repaired-squash -> source-squash it stands
# in for. Everything else must match the source text verbatim (squashed).
REPAIRS_ALLOWLIST: dict[str, str] = {
    # Booklet PDF has "Gibberelllic Acid Growth Regulant" (triple l).
    "gibberellicacidgrowthregulant": "gibberelllicacidgrowthregulant",
}

# Names transcribed WITHOUT a footnote glyph the PDF attaches directly to the
# word (D = registered for desuckering). Squash-verification tries these with
# the glyph re-appended.
DESUCKER_GLYPH_NAMES = {"Spotlight Plus", "Beloukha", "Slasher"}


def squash(s: str) -> str:
    return re.sub(r"[^a-z0-9]", "", s.lower())


def normalise_name(raw: str) -> str:
    """Mirror of the ingestion pipeline's normaliseProductName."""
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9]+", " ", raw.lower())).strip()


def split_top_level(cell: str) -> list[str]:
    """Split a products cell on commas that are not inside parentheses."""
    items: list[str] = []
    depth = 0
    cur = ""
    for ch in cell:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth = max(0, depth - 1)
        if ch == "," and depth == 0:
            items.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        items.append(cur.strip())
    return [i for i in items if i]


def expand_item(item: str) -> list[tuple[str, str]]:
    """Expand one products-cell item into (name, expansion_kind) pairs.

    Rules (deterministic, documented in docs/master-chemical-ingestion.md §17):
      * "Parent (V1, V2)" -> "Parent V1", "Parent V2"  (kind: variant)
      * additionally the bare "Parent" when the parentheses contain exactly
        ONE variant and it starts with a letter — the booklet's
        "also sold as" style, e.g. "Custodia (Forte)" -> Custodia +
        Custodia Forte  (kind: bare_parent)
      * no parentheses -> the item itself  (kind: plain)
    """
    m = re.fullmatch(r"(.+?)\s*\(([^()]+)\)\s*(.*)", item)
    if not m:
        return [(re.sub(r"\s+", " ", item).strip(), "plain")]
    parent, inner, tail = m.group(1).strip(), m.group(2).strip(), m.group(3).strip()
    if tail:
        raise SystemExit(f"unexpected text after parentheses in {item!r} — fix transcription")
    variants = [v.strip() for v in inner.split(",") if v.strip()]
    if not variants:
        raise SystemExit(f"empty variant list in {item!r}")
    out: list[tuple[str, str]] = []
    if len(variants) == 1 and variants[0][:1].isalpha():
        out.append((parent, "bare_parent"))
    for v in variants:
        out.append((re.sub(r"\s+", " ", f"{parent} {v}").strip(), "variant"))
    return out


def verify_against_source(names: list[str], source_text: str) -> list[str]:
    """Every transcribed raw item must appear in the squashed source text."""
    hay = squash(source_text)
    missing: list[str] = []
    for name in names:
        sq = squash(name)
        candidates = [sq, REPAIRS_ALLOWLIST.get(sq, sq)]
        if name in DESUCKER_GLYPH_NAMES:
            candidates.append(sq + "d")
        if not any(c in hay for c in candidates):
            missing.append(name)
    return missing


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", required=True, help="pypdf-extracted booklet text")
    ap.add_argument("--pdf", help="booklet PDF (hashed into provenance)")
    ap.add_argument("--out", required=True, help="manifest JSON output path")
    args = ap.parse_args()

    source_text = open(args.text, encoding="utf-8").read()

    # 1) Verify every transcribed raw item (pre-expansion) against the source.
    raw_items: list[str] = []
    for _, _, cell, _, _ in ROWS:
        raw_items.extend(split_top_level(cell))
    raw_items.extend(c["awri_product_name"] for c in CANCELLED)
    missing = verify_against_source(raw_items, source_text)
    if missing:
        for name in missing:
            print(f"TRANSCRIPTION NOT IN SOURCE: {name!r}", file=sys.stderr)
        raise SystemExit(f"{len(missing)} transcribed item(s) failed source verification")

    # 2) Expand variants and dedupe by the pipeline's normalised name.
    merged: dict[str, dict] = {}
    expansion_rank = {"plain": 0, "variant": 1, "bare_parent": 2}
    for section, active, cell, re_entry, group in ROWS:
        for item in split_top_level(cell):
            for name, kind in expand_item(item):
                key = normalise_name(name)
                if not key:
                    continue
                entry = merged.get(key)
                if entry is None:
                    entry = {
                        "awri_product_name": name,
                        "apvma_registration_number": None,
                        "active_constituents": [],
                        "activity_groups": [],
                        "re_entry_codes": [],
                        "sections": [],
                        "expansion": kind,
                        "listed_as": [],
                    }
                    merged[key] = entry
                if active not in entry["active_constituents"]:
                    entry["active_constituents"].append(active)
                if group and group not in entry["activity_groups"]:
                    entry["activity_groups"].append(group)
                if re_entry and re_entry not in entry["re_entry_codes"]:
                    entry["re_entry_codes"].append(re_entry)
                if section not in entry["sections"]:
                    entry["sections"].append(section)
                if item not in entry["listed_as"]:
                    entry["listed_as"].append(item)
                if expansion_rank[kind] < expansion_rank[entry["expansion"]]:
                    entry["expansion"] = kind

    entries = [merged[k] for k in sorted(merged.keys())]

    provenance = dict(SOURCE)
    if args.pdf:
        provenance["pdf_sha256"] = hashlib.sha256(open(args.pdf, "rb").read()).hexdigest()

    manifest = {
        "manifest_version": 1,
        "source": provenance,
        "table2_rows_transcribed": len(ROWS),
        "entries": entries,
        "cancelled_products": CANCELLED,
    }
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=1, ensure_ascii=False)
        fh.write("\n")

    kinds = {"plain": 0, "variant": 0, "bare_parent": 0}
    for e in entries:
        kinds[e["expansion"]] += 1
    print(f"rows transcribed:      {len(ROWS)}")
    print(f"unique products:       {len(entries)} "
          f"(plain {kinds['plain']}, variant {kinds['variant']}, bare_parent {kinds['bare_parent']})")
    print(f"cancelled list:        {len(CANCELLED)}")
    print(f"manifest written:      {args.out}")


if __name__ == "__main__":
    main()
