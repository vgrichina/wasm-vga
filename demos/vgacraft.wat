(module
  (import "env" "memory" (memory 10))
  (import "env" "sfx" (func $sfx (param i32)))
  (import "env" "note" (func $note (param i32 i32 i32 i32)))
  (import "env" "music" (func $music (param i32)))

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
  ;;   0x1A000  Chunk cache (4×4×4) — 1024 entries × 8 bytes = 8192 bytes
  ;;   0x1C000  Mega-chunk cache (16×16×16) — 256 entries × 8 bytes = 2048 bytes
  ;;   Cache: per-frame generation-tagged direct-mapped hash table
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

  ;; ---- Terrain height: returns 1-22 for given world XY ----
  ;; More hilly terrain with deeper valleys for lakes (water level at Z<=7)
  (func $terrain_height (param $wx i32) (param $wy i32) (result i32)
    (local $h1 i32) (local $h2 i32) (local $h3 i32) (local $h4 i32) (local $result i32)
    ;; h1 = smooth_hash(wx, wy, 32) >> 4  (large rolling hills, 0-15)
    local.get $wx
    local.get $wy
    i32.const 32
    call $smooth_hash
    i32.const 4
    i32.shr_u
    local.set $h1
    ;; h2 = smooth_hash(wx+1000, wy+2000, 12) >> 5 (medium bumps, 0-7)
    local.get $wx
    i32.const 1000
    i32.add
    local.get $wy
    i32.const 2000
    i32.add
    i32.const 12
    call $smooth_hash
    i32.const 5
    i32.shr_u
    local.set $h2
    ;; h3 = smooth_hash(wx+5000, wy+7000, 6) >> 6 (fine detail, 0-3)
    local.get $wx
    i32.const 5000
    i32.add
    local.get $wy
    i32.const 7000
    i32.add
    i32.const 6
    call $smooth_hash
    i32.const 6
    i32.shr_u
    local.set $h3
    ;; h4 = hash2d(wx+9000, wy+3000) & 1 (noise, 0-1)
    local.get $wx
    i32.const 9000
    i32.add
    local.get $wy
    i32.const 3000
    i32.add
    call $hash2d
    i32.const 1
    i32.and
    local.set $h4
    ;; result = 1 + h1 + h2 + h3 + h4  (range ~1 to 27, clamped to 1-22)
    i32.const 1
    local.get $h1
    i32.add
    local.get $h2
    i32.add
    local.get $h3
    local.get $h4
    i32.add
    i32.add
    local.set $result
    local.get $result
    i32.const 22
    i32.gt_s
    if
      i32.const 22
      local.set $result
    end
    local.get $result
    i32.const 1
    i32.lt_s
    if
      i32.const 1
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
    ;; (h & 255) < 10 && terrain_height(wx, wy) > 8 (trees only above water level)
    local.get $h
    i32.const 255
    i32.and
    i32.const 10
    i32.lt_u
    local.get $wx
    local.get $wy
    call $terrain_height
    i32.const 8
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
    ;; Above terrain = air (or water at Z<=7)
    local.get $wz
    local.get $th
    i32.gt_s
    if
      local.get $wz
      i32.const 7
      i32.le_s
      local.get $th
      i32.const 7
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
      i32.const 7
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

    ;; Invalidate octree caches — bump generation so all entries become stale
    global.get $g_cache_gen
    i32.const 1
    i32.add
    i32.const 0xFF
    i32.and
    global.set $g_cache_gen
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

  ;; ---- HSL to RGB conversion ----
  ;; h: 0-360 (degrees), s: 0-255 (saturation), l: 0-255 (lightness)
  ;; Returns packed 0x00RRGGBB
  (func $hsl_to_rgb (param $h i32) (param $s_byte i32) (param $l_byte i32) (result i32)
    (local $s f64) (local $l f64) (local $c f64) (local $x f64) (local $m f64)
    (local $hf f64) (local $hmod f64)
    (local $r f64) (local $g f64) (local $b f64)
    (local $ri i32) (local $gi i32) (local $bi i32)
    ;; s = s_byte / 255.0, l = l_byte / 255.0
    local.get $s_byte
    f64.convert_i32_u
    f64.const 255.0
    f64.div
    local.set $s
    local.get $l_byte
    f64.convert_i32_u
    f64.const 255.0
    f64.div
    local.set $l
    ;; c = (1 - |2l - 1|) * s
    f64.const 2.0
    local.get $l
    f64.mul
    f64.const 1.0
    f64.sub
    local.set $c
    local.get $c
    f64.const 0.0
    f64.lt
    if
      f64.const 0.0
      local.get $c
      f64.sub
      local.set $c
    end
    f64.const 1.0
    local.get $c
    f64.sub
    local.get $s
    f64.mul
    local.set $c
    ;; hf = h / 60.0
    local.get $h
    f64.convert_i32_u
    f64.const 60.0
    f64.div
    local.set $hf
    ;; hmod = hf - floor(hf/2)*2 (hf mod 2)
    local.get $hf
    f64.const 2.0
    f64.div
    f64.floor
    f64.const 2.0
    f64.mul
    local.set $hmod
    local.get $hf
    local.get $hmod
    f64.sub
    local.set $hmod
    ;; x = c * (1 - |hmod - 1|)
    local.get $hmod
    f64.const 1.0
    f64.sub
    local.set $x
    local.get $x
    f64.const 0.0
    f64.lt
    if
      f64.const 0.0
      local.get $x
      f64.sub
      local.set $x
    end
    local.get $c
    f64.const 1.0
    local.get $x
    f64.sub
    f64.mul
    local.set $x
    ;; m = l - c/2
    local.get $l
    local.get $c
    f64.const 2.0
    f64.div
    f64.sub
    local.set $m
    ;; Default
    f64.const 0.0
    local.set $r
    f64.const 0.0
    local.set $g
    f64.const 0.0
    local.set $b
    ;; Sector selection based on hf (0-6)
    local.get $hf
    f64.const 1.0
    f64.lt
    if
      local.get $c
      local.set $r
      local.get $x
      local.set $g
      f64.const 0.0
      local.set $b
    else
      local.get $hf
      f64.const 2.0
      f64.lt
      if
        local.get $x
        local.set $r
        local.get $c
        local.set $g
        f64.const 0.0
        local.set $b
      else
        local.get $hf
        f64.const 3.0
        f64.lt
        if
          f64.const 0.0
          local.set $r
          local.get $c
          local.set $g
          local.get $x
          local.set $b
        else
          local.get $hf
          f64.const 4.0
          f64.lt
          if
            f64.const 0.0
            local.set $r
            local.get $x
            local.set $g
            local.get $c
            local.set $b
          else
            local.get $hf
            f64.const 5.0
            f64.lt
            if
              local.get $x
              local.set $r
              f64.const 0.0
              local.set $g
              local.get $c
              local.set $b
            else
              local.get $c
              local.set $r
              f64.const 0.0
              local.set $g
              local.get $x
              local.set $b
            end
          end
        end
      end
    end
    ;; Final RGB = (component + m) * 255
    local.get $r
    local.get $m
    f64.add
    f64.const 255.0
    f64.mul
    f64.nearest
    i32.trunc_f64_s
    local.set $ri
    local.get $g
    local.get $m
    f64.add
    f64.const 255.0
    f64.mul
    f64.nearest
    i32.trunc_f64_s
    local.set $gi
    local.get $b
    local.get $m
    f64.add
    f64.const 255.0
    f64.mul
    f64.nearest
    i32.trunc_f64_s
    local.set $bi
    ;; Clamp 0-255
    local.get $ri
    i32.const 0
    i32.lt_s
    if  i32.const 0  local.set $ri  end
    local.get $ri
    i32.const 255
    i32.gt_s
    if  i32.const 255  local.set $ri  end
    local.get $gi
    i32.const 0
    i32.lt_s
    if  i32.const 0  local.set $gi  end
    local.get $gi
    i32.const 255
    i32.gt_s
    if  i32.const 255  local.set $gi  end
    local.get $bi
    i32.const 0
    i32.lt_s
    if  i32.const 0  local.set $bi  end
    local.get $bi
    i32.const 255
    i32.gt_s
    if  i32.const 255  local.set $bi  end
    ;; Pack as 0x00RRGGBB
    local.get $ri
    i32.const 16
    i32.shl
    local.get $gi
    i32.const 8
    i32.shl
    i32.or
    local.get $bi
    i32.or
  )

  ;; ============================================================
  ;; PALETTE + LUT INIT — fully in WAT
  ;; 8 material colors × 32 lighting levels = 256 palette entries
  ;; Materials: grass(0), dirt(1), stone(2), sand(3), water(4), wood(5), leaves(6), flowers(7)
  ;; Index = material * 32 + brightness (0=black, 31=full bright)
  ;; Then builds 32KB nearest-color LUT at 0x20000
  ;; ============================================================
  (func $init_palette
    (local $i i32) (local $hi i32) (local $sh i32) (local $idx i32)
    (local $hue i32) (local $lightness i32) (local $saturation i32)
    (local $rgb i32) (local $r i32) (local $g i32) (local $b i32)
    (local $v i32)
    (local $ri i32) (local $gi i32) (local $bi i32)
    (local $pr i32) (local $pg i32) (local $pb i32)
    (local $dr i32) (local $dg i32) (local $db i32)
    (local $dist i32) (local $best_dist i32) (local $best_idx i32)
    (local $p i32) (local $addr i32)
    (local $sin_val f64) (local $sat_f64 f64)
    (local $base_r i32) (local $base_g i32) (local $base_b i32)

    ;; ---- 8 material base colors stored temporarily at 0x28000 ----
    ;; Each material: 3 bytes (R, G, B) — 8 × 3 = 24 bytes
    ;; VIBRANT palette — maximally distinct hues, no duplicates:
    ;; 0: grass — emerald green (pure green, no yellow)
    i32.const 0x28000
    i32.const 30
    i32.store8
    i32.const 0x28001
    i32.const 200
    i32.store8
    i32.const 0x28002
    i32.const 50
    i32.store8
    ;; 1: dirt — warm sienna orange-brown (distinct from wood)
    i32.const 0x28003
    i32.const 185
    i32.store8
    i32.const 0x28004
    i32.const 115
    i32.store8
    i32.const 0x28005
    i32.const 45
    i32.store8
    ;; 2: stone — cool slate blue-grey
    i32.const 0x28006
    i32.const 105
    i32.store8
    i32.const 0x28007
    i32.const 118
    i32.store8
    i32.const 0x28008
    i32.const 160
    i32.store8
    ;; 3: sand — bright warm gold
    i32.const 0x28009
    i32.const 248
    i32.store8
    i32.const 0x2800A
    i32.const 225
    i32.store8
    i32.const 0x2800B
    i32.const 90
    i32.store8
    ;; 4: water — vivid ocean blue
    i32.const 0x2800C
    i32.const 10
    i32.store8
    i32.const 0x2800D
    i32.const 110
    i32.store8
    i32.const 0x2800E
    i32.const 245
    i32.store8
    ;; 5: wood — deep mahogany red-brown (darker, redder than dirt)
    i32.const 0x2800F
    i32.const 110
    i32.store8
    i32.const 0x28010
    i32.const 50
    i32.store8
    i32.const 0x28011
    i32.const 25
    i32.store8
    ;; 6: leaves — rich forest green (distinct darker green from grass)
    i32.const 0x28012
    i32.const 30
    i32.store8
    i32.const 0x28013
    i32.const 160
    i32.store8
    i32.const 0x28014
    i32.const 40
    i32.store8
    ;; 7: flowers/accent — vivid magenta-pink (distinct from all other materials)
    ;; Used for sky/cloud rendering ramp AND flower blocks
    i32.const 0x28015
    i32.const 220
    i32.store8
    i32.const 0x28016
    i32.const 50
    i32.store8
    i32.const 0x28017
    i32.const 180
    i32.store8

    ;; ---- Generate 8 × 32 = 256 palette entries ----
    ;; palette[mat*32 + shade] = base_color * shade / 31
    i32.const 0
    local.set $hi  ;; material index (0-7)
    block $mat_done
      loop $mat_lp
        local.get $hi
        i32.const 8
        i32.ge_u
        br_if $mat_done

        ;; Load base color for this material
        i32.const 0x28000
        local.get $hi
        i32.const 3
        i32.mul
        i32.add
        i32.load8_u
        local.set $base_r
        i32.const 0x28001
        local.get $hi
        i32.const 3
        i32.mul
        i32.add
        i32.load8_u
        local.set $base_g
        i32.const 0x28002
        local.get $hi
        i32.const 3
        i32.mul
        i32.add
        i32.load8_u
        local.set $base_b

        i32.const 0
        local.set $sh  ;; brightness level (0-31)
        block $shade_done
          loop $shade_lp
            local.get $sh
            i32.const 32
            i32.ge_u
            br_if $shade_done

            ;; palette index = hi * 32 + sh
            local.get $hi
            i32.const 32
            i32.mul
            local.get $sh
            i32.add
            local.set $idx

            ;; R = base_r * sh / 31
            local.get $base_r
            local.get $sh
            i32.mul
            i32.const 31
            i32.div_u
            local.set $r
            ;; G = base_g * sh / 31
            local.get $base_g
            local.get $sh
            i32.mul
            i32.const 31
            i32.div_u
            local.set $g
            ;; B = base_b * sh / 31
            local.get $base_b
            local.get $sh
            i32.mul
            i32.const 31
            i32.div_u
            local.set $b

            local.get $idx
            local.get $r
            local.get $g
            local.get $b
            call $set_pal

            local.get $sh
            i32.const 1
            i32.add
            local.set $sh
            br $shade_lp
          end
        end

        local.get $hi
        i32.const 1
        i32.add
        local.set $hi
        br $mat_lp
      end
    end

    ;; ---- Build 32KB nearest-color LUT at 0x20000 ----
    ;; LUT[ri<<10 | gi<<5 | bi] = nearest palette index
    ;; ri,gi,bi each 0-31 (5-bit quantized RGB)
    ;; First, cache palette RGB at 0x28100 (256 * 3 = 768 bytes temp)
    i32.const 0
    local.set $i
    block $cache_done
      loop $cache_lp
        local.get $i
        i32.const 256
        i32.ge_u
        br_if $cache_done
        ;; Read from palette memory at 0x0040
        local.get $i
        i32.const 3
        i32.mul
        local.set $addr
        ;; R
        i32.const 0x28100
        local.get $i
        i32.const 3
        i32.mul
        i32.add
        i32.const 0x0040
        local.get $addr
        i32.add
        i32.load8_u
        i32.store8
        ;; G
        i32.const 0x28101
        local.get $i
        i32.const 3
        i32.mul
        i32.add
        i32.const 0x0041
        local.get $addr
        i32.add
        i32.load8_u
        i32.store8
        ;; B
        i32.const 0x28102
        local.get $i
        i32.const 3
        i32.mul
        i32.add
        i32.const 0x0042
        local.get $addr
        i32.add
        i32.load8_u
        i32.store8
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $cache_lp
      end
    end

    ;; Now iterate 32×32×32 RGB cube
    i32.const 0
    local.set $ri
    block $ri_done
      loop $ri_lp
        local.get $ri
        i32.const 32
        i32.ge_u
        br_if $ri_done
        ;; r = ri * 255 / 31
        local.get $ri
        i32.const 255
        i32.mul
        i32.const 31
        i32.div_u
        local.set $r

        i32.const 0
        local.set $gi
        block $gi_done
          loop $gi_lp
            local.get $gi
            i32.const 32
            i32.ge_u
            br_if $gi_done
            ;; g = gi * 255 / 31
            local.get $gi
            i32.const 255
            i32.mul
            i32.const 31
            i32.div_u
            local.set $g

            i32.const 0
            local.set $bi
            block $bi_done
              loop $bi_lp
                local.get $bi
                i32.const 32
                i32.ge_u
                br_if $bi_done
                ;; b = bi * 255 / 31
                local.get $bi
                i32.const 255
                i32.mul
                i32.const 31
                i32.div_u
                local.set $b

                ;; Find nearest palette entry
                i32.const 0x7FFFFFFF
                local.set $best_dist
                i32.const 0
                local.set $best_idx

                i32.const 0
                local.set $p
                block $p_done
                  loop $p_lp
                    local.get $p
                    i32.const 256
                    i32.ge_u
                    br_if $p_done

                    ;; pr = cached palette R
                    local.get $p
                    i32.const 3
                    i32.mul
                    local.set $addr
                    i32.const 0x28100
                    local.get $addr
                    i32.add
                    i32.load8_u
                    local.set $pr
                    i32.const 0x28101
                    local.get $addr
                    i32.add
                    i32.load8_u
                    local.set $pg
                    i32.const 0x28102
                    local.get $addr
                    i32.add
                    i32.load8_u
                    local.set $pb

                    ;; Weighted perceptual distance: dr²×2 + dg²×4 + db²
                    local.get $r
                    local.get $pr
                    i32.sub
                    local.set $dr
                    local.get $g
                    local.get $pg
                    i32.sub
                    local.set $dg
                    local.get $b
                    local.get $pb
                    i32.sub
                    local.set $db

                    local.get $dr
                    local.get $dr
                    i32.mul
                    i32.const 2
                    i32.mul
                    local.get $dg
                    local.get $dg
                    i32.mul
                    i32.const 4
                    i32.mul
                    i32.add
                    local.get $db
                    local.get $db
                    i32.mul
                    i32.add
                    local.set $dist

                    local.get $dist
                    local.get $best_dist
                    i32.lt_u
                    if
                      local.get $dist
                      local.set $best_dist
                      local.get $p
                      local.set $best_idx
                    end

                    local.get $p
                    i32.const 1
                    i32.add
                    local.set $p
                    br $p_lp
                  end
                end

                ;; Write LUT entry
                i32.const 0x20000
                local.get $ri
                i32.const 10
                i32.shl
                local.get $gi
                i32.const 5
                i32.shl
                i32.or
                local.get $bi
                i32.or
                i32.add
                local.get $best_idx
                i32.store8

                local.get $bi
                i32.const 1
                i32.add
                local.set $bi
                br $bi_lp
              end
            end

            local.get $gi
            i32.const 1
            i32.add
            local.set $gi
            br $gi_lp
          end
        end

        local.get $ri
        i32.const 1
        i32.add
        local.set $ri
        br $ri_lp
      end
    end
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

  ;; ---- Material palette helpers (8 materials × 32 shades) ----
  ;; Block type base colors stored as 24-bit RGB at 0x19500 (9 entries × 3 bytes)
  ;; Written by $init in WAT
  ;; Helper: get base R for a block type (0-8)
  (func $block_base_r (param $type i32) (result i32)
    i32.const 0x19500
    local.get $type
    i32.const 3
    i32.mul
    i32.add
    i32.load8_u
  )
  (func $block_base_g (param $type i32) (result i32)
    i32.const 0x19500
    local.get $type
    i32.const 3
    i32.mul
    i32.add
    i32.const 1
    i32.add
    i32.load8_u
  )
  (func $block_base_b (param $type i32) (result i32)
    i32.const 0x19500
    local.get $type
    i32.const 3
    i32.mul
    i32.add
    i32.const 2
    i32.add
    i32.load8_u
  )
  ;; Backward compat: $block_base returns a dummy value (unused by new renderer)
  (func $block_base (param $type i32) (result i32)
    i32.const 0
  )

  ;; ---- Block color: returns palette index directly ----
  ;; New: 8 materials × 32 shades. palette index = (type-1)*32 + shade
  ;; face: 0=top, 1=side-bright, 2=side-dim, 3=bottom
  ;; shade: 0-15 input from distance etc
  (func $block_color (param $type i32) (param $face i32) (param $shade i32) (result i32)
    (local $r i32) (local $g i32) (local $b i32) (local $s i32)
    (local $mat i32)
    ;; Map block type (1-8) to material index (0-7)
    ;; type 0 = air (shouldn't be called), types 1-8 map to materials 0-7
    local.get $type
    i32.const 1
    i32.sub
    local.set $mat
    local.get $mat
    i32.const 0
    i32.lt_s
    if  i32.const 0  local.set $mat  end
    local.get $mat
    i32.const 7
    i32.gt_s
    if  i32.const 7  local.set $mat  end

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
    ;; Map shade 0..15 to 0..31 (multiply by 2 + 1 to use full range)
    local.get $shade
    i32.const 2
    i32.mul
    i32.const 1
    i32.add
    local.set $shade
    ;; Clamp to 31
    local.get $shade
    i32.const 31
    i32.gt_s
    if  i32.const 31  local.set $shade  end
    ;; Direct palette index = mat * 32 + shade
    local.get $mat
    i32.const 32
    i32.mul
    local.get $shade
    i32.add
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
    ;; Material palette: 8 base colors × 32 lighting levels = 256 colors
    ;; Palette + LUT generated entirely in WAT by $init_palette.
    ;; ================================================================
    call $init_palette

    ;; Write Bayer 4x4 dither matrix at 0x19640 (16 bytes)
    ;; Standard Bayer ordered dither matrix values 0-15
    i32.const 0x19640
    i32.const 0    ;; [0,0]
    i32.store8
    i32.const 0x19641
    i32.const 8    ;; [0,1]
    i32.store8
    i32.const 0x19642
    i32.const 2    ;; [0,2]
    i32.store8
    i32.const 0x19643
    i32.const 10   ;; [0,3]
    i32.store8
    i32.const 0x19644
    i32.const 12   ;; [1,0]
    i32.store8
    i32.const 0x19645
    i32.const 4    ;; [1,1]
    i32.store8
    i32.const 0x19646
    i32.const 14   ;; [1,2]
    i32.store8
    i32.const 0x19647
    i32.const 6    ;; [1,3]
    i32.store8
    i32.const 0x19648
    i32.const 3    ;; [2,0]
    i32.store8
    i32.const 0x19649
    i32.const 11   ;; [2,1]
    i32.store8
    i32.const 0x1964A
    i32.const 1    ;; [2,2]
    i32.store8
    i32.const 0x1964B
    i32.const 9    ;; [2,3]
    i32.store8
    i32.const 0x1964C
    i32.const 15   ;; [3,0]
    i32.store8
    i32.const 0x1964D
    i32.const 7    ;; [3,1]
    i32.store8
    i32.const 0x1964E
    i32.const 13   ;; [3,2]
    i32.store8
    i32.const 0x1964F
    i32.const 5    ;; [3,3]
    i32.store8

    ;; Keep channel level table at 0x19600 for backward compat
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
    i32.const 33    ;; bright[0]
    i32.store8
    i32.const 0x19605
    i32.const 102   ;; bright[1]
    i32.store8
    i32.const 0x19606
    i32.const 179   ;; bright[2]
    i32.store8
    i32.const 0x19607
    i32.const 255   ;; bright[3]
    i32.store8

    ;; ================================================================
    ;; Block type base colors stored as 24-bit RGB at 0x19500
    ;; (9 entries × 3 bytes = 27 bytes)
    ;; ================================================================
    ;; air: 0,0,0
    i32.const 0x19500
    i32.const 0
    i32.store8
    i32.const 0x19501
    i32.const 0
    i32.store8
    i32.const 0x19502
    i32.const 0
    i32.store8
    ;; grass — emerald green
    i32.const 0x19503
    i32.const 30
    i32.store8
    i32.const 0x19504
    i32.const 200
    i32.store8
    i32.const 0x19505
    i32.const 50
    i32.store8
    ;; dirt — warm sienna orange-brown
    i32.const 0x19506
    i32.const 185
    i32.store8
    i32.const 0x19507
    i32.const 115
    i32.store8
    i32.const 0x19508
    i32.const 45
    i32.store8
    ;; stone — cool slate blue-grey
    i32.const 0x19509
    i32.const 105
    i32.store8
    i32.const 0x1950A
    i32.const 118
    i32.store8
    i32.const 0x1950B
    i32.const 160
    i32.store8
    ;; sand — bright warm gold
    i32.const 0x1950C
    i32.const 248
    i32.store8
    i32.const 0x1950D
    i32.const 225
    i32.store8
    i32.const 0x1950E
    i32.const 90
    i32.store8
    ;; water — vivid ocean blue
    i32.const 0x1950F
    i32.const 10
    i32.store8
    i32.const 0x19510
    i32.const 110
    i32.store8
    i32.const 0x19511
    i32.const 245
    i32.store8
    ;; wood — deep mahogany red-brown
    i32.const 0x19512
    i32.const 110
    i32.store8
    i32.const 0x19513
    i32.const 50
    i32.store8
    i32.const 0x19514
    i32.const 25
    i32.store8
    ;; leaves — rich forest green (distinct darker green from grass)
    i32.const 0x19515
    i32.const 30
    i32.store8
    i32.const 0x19516
    i32.const 160
    i32.store8
    i32.const 0x19517
    i32.const 40
    i32.store8
    ;; flowers/accent — vivid magenta-pink (distinct from all other materials)
    i32.const 0x19518
    i32.const 220
    i32.store8
    i32.const 0x19519
    i32.const 50
    i32.store8
    i32.const 0x1951A
    i32.const 180
    i32.store8

    ;; ================================================================
    ;; AMBIENT MUSIC — calm Minecraft-style pentatonic pattern
    ;; Written to 0x19700 (well after string/dither data)
    ;; Format: bpm(u16), steps(u8), num_tracks(u8),
    ;;         per track: type(u8), vol(u8), dur_cs(u8), pad(u8)
    ;;         then note data: track0[steps], track1[steps], track2[steps]
    ;; ================================================================
    ;; bpm = 72 (slow, ambient)
    i32.const 0x19700
    i32.const 72  ;; bpm low byte
    i32.store8
    i32.const 0x19701
    i32.const 0   ;; bpm high byte
    i32.store8
    ;; steps = 32
    i32.const 0x19702
    i32.const 32
    i32.store8
    ;; num_tracks = 3
    i32.const 0x19703
    i32.const 3
    i32.store8
    ;; Track 0: triangle bass — warm and mellow, vol=60, dur=15cs
    i32.const 0x19704
    i32.const 3   ;; triangle
    i32.store8
    i32.const 0x19705
    i32.const 60  ;; vol
    i32.store8
    i32.const 0x19706
    i32.const 15  ;; dur centisec
    i32.store8
    i32.const 0x19707
    i32.const 0   ;; pad
    i32.store8
    ;; Track 1: sine pad — ethereal, vol=45, dur=20cs
    i32.const 0x19708
    i32.const 0   ;; sine
    i32.store8
    i32.const 0x19709
    i32.const 45  ;; vol
    i32.store8
    i32.const 0x1970A
    i32.const 20  ;; dur centisec
    i32.store8
    i32.const 0x1970B
    i32.const 0   ;; pad
    i32.store8
    ;; Track 2: triangle melody — gentle high notes, vol=35, dur=12cs
    i32.const 0x1970C
    i32.const 3   ;; triangle
    i32.store8
    i32.const 0x1970D
    i32.const 35  ;; vol
    i32.store8
    i32.const 0x1970E
    i32.const 12  ;; dur centisec
    i32.store8
    i32.const 0x1970F
    i32.const 0   ;; pad
    i32.store8
    ;; Note data at 0x19710 — 32 steps × 3 tracks = 96 bytes
    ;; Track 0 (bass): C pentatonic — C3(48), D3(50), E3(52), G3(55), A3(57)
    ;; Sparse, breathing bass — lots of rests for openness
    i32.const 0x19710  ;; step 0
    i32.const 48  ;; C3
    i32.store8
    i32.const 0x19711
    i32.const 0   ;; rest
    i32.store8
    i32.const 0x19712
    i32.const 0
    i32.store8
    i32.const 0x19713
    i32.const 0
    i32.store8
    i32.const 0x19714
    i32.const 55  ;; G3
    i32.store8
    i32.const 0x19715
    i32.const 0
    i32.store8
    i32.const 0x19716
    i32.const 0
    i32.store8
    i32.const 0x19717
    i32.const 0
    i32.store8
    i32.const 0x19718
    i32.const 48  ;; C3
    i32.store8
    i32.const 0x19719
    i32.const 0
    i32.store8
    i32.const 0x1971A
    i32.const 0
    i32.store8
    i32.const 0x1971B
    i32.const 0
    i32.store8
    i32.const 0x1971C
    i32.const 57  ;; A3
    i32.store8
    i32.const 0x1971D
    i32.const 0
    i32.store8
    i32.const 0x1971E
    i32.const 0
    i32.store8
    i32.const 0x1971F
    i32.const 0
    i32.store8
    i32.const 0x19720
    i32.const 50  ;; D3
    i32.store8
    i32.const 0x19721
    i32.const 0
    i32.store8
    i32.const 0x19722
    i32.const 0
    i32.store8
    i32.const 0x19723
    i32.const 0
    i32.store8
    i32.const 0x19724
    i32.const 52  ;; E3
    i32.store8
    i32.const 0x19725
    i32.const 0
    i32.store8
    i32.const 0x19726
    i32.const 0
    i32.store8
    i32.const 0x19727
    i32.const 0
    i32.store8
    i32.const 0x19728
    i32.const 55  ;; G3
    i32.store8
    i32.const 0x19729
    i32.const 0
    i32.store8
    i32.const 0x1972A
    i32.const 0
    i32.store8
    i32.const 0x1972B
    i32.const 0
    i32.store8
    i32.const 0x1972C
    i32.const 48  ;; C3
    i32.store8
    i32.const 0x1972D
    i32.const 0
    i32.store8
    i32.const 0x1972E
    i32.const 0
    i32.store8
    i32.const 0x1972F
    i32.const 0
    i32.store8
    ;; Track 1 (pad): gentle chord tones — sparse and airy
    ;; 32 bytes at 0x19730
    i32.const 0x19730
    i32.const 60  ;; C4
    i32.store8
    i32.const 0x19731
    i32.const 0
    i32.store8
    i32.const 0x19732
    i32.const 64  ;; E4
    i32.store8
    i32.const 0x19733
    i32.const 0
    i32.store8
    i32.const 0x19734
    i32.const 0
    i32.store8
    i32.const 0x19735
    i32.const 67  ;; G4
    i32.store8
    i32.const 0x19736
    i32.const 0
    i32.store8
    i32.const 0x19737
    i32.const 0
    i32.store8
    i32.const 0x19738
    i32.const 60  ;; C4
    i32.store8
    i32.const 0x19739
    i32.const 0
    i32.store8
    i32.const 0x1973A
    i32.const 0
    i32.store8
    i32.const 0x1973B
    i32.const 64  ;; E4
    i32.store8
    i32.const 0x1973C
    i32.const 0
    i32.store8
    i32.const 0x1973D
    i32.const 0
    i32.store8
    i32.const 0x1973E
    i32.const 69  ;; A4
    i32.store8
    i32.const 0x1973F
    i32.const 0
    i32.store8
    i32.const 0x19740
    i32.const 0
    i32.store8
    i32.const 0x19741
    i32.const 62  ;; D4
    i32.store8
    i32.const 0x19742
    i32.const 0
    i32.store8
    i32.const 0x19743
    i32.const 67  ;; G4
    i32.store8
    i32.const 0x19744
    i32.const 0
    i32.store8
    i32.const 0x19745
    i32.const 0
    i32.store8
    i32.const 0x19746
    i32.const 64  ;; E4
    i32.store8
    i32.const 0x19747
    i32.const 0
    i32.store8
    i32.const 0x19748
    i32.const 0
    i32.store8
    i32.const 0x19749
    i32.const 67  ;; G4
    i32.store8
    i32.const 0x1974A
    i32.const 0
    i32.store8
    i32.const 0x1974B
    i32.const 0
    i32.store8
    i32.const 0x1974C
    i32.const 60  ;; C4
    i32.store8
    i32.const 0x1974D
    i32.const 0
    i32.store8
    i32.const 0x1974E
    i32.const 0
    i32.store8
    i32.const 0x1974F
    i32.const 0
    i32.store8
    ;; Track 2 (melody): high dreamy notes — very sparse, pentatonic
    ;; 32 bytes at 0x19750
    i32.const 0x19750
    i32.const 0
    i32.store8
    i32.const 0x19751
    i32.const 0
    i32.store8
    i32.const 0x19752
    i32.const 72  ;; C5
    i32.store8
    i32.const 0x19753
    i32.const 0
    i32.store8
    i32.const 0x19754
    i32.const 0
    i32.store8
    i32.const 0x19755
    i32.const 0
    i32.store8
    i32.const 0x19756
    i32.const 0
    i32.store8
    i32.const 0x19757
    i32.const 76  ;; E5
    i32.store8
    i32.const 0x19758
    i32.const 0
    i32.store8
    i32.const 0x19759
    i32.const 0
    i32.store8
    i32.const 0x1975A
    i32.const 0
    i32.store8
    i32.const 0x1975B
    i32.const 0
    i32.store8
    i32.const 0x1975C
    i32.const 79  ;; G5
    i32.store8
    i32.const 0x1975D
    i32.const 0
    i32.store8
    i32.const 0x1975E
    i32.const 0
    i32.store8
    i32.const 0x1975F
    i32.const 0
    i32.store8
    i32.const 0x19760
    i32.const 0
    i32.store8
    i32.const 0x19761
    i32.const 0
    i32.store8
    i32.const 0x19762
    i32.const 0
    i32.store8
    i32.const 0x19763
    i32.const 74  ;; D5
    i32.store8
    i32.const 0x19764
    i32.const 0
    i32.store8
    i32.const 0x19765
    i32.const 0
    i32.store8
    i32.const 0x19766
    i32.const 0
    i32.store8
    i32.const 0x19767
    i32.const 0
    i32.store8
    i32.const 0x19768
    i32.const 72  ;; C5
    i32.store8
    i32.const 0x19769
    i32.const 0
    i32.store8
    i32.const 0x1976A
    i32.const 0
    i32.store8
    i32.const 0x1976B
    i32.const 0
    i32.store8
    i32.const 0x1976C
    i32.const 0
    i32.store8
    i32.const 0x1976D
    i32.const 69  ;; A4
    i32.store8
    i32.const 0x1976E
    i32.const 0
    i32.store8
    i32.const 0x1976F
    i32.const 0
    i32.store8

    ;; Start ambient music
    i32.const 0x19700
    call $music

    ;; Initialize player position (palette set by $init_palette above)
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

    ;; Write monster base color table at 0x1951B (3 entries × 3 bytes = 9 bytes)
    ;; Stored as 24-bit RGB
    ;; creeper(type 0): dark green 30,120,30
    i32.const 0x1951B
    i32.const 30
    i32.store8
    i32.const 0x1951C
    i32.const 120
    i32.store8
    i32.const 0x1951D
    i32.const 30
    i32.store8
    ;; zombie(type 1): olive 100,140,40
    i32.const 0x1951E
    i32.const 100
    i32.store8
    i32.const 0x1951F
    i32.const 140
    i32.store8
    i32.const 0x19520
    i32.const 40
    i32.store8
    ;; skeleton(type 2): bone 220,215,190
    i32.const 0x19521
    i32.const 220
    i32.store8
    i32.const 0x19522
    i32.const 215
    i32.store8
    i32.const 0x19523
    i32.const 190
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

    ;; Init octree cache generation counter
    i32.const 1
    global.set $g_cache_gen

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
  (data (i32.const 0x190F0) "MATERIALS\00")
  (data (i32.const 0x19100) "M\00")
  (data (i32.const 0x19102) "B\00")
  (data (i32.const 0x19104) "L\00")
  (data (i32.const 0x19106) " \00")
  (data (i32.const 0x19108) "ESC:CLOSE\00")
  (data (i32.const 0x19112) "0\00")
  (data (i32.const 0x19114) "1\00")
  (data (i32.const 0x19116) "2\00")
  (data (i32.const 0x19118) "3\00")
  (data (i32.const 0x1911A) "8x32 RAMPS\00")
  (data (i32.const 0x19126) "Steps:\00")
  ;; Bayer dither matrix at 0x19640 is written in init

  ;; ============================================================
  ;; OCTREE-ACCELERATED VOXEL RAYTRACER (CACHED)
  ;; ============================================================
  ;; Multi-level procedural octree with per-frame hash cache.
  ;; Chunk occupancy computed from terrain height bounds, then cached.
  ;; Level 0 (mega):  16×16×16 voxels — fast reject large empty volumes
  ;; Level 1 (chunk): 4×4×4 voxels — fine skip over empty air
  ;; Level 2 (fine):  standard per-voxel DDA in occupied chunks
  ;;
  ;; Terrain height range is 1-22 + trees up to +6 = max 28.
  ;; Water at Z<=7. Bedrock at Z<0.
  ;; Cache: direct-mapped hash table, generation-tagged per frame.
  ;; ============================================================

  ;; Cache generation counter (low byte of frame counter, bumped on mods)
  (global $g_cache_gen (mut i32) (i32.const 0))

  ;; Idle demo mode: frames since last input (triggers auto-camera after threshold)
  (global $g_idle_timer (mut i32) (i32.const 0))
  ;; Idle demo accumulated angle offset for smooth rotation
  (global $g_idle_angle (mut f64) (f64.const 0.0))
  ;; Idle demo flyover altitude (gradually increases from 0)
  (global $g_idle_alt (mut f64) (f64.const 0.0))

  ;; Inventory toggle state
  (global $g_show_inv (mut i32) (i32.const 0))
  (global $g_prev_esc (mut i32) (i32.const 0))

  (global $g_hit_face (mut i32) (i32.const 0))
  (global $g_hit_dist (mut f64) (f64.const 0.0))
  (global $g_hit_vx (mut i32) (i32.const 0))
  (global $g_hit_vy (mut i32) (i32.const 0))
  (global $g_hit_vz (mut i32) (i32.const 0))

  ;; Total ray steps this frame (cast_ray + shadow_ray combined)
  (global $g_total_steps (mut i32) (i32.const 0))

  ;; ---- Terrain height bounds for a rectangular XY region ----
  ;; Returns min terrain height via global, max as result
  ;; Samples corners + center of the region for speed
  (global $g_th_min (mut i32) (i32.const 0))
  (func $terrain_height_bounds (param $x0 i32) (param $y0 i32) (param $x1 i32) (param $y1 i32) (result i32)
    (local $h i32) (local $mn i32) (local $mx i32)
    (local $midx i32) (local $midy i32)
    i32.const 999
    local.set $mn
    i32.const -999
    local.set $mx
    ;; Sample the 4 corners + center (5 samples for speed)
    ;; Corner (x0, y0)
    local.get $x0
    local.get $y0
    call $terrain_height
    local.set $h
    local.get $h
    local.get $mn
    i32.lt_s
    if local.get $h local.set $mn end
    local.get $h
    local.get $mx
    i32.gt_s
    if local.get $h local.set $mx end
    ;; Corner (x1, y0)
    local.get $x1
    local.get $y0
    call $terrain_height
    local.set $h
    local.get $h
    local.get $mn
    i32.lt_s
    if local.get $h local.set $mn end
    local.get $h
    local.get $mx
    i32.gt_s
    if local.get $h local.set $mx end
    ;; Corner (x0, y1)
    local.get $x0
    local.get $y1
    call $terrain_height
    local.set $h
    local.get $h
    local.get $mn
    i32.lt_s
    if local.get $h local.set $mn end
    local.get $h
    local.get $mx
    i32.gt_s
    if local.get $h local.set $mx end
    ;; Corner (x1, y1)
    local.get $x1
    local.get $y1
    call $terrain_height
    local.set $h
    local.get $h
    local.get $mn
    i32.lt_s
    if local.get $h local.set $mn end
    local.get $h
    local.get $mx
    i32.gt_s
    if local.get $h local.set $mx end
    ;; Center
    local.get $x0
    local.get $x1
    i32.add
    i32.const 1
    i32.shr_s
    local.set $midx
    local.get $y0
    local.get $y1
    i32.add
    i32.const 1
    i32.shr_s
    local.set $midy
    local.get $midx
    local.get $midy
    call $terrain_height
    local.set $h
    local.get $h
    local.get $mn
    i32.lt_s
    if local.get $h local.set $mn end
    local.get $h
    local.get $mx
    i32.gt_s
    if local.get $h local.set $mx end
    ;; Apply safety margin: height can vary by ±3 between samples (hillier terrain)
    local.get $mn
    i32.const 3
    i32.sub
    local.tee $mn
    i32.const 1
    i32.lt_s
    if i32.const 1 local.set $mn end
    local.get $mn
    global.set $g_th_min
    local.get $mx
    i32.const 3
    i32.add
    local.tee $mx
    i32.const 22
    i32.gt_s
    if i32.const 22 local.set $mx end
    local.get $mx
  )

  ;; ---- Check if region might have modifications ----
  ;; Returns 1 if any modification falls within the bounding box
  (func $has_mods_in_region (param $x0 i32) (param $y0 i32) (param $z0 i32)
                            (param $x1 i32) (param $y1 i32) (param $z1 i32) (result i32)
    (local $i i32) (local $count i32) (local $addr i32)
    (local $mx i32) (local $my i32) (local $mz i32)
    i32.const 0x10390
    i32.load
    local.set $count
    local.get $count
    i32.eqz
    if
      i32.const 0
      return
    end
    i32.const 0
    local.set $i
    block $done
      loop $lp
        local.get $i
        local.get $count
        i32.ge_u
        br_if $done
        i32.const 0x10C00
        local.get $i
        i32.const 16
        i32.mul
        i32.add
        local.set $addr
        local.get $addr
        i32.load
        local.set $mx
        local.get $addr
        i32.const 4
        i32.add
        i32.load
        local.set $my
        local.get $addr
        i32.const 8
        i32.add
        i32.load
        local.set $mz
        ;; Check if within bounding box
        local.get $mx
        local.get $x0
        i32.ge_s
        local.get $mx
        local.get $x1
        i32.le_s
        i32.and
        local.get $my
        local.get $y0
        i32.ge_s
        i32.and
        local.get $my
        local.get $y1
        i32.le_s
        i32.and
        local.get $mz
        local.get $z0
        i32.ge_s
        i32.and
        local.get $mz
        local.get $z1
        i32.le_s
        i32.and
        if
          i32.const 1
          return
        end
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $lp
      end
    end
    i32.const 0
  )

  ;; ---- Chunk occupancy (4×4×4) — cached with generation tag ----
  ;; Returns 0 if chunk is definitely all air, 1 if it may have solid blocks
  ;; Cache: 1024-entry direct-mapped hash table at 0x1A000
  ;; Entry format: [tag: i32, result: i32] (8 bytes)
  ;; Tag: (gen << 24) | ((cx & 0xFF) << 16) | ((cy & 0xFF) << 8) | (cz & 0xFF)
  (func $chunk_occupied (param $cx i32) (param $cy i32) (param $cz i32) (result i32)
    (local $z_lo i32) (local $z_hi i32)
    (local $x0 i32) (local $y0 i32)
    (local $th_max i32) (local $th_min i32)
    (local $tag i32) (local $hash i32) (local $addr i32) (local $result i32)

    ;; ---- Cache lookup ----
    ;; Build tag: (gen << 24) | ((cx & 0xFF) << 16) | ((cy & 0xFF) << 8) | (cz & 0xFF)
    global.get $g_cache_gen
    i32.const 24
    i32.shl
    local.get $cx
    i32.const 0xFF
    i32.and
    i32.const 16
    i32.shl
    i32.or
    local.get $cy
    i32.const 0xFF
    i32.and
    i32.const 8
    i32.shl
    i32.or
    local.get $cz
    i32.const 0xFF
    i32.and
    i32.or
    local.set $tag

    ;; Hash index: ((cx * 73) ^ (cy * 157) ^ (cz * 31)) & 1023
    local.get $cx
    i32.const 73
    i32.mul
    local.get $cy
    i32.const 157
    i32.mul
    i32.xor
    local.get $cz
    i32.const 31
    i32.mul
    i32.xor
    i32.const 1023
    i32.and
    local.set $hash

    ;; Cache address: 0x1A000 + hash * 8
    i32.const 0x1A000
    local.get $hash
    i32.const 3
    i32.shl
    i32.add
    local.set $addr

    ;; Check tag match
    local.get $addr
    i32.load
    local.get $tag
    i32.eq
    if
      ;; Cache hit — return stored result
      local.get $addr
      i32.const 4
      i32.add
      i32.load
      return
    end

    ;; ---- Cache miss: compute occupancy ----
    ;; World Z range of this chunk
    local.get $cz
    i32.const 2
    i32.shl
    local.set $z_lo
    local.get $z_lo
    i32.const 3
    i32.add
    local.set $z_hi

    ;; Below world (z_lo < 0): always solid (bedrock)
    local.get $z_lo
    i32.const 0
    i32.lt_s
    if
      ;; Store in cache and return
      local.get $addr
      local.get $tag
      i32.store
      local.get $addr
      i32.const 4
      i32.add
      i32.const 1
      i32.store
      i32.const 1
      return
    end

    ;; Far above any possible terrain+trees (max terrain=22, trees add 6 → 28)
    local.get $z_lo
    i32.const 29
    i32.gt_s
    if
      ;; Still check for modifications up here
      local.get $cx
      i32.const 2
      i32.shl
      local.get $cy
      i32.const 2
      i32.shl
      local.get $z_lo
      local.get $cx
      i32.const 2
      i32.shl
      i32.const 3
      i32.add
      local.get $cy
      i32.const 2
      i32.shl
      i32.const 3
      i32.add
      local.get $z_hi
      call $has_mods_in_region
      local.set $result
      ;; Store in cache and return
      local.get $addr
      local.get $tag
      i32.store
      local.get $addr
      i32.const 4
      i32.add
      local.get $result
      i32.store
      local.get $result
      return
    end

    ;; World XY range of this chunk
    local.get $cx
    i32.const 2
    i32.shl
    local.set $x0
    local.get $cy
    i32.const 2
    i32.shl
    local.set $y0

    ;; Get terrain height bounds for this 4×4 region
    local.get $x0
    local.get $y0
    local.get $x0
    i32.const 3
    i32.add
    local.get $y0
    i32.const 3
    i32.add
    call $terrain_height_bounds
    local.set $th_max
    global.get $g_th_min
    local.set $th_min

    ;; Check if chunk Z range intersects terrain
    ;; Terrain fills from Z=0 to Z=th (surface). Below surface = solid.
    ;; So terrain occupies Z <= th_max for any column.
    ;; Trees can extend up to th_max + 6.
    ;; Water at Z <= 7 when th <= 7.

    ;; If chunk bottom is above terrain+trees+margin, it's empty (just air)
    local.get $z_lo
    local.get $th_max
    i32.const 7  ;; tree height (6) + 1 safety margin
    i32.add
    i32.gt_s
    if
      ;; Might still have water if z_lo <= 7
      local.get $z_lo
      i32.const 8
      i32.le_s
      local.get $th_min
      i32.const 8
      i32.le_s
      i32.and
      if
        ;; Store in cache and return occupied
        local.get $addr
        local.get $tag
        i32.store
        local.get $addr
        i32.const 4
        i32.add
        i32.const 1
        i32.store
        i32.const 1
        return
      end
      ;; Check modifications
      local.get $x0
      local.get $y0
      local.get $z_lo
      local.get $x0
      i32.const 3
      i32.add
      local.get $y0
      i32.const 3
      i32.add
      local.get $z_hi
      call $has_mods_in_region
      local.set $result
      ;; Store in cache and return
      local.get $addr
      local.get $tag
      i32.store
      local.get $addr
      i32.const 4
      i32.add
      local.get $result
      i32.store
      local.get $result
      return
    end

    ;; Chunk overlaps potential terrain/tree/water zone → occupied
    ;; (Conservative: some chunks might be empty but we say occupied)
    ;; Store in cache and return
    local.get $addr
    local.get $tag
    i32.store
    local.get $addr
    i32.const 4
    i32.add
    i32.const 1
    i32.store
    i32.const 1
  )

  ;; ---- Mega-chunk occupancy (16×16×16 voxels) — cached ----
  ;; Returns 0 if mega-chunk is definitely all air, 1 if may have solids
  ;; Cache: 256-entry direct-mapped hash table at 0x1C000
  ;; Entry format: [tag: i32, result: i32] (8 bytes)
  (func $mega_chunk_occupied (param $mcx i32) (param $mcy i32) (param $mcz i32) (result i32)
    (local $z_lo i32) (local $z_hi i32)
    (local $x0 i32) (local $y0 i32)
    (local $th_max i32) (local $th_min i32)
    (local $tag i32) (local $hash i32) (local $addr i32) (local $result i32)

    ;; ---- Cache lookup ----
    ;; Build tag: (gen << 24) | ((mcx & 0xFF) << 16) | ((mcy & 0xFF) << 8) | (mcz & 0xFF)
    global.get $g_cache_gen
    i32.const 24
    i32.shl
    local.get $mcx
    i32.const 0xFF
    i32.and
    i32.const 16
    i32.shl
    i32.or
    local.get $mcy
    i32.const 0xFF
    i32.and
    i32.const 8
    i32.shl
    i32.or
    local.get $mcz
    i32.const 0xFF
    i32.and
    i32.or
    local.set $tag

    ;; Hash index: ((mcx * 73) ^ (mcy * 157) ^ (mcz * 31)) & 255
    local.get $mcx
    i32.const 73
    i32.mul
    local.get $mcy
    i32.const 157
    i32.mul
    i32.xor
    local.get $mcz
    i32.const 31
    i32.mul
    i32.xor
    i32.const 255
    i32.and
    local.set $hash

    ;; Cache address: 0x1C000 + hash * 8
    i32.const 0x1C000
    local.get $hash
    i32.const 3
    i32.shl
    i32.add
    local.set $addr

    ;; Check tag match
    local.get $addr
    i32.load
    local.get $tag
    i32.eq
    if
      ;; Cache hit — return stored result
      local.get $addr
      i32.const 4
      i32.add
      i32.load
      return
    end

    ;; ---- Cache miss: compute occupancy ----
    ;; World Z range of this mega-chunk (16 voxels)
    local.get $mcz
    i32.const 4
    i32.shl
    local.set $z_lo
    local.get $z_lo
    i32.const 15
    i32.add
    local.set $z_hi

    ;; Below world: always solid
    local.get $z_lo
    i32.const 0
    i32.lt_s
    if
      local.get $addr
      local.get $tag
      i32.store
      local.get $addr
      i32.const 4
      i32.add
      i32.const 1
      i32.store
      i32.const 1
      return
    end

    ;; Far above everything (max terrain=22, trees +6 → 28)
    local.get $z_lo
    i32.const 29
    i32.gt_s
    if
      ;; Check modifications
      local.get $mcx
      i32.const 4
      i32.shl
      local.get $mcy
      i32.const 4
      i32.shl
      local.get $z_lo
      local.get $mcx
      i32.const 4
      i32.shl
      i32.const 15
      i32.add
      local.get $mcy
      i32.const 4
      i32.shl
      i32.const 15
      i32.add
      local.get $z_hi
      call $has_mods_in_region
      local.set $result
      local.get $addr
      local.get $tag
      i32.store
      local.get $addr
      i32.const 4
      i32.add
      local.get $result
      i32.store
      local.get $result
      return
    end

    ;; World XY range
    local.get $mcx
    i32.const 4
    i32.shl
    local.set $x0
    local.get $mcy
    i32.const 4
    i32.shl
    local.set $y0

    ;; Get terrain height bounds for 16×16 region
    local.get $x0
    local.get $y0
    local.get $x0
    i32.const 15
    i32.add
    local.get $y0
    i32.const 15
    i32.add
    call $terrain_height_bounds
    local.set $th_max
    global.get $g_th_min
    local.set $th_min

    ;; If mega-chunk bottom is above terrain+trees+margin → empty
    local.get $z_lo
    local.get $th_max
    i32.const 7
    i32.add
    i32.gt_s
    if
      ;; Water check (water at Z<=7)
      local.get $z_lo
      i32.const 8
      i32.le_s
      local.get $th_min
      i32.const 8
      i32.le_s
      i32.and
      if
        local.get $addr
        local.get $tag
        i32.store
        local.get $addr
        i32.const 4
        i32.add
        i32.const 1
        i32.store
        i32.const 1
        return
      end
      ;; Modification check
      local.get $x0
      local.get $y0
      local.get $z_lo
      local.get $x0
      i32.const 15
      i32.add
      local.get $y0
      i32.const 15
      i32.add
      local.get $z_hi
      call $has_mods_in_region
      local.set $result
      local.get $addr
      local.get $tag
      i32.store
      local.get $addr
      i32.const 4
      i32.add
      local.get $result
      i32.store
      local.get $result
      return
    end

    ;; Overlaps terrain zone → occupied
    local.get $addr
    local.get $tag
    i32.store
    local.get $addr
    i32.const 4
    i32.add
    i32.const 1
    i32.store
    i32.const 1
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
  ;; cast_ray — Multi-level cached octree 3D DDA
  ;; Three-level skip hierarchy (4×4 and 16×16 cached):
  ;;   1. Mega-chunk (16×16×16): skip large empty volumes (cached)
  ;;   2. Chunk (4×4×4): skip medium empty regions (cached)
  ;;   3. Fine voxel DDA: per-block stepping in occupied chunks
  ;; Max distance: 128 blocks, max steps: 300
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
    (local $mcx i32) (local $mcy i32) (local $mcz i32)
    (local $mega_occ i32)
    (local $skip_size i32)

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

    ;; ---- EARLY SKY EXIT ----
    ;; If ray origin is above max terrain+tree height (Z > 29) and ray goes up,
    ;; there's nothing to hit — skip expensive traversal entirely.
    local.get $vz
    i32.const 30
    i32.gt_s
    local.get $dz
    f64.const 0.0
    f64.ge
    i32.and
    if
      ;; No hit — sky
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
      return
    end

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

    ;; Main traversal loop — max 300 steps (multi-level skipping keeps this fast)
    block $done
      loop $lp
        local.get $steps
        i32.const 300
        i32.ge_u
        br_if $done

        ;; ---- MEGA-CHUNK SKIP CHECK (16×16×16) ----
        local.get $vx
        i32.const 16
        call $floor_div
        local.set $mcx
        local.get $vy
        i32.const 16
        call $floor_div
        local.set $mcy
        local.get $vz
        i32.const 16
        call $floor_div
        local.set $mcz

        local.get $mcx
        local.get $mcy
        local.get $mcz
        call $mega_chunk_occupied
        local.set $mega_occ

        local.get $mega_occ
        i32.eqz
        if
          ;; EMPTY MEGA-CHUNK: skip to mega-chunk boundary (jump 1-16 voxels)
          f64.const 999999.0
          local.set $t_skip_x
          local.get $step_x
          i32.const 1
          i32.eq
          if
            local.get $mcx
            i32.const 1
            i32.add
            i32.const 4
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
            local.get $mcx
            i32.const 4
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
            local.get $mcy
            i32.const 1
            i32.add
            i32.const 4
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
            local.get $mcy
            i32.const 4
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
            local.get $mcz
            i32.const 1
            i32.add
            i32.const 4
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
          f64.const 128.0
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

          ;; Bail if out of Z range (terrain max ~20, lowered from 40 for faster sky exit)
          local.get $vz
          i32.const -1
          i32.lt_s
          br_if $done
          local.get $vz
          i32.const 24
          i32.gt_s
          if
            ;; Above terrain: if going up, bail immediately
            local.get $step_z
            i32.const -1
            i32.ne
            br_if $done
          end

          local.get $steps
          i32.const 1
          i32.add
          local.set $steps
          global.get $g_total_steps
          i32.const 1
          i32.add
          global.set $g_total_steps
          br $lp
        end

        ;; ---- CHUNK SKIP CHECK (4×4×4) ----
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

        local.get $cx
        local.get $cy
        local.get $cz
        call $chunk_occupied
        local.set $chunk_occ

        local.get $chunk_occ
        i32.eqz
        if
          ;; EMPTY CHUNK: skip to chunk boundary (jump 1-4 voxels at once)
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
          f64.const 128.0
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

          ;; Bail if out of Z range (terrain max ~20, lowered from 40 for faster sky exit)
          local.get $vz
          i32.const -1
          i32.lt_s
          br_if $done
          local.get $vz
          i32.const 24
          i32.gt_s
          if
            ;; Above terrain: if going up, bail immediately
            local.get $step_z
            i32.const -1
            i32.ne
            br_if $done
          end

          local.get $steps
          i32.const 1
          i32.add
          local.set $steps
          global.get $g_total_steps
          i32.const 1
          i32.add
          global.set $g_total_steps
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
        f64.const 128.0
        f64.gt
        br_if $done
        local.get $vz
        i32.const -1
        i32.lt_s
        br_if $done
        local.get $vz
        i32.const 32
        i32.gt_s
        if
          ;; Above terrain: if going up, bail immediately
          local.get $step_z
          i32.const -1
          i32.ne
          br_if $done
        end

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
        global.get $g_total_steps
        i32.const 1
        i32.add
        global.set $g_total_steps
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
  ;; SHADOW RAY — Octree-accelerated DDA to check light occlusion
  ;; Returns: 0 = in shadow, 1 = lit
  ;; Uses 2-level octree skip (mega 16×16×16, chunk 4×4×4) for
  ;; proper long-distance shadow casting (up to 64 blocks)
  ;; Works for both sun and moon directions
  ;; ============================================================
  (func $shadow_ray (param $ox f64) (param $oy f64) (param $oz f64)
                     (param $sdx f64) (param $sdy f64) (param $sdz f64)
                     (result i32)
    (local $vx i32) (local $vy i32) (local $vz i32)
    (local $step_x i32) (local $step_y i32) (local $step_z i32)
    (local $t_max_x f64) (local $t_max_y f64) (local $t_max_z f64)
    (local $t_delta_x f64) (local $t_delta_y f64) (local $t_delta_z f64)
    (local $steps i32) (local $block i32)
    (local $inv_dx f64) (local $inv_dy f64) (local $inv_dz f64)
    (local $t_cur f64)
    (local $cx i32) (local $cy i32) (local $cz i32)
    (local $mcx i32) (local $mcy i32) (local $mcz i32)
    (local $chunk_occ i32) (local $mega_occ i32)
    (local $t_skip_x f64) (local $t_skip_y f64) (local $t_skip_z f64)
    (local $t_skip f64)

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

    ;; Inverse direction (precompute once)
    local.get $sdx
    f64.abs
    f64.const 0.000001
    f64.gt
    if (result f64)
      f64.const 1.0
      local.get $sdx
      f64.div
    else
      f64.const 999999.0
    end
    local.set $inv_dx
    local.get $sdy
    f64.abs
    f64.const 0.000001
    f64.gt
    if (result f64)
      f64.const 1.0
      local.get $sdy
      f64.div
    else
      f64.const 999999.0
    end
    local.set $inv_dy
    local.get $sdz
    f64.abs
    f64.const 0.000001
    f64.gt
    if (result f64)
      f64.const 1.0
      local.get $sdz
      f64.div
    else
      f64.const 999999.0
    end
    local.set $inv_dz

    ;; Step direction
    local.get $sdx
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
      local.get $sdx
      f64.div
      local.set $t_max_x
      f64.const 1.0
      local.get $sdx
      f64.div
      local.set $t_delta_x
    else
      local.get $sdx
      f64.const 0.0
      f64.lt
      if
        i32.const -1
        local.set $step_x
        local.get $vx
        f64.convert_i32_s
        local.get $ox
        f64.sub
        local.get $sdx
        f64.div
        local.set $t_max_x
        f64.const -1.0
        local.get $sdx
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

    ;; Step direction Y
    local.get $sdy
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
      local.get $sdy
      f64.div
      local.set $t_max_y
      f64.const 1.0
      local.get $sdy
      f64.div
      local.set $t_delta_y
    else
      local.get $sdy
      f64.const 0.0
      f64.lt
      if
        i32.const -1
        local.set $step_y
        local.get $vy
        f64.convert_i32_s
        local.get $oy
        f64.sub
        local.get $sdy
        f64.div
        local.set $t_max_y
        f64.const -1.0
        local.get $sdy
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

    ;; Step direction Z
    local.get $sdz
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
      local.get $sdz
      f64.div
      local.set $t_max_z
      f64.const 1.0
      local.get $sdz
      f64.div
      local.set $t_delta_z
    else
      local.get $sdz
      f64.const 0.0
      f64.lt
      if
        i32.const -1
        local.set $step_z
        local.get $vz
        f64.convert_i32_s
        local.get $oz
        f64.sub
        local.get $sdz
        f64.div
        local.set $t_max_z
        f64.const -1.0
        local.get $sdz
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

    f64.const 0.0
    local.set $t_cur
    i32.const 0
    local.set $steps

    block $done
      loop $lp
        local.get $steps
        i32.const 200
        i32.ge_u
        br_if $done

        ;; ---- MEGA-CHUNK SKIP (16×16×16) ----
        local.get $vx
        i32.const 16
        call $floor_div
        local.set $mcx
        local.get $vy
        i32.const 16
        call $floor_div
        local.set $mcy
        local.get $vz
        i32.const 16
        call $floor_div
        local.set $mcz

        local.get $mcx
        local.get $mcy
        local.get $mcz
        call $mega_chunk_occupied
        local.set $mega_occ

        local.get $mega_occ
        i32.eqz
        if
          ;; EMPTY MEGA-CHUNK: skip to boundary
          f64.const 999999.0
          local.set $t_skip_x
          local.get $step_x
          i32.const 1
          i32.eq
          if
            local.get $mcx
            i32.const 1
            i32.add
            i32.const 4
            i32.shl
            f64.convert_i32_s
            local.get $ox
            f64.sub
            local.get $t_cur
            local.get $sdx
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
            local.get $mcx
            i32.const 4
            i32.shl
            f64.convert_i32_s
            local.get $ox
            f64.sub
            local.get $t_cur
            local.get $sdx
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
            local.get $mcy
            i32.const 1
            i32.add
            i32.const 4
            i32.shl
            f64.convert_i32_s
            local.get $oy
            f64.sub
            local.get $t_cur
            local.get $sdy
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
            local.get $mcy
            i32.const 4
            i32.shl
            f64.convert_i32_s
            local.get $oy
            f64.sub
            local.get $t_cur
            local.get $sdy
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
            local.get $mcz
            i32.const 1
            i32.add
            i32.const 4
            i32.shl
            f64.convert_i32_s
            local.get $oz
            f64.sub
            local.get $t_cur
            local.get $sdz
            f64.mul
            f64.sub
            local.get $inv_dz
            f64.mul
            local.get $t_cur
            f64.add
            local.set $t_skip_z
          end

          ;; Min exit t
          local.get $t_skip_x
          local.set $t_skip
          local.get $t_skip_y
          local.get $t_skip
          f64.lt
          if
            local.get $t_skip_y
            local.set $t_skip
          end
          local.get $t_skip_z
          local.get $t_skip
          f64.lt
          if
            local.get $t_skip_z
            local.set $t_skip
          end

          local.get $t_skip
          f64.const 0.001
          f64.add
          local.set $t_cur

          ;; Bail if too far
          local.get $t_cur
          f64.const 64.0
          f64.gt
          br_if $done

          ;; Recompute voxel from t
          local.get $ox
          local.get $sdx
          local.get $t_cur
          f64.mul
          f64.add
          f64.floor
          i32.trunc_f64_s
          local.set $vx
          local.get $oy
          local.get $sdy
          local.get $t_cur
          f64.mul
          f64.add
          f64.floor
          i32.trunc_f64_s
          local.set $vy
          local.get $oz
          local.get $sdz
          local.get $t_cur
          f64.mul
          f64.add
          f64.floor
          i32.trunc_f64_s
          local.set $vz

          ;; Recompute t_max from new position
          local.get $sdx
          f64.const 0.0
          f64.gt
          if
            local.get $vx
            f64.convert_i32_s
            f64.const 1.0
            f64.add
            local.get $ox
            f64.sub
            local.get $sdx
            local.get $t_cur
            f64.mul
            f64.sub
            local.get $inv_dx
            f64.mul
            local.get $t_cur
            f64.add
            local.set $t_max_x
          else
            local.get $sdx
            f64.const 0.0
            f64.lt
            if
              local.get $vx
              f64.convert_i32_s
              local.get $ox
              f64.sub
              local.get $sdx
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
          local.get $sdy
          f64.const 0.0
          f64.gt
          if
            local.get $vy
            f64.convert_i32_s
            f64.const 1.0
            f64.add
            local.get $oy
            f64.sub
            local.get $sdy
            local.get $t_cur
            f64.mul
            f64.sub
            local.get $inv_dy
            f64.mul
            local.get $t_cur
            f64.add
            local.set $t_max_y
          else
            local.get $sdy
            f64.const 0.0
            f64.lt
            if
              local.get $vy
              f64.convert_i32_s
              local.get $oy
              f64.sub
              local.get $sdy
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
          local.get $sdz
          f64.const 0.0
          f64.gt
          if
            local.get $vz
            f64.convert_i32_s
            f64.const 1.0
            f64.add
            local.get $oz
            f64.sub
            local.get $sdz
            local.get $t_cur
            f64.mul
            f64.sub
            local.get $inv_dz
            f64.mul
            local.get $t_cur
            f64.add
            local.set $t_max_z
          else
            local.get $sdz
            f64.const 0.0
            f64.lt
            if
              local.get $vz
              f64.convert_i32_s
              local.get $oz
              f64.sub
              local.get $sdz
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
          i32.const 40
          i32.gt_s
          br_if $done

          local.get $steps
          i32.const 1
          i32.add
          local.set $steps
          global.get $g_total_steps
          i32.const 1
          i32.add
          global.set $g_total_steps
          br $lp
        end

        ;; ---- CHUNK SKIP (4×4×4) ----
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

        local.get $cx
        local.get $cy
        local.get $cz
        call $chunk_occupied
        local.set $chunk_occ

        local.get $chunk_occ
        i32.eqz
        if
          ;; EMPTY CHUNK: skip to boundary
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
            local.get $sdx
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
            local.get $sdx
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
            local.get $sdy
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
            local.get $sdy
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
            local.get $sdz
            f64.mul
            f64.sub
            local.get $inv_dz
            f64.mul
            local.get $t_cur
            f64.add
            local.set $t_skip_z
          end

          ;; Min exit t
          local.get $t_skip_x
          local.set $t_skip
          local.get $t_skip_y
          local.get $t_skip
          f64.lt
          if
            local.get $t_skip_y
            local.set $t_skip
          end
          local.get $t_skip_z
          local.get $t_skip
          f64.lt
          if
            local.get $t_skip_z
            local.set $t_skip
          end

          local.get $t_skip
          f64.const 0.001
          f64.add
          local.set $t_cur

          ;; Bail if too far
          local.get $t_cur
          f64.const 64.0
          f64.gt
          br_if $done

          ;; Recompute voxel from t
          local.get $ox
          local.get $sdx
          local.get $t_cur
          f64.mul
          f64.add
          f64.floor
          i32.trunc_f64_s
          local.set $vx
          local.get $oy
          local.get $sdy
          local.get $t_cur
          f64.mul
          f64.add
          f64.floor
          i32.trunc_f64_s
          local.set $vy
          local.get $oz
          local.get $sdz
          local.get $t_cur
          f64.mul
          f64.add
          f64.floor
          i32.trunc_f64_s
          local.set $vz

          ;; Recompute t_max from new position
          local.get $sdx
          f64.const 0.0
          f64.gt
          if
            local.get $vx
            f64.convert_i32_s
            f64.const 1.0
            f64.add
            local.get $ox
            f64.sub
            local.get $sdx
            local.get $t_cur
            f64.mul
            f64.sub
            local.get $inv_dx
            f64.mul
            local.get $t_cur
            f64.add
            local.set $t_max_x
          else
            local.get $sdx
            f64.const 0.0
            f64.lt
            if
              local.get $vx
              f64.convert_i32_s
              local.get $ox
              f64.sub
              local.get $sdx
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
          local.get $sdy
          f64.const 0.0
          f64.gt
          if
            local.get $vy
            f64.convert_i32_s
            f64.const 1.0
            f64.add
            local.get $oy
            f64.sub
            local.get $sdy
            local.get $t_cur
            f64.mul
            f64.sub
            local.get $inv_dy
            f64.mul
            local.get $t_cur
            f64.add
            local.set $t_max_y
          else
            local.get $sdy
            f64.const 0.0
            f64.lt
            if
              local.get $vy
              f64.convert_i32_s
              local.get $oy
              f64.sub
              local.get $sdy
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
          local.get $sdz
          f64.const 0.0
          f64.gt
          if
            local.get $vz
            f64.convert_i32_s
            f64.const 1.0
            f64.add
            local.get $oz
            f64.sub
            local.get $sdz
            local.get $t_cur
            f64.mul
            f64.sub
            local.get $inv_dz
            f64.mul
            local.get $t_cur
            f64.add
            local.set $t_max_z
          else
            local.get $sdz
            f64.const 0.0
            f64.lt
            if
              local.get $vz
              f64.convert_i32_s
              local.get $oz
              f64.sub
              local.get $sdz
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
          i32.const 40
          i32.gt_s
          br_if $done

          local.get $steps
          i32.const 1
          i32.add
          local.set $steps
          global.get $g_total_steps
          i32.const 1
          i32.add
          global.set $g_total_steps
          br $lp
        end

        ;; ---- OCCUPIED: fine DDA step (single voxel) ----
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
          end
        end

        ;; Bail if too far or out of Z range
        local.get $t_cur
        f64.const 64.0
        f64.gt
        br_if $done
        local.get $vz
        i32.const -1
        i32.lt_s
        br_if $done
        local.get $vz
        i32.const 40
        i32.gt_s
        br_if $done

        ;; Check block at new voxel
        local.get $vx
        local.get $vy
        local.get $vz
        call $get_block
        local.set $block
        local.get $block
        i32.const 0
        i32.ne
        local.get $block
        i32.const 5  ;; water is transparent to light
        i32.ne
        i32.and
        if
          ;; Hit solid block — in shadow
          i32.const 0
          return
        end

        local.get $steps
        i32.const 1
        i32.add
        local.set $steps
        global.get $g_total_steps
        i32.const 1
        i32.add
        global.set $g_total_steps
        br $lp
      end
    end

    ;; Reached max steps or distance without hitting — consider lit
    i32.const 1
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
  ;; RGB24 to palette index via 32KB LUT with dithering
  ;; LUT at 0x20000: 32×32×32 RGB cube → nearest palette index
  ;; 8 materials × 32 lighting levels = 256 palette entries
  ;; Palette + LUT built entirely in WAT by $init_palette
  ;; Dithering modes: 0=RAW, 1=Bayer ordered, 2=Floyd-Steinberg error diffusion
  ;; F-S error buffer at 0x28000: 2 rows × 320 × 3 channels × 2 bytes (i16) = 3840 bytes
  ;;   Row 0 (current): 0x28000 .. 0x28000 + 1919
  ;;   Row 1 (next):    0x28780 .. 0x28780 + 1919
  ;;   Each pixel = 6 bytes: R_err(i16), G_err(i16), B_err(i16)
  ;; ============================================================

  ;; Clear Floyd-Steinberg error buffer (both rows, 3840 bytes at 0x28000)
  (func $fs_clear_buf
    (local $i i32)
    i32.const 0
    local.set $i
    block $done
      loop $clr
        local.get $i
        i32.const 3840
        i32.ge_u
        br_if $done
        i32.const 0x28000
        local.get $i
        i32.add
        i32.const 0
        i32.store
        local.get $i
        i32.const 4
        i32.add
        local.set $i
        br $clr
      end
    end
  )

  ;; Swap F-S error buffer rows: copy row1 → row0, clear row1
  ;; Called at the start of each scanline when F-S is active
  (func $fs_swap_rows
    (local $i i32)
    i32.const 0
    local.set $i
    block $done
      loop $cpy
        local.get $i
        i32.const 1920
        i32.ge_u
        br_if $done
        ;; row0[i] = row1[i]
        i32.const 0x28000
        local.get $i
        i32.add
        i32.const 0x28780
        local.get $i
        i32.add
        i32.load
        i32.store
        ;; clear row1[i]
        i32.const 0x28780
        local.get $i
        i32.add
        i32.const 0
        i32.store
        local.get $i
        i32.const 4
        i32.add
        local.set $i
        br $cpy
      end
    end
  )

  ;; Add i16 error value to F-S buffer at given address (clamped i16 add)
  (func $fs_add_err (param $addr i32) (param $val i32)
    (local $cur i32)
    local.get $addr
    i32.load16_s
    local.get $val
    i32.add
    local.tee $cur
    ;; Clamp to [-255, 255] to prevent overflow accumulation
    i32.const -255
    i32.lt_s
    if  i32.const -255  local.set $cur  end
    local.get $cur
    i32.const 255
    i32.gt_s
    if  i32.const 255  local.set $cur  end
    local.get $addr
    local.get $cur
    i32.store16
  )

  (func $rgb_to_rgbl_dither (param $px i32) (param $py i32) (param $r i32) (param $g i32) (param $b i32) (result i32)
    (local $bx i32) (local $by i32) (local $idx i32) (local $threshold i32)
    (local $mode i32)
    (local $err_addr i32) (local $pal_idx i32) (local $pal_addr i32)
    (local $qr i32) (local $qg i32) (local $qb i32)
    (local $er i32) (local $eg i32) (local $eb i32)
    (local $nr_addr i32)

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

    ;; Read dither mode from control block offset 0x11
    ;; 0=RAW, 1=Bayer ordered, 2=Floyd-Steinberg
    i32.const 0x11
    i32.load8_u
    local.set $mode

    local.get $mode
    i32.const 2
    i32.eq
    if
      ;; ---- Floyd-Steinberg error diffusion ----
      ;; Read accumulated error for this pixel from row0 of error buffer
      ;; Error buffer row0 at 0x28000, each pixel = 6 bytes (3 × i16)
      local.get $px
      i32.const 6
      i32.mul
      i32.const 0x28000
      i32.add
      local.set $err_addr

      ;; Add error to input RGB
      local.get $r
      local.get $err_addr
      i32.load16_s
      i32.add
      local.set $r
      local.get $g
      local.get $err_addr
      i32.const 2
      i32.add
      i32.load16_s
      i32.add
      local.set $g
      local.get $b
      local.get $err_addr
      i32.const 4
      i32.add
      i32.load16_s
      i32.add
      local.set $b

      ;; Re-clamp after adding error
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

      ;; Quantize via LUT
      i32.const 0x20000
      local.get $r
      i32.const 3
      i32.shr_u
      i32.const 10
      i32.shl
      local.get $g
      i32.const 3
      i32.shr_u
      i32.const 5
      i32.shl
      i32.or
      local.get $b
      i32.const 3
      i32.shr_u
      i32.or
      i32.add
      i32.load8_u
      local.set $pal_idx

      ;; Look up actual palette RGB to compute quantization error
      ;; Palette at 0x0040, each entry = 3 bytes (R, G, B)
      local.get $pal_idx
      i32.const 3
      i32.mul
      i32.const 0x0040
      i32.add
      local.set $pal_addr

      local.get $pal_addr
      i32.load8_u
      local.set $qr
      local.get $pal_addr
      i32.const 1
      i32.add
      i32.load8_u
      local.set $qg
      local.get $pal_addr
      i32.const 2
      i32.add
      i32.load8_u
      local.set $qb

      ;; Compute error: er = input_r - quantized_r (etc.)
      local.get $r
      local.get $qr
      i32.sub
      local.set $er
      local.get $g
      local.get $qg
      i32.sub
      local.set $eg
      local.get $b
      local.get $qb
      i32.sub
      local.set $eb

      ;; Distribute error using Floyd-Steinberg coefficients:
      ;;   right (+1, 0): 7/16
      ;;   below-left (-1, +1): 3/16
      ;;   below (0, +1): 5/16
      ;;   below-right (+1, +1): 1/16

      ;; Right neighbor (px+1, py) — in row0
      local.get $px
      i32.const 319
      i32.lt_s
      if
        local.get $px
        i32.const 1
        i32.add
        i32.const 6
        i32.mul
        i32.const 0x28000
        i32.add
        local.set $nr_addr
        ;; R: er * 7 / 16
        local.get $nr_addr
        local.get $er
        i32.const 7
        i32.mul
        i32.const 16
        i32.div_s
        call $fs_add_err
        ;; G
        local.get $nr_addr
        i32.const 2
        i32.add
        local.get $eg
        i32.const 7
        i32.mul
        i32.const 16
        i32.div_s
        call $fs_add_err
        ;; B
        local.get $nr_addr
        i32.const 4
        i32.add
        local.get $eb
        i32.const 7
        i32.mul
        i32.const 16
        i32.div_s
        call $fs_add_err
      end

      ;; Below-left (px-1, py+1) — in row1
      local.get $px
      i32.const 0
      i32.gt_s
      if
        local.get $px
        i32.const 1
        i32.sub
        i32.const 6
        i32.mul
        i32.const 0x28780
        i32.add
        local.set $nr_addr
        ;; R: er * 3 / 16
        local.get $nr_addr
        local.get $er
        i32.const 3
        i32.mul
        i32.const 16
        i32.div_s
        call $fs_add_err
        ;; G
        local.get $nr_addr
        i32.const 2
        i32.add
        local.get $eg
        i32.const 3
        i32.mul
        i32.const 16
        i32.div_s
        call $fs_add_err
        ;; B
        local.get $nr_addr
        i32.const 4
        i32.add
        local.get $eb
        i32.const 3
        i32.mul
        i32.const 16
        i32.div_s
        call $fs_add_err
      end

      ;; Below (px, py+1) — in row1
      local.get $px
      i32.const 6
      i32.mul
      i32.const 0x28780
      i32.add
      local.set $nr_addr
      ;; R: er * 5 / 16
      local.get $nr_addr
      local.get $er
      i32.const 5
      i32.mul
      i32.const 16
      i32.div_s
      call $fs_add_err
      ;; G
      local.get $nr_addr
      i32.const 2
      i32.add
      local.get $eg
      i32.const 5
      i32.mul
      i32.const 16
      i32.div_s
      call $fs_add_err
      ;; B
      local.get $nr_addr
      i32.const 4
      i32.add
      local.get $eb
      i32.const 5
      i32.mul
      i32.const 16
      i32.div_s
      call $fs_add_err

      ;; Below-right (px+1, py+1) — in row1
      local.get $px
      i32.const 319
      i32.lt_s
      if
        local.get $px
        i32.const 1
        i32.add
        i32.const 6
        i32.mul
        i32.const 0x28780
        i32.add
        local.set $nr_addr
        ;; R: er * 1 / 16
        local.get $nr_addr
        local.get $er
        i32.const 16
        i32.div_s
        call $fs_add_err
        ;; G
        local.get $nr_addr
        i32.const 2
        i32.add
        local.get $eg
        i32.const 16
        i32.div_s
        call $fs_add_err
        ;; B
        local.get $nr_addr
        i32.const 4
        i32.add
        local.get $eb
        i32.const 16
        i32.div_s
        call $fs_add_err
      end

      ;; Return palette index
      local.get $pal_idx
      return
    end

    local.get $mode
    i32.const 1
    i32.eq
    if
      ;; ---- Bayer ordered dithering ----
      ;; Compute Bayer 4x4 threshold for dithering
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

      ;; Bayer 4x4 matrix stored at 0x19640 (16 bytes), written by init
      i32.const 0x19640
      local.get $idx
      i32.add
      i32.load8_u
      local.set $threshold

      ;; Add dither noise to RGB before quantization to 5-bit
      ;; threshold is 0-15, we scale to ±4 range for smooth dithering
      ;; noise = (threshold - 8) => range -8..+7
      ;; Apply to each channel before >>3 quantization
      local.get $r
      local.get $threshold
      i32.const 8
      i32.sub
      i32.add
      local.set $r
      local.get $r
      i32.const 0
      i32.lt_s
      if  i32.const 0  local.set $r  end
      local.get $r
      i32.const 255
      i32.gt_s
      if  i32.const 255  local.set $r  end

      local.get $g
      local.get $threshold
      i32.const 8
      i32.sub
      i32.add
      local.set $g
      local.get $g
      i32.const 0
      i32.lt_s
      if  i32.const 0  local.set $g  end
      local.get $g
      i32.const 255
      i32.gt_s
      if  i32.const 255  local.set $g  end

      local.get $b
      local.get $threshold
      i32.const 8
      i32.sub
      i32.add
      local.set $b
      local.get $b
      i32.const 0
      i32.lt_s
      if  i32.const 0  local.set $b  end
      local.get $b
      i32.const 255
      i32.gt_s
      if  i32.const 255  local.set $b  end
    end

    ;; LUT lookup: index = (r>>3)<<10 | (g>>3)<<5 | (b>>3)
    i32.const 0x20000
    local.get $r
    i32.const 3
    i32.shr_u
    i32.const 10
    i32.shl
    local.get $g
    i32.const 3
    i32.shr_u
    i32.const 5
    i32.shl
    i32.or
    local.get $b
    i32.const 3
    i32.shr_u
    i32.or
    i32.add
    i32.load8_u
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
    (local $shadow_lit i32) (local $sun_dot f64)
    (local $shadow_ox f64) (local $shadow_oy f64) (local $shadow_oz f64)
    (local $sunset_t i32)
    (local $sky_hr i32) (local $sky_hg i32) (local $sky_hb i32)
    (local $sky_zr i32) (local $sky_zg i32) (local $sky_zb i32)
    (local $fog_r i32) (local $fog_g i32) (local $fog_b i32)
    (local $sun_cr i32) (local $sun_cg i32) (local $sun_cb i32)
    (local $cloud_u i32) (local $cloud_v i32)
    (local $cloud_d1 i32) (local $cloud_d2 i32) (local $cloud_val i32)
    (local $cloud_r i32) (local $cloud_g i32) (local $cloud_b i32)
    (local $cloud_inv_dz f64) (local $cloud_scale f64)

    i32.const 12
    i32.load
    local.set $tick
    i32.const 0
    i32.load
    local.set $frame_ct

    ;; Reset total step counter at start of frame (before rendering)
    i32.const 0
    global.set $g_total_steps

    i32.const 0x10
    i32.load8_u
    local.set $keys
    i32.const 0x08
    i32.load8_u
    local.set $mouse_btn
    i32.const 0x103A4
    i32.load
    local.set $prev_mouse

    ;; If inventory is open, suppress movement/mouse (keep Escape for toggle)
    global.get $g_show_inv
    if
      local.get $keys
      i32.const 64  ;; preserve only bit 6 (Escape) for inventory toggle
      i32.and
      local.set $keys
      i32.const 0
      local.set $mouse_btn
    end

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

    ;; ---- Idle demo detection ----
    ;; If no keys pressed and no mouse buttons, increment idle timer
    ;; Any input resets the timer
    local.get $keys
    local.get $mouse_btn
    i32.or
    if
      ;; User is active — reset idle timer, idle angle, and flyover altitude
      ;; If we were in idle flyover, snap pz back near ground to avoid
      ;; long falls that can cause out-of-range trunc errors in raycasting
      global.get $g_idle_timer
      i32.const 180
      i32.gt_s
      if
        ;; Was in idle flyover — snap pz to ground + 1.7
        local.get $px
        f64.floor
        i32.trunc_f64_s
        local.get $py
        f64.floor
        i32.trunc_f64_s
        call $terrain_height
        f64.convert_i32_s
        f64.const 1.7
        f64.add
        local.set $pz
        f64.const 0.0
        local.set $vz
      end
      i32.const 0
      global.set $g_idle_timer
      f64.const 0.0
      global.set $g_idle_angle
      f64.const 0.0
      global.set $g_idle_alt
    else
      ;; No input — increment idle timer
      global.get $g_idle_timer
      i32.const 1
      i32.add
      global.set $g_idle_timer
    end

    ;; ---- Check if in idle demo mode (>180 frames = ~3 seconds no input) ----
    global.get $g_idle_timer
    i32.const 180
    i32.gt_s
    if
      ;; === IDLE DEMO MODE ===
      ;; Start on the ground, then gradually do a flyover
      ;; Advance idle angle smoothly
      global.get $g_idle_angle
      f64.const 0.008
      f64.add
      global.set $g_idle_angle

      ;; Gradually increase flyover altitude
      ;; Ramp up slowly: 0 at start, reaching ~15 blocks over ~10 seconds
      ;; idle_alt approaches max_alt smoothly via lerp
      ;; max_alt = 15.0, lerp factor ~0.003 per frame
      global.get $g_idle_alt
      f64.const 15.0
      global.get $g_idle_alt
      f64.sub
      f64.const 0.003
      f64.mul
      f64.add
      global.set $g_idle_alt

      ;; Set angle from idle rotation
      local.get $angle
      f64.const 0.008
      f64.add
      local.set $angle

      ;; Adjust look pitch based on flyover altitude
      ;; When on ground (alt~0): look slightly forward (look_y ~ 5, slight downward)
      ;; When flying high (alt~15): oscillate between looking down at landscape and up at sky
      ;; Transition: blend from ground-level view to flyover view
      ;; fly_frac = idle_alt / 15.0 (0..1)
      ;; ground look_y = 5 (slightly forward/down)
      ;; fly look_y = sin-based oscillation between -20 (up/sky) and +15 (down/landscape)
      global.get $g_idle_alt
      f64.const 15.0
      f64.div
      ;; fly_frac on stack (0..1), clamp to 1.0
      f64.const 1.0
      f64.min
      ;; fly_frac is on stack
      ;; fly_look = sin(idle_angle * 0.25) * 18.0 + 5.0
      ;; This oscillates between -13 (looking up) and +23 (looking down at terrain)
      global.get $g_idle_angle
      f64.const 0.25
      f64.mul
      call $sin_a
      f64.const 18.0
      f64.mul
      f64.const 5.0
      f64.add
      ;; stack: fly_frac, fly_look
      ;; ground_look = 3.0
      ;; result = ground_look + fly_frac * (fly_look - ground_look)
      ;; = 3.0 + fly_frac * (fly_look - 3.0)
      f64.const 3.0
      f64.sub
      f64.mul
      f64.const 3.0
      f64.add
      i32.trunc_f64_s
      local.set $look_y
      i32.const 0x103AC
      local.get $look_y
      i32.store

      ;; Auto-move forward slowly to explore landscape
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

      ;; Gentle forward movement
      local.get $cos_a_v
      f64.const 0.03
      f64.mul
      local.set $move_x
      local.get $sin_a_v
      f64.const 0.03
      f64.mul
      local.set $move_y

      ;; Add slight sinusoidal strafe for more interesting path
      global.get $g_idle_angle
      f64.const 0.15
      f64.mul
      call $sin_a
      f64.const 0.015
      f64.mul
      local.set $speed ;; reuse speed as temp
      local.get $move_x
      local.get $sin_a_v
      f64.neg
      local.get $speed
      f64.mul
      f64.add
      local.set $move_x
      local.get $move_y
      local.get $cos_a_v
      local.get $speed
      f64.mul
      f64.add
      local.set $move_y
    else
      ;; === NORMAL INPUT MODE ===
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

    ;; In idle flyover mode, override gravity with smooth altitude rise
    global.get $g_idle_timer
    i32.const 180
    i32.gt_s
    if
      ;; Idle flyover: target pz = ground_h + 1.7 + idle_alt
      ;; Smoothly lerp current pz toward target
      local.get $ground_h
      f64.convert_i32_s
      f64.const 1.7
      f64.add
      global.get $g_idle_alt
      f64.add
      ;; target_pz on stack
      local.get $pz
      f64.sub
      ;; (target - current) on stack
      f64.const 0.02
      f64.mul
      local.get $pz
      f64.add
      local.set $pz
      f64.const 0.0
      local.set $vz
      i32.const 1
      local.set $on_ground
    else
      ;; Normal gravity
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

    ;; Brightness curve (min 102 = ~40% moonlight at night, 2x brighter than before)
    local.get $day_phase
    i32.const 48
    i32.lt_u
    if
      i32.const 102
      local.set $day_bright
    else
      local.get $day_phase
      i32.const 80
      i32.lt_u
      if
        i32.const 102
        local.get $day_phase
        i32.const 48
        i32.sub
        i32.const 153
        i32.mul
        i32.const 32
        i32.div_u
        i32.add
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
            i32.const 102
            i32.const 208
            local.get $day_phase
            i32.sub
            i32.const 153
            i32.mul
            i32.const 32
            i32.div_u
            i32.add
            local.set $day_bright
          else
            i32.const 102
            local.set $day_bright
          end
        end
      end
    end

    ;; ============================================================
    ;; SUNSET/SUNRISE factor: 0 at full day/night, peaks at 255 during transitions
    ;; Sunrise: day_phase 48-80 (peak at 64), Sunset: day_phase 176-208 (peak at 192)
    ;; sunset_t blends sky from blue to warm orange/pink tones
    ;; ============================================================
    i32.const 0
    local.set $sunset_t

    ;; Sunrise: day_phase 48..80 → triangle peak at 64
    local.get $day_phase
    i32.const 48
    i32.ge_u
    local.get $day_phase
    i32.const 80
    i32.lt_u
    i32.and
    if
      local.get $day_phase
      i32.const 64
      i32.le_u
      if
        ;; Rising: (phase-48)*16 → 0..255
        local.get $day_phase
        i32.const 48
        i32.sub
        i32.const 16
        i32.mul
        local.set $sunset_t
      else
        ;; Falling: (80-phase)*16 → 255..0
        i32.const 80
        local.get $day_phase
        i32.sub
        i32.const 16
        i32.mul
        local.set $sunset_t
      end
    end

    ;; Sunset: day_phase 176..208 → triangle peak at 192
    local.get $day_phase
    i32.const 176
    i32.ge_u
    local.get $day_phase
    i32.const 208
    i32.lt_u
    i32.and
    if
      local.get $day_phase
      i32.const 192
      i32.le_u
      if
        ;; Rising: (phase-176)*16 → 0..255
        local.get $day_phase
        i32.const 176
        i32.sub
        i32.const 16
        i32.mul
        local.set $sunset_t
      else
        ;; Falling: (208-phase)*16 → 255..0
        i32.const 208
        local.get $day_phase
        i32.sub
        i32.const 16
        i32.mul
        local.set $sunset_t
      end
    end

    ;; Clamp sunset_t to 255
    local.get $sunset_t
    i32.const 255
    i32.gt_s
    if  i32.const 255  local.set $sunset_t  end

    ;; ============================================================
    ;; Precompute sky colors with sunset blending
    ;; Day horizon: R=140,G=190,B=235 → Sunset horizon: R=255,G=90,B=20
    ;; Day zenith: R=30,G=85,B=220 → Sunset zenith: R=220,G=35,B=80
    ;; Sun center: R=255,G=250,B=210 → R=255,G=120,B=15 at sunset
    ;; Richer, more dramatic sunsets with deeper oranges and vivid magenta sky
    ;; Fog uses horizon colors
    ;; ============================================================
    ;; sky_hr = 140 + (255-140)*sunset_t/255 = 140 + 115*sunset_t/255
    i32.const 140
    i32.const 115
    local.get $sunset_t
    i32.mul
    i32.const 255
    i32.div_u
    i32.add
    local.set $sky_hr
    ;; sky_hg = 190 - (190-90)*sunset_t/255 = 190 - 100*sunset_t/255
    i32.const 190
    i32.const 100
    local.get $sunset_t
    i32.mul
    i32.const 255
    i32.div_u
    i32.sub
    local.set $sky_hg
    ;; sky_hb = 235 - (235-20)*sunset_t/255 = 235 - 215*sunset_t/255
    i32.const 235
    i32.const 215
    local.get $sunset_t
    i32.mul
    i32.const 255
    i32.div_u
    i32.sub
    local.set $sky_hb
    ;; sky_zr = 30 + (220-30)*sunset_t/255 = 30 + 190*sunset_t/255
    i32.const 30
    i32.const 190
    local.get $sunset_t
    i32.mul
    i32.const 255
    i32.div_u
    i32.add
    local.set $sky_zr
    ;; sky_zg = 85 - (85-35)*sunset_t/255 = 85 - 50*sunset_t/255
    i32.const 85
    i32.const 50
    local.get $sunset_t
    i32.mul
    i32.const 255
    i32.div_u
    i32.sub
    local.set $sky_zg
    ;; sky_zb = 220 - (220-80)*sunset_t/255 = 220 - 140*sunset_t/255
    i32.const 220
    i32.const 140
    local.get $sunset_t
    i32.mul
    i32.const 255
    i32.div_u
    i32.sub
    local.set $sky_zb
    ;; fog_r = sky_hr, fog_g = sky_hg, fog_b = sky_hb (horizon colors for fog)
    local.get $sky_hr
    local.set $fog_r
    local.get $sky_hg
    local.set $fog_g
    local.get $sky_hb
    local.set $fog_b
    ;; Sun center color: blend from (255,250,210) to (255,130,20) with sunset_t
    ;; sun_cr = 255 (always)
    i32.const 255
    local.set $sun_cr
    ;; sun_cg = 250 - (250-120)*sunset_t/255 = 250 - 130*sunset_t/255
    i32.const 250
    i32.const 130
    local.get $sunset_t
    i32.mul
    i32.const 255
    i32.div_u
    i32.sub
    local.set $sun_cg
    ;; sun_cb = 210 - (210-15)*sunset_t/255 = 210 - 195*sunset_t/255
    i32.const 210
    i32.const 195
    local.get $sunset_t
    i32.mul
    i32.const 255
    i32.div_u
    i32.sub
    local.set $sun_cb

    ;; Sky uses color ramps + dithering like everything else (no special palette)

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
          ;; Monster base from table at 0x1951B (24-bit RGB, 3 bytes per entry)
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

    ;; Clear Floyd-Steinberg error buffer if F-S mode is active (mode 2)
    i32.const 0x11
    i32.load8_u
    i32.const 2
    i32.eq
    if
      call $fs_clear_buf
    end

    i32.const 0
    local.set $px_row
    block $row_done
      loop $row_lp
        local.get $px_row
        i32.const 200
        i32.ge_s
        br_if $row_done

        ;; Swap F-S error buffer rows at each scanline start (mode 2)
        ;; row1 (accumulated from previous scanline) → row0, clear row1
        i32.const 0x11
        i32.load8_u
        i32.const 2
        i32.eq
        if
          call $fs_swap_rows
        end

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

              ;; Distance-based shade (extended for multi-level cached octree range)
              i32.const 240
              local.get $dist
              f64.const 1.9
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

              ;; Apply face lighting offset (ambient contribution for non-sun faces)
              local.get $face
              i32.const 0
              i32.eq
              if
                local.get $shade_full
                i32.const 20
                i32.add
                local.set $shade_full
              end
              local.get $face
              i32.const 2
              i32.eq
              if
                local.get $shade_full
                i32.const 10
                i32.sub
                local.set $shade_full
              end
              local.get $face
              i32.const 3
              i32.eq
              if
                local.get $shade_full
                i32.const 25
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
              ;; CELESTIAL SHADOW RAY + DIRECTIONAL LIGHTING
              ;; Cast shadow ray from hit point toward sun/moon to check occlusion
              ;; Also compute N·L for directional lighting
              ;; Works for both sun and moon when visible
              ;; ============================================================
              i32.const 1
              local.set $shadow_lit

              local.get $cel_active
              if
                ;; Compute face normal dot light direction for directional lighting
                ;; face 0 (top): normal = (0, 0, 1)  → dot = cel_dir_z
                ;; face 1 (side bright): normal ~ (-1,0,0) or (0,-1,0) → approximate with -cel_dir_x
                ;; face 2 (side dim): normal ~ (1,0,0) or (0,1,0) → approximate with cel_dir_x
                ;; face 3 (bottom): normal = (0, 0, -1) → dot = -cel_dir_z
                f64.const 0.0
                local.set $sun_dot

                local.get $face
                i32.const 0
                i32.eq
                if
                  local.get $cel_dir_z
                  local.set $sun_dot
                end
                local.get $face
                i32.const 1
                i32.eq
                if
                  ;; Side bright: take max of abs(cel_dir_x), abs(cel_dir_y) negated
                  local.get $cel_dir_x
                  f64.neg
                  local.get $cel_dir_y
                  f64.neg
                  f64.max
                  local.set $sun_dot
                end
                local.get $face
                i32.const 2
                i32.eq
                if
                  ;; Side dim: take max of cel_dir_x, cel_dir_y
                  local.get $cel_dir_x
                  local.get $cel_dir_y
                  f64.max
                  local.set $sun_dot
                end
                local.get $face
                i32.const 3
                i32.eq
                if
                  local.get $cel_dir_z
                  f64.neg
                  local.set $sun_dot
                end

                ;; Clamp sun_dot to [0, 1]
                local.get $sun_dot
                f64.const 0.0
                f64.lt
                if
                  f64.const 0.0
                  local.set $sun_dot
                end
                local.get $sun_dot
                f64.const 1.0
                f64.gt
                if
                  f64.const 1.0
                  local.set $sun_dot
                end

                ;; Apply directional lighting: blend between ambient and full lit
                ;; For sun: ambient=0.35, strength=0.65
                ;; For moon: ambient=0.55, strength=0.45 (subtler directional)
                local.get $shade_full
                f64.convert_i32_s
                local.get $cel_is_sun
                if (result f64)
                  f64.const 0.35
                  f64.const 0.65
                  local.get $sun_dot
                  f64.mul
                  f64.add
                else
                  f64.const 0.55
                  f64.const 0.45
                  local.get $sun_dot
                  f64.mul
                  f64.add
                end
                f64.mul
                i32.trunc_f64_s
                local.set $shade_full

                ;; Shadow ray: offset hit point slightly along face normal
                ;; to avoid self-intersection, then trace toward light source
                ;; Always cast shadow ray for every pixel — shadow alters
                ;; lighting intensity (shade_full) before dithering handles it

                  ;; Compute shadow origin: hit point + face normal * 0.01
                  local.get $hit_px
                  local.set $shadow_ox
                  local.get $hit_py
                  local.set $shadow_oy
                  local.get $hit_pz
                  local.set $shadow_oz

                  local.get $face
                  i32.const 0
                  i32.eq
                  if
                    local.get $shadow_oz
                    f64.const 0.02
                    f64.add
                    local.set $shadow_oz
                  end
                  local.get $face
                  i32.const 3
                  i32.eq
                  if
                    local.get $shadow_oz
                    f64.const 0.02
                    f64.sub
                    local.set $shadow_oz
                  end
                  local.get $face
                  i32.const 1
                  i32.eq
                  if
                    local.get $shadow_ox
                    f64.const 0.02
                    f64.sub
                    local.set $shadow_ox
                    local.get $shadow_oy
                    f64.const 0.02
                    f64.sub
                    local.set $shadow_oy
                  end
                  local.get $face
                  i32.const 2
                  i32.eq
                  if
                    local.get $shadow_ox
                    f64.const 0.02
                    f64.add
                    local.set $shadow_ox
                    local.get $shadow_oy
                    f64.const 0.02
                    f64.add
                    local.set $shadow_oy
                  end

                  ;; Cast shadow ray toward light source (sun or moon)
                  local.get $shadow_ox
                  local.get $shadow_oy
                  local.get $shadow_oz
                  local.get $cel_dir_x
                  local.get $cel_dir_y
                  local.get $cel_dir_z
                  call $shadow_ray
                  local.set $shadow_lit

                ;; Apply shadow: if in shadow, darken
                ;; Sun shadow: 45% brightness (strong shadow)
                ;; Moon shadow: 65% brightness (soft shadow)
                local.get $shadow_lit
                i32.eqz
                if
                  local.get $shade_full
                  local.get $cel_is_sun
                  if (result i32)
                    i32.const 115  ;; 45% brightness when sun-shadowed (0.45 * 256 ≈ 115)
                  else
                    i32.const 166  ;; 65% brightness when moon-shadowed (0.65 * 256 ≈ 166)
                  end
                  i32.mul
                  i32.const 256
                  i32.div_u
                  local.set $shade_full
                end
              end

              ;; Clamp shade_full after sun lighting
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
              ;; Convert block color to 24-bit RGB using new 24-bit base colors
              ;; Block base stored as RGB triplet at 0x19500 + type*3
              ;; Final RGB = base_component * shade_full / 255
              ;; ============================================================
              ;; Water shimmer: modify shade for water blocks
              local.get $hit_type
              i32.const 5
              i32.eq
              if
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
                ;; Now using 24-bit block base colors from 0x19500 + type*3
                local.get $fb_addr
                local.get $px_col
                local.get $px_row
                ;; R: fog from block R to sky R (using sunset-aware fog colors)
                local.get $fog_r
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
                ;; block R contribution (24-bit base)
                local.get $hit_type
                call $block_base_r
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
                ;; G: fog blend (using sunset-aware fog colors)
                local.get $fog_g
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
                local.get $hit_type
                call $block_base_g
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
                ;; B: fog blend (using sunset-aware fog colors)
                local.get $fog_b
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
                local.get $hit_type
                call $block_base_b
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
                ;; R = block_base_r(type) * shade_full / 255
                ;; G = block_base_g(type) * shade_full / 255
                ;; B = block_base_b(type) * shade_full / 255
                local.get $fb_addr
                local.get $px_col
                local.get $px_row
                ;; R
                local.get $hit_type
                call $block_base_r
                local.get $shade_full
                i32.mul
                i32.const 255
                i32.div_u
                ;; G
                local.get $hit_type
                call $block_base_g
                local.get $shade_full
                i32.mul
                i32.const 255
                i32.div_u
                ;; B
                local.get $hit_type
                call $block_base_b
                local.get $shade_full
                i32.mul
                i32.const 255
                i32.div_u
                call $rgb_to_rgbl_dither
                i32.store8
              end
            else
              ;; Sky (allow slightly below horizon so sun/moon disc isn't clipped)
              local.get $ray_dz
              f64.const -0.06
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

                ;; ============================================================
                ;; UNIFIED SKY RENDERING: sky gradient → sun/moon → clouds → stars
                ;; Stars only visible where clouds don't cover them
                ;; ============================================================

                ;; Step 1: Always compute sky gradient into cloud_r/g/b
                ;; Sky gradient with dithered 24-bit RGB
                ;; ray_dz (0..1) controls gradient from horizon to zenith
                ;; Sky color: blend from horizon to zenith (sunset-aware)
                ;; Horizon/Zenith colors precomputed with sunset blending
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
                    ;; R = (sky_hr*(255-t) + sky_zr*t) / 255
                    ;; G = (sky_hg*(255-t) + sky_zg*t) / 255
                    ;; B = (sky_hb*(255-t) + sky_zb*t) / 255
                    ;; Then multiply by day_bright/255 and add night base

                    ;; Compute base sky R
                    local.get $sky_hr
                    i32.const 255
                    local.get $sky_idx
                    i32.sub
                    i32.mul
                    local.get $sky_zr
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
                    local.set $cloud_r
                    ;; Compute base sky G
                    local.get $sky_hg
                    i32.const 255
                    local.get $sky_idx
                    i32.sub
                    i32.mul
                    local.get $sky_zg
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
                    local.set $cloud_g
                    ;; Compute base sky B
                    local.get $sky_hb
                    i32.const 255
                    local.get $sky_idx
                    i32.sub
                    i32.mul
                    local.get $sky_zb
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
                    local.set $cloud_b

                ;; Step 2: Blend sun/moon into cloud_r/g/b (behind clouds)
                local.get $cel_active
                local.get $cel_is_sun
                i32.and
                local.get $cel_dot
                f64.const 0.980
                f64.gt
                i32.and
                if
                  ;; Sun rendering: blend sun color into sky gradient (cloud_r/g/b)
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

                  ;; Blend: cloud_r = cloud_r*(255-t)/255 + sun_cr*t/255
                  local.get $cloud_r
                  i32.const 255
                  local.get $shade_full
                  i32.sub
                  i32.mul
                  local.get $sun_cr
                  local.get $shade_full
                  i32.mul
                  i32.add
                  i32.const 255
                  i32.div_u
                  local.set $cloud_r
                  ;; G
                  local.get $cloud_g
                  i32.const 255
                  local.get $shade_full
                  i32.sub
                  i32.mul
                  local.get $sun_cg
                  local.get $shade_full
                  i32.mul
                  i32.add
                  i32.const 255
                  i32.div_u
                  local.set $cloud_g
                  ;; B
                  local.get $cloud_b
                  i32.const 255
                  local.get $shade_full
                  i32.sub
                  i32.mul
                  local.get $sun_cb
                  local.get $shade_full
                  i32.mul
                  i32.add
                  i32.const 255
                  i32.div_u
                  local.set $cloud_b
                end

                ;; Moon blending into cloud_r/g/b
                local.get $cel_active
                local.get $cel_is_sun
                i32.eqz
                i32.and
                local.get $cel_dot
                f64.const 0.988
                f64.gt
                i32.and
                if
                  ;; Moon rendering: blend moon color into sky gradient (cloud_r/g/b)
                  ;; Map cel_dot from 0.988..1.0 to t = 0..255
                  local.get $cel_dot
                  f64.const 0.988
                  f64.sub
                  f64.const 21250.0  ;; 255/0.012
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

                  ;; Moon: bright cool white with warm edge glow
                  ;; Compute moon RGB based on shade_full
                  ;; shade_full 0-127: warm edge glow (180,160,120)
                  ;; shade_full 128-255: bright center (210,220,240)
                  ;; Blend moon color into cloud_r/g/b using shade_full as opacity

                  ;; Compute moon color for this pixel
                  local.get $shade_full
                  i32.const 128
                  i32.lt_s
                  if
                    ;; Outer halo: blend night sky toward warm edge (180,160,120)
                    ;; t2 = shade_full * 2 (0-254)
                    ;; moon_r = 2*(255-t2)/255 + 180*t2/255
                    i32.const 2
                    i32.const 255
                    local.get $shade_full
                    i32.const 2
                    i32.mul
                    i32.sub
                    i32.mul
                    i32.const 180
                    local.get $shade_full
                    i32.const 2
                    i32.mul
                    i32.mul
                    i32.add
                    i32.const 255
                    i32.div_u
                    local.set $cloud_r
                    ;; moon_g
                    i32.const 4
                    i32.const 255
                    local.get $shade_full
                    i32.const 2
                    i32.mul
                    i32.sub
                    i32.mul
                    i32.const 160
                    local.get $shade_full
                    i32.const 2
                    i32.mul
                    i32.mul
                    i32.add
                    i32.const 255
                    i32.div_u
                    local.set $cloud_g
                    ;; moon_b
                    i32.const 10
                    i32.const 255
                    local.get $shade_full
                    i32.const 2
                    i32.mul
                    i32.sub
                    i32.mul
                    i32.const 120
                    local.get $shade_full
                    i32.const 2
                    i32.mul
                    i32.mul
                    i32.add
                    i32.const 255
                    i32.div_u
                    local.set $cloud_b
                  else
                    ;; Inner disc: blend warm edge (180,160,120) → bright center (210,220,240)
                    ;; t2 = (shade_full - 128) * 2 (0-254)
                    i32.const 180
                    i32.const 255
                    local.get $shade_full
                    i32.const 128
                    i32.sub
                    i32.const 2
                    i32.mul
                    i32.sub
                    i32.mul
                    i32.const 210
                    local.get $shade_full
                    i32.const 128
                    i32.sub
                    i32.const 2
                    i32.mul
                    i32.mul
                    i32.add
                    i32.const 255
                    i32.div_u
                    local.set $cloud_r
                    ;; G
                    i32.const 160
                    i32.const 255
                    local.get $shade_full
                    i32.const 128
                    i32.sub
                    i32.const 2
                    i32.mul
                    i32.sub
                    i32.mul
                    i32.const 220
                    local.get $shade_full
                    i32.const 128
                    i32.sub
                    i32.const 2
                    i32.mul
                    i32.mul
                    i32.add
                    i32.const 255
                    i32.div_u
                    local.set $cloud_g
                    ;; B
                    i32.const 120
                    i32.const 255
                    local.get $shade_full
                    i32.const 128
                    i32.sub
                    i32.const 2
                    i32.mul
                    i32.sub
                    i32.mul
                    i32.const 240
                    local.get $shade_full
                    i32.const 128
                    i32.sub
                    i32.const 2
                    i32.mul
                    i32.mul
                    i32.add
                    i32.const 255
                    i32.div_u
                    local.set $cloud_b
                  end
                end

                    ;; Reset cloud_val before cloud computation (0 = no cloud)
                    i32.const 0
                    local.set $cloud_val

                    ;; ============================================================
                    ;; PROCEDURAL CLOUDS — two layers of scrolling noise
                    ;; Project ray onto cloud planes, sample multi-octave noise
                    ;; Only during daytime (day_bright > 30) and above horizon
                    ;; ============================================================
                    local.get $day_bright
                    i32.const 30
                    i32.gt_s
                    local.get $ray_dz
                    f64.const 0.02
                    f64.gt
                    i32.and
                    if
                      ;; inv_dz = 1.0 / ray_dz (projection scale onto cloud plane)
                      f64.const 1.0
                      local.get $ray_dz
                      f64.div
                      local.set $cloud_inv_dz

                      ;; ---- Layer 1: large puffy clouds (high altitude, slow drift) ----
                      ;; Project ray onto plane: u = ray_dx / ray_dz * scale + px + time_offset
                      ;; cloud_u = (ray_dx * 80 / ray_dz) + px*4 + tick/120
                      ;; cloud_v = (ray_dy * 80 / ray_dz) + py*4 + tick/200
                      local.get $ray_dx
                      f64.const 80.0
                      f64.mul
                      local.get $cloud_inv_dz
                      f64.mul
                      local.get $px
                      f64.const 4.0
                      f64.mul
                      f64.add
                      local.get $tick
                      f64.convert_i32_s
                      f64.const 120.0
                      f64.div
                      f64.add
                      i32.trunc_f64_s
                      local.set $cloud_u
                      local.get $ray_dy
                      f64.const 80.0
                      f64.mul
                      local.get $cloud_inv_dz
                      f64.mul
                      local.get $py
                      f64.const 4.0
                      f64.mul
                      f64.add
                      local.get $tick
                      f64.convert_i32_s
                      f64.const 200.0
                      f64.div
                      f64.add
                      i32.trunc_f64_s
                      local.set $cloud_v
                      ;; Octave 1: large scale (period=64), contributes 0-180
                      local.get $cloud_u
                      local.get $cloud_v
                      i32.const 64
                      call $smooth_hash
                      i32.const 180
                      i32.mul
                      i32.const 255
                      i32.div_u
                      local.set $cloud_d1
                      ;; Octave 2: medium detail (period=24), contributes 0-60
                      local.get $cloud_u
                      i32.const 3
                      i32.mul
                      local.get $cloud_v
                      i32.const 3
                      i32.mul
                      i32.const 24
                      call $smooth_hash
                      i32.const 60
                      i32.mul
                      i32.const 255
                      i32.div_u
                      local.get $cloud_d1
                      i32.add
                      local.set $cloud_d1
                      ;; Octave 3: fine wispy detail (period=10), contributes 0-25
                      local.get $cloud_u
                      i32.const 7
                      i32.mul
                      i32.const 1000
                      i32.add
                      local.get $cloud_v
                      i32.const 7
                      i32.mul
                      i32.const 2000
                      i32.add
                      i32.const 10
                      call $smooth_hash
                      i32.const 25
                      i32.mul
                      i32.const 255
                      i32.div_u
                      local.get $cloud_d1
                      i32.add
                      local.set $cloud_d1
                      ;; Threshold: subtract 120, clamp to 0-145, then scale to 0-255
                      ;; This makes clouds have defined edges with clear sky between
                      local.get $cloud_d1
                      i32.const 120
                      i32.sub
                      local.set $cloud_d1
                      local.get $cloud_d1
                      i32.const 0
                      i32.lt_s
                      if  i32.const 0  local.set $cloud_d1  end
                      ;; Scale: d1 * 255 / 145 ≈ d1 * 7 / 4
                      local.get $cloud_d1
                      i32.const 7
                      i32.mul
                      i32.const 4
                      i32.div_u
                      local.set $cloud_d1
                      local.get $cloud_d1
                      i32.const 255
                      i32.gt_s
                      if  i32.const 255  local.set $cloud_d1  end

                      ;; ---- Layer 2: thin wispy cirrus (higher, faster drift) ----
                      local.get $ray_dx
                      f64.const 120.0
                      f64.mul
                      local.get $cloud_inv_dz
                      f64.mul
                      local.get $px
                      f64.const 6.0
                      f64.mul
                      f64.add
                      local.get $tick
                      f64.convert_i32_s
                      f64.const 60.0
                      f64.div
                      f64.add
                      i32.trunc_f64_s
                      local.set $cloud_u
                      local.get $ray_dy
                      f64.const 120.0
                      f64.mul
                      local.get $cloud_inv_dz
                      f64.mul
                      local.get $py
                      f64.const 6.0
                      f64.mul
                      f64.add
                      local.get $tick
                      f64.convert_i32_s
                      f64.const 300.0
                      f64.div
                      f64.add
                      i32.trunc_f64_s
                      local.set $cloud_v
                      ;; Single octave with wider period for streaky look
                      local.get $cloud_u
                      i32.const 5000
                      i32.add
                      local.get $cloud_v
                      i32.const 5000
                      i32.add
                      i32.const 40
                      call $smooth_hash
                      i32.const 140
                      i32.mul
                      i32.const 255
                      i32.div_u
                      local.set $cloud_d2
                      ;; Wispy detail octave
                      local.get $cloud_u
                      i32.const 4
                      i32.mul
                      i32.const 8000
                      i32.add
                      local.get $cloud_v
                      i32.const 4
                      i32.mul
                      i32.const 9000
                      i32.add
                      i32.const 16
                      call $smooth_hash
                      i32.const 80
                      i32.mul
                      i32.const 255
                      i32.div_u
                      local.get $cloud_d2
                      i32.add
                      local.set $cloud_d2
                      ;; Threshold higher for thinner clouds
                      local.get $cloud_d2
                      i32.const 130
                      i32.sub
                      local.set $cloud_d2
                      local.get $cloud_d2
                      i32.const 0
                      i32.lt_s
                      if  i32.const 0  local.set $cloud_d2  end
                      ;; Scale to 0-255
                      local.get $cloud_d2
                      i32.const 255
                      i32.mul
                      i32.const 90
                      i32.div_u
                      local.set $cloud_d2
                      local.get $cloud_d2
                      i32.const 255
                      i32.gt_s
                      if  i32.const 255  local.set $cloud_d2  end
                      ;; Cirrus layer is semi-transparent (max 50% opacity)
                      local.get $cloud_d2
                      i32.const 1
                      i32.shr_u
                      local.set $cloud_d2

                      ;; Combine layers: use max of both for soft overlap
                      ;; cloud_val = max(cloud_d1, cloud_d2)
                      ;; Actually blend additively for layered feel: d1 + d2*(255-d1)/255
                      local.get $cloud_d1
                      local.get $cloud_d2
                      i32.const 255
                      local.get $cloud_d1
                      i32.sub
                      i32.mul
                      i32.const 255
                      i32.div_u
                      i32.add
                      local.set $cloud_val
                      local.get $cloud_val
                      i32.const 255
                      i32.gt_s
                      if  i32.const 255  local.set $cloud_val  end

                      ;; Fade clouds near horizon (ray_dz < 0.15 → fade out)
                      ;; horizon_fade = min(255, ray_dz * 255 / 0.15) = ray_dz * 1700
                      local.get $ray_dz
                      f64.const 1700.0
                      f64.mul
                      i32.trunc_f64_s
                      local.set $shade_frac
                      local.get $shade_frac
                      i32.const 255
                      i32.gt_s
                      if  i32.const 255  local.set $shade_frac  end
                      ;; Apply horizon fade
                      local.get $cloud_val
                      local.get $shade_frac
                      i32.mul
                      i32.const 255
                      i32.div_u
                      local.set $cloud_val

                      ;; Scale cloud opacity by day brightness
                      local.get $cloud_val
                      local.get $day_bright
                      i32.mul
                      i32.const 255
                      i32.div_u
                      local.set $cloud_val

                      ;; Blend cloud white into sky color
                      ;; Cloud color: bright white (245,248,255) during day
                      ;; At sunset, intensely warm: blend toward (255,160,80)
                      ;; cloud_target_r = 245 + 10*sunset_t/255
                      ;; cloud_target_g = 248 - 88*sunset_t/255
                      ;; cloud_target_b = 255 - 175*sunset_t/255

                      ;; R: sky_r + (cloud_white_r - sky_r) * cloud_val / 255
                      ;; Simplified: sky_r * (255-cloud_val)/255 + cloud_white_r * cloud_val/255
                      local.get $cloud_r
                      i32.const 255
                      local.get $cloud_val
                      i32.sub
                      i32.mul
                      ;; cloud_target_r
                      i32.const 245
                      i32.const 10
                      local.get $sunset_t
                      i32.mul
                      i32.const 255
                      i32.div_u
                      i32.add
                      local.get $cloud_val
                      i32.mul
                      i32.add
                      i32.const 255
                      i32.div_u
                      local.set $cloud_r

                      ;; G
                      local.get $cloud_g
                      i32.const 255
                      local.get $cloud_val
                      i32.sub
                      i32.mul
                      ;; cloud_target_g
                      i32.const 248
                      i32.const 88
                      local.get $sunset_t
                      i32.mul
                      i32.const 255
                      i32.div_u
                      i32.sub
                      local.get $cloud_val
                      i32.mul
                      i32.add
                      i32.const 255
                      i32.div_u
                      local.set $cloud_g

                      ;; B
                      local.get $cloud_b
                      i32.const 255
                      local.get $cloud_val
                      i32.sub
                      i32.mul
                      ;; cloud_target_b
                      i32.const 255
                      i32.const 175
                      local.get $sunset_t
                      i32.mul
                      i32.const 255
                      i32.div_u
                      i32.sub
                      local.get $cloud_val
                      i32.mul
                      i32.add
                      i32.const 255
                      i32.div_u
                      local.set $cloud_b
                    end

                    ;; ============================================================
                    ;; Step 3: NIGHT STARS — cubemap-style direction-based stars
                    ;; Uses ray direction for stable parallax (not screen coords)
                    ;; Only visible when day_bright < 140 AND cloud_val < 20
                    ;; Stars render BEHIND clouds — only where sky is clear
                    ;; ============================================================
                    local.get $day_bright
                    i32.const 140
                    i32.lt_s
                    local.get $ray_dz
                    f64.const 0.05
                    f64.gt
                    i32.and
                    local.get $cloud_val
                    i32.const 20
                    i32.lt_s
                    i32.and
                    if
                      ;; Cubemap-style star hash: quantize ray direction to a grid
                      ;; on the sky sphere, then hash the grid cell for star presence.
                      ;; This gives stars fixed positions on the sky dome that don't
                      ;; move with the camera — only the visible portion changes.
                      ;;
                      ;; Project ray onto unit sphere grid:
                      ;; grid_u = atan2(ray_dy, ray_dx) * 200 / pi  (azimuth, ~400 cells around)
                      ;; grid_v = ray_dz * 300  (elevation, ~300 cells zenith)
                      ;; Approximate atan2 with ray_dx and ray_dy ratios for speed
                      ;;
                      ;; Fast spherical grid: use (ray_dx/ray_dz, ray_dy/ray_dz) projected
                      ;; onto a high-res grid. Since ray_dz > 0.05 (checked above), safe to divide.
                      ;; Multiply by large scale for fine grid cells.

                      ;; grid_u = (ray_dx / ray_dz) * 150
                      ;; grid_v = (ray_dy / ray_dz) * 150
                      ;; These are stable in world space — camera rotation changes which
                      ;; grid cells map to which screen pixels, but the grid itself is fixed.
                      local.get $ray_dx
                      local.get $ray_dz
                      f64.div
                      f64.const 150.0
                      f64.mul
                      i32.trunc_f64_s
                      ;; grid_u on stack

                      local.get $ray_dy
                      local.get $ray_dz
                      f64.div
                      f64.const 150.0
                      f64.mul
                      i32.trunc_f64_s
                      ;; grid_v on stack

                      ;; Hash: (grid_u * 7919 + grid_v * 7727 + 13) & 0x7FFFFFFF % 997
                      ;; Store grid_v, compute hash
                      local.set $cloud_d2  ;; reuse as grid_v temp
                      ;; grid_u still on stack
                      i32.const 7919
                      i32.mul
                      local.get $cloud_d2
                      i32.const 7727
                      i32.mul
                      i32.add
                      i32.const 13
                      i32.add
                      i32.const 0x7FFFFFFF
                      i32.and
                      i32.const 997
                      i32.rem_u
                      i32.const 3
                      i32.lt_u
                      if
                        ;; Star brightness: twinkle using tick + direction hash
                        ;; Fade with day brightness: star_alpha = (140 - day_bright) * 255 / 140
                        ;; Also fade by inverse cloud_val for smooth cloud edges
                        i32.const 140
                        local.get $day_bright
                        i32.sub
                        i32.const 255
                        i32.mul
                        i32.const 140
                        i32.div_u
                        local.set $shade_frac  ;; reuse as star_alpha

                        ;; Further attenuate by cloud proximity (cloud_val 0→20)
                        ;; star_alpha *= (20 - cloud_val) / 20
                        local.get $shade_frac
                        i32.const 20
                        local.get $cloud_val
                        i32.sub
                        i32.mul
                        i32.const 20
                        i32.div_u
                        local.set $shade_frac

                        ;; Twinkle: use direction-based hash + tick for animation
                        ;; (grid_u * 31 + grid_v * 17 + tick>>7) & 3 == 0
                        local.get $ray_dx
                        local.get $ray_dz
                        f64.div
                        f64.const 150.0
                        f64.mul
                        i32.trunc_f64_s
                        i32.const 31
                        i32.mul
                        local.get $cloud_d2  ;; grid_v
                        i32.const 17
                        i32.mul
                        i32.add
                        local.get $tick
                        i32.const 7
                        i32.shr_u
                        i32.add
                        i32.const 3
                        i32.and
                        i32.const 0
                        i32.eq
                        if
                          ;; Bright twinkle frame: blend star white into sky
                          ;; R = cloud_r + (255 - cloud_r) * star_alpha / 255
                          local.get $cloud_r
                          i32.const 255
                          local.get $cloud_r
                          i32.sub
                          local.get $shade_frac
                          i32.mul
                          i32.const 255
                          i32.div_u
                          i32.add
                          local.set $cloud_r
                          local.get $cloud_g
                          i32.const 255
                          local.get $cloud_g
                          i32.sub
                          local.get $shade_frac
                          i32.mul
                          i32.const 255
                          i32.div_u
                          i32.add
                          local.set $cloud_g
                          local.get $cloud_b
                          i32.const 255
                          local.get $cloud_b
                          i32.sub
                          local.get $shade_frac
                          i32.mul
                          i32.const 255
                          i32.div_u
                          i32.add
                          local.set $cloud_b
                        end
                      end
                    end

                    ;; Write final sky+sun/moon+clouds+stars pixel
                    local.get $fb_addr
                    local.get $px_col
                    local.get $px_row
                    local.get $cloud_r
                    local.get $cloud_g
                    local.get $cloud_b
                    call $rgb_to_rgbl_dither
                    i32.store8
              else
                ;; Below horizon fog: dithered sky at horizon level (sunset-aware)
                ;; Use precomputed horizon sky color
                ;; plus night base
                local.get $fb_addr
                local.get $px_col
                local.get $px_row
                ;; R
                local.get $fog_r
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
                local.get $fog_g
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
                local.get $fog_b
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
      i32.const 31
      call $draw_num
    else
      local.get $game_hour
      i32.const 275
      i32.const 2
      i32.const 31
      call $draw_num
    end
    i32.const 0x190E0
    i32.const 285
    i32.const 2
    i32.const 31
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
      i32.const 31
      call $draw_num
    else
      local.get $game_min
      i32.const 290
      i32.const 2
      i32.const 31
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
      i32.const 127  ;; sand ramp bright (mat 3, shade 31)
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
    i32.const 31
    call $draw_str
    i32.const 0x10390
    i32.load
    i32.const 32
    i32.const 2
    i32.const 31
    call $draw_num
    i32.const 0x190D0
    i32.const 57
    i32.const 2
    i32.const 24
    call $draw_str
    i32.const 0x10394
    i32.load
    i32.const 62
    i32.const 2
    i32.const 24
    call $draw_num

    ;; ---- Total ray steps display ----
    i32.const 0x19126
    i32.const 2
    i32.const 9
    i32.const 24
    call $draw_str
    global.get $g_total_steps
    i32.const 32
    i32.const 9
    i32.const 31
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
      i32.const 44   ;; red hue ramp shade 12
      call $draw_str
      i32.const 0x19070
      i32.const 72
      i32.const 90
      i32.const 44
      call $draw_str
      i32.const 0x19090
      i32.const 72
      i32.const 102
      i32.const 44
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
      i32.const 124  ;; green hue ramp shade 12
      call $draw_str
      i32.const 0x19010
      i32.const 70
      i32.const 180
      i32.const 95   ;; bright stone (mat 2, shade 31)
      call $draw_str
      i32.const 0x19030
      i32.const 60
      i32.const 190
      i32.const 28
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

    ;; ---- Inventory toggle on Escape (bit 6) ----
    local.get $keys
    i32.const 64  ;; bit 6 = Escape
    i32.and
    i32.const 0
    i32.ne
    if
      global.get $g_prev_esc
      i32.eqz
      if
        ;; Rising edge: toggle inventory
        global.get $g_show_inv
        i32.eqz
        if
          i32.const 1
          global.set $g_show_inv
        else
          i32.const 0
          global.set $g_show_inv
        end
      end
    end
    local.get $keys
    i32.const 64
    i32.and
    i32.const 0
    i32.ne
    global.set $g_prev_esc

    ;; ---- Draw inventory overlay if open ----
    global.get $g_show_inv
    if
      call $draw_inventory
    end
  )

  ;; ============================================================
  ;; INVENTORY — 8 material × 32 shade palette display
  ;; 8 rows of 32 brightness levels each
  ;; ============================================================
  (func $draw_inventory
    (local $r i32) (local $g i32) (local $b i32) (local $l i32)
    (local $row i32) (local $col i32)
    (local $cx i32) (local $cy i32)
    (local $pal_idx i32)
    (local $i i32) (local $j i32)
    (local $label_x i32) (local $label_y i32)
    (local $anim i32)

    ;; Semi-transparent dark background overlay
    ;; Fill entire screen with dark color (palette 0 = black)
    i32.const 0
    local.set $i
    block $bg_done
      loop $bg_lp
        local.get $i
        i32.const 200
        i32.ge_s
        br_if $bg_done
        i32.const 0
        local.set $j
        block $bg_col_done
          loop $bg_col_lp
            local.get $j
            i32.const 320
            i32.ge_s
            br_if $bg_col_done
            ;; Checkerboard dither: every other pixel to dark
            local.get $i
            local.get $j
            i32.add
            i32.const 1
            i32.and
            if
              local.get $j
              local.get $i
              i32.const 0  ;; black
              call $put_pixel
            end
            local.get $j
            i32.const 1
            i32.add
            local.set $j
            br $bg_col_lp
          end
        end
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $bg_lp
      end
    end

    ;; Title: "MATERIALS" centered at top
    i32.const 0x190F0  ;; "MATERIALS"
    i32.const 110
    i32.const 3
    i32.const 255  ;; bright (coal ramp max = mat7*32+31)
    call $draw_str

    ;; "8x32 RAMPS" subtitle
    i32.const 0x1911A  ;; "8x32 RAMPS"
    i32.const 110
    i32.const 11
    i32.const 31   ;; grass ramp brightest (mat 0, shade 31)
    call $draw_str

    ;; Column header: "B" (brightness) label
    i32.const 0x19102  ;; "B"
    i32.const 36
    i32.const 21
    i32.const 255  ;; coal bright
    call $draw_str

    ;; Row header: "M" (material) label
    i32.const 0x19100  ;; "M"
    i32.const 2
    i32.const 30
    i32.const 255  ;; coal bright
    call $draw_str

    ;; ---- Draw the 256 color swatches ----
    ;; 8 rows (materials) × 32 columns (brightness levels)
    ;; Each cell: w=9, h=18, x = 10 + shade*9.5, y = 22 + mat*20
    i32.const 0
    local.set $r  ;; material index 0-7
    block $mat_done
      loop $mat_lp
        local.get $r
        i32.const 8
        i32.ge_u
        br_if $mat_done
        i32.const 0
        local.set $l  ;; brightness index 0-31
        block $shade_done
          loop $shade_lp
            local.get $l
            i32.const 32
            i32.ge_u
            br_if $shade_done

            ;; Palette index = material * 32 + brightness
            local.get $r
            i32.const 32
            i32.mul
            local.get $l
            i32.add
            local.set $pal_idx

            ;; Cell x = 10 + shade*9 (fits 32 cols in ~298px)
            i32.const 10
            local.get $l
            i32.const 9
            i32.mul
            i32.add
            local.set $cx

            ;; Cell y = 24 + material*21
            i32.const 24
            local.get $r
            i32.const 21
            i32.mul
            i32.add
            local.set $cy

            ;; Draw filled rectangle 8×19
            local.get $cx
            local.get $cy
            i32.const 8
            i32.const 19
            local.get $pal_idx
            call $fill_rect

            local.get $l
            i32.const 1
            i32.add
            local.set $l
            br $shade_lp
          end
        end
        local.get $r
        i32.const 1
        i32.add
        local.set $r
        br $mat_lp
      end
    end

    ;; Footer: "ESC:CLOSE"
    i32.const 0x19108
    i32.const 130
    i32.const 194
    i32.const 255  ;; coal bright
    call $draw_str
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