package goldsrc_mdl_reader

import "core:encoding/endian"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/textures"
import anim "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

// Models of GoldSrc (Half-Life, Counter-Strike 1.6): studio models, version 10
// of the format of studio.h. The reader takes:
//
// - the bones, their rest pose (position and angles) and the scale of their
//   animated channels;
// - of each body part, the first of its variants (R_StudioSetupModel with body
//   0): its vertices and normals, the bone of each, and its meshes as "tricmds",
//   the strips and fans of GoldSrc, with their skin reference;
// - the textures the file keeps: 8-bit indices and a palette, with the masked
//   flag (index 255 transparent);
// - the sequences: each a clip with the rotation of every bone and the position
//   of those that move. The frames of a sequence of group 0 are in the model;
//   those of another group, in the file its group names (models/x01.mdl, an
//   IDSQ file), looked for beside the model.
// - a model that keeps no textures takes them, with its skin table, from
//   <name>T.mdl beside it, as GoldSrc does.
//
// A vertex of a studio model lives in the space of its bone, and the bone takes
// it to its place (R_StudioDrawPoints): there is no bind pose, so the inverse
// bind of every joint is the identity. A model with one bone, or without
// sequences in the file, imports static: its rest pose baked into the vertices.

MAGIC :: "IDST"
VERSION :: 10
HEADER_INTS :: 140 // offset of numbones in studiohdr_t
SEQUENCE_GROUP_SIZE :: 104
BONE_SIZE :: 112
TEXTURE_SIZE :: 80
BODYPART_SIZE :: 76
MODEL_SIZE :: 112
MESH_SIZE :: 20
SEQUENCE_SIZE :: 176
NF_MASKED :: 0x0040
PALETTE_BYTES :: 768

FORMAT :: importer.Format{
    name="GoldSrc model",
    extensions={0=".mdl"},
    version=0,
    // X forward, Y left, Z up, in the units of the maps: 32 to the meter, as valve220
    space={meters_per_unit=1.0/32,axes={.X,.Z,.Negative_Y},v_origin=.Top},
    sniff=sniff,
    read=read,
}

// IDST and version 10. Version 6 (the models of Quake) and the studio models of
// Source (IDST 44 and later) start the same way and are not this.
sniff :: proc(head:[]u8) -> importer.Sniff {
    if len(head)>=4 && string(head[:4])=="IDSQ" {return .Content} // read tells what it is
    if len(head)<8 || string(head[:4])!=MAGIC {return .No}
    version,_:=endian.get_i32(head[4:8],.Little)
    return .Content if version==VERSION else .No
}

Bone :: struct {
    name:string,
    parent:int,
    value:[6]f32, // position xyz, then angles in radians
    scale:[6]f32, // of each animated channel
}

Texture :: struct {
    name:string,
    flags:i32,
    width,height:int,
    offset:int,
}

Sequence :: struct {
    label:string,
    fps:f32,
    frames:int,
    motion_type:i32,
    motion_bone:int,
    blends:int,
    anim_index:int,
    blend_start,blend_end:f32,
    group:int,
}

Header :: struct {
    name:string,
    bones,bone_index:int,
    sequences,sequence_index:int,
    groups,group_index:int,
    textures,texture_index:int,
    skin_refs,skin_families,skin_index:int,
    body_parts,body_part_index:int,
}

@(private)
Mdl :: struct {
    d:[]u8,
    h:Header,
}

@(private)
i32_at :: proc(d:[]u8,at:int) -> int {
    if at<0 || at+4>len(d) {return 0}
    v,_:=endian.get_i32(d[at:at+4],.Little)
    return int(v)
}

@(private)
i16_at :: proc(d:[]u8,at:int) -> int {
    if at<0 || at+2>len(d) {return 0}
    v,_:=endian.get_i16(d[at:at+2],.Little)
    return int(v)
}

@(private)
u16_at :: proc(d:[]u8,at:int) -> int {
    if at<0 || at+2>len(d) {return 0}
    v,_:=endian.get_u16(d[at:at+2],.Little)
    return int(v)
}

@(private)
f32_at :: proc(d:[]u8,at:int) -> f32 {
    if at<0 || at+4>len(d) {return 0}
    v,_:=endian.get_f32(d[at:at+4],.Little)
    return v
}

