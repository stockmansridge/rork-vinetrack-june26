"""Read physical tables from the retained PDF. Local diagnostic only; never promotes label claims."""
import contextlib
import hashlib
import io
import json
import pathlib
import pymupdf

pdf = pathlib.Path(__file__).with_name("weedmaster_duo_documented.pdf")
expected = "69213c077e191e99682e515884d7667156367ea7ab927ecdac2882f4d0ec39b8"
assert hashlib.sha256(pdf.read_bytes()).hexdigest() == expected
with pymupdf.open(pdf) as document:
    assert len(document) == 15
    with contextlib.redirect_stdout(io.StringIO()):
        page9_tables = document[8].find_tables().tables
    vineyard = next((table for table in page9_tables
                     if table.col_count == 4 and any("TREE AND VINE CROPS:" in (row[0] or "")
                                                      for row in table.extract())), None)
    assert vineyard is not None
    vine_rows = [row for row in vineyard.extract() if "TREE AND VINE CROPS:" in (row[0] or "")]
    assert len(vine_rows) == 1
    crops, references, vineyard_rate, comments = vine_rows[0]
    assert "Vineyards" in crops and "ANNUAL WEED CONTROL" in references and "PERENNIAL WEED CONTROL" in references
    assert vineyard_rate is None
    tables = []
    for number in (2, 3, 4, 5):
        page = document[number - 1]
        with contextlib.redirect_stdout(io.StringIO()):
            page_tables = page.find_tables().tables
        for table in page_tables:
            cells = table.extract()
            if number == 2 and cells and cells[0][0] == "SITUATION" and "WEED" in cells[0][1]:
                tables.append({"page": number, "kind": "annual", "heading": cells[0], "rows": cells[1:]})
            # Page 5 has a SECOND 5-column table, BRUSH AND WOODY WEEDS; it is not Table 3.
            if number in (3, 4, 5) and (number != 5 or not any(t["page"] == 5 for t in tables)) and cells and cells[0][0] == "WEEDS" and table.col_count == 5 and "RATE" in cells[0]:
                tables.append({"page": number, "kind": "perennial", "heading": cells[:2], "rows": cells[2:]})
    assert len(tables) == 4
    print(json.dumps({"sha256": expected, "physical_pages": len(document), "page_1_text": document[0].get_text().strip(),
                      "vineyard": {"physical_page": 9, "crop_cell": crops, "reference_cell": references,
                                   "rate_cell": vineyard_rate, "comments_cell": comments},
                      "tables": tables}, ensure_ascii=False))
