# Thesis LaTeX (Overleaf-ready)

Upload this whole folder as an Overleaf project (zip the contents of `docs/latex/`, not the parent `docs/` tree).

## Overleaf settings

| Setting | Value |
| ------- | ----- |
| Main document | `manuscript.tex` |
| Compiler | **pdfLaTeX** |
| TeX Live | any recent image |

Bibliography is produced by `icsthesis.cls` via `\makereferences{references}` (apacite + `references.bib`). Overleaf usually runs BibTeX automatically; if citations are `?`, do a full recompile (Recompile from scratch).

## Contents

- `manuscript.tex` — thesis body
- `icsthesis.cls` — ICS thesis class
- `references.bib` — BibTeX
- `figures/fig*.png` — Chapter 2 and Chapter 3 figures (paths match `\includegraphics`; matplotlib builds from `docs/reviews/sp1-methods/build_figures.py` and `scripts/build_workflow_figure.py`)

Canonical figure sources for the SLR workflow remain under `docs/reviews/sp1-methods/figures/`. After regenerating a figure, copy the new `fig*.png` files into `figures/` before re-uploading.