@(private)
cstring_at :: proc(d:[]u8,at,size:int) -> string {
    if at<0 || at+size>len(d) {return ""}
    raw:=d[at:at+size]
    end:=0
    for end<size && raw[end]!=0 {end+=1}
    return string(raw[:end])
}

header_read :: proc(d:[]u8) -> (h:Header,message:string,ok:bool) {
    if len(d)<HEADER_INTS+72 || string(d[:4])!=MAGIC {return h,"not a studio model of GoldSrc (no IDST)",false}
    if v:=i32_at(d,4);v!=VERSION {return h,fmt.tprintf("version %d: this reads version 10",v),false}
    h.name=cstring_at(d,8,64)
    o:=HEADER_INTS
    h.bones,h.bone_index=i32_at(d,o),i32_at(d,o+4)
    h.sequences,h.sequence_index=i32_at(d,o+24),i32_at(d,o+28)
    h.groups,h.group_index=i32_at(d,o+32),i32_at(d,o+36)
    h.textures,h.texture_index=i32_at(d,o+40),i32_at(d,o+44)
    h.skin_refs,h.skin_families,h.skin_index=i32_at(d,o+52),i32_at(d,o+56),i32_at(d,o+60)
    h.body_parts,h.body_part_index=i32_at(d,o+64),i32_at(d,o+68)
    if h.bones<0 || h.bones>128 || h.textures<0 || h.body_parts<0 || h.sequences<0 {return h,"the counts of the header are not those of a model",false}
    return h,"",true
}

bones_read :: proc(d:[]u8,h:Header,allocator:=context.allocator) -> []Bone {
    out:=make([]Bone,h.bones,allocator)
    for &b,i in out {
        at:=h.bone_index+i*BONE_SIZE
        b.name=cstring_at(d,at,32)
        b.parent=i32_at(d,at+32)
        for k in 0..<6 {b.value[k]=f32_at(d,at+64+k*4);b.scale[k]=f32_at(d,at+88+k*4)}
    }
    return out
}

textures_read :: proc(d:[]u8,h:Header,allocator:=context.allocator) -> []Texture {
    out:=make([]Texture,h.textures,allocator)
    for &t,i in out {
        at:=h.texture_index+i*TEXTURE_SIZE
        t.name=cstring_at(d,at,64)
        t.flags=i32(i32_at(d,at+64))
        t.width,t.height,t.offset=i32_at(d,at+68),i32_at(d,at+72),i32_at(d,at+76)
    }
    return out
}

sequences_read :: proc(d:[]u8,h:Header,allocator:=context.allocator) -> []Sequence {
    out:=make([]Sequence,h.sequences,allocator)
    for &s,i in out {
        at:=h.sequence_index+i*SEQUENCE_SIZE
        s.label=cstring_at(d,at,32)
        s.fps=f32_at(d,at+32)
        s.frames=i32_at(d,at+56)
        s.motion_type,s.motion_bone=i32(i32_at(d,at+68)),i32_at(d,at+72)
        s.blends,s.anim_index=i32_at(d,at+120),i32_at(d,at+124)
        s.blend_start,s.blend_end=f32_at(d,at+136),f32_at(d,at+144)
        s.group=i32_at(d,at+156)
    }
    return out
}

// The quaternion of the angles of GoldSrc (radians: pitch about x, yaw about y,
// roll about z, the order of AngleQuaternion), as x y z w.
studio_quaternion :: proc(angles:[3]f32) -> mm.Vec4 {
    sr,cr:=math.sin(angles.x/2),math.cos(angles.x/2)
    sp,cp:=math.sin(angles.y/2),math.cos(angles.y/2)
    sy,cy:=math.sin(angles.z/2),math.cos(angles.z/2)
    return {sr*cp*cy-cr*sp*sy,cr*sp*cy+sr*cp*sy,cr*cp*sy-sr*sp*cy,cr*cp*cy+sr*sp*sy}
}

@(private)
quat_of :: proc(v:mm.Vec4) -> quaternion128 {return quaternion(real=v.w,imag=v.x,jmag=v.y,kmag=v.z)}

