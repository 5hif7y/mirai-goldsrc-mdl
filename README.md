# goldsrc_mdl: GoldSrc models for Mirai

A plugin for the Mirai engine editor that imports studio models of GoldSrc (`.mdl`, version 10: Half-Life,
Counter-Strike 1.6) with the textures they keep and, for a model with bones and sequences, its skeleton and
one animation clip per sequence.

## Install

```sh
mirai plugin add goldsrc_mdl
```

Then import a `.mdl` from the editor. Like every format of a plugin, it imports in the editor and through
its API, not with `mirai import`.

## What it reads

- **Meshes:** of each body part, its first variant (what GoldSrc draws with body 0), as triangles from the
  strips and fans of its tricmds, with normals and texture coordinates.
- **Materials:** one per texture a mesh uses, with the 8-bit pixels and palette the model keeps; a texture
  with the masked flag imports with alpha cutout (palette index 255 transparent). A model that keeps no
  textures takes them, and its skin table, from `<name>T.mdl` beside it, as GoldSrc does.
- **Skeleton:** the bones with their rest pose. A vertex of a studio model lives in the space of its bone,
  without a bind pose, so every joint has the identity as inverse bind; one bone per vertex.
- **Clips:** each sequence with its frames, the rotation of every bone and the position of the bones that
  move. The position of the motion bone is zeroed on the axes its motion type asks for (`STUDIO_X`, `Y`,
  `Z`). A sequence of 9 blends (the aim grid of a Counter-Strike player) gives three clips: the middle, and
  `_up` and `_down`; other blended sequences give the blend nearest to looking ahead.
- **Sequence groups:** the frames of a sequence of another group come from the file its group names
  (`models/hostage01.mdl`, an `IDSQ` file), looked for beside the model.
- **Static models:** a model with one bone, or without sequences, imports static, with its rest pose baked
  into the vertices.
- **Units:** 32 to the meter, as the maps of the `valve220` plugin, Z up turned to Y up.

Importing a `T.mdl` or an `IDSQ` file on its own fails with a message that names what it is: they are parts
of a model, which reads them.

Not read: the other variants of a body part, skin families other than the first, hitboxes, attachments and
bone controllers, events of sequences, and additive textures (they import as opaque).

## Measured

On Windows 10, against the 179 `.mdl` files of a Counter-Strike 1.6 install, which are not in the
repository: the 169 models import; the other 10 are two texture files and eight sequence group files. A
player (`gsg9.mdl`): 766 triangles, 53 bones, 242 clips. A hostage with its sequences in eight group files:
591 triangles, 21 bones, 129 clips. A first-person weapon (`v_ak47.mdl`): 1 050 triangles, 42 bones, 6 clips.

## Tests

With `mirai test plugins/goldsrc_mdl/editor/mdl`. The models of the tests are written by the tests.

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
