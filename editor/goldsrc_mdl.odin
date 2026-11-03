package goldsrc_mdl_editor

import "mirai:editor"
import mdl "project:plugins/goldsrc_mdl/editor/mdl"

// Studio models of GoldSrc (.mdl, version 10) in the import of the editor:
// meshes with the textures the file keeps, and, for a model with bones and
// sequences, its skeleton and a clip per sequence (mdl/mdl.odin).

@(storage)
Goldsrc_Mdl_Format :: struct {provider:editor.Import_Format_Provider}

goldsrc_mdl_format_default :: proc() -> Goldsrc_Mdl_Format {
    return {provider={format=mdl.FORMAT}}
}
