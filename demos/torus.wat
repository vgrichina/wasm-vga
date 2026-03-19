(module
  (import "env" "memory" (memory 4))

  ;; Gouraud-shaded torus with triangle rasterization
  ;; Memory:
  ;;   0x10040  Base vertices+normals: N_RING*N_TUBE * 24 bytes (x,y,z,nx,ny,nz as f32)
  ;;   0x16000  Transformed verts: N_RING*N_TUBE * 16 bytes (sx,sy,sz,brightness as f32)
  ;;   0x1C000  Z-buffer: 320*200 = 64000 bytes (u8)
  ;; Torus: R=65 (major), r=28 (minor), 24 ring segments, 12 tube segments = 288 verts

  ;; Constants
  ;; N_RING=24, N_TUBE=12, N_VERTS=288
  ;; BASE_VERTS = 0x10040
  ;; TRANS_VERTS = 0x16000
  ;; ZBUF = 0x1C000

  (func $sin_a (param $x f64) (result f64)
    (local $x2 f64) (local $x3 f64) (local $x5 f64) (local $x7 f64)
    (local.set $x (f64.sub (local.get $x)
      (f64.mul (f64.floor (f64.div (local.get $x) (f64.const 6.283185307))) (f64.const 6.283185307))))
    (if (f64.gt (local.get $x) (f64.const 3.141592653))
      (then (local.set $x (f64.sub (local.get $x) (f64.const 6.283185307)))))
    (local.set $x2 (f64.mul (local.get $x) (local.get $x)))
    (local.set $x3 (f64.mul (local.get $x2) (local.get $x)))
    (local.set $x5 (f64.mul (local.get $x3) (local.get $x2)))
    (local.set $x7 (f64.mul (local.get $x5) (local.get $x2)))
    (f64.sub (f64.add (local.get $x) (f64.div (local.get $x5) (f64.const 120.0)))
      (f64.add (f64.div (local.get $x3) (f64.const 6.0)) (f64.div (local.get $x7) (f64.const 5040.0))))
  )

  (func $cos_a (param $x f64) (result f64)
    (call $sin_a (f64.add (local.get $x) (f64.const 1.5707963)))
  )

  ;; Base vertex addr: index * 24 + BASE
  (func $bv_addr (param $idx i32) (result i32)
    (i32.add (i32.const 0x10040) (i32.mul (local.get $idx) (i32.const 24)))
  )

  ;; Transformed vertex addr: index * 16 + TRANS
  (func $tv_addr (param $idx i32) (result i32)
    (i32.add (i32.const 0x16000) (i32.mul (local.get $idx) (i32.const 16)))
  )

  ;; Vertex index from (ring_i, tube_j)
  (func $vidx (param $i i32) (param $j i32) (result i32)
    (i32.add (i32.mul (local.get $i) (i32.const 12)) (local.get $j))
  )

  (func (export "init")
    (local $i i32) (local $j i32) (local $idx i32) (local $addr i32)
    (local $theta f64) (local $phi f64)
    (local $cos_t f64) (local $sin_t f64) (local $cos_p f64) (local $sin_p f64)
    (local $cx f64) (local $x f64) (local $y f64) (local $z f64)
    (local $pal_i i32) (local $pal_addr i32)
    (local $t f64) (local $r i32) (local $g i32) (local $b i32)

    ;; Setup copper/gold palette
    (local.set $pal_i (i32.const 0))
    (block $pdone (loop $plp (br_if $pdone (i32.ge_u (local.get $pal_i) (i32.const 256)))
      (local.set $pal_addr (i32.add (i32.const 0x0040) (i32.mul (local.get $pal_i) (i32.const 3))))
      (local.set $t (f64.div (f64.convert_i32_u (local.get $pal_i)) (f64.const 255.0)))
      ;; R: warm copper
      (local.set $r (i32.trunc_f64_s (f64.mul (local.get $t) (f64.const 255.0))))
      ;; G: golden, lagging behind R
      (local.set $g (i32.trunc_f64_s (f64.mul (f64.mul (local.get $t) (local.get $t)) (f64.const 200.0))))
      ;; B: subtle cool highlight at top
      (local.set $b (i32.trunc_f64_s (f64.mul (f64.mul (local.get $t) (f64.mul (local.get $t) (local.get $t))) (f64.const 140.0))))
      (if (i32.gt_s (local.get $r) (i32.const 255)) (then (local.set $r (i32.const 255))))
      (if (i32.gt_s (local.get $g) (i32.const 255)) (then (local.set $g (i32.const 255))))
      (if (i32.gt_s (local.get $b) (i32.const 255)) (then (local.set $b (i32.const 255))))
      (i32.store8 (local.get $pal_addr) (local.get $r))
      (i32.store8 (i32.add (local.get $pal_addr) (i32.const 1)) (local.get $g))
      (i32.store8 (i32.add (local.get $pal_addr) (i32.const 2)) (local.get $b))
      (local.set $pal_i (i32.add (local.get $pal_i) (i32.const 1)))
      (br $plp)))

    ;; Generate torus vertices and normals
    ;; Parametric: x = (R + r*cos(phi))*cos(theta)
    ;;             y = (R + r*cos(phi))*sin(theta)
    ;;             z = r*sin(phi)
    ;; Normal: (cos(phi)*cos(theta), cos(phi)*sin(theta), sin(phi))
    (local.set $i (i32.const 0))
    (block $idone (loop $ilp (br_if $idone (i32.ge_u (local.get $i) (i32.const 24)))
      (local.set $theta (f64.mul (f64.div (f64.convert_i32_u (local.get $i)) (f64.const 24.0)) (f64.const 6.283185)))
      (local.set $cos_t (call $cos_a (local.get $theta)))
      (local.set $sin_t (call $sin_a (local.get $theta)))
      (local.set $j (i32.const 0))
      (block $jdone (loop $jlp (br_if $jdone (i32.ge_u (local.get $j) (i32.const 12)))
        (local.set $phi (f64.mul (f64.div (f64.convert_i32_u (local.get $j)) (f64.const 12.0)) (f64.const 6.283185)))
        (local.set $cos_p (call $cos_a (local.get $phi)))
        (local.set $sin_p (call $sin_a (local.get $phi)))
        (local.set $cx (f64.add (f64.const 65.0) (f64.mul (f64.const 28.0) (local.get $cos_p))))
        (local.set $x (f64.mul (local.get $cx) (local.get $cos_t)))
        (local.set $y (f64.mul (local.get $cx) (local.get $sin_t)))
        (local.set $z (f64.mul (f64.const 28.0) (local.get $sin_p)))
        (local.set $idx (call $vidx (local.get $i) (local.get $j)))
        (local.set $addr (call $bv_addr (local.get $idx)))
        ;; Store position
        (f32.store (local.get $addr) (f32.demote_f64 (local.get $x)))
        (f32.store (i32.add (local.get $addr) (i32.const 4)) (f32.demote_f64 (local.get $y)))
        (f32.store (i32.add (local.get $addr) (i32.const 8)) (f32.demote_f64 (local.get $z)))
        ;; Store normal
        (f32.store (i32.add (local.get $addr) (i32.const 12))
          (f32.demote_f64 (f64.mul (local.get $cos_p) (local.get $cos_t))))
        (f32.store (i32.add (local.get $addr) (i32.const 16))
          (f32.demote_f64 (f64.mul (local.get $cos_p) (local.get $sin_t))))
        (f32.store (i32.add (local.get $addr) (i32.const 20))
          (f32.demote_f64 (local.get $sin_p)))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $jlp)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $ilp)))
  )

  ;; ---- Frame: transform, light, project, rasterize ----
  (func (export "frame")
    (local $i i32) (local $j i32) (local $idx i32)
    (local $baddr i32) (local $taddr i32)
    (local $tick i32)
    ;; mouse input
    (local $mx i32) (local $my i32)
    (local $mouse_dx f64) (local $mouse_dy f64)
    ;; rotation angles
    (local $ax f64) (local $ay f64) (local $az f64)
    (local $cax f64) (local $sax f64) (local $cay f64) (local $say f64) (local $caz f64) (local $saz f64)
    ;; vertex transform
    (local $vx f64) (local $vy f64) (local $vz f64)
    (local $nx f64) (local $ny f64) (local $nz f64)
    (local $tx f64) (local $ty f64) (local $tz f64)
    (local $tnx f64) (local $tny f64) (local $tnz f64)
    (local $tmp f64)
    ;; lighting + projection
    (local $brightness f64) (local $bint i32)
    (local $proj_scale f64) (local $sx f64) (local $sy f64)
    ;; rasterization
    (local $i0 i32) (local $i1 i32) (local $i2 i32) (local $i3 i32)
    (local $ni i32) (local $nj i32)

    (local.set $tick (i32.shr_u (i32.load (i32.const 12)) (i32.const 4)))

    ;; Read mouse position and compute offset from screen center
    (local.set $mx (i32.load16_u (i32.const 0x04)))
    (local.set $my (i32.load16_u (i32.const 0x06)))
    ;; mouse_dx = (mx - 160) / 160.0 => range [-1, 1], scaled to radians
    (local.set $mouse_dx (f64.mul
      (f64.div (f64.convert_i32_s (i32.sub (local.get $mx) (i32.const 160))) (f64.const 160.0))
      (f64.const 3.14159)))
    ;; mouse_dy = (my - 100) / 100.0 => range [-1, 1], scaled to radians
    (local.set $mouse_dy (f64.mul
      (f64.div (f64.convert_i32_s (i32.sub (local.get $my) (i32.const 100))) (f64.const 100.0))
      (f64.const 3.14159)))

    ;; Rotation angles: time-based + mouse offset
    (local.set $ax (f64.add (f64.mul (f64.convert_i32_u (local.get $tick)) (f64.const 0.03)) (local.get $mouse_dy)))
    (local.set $ay (f64.add (f64.mul (f64.convert_i32_u (local.get $tick)) (f64.const 0.02)) (local.get $mouse_dx)))
    (local.set $az (f64.mul (f64.convert_i32_u (local.get $tick)) (f64.const 0.01)))
    (local.set $cax (call $cos_a (local.get $ax)))
    (local.set $sax (call $sin_a (local.get $ax)))
    (local.set $cay (call $cos_a (local.get $ay)))
    (local.set $say (call $sin_a (local.get $ay)))
    (local.set $caz (call $cos_a (local.get $az)))
    (local.set $saz (call $sin_a (local.get $az)))

    ;; Clear framebuffer (dark background)
    (local.set $i (i32.const 0))
    (block $cdone (loop $clp (br_if $cdone (i32.ge_u (local.get $i) (i32.const 64000)))
      (i32.store8 (i32.add (i32.const 0x0340) (local.get $i)) (i32.const 2))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $clp)))
    ;; Clear z-buffer (255 = far)
    (local.set $i (i32.const 0))
    (block $zdone (loop $zlp (br_if $zdone (i32.ge_u (local.get $i) (i32.const 64000)))
      (i32.store8 (i32.add (i32.const 0x1C000) (local.get $i)) (i32.const 255))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $zlp)))

    ;; Transform all vertices
    (local.set $idx (i32.const 0))
    (block $tdone (loop $tlp (br_if $tdone (i32.ge_u (local.get $idx) (i32.const 288)))
      (local.set $baddr (call $bv_addr (local.get $idx)))
      (local.set $taddr (call $tv_addr (local.get $idx)))
      ;; Load base position
      (local.set $vx (f64.promote_f32 (f32.load (local.get $baddr))))
      (local.set $vy (f64.promote_f32 (f32.load (i32.add (local.get $baddr) (i32.const 4)))))
      (local.set $vz (f64.promote_f32 (f32.load (i32.add (local.get $baddr) (i32.const 8)))))
      ;; Load base normal
      (local.set $nx (f64.promote_f32 (f32.load (i32.add (local.get $baddr) (i32.const 12)))))
      (local.set $ny (f64.promote_f32 (f32.load (i32.add (local.get $baddr) (i32.const 16)))))
      (local.set $nz (f64.promote_f32 (f32.load (i32.add (local.get $baddr) (i32.const 20)))))

      ;; Rotate X: y' = y*cx - z*sx, z' = y*sx + z*cx
      (local.set $tmp (f64.sub (f64.mul (local.get $vy) (local.get $cax)) (f64.mul (local.get $vz) (local.get $sax))))
      (local.set $vz (f64.add (f64.mul (local.get $vy) (local.get $sax)) (f64.mul (local.get $vz) (local.get $cax))))
      (local.set $vy (local.get $tmp))
      (local.set $tmp (f64.sub (f64.mul (local.get $ny) (local.get $cax)) (f64.mul (local.get $nz) (local.get $sax))))
      (local.set $nz (f64.add (f64.mul (local.get $ny) (local.get $sax)) (f64.mul (local.get $nz) (local.get $cax))))
      (local.set $ny (local.get $tmp))

      ;; Rotate Y: x' = x*cy + z*sy, z' = -x*sy + z*cy
      (local.set $tmp (f64.add (f64.mul (local.get $vx) (local.get $cay)) (f64.mul (local.get $vz) (local.get $say))))
      (local.set $vz (f64.add (f64.mul (f64.neg (local.get $vx)) (local.get $say)) (f64.mul (local.get $vz) (local.get $cay))))
      (local.set $vx (local.get $tmp))
      (local.set $tmp (f64.add (f64.mul (local.get $nx) (local.get $cay)) (f64.mul (local.get $nz) (local.get $say))))
      (local.set $nz (f64.add (f64.mul (f64.neg (local.get $nx)) (local.get $say)) (f64.mul (local.get $nz) (local.get $cay))))
      (local.set $nx (local.get $tmp))

      ;; Rotate Z: x' = x*cz - y*sz, y' = x*sz + y*cz
      (local.set $tmp (f64.sub (f64.mul (local.get $vx) (local.get $caz)) (f64.mul (local.get $vy) (local.get $saz))))
      (local.set $vy (f64.add (f64.mul (local.get $vx) (local.get $saz)) (f64.mul (local.get $vy) (local.get $caz))))
      (local.set $vx (local.get $tmp))
      (local.set $tmp (f64.sub (f64.mul (local.get $nx) (local.get $caz)) (f64.mul (local.get $ny) (local.get $saz))))
      (local.set $ny (f64.add (f64.mul (local.get $nx) (local.get $saz)) (f64.mul (local.get $ny) (local.get $caz))))
      (local.set $nx (local.get $tmp))

      ;; Lighting: dot(normal, light_dir) where light = (0.577, 0.577, 0.577)
      (local.set $brightness (f64.add (f64.add
        (f64.mul (local.get $nx) (f64.const 0.577))
        (f64.mul (local.get $ny) (f64.const 0.577)))
        (f64.mul (local.get $nz) (f64.const 0.577))))
      ;; Ambient + diffuse
      (local.set $brightness (f64.add (f64.const 0.15)
        (f64.mul (f64.const 0.85) (select (f64.const 0.0) (local.get $brightness)
          (f64.lt (local.get $brightness) (f64.const 0.0))))))
      ;; Specular highlight: approximate with higher power of positive dot
      (if (f64.gt (local.get $brightness) (f64.const 0.7))
        (then
          (local.set $brightness (f64.add (local.get $brightness)
            (f64.mul (f64.sub (local.get $brightness) (f64.const 0.7)) (f64.const 0.8))))
        )
      )
      (if (f64.gt (local.get $brightness) (f64.const 1.0))
        (then (local.set $brightness (f64.const 1.0))))

      ;; Perspective projection: translate z back, project
      (local.set $vz (f64.add (local.get $vz) (f64.const 250.0)))
      (if (f64.lt (local.get $vz) (f64.const 10.0))
        (then (local.set $vz (f64.const 10.0))))
      (local.set $proj_scale (f64.div (f64.const 300.0) (local.get $vz)))
      (local.set $sx (f64.add (f64.mul (local.get $vx) (local.get $proj_scale)) (f64.const 160.0)))
      (local.set $sy (f64.add (f64.mul (local.get $vy) (local.get $proj_scale)) (f64.const 100.0)))

      ;; Store transformed: sx, sy, sz (for z-buffer), brightness
      (f32.store (local.get $taddr) (f32.demote_f64 (local.get $sx)))
      (f32.store (i32.add (local.get $taddr) (i32.const 4)) (f32.demote_f64 (local.get $sy)))
      (f32.store (i32.add (local.get $taddr) (i32.const 8)) (f32.demote_f64 (local.get $vz)))
      (f32.store (i32.add (local.get $taddr) (i32.const 12)) (f32.demote_f64 (local.get $brightness)))

      (local.set $idx (i32.add (local.get $idx) (i32.const 1)))
      (br $tlp)))

    ;; Rasterize quads as triangle pairs
    (local.set $i (i32.const 0))
    (block $qdone (loop $qlp (br_if $qdone (i32.ge_u (local.get $i) (i32.const 24)))
      (local.set $j (i32.const 0))
      (local.set $ni (i32.rem_u (i32.add (local.get $i) (i32.const 1)) (i32.const 24)))
      (block $qjdone (loop $qjlp (br_if $qjdone (i32.ge_u (local.get $j) (i32.const 12)))
        (local.set $nj (i32.rem_u (i32.add (local.get $j) (i32.const 1)) (i32.const 12)))
        ;; Quad vertices: (i,j), (ni,j), (ni,nj), (i,nj)
        (local.set $i0 (call $vidx (local.get $i) (local.get $j)))
        (local.set $i1 (call $vidx (local.get $ni) (local.get $j)))
        (local.set $i2 (call $vidx (local.get $ni) (local.get $nj)))
        (local.set $i3 (call $vidx (local.get $i) (local.get $nj)))
        ;; Triangle 1: i0, i1, i2
        (call $draw_triangle (local.get $i0) (local.get $i1) (local.get $i2))
        ;; Triangle 2: i0, i2, i3
        (call $draw_triangle (local.get $i0) (local.get $i2) (local.get $i3))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $qjlp)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $qlp)))
  )

  ;; ---- Triangle rasterizer with Gouraud shading ----
  (func $draw_triangle (param $vi0 i32) (param $vi1 i32) (param $vi2 i32)
    (local $a0 i32) (local $a1 i32) (local $a2 i32)
    ;; Screen coords (fixed point <<8 for interpolation)
    (local $x0 i32) (local $y0 i32) (local $b0 i32) (local $z0 i32)
    (local $x1 i32) (local $y1 i32) (local $b1 i32) (local $z1 i32)
    (local $x2 i32) (local $y2 i32) (local $b2 i32) (local $z2 i32)
    (local $tmp_x i32) (local $tmp_y i32) (local $tmp_b i32) (local $tmp_z i32)
    ;; backface cull
    (local $edge1x i32) (local $edge1y i32) (local $edge2x i32) (local $edge2y i32) (local $cross i32)
    ;; scanline
    (local $y i32) (local $dy_top_mid i32) (local $dy_top_bot i32) (local $dy_mid_bot i32)
    (local $xa i32) (local $xb i32) (local $ba i32) (local $bb i32)
    (local $za i32) (local $zb i32)
    (local $t1 i32) (local $t2 i32)
    (local $x i32) (local $bri i32) (local $zval i32)
    (local $dx i32) (local $fb_off i32)
    (local $avg_z i32)

    ;; Load screen coords
    (local.set $a0 (call $tv_addr (local.get $vi0)))
    (local.set $a1 (call $tv_addr (local.get $vi1)))
    (local.set $a2 (call $tv_addr (local.get $vi2)))
    (local.set $x0 (i32.trunc_f32_s (f32.load (local.get $a0))))
    (local.set $y0 (i32.trunc_f32_s (f32.load (i32.add (local.get $a0) (i32.const 4)))))
    (local.set $z0 (i32.trunc_f32_s (f32.load (i32.add (local.get $a0) (i32.const 8)))))
    (local.set $b0 (i32.trunc_f32_s (f32.mul (f32.load (i32.add (local.get $a0) (i32.const 12))) (f32.const 255.0))))
    (local.set $x1 (i32.trunc_f32_s (f32.load (local.get $a1))))
    (local.set $y1 (i32.trunc_f32_s (f32.load (i32.add (local.get $a1) (i32.const 4)))))
    (local.set $z1 (i32.trunc_f32_s (f32.load (i32.add (local.get $a1) (i32.const 8)))))
    (local.set $b1 (i32.trunc_f32_s (f32.mul (f32.load (i32.add (local.get $a1) (i32.const 12))) (f32.const 255.0))))
    (local.set $x2 (i32.trunc_f32_s (f32.load (local.get $a2))))
    (local.set $y2 (i32.trunc_f32_s (f32.load (i32.add (local.get $a2) (i32.const 4)))))
    (local.set $z2 (i32.trunc_f32_s (f32.load (i32.add (local.get $a2) (i32.const 8)))))
    (local.set $b2 (i32.trunc_f32_s (f32.mul (f32.load (i32.add (local.get $a2) (i32.const 12))) (f32.const 255.0))))

    ;; Backface culling (screen-space cross product of edges)
    (local.set $edge1x (i32.sub (local.get $x1) (local.get $x0)))
    (local.set $edge1y (i32.sub (local.get $y1) (local.get $y0)))
    (local.set $edge2x (i32.sub (local.get $x2) (local.get $x0)))
    (local.set $edge2y (i32.sub (local.get $y2) (local.get $y0)))
    (local.set $cross (i32.sub
      (i32.mul (local.get $edge1x) (local.get $edge2y))
      (i32.mul (local.get $edge1y) (local.get $edge2x))))
    ;; Skip back-facing triangles
    (if (i32.ge_s (local.get $cross) (i32.const 0)) (then (return)))

    ;; Average z for z-buffer (coarse per-triangle)
    (local.set $avg_z (i32.shr_u (i32.add (i32.add (local.get $z0) (local.get $z1)) (local.get $z2)) (i32.const 2)))
    (if (i32.gt_u (local.get $avg_z) (i32.const 255)) (then (local.set $avg_z (i32.const 255))))

    ;; Sort vertices by Y (bubble sort)
    ;; if y0 > y1: swap 0,1
    (if (i32.gt_s (local.get $y0) (local.get $y1))
      (then
        (local.set $tmp_x (local.get $x0)) (local.set $tmp_y (local.get $y0))
        (local.set $tmp_b (local.get $b0)) (local.set $tmp_z (local.get $z0))
        (local.set $x0 (local.get $x1)) (local.set $y0 (local.get $y1))
        (local.set $b0 (local.get $b1)) (local.set $z0 (local.get $z1))
        (local.set $x1 (local.get $tmp_x)) (local.set $y1 (local.get $tmp_y))
        (local.set $b1 (local.get $tmp_b)) (local.set $z1 (local.get $tmp_z))
      )
    )
    ;; if y1 > y2: swap 1,2
    (if (i32.gt_s (local.get $y1) (local.get $y2))
      (then
        (local.set $tmp_x (local.get $x1)) (local.set $tmp_y (local.get $y1))
        (local.set $tmp_b (local.get $b1)) (local.set $tmp_z (local.get $z1))
        (local.set $x1 (local.get $x2)) (local.set $y1 (local.get $y2))
        (local.set $b1 (local.get $b2)) (local.set $z1 (local.get $z2))
        (local.set $x2 (local.get $tmp_x)) (local.set $y2 (local.get $tmp_y))
        (local.set $b2 (local.get $tmp_b)) (local.set $z2 (local.get $tmp_z))
      )
    )
    ;; if y0 > y1: swap 0,1 again
    (if (i32.gt_s (local.get $y0) (local.get $y1))
      (then
        (local.set $tmp_x (local.get $x0)) (local.set $tmp_y (local.get $y0))
        (local.set $tmp_b (local.get $b0)) (local.set $tmp_z (local.get $z0))
        (local.set $x0 (local.get $x1)) (local.set $y0 (local.get $y1))
        (local.set $b0 (local.get $b1)) (local.set $z0 (local.get $z1))
        (local.set $x1 (local.get $tmp_x)) (local.set $y1 (local.get $tmp_y))
        (local.set $b1 (local.get $tmp_b)) (local.set $z1 (local.get $tmp_z))
      )
    )

    ;; Now y0 <= y1 <= y2
    (local.set $dy_top_bot (i32.sub (local.get $y2) (local.get $y0)))
    (if (i32.eqz (local.get $dy_top_bot)) (then (return))) ;; degenerate
    (local.set $dy_top_mid (i32.sub (local.get $y1) (local.get $y0)))
    (local.set $dy_mid_bot (i32.sub (local.get $y2) (local.get $y1)))

    ;; Scanline from y0 to y2
    (local.set $y (select (local.get $y0) (i32.const 0) (i32.ge_s (local.get $y0) (i32.const 0))))
    (block $ydone (loop $ylp
      (br_if $ydone (i32.or (i32.gt_s (local.get $y) (local.get $y2)) (i32.ge_s (local.get $y) (i32.const 200))))

      ;; Interpolate along long edge (v0 -> v2)
      ;; t2 = (y - y0) * 256 / dy_top_bot
      (local.set $t2 (i32.div_s (i32.mul (i32.sub (local.get $y) (local.get $y0)) (i32.const 256)) (local.get $dy_top_bot)))
      (local.set $xb (i32.add (local.get $x0) (i32.shr_s (i32.mul (i32.sub (local.get $x2) (local.get $x0)) (local.get $t2)) (i32.const 8))))
      (local.set $bb (i32.add (local.get $b0) (i32.shr_s (i32.mul (i32.sub (local.get $b2) (local.get $b0)) (local.get $t2)) (i32.const 8))))

      ;; Interpolate along short edge
      (if (i32.lt_s (local.get $y) (local.get $y1))
        (then
          ;; Upper half: v0 -> v1
          (if (i32.gt_s (local.get $dy_top_mid) (i32.const 0))
            (then
              (local.set $t1 (i32.div_s (i32.mul (i32.sub (local.get $y) (local.get $y0)) (i32.const 256)) (local.get $dy_top_mid)))
              (local.set $xa (i32.add (local.get $x0) (i32.shr_s (i32.mul (i32.sub (local.get $x1) (local.get $x0)) (local.get $t1)) (i32.const 8))))
              (local.set $ba (i32.add (local.get $b0) (i32.shr_s (i32.mul (i32.sub (local.get $b1) (local.get $b0)) (local.get $t1)) (i32.const 8))))
            )
            (else
              (local.set $xa (local.get $x0))
              (local.set $ba (local.get $b0))
            )
          )
        )
        (else
          ;; Lower half: v1 -> v2
          (if (i32.gt_s (local.get $dy_mid_bot) (i32.const 0))
            (then
              (local.set $t1 (i32.div_s (i32.mul (i32.sub (local.get $y) (local.get $y1)) (i32.const 256)) (local.get $dy_mid_bot)))
              (local.set $xa (i32.add (local.get $x1) (i32.shr_s (i32.mul (i32.sub (local.get $x2) (local.get $x1)) (local.get $t1)) (i32.const 8))))
              (local.set $ba (i32.add (local.get $b1) (i32.shr_s (i32.mul (i32.sub (local.get $b2) (local.get $b1)) (local.get $t1)) (i32.const 8))))
            )
            (else
              (local.set $xa (local.get $x1))
              (local.set $ba (local.get $b1))
            )
          )
        )
      )

      ;; Ensure xa <= xb
      (if (i32.gt_s (local.get $xa) (local.get $xb))
        (then
          (local.set $tmp_x (local.get $xa)) (local.set $xa (local.get $xb)) (local.set $xb (local.get $tmp_x))
          (local.set $tmp_b (local.get $ba)) (local.set $ba (local.get $bb)) (local.set $bb (local.get $tmp_b))
        )
      )

      ;; Draw horizontal span with interpolated brightness
      (local.set $dx (i32.sub (local.get $xb) (local.get $xa)))
      (local.set $x (select (local.get $xa) (i32.const 0) (i32.ge_s (local.get $xa) (i32.const 0))))
      (block $xdone (loop $xlp
        (br_if $xdone (i32.or (i32.gt_s (local.get $x) (local.get $xb)) (i32.ge_s (local.get $x) (i32.const 320))))
        ;; Interpolate brightness
        (if (i32.gt_s (local.get $dx) (i32.const 0))
          (then
            (local.set $bri (i32.add (local.get $ba)
              (i32.div_s (i32.mul (i32.sub (local.get $bb) (local.get $ba))
                (i32.sub (local.get $x) (local.get $xa))) (local.get $dx))))
          )
          (else (local.set $bri (local.get $ba)))
        )
        ;; Clamp brightness
        (if (i32.lt_s (local.get $bri) (i32.const 0)) (then (local.set $bri (i32.const 0))))
        (if (i32.gt_s (local.get $bri) (i32.const 255)) (then (local.set $bri (i32.const 255))))
        ;; Z-buffer check
        (local.set $fb_off (i32.add (i32.mul (local.get $y) (i32.const 320)) (local.get $x)))
        (if (i32.lt_u (local.get $avg_z) (i32.load8_u (i32.add (i32.const 0x1C000) (local.get $fb_off))))
          (then
            (i32.store8 (i32.add (i32.const 0x1C000) (local.get $fb_off)) (local.get $avg_z))
            (i32.store8 (i32.add (i32.const 0x0340) (local.get $fb_off)) (local.get $bri))
          )
        )
        (local.set $x (i32.add (local.get $x) (i32.const 1)))
        (br $xlp)))

      (local.set $y (i32.add (local.get $y) (i32.const 1)))
      (br $ylp)))
  )
)
