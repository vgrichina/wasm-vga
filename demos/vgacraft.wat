(module
  (import "env" "memory" (memory 10))
  (import "env" "sfx" (func $sfx (param i32)))
  (import "env" "note" (func $note (param i32 i32 i32 i32)))

  ;; ============================================================
  ;; VGACraft — Proper Per-Pixel 3D Voxel Raytracer
  ;; ============================================================
  ;; True per-pixel raytracing: every pixel (320×200 = 64000 rays)
  ;; gets its own ray through the voxel world using 3D DDA
  ;; (Amanatides & Woo grid traversal).
  ;;
  ;; WASD to move, Mouse to look, Click to dig, Shift+click to place
  ;; Space to jump
  ;;
  ;; Memory layout:
  ;;   0x10340  PRNG state (4 bytes)
  ;;   0x10344  Player state (64 bytes)
  ;;     +0:  px (f64) world X
  ;;     +8:  py (f64) world Y (horizontal plane)
  ;;     +16: angle (f64) facing direction (yaw)
  ;;     +24: pz (f64) player Z height (eye level)
  ;;     +32: vz (f64) vertical velocity
  ;;     +40: on_ground (i32)
  ;;     +48: bob_phase (f64)
  ;;   0x10390  Game state (32 bytes)
  ;;     +0:  mod_count (i32)
  ;;     +4:  max_mods (i32)
  ;;     +8:  gods_angry (i32)
  ;;     +12: msg_timer (i32)
  ;;     +16: dig_cooldown (i32)
  ;;     +20: prev_mouse (i32)
  ;;     +24: selected_block (i32)
  ;;     +28: look_y (i32) - vertical look pitch
  ;;   0x103B0  zbuffer (320 * 4 = 1280 bytes) — f32 per column for sprites
  ;;   0x10900  Monster array (24 monsters * 32 bytes = 768)
  ;;   0x10C00  Modification table (max ~1900 entries * 16 bytes)
  ;;   0x19000  String data
  ;;   0x19200  Font data
  ;; ============================================================

  ;; ---- PRNG (xorshift32) ----
  (func $rand (result i32)
    (local $s i32)
    i32.const 0x10340
    i32.load
    local.set $s
    local.get $s
    i32.eqz
    if
      i32.const 2654435761
      local.set $s
    end
    local.get $s
    local.get $s
    i32.const 13
    i32.shl
    i32.xor
    local.set $s
    local.get $s
    local.get $s
    i32.const 17
    i32.shr_u
    i32.xor
    local.set $s
    local.get $s
    local.get $s
    i32.const 5
    i32.shl
    i32.xor
    local.set $s
    i32.const 0x10340
    local.get $s
    i32.store
    local.get $s
  )

  ;; ---- Hash function for procedural terrain ----
  (func $hash2d (param $x i32) (param $y i32) (result i32)
    (local $h i32)
    i32.const 0x27d4eb2d
    local.set $h
    local.get $h
    local.get $x
    i32.const 374761393
    i32.mul
    i32.xor
    local.set $h
    local.get $h
    local.get $y
    i32.const 668265263
    i32.mul
    i32.xor
    local.set $h
    local.get $h
    local.get $h
    i32.const 13
    i32.shr_u
    i32.xor
    local.set $h
    local.get $h
    i32.const 1274126177
    i32.mul
    local.set $h
    local.get $h
    local.get $h
    i32.const 16
    i32.shr_u
    i32.xor
    local.set $h
    local.get $h
    i32.const 2654435761
    i32.mul
    local.set $h
    local.get $h
    local.get $h
    i32.const 13
    i32.shr_u
    i32.xor
    local.set $h
    local.get $h
  )

  ;; ---- 3-input hash ----
  (func $hash3d (param $x i32) (param $y i32) (param $z i32) (result i32)
    (local $h i32)
    i32.const 0x27d4eb2d
    local.set $h
    local.get $h
    local.get $x
    i32.const 374761393
    i32.mul
    i32.xor
    local.set $h
    local.get $h
    local.get $y
    i32.const 668265263
    i32.mul
    i32.xor
    local.set $h
    local.get $h
    local.get $z
    i32.const 1103515245
    i32.mul
    i32.xor
    local.set $h
    local.get $h
    local.get $h
    i32.const 13
    i32.shr_u
    i32.xor
    local.set $h
    local.get $h
    i32.const 1274126177
    i32.mul
    local.set $h
    local.get $h
    local.get $h
    i32.const 16
    i32.shr_u
    i32.xor
    local.set $h
    local.get $h
  )

  ;; ---- Smooth noise interpolation ----
  (func $smooth_hash (param $wx i32) (param $wy i32) (param $period i32) (result i32)
    (local $gx i32) (local $gy i32)
    (local $fx i32) (local $fy i32)
    (local $h00 i32) (local $h10 i32) (local $h01 i32) (local $h11 i32)
    (local $top i32) (local $bot i32) (local $result i32)
    ;; gx = wx / period
    local.get $wx
    local.get $period
    i32.div_s
    local.set $gx
    ;; if (wx < 0 && gx * period != wx) gx--
    local.get $wx
    i32.const 0
    i32.lt_s
    local.get $gx
    local.get $period
    i32.mul
    local.get $wx
    i32.ne
    i32.and
    if
      local.get $gx
      i32.const 1
      i32.sub
      local.set $gx
    end
    ;; gy = wy / period
    local.get $wy
    local.get $period
    i32.div_s
    local.set $gy
    ;; if (wy < 0 && gy * period != wy) gy--
    local.get $wy
    i32.const 0
    i32.lt_s
    local.get $gy
    local.get $period
    i32.mul
    local.get $wy
    i32.ne
    i32.and
    if
      local.get $gy
      i32.const 1
      i32.sub
      local.set $gy
    end
    ;; fx = wx - gx * period
    local.get $wx
    local.get $gx
    local.get $period
    i32.mul
    i32.sub
    local.set $fx
    ;; fy = wy - gy * period
    local.get $wy
    local.get $gy
    local.get $period
    i32.mul
    i32.sub
    local.set $fy
    ;; h00 = hash2d(gx, gy) & 255
    local.get $gx
    local.get $gy
    call $hash2d
    i32.const 255
    i32.and
    local.set $h00
    ;; h10 = hash2d(gx+1, gy) & 255
    local.get $gx
    i32.const 1
    i32.add
    local.get $gy
    call $hash2d
    i32.const 255
    i32.and
    local.set $h10
    ;; h01 = hash2d(gx, gy+1) & 255
    local.get $gx
    local.get $gy
    i32.const 1
    i32.add
    call $hash2d
    i32.const 255
    i32.and
    local.set $h01
    ;; h11 = hash2d(gx+1, gy+1) & 255
    local.get $gx
    i32.const 1
    i32.add
    local.get $gy
    i32.const 1
    i32.add
    call $hash2d
    i32.const 255
    i32.and
    local.set $h11
    ;; top = (h00 * (period - fx) + h10 * fx) / period
    local.get $h00
    local.get $period
    local.get $fx
    i32.sub
    i32.mul
    local.get $h10
    local.get $fx
    i32.mul
    i32.add
    local.get $period
    i32.div_u
    local.set $top
    ;; bot = (h01 * (period - fx) + h11 * fx) / period
    local.get $h01
    local.get $period
    local.get $fx
    i32.sub
    i32.mul
    local.get $h11
    local.get $fx
    i32.mul
    i32.add
    local.get $period
    i32.div_u
    local.set $bot
    ;; result = (top * (period - fy) + bot * fy) / period
    local.get $top
    local.get $period
    local.get $fy
    i32.sub
    i32.mul
    local.get $bot
    local.get $fy
    i32.mul
    i32.add
    local.get $period
    i32.div_u
    local.set $result
    local.get $result
  )

  ;; ---- Terrain height: returns 2-14 for given world XY ----
  (func $terrain_height (param $wx i32) (param $wy i32) (result i32)
    (local $h1 i32) (local $h2 i32) (local $h3 i32) (local $result i32)
    ;; h1 = smooth_hash(wx, wy, 16) >> 5
    local.get $wx
    local.get $wy
    i32.const 16
    call $smooth_hash
    i32.const 5
    i32.shr_u
    local.set $h1
    ;; h2 = smooth_hash(wx+1000, wy+2000, 7) >> 6
    local.get $wx
    i32.const 1000
    i32.add
    local.get $wy
    i32.const 2000
    i32.add
    i32.const 7
    call $smooth_hash
    i32.const 6
    i32.shr_u
    local.set $h2
    ;; h3 = hash2d(wx+5000, wy+7000) & 1
    local.get $wx
    i32.const 5000
    i32.add
    local.get $wy
    i32.const 7000
    i32.add
    call $hash2d
    i32.const 1
    i32.and
    local.set $h3
    ;; result = 2 + h1 + h2 + h3
    i32.const 2
    local.get $h1
    i32.add
    local.get $h2
    local.get $h3
    i32.add
    i32.add
    local.set $result
    local.get $result
    i32.const 14
    i32.gt_s
    if
      i32.const 14
      local.set $result
    end
    local.get $result
    i32.const 2
    i32.lt_s
    if
      i32.const 2
      local.set $result
    end
    local.get $result
  )

  ;; ---- Check if there's a tree at this position ----
  (func $has_tree (param $wx i32) (param $wy i32) (result i32)
    (local $h i32)
    local.get $wx
    i32.const 3333
    i32.add
    local.get $wy
    i32.const 7777
    i32.add
    call $hash2d
    local.set $h
    ;; (h & 255) < 10 && terrain_height(wx, wy) > 5
    local.get $h
    i32.const 255
    i32.and
    i32.const 10
    i32.lt_u
    local.get $wx
    local.get $wy
    call $terrain_height
    i32.const 5
    i32.gt_s
    i32.and
  )

  ;; ---- Get block type at world position (wx, wy, wz) ----
  ;; Block types: 0=air, 1=grass, 2=dirt, 3=stone, 4=sand, 5=water, 6=wood, 7=leaves, 8=coal
  (func $get_block (param $wx i32) (param $wy i32) (param $wz i32) (result i32)
    (local $i i32) (local $count i32) (local $addr i32)
    (local $th i32) (local $block_hash i32)
    ;; Check modification table first
    i32.const 0x10390
    i32.load
    local.set $count
    i32.const 0
    local.set $i
    block $mod_done
      loop $mod_loop
        local.get $i
        local.get $count
        i32.ge_u
        br_if $mod_done
        i32.const 0x10C00
        local.get $i
        i32.const 16
        i32.mul
        i32.add
        local.set $addr
        ;; if coords match, return stored type
        local.get $addr
        i32.load
        local.get $wx
        i32.eq
        local.get $addr
        i32.const 4
        i32.add
        i32.load
        local.get $wy
        i32.eq
        i32.and
        local.get $addr
        i32.const 8
        i32.add
        i32.load
        local.get $wz
        i32.eq
        i32.and
        if
          local.get $addr
          i32.const 12
          i32.add
          i32.load
          return
        end
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $mod_loop
      end
    end
    ;; Procedural generation
    local.get $wz
    i32.const 0
    i32.lt_s
    if
      i32.const 3
      return
    end
    local.get $wx
    local.get $wy
    call $terrain_height
    local.set $th
    ;; Tree trunk and leaves
    local.get $wx
    local.get $wy
    call $has_tree
    if
      local.get $wz
      local.get $th
      i32.gt_s
      local.get $wz
      local.get $th
      i32.const 4
      i32.add
      i32.le_s
      i32.and
      if
        i32.const 6
        return
      end
      local.get $wz
      local.get $th
      i32.const 3
      i32.add
      i32.ge_s
      local.get $wz
      local.get $th
      i32.const 6
      i32.add
      i32.le_s
      i32.and
      if
        i32.const 7
        return
      end
    end
    ;; Check neighbor trees for leaves
    local.get $wz
    local.get $th
    i32.const 3
    i32.add
    i32.ge_s
    local.get $wz
    local.get $th
    i32.const 5
    i32.add
    i32.le_s
    i32.and
    if
      local.get $wx
      i32.const 1
      i32.add
      local.get $wy
      call $has_tree
      local.get $wx
      i32.const 1
      i32.sub
      local.get $wy
      call $has_tree
      i32.or
      local.get $wx
      local.get $wy
      i32.const 1
      i32.add
      call $has_tree
      i32.or
      local.get $wx
      local.get $wy
      i32.const 1
      i32.sub
      call $has_tree
      i32.or
      if
        i32.const 7
        return
      end
    end
    ;; Above terrain = air (or water)
    local.get $wz
    local.get $th
    i32.gt_s
    if
      local.get $wz
      i32.const 4
      i32.le_s
      local.get $th
      i32.const 4
      i32.le_s
      i32.and
      if
        i32.const 5
        return
      end
      i32.const 0
      return
    end
    ;; Top block
    local.get $wz
    local.get $th
    i32.eq
    if
      local.get $th
      i32.const 4
      i32.le_s
      if
        i32.const 4
        return
      end
      i32.const 1
      return
    end
    ;; 1-3 below top = dirt
    local.get $wz
    local.get $th
    i32.const 3
    i32.sub
    i32.gt_s
    if
      i32.const 2
      return
    end
    ;; Coal ore
    local.get $wx
    local.get $wz
    i32.const 13
    i32.mul
    i32.add
    local.get $wy
    local.get $wz
    i32.const 7
    i32.mul
    i32.add
    call $hash2d
    i32.const 31
    i32.and
    local.set $block_hash
    local.get $block_hash
    i32.eqz
    if
      i32.const 8
      return
    end
    i32.const 3
  )

  ;; ---- Store a block modification ----
  (func $set_block (param $wx i32) (param $wy i32) (param $wz i32) (param $type i32)
    (local $i i32) (local $count i32) (local $addr i32) (local $max_mods i32)
    i32.const 0x10390
    i32.load
    local.set $count
    i32.const 0
    local.set $i
    block $search_done
      loop $search
        local.get $i
        local.get $count
        i32.ge_u
        br_if $search_done
        i32.const 0x10C00
        local.get $i
        i32.const 16
        i32.mul
        i32.add
        local.set $addr
        local.get $addr
        i32.load
        local.get $wx
        i32.eq
        local.get $addr
        i32.const 4
        i32.add
        i32.load
        local.get $wy
        i32.eq
        i32.and
        local.get $addr
        i32.const 8
        i32.add
        i32.load
        local.get $wz
        i32.eq
        i32.and
        if
          local.get $addr
          i32.const 12
          i32.add
          local.get $type
          i32.store
          return
        end
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $search
      end
    end
    i32.const 0x10394
    i32.load
    local.set $max_mods
    local.get $count
    local.get $max_mods
    i32.ge_u
    if
      i32.const 0x10398
      i32.const 1
      i32.store
      i32.const 0x1039C
      i32.const 300
      i32.store
      return
    end
    i32.const 0x10C00
    local.get $count
    i32.const 16
    i32.mul
    i32.add
    local.set $addr
    local.get $addr
    local.get $wx
    i32.store
    local.get $addr
    i32.const 4
    i32.add
    local.get $wy
    i32.store
    local.get $addr
    i32.const 8
    i32.add
    local.get $wz
    i32.store
    local.get $addr
    i32.const 12
    i32.add
    local.get $type
    i32.store
    i32.const 0x10390
    local.get $count
    i32.const 1
    i32.add
    i32.store

    ;; Invalidate octree around the modified block
    local.get $wx
    local.get $wy
    local.get $wz
    call $octree_invalidate
  )

  ;; ---- sin/cos approximation ----
  (func $sin_a (param $x f64) (result f64)
    (local $x2 f64) (local $x3 f64) (local $x5 f64) (local $x7 f64)
    (local $sign f64)
    f64.const 1.0
    local.set $sign
    ;; x = x - floor(x / 2pi) * 2pi
    local.get $x
    local.get $x
    f64.const 6.283185307179586
    f64.div
    f64.floor
    f64.const 6.283185307179586
    f64.mul
    f64.sub
    local.set $x
    ;; if x >= pi: x -= pi, sign = -1
    local.get $x
    f64.const 3.141592653589793
    f64.ge
    if
      local.get $x
      f64.const 3.141592653589793
      f64.sub
      local.set $x
      f64.const -1.0
      local.set $sign
    end
    ;; if x > pi/2: x = pi - x
    local.get $x
    f64.const 1.5707963267948966
    f64.gt
    if
      f64.const 3.141592653589793
      local.get $x
      f64.sub
      local.set $x
    end
    local.get $x
    local.get $x
    f64.mul
    local.set $x2
    local.get $x2
    local.get $x
    f64.mul
    local.set $x3
    local.get $x3
    local.get $x2
    f64.mul
    local.set $x5
    local.get $x5
    local.get $x2
    f64.mul
    local.set $x7
    ;; sign * (x - x3/6 + x5/120 - x7/5040)
    local.get $sign
    local.get $x
    local.get $x5
    f64.const 120.0
    f64.div
    f64.add
    local.get $x3
    f64.const 6.0
    f64.div
    local.get $x7
    f64.const 5040.0
    f64.div
    f64.add
    f64.sub
    f64.mul
  )

  (func $cos_a (param $x f64) (result f64)
    local.get $x
    f64.const 1.5707963267948966
    f64.add
    call $sin_a
  )

  ;; ---- Set palette entry ----
  (func $set_pal (param $idx i32) (param $r i32) (param $g i32) (param $b i32)
    (local $a i32)
    i32.const 0x0040
    local.get $idx
    i32.const 3
    i32.mul
    i32.add
    local.set $a
    local.get $a
    local.get $r
    i32.store8
    local.get $a
    i32.const 1
    i32.add
    local.get $g
    i32.store8
    local.get $a
    i32.const 2
    i32.add
    local.get $b
    i32.store8
  )

  ;; ---- put_pixel ----
  (func $put_pixel (param $x i32) (param $y i32) (param $c i32)
    local.get $x
    i32.const 0
    i32.ge_s
    local.get $x
    i32.const 320
    i32.lt_s
    i32.and
    local.get $y
    i32.const 0
    i32.ge_s
    local.get $y
    i32.const 200
    i32.lt_s
    i32.and
    i32.and
    if
      i32.const 0x0340
      local.get $y
      i32.const 320
      i32.mul
      local.get $x
      i32.add
      i32.add
      local.get $c
      i32.store8
    end
  )

  ;; ---- fill_rect ----
  (func $fill_rect (param $x i32) (param $y i32) (param $w i32) (param $h i32) (param $c i32)
    (local $ix i32) (local $iy i32)
    i32.const 0
    local.set $iy
    block $done
      loop $ly
        local.get $iy
        local.get $h
        i32.ge_s
        br_if $done
        i32.const 0
        local.set $ix
        block $done2
          loop $lx
            local.get $ix
            local.get $w
            i32.ge_s
            br_if $done2
            local.get $x
            local.get $ix
            i32.add
            local.get $y
            local.get $iy
            i32.add
            local.get $c
            call $put_pixel
            local.get $ix
            i32.const 1
            i32.add
            local.set $ix
            br $lx
          end
        end
        local.get $iy
        i32.const 1
        i32.add
        local.set $iy
        br $ly
      end
    end
  )

  ;; ---- RGB+Brightness palette helpers ----
  ;; Palette: index = (R<<6)|(G<<4)|(B<<2)|L  where R,G,B,L are 0-3
  ;; Block type to RGB base (without brightness bits):
  ;;   0=air(0x00), 1=grass(0x30), 2=dirt(0x90), 3=stone(0xA8),
  ;;   4=sand(0xF4), 5=water(0x1C), 6=wood(0x50), 7=leaves(0x20), 8=coal(0x54)
  ;; Helper: get base RGB index for a block type (0-8)
  (func $block_base (param $type i32) (result i32)
    ;; Table stored at 0x19500 (8 bytes)
    i32.const 0x19500
    local.get $type
    i32.add
    i32.load8_u
  )

  ;; ---- Block color: returns palette index ----
  ;; face: 0=top, 1=side-bright, 2=side-dim, 3=bottom
  ;; shade: 0-15 input from distance etc, mapped to 0-3 brightness
  (func $block_color (param $type i32) (param $face i32) (param $shade i32) (result i32)
    (local $base i32)
    local.get $type
    call $block_base
    local.set $base
    ;; Top face gets +4 brightness boost
    local.get $face
    i32.const 0
    i32.eq
    if
      local.get $shade
      i32.const 4
      i32.add
      local.set $shade
    end
    ;; Dim side gets -2
    local.get $face
    i32.const 2
    i32.eq
    if
      local.get $shade
      i32.const 2
      i32.sub
      local.set $shade
    end
    ;; Bottom gets -4
    local.get $face
    i32.const 3
    i32.eq
    if
      local.get $shade
      i32.const 4
      i32.sub
      local.set $shade
    end
    ;; Clamp shade 0..15
    local.get $shade
    i32.const 0
    i32.lt_s
    if
      i32.const 0
      local.set $shade
    end
    local.get $shade
    i32.const 15
    i32.gt_s
    if
      i32.const 15
      local.set $shade
    end
    ;; Map shade 0..15 to brightness 0..3: shade >> 2
    local.get $base
    local.get $shade
    i32.const 2
    i32.shr_u
    i32.or
  )

  ;; ---- Mini font (4x6 bitmap) ----
  (func $draw_char (param $ch i32) (param $dx i32) (param $dy i32) (param $color i32)
    (local $addr i32) (local $row i32) (local $col i32) (local $bits i32)
    local.get $ch
    i32.const 32
    i32.lt_u
    if
      return
    end
    local.get $ch
    i32.const 127
    i32.gt_u
    if
      return
    end
    i32.const 0x19200
    local.get $ch
    i32.const 32
    i32.sub
    i32.const 6
    i32.mul
    i32.add
    local.set $addr
    i32.const 0
    local.set $row
    block $done
      loop $lr
        local.get $row
        i32.const 6
        i32.ge_s
        br_if $done
        local.get $addr
        local.get $row
        i32.add
        i32.load8_u
        local.set $bits
        i32.const 0
        local.set $col
        block $done2
          loop $lc
            local.get $col
            i32.const 4
            i32.ge_s
            br_if $done2
            local.get $bits
            i32.const 8
            local.get $col
            i32.shr_u
            i32.and
            if
              local.get $dx
              local.get $col
              i32.add
              local.get $dy
              local.get $row
              i32.add
              local.get $color
              call $put_pixel
            end
            local.get $col
            i32.const 1
            i32.add
            local.set $col
            br $lc
          end
        end
        local.get $row
        i32.const 1
        i32.add
        local.set $row
        br $lr
      end
    end
  )

  ;; Draw null-terminated string
  (func $draw_str (param $addr i32) (param $x i32) (param $y i32) (param $color i32)
    (local $ch i32) (local $ox i32)
    local.get $x
    local.set $ox
    block $done
      loop $lp
        local.get $addr
        i32.load8_u
        local.set $ch
        local.get $ch
        i32.eqz
        br_if $done
        local.get $ch
        local.get $ox
        local.get $y
        local.get $color
        call $draw_char
        local.get $ox
        i32.const 5
        i32.add
        local.set $ox
        local.get $addr
        i32.const 1
        i32.add
        local.set $addr
        br $lp
      end
    end
  )

  ;; Draw number
  (func $draw_num (param $val i32) (param $x i32) (param $y i32) (param $color i32)
    (local $digits i32) (local $d i32) (local $v i32) (local $ox i32)
    local.get $val
    local.set $v
    i32.const 1
    local.set $digits
    block $cd
      loop $cl
        local.get $v
        i32.const 10
        i32.div_u
        local.set $v
        local.get $v
        i32.eqz
        br_if $cd
        local.get $digits
        i32.const 1
        i32.add
        local.set $digits
        br $cl
      end
    end
    local.get $x
    local.get $digits
    i32.const 1
    i32.sub
    i32.const 5
    i32.mul
    i32.add
    local.set $ox
    local.get $val
    local.set $v
    block $dd
      loop $dl
        local.get $v
        i32.const 10
        i32.rem_u
        local.set $d
        local.get $d
        i32.const 48
        i32.add
        local.get $ox
        local.get $y
        local.get $color
        call $draw_char
        local.get $v
        i32.const 10
        i32.div_u
        local.set $v
        local.get $ox
        i32.const 5
        i32.sub
        local.set $ox
        local.get $v
        i32.eqz
        br_if $dd
        br $dl
      end
    end
  )

  ;; ============================================================
  ;; INIT
  ;; ============================================================
  (func (export "init")
    (local $i i32)

    ;; PRNG seed
    i32.const 0x10340
    i32.const 42069
    i32.store

    ;; ================================================================
    ;; RGB+Brightness palette: 2-bit R, G, B + 2-bit brightness = 256 colors
    ;; index = (R<<6)|(G<<4)|(B<<2)|L  R,G,B,L in 0..3
    ;; Channel values: 0→0, 1→85, 2→170, 3→255
    ;; Brightness: L=0→0.13, L=1→0.40, L=2→0.70, L=3→1.0
    ;; We must write this palette ourselves since harness uses standard VGA.
    ;; ================================================================
    ;; Write RGBL palette to 0x0040 (256 entries × 3 bytes = 768 bytes)
    ;; Channel levels table at 0x19600 (4 bytes): 0, 85, 170, 255
    ;; Brightness table at 0x19604 (4 × 2 bytes as fixed-point 0..256):
    ;;   L=0: 33, L=1: 102, L=2: 179, L=3: 255
    i32.const 0x19600
    i32.const 0     ;; chan[0] = 0
    i32.store8
    i32.const 0x19601
    i32.const 85    ;; chan[1] = 85
    i32.store8
    i32.const 0x19602
    i32.const 170   ;; chan[2] = 170
    i32.store8
    i32.const 0x19603
    i32.const 255   ;; chan[3] = 255
    i32.store8
    i32.const 0x19604
    i32.const 33    ;; bright[0] = 33/255 ≈ 0.13
    i32.store8
    i32.const 0x19605
    i32.const 102   ;; bright[1] = 102/255 ≈ 0.40
    i32.store8
    i32.const 0x19606
    i32.const 179   ;; bright[2] = 179/255 ≈ 0.70
    i32.store8
    i32.const 0x19607
    i32.const 255   ;; bright[3] = 255/255 = 1.0
    i32.store8
    ;; Loop over 256 palette entries
    i32.const 0
    local.set $i
    block $pal_done
      loop $pal_lp
        local.get $i
        i32.const 256
        i32.ge_u
        br_if $pal_done
        ;; Decode: R = (i>>6)&3, G = (i>>4)&3, B = (i>>2)&3, L = i&3
        ;; bright = table[L]
        ;; R_out = chan[R] * bright / 255
        ;; G_out = chan[G] * bright / 255
        ;; B_out = chan[B] * bright / 255
        ;; Palette address = 0x0040 + i*3
        ;; Write R
        i32.const 0x0040
        local.get $i
        i32.const 3
        i32.mul
        i32.add
        ;; chan[(i>>6)&3] * bright[i&3] / 255
        i32.const 0x19600
        local.get $i
        i32.const 6
        i32.shr_u
        i32.const 3
        i32.and
        i32.add
        i32.load8_u
        i32.const 0x19604
        local.get $i
        i32.const 3
        i32.and
        i32.add
        i32.load8_u
        i32.mul
        i32.const 255
        i32.div_u
        i32.store8
        ;; Write G
        i32.const 0x0040
        local.get $i
        i32.const 3
        i32.mul
        i32.add
        i32.const 1
        i32.add
        ;; chan[(i>>4)&3] * bright[i&3] / 255
        i32.const 0x19600
        local.get $i
        i32.const 4
        i32.shr_u
        i32.const 3
        i32.and
        i32.add
        i32.load8_u
        i32.const 0x19604
        local.get $i
        i32.const 3
        i32.and
        i32.add
        i32.load8_u
        i32.mul
        i32.const 255
        i32.div_u
        i32.store8
        ;; Write B
        i32.const 0x0040
        local.get $i
        i32.const 3
        i32.mul
        i32.add
        i32.const 2
        i32.add
        ;; chan[(i>>2)&3] * bright[i&3] / 255
        i32.const 0x19600
        local.get $i
        i32.const 2
        i32.shr_u
        i32.const 3
        i32.and
        i32.add
        i32.load8_u
        i32.const 0x19604
        local.get $i
        i32.const 3
        i32.and
        i32.add
        i32.load8_u
        i32.mul
        i32.const 255
        i32.div_u
        i32.store8
        ;; Next
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $pal_lp
      end
    end
    ;; ================================================================
    ;; Block type base color table at 0x19500 (9 bytes):
    ;; Indexed by block type from get_block (0=air, 1=grass, ..., 8=coal)
    ;; RGBL encoding: index = (R<<6)|(G<<4)|(B<<2)|L, L=0 for base
    ;;   type 0 (air):    0x00 (unused)
    ;;   type 1 (grass):  R=0,G=3,B=0 → 0x30
    ;;   type 2 (dirt):   R=2,G=1,B=0 → 0x90
    ;;   type 3 (stone):  R=2,G=2,B=2 → 0xA8
    ;;   type 4 (sand):   R=3,G=3,B=1 → 0xF4
    ;;   type 5 (water):  R=0,G=1,B=3 → 0x1C
    ;;   type 6 (wood):   R=1,G=1,B=0 → 0x50
    ;;   type 7 (leaves): R=0,G=2,B=0 → 0x20
    ;;   type 8 (coal):   R=1,G=1,B=1 → 0x54
    ;; ================================================================

    ;; Write block base color table
    i32.const 0x19500
    i32.const 0x00  ;; air: unused
    i32.store8
    i32.const 0x19501
    i32.const 0x30  ;; grass: green (R=0,G=3,B=0)
    i32.store8
    i32.const 0x19502
    i32.const 0x90  ;; dirt: brown (R=2,G=1,B=0)
    i32.store8
    i32.const 0x19503
    i32.const 0xA8  ;; stone: gray (R=2,G=2,B=2)
    i32.store8
    i32.const 0x19504
    i32.const 0xF4  ;; sand: yellow (R=3,G=3,B=1)
    i32.store8
    i32.const 0x19505
    i32.const 0x1C  ;; water: blue (R=0,G=1,B=3)
    i32.store8
    i32.const 0x19506
    i32.const 0x50  ;; wood: brown (R=1,G=1,B=0)
    i32.store8
    i32.const 0x19507
    i32.const 0x20  ;; leaves: dark green (R=0,G=2,B=0)
    i32.store8
    i32.const 0x19508
    i32.const 0x54  ;; coal: dark gray (R=1,G=1,B=1)
    i32.store8

    ;; Initialize player position (palette set by harness)
    i32.const 0x10344
    f64.const 32.5
    f64.store
    i32.const 0x1034C
    f64.const 32.5
    f64.store
    i32.const 0x10354
    f64.const 0.0
    f64.store
    i32.const 0x1035C
    i32.const 32
    i32.const 32
    call $terrain_height
    f64.convert_i32_s
    f64.const 1.7
    f64.add
    f64.store
    i32.const 0x10364
    f64.const 0.0
    f64.store
    i32.const 0x1036C
    i32.const 1
    i32.store
    i32.const 0x10374
    f64.const 0.0
    f64.store

    ;; Write monster base color table at 0x1950C (3 bytes)
    ;; creeper(type 0): dark green R=0,G=2,B=0 → 0x20
    ;; zombie(type 1): olive R=1,G=2,B=0 → 0x60
    ;; skeleton(type 2): bone R=3,G=3,B=2 → 0xF8
    i32.const 0x1950C
    i32.const 0x20
    i32.store8
    i32.const 0x1950D
    i32.const 0x60
    i32.store8
    i32.const 0x1950E
    i32.const 0xF8
    i32.store8

    ;; Game state
    i32.const 0x10390
    i32.const 0
    i32.store
    i32.const 0x10394
    i32.const 1900
    i32.store
    i32.const 0x10398
    i32.const 0
    i32.store
    i32.const 0x1039C
    i32.const 0
    i32.store
    i32.const 0x103A0
    i32.const 0
    i32.store
    i32.const 0x103A4
    i32.const 0
    i32.store
    i32.const 0x103A8
    i32.const 1
    i32.store
    i32.const 0x103AC
    i32.const 0
    i32.store

    ;; Initialize octree cache
    call $octree_init

    ;; Spawn monsters
    call $spawn_monsters
    ;; Init font
    call $init_font
  )

  ;; ---- Spawn monsters ----
  (func $spawn_monsters
    (local $i i32) (local $addr i32) (local $angle f64) (local $dist f64)
    (local $mx f64) (local $my f64) (local $px f64) (local $py f64)
    i32.const 0x10344
    f64.load
    local.set $px
    i32.const 0x1034C
    f64.load
    local.set $py
    i32.const 0
    local.set $i
    block $done
      loop $lp
        local.get $i
        i32.const 24
        i32.ge_u
        br_if $done
        i32.const 0x10900
        local.get $i
        i32.const 32
        i32.mul
        i32.add
        local.set $addr
        local.get $i
        f64.convert_i32_u
        f64.const 0.2618
        f64.mul
        local.set $angle
        f64.const 8.0
        call $rand
        i32.const 15
        i32.and
        f64.convert_i32_u
        f64.const 1.5
        f64.mul
        f64.add
        local.set $dist
        local.get $px
        local.get $angle
        call $cos_a
        local.get $dist
        f64.mul
        f64.add
        local.set $mx
        local.get $py
        local.get $angle
        call $sin_a
        local.get $dist
        f64.mul
        f64.add
        local.set $my
        local.get $addr
        i32.const 1
        i32.store
        local.get $addr
        i32.const 4
        i32.add
        local.get $i
        i32.const 3
        i32.rem_u
        i32.store
        local.get $addr
        i32.const 8
        i32.add
        local.get $mx
        f64.store
        local.get $addr
        i32.const 16
        i32.add
        local.get $my
        f64.store
        local.get $addr
        i32.const 24
        i32.add
        i32.const 3
        i32.store
        local.get $addr
        i32.const 28
        i32.add
        call $rand
        i32.const 255
        i32.and
        i32.store
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $lp
      end
    end
  )

  ;; ---- Font init (mini 4x6 bitmap font) ----
  (func $init_font
    (local $base i32)
    i32.const 0x19200
    local.set $base
    ;; '!' (33) offset=6
    local.get $base
    i32.const 6
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 7
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 8
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 9
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 10
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 11
    i32.add
    i32.const 0x00
    i32.store8
    ;; '0' offset=96
    local.get $base
    i32.const 96
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 97
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 98
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 99
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 100
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 101
    i32.add
    i32.const 0x00
    i32.store8
    ;; '1'
    local.get $base
    i32.const 102
    i32.add
    i32.const 0x02
    i32.store8
    local.get $base
    i32.const 103
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 104
    i32.add
    i32.const 0x02
    i32.store8
    local.get $base
    i32.const 105
    i32.add
    i32.const 0x02
    i32.store8
    local.get $base
    i32.const 106
    i32.add
    i32.const 0x07
    i32.store8
    local.get $base
    i32.const 107
    i32.add
    i32.const 0x00
    i32.store8
    ;; '2'
    local.get $base
    i32.const 108
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 109
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 110
    i32.add
    i32.const 0x02
    i32.store8
    local.get $base
    i32.const 111
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 112
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 113
    i32.add
    i32.const 0x00
    i32.store8
    ;; '3'
    local.get $base
    i32.const 114
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 115
    i32.add
    i32.const 0x01
    i32.store8
    local.get $base
    i32.const 116
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 117
    i32.add
    i32.const 0x01
    i32.store8
    local.get $base
    i32.const 118
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 119
    i32.add
    i32.const 0x00
    i32.store8
    ;; '4'
    local.get $base
    i32.const 120
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 121
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 122
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 123
    i32.add
    i32.const 0x01
    i32.store8
    local.get $base
    i32.const 124
    i32.add
    i32.const 0x01
    i32.store8
    local.get $base
    i32.const 125
    i32.add
    i32.const 0x00
    i32.store8
    ;; '5'
    local.get $base
    i32.const 126
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 127
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 128
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 129
    i32.add
    i32.const 0x01
    i32.store8
    local.get $base
    i32.const 130
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 131
    i32.add
    i32.const 0x00
    i32.store8
    ;; '6'
    local.get $base
    i32.const 132
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 133
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 134
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 135
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 136
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 137
    i32.add
    i32.const 0x00
    i32.store8
    ;; '7'
    local.get $base
    i32.const 138
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 139
    i32.add
    i32.const 0x01
    i32.store8
    local.get $base
    i32.const 140
    i32.add
    i32.const 0x02
    i32.store8
    local.get $base
    i32.const 141
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 142
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 143
    i32.add
    i32.const 0x00
    i32.store8
    ;; '8'
    local.get $base
    i32.const 144
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 145
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 146
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 147
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 148
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 149
    i32.add
    i32.const 0x00
    i32.store8
    ;; '9'
    local.get $base
    i32.const 150
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 151
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 152
    i32.add
    i32.const 0x07
    i32.store8
    local.get $base
    i32.const 153
    i32.add
    i32.const 0x01
    i32.store8
    local.get $base
    i32.const 154
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 155
    i32.add
    i32.const 0x00
    i32.store8
    ;; ':' offset=156
    local.get $base
    i32.const 156
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 157
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 158
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 159
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 160
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 161
    i32.add
    i32.const 0x00
    i32.store8
    ;; '/' offset=90
    local.get $base
    i32.const 90
    i32.add
    i32.const 0x01
    i32.store8
    local.get $base
    i32.const 91
    i32.add
    i32.const 0x02
    i32.store8
    local.get $base
    i32.const 92
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 93
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 94
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 95
    i32.add
    i32.const 0x00
    i32.store8
    ;; Letters A-Z at offset 198..
    local.get $base
    i32.const 198
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 199
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 200
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 201
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 202
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 203
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 204
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 205
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 206
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 207
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 208
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 209
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 210
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 211
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 212
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 213
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 214
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 215
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 216
    i32.add
    i32.const 0x0C
    i32.store8
    local.get $base
    i32.const 217
    i32.add
    i32.const 0x0A
    i32.store8
    local.get $base
    i32.const 218
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 219
    i32.add
    i32.const 0x0A
    i32.store8
    local.get $base
    i32.const 220
    i32.add
    i32.const 0x0C
    i32.store8
    local.get $base
    i32.const 221
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 222
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 223
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 224
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 225
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 226
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 227
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 228
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 229
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 230
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 231
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 232
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 233
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 234
    i32.add
    i32.const 0x07
    i32.store8
    local.get $base
    i32.const 235
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 236
    i32.add
    i32.const 0x0B
    i32.store8
    local.get $base
    i32.const 237
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 238
    i32.add
    i32.const 0x07
    i32.store8
    local.get $base
    i32.const 239
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 240
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 241
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 242
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 243
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 244
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 245
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 246
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 247
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 248
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 249
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 250
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 251
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 252
    i32.add
    i32.const 0x01
    i32.store8
    local.get $base
    i32.const 253
    i32.add
    i32.const 0x01
    i32.store8
    local.get $base
    i32.const 254
    i32.add
    i32.const 0x01
    i32.store8
    local.get $base
    i32.const 255
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 256
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 257
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 258
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 259
    i32.add
    i32.const 0x0A
    i32.store8
    local.get $base
    i32.const 260
    i32.add
    i32.const 0x0C
    i32.store8
    local.get $base
    i32.const 261
    i32.add
    i32.const 0x0A
    i32.store8
    local.get $base
    i32.const 262
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 263
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 264
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 265
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 266
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 267
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 268
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 269
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 270
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 271
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 272
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 273
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 274
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 275
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 276
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 277
    i32.add
    i32.const 0x0D
    i32.store8
    local.get $base
    i32.const 278
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 279
    i32.add
    i32.const 0x0B
    i32.store8
    local.get $base
    i32.const 280
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 281
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 282
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 283
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 284
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 285
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 286
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 287
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 288
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 289
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 290
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 291
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 292
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 293
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 294
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 295
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 296
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 297
    i32.add
    i32.const 0x07
    i32.store8
    local.get $base
    i32.const 298
    i32.add
    i32.const 0x01
    i32.store8
    local.get $base
    i32.const 299
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 300
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 301
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 302
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 303
    i32.add
    i32.const 0x0A
    i32.store8
    local.get $base
    i32.const 304
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 305
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 306
    i32.add
    i32.const 0x07
    i32.store8
    local.get $base
    i32.const 307
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 308
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 309
    i32.add
    i32.const 0x01
    i32.store8
    local.get $base
    i32.const 310
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 311
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 312
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 313
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 314
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 315
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 316
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 317
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 318
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 319
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 320
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 321
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 322
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 323
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 324
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 325
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 326
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 327
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 328
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 329
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 330
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 331
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 332
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 333
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 334
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 335
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 336
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 337
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 338
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 339
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 340
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 341
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 342
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 343
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 344
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 345
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 346
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 347
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 348
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 349
    i32.add
    i32.const 0x01
    i32.store8
    local.get $base
    i32.const 350
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 351
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 352
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 353
    i32.add
    i32.const 0x00
    i32.store8
    ;; Lowercase copies (a-z = same as A-Z)
    local.get $base
    i32.const 390
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 391
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 392
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 393
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 394
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 395
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 396
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 397
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 398
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 399
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 400
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 401
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 402
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 403
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 404
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 405
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 406
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 407
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 408
    i32.add
    i32.const 0x0C
    i32.store8
    local.get $base
    i32.const 409
    i32.add
    i32.const 0x0A
    i32.store8
    local.get $base
    i32.const 410
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 411
    i32.add
    i32.const 0x0A
    i32.store8
    local.get $base
    i32.const 412
    i32.add
    i32.const 0x0C
    i32.store8
    local.get $base
    i32.const 413
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 414
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 415
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 416
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 417
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 418
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 419
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 420
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 421
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 422
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 423
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 424
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 425
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 426
    i32.add
    i32.const 0x07
    i32.store8
    local.get $base
    i32.const 427
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 428
    i32.add
    i32.const 0x0B
    i32.store8
    local.get $base
    i32.const 429
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 430
    i32.add
    i32.const 0x07
    i32.store8
    local.get $base
    i32.const 431
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 432
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 433
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 434
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 435
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 436
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 437
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 438
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 439
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 440
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 441
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 442
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 443
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 444
    i32.add
    i32.const 0x01
    i32.store8
    local.get $base
    i32.const 445
    i32.add
    i32.const 0x01
    i32.store8
    local.get $base
    i32.const 446
    i32.add
    i32.const 0x01
    i32.store8
    local.get $base
    i32.const 447
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 448
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 449
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 450
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 451
    i32.add
    i32.const 0x0A
    i32.store8
    local.get $base
    i32.const 452
    i32.add
    i32.const 0x0C
    i32.store8
    local.get $base
    i32.const 453
    i32.add
    i32.const 0x0A
    i32.store8
    local.get $base
    i32.const 454
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 455
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 456
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 457
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 458
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 459
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 460
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 461
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 462
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 463
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 464
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 465
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 466
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 467
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 468
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 469
    i32.add
    i32.const 0x0D
    i32.store8
    local.get $base
    i32.const 470
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 471
    i32.add
    i32.const 0x0B
    i32.store8
    local.get $base
    i32.const 472
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 473
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 474
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 475
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 476
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 477
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 478
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 479
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 480
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 481
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 482
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 483
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 484
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 485
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 486
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 487
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 488
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 489
    i32.add
    i32.const 0x07
    i32.store8
    local.get $base
    i32.const 490
    i32.add
    i32.const 0x01
    i32.store8
    local.get $base
    i32.const 491
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 492
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 493
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 494
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 495
    i32.add
    i32.const 0x0A
    i32.store8
    local.get $base
    i32.const 496
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 497
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 498
    i32.add
    i32.const 0x07
    i32.store8
    local.get $base
    i32.const 499
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 500
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 501
    i32.add
    i32.const 0x01
    i32.store8
    local.get $base
    i32.const 502
    i32.add
    i32.const 0x0E
    i32.store8
    local.get $base
    i32.const 503
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 504
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 505
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 506
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 507
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 508
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 509
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 510
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 511
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 512
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 513
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 514
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 515
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 516
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 517
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 518
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 519
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 520
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 521
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 522
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 523
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 524
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 525
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 526
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 527
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 528
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 529
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 530
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 531
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 532
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 533
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 534
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 535
    i32.add
    i32.const 0x09
    i32.store8
    local.get $base
    i32.const 536
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 537
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 538
    i32.add
    i32.const 0x04
    i32.store8
    local.get $base
    i32.const 539
    i32.add
    i32.const 0x00
    i32.store8
    local.get $base
    i32.const 540
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 541
    i32.add
    i32.const 0x01
    i32.store8
    local.get $base
    i32.const 542
    i32.add
    i32.const 0x06
    i32.store8
    local.get $base
    i32.const 543
    i32.add
    i32.const 0x08
    i32.store8
    local.get $base
    i32.const 544
    i32.add
    i32.const 0x0F
    i32.store8
    local.get $base
    i32.const 545
    i32.add
    i32.const 0x00
    i32.store8
  )

  ;; ============================================================
  ;; Strings
  ;; ============================================================
  (data (i32.const 0x19000) "VGACRAFT RT\00")
  (data (i32.const 0x19010) "WASD:move LR:turn\00")
  (data (i32.const 0x19030) "CLICK:dig SHIFT:place\00")
  (data (i32.const 0x19050) "You angered the\00")
  (data (i32.const 0x19070) "Minecraft gods by\00")
  (data (i32.const 0x19090) "digging too much!\00")
  (data (i32.const 0x190B0) "Blocks:\00")
  (data (i32.const 0x190C0) "Mods:\00")
  (data (i32.const 0x190D0) "/\00")
  (data (i32.const 0x190E0) ":\00")

  ;; ============================================================
  ;; OCTREE-ACCELERATED VOXEL RAYTRACER
  ;; ============================================================
  ;; Two-level octree for O(log n) raycasting over long distances.
  ;; Level 0 (coarse): 4×4×4 chunk grid. Each chunk = 1 byte
  ;;   (0=all air/empty, 1=has solid blocks, 255=not yet computed).
  ;;   Cached at 0x1A000. Index = ((cx&63)*64 + (cy&63))*8 + (cz&7)
  ;;   Chunks are 4×4×4 voxels, covering world Z 0..31.
  ;;   Lazily built from procedural terrain on first access.
  ;; Level 1 (fine): standard DDA within non-empty chunks.
  ;;
  ;; Memory layout for octree cache:
  ;;   0x1A000 .. 0x1FFFF  chunk occupancy (64*64*8 = 32768 bytes)
  ;;   0x20000 .. 0x20003  cache_gen counter (invalidated on set_block)
  ;; ============================================================

  (global $g_hit_face (mut i32) (i32.const 0))
  (global $g_hit_dist (mut f64) (f64.const 0.0))
  (global $g_hit_vx (mut i32) (i32.const 0))
  (global $g_hit_vy (mut i32) (i32.const 0))
  (global $g_hit_vz (mut i32) (i32.const 0))
  (global $g_cache_gen (mut i32) (i32.const 0))

  ;; ---- Initialize octree cache (fill with 255 = unknown) ----
  (func $octree_init
    (local $i i32)
    i32.const 0
    local.set $i
    block $done
      loop $lp
        local.get $i
        i32.const 32768
        i32.ge_u
        br_if $done
        i32.const 0x1A000
        local.get $i
        i32.add
        i32.const 255
        i32.store8
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $lp
      end
    end
  )

  ;; ---- Invalidate octree near a modification ----
  ;; Called when a block is set/removed. Marks the chunk and neighbors as unknown.
  (func $octree_invalidate (param $wx i32) (param $wy i32) (param $wz i32)
    (local $cx i32) (local $cy i32) (local $cz i32)
    (local $dx i32) (local $dy i32) (local $dz i32)
    (local $ncx i32) (local $ncy i32) (local $ncz i32)
    (local $addr i32)
    ;; chunk coords
    local.get $wx
    i32.const 2
    i32.shr_s
    local.set $cx
    local.get $wy
    i32.const 2
    i32.shr_s
    local.set $cy
    local.get $wz
    i32.const 2
    i32.shr_s
    local.set $cz
    ;; Mark 3x3x3 neighborhood of chunks as unknown
    i32.const -1
    local.set $dx
    block $dx_done
      loop $dx_lp
        local.get $dx
        i32.const 2
        i32.ge_s
        br_if $dx_done
        i32.const -1
        local.set $dy
        block $dy_done
          loop $dy_lp
            local.get $dy
            i32.const 2
            i32.ge_s
            br_if $dy_done
            i32.const -1
            local.set $dz
            block $dz_done
              loop $dz_lp
                local.get $dz
                i32.const 2
                i32.ge_s
                br_if $dz_done
                local.get $cx
                local.get $dx
                i32.add
                i32.const 63
                i32.and
                local.set $ncx
                local.get $cy
                local.get $dy
                i32.add
                i32.const 63
                i32.and
                local.set $ncy
                local.get $cz
                local.get $dz
                i32.add
                local.set $ncz
                local.get $ncz
                i32.const 0
                i32.ge_s
                local.get $ncz
                i32.const 8
                i32.lt_s
                i32.and
                if
                  i32.const 0x1A000
                  local.get $ncx
                  i32.const 6
                  i32.shl
                  local.get $ncy
                  i32.add
                  i32.const 3
                  i32.shl
                  local.get $ncz
                  i32.add
                  i32.add
                  i32.const 255
                  i32.store8
                end
                local.get $dz
                i32.const 1
                i32.add
                local.set $dz
                br $dz_lp
              end
            end
            local.get $dy
            i32.const 1
            i32.add
            local.set $dy
            br $dy_lp
          end
        end
        local.get $dx
        i32.const 1
        i32.add
        local.set $dx
        br $dx_lp
      end
    end
  )

  ;; ---- Get chunk occupancy (lazy-build from procedural terrain) ----
  ;; Returns 0 if chunk is all air, 1 if it has any solid block
  (func $chunk_occupied (param $cx i32) (param $cy i32) (param $cz i32) (result i32)
    (local $addr i32) (local $val i32)
    (local $bx i32) (local $by i32) (local $bz i32)
    (local $wx i32) (local $wy i32) (local $wz i32)
    (local $has_solid i32)
    ;; Clamp cz to 0..7
    local.get $cz
    i32.const 0
    i32.lt_s
    if
      ;; Below world: always solid (bedrock)
      i32.const 1
      return
    end
    local.get $cz
    i32.const 7
    i32.gt_s
    if
      ;; Above world: always empty
      i32.const 0
      return
    end
    ;; Compute cache address
    i32.const 0x1A000
    local.get $cx
    i32.const 63
    i32.and
    i32.const 6
    i32.shl
    local.get $cy
    i32.const 63
    i32.and
    i32.add
    i32.const 3
    i32.shl
    local.get $cz
    i32.add
    i32.add
    local.set $addr
    local.get $addr
    i32.load8_u
    local.set $val
    ;; If already computed (0 or 1), return it
    local.get $val
    i32.const 255
    i32.ne
    if
      local.get $val
      return
    end
    ;; Lazy build: scan all 4×4×4 voxels in this chunk
    i32.const 0
    local.set $has_solid
    i32.const 0
    local.set $bx
    block $scan_done
      loop $scan_x
        local.get $bx
        i32.const 4
        i32.ge_u
        br_if $scan_done
        i32.const 0
        local.set $by
        block $sy_done
          loop $scan_y
            local.get $by
            i32.const 4
            i32.ge_u
            br_if $sy_done
            i32.const 0
            local.set $bz
            block $sz_done
              loop $scan_z
                local.get $bz
                i32.const 4
                i32.ge_u
                br_if $sz_done
                local.get $cx
                i32.const 2
                i32.shl
                local.get $bx
                i32.add
                local.set $wx
                local.get $cy
                i32.const 2
                i32.shl
                local.get $by
                i32.add
                local.set $wy
                local.get $cz
                i32.const 2
                i32.shl
                local.get $bz
                i32.add
                local.set $wz
                local.get $wx
                local.get $wy
                local.get $wz
                call $get_block
                i32.const 0
                i32.ne
                if
                  i32.const 1
                  local.set $has_solid
                  ;; Early exit
                  local.get $addr
                  i32.const 1
                  i32.store8
                  i32.const 1
                  return
                end
                local.get $bz
                i32.const 1
                i32.add
                local.set $bz
                br $scan_z
              end
            end
            local.get $by
            i32.const 1
            i32.add
            local.set $by
            br $scan_y
          end
        end
        local.get $bx
        i32.const 1
        i32.add
        local.set $bx
        br $scan_x
      end
    end
    ;; All air
    local.get $addr
    i32.const 0
    i32.store8
    i32.const 0
  )

  ;; ---- Floor divide (handles negatives correctly) ----
  (func $floor_div (param $a i32) (param $b i32) (result i32)
    (local $d i32)
    local.get $a
    local.get $b
    i32.div_s
    local.set $d
    ;; If a < 0 and a != d*b, subtract 1
    local.get $a
    i32.const 0
    i32.lt_s
    local.get $d
    local.get $b
    i32.mul
    local.get $a
    i32.ne
    i32.and
    if
      local.get $d
      i32.const 1
      i32.sub
      local.set $d
    end
    local.get $d
  )

  ;; ============================================================
  ;; cast_ray — Octree-accelerated 3D DDA
  ;; Two phases per step:
  ;;   1. Check if current chunk (4×4×4) is empty → skip to chunk boundary
  ;;   2. If chunk has solids → fine DDA within chunk up to 4 steps
  ;; Max distance: 96 blocks (was 24), max steps: 200
  ;; ============================================================
  (func $cast_ray (param $ox f64) (param $oy f64) (param $oz f64)
                   (param $dx f64) (param $dy f64) (param $dz f64)
                   (result i32)
    (local $vx i32) (local $vy i32) (local $vz i32)
    (local $step_x i32) (local $step_y i32) (local $step_z i32)
    (local $t_max_x f64) (local $t_max_y f64) (local $t_max_z f64)
    (local $t_delta_x f64) (local $t_delta_y f64) (local $t_delta_z f64)
    (local $steps i32) (local $block i32) (local $face i32)
    (local $t_cur f64)
    (local $cx i32) (local $cy i32) (local $cz i32)
    (local $chunk_occ i32)
    (local $chunk_bound_x f64) (local $chunk_bound_y f64) (local $chunk_bound_z f64)
    (local $t_skip_x f64) (local $t_skip_y f64) (local $t_skip_z f64)
    (local $t_skip f64)
    (local $new_x f64) (local $new_y f64) (local $new_z f64)
    (local $inv_dx f64) (local $inv_dy f64) (local $inv_dz f64)

    ;; Precompute inverse direction
    local.get $dx
    f64.abs
    f64.const 0.000001
    f64.gt
    if (result f64)
      f64.const 1.0
      local.get $dx
      f64.div
    else
      f64.const 999999.0
    end
    local.set $inv_dx
    local.get $dy
    f64.abs
    f64.const 0.000001
    f64.gt
    if (result f64)
      f64.const 1.0
      local.get $dy
      f64.div
    else
      f64.const 999999.0
    end
    local.set $inv_dy
    local.get $dz
    f64.abs
    f64.const 0.000001
    f64.gt
    if (result f64)
      f64.const 1.0
      local.get $dz
      f64.div
    else
      f64.const 999999.0
    end
    local.set $inv_dz

    ;; Starting voxel
    local.get $ox
    f64.floor
    i32.trunc_f64_s
    local.set $vx
    local.get $oy
    f64.floor
    i32.trunc_f64_s
    local.set $vy
    local.get $oz
    f64.floor
    i32.trunc_f64_s
    local.set $vz

    ;; Step direction and t_delta for X
    local.get $dx
    f64.const 0.0
    f64.gt
    if
      i32.const 1
      local.set $step_x
      local.get $vx
      f64.convert_i32_s
      f64.const 1.0
      f64.add
      local.get $ox
      f64.sub
      local.get $dx
      f64.div
      local.set $t_max_x
      f64.const 1.0
      local.get $dx
      f64.div
      local.set $t_delta_x
    else
      local.get $dx
      f64.const 0.0
      f64.lt
      if
        i32.const -1
        local.set $step_x
        local.get $vx
        f64.convert_i32_s
        local.get $ox
        f64.sub
        local.get $dx
        f64.div
        local.set $t_max_x
        f64.const -1.0
        local.get $dx
        f64.div
        local.set $t_delta_x
      else
        i32.const 0
        local.set $step_x
        f64.const 999999.0
        local.set $t_max_x
        f64.const 999999.0
        local.set $t_delta_x
      end
    end

    ;; Step direction and t_delta for Y
    local.get $dy
    f64.const 0.0
    f64.gt
    if
      i32.const 1
      local.set $step_y
      local.get $vy
      f64.convert_i32_s
      f64.const 1.0
      f64.add
      local.get $oy
      f64.sub
      local.get $dy
      f64.div
      local.set $t_max_y
      f64.const 1.0
      local.get $dy
      f64.div
      local.set $t_delta_y
    else
      local.get $dy
      f64.const 0.0
      f64.lt
      if
        i32.const -1
        local.set $step_y
        local.get $vy
        f64.convert_i32_s
        local.get $oy
        f64.sub
        local.get $dy
        f64.div
        local.set $t_max_y
        f64.const -1.0
        local.get $dy
        f64.div
        local.set $t_delta_y
      else
        i32.const 0
        local.set $step_y
        f64.const 999999.0
        local.set $t_max_y
        f64.const 999999.0
        local.set $t_delta_y
      end
    end

    ;; Step direction and t_delta for Z
    local.get $dz
    f64.const 0.0
    f64.gt
    if
      i32.const 1
      local.set $step_z
      local.get $vz
      f64.convert_i32_s
      f64.const 1.0
      f64.add
      local.get $oz
      f64.sub
      local.get $dz
      f64.div
      local.set $t_max_z
      f64.const 1.0
      local.get $dz
      f64.div
      local.set $t_delta_z
    else
      local.get $dz
      f64.const 0.0
      f64.lt
      if
        i32.const -1
        local.set $step_z
        local.get $vz
        f64.convert_i32_s
        local.get $oz
        f64.sub
        local.get $dz
        f64.div
        local.set $t_max_z
        f64.const -1.0
        local.get $dz
        f64.div
        local.set $t_delta_z
      else
        i32.const 0
        local.set $step_z
        f64.const 999999.0
        local.set $t_max_z
        f64.const 999999.0
        local.set $t_delta_z
      end
    end

    i32.const 0
    local.set $face
    f64.const 0.0
    local.set $t_cur
    i32.const 0
    local.set $steps

    ;; Check starting block
    local.get $vz
    i32.const -1
    i32.ge_s
    local.get $vz
    i32.const 32
    i32.le_s
    i32.and
    if
      local.get $vx
      local.get $vy
      local.get $vz
      call $get_block
      local.set $block
      local.get $block
      i32.const 0
      i32.ne
      if
        i32.const 0
        global.set $g_hit_face
        f64.const 0.0
        global.set $g_hit_dist
        local.get $vx
        global.set $g_hit_vx
        local.get $vy
        global.set $g_hit_vy
        local.get $vz
        global.set $g_hit_vz
        local.get $block
        return
      end
    end

    ;; Main traversal loop — max 200 steps (octree skipping keeps this fast)
    block $done
      loop $lp
        local.get $steps
        i32.const 200
        i32.ge_u
        br_if $done

        ;; ---- OCTREE SKIP CHECK ----
        ;; Current chunk coords (floor_div by 4)
        local.get $vx
        i32.const 4
        call $floor_div
        local.set $cx
        local.get $vy
        i32.const 4
        call $floor_div
        local.set $cy
        local.get $vz
        i32.const 4
        call $floor_div
        local.set $cz

        ;; Check chunk occupancy
        local.get $cx
        local.get $cy
        local.get $cz
        call $chunk_occupied
        local.set $chunk_occ

        local.get $chunk_occ
        i32.eqz
        if
          ;; EMPTY CHUNK: skip to chunk boundary (jump 1-4 voxels at once)
          ;; Compute t to exit this 4-block chunk in each axis
          ;; Chunk boundary in world coords:
          ;;   X: step>0 → (cx+1)*4, step<0 → cx*4, step==0 → huge
          f64.const 999999.0
          local.set $t_skip_x
          local.get $step_x
          i32.const 1
          i32.eq
          if
            local.get $cx
            i32.const 1
            i32.add
            i32.const 2
            i32.shl
            f64.convert_i32_s
            local.get $ox
            f64.sub
            local.get $t_cur
            local.get $dx
            f64.mul
            f64.sub
            local.get $inv_dx
            f64.mul
            local.get $t_cur
            f64.add
            local.set $t_skip_x
          end
          local.get $step_x
          i32.const -1
          i32.eq
          if
            local.get $cx
            i32.const 2
            i32.shl
            f64.convert_i32_s
            local.get $ox
            f64.sub
            local.get $t_cur
            local.get $dx
            f64.mul
            f64.sub
            local.get $inv_dx
            f64.mul
            local.get $t_cur
            f64.add
            local.set $t_skip_x
          end

          f64.const 999999.0
          local.set $t_skip_y
          local.get $step_y
          i32.const 1
          i32.eq
          if
            local.get $cy
            i32.const 1
            i32.add
            i32.const 2
            i32.shl
            f64.convert_i32_s
            local.get $oy
            f64.sub
            local.get $t_cur
            local.get $dy
            f64.mul
            f64.sub
            local.get $inv_dy
            f64.mul
            local.get $t_cur
            f64.add
            local.set $t_skip_y
          end
          local.get $step_y
          i32.const -1
          i32.eq
          if
            local.get $cy
            i32.const 2
            i32.shl
            f64.convert_i32_s
            local.get $oy
            f64.sub
            local.get $t_cur
            local.get $dy
            f64.mul
            f64.sub
            local.get $inv_dy
            f64.mul
            local.get $t_cur
            f64.add
            local.set $t_skip_y
          end

          f64.const 999999.0
          local.set $t_skip_z
          local.get $step_z
          i32.const 1
          i32.eq
          if
            local.get $cz
            i32.const 1
            i32.add
            i32.const 2
            i32.shl
            f64.convert_i32_s
            local.get $oz
            f64.sub
            local.get $t_cur
            local.get $dz
            f64.mul
            f64.sub
            local.get $inv_dz
            f64.mul
            local.get $t_cur
            f64.add
            local.set $t_skip_z
          end

          ;; Find minimum exit t and set face accordingly
          local.get $t_skip_x
          local.set $t_skip
          ;; face from X exit
          local.get $step_x
          i32.const 1
          i32.eq
          if
            i32.const 2
            local.set $face
          else
            i32.const 1
            local.set $face
          end

          local.get $t_skip_y
          local.get $t_skip
          f64.lt
          if
            local.get $t_skip_y
            local.set $t_skip
            local.get $step_y
            i32.const 1
            i32.eq
            if
              i32.const 2
              local.set $face
            else
              i32.const 1
              local.set $face
            end
          end

          local.get $t_skip_z
          local.get $t_skip
          f64.lt
          if
            local.get $t_skip_z
            local.set $t_skip
            local.get $step_z
            i32.const 1
            i32.eq
            if
              i32.const 3
              local.set $face
            else
              i32.const 0
              local.set $face
            end
          end

          ;; Advance to chunk exit + tiny epsilon
          local.get $t_skip
          f64.const 0.001
          f64.add
          local.set $t_cur

          ;; Bail if too far
          local.get $t_cur
          f64.const 96.0
          f64.gt
          br_if $done

          ;; Recompute voxel position from parametric t
          local.get $ox
          local.get $dx
          local.get $t_cur
          f64.mul
          f64.add
          f64.floor
          i32.trunc_f64_s
          local.set $vx
          local.get $oy
          local.get $dy
          local.get $t_cur
          f64.mul
          f64.add
          f64.floor
          i32.trunc_f64_s
          local.set $vy
          local.get $oz
          local.get $dz
          local.get $t_cur
          f64.mul
          f64.add
          f64.floor
          i32.trunc_f64_s
          local.set $vz

          ;; Recompute t_max for fine DDA from new position
          local.get $dx
          f64.const 0.0
          f64.gt
          if
            local.get $vx
            f64.convert_i32_s
            f64.const 1.0
            f64.add
            local.get $ox
            f64.sub
            local.get $dx
            local.get $t_cur
            f64.mul
            f64.sub
            local.get $inv_dx
            f64.mul
            local.get $t_cur
            f64.add
            local.set $t_max_x
          else
            local.get $dx
            f64.const 0.0
            f64.lt
            if
              local.get $vx
              f64.convert_i32_s
              local.get $ox
              f64.sub
              local.get $dx
              local.get $t_cur
              f64.mul
              f64.sub
              local.get $inv_dx
              f64.mul
              local.get $t_cur
              f64.add
              local.set $t_max_x
            end
          end
          local.get $dy
          f64.const 0.0
          f64.gt
          if
            local.get $vy
            f64.convert_i32_s
            f64.const 1.0
            f64.add
            local.get $oy
            f64.sub
            local.get $dy
            local.get $t_cur
            f64.mul
            f64.sub
            local.get $inv_dy
            f64.mul
            local.get $t_cur
            f64.add
            local.set $t_max_y
          else
            local.get $dy
            f64.const 0.0
            f64.lt
            if
              local.get $vy
              f64.convert_i32_s
              local.get $oy
              f64.sub
              local.get $dy
              local.get $t_cur
              f64.mul
              f64.sub
              local.get $inv_dy
              f64.mul
              local.get $t_cur
              f64.add
              local.set $t_max_y
            end
          end
          local.get $dz
          f64.const 0.0
          f64.gt
          if
            local.get $vz
            f64.convert_i32_s
            f64.const 1.0
            f64.add
            local.get $oz
            f64.sub
            local.get $dz
            local.get $t_cur
            f64.mul
            f64.sub
            local.get $inv_dz
            f64.mul
            local.get $t_cur
            f64.add
            local.set $t_max_z
          else
            local.get $dz
            f64.const 0.0
            f64.lt
            if
              local.get $vz
              f64.convert_i32_s
              local.get $oz
              f64.sub
              local.get $dz
              local.get $t_cur
              f64.mul
              f64.sub
              local.get $inv_dz
              f64.mul
              local.get $t_cur
              f64.add
              local.set $t_max_z
            end
          end

          ;; Bail if out of Z range
          local.get $vz
          i32.const -1
          i32.lt_s
          br_if $done
          local.get $vz
          i32.const 32
          i32.gt_s
          br_if $done

          local.get $steps
          i32.const 1
          i32.add
          local.set $steps
          br $lp
        end

        ;; ---- OCCUPIED CHUNK: fine DDA step (single voxel) ----
        ;; Step along smallest t_max axis
        local.get $t_max_x
        local.get $t_max_y
        f64.le
        if
          local.get $t_max_x
          local.get $t_max_z
          f64.le
          if
            ;; Step X
            local.get $t_max_x
            local.set $t_cur
            local.get $vx
            local.get $step_x
            i32.add
            local.set $vx
            local.get $t_max_x
            local.get $t_delta_x
            f64.add
            local.set $t_max_x
            local.get $step_x
            i32.const 1
            i32.eq
            if
              i32.const 2
              local.set $face
            else
              i32.const 1
              local.set $face
            end
          else
            ;; Step Z
            local.get $t_max_z
            local.set $t_cur
            local.get $vz
            local.get $step_z
            i32.add
            local.set $vz
            local.get $t_max_z
            local.get $t_delta_z
            f64.add
            local.set $t_max_z
            local.get $step_z
            i32.const 1
            i32.eq
            if
              i32.const 3
              local.set $face
            else
              i32.const 0
              local.set $face
            end
          end
        else
          local.get $t_max_y
          local.get $t_max_z
          f64.le
          if
            ;; Step Y
            local.get $t_max_y
            local.set $t_cur
            local.get $vy
            local.get $step_y
            i32.add
            local.set $vy
            local.get $t_max_y
            local.get $t_delta_y
            f64.add
            local.set $t_max_y
            local.get $step_y
            i32.const 1
            i32.eq
            if
              i32.const 2
              local.set $face
            else
              i32.const 1
              local.set $face
            end
          else
            ;; Step Z
            local.get $t_max_z
            local.set $t_cur
            local.get $vz
            local.get $step_z
            i32.add
            local.set $vz
            local.get $t_max_z
            local.get $t_delta_z
            f64.add
            local.set $t_max_z
            local.get $step_z
            i32.const 1
            i32.eq
            if
              i32.const 3
              local.set $face
            else
              i32.const 0
              local.set $face
            end
          end
        end

        ;; Bail if too far or out of Z range
        local.get $t_cur
        f64.const 96.0
        f64.gt
        br_if $done
        local.get $vz
        i32.const -1
        i32.lt_s
        br_if $done
        local.get $vz
        i32.const 32
        i32.gt_s
        br_if $done

        ;; Check block
        local.get $vx
        local.get $vy
        local.get $vz
        call $get_block
        local.set $block
        local.get $block
        i32.const 0
        i32.ne
        if
          local.get $face
          global.set $g_hit_face
          local.get $t_cur
          global.set $g_hit_dist
          local.get $vx
          global.set $g_hit_vx
          local.get $vy
          global.set $g_hit_vy
          local.get $vz
          global.set $g_hit_vz
          local.get $block
          return
        end

        local.get $steps
        i32.const 1
        i32.add
        local.set $steps
        br $lp
      end
    end

    ;; No hit
    i32.const 0
    global.set $g_hit_face
    f64.const 999.0
    global.set $g_hit_dist
    i32.const 0
    global.set $g_hit_vx
    i32.const 0
    global.set $g_hit_vy
    i32.const 0
    global.set $g_hit_vz
    i32.const 0
  )

  ;; ============================================================
  ;; PROCEDURAL TEXTURES
  ;; ============================================================
  (func $texture_offset (param $type i32) (param $face i32)
        (param $vx i32) (param $vy i32) (param $vz i32)
        (param $fu i32) (param $fv i32) (result i32)
    (local $h i32) (local $h2 i32) (local $h3 i32)
    (local $result i32)
    ;; Base hash combining voxel + UV
    local.get $vx
    local.get $fu
    i32.const 37
    i32.mul
    i32.add
    local.get $vy
    local.get $fv
    i32.const 53
    i32.mul
    i32.add
    local.get $vz
    call $hash3d
    i32.const 255
    i32.and
    local.set $h
    ;; Per-block-position hash for variation
    local.get $vx
    local.get $vy
    local.get $vz
    call $hash3d
    i32.const 255
    i32.and
    local.set $h2

    ;; Grass (type 1)
    local.get $type
    i32.const 1
    i32.eq
    if
      local.get $face
      i32.const 0
      i32.eq
      if
        ;; Top face: grass blades pattern
        local.get $fu
        local.get $vx
        local.get $vy
        i32.const 17
        i32.mul
        i32.add
        i32.const 0
        call $hash3d
        i32.const 15
        i32.and
        local.set $h3
        local.get $h3
        i32.const 3
        i32.lt_u
        if
          i32.const -1
          return
        end
        local.get $h3
        i32.const 12
        i32.gt_u
        if
          i32.const 1
          return
        end
        local.get $h
        i32.const 12
        i32.lt_u
        local.get $h2
        i32.const 40
        i32.lt_u
        i32.and
        if
          i32.const 2
          return
        end
        i32.const 0
        return
      else
        ;; Side face: dirt showing through with grass line at top
        local.get $fv
        i32.const 0
        i32.eq
        if
          i32.const 1
          return
        end
        local.get $h
        i32.const 60
        i32.lt_u
        if
          i32.const -1
          return
        end
        i32.const 0
        return
      end
    end

    ;; Dirt (type 2)
    local.get $type
    i32.const 2
    i32.eq
    if
      local.get $h
      i32.const 30
      i32.lt_u
      if
        i32.const -1
        return
      end
      local.get $h
      i32.const 230
      i32.gt_u
      if
        i32.const 1
        return
      end
      local.get $fu
      local.get $vx
      i32.const 7
      i32.mul
      i32.add
      local.get $fv
      local.get $vz
      call $hash3d
      i32.const 31
      i32.and
      local.set $h3
      local.get $h3
      i32.eqz
      if
        i32.const -2
        return
      end
      i32.const 0
      return
    end

    ;; Stone (type 3)
    local.get $type
    i32.const 3
    i32.eq
    if
      local.get $fu
      local.get $vx
      i32.const 13
      i32.mul
      i32.add
      local.get $fv
      local.get $vy
      i32.const 19
      i32.mul
      i32.add
      local.get $vz
      call $hash3d
      i32.const 63
      i32.and
      local.set $h3
      local.get $h3
      i32.const 3
      i32.lt_u
      if
        i32.const -2
        return
      end
      local.get $h
      i32.const 40
      i32.lt_u
      if
        i32.const -1
        return
      end
      local.get $h
      i32.const 220
      i32.gt_u
      if
        i32.const 1
        return
      end
      i32.const 0
      return
    end

    ;; Sand (type 4)
    local.get $type
    i32.const 4
    i32.eq
    if
      local.get $h
      i32.const 3
      i32.and
      i32.const 1
      i32.sub
      local.set $result
      local.get $result
      return
    end

    ;; Wood (type 6)
    local.get $type
    i32.const 6
    i32.eq
    if
      local.get $face
      i32.const 0
      i32.eq
      if
        ;; Top/bottom: ring pattern
        local.get $fu
        i32.const 4
        i32.sub
        local.get $fu
        i32.const 4
        i32.sub
        i32.mul
        local.get $fv
        i32.const 4
        i32.sub
        local.get $fv
        i32.const 4
        i32.sub
        i32.mul
        i32.add
        i32.const 3
        i32.and
        local.set $h3
        local.get $h3
        i32.const 1
        i32.sub
        return
      else
        ;; Side: vertical grain lines
        local.get $fu
        local.get $vx
        local.get $vy
        i32.add
        i32.const 6
        call $hash3d
        i32.const 7
        i32.and
        local.set $h3
        local.get $h3
        i32.const 2
        i32.lt_u
        if
          i32.const -1
          return
        end
        i32.const 0
        return
      end
    end

    ;; Leaves (type 7)
    local.get $type
    i32.const 7
    i32.eq
    if
      local.get $h
      i32.const 25
      i32.lt_u
      if
        i32.const -2
        return
      end
      local.get $h
      i32.const 200
      i32.gt_u
      if
        i32.const 1
        return
      end
      i32.const 0
      return
    end

    ;; Coal (type 8)
    local.get $type
    i32.const 8
    i32.eq
    if
      local.get $fu
      local.get $vx
      i32.const 11
      i32.mul
      i32.add
      local.get $fv
      local.get $vy
      i32.const 23
      i32.mul
      i32.add
      local.get $vz
      i32.const 7
      i32.mul
      call $hash3d
      i32.const 15
      i32.and
      local.set $h3
      local.get $h3
      i32.const 4
      i32.lt_u
      if
        i32.const -2
        return
      end
      local.get $h
      i32.const 200
      i32.gt_u
      if
        i32.const 1
        return
      end
      i32.const 0
      return
    end

    ;; Default
    i32.const 0
  )

  ;; ============================================================
  ;; RGB24 to RGBL with ordered dithering
  ;; Takes pixel coords (px,py) and 24-bit RGB (r,g,b each 0-255)
  ;; Returns RGBL palette index = (R<<6)|(G<<4)|(B<<2)|L
  ;; ============================================================
  (func $rgb_to_rgbl_dither (param $px i32) (param $py i32) (param $r i32) (param $g i32) (param $b i32) (result i32)
    (local $bx i32) (local $by i32) (local $idx i32) (local $threshold i32)
    (local $max_c i32) (local $best_l i32) (local $bright i32)
    (local $ri i32) (local $gi i32) (local $bi i32)
    (local $rf i32) (local $gf i32) (local $bf i32)
    (local $scaled i32)
    ;; Compute Bayer threshold (0-15)
    local.get $px
    i32.const 3
    i32.and
    local.set $bx
    local.get $py
    i32.const 3
    i32.and
    local.set $by
    local.get $by
    i32.const 4
    i32.mul
    local.get $bx
    i32.add
    local.set $idx
    ;; Bayer 4x4 matrix lookup
    i32.const 0
    local.set $threshold
    local.get $idx
    i32.const 0
    i32.eq
    if  i32.const 0  local.set $threshold  end
    local.get $idx
    i32.const 1
    i32.eq
    if  i32.const 8  local.set $threshold  end
    local.get $idx
    i32.const 2
    i32.eq
    if  i32.const 2  local.set $threshold  end
    local.get $idx
    i32.const 3
    i32.eq
    if  i32.const 10  local.set $threshold  end
    local.get $idx
    i32.const 4
    i32.eq
    if  i32.const 12  local.set $threshold  end
    local.get $idx
    i32.const 5
    i32.eq
    if  i32.const 4  local.set $threshold  end
    local.get $idx
    i32.const 6
    i32.eq
    if  i32.const 14  local.set $threshold  end
    local.get $idx
    i32.const 7
    i32.eq
    if  i32.const 6  local.set $threshold  end
    local.get $idx
    i32.const 8
    i32.eq
    if  i32.const 3  local.set $threshold  end
    local.get $idx
    i32.const 9
    i32.eq
    if  i32.const 11  local.set $threshold  end
    local.get $idx
    i32.const 10
    i32.eq
    if  i32.const 1  local.set $threshold  end
    local.get $idx
    i32.const 11
    i32.eq
    if  i32.const 9  local.set $threshold  end
    local.get $idx
    i32.const 12
    i32.eq
    if  i32.const 15  local.set $threshold  end
    local.get $idx
    i32.const 13
    i32.eq
    if  i32.const 7  local.set $threshold  end
    local.get $idx
    i32.const 14
    i32.eq
    if  i32.const 13  local.set $threshold  end
    local.get $idx
    i32.const 15
    i32.eq
    if  i32.const 5  local.set $threshold  end

    ;; Clamp inputs to 0-255
    local.get $r
    i32.const 0
    i32.lt_s
    if  i32.const 0  local.set $r  end
    local.get $r
    i32.const 255
    i32.gt_s
    if  i32.const 255  local.set $r  end
    local.get $g
    i32.const 0
    i32.lt_s
    if  i32.const 0  local.set $g  end
    local.get $g
    i32.const 255
    i32.gt_s
    if  i32.const 255  local.set $g  end
    local.get $b
    i32.const 0
    i32.lt_s
    if  i32.const 0  local.set $b  end
    local.get $b
    i32.const 255
    i32.gt_s
    if  i32.const 255  local.set $b  end

    ;; Find max channel
    local.get $r
    local.set $max_c
    local.get $g
    local.get $max_c
    i32.gt_s
    if  local.get $g  local.set $max_c  end
    local.get $b
    local.get $max_c
    i32.gt_s
    if  local.get $b  local.set $max_c  end

    ;; Choose brightness level L based on max channel
    ;; Brightness thresholds: L0=33, L1=102, L2=179, L3=255
    ;; Choose L such that max_c fits within chan[3]*bright[L]/255 = bright[L]
    ;; L0 handles max_c 0..33, L1 handles 0..102, L2 handles 0..179, L3 handles 0..255
    ;; Pick smallest L where bright[L] >= max_c (so channels have room)
    ;; But also dither between L levels for smoother gradients
    i32.const 3
    local.set $best_l
    local.get $max_c
    i32.const 180
    i32.lt_s
    if  i32.const 2  local.set $best_l  end
    local.get $max_c
    i32.const 103
    i32.lt_s
    if  i32.const 1  local.set $best_l  end
    local.get $max_c
    i32.const 34
    i32.lt_s
    if  i32.const 0  local.set $best_l  end

    ;; Get brightness value for chosen L
    ;; bright[0]=33, bright[1]=102, bright[2]=179, bright[3]=255
    i32.const 0x19604
    local.get $best_l
    i32.add
    i32.load8_u
    local.set $bright

    ;; Avoid division by zero
    local.get $bright
    i32.const 1
    i32.lt_s
    if  i32.const 1  local.set $bright  end

    ;; Scale each channel: mapped = ch * 3 * 255 / (bright * 85)
    ;; This maps to 0..765 range, then we quantize to 0..3 with dithering
    ;; Simplified: mapped = ch * 3 / bright (approximately)
    ;; More precisely: we want idx such that idx * 85 * bright / 255 ≈ ch
    ;; So idx_full = ch * 255 / (85 * bright) * 16 for 4-bit precision
    ;; idx_int = idx_full >> 4, idx_frac = idx_full & 15

    ;; Red: scaled = r * 48 / bright (maps 0-255 to 0-48, where 0,16,32,48 = levels 0-3)
    local.get $r
    i32.const 48
    i32.mul
    local.get $bright
    i32.div_u
    local.set $scaled
    local.get $scaled
    i32.const 48
    i32.gt_s
    if  i32.const 48  local.set $scaled  end
    local.get $scaled
    i32.const 4
    i32.shr_u
    local.set $ri
    local.get $scaled
    i32.const 15
    i32.and
    local.set $rf
    ;; Dither: if fractional > threshold, bump up
    local.get $rf
    local.get $threshold
    i32.gt_u
    if
      local.get $ri
      i32.const 1
      i32.add
      local.set $ri
    end
    local.get $ri
    i32.const 3
    i32.gt_s
    if  i32.const 3  local.set $ri  end

    ;; Green
    local.get $g
    i32.const 48
    i32.mul
    local.get $bright
    i32.div_u
    local.set $scaled
    local.get $scaled
    i32.const 48
    i32.gt_s
    if  i32.const 48  local.set $scaled  end
    local.get $scaled
    i32.const 4
    i32.shr_u
    local.set $gi
    local.get $scaled
    i32.const 15
    i32.and
    local.set $gf
    local.get $gf
    local.get $threshold
    i32.gt_u
    if
      local.get $gi
      i32.const 1
      i32.add
      local.set $gi
    end
    local.get $gi
    i32.const 3
    i32.gt_s
    if  i32.const 3  local.set $gi  end

    ;; Blue
    local.get $b
    i32.const 48
    i32.mul
    local.get $bright
    i32.div_u
    local.set $scaled
    local.get $scaled
    i32.const 48
    i32.gt_s
    if  i32.const 48  local.set $scaled  end
    local.get $scaled
    i32.const 4
    i32.shr_u
    local.set $bi
    local.get $scaled
    i32.const 15
    i32.and
    local.set $bf
    local.get $bf
    local.get $threshold
    i32.gt_u
    if
      local.get $bi
      i32.const 1
      i32.add
      local.set $bi
    end
    local.get $bi
    i32.const 3
    i32.gt_s
    if  i32.const 3  local.set $bi  end

    ;; Compose RGBL index
    local.get $ri
    i32.const 6
    i32.shl
    local.get $gi
    i32.const 4
    i32.shl
    i32.or
    local.get $bi
    i32.const 2
    i32.shl
    i32.or
    local.get $best_l
    i32.or
  )

  ;; ============================================================
  ;; ORDERED DITHERING — 4x4 Bayer matrix
  ;; ============================================================
  (func $dither_test (param $px i32) (param $py i32) (param $frac i32) (result i32)
    (local $bx i32) (local $by i32) (local $threshold i32) (local $idx i32)
    local.get $px
    i32.const 3
    i32.and
    local.set $bx
    local.get $py
    i32.const 3
    i32.and
    local.set $by
    local.get $by
    i32.const 4
    i32.mul
    local.get $bx
    i32.add
    local.set $idx
    i32.const 0
    local.set $threshold
    local.get $idx
    i32.const 0
    i32.eq
    if  i32.const 0  local.set $threshold  end
    local.get $idx
    i32.const 1
    i32.eq
    if  i32.const 8  local.set $threshold  end
    local.get $idx
    i32.const 2
    i32.eq
    if  i32.const 2  local.set $threshold  end
    local.get $idx
    i32.const 3
    i32.eq
    if  i32.const 10  local.set $threshold  end
    local.get $idx
    i32.const 4
    i32.eq
    if  i32.const 12  local.set $threshold  end
    local.get $idx
    i32.const 5
    i32.eq
    if  i32.const 4  local.set $threshold  end
    local.get $idx
    i32.const 6
    i32.eq
    if  i32.const 14  local.set $threshold  end
    local.get $idx
    i32.const 7
    i32.eq
    if  i32.const 6  local.set $threshold  end
    local.get $idx
    i32.const 8
    i32.eq
    if  i32.const 3  local.set $threshold  end
    local.get $idx
    i32.const 9
    i32.eq
    if  i32.const 11  local.set $threshold  end
    local.get $idx
    i32.const 10
    i32.eq
    if  i32.const 1  local.set $threshold  end
    local.get $idx
    i32.const 11
    i32.eq
    if  i32.const 9  local.set $threshold  end
    local.get $idx
    i32.const 12
    i32.eq
    if  i32.const 15  local.set $threshold  end
    local.get $idx
    i32.const 13
    i32.eq
    if  i32.const 7  local.set $threshold  end
    local.get $idx
    i32.const 14
    i32.eq
    if  i32.const 13  local.set $threshold  end
    local.get $idx
    i32.const 15
    i32.eq
    if  i32.const 5  local.set $threshold  end
    local.get $frac
    local.get $threshold
    i32.gt_u
    if
      i32.const 1
      return
    end
    i32.const 0
  )

  ;; ============================================================
  ;; FRAME — Per-pixel voxel raytracer
  ;; ============================================================
  (func (export "frame")
    (local $px_col i32) (local $px_row i32) (local $tick i32) (local $keys i32)
    (local $px f64) (local $py f64) (local $pz f64) (local $angle f64)
    (local $cos_a_v f64) (local $sin_a_v f64)
    (local $move_x f64) (local $move_y f64) (local $speed f64)
    (local $mouse_btn i32) (local $prev_mouse i32)
    (local $mouse_x i32) (local $mouse_y i32) (local $look_y i32)
    (local $msg_timer i32) (local $dig_cd i32)
    (local $vz f64) (local $on_ground i32) (local $ground_h i32)
    (local $bob f64) (local $bob_phase f64)
    (local $new_px f64) (local $new_py f64)
    (local $check_x i32) (local $check_y i32) (local $check_h i32)
    (local $frame_ct i32)
    (local $screen_u f64) (local $screen_v f64)
    (local $ray_dx f64) (local $ray_dy f64) (local $ray_dz f64)
    (local $fwd_x f64) (local $fwd_y f64) (local $fwd_z f64)
    (local $right_x f64) (local $right_y f64)
    (local $up_x f64) (local $up_y f64) (local $up_z f64)
    (local $pitch f64)
    (local $cos_pitch f64) (local $sin_pitch f64)
    (local $hit_type i32) (local $face i32) (local $dist f64)
    (local $shade i32) (local $color i32)
    (local $fb_addr i32)
    (local $sky_idx i32)
    (local $len f64)
    (local $hit_vx i32) (local $hit_vy i32) (local $hit_vz i32)
    (local $hit_px f64) (local $hit_py f64) (local $hit_pz f64)
    (local $tex_u i32) (local $tex_v i32)
    (local $tex_off i32)
    (local $shade_full i32) (local $shade_frac i32)
    (local $dither_bump i32)
    (local $i i32) (local $m_addr i32) (local $m_active i32)
    (local $m_type i32) (local $m_wx f64) (local $m_wy f64)
    (local $dx f64) (local $dy f64) (local $m_dist f64)
    (local $day_tick i32) (local $day_phase i32) (local $day_bright i32)
    (local $sky_r i32) (local $sky_g i32) (local $sky_b i32)
    (local $sun_sx i32) (local $sun_sy i32) (local $sun_screen_x i32) (local $sun_screen_y i32)
    (local $sun_dx i32) (local $sun_dy i32) (local $sun_r2 i32)
    (local $game_hour i32) (local $game_min i32)
    (local $cel_dir_x f64) (local $cel_dir_y f64) (local $cel_dir_z f64)
    (local $cel_active i32) (local $cel_is_sun i32)
    (local $cel_angle f64) (local $cel_dot f64)

    i32.const 12
    i32.load
    local.set $tick
    i32.const 0
    i32.load
    local.set $frame_ct
    i32.const 0x10
    i32.load8_u
    local.set $keys
    i32.const 0x08
    i32.load8_u
    local.set $mouse_btn
    i32.const 0x103A4
    i32.load
    local.set $prev_mouse

    ;; Load player
    i32.const 0x10344
    f64.load
    local.set $px
    i32.const 0x1034C
    f64.load
    local.set $py
    i32.const 0x10354
    f64.load
    local.set $angle
    i32.const 0x1035C
    f64.load
    local.set $pz
    i32.const 0x10364
    f64.load
    local.set $vz
    i32.const 0x1036C
    i32.load
    local.set $on_ground
    i32.const 0x10374
    f64.load
    local.set $bob_phase
    i32.const 0x103AC
    i32.load
    local.set $look_y

    ;; ---- Mouse X → yaw ----
    i32.const 0x04
    i32.load8_u
    i32.const 0x05
    i32.load8_u
    i32.const 8
    i32.shl
    i32.or
    local.set $mouse_x
    local.get $angle
    local.get $mouse_x
    f64.convert_i32_s
    f64.const 160.0
    f64.sub
    f64.const 0.0002
    f64.mul
    f64.sub
    local.set $angle

    ;; ---- Mouse Y → look pitch ----
    i32.const 0x06
    i32.load8_u
    i32.const 0x07
    i32.load8_u
    i32.const 8
    i32.shl
    i32.or
    local.set $mouse_y
    local.get $mouse_y
    f64.convert_i32_s
    f64.const 100.0
    f64.sub
    f64.const -0.6
    f64.mul
    i32.trunc_f64_s
    local.set $look_y
    local.get $look_y
    i32.const -60
    i32.lt_s
    if
      i32.const -60
      local.set $look_y
    end
    local.get $look_y
    i32.const 60
    i32.gt_s
    if
      i32.const 60
      local.set $look_y
    end
    i32.const 0x103AC
    local.get $look_y
    i32.store

    ;; ---- Input ----
    f64.const 0.06
    local.set $speed
    ;; Turn left
    local.get $keys
    i32.const 4
    i32.and
    if
      local.get $angle
      f64.const 0.04
      f64.sub
      local.set $angle
    end
    ;; Turn right
    local.get $keys
    i32.const 8
    i32.and
    if
      local.get $angle
      f64.const 0.04
      f64.add
      local.set $angle
    end

    local.get $angle
    call $cos_a
    local.set $cos_a_v
    local.get $angle
    call $sin_a
    local.set $sin_a_v

    f64.const 0.0
    local.set $move_x
    f64.const 0.0
    local.set $move_y
    ;; Forward
    local.get $keys
    i32.const 1
    i32.and
    if
      local.get $move_x
      local.get $cos_a_v
      local.get $speed
      f64.mul
      f64.add
      local.set $move_x
      local.get $move_y
      local.get $sin_a_v
      local.get $speed
      f64.mul
      f64.add
      local.set $move_y
    end
    ;; Backward
    local.get $keys
    i32.const 2
    i32.and
    if
      local.get $move_x
      local.get $cos_a_v
      local.get $speed
      f64.mul
      f64.sub
      local.set $move_x
      local.get $move_y
      local.get $sin_a_v
      local.get $speed
      f64.mul
      f64.sub
      local.set $move_y
    end

    ;; Collision check
    local.get $px
    local.get $move_x
    f64.add
    local.set $new_px
    local.get $py
    local.get $move_y
    f64.add
    local.set $new_py
    local.get $new_px
    f64.floor
    i32.trunc_f64_s
    local.set $check_x
    local.get $new_py
    f64.floor
    i32.trunc_f64_s
    local.set $check_y
    local.get $check_x
    local.get $check_y
    call $terrain_height
    local.set $check_h
    local.get $check_h
    local.get $pz
    i32.trunc_f64_s
    i32.const 1
    i32.add
    i32.le_s
    if
      local.get $new_px
      local.set $px
      local.get $new_py
      local.set $py
    end

    ;; Gravity
    local.get $px
    f64.floor
    i32.trunc_f64_s
    local.get $py
    f64.floor
    i32.trunc_f64_s
    call $terrain_height
    local.set $ground_h
    local.get $vz
    f64.const 0.015
    f64.sub
    local.set $vz
    local.get $pz
    local.get $vz
    f64.add
    local.set $pz
    local.get $pz
    local.get $ground_h
    f64.convert_i32_s
    f64.const 1.7
    f64.add
    f64.le
    if
      local.get $ground_h
      f64.convert_i32_s
      f64.const 1.7
      f64.add
      local.set $pz
      f64.const 0.0
      local.set $vz
      i32.const 1
      local.set $on_ground
    else
      i32.const 0
      local.set $on_ground
    end

    ;; Jump
    local.get $keys
    i32.const 16
    i32.and
    local.get $on_ground
    i32.and
    if
      f64.const 0.18
      local.set $vz
    end

    ;; Head bob
    local.get $on_ground
    local.get $keys
    i32.const 1
    i32.and
    local.get $keys
    i32.const 2
    i32.and
    i32.or
    i32.and
    if
      local.get $bob_phase
      f64.const 0.15
      f64.add
      local.set $bob_phase
      local.get $bob_phase
      call $sin_a
      f64.const 0.08
      f64.mul
      local.set $bob
    else
      f64.const 0.0
      local.set $bob
    end

    ;; Digging
    i32.const 0x103A0
    i32.load
    local.set $dig_cd
    local.get $dig_cd
    i32.const 0
    i32.gt_s
    if
      i32.const 0x103A0
      local.get $dig_cd
      i32.const 1
      i32.sub
      i32.store
    end
    local.get $mouse_btn
    i32.const 1
    i32.and
    local.get $prev_mouse
    i32.const 1
    i32.and
    i32.eqz
    i32.and
    if
      i32.const 0x103A0
      i32.load
      i32.eqz
      if
        local.get $px
        local.get $py
        local.get $pz
        local.get $angle
        local.get $keys
        i32.const 128
        i32.and
        call $dig_or_place
        i32.const 0x103A0
        i32.const 10
        i32.store
      end
    end
    i32.const 0x103A4
    i32.const 0x08
    i32.load8_u
    i32.store

    ;; Store player
    i32.const 0x10344
    local.get $px
    f64.store
    i32.const 0x1034C
    local.get $py
    f64.store
    i32.const 0x10354
    local.get $angle
    f64.store
    i32.const 0x1035C
    local.get $pz
    f64.store
    i32.const 0x10364
    local.get $vz
    f64.store
    i32.const 0x1036C
    local.get $on_ground
    i32.store
    i32.const 0x10374
    local.get $bob_phase
    f64.store

    ;; ============================================================
    ;; DAY/NIGHT CYCLE
    ;; ============================================================
    local.get $tick
    i32.const 120000
    i32.rem_u
    local.set $day_tick
    local.get $day_tick
    i32.const 256
    i32.mul
    i32.const 120000
    i32.div_u
    local.set $day_phase

    ;; Compute game time
    local.get $day_tick
    i32.const 24
    i32.mul
    i32.const 120000
    i32.div_u
    local.set $game_hour
    local.get $day_tick
    i32.const 1440
    i32.mul
    i32.const 120000
    i32.div_u
    i32.const 60
    i32.rem_u
    local.set $game_min

    ;; Brightness curve
    local.get $day_phase
    i32.const 48
    i32.lt_u
    if
      i32.const 0
      local.set $day_bright
    else
      local.get $day_phase
      i32.const 80
      i32.lt_u
      if
        local.get $day_phase
        i32.const 48
        i32.sub
        i32.const 255
        i32.mul
        i32.const 32
        i32.div_u
        local.set $day_bright
      else
        local.get $day_phase
        i32.const 176
        i32.lt_u
        if
          i32.const 255
          local.set $day_bright
        else
          local.get $day_phase
          i32.const 208
          i32.lt_u
          if
            i32.const 208
            local.get $day_phase
            i32.sub
            i32.const 255
            i32.mul
            i32.const 32
            i32.div_u
            local.set $day_bright
          else
            i32.const 0
            local.set $day_bright
          end
        end
      end
    end

    ;; Update sky palette: 4 brightness levels of sky blue (0x5C..0x5F)
    ;; Sky at full day: R=85, G=170, B=255
    ;; Brightness scales: L0=33/255, L1=102/255, L2=179/255, L3=255/255
    ;; Each sky palette entry: R = 85*scale*day_bright/65025, etc.

    ;; L=0: scale=33
    i32.const 85
    i32.const 33
    i32.mul
    local.get $day_bright
    i32.mul
    i32.const 65025
    i32.div_u
    local.set $sky_r
    i32.const 170
    i32.const 33
    i32.mul
    local.get $day_bright
    i32.mul
    i32.const 65025
    i32.div_u
    local.set $sky_g
    i32.const 255
    i32.const 33
    i32.mul
    local.get $day_bright
    i32.mul
    i32.const 65025
    i32.div_u
    local.set $sky_b
    i32.const 0x5C
    local.get $sky_r
    local.get $sky_g
    local.get $sky_b
    call $set_pal

    ;; L=1: scale=102
    i32.const 85
    i32.const 102
    i32.mul
    local.get $day_bright
    i32.mul
    i32.const 65025
    i32.div_u
    local.set $sky_r
    i32.const 170
    i32.const 102
    i32.mul
    local.get $day_bright
    i32.mul
    i32.const 65025
    i32.div_u
    local.set $sky_g
    i32.const 255
    i32.const 102
    i32.mul
    local.get $day_bright
    i32.mul
    i32.const 65025
    i32.div_u
    local.set $sky_b
    i32.const 0x5D
    local.get $sky_r
    local.get $sky_g
    local.get $sky_b
    call $set_pal

    ;; L=2: scale=179
    i32.const 85
    i32.const 179
    i32.mul
    local.get $day_bright
    i32.mul
    i32.const 65025
    i32.div_u
    local.set $sky_r
    i32.const 170
    i32.const 179
    i32.mul
    local.get $day_bright
    i32.mul
    i32.const 65025
    i32.div_u
    local.set $sky_g
    i32.const 255
    i32.const 179
    i32.mul
    local.get $day_bright
    i32.mul
    i32.const 65025
    i32.div_u
    local.set $sky_b
    i32.const 0x5E
    local.get $sky_r
    local.get $sky_g
    local.get $sky_b
    call $set_pal

    ;; L=3: scale=255
    i32.const 85
    local.get $day_bright
    i32.mul
    i32.const 255
    i32.div_u
    local.set $sky_r
    i32.const 170
    local.get $day_bright
    i32.mul
    i32.const 255
    i32.div_u
    local.set $sky_g
    local.get $day_bright
    local.set $sky_b
    i32.const 0x5F
    local.get $sky_r
    local.get $sky_g
    local.get $sky_b
    call $set_pal

    ;; ---- Update monsters (AI) ----
    i32.const 0
    local.set $i
    block $mob_done
      loop $mob_lp
        local.get $i
        i32.const 24
        i32.ge_u
        br_if $mob_done
        i32.const 0x10900
        local.get $i
        i32.const 32
        i32.mul
        i32.add
        local.set $m_addr
        local.get $m_addr
        i32.load
        local.set $m_active
        local.get $m_active
        if
          ;; Monster type at offset +4 (0=creep,1=zombie,2=skeleton)
          ;; Monster base from table at 0x1950C
          local.get $m_addr
          i32.const 4
          i32.add
          i32.load
          local.set $m_type
          local.get $m_addr
          i32.const 8
          i32.add
          f64.load
          local.set $m_wx
          local.get $m_addr
          i32.const 16
          i32.add
          f64.load
          local.set $m_wy
          local.get $px
          local.get $m_wx
          f64.sub
          local.set $dx
          local.get $py
          local.get $m_wy
          f64.sub
          local.set $dy
          local.get $dx
          local.get $dx
          f64.mul
          local.get $dy
          local.get $dy
          f64.mul
          f64.add
          f64.sqrt
          local.set $m_dist
          local.get $m_dist
          f64.const 3.0
          f64.gt
          if
            local.get $m_addr
            i32.const 8
            i32.add
            local.get $m_wx
            local.get $dx
            local.get $m_dist
            f64.div
            f64.const 0.01
            f64.mul
            f64.add
            f64.store
            local.get $m_addr
            i32.const 16
            i32.add
            local.get $m_wy
            local.get $dy
            local.get $m_dist
            f64.div
            f64.const 0.01
            f64.mul
            f64.add
            f64.store
          end
          local.get $m_addr
          i32.const 28
          i32.add
          local.get $m_addr
          i32.const 28
          i32.add
          i32.load
          i32.const 1
          i32.add
          i32.store
        end
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $mob_lp
      end
    end

    ;; ============================================================
    ;; COMPUTE SUN/MOON 3D WORLD DIRECTION
    ;; ============================================================
    i32.const 0
    local.set $cel_active

    ;; Sun: visible when day_phase 48..208
    local.get $day_phase
    i32.const 48
    i32.ge_u
    local.get $day_phase
    i32.const 208
    i32.lt_u
    i32.and
    if
      i32.const 1
      local.set $cel_active
      i32.const 1
      local.set $cel_is_sun
      local.get $day_phase
      i32.const 48
      i32.sub
      f64.convert_i32_u
      f64.const 160.0
      f64.div
      f64.const 3.14159265358979
      f64.mul
      local.set $cel_angle
      local.get $cel_angle
      call $cos_a
      local.set $cel_dir_x
      f64.const 0.0
      local.set $cel_dir_y
      local.get $cel_angle
      call $sin_a
      local.set $cel_dir_z
    end

    ;; Moon: visible when day_phase 0..48 or 208..255
    local.get $day_phase
    i32.const 48
    i32.lt_u
    local.get $day_phase
    i32.const 208
    i32.ge_u
    i32.or
    if
      i32.const 1
      local.set $cel_active
      i32.const 0
      local.set $cel_is_sun
      local.get $day_phase
      i32.const 48
      i32.lt_u
      if
        local.get $day_phase
        i32.const 48
        i32.add
        f64.convert_i32_u
        local.set $cel_angle
      else
        local.get $day_phase
        i32.const 208
        i32.sub
        f64.convert_i32_u
        local.set $cel_angle
      end
      local.get $cel_angle
      f64.const 96.0
      f64.div
      f64.const 3.14159265358979
      f64.mul
      local.set $cel_angle
      local.get $cel_angle
      call $cos_a
      local.set $cel_dir_x
      f64.const 0.0
      local.set $cel_dir_y
      local.get $cel_angle
      call $sin_a
      local.set $cel_dir_z
    end

    ;; ============================================================
    ;; PER-PIXEL RAYTRACING
    ;; ============================================================
    local.get $look_y
    f64.convert_i32_s
    f64.const 0.015
    f64.mul
    local.set $pitch

    local.get $pitch
    call $cos_a
    local.set $cos_pitch
    local.get $pitch
    call $sin_a
    local.set $sin_pitch

    ;; Forward direction
    local.get $cos_a_v
    local.get $cos_pitch
    f64.mul
    local.set $fwd_x
    local.get $sin_a_v
    local.get $cos_pitch
    f64.mul
    local.set $fwd_y
    local.get $sin_pitch
    local.set $fwd_z

    ;; Right
    local.get $sin_a_v
    local.set $right_x
    local.get $cos_a_v
    f64.neg
    local.set $right_y

    ;; Up
    local.get $cos_a_v
    local.get $sin_pitch
    f64.mul
    f64.neg
    local.set $up_x
    local.get $sin_a_v
    local.get $sin_pitch
    f64.mul
    f64.neg
    local.set $up_y
    local.get $cos_pitch
    local.set $up_z

    i32.const 0
    local.set $px_row
    block $row_done
      loop $row_lp
        local.get $px_row
        i32.const 200
        i32.ge_s
        br_if $row_done

        ;; screen_v
        f64.const 0.5
        local.get $px_row
        f64.convert_i32_s
        f64.const 200.0
        f64.div
        f64.sub
        f64.const 1.25
        f64.mul
        local.set $screen_v

        i32.const 0
        local.set $px_col
        block $col_done
          loop $col_lp
            local.get $px_col
            i32.const 320
            i32.ge_s
            br_if $col_done

            ;; screen_u
            local.get $px_col
            f64.convert_i32_s
            f64.const 160.0
            f64.div
            f64.const 1.0
            f64.sub
            local.set $screen_u

            ;; Ray direction = fwd * 1.6 + right * screen_u + up * screen_v
            local.get $fwd_x
            f64.const 1.6
            f64.mul
            local.get $right_x
            local.get $screen_u
            f64.mul
            f64.add
            local.get $up_x
            local.get $screen_v
            f64.mul
            f64.add
            local.set $ray_dx
            local.get $fwd_y
            f64.const 1.6
            f64.mul
            local.get $right_y
            local.get $screen_u
            f64.mul
            f64.add
            local.get $up_y
            local.get $screen_v
            f64.mul
            f64.add
            local.set $ray_dy
            local.get $fwd_z
            f64.const 1.6
            f64.mul
            local.get $up_z
            local.get $screen_v
            f64.mul
            f64.add
            local.set $ray_dz

            ;; Normalize ray direction
            local.get $ray_dx
            local.get $ray_dx
            f64.mul
            local.get $ray_dy
            local.get $ray_dy
            f64.mul
            f64.add
            local.get $ray_dz
            local.get $ray_dz
            f64.mul
            f64.add
            f64.sqrt
            local.set $len
            local.get $len
            f64.const 0.001
            f64.gt
            if
              local.get $ray_dx
              local.get $len
              f64.div
              local.set $ray_dx
              local.get $ray_dy
              local.get $len
              f64.div
              local.set $ray_dy
              local.get $ray_dz
              local.get $len
              f64.div
              local.set $ray_dz
            end

            ;; Cast ray
            local.get $px
            local.get $py
            local.get $pz
            local.get $bob
            f64.add
            local.get $ray_dx
            local.get $ray_dy
            local.get $ray_dz
            call $cast_ray
            local.set $hit_type

            global.get $g_hit_face
            local.set $face
            global.get $g_hit_dist
            local.set $dist
            global.get $g_hit_vx
            local.set $hit_vx
            global.get $g_hit_vy
            local.set $hit_vy
            global.get $g_hit_vz
            local.set $hit_vz

            i32.const 0x0340
            local.get $px_row
            i32.const 320
            i32.mul
            local.get $px_col
            i32.add
            i32.add
            local.set $fb_addr

            local.get $hit_type
            i32.const 0
            i32.ne
            if
              ;; Compute hit point for texture UV
              local.get $px
              local.get $ray_dx
              local.get $dist
              f64.mul
              f64.add
              local.set $hit_px
              local.get $py
              local.get $ray_dy
              local.get $dist
              f64.mul
              f64.add
              local.set $hit_py
              local.get $pz
              local.get $bob
              f64.add
              local.get $ray_dz
              local.get $dist
              f64.mul
              f64.add
              local.set $hit_pz

              ;; Compute texture UV based on face
              local.get $face
              i32.const 0
              i32.eq
              local.get $face
              i32.const 3
              i32.eq
              i32.or
              if
                ;; Top/bottom face
                local.get $hit_px
                local.get $hit_px
                f64.floor
                f64.sub
                f64.const 8.0
                f64.mul
                i32.trunc_f64_s
                i32.const 7
                i32.and
                local.set $tex_u
                local.get $hit_py
                local.get $hit_py
                f64.floor
                f64.sub
                f64.const 8.0
                f64.mul
                i32.trunc_f64_s
                i32.const 7
                i32.and
                local.set $tex_v
              end
              local.get $face
              i32.const 1
              i32.eq
              if
                ;; Side bright face
                local.get $hit_px
                local.get $hit_px
                f64.floor
                f64.sub
                f64.const 8.0
                f64.mul
                i32.trunc_f64_s
                i32.const 7
                i32.and
                local.set $tex_u
                f64.const 1.0
                local.get $hit_pz
                local.get $hit_pz
                f64.floor
                f64.sub
                f64.sub
                f64.const 8.0
                f64.mul
                i32.trunc_f64_s
                i32.const 7
                i32.and
                local.set $tex_v
              end
              local.get $face
              i32.const 2
              i32.eq
              if
                ;; Side dim face
                local.get $hit_py
                local.get $hit_py
                f64.floor
                f64.sub
                f64.const 8.0
                f64.mul
                i32.trunc_f64_s
                i32.const 7
                i32.and
                local.set $tex_u
                f64.const 1.0
                local.get $hit_pz
                local.get $hit_pz
                f64.floor
                f64.sub
                f64.sub
                f64.const 8.0
                f64.mul
                i32.trunc_f64_s
                i32.const 7
                i32.and
                local.set $tex_v
              end

              ;; Distance-based shade (extended for octree range)
              i32.const 240
              local.get $dist
              f64.const 2.5
              f64.mul
              i32.trunc_f64_s
              i32.sub
              local.set $shade_full
              local.get $shade_full
              i32.const 0
              i32.lt_s
              if  i32.const 0  local.set $shade_full  end
              local.get $shade_full
              i32.const 255
              i32.gt_s
              if  i32.const 255  local.set $shade_full  end

              ;; Apply face lighting offset
              local.get $face
              i32.const 0
              i32.eq
              if
                local.get $shade_full
                i32.const 32
                i32.add
                local.set $shade_full
              end
              local.get $face
              i32.const 2
              i32.eq
              if
                local.get $shade_full
                i32.const 16
                i32.sub
                local.set $shade_full
              end
              local.get $face
              i32.const 3
              i32.eq
              if
                local.get $shade_full
                i32.const 32
                i32.sub
                local.set $shade_full
              end

              ;; Apply texture offset
              local.get $hit_type
              local.get $face
              local.get $hit_vx
              local.get $hit_vy
              local.get $hit_vz
              local.get $tex_u
              local.get $tex_v
              call $texture_offset
              local.set $tex_off
              local.get $shade_full
              local.get $tex_off
              i32.const 12
              i32.mul
              i32.add
              local.set $shade_full

              ;; Clamp to 0..255
              local.get $shade_full
              i32.const 0
              i32.lt_s
              if  i32.const 0  local.set $shade_full  end
              local.get $shade_full
              i32.const 255
              i32.gt_s
              if  i32.const 255  local.set $shade_full  end

              ;; ============================================================
              ;; Apply day_bright to shade_full for proper day/night lighting
              ;; shade_full (0-255) * day_bright (0-255) / 255
              ;; This gives us 256 brightness levels before palette mapping
              ;; ============================================================
              local.get $shade_full
              local.get $day_bright
              i32.mul
              i32.const 255
              i32.div_u
              local.set $shade_full

              ;; ============================================================
              ;; Convert block color to 24-bit RGB, then dither to RGBL palette
              ;; Block base encodes R,G,B as 2-bit indices (0-3) in RGBL format
              ;; base = (R2<<6)|(G2<<4)|(B2<<2)
              ;; Channel levels: 0→0, 1→85, 2→170, 3→255
              ;; Final RGB = channel[base_component] * shade_full / 255
              ;; ============================================================
              ;; Get base color components from block type
              local.get $hit_type
              call $block_base
              local.set $color  ;; reuse $color as temp for base

              ;; Water shimmer: override base for water blocks
              local.get $hit_type
              i32.const 5
              i32.eq
              if
                i32.const 0x1C  ;; water base R=0,G=1,B=3
                local.set $color
                ;; Add shimmer by modifying shade
                local.get $shade_full
                local.get $tex_u
                local.get $tex_v
                i32.add
                local.get $tick
                i32.const 6
                i32.shr_u
                i32.add
                i32.const 7
                i32.and
                i32.const 8
                i32.mul
                i32.add
                local.set $shade_full
                local.get $shade_full
                i32.const 255
                i32.gt_s
                if  i32.const 255  local.set $shade_full  end
              end

              ;; Distance fog: blend shade toward sky color at far distances
              local.get $dist
              f64.const 60.0
              f64.gt
              if
                ;; fog_t = (dist-60)*8, clamped to 0..255
                local.get $dist
                f64.const 60.0
                f64.sub
                f64.const 8.0
                f64.mul
                i32.trunc_f64_s
                local.set $shade_frac  ;; reuse as fog amount
                local.get $shade_frac
                i32.const 0
                i32.lt_s
                if  i32.const 0  local.set $shade_frac  end
                local.get $shade_frac
                i32.const 255
                i32.gt_s
                if  i32.const 255  local.set $shade_frac  end
                ;; Blend to sky: write dithered sky color and skip block color
                local.get $fb_addr
                local.get $px_col
                local.get $px_row
                ;; R: fog from block R to sky R
                ;; sky R at day: 140*day_bright/255, night: 2
                ;; Simplified: just use sky color
                i32.const 140
                local.get $day_bright
                i32.mul
                i32.const 2
                i32.const 255
                local.get $day_bright
                i32.sub
                i32.mul
                i32.add
                i32.const 255
                i32.div_u
                local.get $shade_frac
                i32.mul
                ;; block R contribution
                i32.const 0x19600
                local.get $color
                i32.const 6
                i32.shr_u
                i32.const 3
                i32.and
                i32.add
                i32.load8_u
                local.get $shade_full
                i32.mul
                i32.const 255
                i32.div_u
                i32.const 255
                local.get $shade_frac
                i32.sub
                i32.mul
                i32.add
                i32.const 255
                i32.div_u
                ;; G: fog blend
                i32.const 180
                local.get $day_bright
                i32.mul
                i32.const 4
                i32.const 255
                local.get $day_bright
                i32.sub
                i32.mul
                i32.add
                i32.const 255
                i32.div_u
                local.get $shade_frac
                i32.mul
                i32.const 0x19600
                local.get $color
                i32.const 4
                i32.shr_u
                i32.const 3
                i32.and
                i32.add
                i32.load8_u
                local.get $shade_full
                i32.mul
                i32.const 255
                i32.div_u
                i32.const 255
                local.get $shade_frac
                i32.sub
                i32.mul
                i32.add
                i32.const 255
                i32.div_u
                ;; B: fog blend
                i32.const 220
                local.get $day_bright
                i32.mul
                i32.const 10
                i32.const 255
                local.get $day_bright
                i32.sub
                i32.mul
                i32.add
                i32.const 255
                i32.div_u
                local.get $shade_frac
                i32.mul
                i32.const 0x19600
                local.get $color
                i32.const 2
                i32.shr_u
                i32.const 3
                i32.and
                i32.add
                i32.load8_u
                local.get $shade_full
                i32.mul
                i32.const 255
                i32.div_u
                i32.const 255
                local.get $shade_frac
                i32.sub
                i32.mul
                i32.add
                i32.const 255
                i32.div_u
                call $rgb_to_rgbl_dither
                i32.store8
              else
                ;; No fog: compute 24-bit RGB from block base and shade, then dither
                ;; R = channel[(base>>6)&3] * shade_full / 255
                ;; G = channel[(base>>4)&3] * shade_full / 255
                ;; B = channel[(base>>2)&3] * shade_full / 255
                local.get $fb_addr
                local.get $px_col
                local.get $px_row
                ;; R
                i32.const 0x19600
                local.get $color
                i32.const 6
                i32.shr_u
                i32.const 3
                i32.and
                i32.add
                i32.load8_u
                local.get $shade_full
                i32.mul
                i32.const 255
                i32.div_u
                ;; G
                i32.const 0x19600
                local.get $color
                i32.const 4
                i32.shr_u
                i32.const 3
                i32.and
                i32.add
                i32.load8_u
                local.get $shade_full
                i32.mul
                i32.const 255
                i32.div_u
                ;; B
                i32.const 0x19600
                local.get $color
                i32.const 2
                i32.shr_u
                i32.const 3
                i32.and
                i32.add
                i32.load8_u
                local.get $shade_full
                i32.mul
                i32.const 255
                i32.div_u
                call $rgb_to_rgbl_dither
                i32.store8
              end
            else
              ;; Sky
              local.get $ray_dz
              f64.const 0.0
              f64.gt
              if
                ;; Check sun/moon
                f64.const 0.0
                local.set $cel_dot
                local.get $cel_active
                if
                  local.get $ray_dx
                  local.get $cel_dir_x
                  f64.mul
                  local.get $ray_dy
                  local.get $cel_dir_y
                  f64.mul
                  f64.add
                  local.get $ray_dz
                  local.get $cel_dir_z
                  f64.mul
                  f64.add
                  local.set $cel_dot
                end

                local.get $cel_active
                local.get $cel_is_sun
                i32.and
                local.get $cel_dot
                f64.const 0.980
                f64.gt
                i32.and
                if
                  ;; Sun rendering with dithered 24-bit RGB
                  ;; cel_dot 0.980→1.0, map to t = 0..255
                  local.get $cel_dot
                  f64.const 0.980
                  f64.sub
                  f64.const 12750.0
                  f64.mul
                  i32.trunc_f64_s
                  local.set $shade_full
                  local.get $shade_full
                  i32.const 255
                  i32.gt_s
                  if  i32.const 255  local.set $shade_full  end
                  local.get $shade_full
                  i32.const 0
                  i32.lt_s
                  if  i32.const 0  local.set $shade_full  end

                  ;; Blend from sky color to sun color (warm yellow-white)
                  ;; Sky RGB: (sky_r, sky_g, sky_b) scaled by bright[3]/day_bright
                  ;; Actually compute sky at full brightness for blending base
                  ;; sky base at day: R=85*day_bright/255, G=170*day_bright/255, B=day_bright
                  ;; Sun center: R=255, G=240, B=200
                  ;; Blend: color = sky*(255-t)/255 + sun*t/255
                  ;; Red
                  local.get $fb_addr
                  local.get $px_col
                  local.get $px_row
                  ;; R = sky_r_full*(255-t)/255 + 255*t/255
                  ;; sky_r_full = 85*day_bright/255
                  i32.const 85
                  local.get $day_bright
                  i32.mul
                  i32.const 255
                  i32.div_u
                  i32.const 255
                  local.get $shade_full
                  i32.sub
                  i32.mul
                  i32.const 255
                  local.get $shade_full
                  i32.mul
                  i32.add
                  i32.const 255
                  i32.div_u
                  ;; G = sky_g_full*(255-t)/255 + 240*t/255
                  i32.const 170
                  local.get $day_bright
                  i32.mul
                  i32.const 255
                  i32.div_u
                  i32.const 255
                  local.get $shade_full
                  i32.sub
                  i32.mul
                  i32.const 240
                  local.get $shade_full
                  i32.mul
                  i32.add
                  i32.const 255
                  i32.div_u
                  ;; B = day_bright*(255-t)/255 + 200*t/255
                  local.get $day_bright
                  i32.const 255
                  local.get $shade_full
                  i32.sub
                  i32.mul
                  i32.const 200
                  local.get $shade_full
                  i32.mul
                  i32.add
                  i32.const 255
                  i32.div_u
                  call $rgb_to_rgbl_dither
                  i32.store8
                else
                  local.get $cel_active
                  local.get $cel_is_sun
                  i32.eqz
                  i32.and
                  local.get $cel_dot
                  f64.const 0.992
                  f64.gt
                  i32.and
                  if
                    ;; Moon rendering with dithered 24-bit RGB (dim moonlight)
                    ;; Map cel_dot from 0.992..1.0 to t = 0..255
                    local.get $cel_dot
                    f64.const 0.992
                    f64.sub
                    f64.const 31875.0  ;; 255/0.008
                    f64.mul
                    i32.trunc_f64_s
                    local.set $shade_full
                    local.get $shade_full
                    i32.const 0
                    i32.lt_s
                    if  i32.const 0  local.set $shade_full  end
                    local.get $shade_full
                    i32.const 255
                    i32.gt_s
                    if  i32.const 255  local.set $shade_full  end

                    ;; Moon: dim cool white, max brightness ~100 (not very bright)
                    ;; Blend from night sky (very dark blue) to moon surface
                    ;; Night sky: R≈2, G≈4, B≈10
                    ;; Moon center: R=90, G=95, B=100 (dim cool white)
                    local.get $fb_addr
                    local.get $px_col
                    local.get $px_row
                    ;; R = 2*(255-t)/255 + 90*t/255
                    i32.const 2
                    i32.const 255
                    local.get $shade_full
                    i32.sub
                    i32.mul
                    i32.const 90
                    local.get $shade_full
                    i32.mul
                    i32.add
                    i32.const 255
                    i32.div_u
                    ;; G = 4*(255-t)/255 + 95*t/255
                    i32.const 4
                    i32.const 255
                    local.get $shade_full
                    i32.sub
                    i32.mul
                    i32.const 95
                    local.get $shade_full
                    i32.mul
                    i32.add
                    i32.const 255
                    i32.div_u
                    ;; B = 10*(255-t)/255 + 100*t/255
                    i32.const 10
                    i32.const 255
                    local.get $shade_full
                    i32.sub
                    i32.mul
                    i32.const 100
                    local.get $shade_full
                    i32.mul
                    i32.add
                    i32.const 255
                    i32.div_u
                    call $rgb_to_rgbl_dither
                    i32.store8
                  else
                    ;; Sky gradient with dithered 24-bit RGB
                    ;; ray_dz (0..1) controls gradient from horizon to zenith
                    ;; Sky color: blend from horizon (lighter/hazier) to zenith (deeper blue)
                    ;; Horizon: R=140, G=180, B=220 (hazy)  Zenith: R=30, G=80, B=200 (deep)
                    ;; Scale by day_bright/255
                    ;; Also at night: very dark blue R≈2, G≈4, B≈10
                    local.get $ray_dz
                    f64.const 0.0
                    f64.lt
                    if
                      f64.const 0.0
                      local.set $ray_dz
                    end
                    local.get $ray_dz
                    f64.const 1.0
                    f64.gt
                    if
                      f64.const 1.0
                      local.set $ray_dz
                    end
                    ;; t = ray_dz * 255 (zenith blend)
                    local.get $ray_dz
                    f64.const 255.0
                    f64.mul
                    i32.trunc_f64_s
                    local.set $sky_idx
                    local.get $sky_idx
                    i32.const 255
                    i32.gt_s
                    if  i32.const 255  local.set $sky_idx  end

                    ;; Day sky RGB (before brightness scaling):
                    ;; R = (140*(255-t) + 30*t) / 255
                    ;; G = (180*(255-t) + 80*t) / 255
                    ;; B = (220*(255-t) + 200*t) / 255
                    ;; Then multiply by day_bright/255 and add night base

                    local.get $fb_addr
                    local.get $px_col
                    local.get $px_row
                    ;; R: day_r * day_bright/255 + night_r * (255-day_bright)/255
                    ;; day_r = (140*(255-sky_idx) + 30*sky_idx) / 255
                    i32.const 140
                    i32.const 255
                    local.get $sky_idx
                    i32.sub
                    i32.mul
                    i32.const 30
                    local.get $sky_idx
                    i32.mul
                    i32.add
                    i32.const 255
                    i32.div_u
                    local.get $day_bright
                    i32.mul
                    ;; night_r = 2
                    i32.const 2
                    i32.const 255
                    local.get $day_bright
                    i32.sub
                    i32.mul
                    i32.add
                    i32.const 255
                    i32.div_u
                    ;; G
                    i32.const 180
                    i32.const 255
                    local.get $sky_idx
                    i32.sub
                    i32.mul
                    i32.const 80
                    local.get $sky_idx
                    i32.mul
                    i32.add
                    i32.const 255
                    i32.div_u
                    local.get $day_bright
                    i32.mul
                    i32.const 4
                    i32.const 255
                    local.get $day_bright
                    i32.sub
                    i32.mul
                    i32.add
                    i32.const 255
                    i32.div_u
                    ;; B
                    i32.const 220
                    i32.const 255
                    local.get $sky_idx
                    i32.sub
                    i32.mul
                    i32.const 200
                    local.get $sky_idx
                    i32.mul
                    i32.add
                    i32.const 255
                    i32.div_u
                    local.get $day_bright
                    i32.mul
                    i32.const 10
                    i32.const 255
                    local.get $day_bright
                    i32.sub
                    i32.mul
                    i32.add
                    i32.const 255
                    i32.div_u
                    call $rgb_to_rgbl_dither
                    i32.store8
                  end
                end
              else
                ;; Below horizon fog: dithered sky at horizon level
                ;; Use horizon sky color (ray_dz≈0 equivalent)
                ;; day: R=140*day_bright/255, G=180*day_bright/255, B=220*day_bright/255
                ;; plus night base
                local.get $fb_addr
                local.get $px_col
                local.get $px_row
                ;; R
                i32.const 140
                local.get $day_bright
                i32.mul
                i32.const 2
                i32.const 255
                local.get $day_bright
                i32.sub
                i32.mul
                i32.add
                i32.const 255
                i32.div_u
                ;; G
                i32.const 180
                local.get $day_bright
                i32.mul
                i32.const 4
                i32.const 255
                local.get $day_bright
                i32.sub
                i32.mul
                i32.add
                i32.const 255
                i32.div_u
                ;; B
                i32.const 220
                local.get $day_bright
                i32.mul
                i32.const 10
                i32.const 255
                local.get $day_bright
                i32.sub
                i32.mul
                i32.add
                i32.const 255
                i32.div_u
                call $rgb_to_rgbl_dither
                i32.store8
              end
            end

            local.get $px_col
            i32.const 1
            i32.add
            local.set $px_col
            br $col_lp
          end
        end

        local.get $px_row
        i32.const 1
        i32.add
        local.set $px_row
        br $row_lp
      end
    end

    ;; ---- Crosshair ---- (white bright = 0xFF)
    i32.const 160
    i32.const 98
    i32.const 0xFF  ;; white bright
    call $put_pixel
    i32.const 160
    i32.const 99
    i32.const 0xFF
    call $put_pixel
    i32.const 160
    i32.const 101
    i32.const 223
    call $put_pixel
    i32.const 160
    i32.const 102
    i32.const 223
    call $put_pixel
    i32.const 158
    i32.const 100
    i32.const 0xFF
    call $put_pixel
    i32.const 159
    i32.const 100
    i32.const 0xFF
    call $put_pixel
    i32.const 161
    i32.const 100
    i32.const 0xFF
    call $put_pixel
    i32.const 162
    i32.const 100
    i32.const 0xFF
    call $put_pixel

    ;; ---- HUD ----
    ;; Time display (top-right)
    local.get $game_hour
    i32.const 10
    i32.lt_u
    if
      i32.const 48
      i32.const 275
      i32.const 2
      i32.const 223  ;; base 13 shade 15 (white bright)
      call $draw_char
      local.get $game_hour
      i32.const 280
      i32.const 2
      i32.const 223
      call $draw_num
    else
      local.get $game_hour
      i32.const 275
      i32.const 2
      i32.const 223
      call $draw_num
    end
    i32.const 0x190E0
    i32.const 285
    i32.const 2
    i32.const 223
    call $draw_str
    local.get $game_min
    i32.const 10
    i32.lt_u
    if
      i32.const 48
      i32.const 290
      i32.const 2
      i32.const 223
      call $draw_char
      local.get $game_min
      i32.const 295
      i32.const 2
      i32.const 223
      call $draw_num
    else
      local.get $game_min
      i32.const 290
      i32.const 2
      i32.const 223
      call $draw_num
    end
    ;; Day/Night indicator
    local.get $day_bright
    i32.const 128
    i32.gt_u
    if
      i32.const 42
      i32.const 305
      i32.const 2
      i32.const 255  ;; base 15 shade 15 (yellow bright)
      call $draw_char
    else
      i32.const 111
      i32.const 305
      i32.const 2
      i32.const 221  ;; base 13 shade 13 (white dim)
      call $draw_char
    end

    i32.const 0x190C0
    i32.const 2
    i32.const 2
    i32.const 223
    call $draw_str
    i32.const 0x10390
    i32.load
    i32.const 32
    i32.const 2
    i32.const 223
    call $draw_num
    i32.const 0x190D0
    i32.const 57
    i32.const 2
    i32.const 221
    call $draw_str
    i32.const 0x10394
    i32.load
    i32.const 62
    i32.const 2
    i32.const 221
    call $draw_num

    ;; ---- Gods angry message ----
    i32.const 0x1039C
    i32.load
    local.set $msg_timer
    local.get $msg_timer
    i32.const 0
    i32.gt_s
    if
      i32.const 0x1039C
      local.get $msg_timer
      i32.const 1
      i32.sub
      i32.store
      i32.const 55
      i32.const 70
      i32.const 210
      i32.const 50
      i32.const 226  ;; base 14 shade 2 (dark red bg)
      call $fill_rect
      i32.const 0x19050
      i32.const 80
      i32.const 78
      i32.const 236  ;; base 14 shade 12 (red text)
      call $draw_str
      i32.const 0x19070
      i32.const 72
      i32.const 90
      i32.const 236
      call $draw_str
      i32.const 0x19090
      i32.const 72
      i32.const 102
      i32.const 236
      call $draw_str
      local.get $msg_timer
      i32.const 31
      i32.and
      i32.const 0
      i32.eq
      if
        i32.const 2
        i32.const 80
        i32.const 200
        i32.const 180
        call $note
      end
    end

    ;; ---- Title (first 180 frames) ----
    local.get $frame_ct
    i32.const 180
    i32.lt_u
    if
      i32.const 0x19000
      i32.const 105
      i32.const 30
      i32.const 175  ;; base 10 shade 15 (green bright)
      call $draw_str
      i32.const 0x19010
      i32.const 70
      i32.const 180
      i32.const 221  ;; base 13 shade 13 (white dim)
      call $draw_str
      i32.const 0x19030
      i32.const 60
      i32.const 190
      i32.const 221
      call $draw_str
    end

    ;; Dig sound
    local.get $mouse_btn
    i32.const 1
    i32.and
    local.get $prev_mouse
    i32.const 1
    i32.and
    i32.eqz
    i32.and
    if
      i32.const 3
      i32.const 200
      i32.const 50
      i32.const 150
      call $note
    end
  )

  ;; ---- Dig or place block ----
  (func $dig_or_place (param $px f64) (param $py f64) (param $pz f64) (param $angle f64) (param $place_mode i32)
    (local $t f64) (local $cx f64) (local $cy f64) (local $cz f64)
    (local $wx i32) (local $wy i32) (local $wz i32)
    (local $block i32)
    (local $ray_dx f64) (local $ray_dy f64) (local $ray_dz f64)
    (local $look_y i32) (local $pitch f64)
    (local $cos_pitch f64)

    ;; Construct forward ray with pitch
    i32.const 0x103AC
    i32.load
    local.set $look_y
    local.get $look_y
    f64.convert_i32_s
    f64.const 0.015
    f64.mul
    local.set $pitch
    local.get $pitch
    call $cos_a
    local.set $cos_pitch
    local.get $angle
    call $cos_a
    local.get $cos_pitch
    f64.mul
    local.set $ray_dx
    local.get $angle
    call $sin_a
    local.get $cos_pitch
    f64.mul
    local.set $ray_dy
    local.get $pitch
    call $sin_a
    local.set $ray_dz

    f64.const 0.5
    local.set $t
    block $done
      loop $lp
        local.get $t
        f64.const 6.0
        f64.gt
        br_if $done

        local.get $px
        local.get $ray_dx
        local.get $t
        f64.mul
        f64.add
        local.set $cx
        local.get $py
        local.get $ray_dy
        local.get $t
        f64.mul
        f64.add
        local.set $cy
        local.get $pz
        local.get $ray_dz
        local.get $t
        f64.mul
        f64.add
        local.set $cz
        local.get $cx
        f64.floor
        i32.trunc_f64_s
        local.set $wx
        local.get $cy
        f64.floor
        i32.trunc_f64_s
        local.set $wy
        local.get $cz
        f64.floor
        i32.trunc_f64_s
        local.set $wz
        local.get $wx
        local.get $wy
        local.get $wz
        call $get_block
        local.set $block

        local.get $block
        i32.const 0
        i32.ne
        if
          local.get $place_mode
          if
            ;; Place block: step back slightly
            local.get $cx
            local.get $ray_dx
            f64.const 0.3
            f64.mul
            f64.sub
            local.set $cx
            local.get $cy
            local.get $ray_dy
            f64.const 0.3
            f64.mul
            f64.sub
            local.set $cy
            local.get $cz
            local.get $ray_dz
            f64.const 0.3
            f64.mul
            f64.sub
            local.set $cz
            local.get $cx
            f64.floor
            i32.trunc_f64_s
            local.get $cy
            f64.floor
            i32.trunc_f64_s
            local.get $cz
            f64.floor
            i32.trunc_f64_s
            i32.const 2
            call $set_block
            i32.const 1
            i32.const 300
            i32.const 60
            i32.const 120
            call $note
          else
            local.get $wx
            local.get $wy
            local.get $wz
            i32.const 0
            call $set_block
            i32.const 3
            i32.const 150
            i32.const 80
            i32.const 100
            call $note
          end
          return
        end

        local.get $t
        f64.const 0.2
        f64.add
        local.set $t
        br $lp
      end
    end
  )
)