// The value of a channel of a bone in a frame: rest value plus key times scale,
// walking the run-length values as R_StudioCalcBones. A channel with offset 0
// is not animated and keeps the rest value.
channel_value :: proc(d:[]u8,bones:[]Bone,anim_at,bone,index,frame:int) -> f32 {
    rest,factor:=bones[bone].value[index],bones[bone].scale[index]
    entry:=anim_at+bone*12
    offset:=u16_at(d,entry+index*2)
    if offset==0 {return rest}
    at:=entry+offset
    if at+2>len(d) {return rest}
    j:=frame
    valid,total:=int(d[at]),int(d[at+1])
    if total<valid {j=0}
    for total<=j {
        j-=total
        at+=(valid+1)*2
        if at+2>len(d) || total==0 {return rest}
        valid,total=int(d[at]),int(d[at+1])
        if total<valid {j=0}
    }
    slot:=j+1 if valid>j else valid
    return rest+f32(i16_at(d,at+slot*2))*factor
}

// The blends of a sequence to import: the one that looks ahead and, in the
// grid of 3x3 of a player of Counter-Strike, the middle column up and down.
blends_of :: proc(s:Sequence) -> (rows:[3]int,suffixes:[3]string,count:int) {
    neutral:=0
    switch {
    case s.blends==9:
        neutral=4
    case s.blends>1 && s.blend_end!=s.blend_start:
        t:=(0-s.blend_start)/(s.blend_end-s.blend_start)
        neutral=clamp(int(math.round(t*f32(s.blends-1))),0,s.blends-1)
    }
    rows[0],suffixes[0],count=neutral,"",1
    if s.blends==9 {
        rows[1],suffixes[1]=1,"_up"
        rows[2],suffixes[2]=7,"_down"
        count=3
    }
    return
}

// The sequences with their frames in this file: the others live in other
// .mdl files (seqgroup), which this does not read.
@(private)
imported_sequence :: proc(s:Sequence) -> bool {
    return s.frames>0 && s.label!="" && s.label!="default" && s.label!="dummy"
}

// The RGBA8 texels of a texture the file keeps, masked index 255 transparent.
texture_texels :: proc(d:[]u8,t:Texture,allocator:=context.allocator) -> (rgba:[]u8,ok:bool) {
    count:=t.width*t.height
    if count<=0 || t.offset<0 || t.offset+count+PALETTE_BYTES>len(d) {return nil,false}
    pixels:=d[t.offset:t.offset+count]
    palette:=d[t.offset+count:t.offset+count+PALETTE_BYTES]
    masked:=t.flags&NF_MASKED!=0
    rgba=make([]u8,count*4,allocator)
    for index,i in pixels {
        if masked && index==255 {continue}
        rgba[i*4],rgba[i*4+1],rgba[i*4+2],rgba[i*4+3]=palette[int(index)*3],palette[int(index)*3+1],palette[int(index)*3+2],255
    }
    return rgba,true
}

@(private)
Tri_Vertex :: struct {vertex,normal,s,t:int}

// The triangles of a stream of tricmds: strips (n > 0) and fans (n < 0); a
// strip turns the order of its odd triangles.
tricmds :: proc(d:[]u8,at_start:int,out:^[dynamic][3]Tri_Vertex) {
    at:=at_start
    run:=make([dynamic]Tri_Vertex,context.temp_allocator)
    for at+2<=len(d) {
        count:=i16_at(d,at)
        at+=2
        if count==0 {return}
        clear(&run)
        for _ in 0..<abs(count) {
            if at+8>len(d) {return}
            append(&run,Tri_Vertex{i16_at(d,at),i16_at(d,at+2),i16_at(d,at+4),i16_at(d,at+6)})
            at+=8
        }
        if count<0 {
            for i in 1..<len(run)-1 {append(out,[3]Tri_Vertex{run[0],run[i],run[i+1]})}
        } else {
            for i in 0..<len(run)-2 {
                if i%2==0 {append(out,[3]Tri_Vertex{run[i],run[i+1],run[i+2]})} else {append(out,[3]Tri_Vertex{run[i+1],run[i],run[i+2]})}
            }
        }
    }
}

// Rest transforms of the bones, local and in the space of the model.
@(private)
Pose :: struct {rotation:matrix[3,3]f32,position:[3]f32}

@(private)
pose_of :: proc(q:mm.Vec4,p:[3]f32) -> Pose {
    x,y,z,w:=q.x,q.y,q.z,q.w
    return {matrix[3,3]f32{
        1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w),
        2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w),
        2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y),
    },p}
}

