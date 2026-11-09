# SkadisModeler

See how your 3D-printed **IKEA SKÅDIS** pegboard designs fit before you print
them. Pick a board, add your STL or 3MF models, and drag them from slot to slot
in 3D. Anything that overlaps, misses the slots or hangs off the board turns red
and says why.

macOS 13 or later, Apple Silicon or Intel.

## Install

Download [`updates/SkadisModeler.zip`](updates/SkadisModeler.zip), unzip it and
double-click **Install SkadisModeler.command**. If macOS blocks it, right-click
it, choose Open, then Open again. The app goes into `~/Applications` and keeps
itself up to date from this repo (**SkadisModeler ▸ Check for Updates…**).

## Using it

- **Board**: with nothing selected, the panel on the right picks the board:
  IKEA 36 × 56, 56 × 56, 76 × 56 and 76 × 100 cm, boards built from 240 mm
  printed tiles, or any custom size. White, black, wood or grey.
- **Add models**: click **+**, drop files on the window, or point the
  **Library** list at the folder that holds your designs and double-click one.
  STL and 3MF both work. A 3MF with several objects adds each one.
- **Move**: drag a model and it snaps from slot to slot. The arrow keys move the
  selected model 40 mm; Option-arrow moves a single column (20 mm across, 20 mm
  up or down, the way the slots are staggered). Turn off **Snap to Slots** to
  place things to the millimetre.
- **Look around**: drag the board to orbit, right-drag (or Shift-drag) to pan,
  scroll or pinch to zoom. **Front**, **Side** and **Top** are flat views with
  no perspective, so sizes and gaps read true. Side shows how far things stick
  out and where the hooks sit behind the board.
- **Fit**: select a model to see its size, how far it sticks out, where its
  edges are from the board's edges, and anything wrong with where it is.
- **Turn**: Spin, Tip and Swing give all 24 right-angle orientations for models
  that weren't drawn hanging. **Find Hooks Again** puts it back.
- **Layouts**: the board you're working on is remembered between launches.
  **File ▸ Save Layout** writes a `.skadis` file you can open again. Layouts
  point at your model files, so re-export a design and reopen the layout to see
  the new version in place.

## Planning a board with an LLM

The app carries a command-line tool, `skadis`, so an AI assistant that can run
shell commands (Claude Code, for one) can plan a board for you: measure your
models, try a layout, check it fits, look at it, and try again.

```bash
~/Applications/SkadisModeler.app/Contents/MacOS/skadis help
```

| Command | What it does |
|---|---|
| `skadis boards` | The boards it knows |
| `skadis inventory <folder>` | Every model's width, height, how far it sticks out, and its hooks |
| `skadis pack --board ikea76x56 <models…>` | Fit models in order from the top-left |
| `skadis arrange plan.json -o board.skadis --render board.png` | Place models where a plan says, write a layout the app opens, and draw it |
| `skadis check board.skadis` | Where everything is and every problem |
| `skadis render board.skadis -o board.png` | Draw it: `--view front` (flat, with name labels), `side`, `top` or `3d` |

Results are JSON. A plan is a short JSON file: a board, and for each model a
file and, if you care where it goes, the `left` and `top` of its edges in
millimetres from the board's left and top edges. Anything without a position is
fitted into the free space.

```json
{"board": "ikea76x56",
 "items": [
   {"file": "Drill Holder/drill_holder.3mf", "name": "Drill", "left": 600, "top": 380},
   {"file": "Mic Holder/mic_holder.3mf", "name": "Mics", "left": 30, "top": 30},
   {"file": "Pliers Holder/pliers_holder.stl"}
 ]}
```

To use it, tell your assistant what matters and let it iterate. For example:

> Run `~/Applications/SkadisModeler.app/Contents/MacOS/skadis help`, then plan
> my 76 × 56 board from the models in `~/3D Prints/Skadis`. Mics together at
> the top left, hand tools along the right, heavy things low, and leave 60 mm
> under each holder for the tool. Keep going until `skadis check` says it fits,
> then show me the picture.

The tool guarantees the result physically fits; what counts as a good layout is
up to what you tell the assistant. Open the `.skadis` file it writes in
SkadisModeler to adjust by hand. Drawing pictures needs the Mac's graphics, so
`render` has to run in a normal Terminal session, not a sandbox.

## How it finds the hooks

SKÅDIS slots are 5 × 15 mm, in columns 20 mm apart, 40 mm apart within a
column, with every other column shifted 20 mm. SkadisModeler looks for the
model's biggest flat rear face (the part that sits against the board) and the
thin tongues poking out behind it. Each tongue that reaches right through the
5 mm board is a hook, and its slot is placed so the tongue rests on the slot's
bottom end. A model exported with X out from the board, Y along it and Z up
needs no turning; otherwise all 24 right-angle orientations are tried.

Then it checks, for wherever you've put the model:

- every hook column lands in a real slot, and its lower peg has one too
- nothing overlaps another model (hollow shapes count as full, since a cup is
  there to hold something)
- how far it hangs past the board's edges

Models with no hooks it recognises can still be placed, by their back face.

### What it can't tell you

- **IKEA's edge margins.** The slot pattern is centred on IKEA boards. Slot
  size and spacing are the real ones, but measure from your board's edge to its
  first slot before trusting how close something sits to the edge.
- **Clearance for getting hooks in.** A hook has to be lifted about 6 mm and
  pushed in. SkadisModeler shows where things end up, not whether there's room
  above to get them there.
- **Whether the tool itself fits.** It checks holder against holder. Leave room
  for what goes in them.

## Errors

Every error has a code like `SM-203`, with what happened and what to try in
[ERRORS.md](ERRORS.md).

## Building

Command Line Tools are enough (`xcode-select --install`), no Xcode project.

```bash
./build.sh        # SkadisModeler.app for this Mac
./install.sh      # build, copy to ~/Applications, open
./test.sh         # offline checks: readers, slot pattern, hook finding, overlaps
./release.sh      # universal build + updates/SkadisModeler.zip + updates/latest.json
```

`./test.sh --scan <folder>` lists what's found in every model under a folder
(triangles, size, hook columns), which is the quickest way to see whether a
design's hooks are recognised. `./snapshot.sh <out folder> <models…>` renders
the board and the window to PNGs and drives the 3D view with mouse events.

Source layout: `Mesh.swift` and `ThreeMF.swift` read models, `Board.swift` is
the slot pattern, `Analysis.swift` finds hooks and footprints, `Layout.swift`
does the fit checks, `Scene.swift` and `BoardView.swift` are the SceneKit scene,
camera and mouse handling,
`Planner.swift` reads plans and writes fit reports, `AppModel.swift` ties it
together, `Views.swift` is the SwiftUI window, and `Tools/skadis` is the command.

## Privacy

SkadisModeler only reads the model files you add. No accounts, no analytics.
The only thing it fetches is a small version file from this repo, to see
whether an update exists.

MIT licence. Not affiliated with IKEA.
