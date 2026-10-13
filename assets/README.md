# zflac logo

A "Z" set in FLAC's level-meter bars. The same Z is the initial of the
wordmark — there is only ever one Z in the logo.

- **meter bars** (red hot / green cold) are the top and bottom strokes, borrowed
  from the FLAC logo's level indicator.
- **diagonal** is a lightning bolt in Zig orange: two parallel strokes joined by
  one angled jog, cut flat the way the Zig mark bevels its Z stroke. It is the
  only diagonal in the mark, and the only place the mark stops being a grid.
- **plate** (icon and badge only) is FLAC's black slab, chamfered at 45° like the
  corners of the Zig logomark.
- **`flac`** is drawn as paths, not a font: geometric lowercase, 22-unit stroke
  on a 100-unit x-height, `c` mouth cut at 45° to echo the bevels. The Z is
  scaled to the same x-height and stroke weight so it sits in the word as a
  letter.

## Files

| file | viewBox | use |
|---|---|---|
| `zflac-badge.svg` | 920×320 | primary — READMEs, docs, site header; carries its own plate, reads on any background |
| `zflac-lockup.svg` | 786×226 | transparent plate, ink wordmark — light backgrounds |
| `zflac-mark.svg` | 512×512 | icon with plate — favicon, app icon, avatar |
| `zflac-mark-mono.svg` | 512×512 | one colour, inherits `currentColor` — ≤32px, print, stencils |

## Palette

| role | hex |
|---|---|
| plate / ink | `#0e1116` |
| meter hot | `#e8382c` |
| meter cold | `#2ea02a` |
| zig stroke | `#f7a41d` |
| wordmark on plate | `#f4f6f8` |

## Usage

```md
[![zflac](assets/zflac-badge.svg)](https://github.com/ludiazv/zflac)
```

- Clear space: one meter bar (60 units in the 512 grid) on every side.
- Minimum sizes: badge 240px wide, mark 32px, mono mark 16px.
- Never recolour the meter bars independently, and never pair the mark with a
  second "z" — the Z in the wordmark *is* the logomark.
- Keep the bolt's jog: straightening the diagonal turns the mark back into an
  ordinary Z and loses the Zig reference.
- On photos or unknown backgrounds use the badge.

## Note

Original artwork, MIT (same as the code). It is an homage: the FLAC level-meter
design is © Mike Wren / Xiph.Org and the Z stroke and orange are the Zig
logomark, © Zig Software Foundation. zflac is not affiliated with either, and
neither's actual letterforms or logomarks are reproduced here.
