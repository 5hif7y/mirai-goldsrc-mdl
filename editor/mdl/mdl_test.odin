package goldsrc_mdl_reader

import "core:encoding/endian"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import importer "mirai:cook/import"

// A studio model written in code: two bones, the child 16 units along y and
// free to turn about z (yaw); one triangle, two corners on the root and one
// on the child; a 4x4 texture whose palette makes every texel (10 20 30); and,
// unless static, a sequence "idle" of two frames that turns the child 1 radian.

@(private="file")
put :: proc(b:[]u8,at:int,v:$T) {
    when T==i32 {endian.put_i32(b[at:at+4],.Little,v)}
    else when T==f32 {endian.put_f32(b[at:at+4],.Little,v)}
    else when T==i16 {endian.put_i16(b[at:at+2],.Little,v)}
    else when T==u16 {endian.put_u16(b[at:at+2],.Little,v)}
}

@(private="file")
put_text :: proc(b:[]u8,at:int,text:string) {copy(b[at:],text)}

@(private="file")
two_bone_model :: proc(sequences:bool) -> []u8 {
    b:=make([]u8,3000,context.temp_allocator)
    copy(b,"IDST")
    put(b,4,i32(10))
    put_text(b,8,"test")
    h:=HEADER_INTS
    put(b,h,i32(2));put(b,h+4,i32(300))                 // bones
    put(b,h+24,i32(1 if sequences else 0));put(b,h+28,i32(2200)) // sequences
    put(b,h+40,i32(1));put(b,h+44,i32(600))              // textures
    put(b,h+52,i32(1));put(b,h+56,i32(1));put(b,h+60,i32(1500)) // skin refs, families, table
    put(b,h+64,i32(1));put(b,h+68,i32(1520))             // body parts
    // bones: root, and child at (0 16 0) whose yaw channel is scaled 0.01
    put_text(b,300,"root");put(b,300+32,i32(-1))
    put_text(b,412,"child");put(b,412+32,i32(0))
    put(b,412+64+4,f32(16))
    put(b,412+88+4*4,f32(0.01))
    // texture: 4x4 of index 1, palette entry 1 is (10 20 30)
    put_text(b,600,"skin");put(b,600+68,i32(4));put(b,600+72,i32(4));put(b,600+76,i32(700))
    for i in 0..<16 {b[700+i]=1}
    b[716+3],b[716+4],b[716+5]=10,20,30
    put(b,1500,i16(0))
    // body part and its model
    put_text(b,1520,"body");put(b,1520+64,i32(1));put(b,1520+68,i32(1));put(b,1520+72,i32(1600))
    put_text(b,1600,"body")
    put(b,1600+72,i32(1));put(b,1600+76,i32(1800))
    put(b,1600+80,i32(3));put(b,1600+84,i32(1850));put(b,1600+88,i32(1900))
    put(b,1600+92,i32(3));put(b,1600+96,i32(1860));put(b,1600+100,i32(2000))
    put(b,1800,i32(1));put(b,1800+4,i32(2100));put(b,1800+8,i32(0))
    b[1850],b[1851],b[1852]=0,0,1
    b[1860],b[1861],b[1862]=0,0,1
    verts:=[3][3]f32{{0,0,0},{16,0,0},{0,0,0}}
    for v,i in verts {for k in 0..<3 {put(b,1900+i*12+k*4,v[k])}}
    for i in 0..<3 {put(b,2000+i*12+8,f32(1))}
    // a strip of three corners
    put(b,2100,i16(3))
    corners:=[3][4]i16{{0,0,0,0},{1,1,4,0},{2,2,0,4}}
    for c,i in corners {for k in 0..<4 {put(b,2102+i*8+k*2,c[k])}}
    put(b,2126,i16(0))
    // the sequence: 2 frames at 10 per second, one blend, frames at 2400
    put_text(b,2200,"idle");put(b,2200+32,f32(10));put(b,2200+56,i32(2))
    put(b,2200+120,i32(1));put(b,2200+124,i32(2400))
    // the child's yaw (channel 4): run of two values, 0 and 100
    put(b,2412+4*2,u16(12))
    b[2424],b[2425]=2,2
    put(b,2426,i16(0));put(b,2428,i16(100))
    return b
}

