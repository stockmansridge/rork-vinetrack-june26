export const CROPSURE_CATALOGUE_URL = "https://cropsure.com/fungicide/";
export const CROPSURE_GREENSHIELD_LABEL_URL =
  "https://cropsure.com/wp-content/uploads/2023/10/cropsure-greenshield-750wg-fungicide-label.pdf";

/** Minimal reproduction of CropSure's generic catalogue page and exact label anchor. */
export const CROPSURE_CATALOGUE_HTML = `<!doctype html>
<html>
  <head><title>Fungicide | CropSure</title></head>
  <body>
    <h1>Fungicide</h1>
    <section>
      <a href="/wp-content/uploads/2023/10/cropsure-greenshield-750wg-fungicide-label.pdf">
        Greenshield 750WG Fungicide Label Download
      </a>
      <a href="/wp-content/uploads/2023/10/cropsure-greenshield-750wg-fungicide-sds.pdf">
        CropSure Greenshield 750WG Fungicide SDS
      </a>
      <a href="/wp-content/uploads/2023/10/unrelated-product-label.pdf">
        Unrelated Product Label
      </a>
    </section>
  </body>
</html>`;
