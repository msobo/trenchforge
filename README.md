# TrenchForge

Blockout level design with textures, directly in the Godot 3D viewport. TrenchForge builds levels from convex brushes, inspired by [TrenchBroom](https://github.com/TrenchBroom/TrenchBroom) and [Anvil Level Design](https://anvilleveldesign.com/docs/intro/).

Levels are regular Godot scenes (`.tscn`). There is no external editor and no import step, and a finished level only needs standard Godot nodes at runtime.

## Requirements

Godot **4.7** or later (Forward+).

## Installation

1. Download the latest version from the [Releases](../../releases) page.
2. Copy the `addons/trenchforge/` folder into your project, so that it ends up at `res://addons/trenchforge/`.
3. Open *Project → Project Settings → Plugins* and enable **TrenchForge**.
4. Put your textures (PNG, JPG, …) in `res://textures`. You can add more folders under *Project Settings → TrenchForge → Texture Roots*.

You now have a TrenchForge toolbar in the 3D view, the docks **TF Materials** and **TF Face**, and the bottom panels **TrenchForge** (settings) and **TF UV** (UV editor).

The interface is in English by default. To switch to German, set *TrenchForge → Editor → Interface → Language* in the settings panel.

## Tutorial: your first room

This builds a textured room with a doorway in about ten minutes. `Ctrl` means `Cmd` on macOS. Shortcuts work while the 3D viewport has focus and a map is being edited.

1. **Create a map.** Choose *Scene → New Scene → Other Node*, select `TFMap`, and save the scene. Select the map to show the toolbar.
2. **Pick a material.** Click a texture in the **TF Materials** dock. New brushes use this material.
3. **Draw a block.** Press `B` for the Box tool. Click once for the first corner, again for the opposite corner, and a third time for the height. Try 10 × 4 × 10 m. `[` and `]` halve and double the grid.
4. **Hollow it out.** With the new brush selected, press `Ctrl+Shift+H`. The block becomes six walls.
5. **Cut a door.** Press `Shift+C` for Cube-Cut, click a wall, drag a rectangle, drag the depth through the wall, and click to confirm.
6. **Paint textures.** Pick a material, then click or drag over faces with **Alt+LMB**. **Alt+RMB** picks up the material and UVs of a face. `Tab` toggles face mode for selecting single faces.
7. **Play it.** Add a light and your own `CharacterBody3D` with a camera, then press `F6`. TrenchForge rebuilds outdated maps before the game starts, and `Ctrl+B` builds right away.

All shortcuts can be changed under *Editor → Editor Settings → TrenchForge → Shortcuts*.

## License

[MIT](LICENSE)