@(private="file")
import_bytes :: proc(t:^testing.T,bytes:[]u8,name:string) -> (model:importer.Imported_Model,ok:bool) {
    directory,_:=os.temp_directory(context.temp_allocator)
    folder,_:=strings.replace_all(fmt.tprintf("%s/mirai-goldsrc-mdl-%d-%s",directory,os.get_pid(),name),"\\","/",context.temp_allocator)
    os.remove_all(folder)
    os.make_directory_all(folder)
    defer os.remove_all(folder)
    path:=fmt.tprintf("%s/%s.mdl",folder,name)
    testing.expect(t,os.write_entire_file(path,bytes)==nil)
    formats:=[?]importer.Format{FORMAT}
    error:importer.Error
    model,error=importer.import_model(path,formats[:],{})
    if !testing.expectf(t,error.code==.None,"%v %s",error.code,error.message) {return}
    return model,true
}

@(test)
a_model_with_bones_and_a_sequence_imports_skinned :: proc(t:^testing.T) {
    model,ok:=import_bytes(t,two_bone_model(true),"skinned")
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.meshes),1)
    if len(model.meshes)!=1 {return}
    mesh:=model.meshes[0]
    testing.expect_value(t,len(mesh.indices)/3,1)
    testing.expect(t,len(mesh.skin)==len(mesh.vertices) && len(mesh.joints)==2,"one joint per bone and a skin per vertex")
    testing.expect(t,len(model.skeletons)==1 && len(model.skeletons[0].bones)==2,"a skeleton of two bones")
    if !testing.expect_value(t,len(model.animations),1) {return}
    clip:=model.animations[0]
    testing.expect_value(t,clip.name,"idle")
    turned:=false
    for track in clip.tracks {
        if track.property!=.Rotation || !strings.has_suffix(track.target,"child") || len(track.keys)!=2 {continue}
        // a turn of 1 radian about z of GoldSrc: w = cos(0.5)
        turned=abs(track.keys[0].value.w-1)<1e-4 && abs(abs(track.keys[1].value.w)-math.cos(f32(0.5)))<1e-3
    }
    testing.expect(t,turned,"the child turns 1 radian between the two frames")
    if !testing.expect_value(t,len(model.images),1) {return}
    image:=model.images[0]
    testing.expect(t,image.made.width==4 && image.made.texels[0]==10 && image.made.texels[1]==20 && image.made.texels[2]==30,"the texels and palette of the file")
}

@(test)
a_model_without_sequences_imports_static_in_its_rest_pose :: proc(t:^testing.T) {
    model,ok:=import_bytes(t,two_bone_model(false),"static")
    if !ok {return}
    defer importer.model_destroy(&model)
    if !testing.expect_value(t,len(model.meshes),1) {return}
    mesh:=model.meshes[0]
    testing.expect(t,len(mesh.skin)==0 && len(model.skeletons)==0 && len(model.animations)==0,"no skeleton for a static model")
    // the corner on the child is at (0 16 0) of GoldSrc: 0.5 m along -z of the engine
    found:=false
    for v in mesh.vertices {found||=abs(v.position.z+0.5)<1e-4 && abs(v.position.x)<1e-4}
    testing.expect(t,found,"the rest pose of the child is baked into its corner")
}

// A model that keeps no textures takes them, and its skin table, from <name>T.mdl beside it.
@(test)
a_model_takes_its_textures_from_its_t_file :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    folder,_:=strings.replace_all(fmt.tprintf("%s/mirai-goldsrc-mdl-%d-tfile",directory,os.get_pid()),"\\","/",context.temp_allocator)
    os.remove_all(folder)
    os.make_directory_all(folder)
    defer os.remove_all(folder)
    model_bytes:=two_bone_model(false)
    put(model_bytes,HEADER_INTS+40,i32(0)) // no textures of its own
    put(model_bytes,HEADER_INTS+52,i32(0))  // nor skin table
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/prop.mdl",folder),model_bytes)==nil)
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/propT.mdl",folder),two_bone_model(false))==nil)
    formats:=[?]importer.Format{FORMAT}
    model,error:=importer.import_model(fmt.tprintf("%s/prop.mdl",folder),formats[:],{})
    if !testing.expectf(t,error.code==.None,"%v %s",error.code,error.message) {return}
    defer importer.model_destroy(&model)
    testing.expect(t,len(model.images)==1 && model.images[0].made.texels[0]==10,"the texels of the T file")
}