@(private)
world_poses :: proc(bones:[]Bone,allocator:=context.allocator) -> []Pose {
    world:=make([]Pose,len(bones),allocator)
    for b,i in bones {
        local:=pose_of(studio_quaternion({b.value[3],b.value[4],b.value[5]}),{b.value[0],b.value[1],b.value[2]})
        if b.parent>=0 && b.parent<i {
            p:=world[b.parent]
            world[i]={p.rotation*local.rotation,p.rotation*local.position+p.position}
        } else {
            world[i]=local
        }
    }
    return world
}

read :: proc(c:^importer.Reader,bytes:[]u8) -> bool {
    d:=bytes
    if len(d)>=4 && string(d[:4])=="IDSQ" {return importer.fail(c,.Unsupported,"%s keeps only the frames of sequences of a model (a sequence group); import the model, which reads it",c.file_name)}
    h,message,ok:=header_read(d)
    if !ok {return importer.fail(c,.Malformed,"%s",message)}
    bones:=bones_read(d,h,context.temp_allocator)
    // the textures and the skin table: of the model, or of <name>T.mdl beside it
    td,th:=d,h
    if h.textures==0 {
        if file,found:=texture_file(c);found {
            data,read:=importer.read_source(c,file)
            if !read {return false}
            other,other_message,other_ok:=header_read(data)
            if !other_ok {return importer.fail(c,.Malformed,"%s: %s",file,other_message)}
            td,th=data,other
        }
    }
    textures_:=textures_read(td,th,context.temp_allocator)
    sequences:=sequences_read(d,h,context.temp_allocator)
    if len(bones)==0 {
        if h.textures>0 {return importer.fail(c,.Unsupported,"%s keeps only textures: it is the texture file of a model, which takes them from it; import the model",c.file_name)}
        return importer.fail(c,.Malformed,"the model has no bones")
    }
    skinned:=false
    if len(bones)>1 {for s in sequences {skinned||=imported_sequence(s)}}
    world:=world_poses(bones,context.temp_allocator)
    skin_table:=make([]int,max(th.skin_refs,0),context.temp_allocator)
    for &t,i in skin_table {t=i16_at(td,th.skin_index+i*2)}

    // the paths of the bones, by their parents
    paths:=make([]string,len(bones),context.temp_allocator)
    for b,i in bones {
        segment:=importer.target_segment(b.name if b.name!="" else fmt.tprintf("bone %d",i))
        paths[i]=strings.clone(segment,context.temp_allocator)
        if b.parent>=0 && b.parent<i {paths[i]=fmt.tprintf("%s/%s",paths[b.parent],segment)}
        if len(paths[i])>=asset.NODE_PATH_CAPACITY {return importer.fail(c,.Limit,"the path of bone %s is too long",b.name)}
    }
    skeleton:=-1
    joints:[]asset.Rig_Joint
    if skinned {
        rows:=make([]asset.Skeleton_Bone,len(bones),context.temp_allocator)
        joints=make([]asset.Rig_Joint,len(bones),c.out)
        for b,i in bones {
            q:=studio_quaternion({b.value[3],b.value[4],b.value[5]})
            parent:=b.parent if b.parent>=0 && b.parent<i else -1
            rows[i]={parent=i32(parent),target=base.name_hash(paths[i]),translation={b.value[0],b.value[1],b.value[2]},rotation=quat_of(q),scale={1,1,1}}
            asset.text_set(rows[i].name[:],b.name)
            asset.text_set(rows[i].path[:],paths[i])
            append(&c.nodes,importer.Imported_Node{name=importer.own(c,b.name),path=importer.own(c,paths[i]),target=base.name_hash(paths[i]),parent=parent,transform={position=rows[i].translation,rotation=rows[i].rotation,scale={1,1,1}},mesh=-1,visible=true})
            joints[i]={node=u32(i),inverse_bind=1}
        }
        skeleton=len(c.skeletons)
        append(&c.skeletons,importer.Imported_Skeleton{name=importer.own(c,fmt.tprintf("%s skeleton",c.stem)),bones=importer.own_slice(c,rows)})
    }

    // materials: one per texture a mesh uses, with the texels of the file
    material_of:=make(map[int]int,context.temp_allocator)
    material :: proc(c:^importer.Reader,d:[]u8,t:Texture,row:int,material_of:^map[int]int) -> int {
        if m,found:=material_of[row];found {return m}
        images:[asset.Material_Map_Kind]int
        for &image in images {image=-1}
        info:=asset.MATERIAL_DEFAULTS
        info.metallic,info.roughness=0,1
        if t.flags&NF_MASKED!=0 {info.alpha_mode,info.alpha_cutoff=.Mask,0.5}
        if rgba,ok:=texture_texels(d,t,context.temp_allocator);ok {
            images[.Base_Color]=importer.image_pixels(c,fmt.tprintf("texture:%d",row),t.name,textures.Source{texels=rgba,width=t.width,height=t.height,format=.RGBA8},true,false)
        } else {
            importer.warn(c,"texture %s: its pixels are not in the file",t.name)
        }
        m:=importer.material_add(c,t.name,len(c.materials),info,images)
        material_of[row]=m
        return m
    }

    triangles:=make([dynamic][3]Tri_Vertex,context.temp_allocator)
    for part in 0..<h.body_parts {
        at:=h.body_part_index+part*BODYPART_SIZE
        models,model_index:=i32_at(d,at+64),i32_at(d,at+72)
        if models<=0 {continue}
        mb:=model_index // the first variant: body 0
        name:=cstring_at(d,mb,64)
        meshes,mesh_index:=i32_at(d,mb+72),i32_at(d,mb+76)
        verts,vert_info,vert_index:=i32_at(d,mb+80),i32_at(d,mb+84),i32_at(d,mb+88)
        norms,norm_info,norm_index:=i32_at(d,mb+92),i32_at(d,mb+96),i32_at(d,mb+100)
        b:importer.Mesh_Builder
        importer.builder_init(&b,c,skinned)
        for k in 0..<meshes {
            mt:=mesh_index+k*MESH_SIZE
            tri_index,skin_ref:=i32_at(d,mt+4),i32_at(d,mt+8)
            if skin_ref<0 || skin_ref>=len(skin_table) {continue}
            row:=skin_table[skin_ref]
            if row<0 || row>=len(textures_) || textures_[row].width==0 || textures_[row].height==0 {continue}
            t:=textures_[row]
            clear(&triangles)
            tricmds(d,tri_index,&triangles)
            if len(triangles)==0 {continue}
            slot,slot_ok:=importer.builder_slot(&b,u32(row),t.name,material(c,td,t,row,&material_of))
            if !slot_ok {return false}
            for tri in triangles {
                corners:[3]importer.Corner
                skin:[3]asset.Skin_Vertex
                bad:=false
                for v,n in tri {
                    if v.vertex<0 || v.vertex>=verts || v.normal<0 || v.normal>=norms {bad=true;break}
                    p:=[3]f32{f32_at(d,vert_index+v.vertex*12),f32_at(d,vert_index+v.vertex*12+4),f32_at(d,vert_index+v.vertex*12+8)}
                    nrm:=[3]f32{f32_at(d,norm_index+v.normal*12),f32_at(d,norm_index+v.normal*12+4),f32_at(d,norm_index+v.normal*12+8)}
                    bone:=clamp(int(d[vert_info+v.vertex]) if vert_info+v.vertex<len(d) else 0,0,len(bones)-1)
                    normal_bone:=clamp(int(d[norm_info+v.normal]) if norm_info+v.normal<len(d) else 0,0,len(bones)-1)
                    if !skinned {
                        p=world[bone].rotation*p+world[bone].position
                        nrm=world[normal_bone].rotation*nrm
                    }
                    corners[n]={position=p,normal=importer.normal_of(nrm,{0,0,1}),uv={f32(v.s)/f32(t.width),f32(v.t)/f32(t.height)},has_uv=true,color=0xffffffff}
                    skin[n].joints[0],skin[n].weights[0]=u16(bone),255
                }
                if !bad {importer.builder_triangle(&b,slot,corners,skin)}
            }
        }
        if importer.builder_triangles(&b)==0 {continue}
        mesh:=importer.builder_finish(&b,name if name!="" else c.stem)
        if skinned {mesh.joints,mesh.skeleton=joints,skeleton}
        mesh_row:=importer.mesh_add(c,mesh)
        node_name:=name if name!="" else c.stem
        append(&c.nodes,importer.Imported_Node{name=importer.own(c,node_name),path=importer.own(c,importer.target_segment(node_name)),target=base.name_hash(importer.target_segment(node_name)),parent=-1,transform={rotation=1,scale={1,1,1}},mesh=mesh_row,visible=true})
    }
    if len(c.meshes)==0 {return importer.fail(c,.Malformed,"the model has no geometry with a texture of its own")}
    if !skinned {return true}

    // clips: a sequence and each blend of it
    for s in sequences {
        if !imported_sequence(s) {continue}
        fps:=s.fps if s.fps>0 else 30
        // GoldSrc zeroes the position of the motion bone on the axes the bits
        // STUDIO_X, Y and Z of motiontype ask for; the rest is pose
        zeroed:=[3]bool{s.motion_type&1!=0,s.motion_type&2!=0,s.motion_type&4!=0}
        rows,suffixes,count:=blends_of(s)
        // the frames: in the model for group 0, else in the file of the group
        frames_of:=d
        if s.group!=0 {
            data,found:=group_file(c,d,h,s.group)
            if !found {
                importer.warn(c,"sequence %s lives in the file of group %d, which is not beside the model, and is left out",s.label,s.group)
                continue
            }
            frames_of=data
        }
        for variant in 0..<count {
            anim_at:=s.anim_index+rows[variant]*len(bones)*12
            tracks:=make([dynamic]asset.Animation_Track_Desc,c.out)
            for bone,i in bones {
                positions:=make([]anim.Keyframe,s.frames,c.out)
                rotations:=make([]anim.Keyframe,s.frames,c.out)
                moves:=false
                for frame in 0..<s.frames {
                    time:=f32(frame)/fps
                    p:[3]f32
                    for k in 0..<3 {p[k]=channel_value(frames_of,bones,anim_at,i,k,frame)}
                    if i==s.motion_bone {for k in 0..<3 {if zeroed[k] {p[k]=0}}}
                    positions[frame]={time=time,value={p.x,p.y,p.z,0},interpolation=.Linear}
                    for k in 0..<3 {moves||=abs(p[k]-positions[0].value[k])>1e-4 || abs(p[k]-bone.value[k])>1e-4}
                    q:=studio_quaternion({channel_value(frames_of,bones,anim_at,i,3,frame),channel_value(frames_of,bones,anim_at,i,4,frame),channel_value(frames_of,bones,anim_at,i,5,frame)})
                    // q and -q are the same turn: keep the side of the previous key
                    if frame>0 {
                        prev:=rotations[frame-1].value
                        if q.x*prev.x+q.y*prev.y+q.z*prev.z+q.w*prev.w<0 {q=-q}
                    }
                    rotations[frame]={time=time,value=q,interpolation=.Linear}
                }
                if moves {append(&tracks,asset.Animation_Track_Desc{target=importer.own(c,paths[i]),property=.Position,keys=positions})}
                append(&tracks,asset.Animation_Track_Desc{target=importer.own(c,paths[i]),property=.Rotation,keys=rotations})
            }
            append(&c.animations,asset.Animation_Clip_Desc{name=importer.own(c,fmt.tprintf("%s%s",s.label,suffixes[variant])),tracks=tracks[:]})
        }
    }
    return true
}

// <name>T.mdl beside the model, in either case of the T.
@(private)
texture_file :: proc(c:^importer.Reader) -> (path:string,found:bool) {
    for suffix in ([2]string{"T.mdl","t.mdl"}) {
        candidate:=fmt.tprintf("%s/%s%s",c.directory,c.stem,suffix)
        if os.exists(candidate) {return candidate,true}
    }
    return "",false
}

// The bytes of the file of a sequence group: the name its row gives
// (models/x01.mdl), looked for beside the model; read once per import.
@(private)
group_file :: proc(c:^importer.Reader,d:[]u8,h:Header,group:int) -> (data:[]u8,found:bool) {
    if group<=0 || group>=h.groups {return}
    name:=cstring_at(d,h.group_index+group*SEQUENCE_GROUP_SIZE+32,64)
    if name=="" {return}
    path:=fmt.tprintf("%s/%s",c.directory,filepath.base(name))
    if !os.exists(path) {return}
    bytes,read:=importer.read_source(c,path)
    if !read || len(bytes)<4 || string(bytes[:4])!="IDSQ" {return}
    return bytes,true
}
