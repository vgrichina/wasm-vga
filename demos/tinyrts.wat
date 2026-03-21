(module
  ;; TinyRTS - A mini Real-Time Strategy game in WebAssembly
  ;; Inspired by Warcraft / StarCraft
  ;; 320x200 VGA Mode 13h
  ;;
  ;; Controls: Mouse to select/command, Left click select, Right click move/attack
  ;; Keys: Space=spawn worker, Enter=spawn soldier, Shift=spawn archer
  ;;        Up/W=scroll up, Down/S=scroll down, Left/A=scroll left, Right/D=scroll right

  (import "env" "memory" (memory 4))
  (import "env" "sfx" (func $sfx (param i32)))
  (import "env" "note" (func $note (param i32 i32 i32 i32)))
  (import "env" "music" (func $music (param i32)))

  ;; Memory layout:
  ;; 0x0000-0x003F  control block
  ;; 0x0040-0x033F  palette (768 bytes)
  ;; 0x0340-0x103F  framebuffer (64000 bytes)
  ;; 0x10340+       game data

  ;; Game data offsets
  ;; 0x10400: map tiles (128*128 = 16384 bytes) -- terrain
  ;; 0x14400: units array (max 64 units, 32 bytes each = 2048)
  ;; 0x14C00: buildings array (max 32 buildings, 32 bytes each = 1024)
  ;; 0x15000: particles array (max 64 particles, 16 bytes each = 1024)
  ;; 0x15400: projectiles array (max 32, 20 bytes each = 640)
  ;; 0x15680: selection box data (16 bytes)
  ;; 0x15690: game state (gold, etc) (64 bytes)
  ;; 0x156D0: fog of war (128*128 = 16384 bytes)
  ;; 0x196D0: minimap buffer (64*64 = 4096 bytes)
  ;; 0x1A6D0: sfx data (64 bytes)
  ;; 0x1A710: music pattern (256 bytes)
  ;; 0x1A810: RNG state (4 bytes)
  ;; 0x1A820: camera position (8 bytes: cam_x i16, cam_y i16, ... )
  ;; 0x1A830: enemy AI state (64 bytes)
  ;; 0x1A870: gold mine positions (max 8, 8 bytes each = 64)
  ;; 0x1A8B0: tree data overlay on map
  ;; 0x1A900: scroll speeds (4 bytes)
  ;; 0x1A910: frame timer (4 bytes)
  ;; 0x1A920: selected unit list (max 16 unit indices, 16 bytes)
  ;; 0x1A930: num selected (4 bytes)
  ;; 0x1A940: last mouse state (4 bytes)
  ;; 0x1A950: drag select state (16 bytes)
  ;; 0x1A960: game over state (4 bytes)
  ;; 0x1A970: enemy spawn timer (4 bytes)
  ;; 0x1A980: player stats display (16 bytes)
  ;; 0x1AFC0: flow field slot headers (4 slots × 16 bytes = 64 bytes)
  ;;          each: target_tile (i32), age (i32), user_count (i32), pad (i32)
  ;; 0x1B000: flow field grids (4 slots × 16384 bytes = 65536 bytes)
  ;;          slot 0: 0x1B000, slot 1: 0x1F000, slot 2: 0x23000, slot 3: 0x27000
  ;; 0x2B000: BFS queue (shared scratch, 16384 entries × 4 bytes = 65536 bytes)

  ;; Unit struct (32 bytes):
  ;; +0: active (u8) - 0=inactive, 1=active
  ;; +1: type (u8) - 0=worker, 1=soldier, 2=archer, 3=enemy_soldier, 4=enemy_archer
  ;; +2: team (u8) - 0=player, 1=enemy
  ;; +3: state (u8) - 0=idle, 1=moving, 2=attacking, 3=gathering, 4=dead, 5=returning
  ;; +4: x (i16) - world position * 16 (subpixel)
  ;; +6: y (i16)
  ;; +8: target_x (i16)
  ;; +10: target_y (i16)
  ;; +12: hp (i16)
  ;; +14: max_hp (i16)
  ;; +16: attack (u8)
  ;; +17: range (u8) - attack range in pixels
  ;; +18: speed (u8) - movement speed
  ;; +19: selected (u8) - is selected
  ;; +20: anim_frame (u8)
  ;; +21: anim_timer (u8)
  ;; +22: attack_timer (u8)
  ;; +23: facing (u8) - 0=down,1=left,2=up,3=right
  ;; +24: target_unit (i8) - index of unit being attacked, -1 if none
  ;; +25: carry_gold (u8) - gold being carried (workers)
  ;; +26: attack_cooldown_max (u8)
  ;; +27: pad
  ;; +28: prev_x (i16) - for stuck detection
  ;; +30: stuck_counter (u8)

  ;; Building struct (32 bytes):
  ;; +0: active (u8)
  ;; +1: type (u8) - 0=town_hall, 1=barracks, 2=tower, 3=gold_mine, 4=enemy_hall, 5=enemy_barracks
  ;; +2: team (u8)
  ;; +3: state (u8) - 0=normal, 1=building, 2=destroyed
  ;; +4: x (i16) - world position
  ;; +6: y (i16)
  ;; +8: hp (i16)
  ;; +10: max_hp (i16)
  ;; +12: width (u8) - in tiles (each tile = 8px)
  ;; +13: height (u8)
  ;; +14: build_progress (u8)
  ;; +15: pad
  ;; +16-31: pad

  (global $MAP_W i32 (i32.const 128))
  (global $MAP_H i32 (i32.const 128))
  (global $TILE_SIZE i32 (i32.const 8))
  (global $MAP_ADDR i32 (i32.const 0x10400))
  (global $UNIT_ADDR i32 (i32.const 0x14400))
  (global $MAX_UNITS i32 (i32.const 64))
  (global $UNIT_SIZE i32 (i32.const 32))
  (global $BLDG_ADDR i32 (i32.const 0x14C00))
  (global $MAX_BLDGS i32 (i32.const 32))
  (global $BLDG_SIZE i32 (i32.const 32))
  (global $PART_ADDR i32 (i32.const 0x15000))
  (global $MAX_PARTS i32 (i32.const 64))
  (global $PROJ_ADDR i32 (i32.const 0x15400))
  (global $MAX_PROJS i32 (i32.const 32))
  (global $SEL_BOX i32 (i32.const 0x15680))
  (global $GAME_STATE i32 (i32.const 0x15690))
  (global $FOG_ADDR i32 (i32.const 0x156D0))
  (global $MINIMAP_ADDR i32 (i32.const 0x196D0))
  (global $SFX_ADDR i32 (i32.const 0x1A6D0))
  (global $MUSIC_ADDR i32 (i32.const 0x1A710))
  (global $RNG_ADDR i32 (i32.const 0x1A810))
  (global $CAM_ADDR i32 (i32.const 0x1A820))
  (global $AI_ADDR i32 (i32.const 0x1A830))
  (global $MINE_ADDR i32 (i32.const 0x1A870))
  (global $SEL_LIST i32 (i32.const 0x1A920))
  (global $NUM_SEL i32 (i32.const 0x1A930))
  (global $LAST_MOUSE i32 (i32.const 0x1A940))
  (global $DRAG_STATE i32 (i32.const 0x1A950))
  (global $GAME_OVER i32 (i32.const 0x1A960))
  (global $ENEMY_TIMER i32 (i32.const 0x1A970))
  (global $FRAME_TIMER i32 (i32.const 0x1A910))
  (global $FLOW_HDR i32 (i32.const 0x1AFC0))
  (global $FLOW_GRID i32 (i32.const 0x1B000))
  (global $FLOW_SLOTS i32 (i32.const 4))
  (global $BFS_QUEUE i32 (i32.const 0x2B000))

  (global $FB i32 (i32.const 0x0340))
  (global $PAL i32 (i32.const 0x0040))
  (global $CTL i32 (i32.const 0x0000))
  (global $SCR_W i32 (i32.const 320))
  (global $SCR_H i32 (i32.const 200))

  ;; ============ RNG ============
  (func $rng (result i32)
    (local $s i32)
    (local.set $s (i32.load (i32.const 0x1A810)))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 13))))
    (local.set $s (i32.xor (local.get $s) (i32.shr_u (local.get $s) (i32.const 17))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 5))))
    (i32.store (i32.const 0x1A810) (local.get $s))
    (local.get $s)
  )

  ;; ============ PALETTE SETUP ============
  (func $setup_palette
    (local $i i32)
    (local $addr i32)
    ;; Color indices:
    ;; 0: black (background/UI)
    ;; 1: dark green (grass dark)
    ;; 2: green (grass)
    ;; 3: light green (grass light)
    ;; 4: dark brown (dirt)
    ;; 5: brown (tree trunk)
    ;; 6: dark blue (water dark)
    ;; 7: blue (water)
    ;; 8: light blue (water light / UI)
    ;; 9: dark gray (stone)
    ;; 10: gray (stone/building)
    ;; 11: light gray (building highlight)
    ;; 12: white
    ;; 13: red (enemy/hp bar)
    ;; 14: dark red
    ;; 15: yellow (gold)
    ;; 16: dark yellow/orange
    ;; 17: skin tone
    ;; 18: dark skin
    ;; 19: blue team color (player)
    ;; 20: dark blue team
    ;; 21: red team color (enemy)
    ;; 22: dark red team
    ;; 23: bright green (hp bar)
    ;; 24: dark green (hp bar bg)
    ;; 25: purple (archer)
    ;; 26: dark purple
    ;; 27: cyan (selection)
    ;; 28: tan (path/road)
    ;; 29: dark tan
    ;; 30: UI dark
    ;; 31: UI medium
    ;; 32: gold sparkle
    ;; 33: tree dark green
    ;; 34: tree green
    ;; 35: tree light green
    ;; 36: shadow
    ;; 37: blood red
    ;; 38: minimap player
    ;; 39: minimap enemy
    ;; 40: minimap gold

    ;; 0: black
    (i32.store8 (i32.const 0x0040) (i32.const 0))
    (i32.store8 (i32.const 0x0041) (i32.const 0))
    (i32.store8 (i32.const 0x0042) (i32.const 0))
    ;; 1: dark green
    (i32.store8 (i32.const 0x0043) (i32.const 20))
    (i32.store8 (i32.const 0x0044) (i32.const 50))
    (i32.store8 (i32.const 0x0045) (i32.const 15))
    ;; 2: green (grass)
    (i32.store8 (i32.const 0x0046) (i32.const 34))
    (i32.store8 (i32.const 0x0047) (i32.const 85))
    (i32.store8 (i32.const 0x0048) (i32.const 25))
    ;; 3: light green
    (i32.store8 (i32.const 0x0049) (i32.const 55))
    (i32.store8 (i32.const 0x004A) (i32.const 110))
    (i32.store8 (i32.const 0x004B) (i32.const 40))
    ;; 4: dark brown (dirt)
    (i32.store8 (i32.const 0x004C) (i32.const 60))
    (i32.store8 (i32.const 0x004D) (i32.const 40))
    (i32.store8 (i32.const 0x004E) (i32.const 20))
    ;; 5: brown (trunk)
    (i32.store8 (i32.const 0x004F) (i32.const 90))
    (i32.store8 (i32.const 0x0050) (i32.const 60))
    (i32.store8 (i32.const 0x0051) (i32.const 30))
    ;; 6: dark blue (water)
    (i32.store8 (i32.const 0x0052) (i32.const 15))
    (i32.store8 (i32.const 0x0053) (i32.const 30))
    (i32.store8 (i32.const 0x0054) (i32.const 80))
    ;; 7: blue (water)
    (i32.store8 (i32.const 0x0055) (i32.const 30))
    (i32.store8 (i32.const 0x0056) (i32.const 60))
    (i32.store8 (i32.const 0x0057) (i32.const 130))
    ;; 8: light blue
    (i32.store8 (i32.const 0x0058) (i32.const 60))
    (i32.store8 (i32.const 0x0059) (i32.const 100))
    (i32.store8 (i32.const 0x005A) (i32.const 170))
    ;; 9: dark gray
    (i32.store8 (i32.const 0x005B) (i32.const 50))
    (i32.store8 (i32.const 0x005C) (i32.const 50))
    (i32.store8 (i32.const 0x005D) (i32.const 55))
    ;; 10: gray
    (i32.store8 (i32.const 0x005E) (i32.const 100))
    (i32.store8 (i32.const 0x005F) (i32.const 100))
    (i32.store8 (i32.const 0x0060) (i32.const 110))
    ;; 11: light gray
    (i32.store8 (i32.const 0x0061) (i32.const 160))
    (i32.store8 (i32.const 0x0062) (i32.const 160))
    (i32.store8 (i32.const 0x0063) (i32.const 170))
    ;; 12: white
    (i32.store8 (i32.const 0x0064) (i32.const 230))
    (i32.store8 (i32.const 0x0065) (i32.const 230))
    (i32.store8 (i32.const 0x0066) (i32.const 240))
    ;; 13: red
    (i32.store8 (i32.const 0x0067) (i32.const 220))
    (i32.store8 (i32.const 0x0068) (i32.const 40))
    (i32.store8 (i32.const 0x0069) (i32.const 40))
    ;; 14: dark red
    (i32.store8 (i32.const 0x006A) (i32.const 140))
    (i32.store8 (i32.const 0x006B) (i32.const 20))
    (i32.store8 (i32.const 0x006C) (i32.const 20))
    ;; 15: yellow (gold)
    (i32.store8 (i32.const 0x006D) (i32.const 255))
    (i32.store8 (i32.const 0x006E) (i32.const 220))
    (i32.store8 (i32.const 0x006F) (i32.const 50))
    ;; 16: dark yellow/orange
    (i32.store8 (i32.const 0x0070) (i32.const 200))
    (i32.store8 (i32.const 0x0071) (i32.const 150))
    (i32.store8 (i32.const 0x0072) (i32.const 30))
    ;; 17: skin tone
    (i32.store8 (i32.const 0x0073) (i32.const 220))
    (i32.store8 (i32.const 0x0074) (i32.const 180))
    (i32.store8 (i32.const 0x0075) (i32.const 140))
    ;; 18: dark skin
    (i32.store8 (i32.const 0x0076) (i32.const 170))
    (i32.store8 (i32.const 0x0077) (i32.const 130))
    (i32.store8 (i32.const 0x0078) (i32.const 100))
    ;; 19: blue team (player)
    (i32.store8 (i32.const 0x0079) (i32.const 50))
    (i32.store8 (i32.const 0x007A) (i32.const 80))
    (i32.store8 (i32.const 0x007B) (i32.const 200))
    ;; 20: dark blue team
    (i32.store8 (i32.const 0x007C) (i32.const 30))
    (i32.store8 (i32.const 0x007D) (i32.const 50))
    (i32.store8 (i32.const 0x007E) (i32.const 140))
    ;; 21: red team (enemy)
    (i32.store8 (i32.const 0x007F) (i32.const 200))
    (i32.store8 (i32.const 0x0080) (i32.const 50))
    (i32.store8 (i32.const 0x0081) (i32.const 50))
    ;; 22: dark red team
    (i32.store8 (i32.const 0x0082) (i32.const 140))
    (i32.store8 (i32.const 0x0083) (i32.const 30))
    (i32.store8 (i32.const 0x0084) (i32.const 30))
    ;; 23: bright green (hp)
    (i32.store8 (i32.const 0x0085) (i32.const 50))
    (i32.store8 (i32.const 0x0086) (i32.const 200))
    (i32.store8 (i32.const 0x0087) (i32.const 50))
    ;; 24: dark green (hp bg)
    (i32.store8 (i32.const 0x0088) (i32.const 30))
    (i32.store8 (i32.const 0x0089) (i32.const 60))
    (i32.store8 (i32.const 0x008A) (i32.const 30))
    ;; 25: purple (archer)
    (i32.store8 (i32.const 0x008B) (i32.const 140))
    (i32.store8 (i32.const 0x008C) (i32.const 50))
    (i32.store8 (i32.const 0x008D) (i32.const 180))
    ;; 26: dark purple
    (i32.store8 (i32.const 0x008E) (i32.const 90))
    (i32.store8 (i32.const 0x008F) (i32.const 30))
    (i32.store8 (i32.const 0x0090) (i32.const 120))
    ;; 27: cyan (selection)
    (i32.store8 (i32.const 0x0091) (i32.const 0))
    (i32.store8 (i32.const 0x0092) (i32.const 220))
    (i32.store8 (i32.const 0x0093) (i32.const 220))
    ;; 28: tan (path)
    (i32.store8 (i32.const 0x0094) (i32.const 160))
    (i32.store8 (i32.const 0x0095) (i32.const 130))
    (i32.store8 (i32.const 0x0096) (i32.const 80))
    ;; 29: dark tan
    (i32.store8 (i32.const 0x0097) (i32.const 120))
    (i32.store8 (i32.const 0x0098) (i32.const 95))
    (i32.store8 (i32.const 0x0099) (i32.const 60))
    ;; 30: UI dark
    (i32.store8 (i32.const 0x009A) (i32.const 20))
    (i32.store8 (i32.const 0x009B) (i32.const 15))
    (i32.store8 (i32.const 0x009C) (i32.const 30))
    ;; 31: UI medium
    (i32.store8 (i32.const 0x009D) (i32.const 40))
    (i32.store8 (i32.const 0x009E) (i32.const 35))
    (i32.store8 (i32.const 0x009F) (i32.const 55))
    ;; 32: gold sparkle
    (i32.store8 (i32.const 0x00A0) (i32.const 255))
    (i32.store8 (i32.const 0x00A1) (i32.const 255))
    (i32.store8 (i32.const 0x00A2) (i32.const 150))
    ;; 33: tree dark
    (i32.store8 (i32.const 0x00A3) (i32.const 15))
    (i32.store8 (i32.const 0x00A4) (i32.const 60))
    (i32.store8 (i32.const 0x00A5) (i32.const 15))
    ;; 34: tree green
    (i32.store8 (i32.const 0x00A6) (i32.const 25))
    (i32.store8 (i32.const 0x00A7) (i32.const 90))
    (i32.store8 (i32.const 0x00A8) (i32.const 20))
    ;; 35: tree light
    (i32.store8 (i32.const 0x00A9) (i32.const 45))
    (i32.store8 (i32.const 0x00AA) (i32.const 120))
    (i32.store8 (i32.const 0x00AB) (i32.const 35))
    ;; 36: shadow
    (i32.store8 (i32.const 0x00AC) (i32.const 10))
    (i32.store8 (i32.const 0x00AD) (i32.const 10))
    (i32.store8 (i32.const 0x00AE) (i32.const 15))
    ;; 37: blood
    (i32.store8 (i32.const 0x00AF) (i32.const 180))
    (i32.store8 (i32.const 0x00B0) (i32.const 10))
    (i32.store8 (i32.const 0x00B1) (i32.const 10))
    ;; 38: minimap player (bright blue)
    (i32.store8 (i32.const 0x00B2) (i32.const 80))
    (i32.store8 (i32.const 0x00B3) (i32.const 120))
    (i32.store8 (i32.const 0x00B4) (i32.const 255))
    ;; 39: minimap enemy (bright red)
    (i32.store8 (i32.const 0x00B5) (i32.const 255))
    (i32.store8 (i32.const 0x00B6) (i32.const 60))
    (i32.store8 (i32.const 0x00B7) (i32.const 60))
    ;; 40: minimap gold
    (i32.store8 (i32.const 0x00B8) (i32.const 255))
    (i32.store8 (i32.const 0x00B9) (i32.const 230))
    (i32.store8 (i32.const 0x00BA) (i32.const 0))
  )

  ;; ============ PIXEL DRAWING ============
  (func $put_pixel (param $x i32) (param $y i32) (param $col i32)
    (local $addr i32)
    (if (i32.and
          (i32.and (i32.ge_s (local.get $x) (i32.const 0)) (i32.lt_s (local.get $x) (i32.const 320)))
          (i32.and (i32.ge_s (local.get $y) (i32.const 0)) (i32.lt_s (local.get $y) (i32.const 200)))
        )
      (then
        (local.set $addr (i32.add (i32.const 0x0340)
          (i32.add (i32.mul (local.get $y) (i32.const 320)) (local.get $x))))
        (i32.store8 (local.get $addr) (local.get $col))
      )
    )
  )

  ;; Fill rect
  (func $fill_rect (param $x i32) (param $y i32) (param $w i32) (param $h i32) (param $col i32)
    (local $ix i32)
    (local $iy i32)
    (local.set $iy (i32.const 0))
    (block $brk_y
      (loop $lp_y
        (br_if $brk_y (i32.ge_s (local.get $iy) (local.get $h)))
        (local.set $ix (i32.const 0))
        (block $brk_x
          (loop $lp_x
            (br_if $brk_x (i32.ge_s (local.get $ix) (local.get $w)))
            (call $put_pixel
              (i32.add (local.get $x) (local.get $ix))
              (i32.add (local.get $y) (local.get $iy))
              (local.get $col))
            (local.set $ix (i32.add (local.get $ix) (i32.const 1)))
            (br $lp_x)
          )
        )
        (local.set $iy (i32.add (local.get $iy) (i32.const 1)))
        (br $lp_y)
      )
    )
  )

  ;; Horizontal line
  (func $hline (param $x i32) (param $y i32) (param $len i32) (param $col i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $brk
      (loop $lp
        (br_if $brk (i32.ge_s (local.get $i) (local.get $len)))
        (call $put_pixel (i32.add (local.get $x) (local.get $i)) (local.get $y) (local.get $col))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)
      )
    )
  )

  (func $vline (param $x i32) (param $y i32) (param $len i32) (param $col i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $brk
      (loop $lp
        (br_if $brk (i32.ge_s (local.get $i) (local.get $len)))
        (call $put_pixel (local.get $x) (i32.add (local.get $y) (local.get $i)) (local.get $col))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)
      )
    )
  )

  ;; Place an ellipse of given tile type on the map
  (func $place_ellipse (param $cx i32) (param $cy i32) (param $rx i32) (param $ry i32) (param $tile i32)
    (local $x i32)
    (local $y i32)
    (local $dx i32)
    (local $dy i32)
    (local $addr i32)
    (local.set $y (i32.sub (local.get $cy) (local.get $ry)))
    (block $brk_y
      (loop $lp_y
        (br_if $brk_y (i32.gt_s (local.get $y) (i32.add (local.get $cy) (local.get $ry))))
        (local.set $x (i32.sub (local.get $cx) (local.get $rx)))
        (block $brk_x
          (loop $lp_x
            (br_if $brk_x (i32.gt_s (local.get $x) (i32.add (local.get $cx) (local.get $rx))))
            (if (i32.and
                  (i32.and (i32.ge_s (local.get $x) (i32.const 0)) (i32.lt_s (local.get $x) (i32.const 128)))
                  (i32.and (i32.ge_s (local.get $y) (i32.const 0)) (i32.lt_s (local.get $y) (i32.const 128))))
              (then
                ;; Check if inside ellipse: (dx/rx)^2 + (dy/ry)^2 <= 1
                ;; Multiply out: dx*dx*ry*ry + dy*dy*rx*rx <= rx*rx*ry*ry
                (local.set $dx (i32.sub (local.get $x) (local.get $cx)))
                (local.set $dy (i32.sub (local.get $y) (local.get $cy)))
                (if (i32.le_s
                      (i32.add
                        (i32.mul (i32.mul (local.get $dx) (local.get $dx)) (i32.mul (local.get $ry) (local.get $ry)))
                        (i32.mul (i32.mul (local.get $dy) (local.get $dy)) (i32.mul (local.get $rx) (local.get $rx))))
                      (i32.mul (i32.mul (local.get $rx) (local.get $rx)) (i32.mul (local.get $ry) (local.get $ry))))
                  (then
                    (local.set $addr (i32.add (i32.const 0x10400)
                      (i32.add (i32.mul (local.get $y) (i32.const 128)) (local.get $x))))
                    (i32.store8 (local.get $addr) (local.get $tile))
                  )
                )
              )
            )
            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (br $lp_x)
          )
        )
        (local.set $y (i32.add (local.get $y) (i32.const 1)))
        (br $lp_y)
      )
    )
  )

  ;; ============ MAP GENERATION ============
  (func $generate_map
    (local $x i32)
    (local $y i32)
    (local $addr i32)
    (local $r i32)
    (local $tile i32)
    (local $i i32)
    (local $cx i32)
    (local $cy i32)
    (local $dx i32)
    (local $dy i32)
    (local $dist i32)

    ;; Fill with grass
    (local.set $y (i32.const 0))
    (block $brk_y
      (loop $lp_y
        (br_if $brk_y (i32.ge_s (local.get $y) (i32.const 128)))
        (local.set $x (i32.const 0))
        (block $brk_x
          (loop $lp_x
            (br_if $brk_x (i32.ge_s (local.get $x) (i32.const 128)))
            (local.set $addr (i32.add (i32.const 0x10400)
              (i32.add (i32.mul (local.get $y) (i32.const 128)) (local.get $x))))
            ;; terrain: 0=grass, 1=grass_dark, 2=grass_light, 3=dirt, 4=water, 5=tree, 6=stone, 7=gold
            (local.set $r (i32.and (call $rng) (i32.const 255)))
            (if (i32.lt_u (local.get $r) (i32.const 180))
              (then (local.set $tile (i32.const 0))) ;; grass
              (else
                (if (i32.lt_u (local.get $r) (i32.const 210))
                  (then (local.set $tile (i32.const 1))) ;; dark grass
                  (else (local.set $tile (i32.const 2))) ;; light grass
                )
              )
            )
            (i32.store8 (local.get $addr) (local.get $tile))
            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (br $lp_x)
          )
        )
        (local.set $y (i32.add (local.get $y) (i32.const 1)))
        (br $lp_y)
      )
    )

    ;; === MOUNTAIN RANGE (stone=6) across center, diagonal NW-SE ===
    ;; Creates a natural barrier with gaps for choke points
    (local.set $y (i32.const 35))
    (block $mt_brk
      (loop $mt_lp
        (br_if $mt_brk (i32.ge_s (local.get $y) (i32.const 95)))
        ;; Mountain center follows diagonal: x = 64 + (y-64)*0.5 with noise
        (local.set $cx (i32.add
          (i32.add (i32.const 55) (i32.shr_s (i32.sub (local.get $y) (i32.const 64)) (i32.const 1)))
          (i32.sub (i32.rem_u (call $rng) (i32.const 5)) (i32.const 2))))
        ;; Width varies: thicker in middle, thinner at edges
        (local.set $dist (call $abs (i32.sub (local.get $y) (i32.const 64))))
        (local.set $r (i32.sub (i32.const 3) (i32.shr_u (local.get $dist) (i32.const 4))))
        (if (i32.lt_s (local.get $r) (i32.const 1)) (then (local.set $r (i32.const 1))))
        ;; Gap at y=46-56 (north choke) and y=74-84 (south choke)
        (if (i32.and
              (i32.or
                (i32.and (i32.ge_s (local.get $y) (i32.const 46)) (i32.le_s (local.get $y) (i32.const 56)))
                (i32.and (i32.ge_s (local.get $y) (i32.const 74)) (i32.le_s (local.get $y) (i32.const 84))))
              (i32.const 1))
          (then (local.set $r (i32.const 0))) ;; no mountain at choke
        )
        (local.set $x (i32.sub (local.get $cx) (local.get $r)))
        (block $mx_brk
          (loop $mx_lp
            (br_if $mx_brk (i32.gt_s (local.get $x) (i32.add (local.get $cx) (local.get $r))))
            (if (i32.and
                  (i32.and (i32.ge_s (local.get $x) (i32.const 0)) (i32.lt_s (local.get $x) (i32.const 128)))
                  (i32.and (i32.ge_s (local.get $y) (i32.const 0)) (i32.lt_s (local.get $y) (i32.const 128))))
              (then
                (local.set $addr (i32.add (i32.const 0x10400)
                  (i32.add (i32.mul (local.get $y) (i32.const 128)) (local.get $x))))
                (i32.store8 (local.get $addr) (i32.const 6)) ;; stone
              )
            )
            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (br $mx_lp)
          )
        )
        (local.set $y (i32.add (local.get $y) (i32.const 1)))
        (br $mt_lp)
      )
    )

    ;; === LAKES (water=4) ===
    ;; Lake 1: west side (30, 70) - blocks flanking
    (call $place_ellipse (i32.const 25) (i32.const 72) (i32.const 8) (i32.const 5) (i32.const 4))
    ;; Lake 2: east side (95, 55) - mirror
    (call $place_ellipse (i32.const 95) (i32.const 52) (i32.const 7) (i32.const 6) (i32.const 4))
    ;; Lake 3: small pond near player base
    (call $place_ellipse (i32.const 30) (i32.const 110) (i32.const 4) (i32.const 3) (i32.const 4))
    ;; Lake 4: small pond near enemy base
    (call $place_ellipse (i32.const 98) (i32.const 18) (i32.const 4) (i32.const 3) (i32.const 4))

    ;; === FOREST CLUSTERS (tree=5) ===
    (local.set $i (i32.const 0))
    (block $brk_tc
      (loop $lp_tc
        (br_if $brk_tc (i32.ge_s (local.get $i) (i32.const 18)))
        (local.set $cx (i32.add (i32.const 10) (i32.rem_u (call $rng) (i32.const 108))))
        (local.set $cy (i32.add (i32.const 10) (i32.rem_u (call $rng) (i32.const 108))))
        ;; Place 8-12 trees around center
        (local.set $x (i32.const 0))
        (block $brk_t
          (loop $lp_t
            (br_if $brk_t (i32.ge_s (local.get $x) (i32.const 10)))
            (local.set $dx (i32.add (local.get $cx)
              (i32.sub (i32.rem_u (call $rng) (i32.const 7)) (i32.const 3))))
            (local.set $dy (i32.add (local.get $cy)
              (i32.sub (i32.rem_u (call $rng) (i32.const 7)) (i32.const 3))))
            (if (i32.and
                  (i32.and (i32.ge_s (local.get $dx) (i32.const 0)) (i32.lt_s (local.get $dx) (i32.const 128)))
                  (i32.and (i32.ge_s (local.get $dy) (i32.const 0)) (i32.lt_s (local.get $dy) (i32.const 128)))
                )
              (then
                (local.set $addr (i32.add (i32.const 0x10400)
                  (i32.add (i32.mul (local.get $dy) (i32.const 128)) (local.get $dx))))
                ;; Only place tree on grass
                (if (i32.lt_u (i32.load8_u (local.get $addr)) (i32.const 3))
                  (then (i32.store8 (local.get $addr) (i32.const 5)))
                )
              )
            )
            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (br $lp_t)
          )
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_tc)
      )
    )

    ;; Clear areas for bases (player bottom-left, enemy top-right)
    ;; Player base area: tiles 5-20, 95-115
    (local.set $y (i32.const 95))
    (block $bp1
      (loop $lp_bp1
        (br_if $bp1 (i32.ge_s (local.get $y) (i32.const 120)))
        (local.set $x (i32.const 5))
        (block $bp2
          (loop $lp_bp2
            (br_if $bp2 (i32.ge_s (local.get $x) (i32.const 25)))
            (local.set $addr (i32.add (i32.const 0x10400)
              (i32.add (i32.mul (local.get $y) (i32.const 128)) (local.get $x))))
            (i32.store8 (local.get $addr) (i32.const 3)) ;; light grass
            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (br $lp_bp2)
          )
        )
        (local.set $y (i32.add (local.get $y) (i32.const 1)))
        (br $lp_bp1)
      )
    )
    ;; Enemy base area: tiles 105-120, 5-25
    (local.set $y (i32.const 5))
    (block $be1
      (loop $lp_be1
        (br_if $be1 (i32.ge_s (local.get $y) (i32.const 25)))
        (local.set $x (i32.const 105))
        (block $be2
          (loop $lp_be2
            (br_if $be2 (i32.ge_s (local.get $x) (i32.const 123)))
            (local.set $addr (i32.add (i32.const 0x10400)
              (i32.add (i32.mul (local.get $y) (i32.const 128)) (local.get $x))))
            (i32.store8 (local.get $addr) (i32.const 3))
            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (br $lp_be2)
          )
        )
        (local.set $y (i32.add (local.get $y) (i32.const 1)))
        (br $lp_be1)
      )
    )

    ;; Place gold mine tiles near each base
    ;; Player gold: around tile (25, 105)
    (local.set $addr (i32.add (i32.const 0x10400) (i32.add (i32.mul (i32.const 105) (i32.const 128)) (i32.const 25))))
    (i32.store8 (local.get $addr) (i32.const 7))
    (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (i32.const 7))
    (i32.store8 (i32.add (local.get $addr) (i32.const 128)) (i32.const 7))
    (i32.store8 (i32.add (local.get $addr) (i32.const 129)) (i32.const 7))

    ;; Enemy gold: around tile (100, 15)
    (local.set $addr (i32.add (i32.const 0x10400) (i32.add (i32.mul (i32.const 15) (i32.const 128)) (i32.const 100))))
    (i32.store8 (local.get $addr) (i32.const 7))
    (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (i32.const 7))
    (i32.store8 (i32.add (local.get $addr) (i32.const 128)) (i32.const 7))
    (i32.store8 (i32.add (local.get $addr) (i32.const 129)) (i32.const 7))

    ;; Center gold mine
    (local.set $addr (i32.add (i32.const 0x10400) (i32.add (i32.mul (i32.const 40) (i32.const 128)) (i32.const 60))))
    (i32.store8 (local.get $addr) (i32.const 7))
    (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (i32.const 7))
  )

  ;; ============ CREATE BUILDING ============
  (func $create_building (param $type i32) (param $team i32) (param $x i32) (param $y i32) (result i32)
    (local $i i32)
    (local $addr i32)
    (local $w i32)
    (local $h i32)
    (local $hp i32)
    ;; Find free building slot
    (local.set $i (i32.const 0))
    (block $found
      (loop $search
        (br_if $found (i32.ge_s (local.get $i) (i32.const 32)))
        (local.set $addr (i32.add (i32.const 0x14C00) (i32.mul (local.get $i) (i32.const 32))))
        (if (i32.eqz (i32.load8_u (local.get $addr)))
          (then
            ;; Set size based on type
            (if (i32.or (i32.eq (local.get $type) (i32.const 0))
                        (i32.eq (local.get $type) (i32.const 4))) ;; town hall / enemy hall
              (then
                (local.set $w (i32.const 4))
                (local.set $h (i32.const 4))
                (local.set $hp (i32.const 500))
              )
              (else
                (if (i32.or (i32.eq (local.get $type) (i32.const 1))
                            (i32.eq (local.get $type) (i32.const 5))) ;; barracks
                  (then
                    (local.set $w (i32.const 3))
                    (local.set $h (i32.const 3))
                    (local.set $hp (i32.const 300))
                  )
                  (else
                    (if (i32.eq (local.get $type) (i32.const 3)) ;; gold mine
                      (then
                        (local.set $w (i32.const 2))
                        (local.set $h (i32.const 2))
                        (local.set $hp (i32.const 9999))
                      )
                      (else ;; tower
                        (local.set $w (i32.const 2))
                        (local.set $h (i32.const 2))
                        (local.set $hp (i32.const 200))
                      )
                    )
                  )
                )
              )
            )
            (i32.store8 (local.get $addr) (i32.const 1)) ;; active
            (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (local.get $type))
            (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (local.get $team))
            (i32.store8 (i32.add (local.get $addr) (i32.const 3)) (i32.const 0)) ;; normal
            (i32.store16 (i32.add (local.get $addr) (i32.const 4)) (local.get $x))
            (i32.store16 (i32.add (local.get $addr) (i32.const 6)) (local.get $y))
            (i32.store16 (i32.add (local.get $addr) (i32.const 8)) (local.get $hp))
            (i32.store16 (i32.add (local.get $addr) (i32.const 10)) (local.get $hp))
            (i32.store8 (i32.add (local.get $addr) (i32.const 12)) (local.get $w))
            (i32.store8 (i32.add (local.get $addr) (i32.const 13)) (local.get $h))
            (return (local.get $i))
          )
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $search)
      )
    )
    (i32.const -1)
  )

  ;; ============ CREATE UNIT ============
  (func $create_unit (param $type i32) (param $team i32) (param $x i32) (param $y i32) (result i32)
    (local $i i32)
    (local $addr i32)
    (local $hp i32)
    (local $atk i32)
    (local $rng i32)
    (local $spd i32)
    (local $cd i32)

    ;; Stats per unit type
    (if (i32.eq (local.get $type) (i32.const 0)) ;; worker
      (then
        (local.set $hp (i32.const 30))
        (local.set $atk (i32.const 3))
        (local.set $rng (i32.const 8))
        (local.set $spd (i32.const 2))
        (local.set $cd (i32.const 30))
      )
    )
    (if (i32.or (i32.eq (local.get $type) (i32.const 1))
                (i32.eq (local.get $type) (i32.const 3))) ;; soldier / enemy soldier
      (then
        (local.set $hp (i32.const 60))
        (local.set $atk (i32.const 8))
        (local.set $rng (i32.const 10))
        (local.set $spd (i32.const 2))
        (local.set $cd (i32.const 20))
      )
    )
    (if (i32.or (i32.eq (local.get $type) (i32.const 2))
                (i32.eq (local.get $type) (i32.const 4))) ;; archer / enemy archer
      (then
        (local.set $hp (i32.const 35))
        (local.set $atk (i32.const 6))
        (local.set $rng (i32.const 40))
        (local.set $spd (i32.const 2))
        (local.set $cd (i32.const 25))
      )
    )

    ;; Find free slot
    (local.set $i (i32.const 0))
    (block $found
      (loop $search
        (br_if $found (i32.ge_s (local.get $i) (i32.const 64)))
        (local.set $addr (i32.add (i32.const 0x14400) (i32.mul (local.get $i) (i32.const 32))))
        (if (i32.eqz (i32.load8_u (local.get $addr)))
          (then
            (i32.store8 (local.get $addr) (i32.const 1)) ;; active
            (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (local.get $type))
            (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (local.get $team))
            (i32.store8 (i32.add (local.get $addr) (i32.const 3)) (i32.const 0)) ;; idle
            (i32.store16 (i32.add (local.get $addr) (i32.const 4)) (local.get $x))
            (i32.store16 (i32.add (local.get $addr) (i32.const 6)) (local.get $y))
            (i32.store16 (i32.add (local.get $addr) (i32.const 8)) (local.get $x)) ;; target = current
            (i32.store16 (i32.add (local.get $addr) (i32.const 10)) (local.get $y))
            (i32.store16 (i32.add (local.get $addr) (i32.const 12)) (local.get $hp))
            (i32.store16 (i32.add (local.get $addr) (i32.const 14)) (local.get $hp))
            (i32.store8 (i32.add (local.get $addr) (i32.const 16)) (local.get $atk))
            (i32.store8 (i32.add (local.get $addr) (i32.const 17)) (local.get $rng))
            (i32.store8 (i32.add (local.get $addr) (i32.const 18)) (local.get $spd))
            (i32.store8 (i32.add (local.get $addr) (i32.const 19)) (i32.const 0)) ;; not selected
            (i32.store8 (i32.add (local.get $addr) (i32.const 24)) (i32.const 255)) ;; no target unit (signed -1)
            (i32.store8 (i32.add (local.get $addr) (i32.const 26)) (local.get $cd))
            (return (local.get $i))
          )
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $search)
      )
    )
    (i32.const -1)
  )

  ;; ============ DRAW MAP TILE ============
  (func $draw_tile (param $tx i32) (param $ty i32) (param $sx i32) (param $sy i32)
    (local $tile i32)
    (local $addr i32)
    (local $col i32)
    (local $px i32)
    (local $py i32)
    (local $r i32)

    ;; Bounds check
    (if (i32.or
          (i32.or (i32.lt_s (local.get $tx) (i32.const 0)) (i32.ge_s (local.get $tx) (i32.const 128)))
          (i32.or (i32.lt_s (local.get $ty) (i32.const 0)) (i32.ge_s (local.get $ty) (i32.const 128)))
        )
      (then (return))
    )

    (local.set $addr (i32.add (i32.const 0x10400)
      (i32.add (i32.mul (local.get $ty) (i32.const 128)) (local.get $tx))))
    (local.set $tile (i32.load8_u (local.get $addr)))

    ;; Pick color
    (if (i32.eq (local.get $tile) (i32.const 0)) (then (local.set $col (i32.const 2)))) ;; grass
    (if (i32.eq (local.get $tile) (i32.const 1)) (then (local.set $col (i32.const 1)))) ;; dark grass
    (if (i32.eq (local.get $tile) (i32.const 2)) (then (local.set $col (i32.const 3)))) ;; light grass
    (if (i32.eq (local.get $tile) (i32.const 3)) (then (local.set $col (i32.const 4)))) ;; dirt
    (if (i32.eq (local.get $tile) (i32.const 4)) (then (local.set $col (i32.const 7)))) ;; water
    (if (i32.eq (local.get $tile) (i32.const 6)) (then (local.set $col (i32.const 9)))) ;; stone
    (if (i32.eq (local.get $tile) (i32.const 7)) (then (local.set $col (i32.const 15)))) ;; gold

    ;; Fill 8x8 tile
    (call $fill_rect (local.get $sx) (local.get $sy) (i32.const 8) (i32.const 8) (local.get $col))

    ;; Water shimmer
    (if (i32.eq (local.get $tile) (i32.const 4))
      (then
        (local.set $r (i32.and (i32.add (local.get $tx) (i32.load (i32.const 0))) (i32.const 3)))
        (if (i32.eqz (local.get $r))
          (then
            (call $put_pixel (i32.add (local.get $sx) (i32.const 2))
              (i32.add (local.get $sy) (i32.const 3)) (i32.const 8))
            (call $put_pixel (i32.add (local.get $sx) (i32.const 5))
              (i32.add (local.get $sy) (i32.const 6)) (i32.const 8))
          )
        )
      )
    )

    ;; Stone/mountain detail
    (if (i32.eq (local.get $tile) (i32.const 6))
      (then
        ;; Highlight pixels for rocky texture
        (call $put_pixel (i32.add (local.get $sx) (i32.const 1))
          (i32.add (local.get $sy) (i32.const 1)) (i32.const 10))
        (call $put_pixel (i32.add (local.get $sx) (i32.const 5))
          (i32.add (local.get $sy) (i32.const 3)) (i32.const 10))
        (call $put_pixel (i32.add (local.get $sx) (i32.const 3))
          (i32.add (local.get $sy) (i32.const 6)) (i32.const 10))
        ;; Dark crevice pixels
        (call $put_pixel (i32.add (local.get $sx) (i32.const 4))
          (i32.add (local.get $sy) (i32.const 2)) (i32.const 0))
        (call $put_pixel (i32.add (local.get $sx) (i32.const 2))
          (i32.add (local.get $sy) (i32.const 5)) (i32.const 0))
      )
    )

    ;; Gold sparkle
    (if (i32.eq (local.get $tile) (i32.const 7))
      (then
        (local.set $r (i32.and (i32.add (local.get $tx) (i32.load (i32.const 0))) (i32.const 7)))
        (call $put_pixel (i32.add (local.get $sx) (local.get $r))
          (i32.add (local.get $sy) (i32.const 3)) (i32.const 32))
        (call $put_pixel (i32.add (local.get $sx) (i32.const 4))
          (i32.add (local.get $sy) (local.get $r)) (i32.const 16))
      )
    )

    ;; Tree: draw a pixel-art tree on top
    (if (i32.eq (local.get $tile) (i32.const 5))
      (then
        ;; Ground
        (call $fill_rect (local.get $sx) (local.get $sy) (i32.const 8) (i32.const 8) (i32.const 2))
        ;; Trunk
        (call $fill_rect (i32.add (local.get $sx) (i32.const 3))
          (i32.add (local.get $sy) (i32.const 5)) (i32.const 2) (i32.const 3) (i32.const 5))
        ;; Canopy - triangle/circle shape
        (call $fill_rect (i32.add (local.get $sx) (i32.const 2))
          (i32.add (local.get $sy) (i32.const 1)) (i32.const 4) (i32.const 4) (i32.const 34))
        (call $fill_rect (i32.add (local.get $sx) (i32.const 1))
          (i32.add (local.get $sy) (i32.const 2)) (i32.const 6) (i32.const 2) (i32.const 34))
        ;; Highlights
        (call $put_pixel (i32.add (local.get $sx) (i32.const 3))
          (i32.add (local.get $sy) (i32.const 1)) (i32.const 35))
        (call $put_pixel (i32.add (local.get $sx) (i32.const 2))
          (i32.add (local.get $sy) (i32.const 2)) (i32.const 35))
        ;; Shadow
        (call $put_pixel (i32.add (local.get $sx) (i32.const 5))
          (i32.add (local.get $sy) (i32.const 4)) (i32.const 33))
      )
    )
  )

  ;; ============ DRAW BUILDING ============
  (func $draw_building (param $idx i32) (param $cam_x i32) (param $cam_y i32)
    (local $addr i32)
    (local $type i32)
    (local $team i32)
    (local $bx i32)
    (local $by i32)
    (local $sx i32)
    (local $sy i32)
    (local $w i32)
    (local $h i32)
    (local $pw i32)
    (local $ph i32)
    (local $col1 i32)
    (local $col2 i32)
    (local $col3 i32)
    (local $hp i32)
    (local $maxhp i32)
    (local $hpw i32)

    (local.set $addr (i32.add (i32.const 0x14C00) (i32.mul (local.get $idx) (i32.const 32))))
    (if (i32.eqz (i32.load8_u (local.get $addr))) (then (return)))

    (local.set $type (i32.load8_u (i32.add (local.get $addr) (i32.const 1))))
    (local.set $team (i32.load8_u (i32.add (local.get $addr) (i32.const 2))))
    (local.set $bx (i32.load16_s (i32.add (local.get $addr) (i32.const 4))))
    (local.set $by (i32.load16_s (i32.add (local.get $addr) (i32.const 6))))
    (local.set $w (i32.load8_u (i32.add (local.get $addr) (i32.const 12))))
    (local.set $h (i32.load8_u (i32.add (local.get $addr) (i32.const 13))))
    (local.set $hp (i32.load16_s (i32.add (local.get $addr) (i32.const 8))))
    (local.set $maxhp (i32.load16_s (i32.add (local.get $addr) (i32.const 10))))

    ;; World to screen
    (local.set $sx (i32.sub (i32.mul (local.get $bx) (i32.const 8)) (local.get $cam_x)))
    (local.set $sy (i32.sub (i32.mul (local.get $by) (i32.const 8)) (local.get $cam_y)))

    (local.set $pw (i32.mul (local.get $w) (i32.const 8)))
    (local.set $ph (i32.mul (local.get $h) (i32.const 8)))

    ;; Visibility check
    (if (i32.or
          (i32.or (i32.gt_s (local.get $sx) (i32.const 320))
                  (i32.lt_s (i32.add (local.get $sx) (local.get $pw)) (i32.const 0)))
          (i32.or (i32.gt_s (local.get $sy) (i32.const 200))
                  (i32.lt_s (i32.add (local.get $sy) (local.get $ph)) (i32.const 0)))
        )
      (then (return))
    )

    ;; Colors based on team
    (if (i32.eqz (local.get $team))
      (then
        (local.set $col1 (i32.const 19)) ;; blue
        (local.set $col2 (i32.const 20)) ;; dark blue
        (local.set $col3 (i32.const 11)) ;; highlight
      )
      (else
        (local.set $col1 (i32.const 21)) ;; red
        (local.set $col2 (i32.const 22)) ;; dark red
        (local.set $col3 (i32.const 11))
      )
    )

    ;; Draw based on type
    (if (i32.or (i32.eq (local.get $type) (i32.const 0))
                (i32.eq (local.get $type) (i32.const 4))) ;; town hall
      (then
        ;; Base
        (call $fill_rect (local.get $sx) (local.get $sy) (local.get $pw) (local.get $ph) (local.get $col2))
        ;; Main body
        (call $fill_rect (i32.add (local.get $sx) (i32.const 2))
          (i32.add (local.get $sy) (i32.const 4))
          (i32.sub (local.get $pw) (i32.const 4))
          (i32.sub (local.get $ph) (i32.const 6))
          (local.get $col1))
        ;; Roof (triangle-ish)
        (call $fill_rect (i32.add (local.get $sx) (i32.const 4))
          (local.get $sy) (i32.sub (local.get $pw) (i32.const 8)) (i32.const 4) (local.get $col1))
        (call $fill_rect (i32.add (local.get $sx) (i32.const 6))
          (local.get $sy) (i32.sub (local.get $pw) (i32.const 12)) (i32.const 2) (local.get $col3))
        ;; Door
        (call $fill_rect (i32.add (local.get $sx) (i32.const 12))
          (i32.add (local.get $sy) (i32.const 22)) (i32.const 6) (i32.const 8) (i32.const 5))
        ;; Windows
        (call $fill_rect (i32.add (local.get $sx) (i32.const 5))
          (i32.add (local.get $sy) (i32.const 12)) (i32.const 4) (i32.const 4) (i32.const 15))
        (call $fill_rect (i32.add (local.get $sx) (i32.const 21))
          (i32.add (local.get $sy) (i32.const 12)) (i32.const 4) (i32.const 4) (i32.const 15))
        ;; Flag on top
        (call $fill_rect (i32.add (local.get $sx) (i32.const 14))
          (i32.sub (local.get $sy) (i32.const 4)) (i32.const 1) (i32.const 4) (i32.const 10))
        (call $fill_rect (i32.add (local.get $sx) (i32.const 15))
          (i32.sub (local.get $sy) (i32.const 4)) (i32.const 4) (i32.const 3) (local.get $col1))
      )
    )

    (if (i32.or (i32.eq (local.get $type) (i32.const 1))
                (i32.eq (local.get $type) (i32.const 5))) ;; barracks
      (then
        ;; Base
        (call $fill_rect (local.get $sx) (local.get $sy) (local.get $pw) (local.get $ph) (local.get $col2))
        ;; Body
        (call $fill_rect (i32.add (local.get $sx) (i32.const 1))
          (i32.add (local.get $sy) (i32.const 2))
          (i32.sub (local.get $pw) (i32.const 2))
          (i32.sub (local.get $ph) (i32.const 3))
          (local.get $col1))
        ;; Roof line
        (call $hline (local.get $sx) (i32.add (local.get $sy) (i32.const 1)) (local.get $pw) (local.get $col3))
        ;; Door
        (call $fill_rect (i32.add (local.get $sx) (i32.const 9))
          (i32.add (local.get $sy) (i32.const 16)) (i32.const 5) (i32.const 6) (i32.const 5))
        ;; Sword emblem
        (call $fill_rect (i32.add (local.get $sx) (i32.const 3))
          (i32.add (local.get $sy) (i32.const 6)) (i32.const 1) (i32.const 8) (i32.const 11))
        (call $fill_rect (i32.add (local.get $sx) (i32.const 1))
          (i32.add (local.get $sy) (i32.const 9)) (i32.const 5) (i32.const 1) (i32.const 11))
      )
    )

    (if (i32.eq (local.get $type) (i32.const 3)) ;; gold mine
      (then
        ;; Rocky exterior
        (call $fill_rect (local.get $sx) (local.get $sy) (local.get $pw) (local.get $ph) (i32.const 9))
        (call $fill_rect (i32.add (local.get $sx) (i32.const 1))
          (i32.add (local.get $sy) (i32.const 1))
          (i32.sub (local.get $pw) (i32.const 2))
          (i32.sub (local.get $ph) (i32.const 2))
          (i32.const 10))
        ;; Gold veins
        (call $put_pixel (i32.add (local.get $sx) (i32.const 4))
          (i32.add (local.get $sy) (i32.const 3)) (i32.const 15))
        (call $put_pixel (i32.add (local.get $sx) (i32.const 8))
          (i32.add (local.get $sy) (i32.const 7)) (i32.const 15))
        (call $put_pixel (i32.add (local.get $sx) (i32.const 3))
          (i32.add (local.get $sy) (i32.const 10)) (i32.const 32))
        (call $put_pixel (i32.add (local.get $sx) (i32.const 10))
          (i32.add (local.get $sy) (i32.const 5)) (i32.const 32))
        ;; Entrance
        (call $fill_rect (i32.add (local.get $sx) (i32.const 5))
          (i32.add (local.get $sy) (i32.const 10)) (i32.const 6) (i32.const 5) (i32.const 0))
      )
    )

    ;; HP bar (only if damaged and not gold mine)
    (if (i32.and
          (i32.lt_s (local.get $hp) (local.get $maxhp))
          (i32.ne (local.get $type) (i32.const 3))
        )
      (then
        (local.set $hpw (i32.div_u (i32.mul (local.get $hp) (local.get $pw)) (local.get $maxhp)))
        (call $fill_rect (local.get $sx) (i32.sub (local.get $sy) (i32.const 3))
          (local.get $pw) (i32.const 2) (i32.const 14))
        (call $fill_rect (local.get $sx) (i32.sub (local.get $sy) (i32.const 3))
          (local.get $hpw) (i32.const 2) (i32.const 23))
      )
    )
  )

  ;; ============ DRAW UNIT (pixel art characters!) ============
  (func $draw_unit (param $idx i32) (param $cam_x i32) (param $cam_y i32)
    (local $addr i32)
    (local $type i32)
    (local $team i32)
    (local $state i32)
    (local $ux i32)
    (local $uy i32)
    (local $sx i32)
    (local $sy i32)
    (local $selected i32)
    (local $anim i32)
    (local $col1 i32)
    (local $col2 i32)
    (local $hp i32)
    (local $maxhp i32)
    (local $hpw i32)
    (local $facing i32)
    (local $carry i32)

    (local.set $addr (i32.add (i32.const 0x14400) (i32.mul (local.get $idx) (i32.const 32))))
    (if (i32.eqz (i32.load8_u (local.get $addr))) (then (return)))
    (local.set $state (i32.load8_u (i32.add (local.get $addr) (i32.const 3))))
    (if (i32.eq (local.get $state) (i32.const 4)) (then (return))) ;; dead

    (local.set $type (i32.load8_u (i32.add (local.get $addr) (i32.const 1))))
    (local.set $team (i32.load8_u (i32.add (local.get $addr) (i32.const 2))))
    (local.set $ux (i32.load16_s (i32.add (local.get $addr) (i32.const 4))))
    (local.set $uy (i32.load16_s (i32.add (local.get $addr) (i32.const 6))))
    (local.set $selected (i32.load8_u (i32.add (local.get $addr) (i32.const 19))))
    (local.set $anim (i32.load8_u (i32.add (local.get $addr) (i32.const 20))))
    (local.set $facing (i32.load8_u (i32.add (local.get $addr) (i32.const 23))))
    (local.set $hp (i32.load16_s (i32.add (local.get $addr) (i32.const 12))))
    (local.set $maxhp (i32.load16_s (i32.add (local.get $addr) (i32.const 14))))
    (local.set $carry (i32.load8_u (i32.add (local.get $addr) (i32.const 25))))

    ;; World to screen
    (local.set $sx (i32.sub (local.get $ux) (local.get $cam_x)))
    (local.set $sy (i32.sub (local.get $uy) (local.get $cam_y)))

    ;; Visibility check
    (if (i32.or
          (i32.or (i32.lt_s (local.get $sx) (i32.const -8)) (i32.gt_s (local.get $sx) (i32.const 324)))
          (i32.or (i32.lt_s (local.get $sy) (i32.const -8)) (i32.gt_s (local.get $sy) (i32.const 204)))
        )
      (then (return))
    )

    ;; Team colors
    (if (i32.eqz (local.get $team))
      (then
        (local.set $col1 (i32.const 19)) ;; blue
        (local.set $col2 (i32.const 20))
      )
      (else
        (local.set $col1 (i32.const 21)) ;; red
        (local.set $col2 (i32.const 22))
      )
    )

    ;; Selection circle (dashed)
    (if (local.get $selected)
      (then
        (call $put_pixel (i32.add (local.get $sx) (i32.const 1))
          (i32.add (local.get $sy) (i32.const 8)) (i32.const 27))
        (call $put_pixel (i32.add (local.get $sx) (i32.const 2))
          (i32.add (local.get $sy) (i32.const 9)) (i32.const 27))
        (call $put_pixel (i32.add (local.get $sx) (i32.const 3))
          (i32.add (local.get $sy) (i32.const 9)) (i32.const 27))
        (call $put_pixel (i32.add (local.get $sx) (i32.const 4))
          (i32.add (local.get $sy) (i32.const 9)) (i32.const 27))
        (call $put_pixel (i32.add (local.get $sx) (i32.const 5))
          (i32.add (local.get $sy) (i32.const 8)) (i32.const 27))
        (call $put_pixel (i32.sub (local.get $sx) (i32.const 0))
          (i32.add (local.get $sy) (i32.const 7)) (i32.const 27))
        (call $put_pixel (i32.add (local.get $sx) (i32.const 6))
          (i32.add (local.get $sy) (i32.const 7)) (i32.const 27))
      )
    )

    ;; Shadow
    (call $fill_rect (i32.add (local.get $sx) (i32.const 1))
      (i32.add (local.get $sy) (i32.const 7)) (i32.const 5) (i32.const 1) (i32.const 36))

    ;; ---- WORKER (type 0) ----
    (if (i32.eq (local.get $type) (i32.const 0))
      (then
        ;; Head
        (call $fill_rect (i32.add (local.get $sx) (i32.const 2))
          (local.get $sy) (i32.const 3) (i32.const 3) (i32.const 17)) ;; skin
        ;; Eyes
        (call $put_pixel (i32.add (local.get $sx) (i32.const 2))
          (i32.add (local.get $sy) (i32.const 1)) (i32.const 0))
        (call $put_pixel (i32.add (local.get $sx) (i32.const 4))
          (i32.add (local.get $sy) (i32.const 1)) (i32.const 0))
        ;; Body (team colored shirt)
        (call $fill_rect (i32.add (local.get $sx) (i32.const 1))
          (i32.add (local.get $sy) (i32.const 3)) (i32.const 5) (i32.const 3) (local.get $col1))
        ;; Arms with animation
        (if (i32.and (local.get $anim) (i32.const 2))
          (then
            (call $put_pixel (local.get $sx)
              (i32.add (local.get $sy) (i32.const 3)) (i32.const 17))
            (call $put_pixel (i32.add (local.get $sx) (i32.const 6))
              (i32.add (local.get $sy) (i32.const 4)) (i32.const 17))
          )
          (else
            (call $put_pixel (local.get $sx)
              (i32.add (local.get $sy) (i32.const 4)) (i32.const 17))
            (call $put_pixel (i32.add (local.get $sx) (i32.const 6))
              (i32.add (local.get $sy) (i32.const 3)) (i32.const 17))
          )
        )
        ;; Legs with walking animation
        (if (i32.and (local.get $anim) (i32.const 2))
          (then
            (call $put_pixel (i32.add (local.get $sx) (i32.const 2))
              (i32.add (local.get $sy) (i32.const 6)) (i32.const 5))
            (call $put_pixel (i32.add (local.get $sx) (i32.const 4))
              (i32.add (local.get $sy) (i32.const 7)) (i32.const 5))
          )
          (else
            (call $put_pixel (i32.add (local.get $sx) (i32.const 2))
              (i32.add (local.get $sy) (i32.const 7)) (i32.const 5))
            (call $put_pixel (i32.add (local.get $sx) (i32.const 4))
              (i32.add (local.get $sy) (i32.const 6)) (i32.const 5))
          )
        )
        ;; Carrying gold indicator
        (if (local.get $carry)
          (then
            (call $fill_rect (i32.add (local.get $sx) (i32.const 5))
              (i32.add (local.get $sy) (i32.const 1)) (i32.const 2) (i32.const 2) (i32.const 15))
          )
        )
      )
    )

    ;; ---- SOLDIER (type 1 or 3) ----
    (if (i32.or (i32.eq (local.get $type) (i32.const 1))
                (i32.eq (local.get $type) (i32.const 3)))
      (then
        ;; Helmet
        (call $fill_rect (i32.add (local.get $sx) (i32.const 1))
          (local.get $sy) (i32.const 5) (i32.const 2) (i32.const 10)) ;; gray
        ;; Face
        (call $fill_rect (i32.add (local.get $sx) (i32.const 2))
          (i32.add (local.get $sy) (i32.const 2)) (i32.const 3) (i32.const 1) (i32.const 17))
        ;; Eyes
        (call $put_pixel (i32.add (local.get $sx) (i32.const 2))
          (i32.add (local.get $sy) (i32.const 2)) (i32.const 0))
        (call $put_pixel (i32.add (local.get $sx) (i32.const 4))
          (i32.add (local.get $sy) (i32.const 2)) (i32.const 0))
        ;; Armor (team color)
        (call $fill_rect (i32.add (local.get $sx) (i32.const 1))
          (i32.add (local.get $sy) (i32.const 3)) (i32.const 5) (i32.const 3) (local.get $col1))
        ;; Belt
        (call $hline (i32.add (local.get $sx) (i32.const 1))
          (i32.add (local.get $sy) (i32.const 5)) (i32.const 5) (local.get $col2))
        ;; Sword (animated)
        (if (i32.eq (local.get $state) (i32.const 2)) ;; attacking
          (then
            ;; Sword forward
            (call $fill_rect (i32.add (local.get $sx) (i32.const 6))
              (i32.add (local.get $sy) (i32.const 1)) (i32.const 1) (i32.const 4) (i32.const 11))
            (call $put_pixel (i32.add (local.get $sx) (i32.const 6))
              (local.get $sy) (i32.const 12)) ;; sword tip
          )
          (else
            ;; Sword at side
            (call $fill_rect (i32.add (local.get $sx) (i32.const 6))
              (i32.add (local.get $sy) (i32.const 3)) (i32.const 1) (i32.const 3) (i32.const 11))
          )
        )
        ;; Shield on left
        (call $fill_rect (i32.sub (local.get $sx) (i32.const 1))
          (i32.add (local.get $sy) (i32.const 3)) (i32.const 2) (i32.const 3) (local.get $col2))
        ;; Legs
        (if (i32.and (local.get $anim) (i32.const 2))
          (then
            (call $put_pixel (i32.add (local.get $sx) (i32.const 2))
              (i32.add (local.get $sy) (i32.const 6)) (i32.const 5))
            (call $put_pixel (i32.add (local.get $sx) (i32.const 4))
              (i32.add (local.get $sy) (i32.const 7)) (i32.const 5))
          )
          (else
            (call $put_pixel (i32.add (local.get $sx) (i32.const 2))
              (i32.add (local.get $sy) (i32.const 7)) (i32.const 5))
            (call $put_pixel (i32.add (local.get $sx) (i32.const 4))
              (i32.add (local.get $sy) (i32.const 6)) (i32.const 5))
          )
        )
      )
    )

    ;; ---- ARCHER (type 2 or 4) ----
    (if (i32.or (i32.eq (local.get $type) (i32.const 2))
                (i32.eq (local.get $type) (i32.const 4)))
      (then
        ;; Hood
        (call $fill_rect (i32.add (local.get $sx) (i32.const 2))
          (local.get $sy) (i32.const 3) (i32.const 2) (i32.const 25)) ;; purple
        ;; Face
        (call $fill_rect (i32.add (local.get $sx) (i32.const 2))
          (i32.add (local.get $sy) (i32.const 2)) (i32.const 3) (i32.const 1) (i32.const 17))
        ;; Eyes
        (call $put_pixel (i32.add (local.get $sx) (i32.const 2))
          (i32.add (local.get $sy) (i32.const 2)) (i32.const 0))
        (call $put_pixel (i32.add (local.get $sx) (i32.const 4))
          (i32.add (local.get $sy) (i32.const 2)) (i32.const 0))
        ;; Cloak (team + purple)
        (call $fill_rect (i32.add (local.get $sx) (i32.const 1))
          (i32.add (local.get $sy) (i32.const 3)) (i32.const 5) (i32.const 3) (local.get $col1))
        ;; Cape flap
        (call $put_pixel (i32.add (local.get $sx) (i32.const 1))
          (i32.add (local.get $sy) (i32.const 6)) (i32.const 25))
        ;; Bow
        (if (i32.eq (local.get $state) (i32.const 2)) ;; attacking - bow drawn
          (then
            (call $put_pixel (i32.add (local.get $sx) (i32.const 6))
              (i32.add (local.get $sy) (i32.const 1)) (i32.const 5))
            (call $put_pixel (i32.add (local.get $sx) (i32.const 6))
              (i32.add (local.get $sy) (i32.const 2)) (i32.const 5))
            (call $put_pixel (i32.add (local.get $sx) (i32.const 6))
              (i32.add (local.get $sy) (i32.const 3)) (i32.const 5))
            (call $put_pixel (i32.add (local.get $sx) (i32.const 6))
              (i32.add (local.get $sy) (i32.const 4)) (i32.const 5))
            ;; Arrow
            (call $put_pixel (i32.add (local.get $sx) (i32.const 7))
              (i32.add (local.get $sy) (i32.const 2)) (i32.const 12))
          )
          (else
            ;; Bow at rest
            (call $put_pixel (i32.add (local.get $sx) (i32.const 6))
              (i32.add (local.get $sy) (i32.const 2)) (i32.const 5))
            (call $put_pixel (i32.add (local.get $sx) (i32.const 6))
              (i32.add (local.get $sy) (i32.const 3)) (i32.const 5))
            (call $put_pixel (i32.add (local.get $sx) (i32.const 6))
              (i32.add (local.get $sy) (i32.const 4)) (i32.const 5))
          )
        )
        ;; Legs
        (if (i32.and (local.get $anim) (i32.const 2))
          (then
            (call $put_pixel (i32.add (local.get $sx) (i32.const 2))
              (i32.add (local.get $sy) (i32.const 6)) (i32.const 5))
            (call $put_pixel (i32.add (local.get $sx) (i32.const 4))
              (i32.add (local.get $sy) (i32.const 7)) (i32.const 5))
          )
          (else
            (call $put_pixel (i32.add (local.get $sx) (i32.const 2))
              (i32.add (local.get $sy) (i32.const 7)) (i32.const 5))
            (call $put_pixel (i32.add (local.get $sx) (i32.const 4))
              (i32.add (local.get $sy) (i32.const 6)) (i32.const 5))
          )
        )
      )
    )

    ;; HP bar (if damaged)
    (if (i32.lt_s (local.get $hp) (local.get $maxhp))
      (then
        (local.set $hpw (i32.div_u (i32.mul (local.get $hp) (i32.const 7)) (local.get $maxhp)))
        (call $fill_rect (local.get $sx) (i32.sub (local.get $sy) (i32.const 2))
          (i32.const 7) (i32.const 1) (i32.const 14))
        (call $fill_rect (local.get $sx) (i32.sub (local.get $sy) (i32.const 2))
          (local.get $hpw) (i32.const 1) (i32.const 23))
      )
    )
  )

  ;; ============ ABS helper ============
  (func $abs (param $v i32) (result i32)
    (if (result i32) (i32.lt_s (local.get $v) (i32.const 0))
      (then (i32.sub (i32.const 0) (local.get $v)))
      (else (local.get $v))
    )
  )

  ;; Check if world position (x,y) is on a passable tile
  ;; Returns 1 if passable, 0 if blocked
  (func $is_passable (param $wx i32) (param $wy i32) (result i32)
    (local $tx i32)
    (local $ty i32)
    (local $tile i32)
    ;; Clamp to map bounds
    (if (result i32) (i32.or
          (i32.or (i32.lt_s (local.get $wx) (i32.const 0)) (i32.ge_s (local.get $wx) (i32.const 1024)))
          (i32.or (i32.lt_s (local.get $wy) (i32.const 0)) (i32.ge_s (local.get $wy) (i32.const 1024))))
      (then (i32.const 0))
      (else
        (local.set $tx (i32.shr_u (local.get $wx) (i32.const 3))) ;; /8
        (local.set $ty (i32.shr_u (local.get $wy) (i32.const 3)))
        (local.set $tile (i32.load8_u (i32.add (i32.const 0x10400)
          (i32.add (i32.mul (local.get $ty) (i32.const 128)) (local.get $tx)))))
        ;; passable: 0,1,2=grass, 3=dirt, 7=gold; blocked: 4=water, 5=tree, 6=stone
        (i32.and
          (i32.ne (local.get $tile) (i32.const 4))
          (i32.and
            (i32.ne (local.get $tile) (i32.const 5))
            (i32.ne (local.get $tile) (i32.const 6))))
      )
    )
  )

  (func $min (param $a i32) (param $b i32) (result i32)
    (if (result i32) (i32.lt_s (local.get $a) (local.get $b))
      (then (local.get $a)) (else (local.get $b)))
  )
  (func $max (param $a i32) (param $b i32) (result i32)
    (if (result i32) (i32.gt_s (local.get $a) (local.get $b))
      (then (local.get $a)) (else (local.get $b)))
  )

  ;; === FLOW FIELD BFS ===
  ;; Flow field at 0x1B000 (128x128 bytes, each = direction 0-7 or 255=unvisited)
  ;; BFS queue at 0x1F000 (16384 entries × 4 bytes = 64K, each entry = i32 tile index)
  ;; Flow field target tile stored at 0x1AFC0 (4 bytes)
  ;; Directions: 0=N, 1=NE, 2=E, 3=SE, 4=S, 5=SW, 6=W, 7=NW
  ;; Each direction points TOWARD the target (reverse of BFS expansion direction)

  ;; Build flow field from target world position (wx, wy) into slot
  (func $build_flow_field (param $wx i32) (param $wy i32) (param $slot i32)
    (local $target_tile i32)
    (local $head i32) (local $tail i32)
    (local $cur i32) (local $cx i32) (local $cy i32)
    (local $dir i32) (local $nx i32) (local $ny i32)
    (local $ni i32) (local $i i32)
    (local $grid_base i32) (local $hdr_base i32)

    ;; Compute grid and header base addresses
    (local.set $grid_base (i32.add (i32.const 0x1B000) (i32.mul (local.get $slot) (i32.const 16384))))
    (local.set $hdr_base (i32.add (i32.const 0x1AFC0) (i32.mul (local.get $slot) (i32.const 16))))

    ;; Convert world to tile
    (local.set $cx (i32.shr_u (local.get $wx) (i32.const 3)))
    (local.set $cy (i32.shr_u (local.get $wy) (i32.const 3)))
    (if (i32.or (i32.ge_u (local.get $cx) (i32.const 128)) (i32.ge_u (local.get $cy) (i32.const 128)))
      (then (return))
    )
    (local.set $target_tile (i32.add (i32.mul (local.get $cy) (i32.const 128)) (local.get $cx)))

    ;; Write slot header
    (i32.store (local.get $hdr_base) (local.get $target_tile))
    (i32.store (i32.add (local.get $hdr_base) (i32.const 4)) (i32.load (i32.const 0x00))) ;; age = frame counter
    (i32.store (i32.add (local.get $hdr_base) (i32.const 8)) (i32.const 0)) ;; user_count = 0

    ;; Clear flow field to 255
    (local.set $i (i32.const 0))
    (block $clr_brk
      (loop $clr_lp
        (br_if $clr_brk (i32.ge_s (local.get $i) (i32.const 16384)))
        (i32.store8 (i32.add (local.get $grid_base) (local.get $i)) (i32.const 255))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $clr_lp)
      )
    )

    ;; Seed BFS with target tile (direction = 8 meaning "you are here")
    (i32.store8 (i32.add (local.get $grid_base) (local.get $target_tile)) (i32.const 8))
    (i32.store (i32.const 0x2B000) (local.get $target_tile))
    (local.set $head (i32.const 0))
    (local.set $tail (i32.const 1))

    ;; BFS loop
    (block $bfs_brk
      (loop $bfs_lp
        (br_if $bfs_brk (i32.ge_s (local.get $head) (local.get $tail)))
        ;; Dequeue
        (local.set $cur (i32.load (i32.add (i32.const 0x2B000) (i32.mul (local.get $head) (i32.const 4)))))
        (local.set $head (i32.add (local.get $head) (i32.const 1)))
        (local.set $cx (i32.rem_u (local.get $cur) (i32.const 128)))
        (local.set $cy (i32.div_u (local.get $cur) (i32.const 128)))

        ;; Try all 8 neighbors
        (local.set $dir (i32.const 0))
        (block $dir_brk
          (loop $dir_lp
            (br_if $dir_brk (i32.ge_s (local.get $dir) (i32.const 8)))

            (local.set $nx (local.get $cx))
            (local.set $ny (local.get $cy))
            (if (i32.or (i32.or (i32.eq (local.get $dir) (i32.const 1))
                                (i32.eq (local.get $dir) (i32.const 2)))
                        (i32.eq (local.get $dir) (i32.const 3)))
              (then (local.set $nx (i32.add (local.get $cx) (i32.const 1))))
            )
            (if (i32.or (i32.or (i32.eq (local.get $dir) (i32.const 5))
                                (i32.eq (local.get $dir) (i32.const 6)))
                        (i32.eq (local.get $dir) (i32.const 7)))
              (then (local.set $nx (i32.sub (local.get $cx) (i32.const 1))))
            )
            (if (i32.or (i32.or (i32.eq (local.get $dir) (i32.const 0))
                                (i32.eq (local.get $dir) (i32.const 1)))
                        (i32.eq (local.get $dir) (i32.const 7)))
              (then (local.set $ny (i32.sub (local.get $cy) (i32.const 1))))
            )
            (if (i32.or (i32.or (i32.eq (local.get $dir) (i32.const 3))
                                (i32.eq (local.get $dir) (i32.const 4)))
                        (i32.eq (local.get $dir) (i32.const 5)))
              (then (local.set $ny (i32.add (local.get $cy) (i32.const 1))))
            )

            ;; Bounds check
            (if (i32.and
                  (i32.and (i32.ge_s (local.get $nx) (i32.const 0)) (i32.lt_s (local.get $nx) (i32.const 128)))
                  (i32.and (i32.ge_s (local.get $ny) (i32.const 0)) (i32.lt_s (local.get $ny) (i32.const 128))))
              (then
                (local.set $ni (i32.add (i32.mul (local.get $ny) (i32.const 128)) (local.get $nx)))
                (if (i32.and
                      (i32.eq (i32.load8_u (i32.add (local.get $grid_base) (local.get $ni))) (i32.const 255))
                      (call $is_passable (i32.mul (local.get $nx) (i32.const 8)) (i32.mul (local.get $ny) (i32.const 8))))
                  (then
                    (i32.store8 (i32.add (local.get $grid_base) (local.get $ni))
                      (i32.and (i32.add (local.get $dir) (i32.const 4)) (i32.const 7)))
                    (if (i32.lt_s (local.get $tail) (i32.const 16384))
                      (then
                        (i32.store (i32.add (i32.const 0x2B000) (i32.mul (local.get $tail) (i32.const 4))) (local.get $ni))
                        (local.set $tail (i32.add (local.get $tail) (i32.const 1)))
                      )
                    )
                  )
                )
              )
            )

            (local.set $dir (i32.add (local.get $dir) (i32.const 1)))
            (br $dir_lp)
          )
        )
        (br $bfs_lp)
      )
    )
  )

  ;; Find flow field slot matching target_tile, or allocate one (evict least used)
  ;; Returns slot index 0-3
  (func $find_or_alloc_flow_slot (param $target_tile i32) (result i32)
    (local $s i32) (local $hdr i32)
    (local $slot_target i32) (local $stx i32) (local $sty i32)
    (local $ttx i32) (local $tty i32) (local $dist i32)
    (local $best_slot i32) (local $best_score i32) (local $score i32)

    (local.set $ttx (i32.rem_u (local.get $target_tile) (i32.const 128)))
    (local.set $tty (i32.div_u (local.get $target_tile) (i32.const 128)))

    ;; Pass 1: find exact or nearby match
    (local.set $s (i32.const 0))
    (block $found
      (loop $scan
        (br_if $found (i32.ge_s (local.get $s) (i32.const 4)))
        (local.set $hdr (i32.add (i32.const 0x1AFC0) (i32.mul (local.get $s) (i32.const 16))))
        (local.set $slot_target (i32.load (local.get $hdr)))
        ;; Exact match
        (if (i32.eq (local.get $slot_target) (local.get $target_tile))
          (then (return (local.get $s)))
        )
        ;; Nearby match: manhattan dist <= 3 tiles
        (if (local.get $slot_target)
          (then
            (local.set $stx (i32.rem_u (local.get $slot_target) (i32.const 128)))
            (local.set $sty (i32.div_u (local.get $slot_target) (i32.const 128)))
            (local.set $dist (i32.add
              (call $abs (i32.sub (local.get $stx) (local.get $ttx)))
              (call $abs (i32.sub (local.get $sty) (local.get $tty)))))
            (if (i32.le_u (local.get $dist) (i32.const 3))
              (then (return (local.get $s)))
            )
          )
        )
        (local.set $s (i32.add (local.get $s) (i32.const 1)))
        (br $scan)
      )
    )

    ;; Pass 2: find empty slot (target_tile == 0)
    (local.set $s (i32.const 0))
    (block $found2
      (loop $scan2
        (br_if $found2 (i32.ge_s (local.get $s) (i32.const 4)))
        (local.set $hdr (i32.add (i32.const 0x1AFC0) (i32.mul (local.get $s) (i32.const 16))))
        (if (i32.eqz (i32.load (local.get $hdr)))
          (then (return (local.get $s)))
        )
        (local.set $s (i32.add (local.get $s) (i32.const 1)))
        (br $scan2)
      )
    )

    ;; Pass 3: evict slot with lowest user_count (tie-break: oldest age)
    (local.set $best_slot (i32.const 0))
    (local.set $best_score (i32.const 0x7FFFFFFF))
    (local.set $s (i32.const 0))
    (block $evict
      (loop $ev_lp
        (br_if $evict (i32.ge_s (local.get $s) (i32.const 4)))
        (local.set $hdr (i32.add (i32.const 0x1AFC0) (i32.mul (local.get $s) (i32.const 16))))
        ;; score = user_count * 65536 + age (lower = more evictable)
        (local.set $score (i32.add
          (i32.mul (i32.load (i32.add (local.get $hdr) (i32.const 8))) (i32.const 65536))
          (i32.and (i32.load (i32.add (local.get $hdr) (i32.const 4))) (i32.const 0xFFFF))))
        (if (i32.lt_u (local.get $score) (local.get $best_score))
          (then
            (local.set $best_score (local.get $score))
            (local.set $best_slot (local.get $s))
          )
        )
        (local.set $s (i32.add (local.get $s) (i32.const 1)))
        (br $ev_lp)
      )
    )
    (local.get $best_slot)
  )

  ;; Move unit using multi-slot flow fields, else greedy + stuck jitter
  (func $move_toward (param $addr i32) (param $tx i32) (param $ty i32) (param $spd i32)
    (local $ux i32) (local $uy i32)
    (local $tile_x i32) (local $tile_y i32)
    (local $flow_dir i32)
    (local $nx i32) (local $ny i32)
    (local $target_tile i32)
    (local $dir i32) (local $best_dist i32) (local $dist i32)
    (local $best_x i32) (local $best_y i32)
    (local $slot i32) (local $grid_base i32) (local $hdr i32)
    (local $prev_x i32) (local $stuck i32)

    (local.set $ux (i32.load16_s (i32.add (local.get $addr) (i32.const 4))))
    (local.set $uy (i32.load16_s (i32.add (local.get $addr) (i32.const 6))))
    (local.set $tile_x (i32.shr_u (local.get $ux) (i32.const 3)))
    (local.set $tile_y (i32.shr_u (local.get $uy) (i32.const 3)))

    (local.set $target_tile (i32.add
      (i32.mul (i32.shr_u (local.get $ty) (i32.const 3)) (i32.const 128))
      (i32.shr_u (local.get $tx) (i32.const 3))))
    (local.set $flow_dir (i32.const 255))

    ;; Find or allocate flow field slot
    (local.set $slot (call $find_or_alloc_flow_slot (local.get $target_tile)))
    (local.set $hdr (i32.add (i32.const 0x1AFC0) (i32.mul (local.get $slot) (i32.const 16))))
    (local.set $grid_base (i32.add (i32.const 0x1B000) (i32.mul (local.get $slot) (i32.const 16384))))

    ;; If slot target doesn't match (new allocation), build BFS now
    (if (i32.ne (i32.load (local.get $hdr)) (local.get $target_tile))
      (then
        ;; Check nearby match: if within 3 tiles, reuse without rebuild
        (if (i32.gt_u
              (i32.add
                (call $abs (i32.sub
                  (i32.rem_u (i32.load (local.get $hdr)) (i32.const 128))
                  (i32.rem_u (local.get $target_tile) (i32.const 128))))
                (call $abs (i32.sub
                  (i32.div_u (i32.load (local.get $hdr)) (i32.const 128))
                  (i32.div_u (local.get $target_tile) (i32.const 128)))))
              (i32.const 3))
          (then
            ;; Not nearby — need full rebuild
            (call $build_flow_field (local.get $tx) (local.get $ty) (local.get $slot))
          )
        )
      )
    )

    ;; Increment user count
    (i32.store (i32.add (local.get $hdr) (i32.const 8))
      (i32.add (i32.load (i32.add (local.get $hdr) (i32.const 8))) (i32.const 1)))

    ;; Look up flow direction
    (if (i32.and (i32.lt_u (local.get $tile_x) (i32.const 128))
                 (i32.lt_u (local.get $tile_y) (i32.const 128)))
      (then
        (local.set $flow_dir (i32.load8_u (i32.add (local.get $grid_base)
          (i32.add (i32.mul (local.get $tile_y) (i32.const 128)) (local.get $tile_x)))))
      )
    )

    ;; Use flow field if valid direction (0-7)
    (if (i32.lt_u (local.get $flow_dir) (i32.const 8))
      (then
        (local.set $nx (local.get $ux))
        (local.set $ny (local.get $uy))
        (if (i32.or (i32.or (i32.eq (local.get $flow_dir) (i32.const 1))
                            (i32.eq (local.get $flow_dir) (i32.const 2)))
                    (i32.eq (local.get $flow_dir) (i32.const 3)))
          (then (local.set $nx (i32.add (local.get $ux) (local.get $spd))))
        )
        (if (i32.or (i32.or (i32.eq (local.get $flow_dir) (i32.const 5))
                            (i32.eq (local.get $flow_dir) (i32.const 6)))
                    (i32.eq (local.get $flow_dir) (i32.const 7)))
          (then (local.set $nx (i32.sub (local.get $ux) (local.get $spd))))
        )
        (if (i32.or (i32.or (i32.eq (local.get $flow_dir) (i32.const 0))
                            (i32.eq (local.get $flow_dir) (i32.const 1)))
                    (i32.eq (local.get $flow_dir) (i32.const 7)))
          (then (local.set $ny (i32.sub (local.get $uy) (local.get $spd))))
        )
        (if (i32.or (i32.or (i32.eq (local.get $flow_dir) (i32.const 3))
                            (i32.eq (local.get $flow_dir) (i32.const 4)))
                    (i32.eq (local.get $flow_dir) (i32.const 5)))
          (then (local.set $ny (i32.add (local.get $uy) (local.get $spd))))
        )
        (i32.store16 (i32.add (local.get $addr) (i32.const 4)) (local.get $nx))
        (i32.store16 (i32.add (local.get $addr) (i32.const 6)) (local.get $ny))
        ;; Update stuck detection
        (i32.store16 (i32.add (local.get $addr) (i32.const 28)) (local.get $ux))
        (i32.store8 (i32.add (local.get $addr) (i32.const 30)) (i32.const 0))
        (return)
      )
    )

    ;; Fallback: greedy best-neighbor (try all 8 directions)
    (local.set $best_dist (i32.const 0x7FFFFFFF))
    (local.set $best_x (local.get $ux))
    (local.set $best_y (local.get $uy))

    ;; Stuck detection: if same position as prev frame, increment counter
    (local.set $prev_x (i32.load16_s (i32.add (local.get $addr) (i32.const 28))))
    (local.set $stuck (i32.load8_u (i32.add (local.get $addr) (i32.const 30))))
    (if (i32.eq (local.get $prev_x) (local.get $ux))
      (then
        (local.set $stuck (i32.add (local.get $stuck) (i32.const 1)))
      )
      (else
        (local.set $stuck (i32.const 0))
      )
    )
    (i32.store16 (i32.add (local.get $addr) (i32.const 28)) (local.get $ux))

    ;; If stuck >= 8 frames, try random perpendicular jitter
    (if (i32.ge_u (local.get $stuck) (i32.const 8))
      (then
        (local.set $stuck (i32.const 0))
        (local.set $dir (i32.and (call $rng) (i32.const 3)))
        (local.set $nx (local.get $ux))
        (local.set $ny (local.get $uy))
        (if (i32.eq (local.get $dir) (i32.const 0))
          (then (local.set $nx (i32.add (local.get $ux) (local.get $spd)))))
        (if (i32.eq (local.get $dir) (i32.const 1))
          (then (local.set $nx (i32.sub (local.get $ux) (local.get $spd)))))
        (if (i32.eq (local.get $dir) (i32.const 2))
          (then (local.set $ny (i32.add (local.get $uy) (local.get $spd)))))
        (if (i32.eq (local.get $dir) (i32.const 3))
          (then (local.set $ny (i32.sub (local.get $uy) (local.get $spd)))))
        (if (call $is_passable (local.get $nx) (local.get $ny))
          (then
            (i32.store16 (i32.add (local.get $addr) (i32.const 4)) (local.get $nx))
            (i32.store16 (i32.add (local.get $addr) (i32.const 6)) (local.get $ny))
            (i32.store8 (i32.add (local.get $addr) (i32.const 30)) (i32.const 0))
            (return)
          )
        )
      )
    )
    (i32.store8 (i32.add (local.get $addr) (i32.const 30)) (local.get $stuck))

    ;; Normal greedy
    (local.set $dir (i32.const 0))
    (block $brk
      (loop $lp
        (br_if $brk (i32.ge_s (local.get $dir) (i32.const 8)))
        (local.set $nx (local.get $ux))
        (local.set $ny (local.get $uy))
        (if (i32.or (i32.or (i32.eq (local.get $dir) (i32.const 1))
                            (i32.eq (local.get $dir) (i32.const 2)))
                    (i32.eq (local.get $dir) (i32.const 3)))
          (then (local.set $nx (i32.add (local.get $ux) (local.get $spd))))
        )
        (if (i32.or (i32.or (i32.eq (local.get $dir) (i32.const 5))
                            (i32.eq (local.get $dir) (i32.const 6)))
                    (i32.eq (local.get $dir) (i32.const 7)))
          (then (local.set $nx (i32.sub (local.get $ux) (local.get $spd))))
        )
        (if (i32.or (i32.or (i32.eq (local.get $dir) (i32.const 0))
                            (i32.eq (local.get $dir) (i32.const 1)))
                    (i32.eq (local.get $dir) (i32.const 7)))
          (then (local.set $ny (i32.sub (local.get $uy) (local.get $spd))))
        )
        (if (i32.or (i32.or (i32.eq (local.get $dir) (i32.const 3))
                            (i32.eq (local.get $dir) (i32.const 4)))
                    (i32.eq (local.get $dir) (i32.const 5)))
          (then (local.set $ny (i32.add (local.get $uy) (local.get $spd))))
        )
        (if (call $is_passable (local.get $nx) (local.get $ny))
          (then
            (local.set $dist (i32.add
              (call $abs (i32.sub (local.get $tx) (local.get $nx)))
              (call $abs (i32.sub (local.get $ty) (local.get $ny)))))
            (if (i32.lt_s (local.get $dist) (local.get $best_dist))
              (then
                (local.set $best_dist (local.get $dist))
                (local.set $best_x (local.get $nx))
                (local.set $best_y (local.get $ny))
              )
            )
          )
        )
        (local.set $dir (i32.add (local.get $dir) (i32.const 1)))
        (br $lp)
      )
    )
    (i32.store16 (i32.add (local.get $addr) (i32.const 4)) (local.get $best_x))
    (i32.store16 (i32.add (local.get $addr) (i32.const 6)) (local.get $best_y))
  )

  ;; ============ UPDATE UNITS ============
  (func $update_units
    (local $i i32)
    (local $addr i32)
    (local $state i32)
    (local $ux i32)
    (local $uy i32)
    (local $tx i32)
    (local $ty i32)
    (local $dx i32)
    (local $dy i32)
    (local $spd i32)
    (local $target_unit i32)
    (local $taddr i32)
    (local $dist i32)
    (local $rng_val i32)
    (local $atk_timer i32)
    (local $atk i32)
    (local $thp i32)
    (local $team i32)
    (local $type i32)
    (local $carry i32)
    (local $anim_timer i32)

    (local.set $i (i32.const 0))
    (block $brk
      (loop $lp
        (br_if $brk (i32.ge_s (local.get $i) (i32.const 64)))
        (local.set $addr (i32.add (i32.const 0x14400) (i32.mul (local.get $i) (i32.const 32))))

        (if (i32.load8_u (local.get $addr)) ;; active
          (then
            (local.set $state (i32.load8_u (i32.add (local.get $addr) (i32.const 3))))
            (local.set $type (i32.load8_u (i32.add (local.get $addr) (i32.const 1))))
            (local.set $team (i32.load8_u (i32.add (local.get $addr) (i32.const 2))))

            ;; Animation timer
            (local.set $anim_timer (i32.load8_u (i32.add (local.get $addr) (i32.const 21))))
            (local.set $anim_timer (i32.add (local.get $anim_timer) (i32.const 1)))
            (if (i32.gt_u (local.get $anim_timer) (i32.const 6))
              (then
                (local.set $anim_timer (i32.const 0))
                (i32.store8 (i32.add (local.get $addr) (i32.const 20))
                  (i32.add (i32.load8_u (i32.add (local.get $addr) (i32.const 20))) (i32.const 1)))
              )
            )
            (i32.store8 (i32.add (local.get $addr) (i32.const 21)) (local.get $anim_timer))

            ;; Skip dead units
            (if (i32.ne (local.get $state) (i32.const 4))
              (then
                (local.set $ux (i32.load16_s (i32.add (local.get $addr) (i32.const 4))))
                (local.set $uy (i32.load16_s (i32.add (local.get $addr) (i32.const 6))))
                (local.set $tx (i32.load16_s (i32.add (local.get $addr) (i32.const 8))))
                (local.set $ty (i32.load16_s (i32.add (local.get $addr) (i32.const 10))))
                (local.set $spd (i32.load8_u (i32.add (local.get $addr) (i32.const 18))))
                (local.set $target_unit (i32.load8_s (i32.add (local.get $addr) (i32.const 24))))

                ;; MOVING state
                (if (i32.or (i32.eq (local.get $state) (i32.const 1))
                            (i32.eq (local.get $state) (i32.const 5))) ;; moving or returning
                  (then
                    (local.set $dx (i32.sub (local.get $tx) (local.get $ux)))
                    (local.set $dy (i32.sub (local.get $ty) (local.get $uy)))
                    (local.set $dist (i32.add (call $abs (local.get $dx)) (call $abs (local.get $dy))))

                    (if (i32.lt_s (local.get $dist) (i32.const 4))
                      (then
                        ;; Arrived
                        (if (i32.eq (local.get $state) (i32.const 5)) ;; returning with gold
                          (then
                            ;; Deposit gold
                            (local.set $carry (i32.load8_u (i32.add (local.get $addr) (i32.const 25))))
                            (if (i32.and (local.get $carry) (i32.eqz (local.get $team)))
                              (then
                                (i32.store (i32.const 0x15690)
                                  (i32.add (i32.load (i32.const 0x15690)) (i32.load8_u (i32.add (local.get $addr) (i32.const 25)))))
                                (i32.store8 (i32.add (local.get $addr) (i32.const 25)) (i32.const 0))
                                ;; Go back to gold mine
                                (i32.store8 (i32.add (local.get $addr) (i32.const 3)) (i32.const 3)) ;; gathering
                                (i32.store16 (i32.add (local.get $addr) (i32.const 8)) (i32.const 208)) ;; gold mine x
                                (i32.store16 (i32.add (local.get $addr) (i32.const 10)) (i32.const 840)) ;; gold mine y
                              )
                            )
                          )
                          (else
                            (i32.store8 (i32.add (local.get $addr) (i32.const 3)) (i32.const 0)) ;; idle
                          )
                        )
                      )
                      (else
                        (call $move_toward (local.get $addr) (local.get $tx) (local.get $ty) (local.get $spd))
                      )
                    )
                  )
                )

                ;; GATHERING state (workers)
                (if (i32.eq (local.get $state) (i32.const 3))
                  (then
                    (local.set $dx (i32.sub (local.get $tx) (local.get $ux)))
                    (local.set $dy (i32.sub (local.get $ty) (local.get $uy)))
                    (local.set $dist (i32.add (call $abs (local.get $dx)) (call $abs (local.get $dy))))
                    (if (i32.lt_s (local.get $dist) (i32.const 12))
                      (then
                        ;; At gold mine - gather
                        (local.set $carry (i32.load8_u (i32.add (local.get $addr) (i32.const 25))))
                        (local.set $atk_timer (i32.load8_u (i32.add (local.get $addr) (i32.const 22))))
                        (local.set $atk_timer (i32.add (local.get $atk_timer) (i32.const 1)))
                        (if (i32.gt_u (local.get $atk_timer) (i32.const 30))
                          (then
                            (local.set $atk_timer (i32.const 0))
                            (local.set $carry (i32.add (local.get $carry) (i32.const 5)))
                            (if (i32.ge_u (local.get $carry) (i32.const 10))
                              (then
                                ;; Full, return to base
                                (i32.store8 (i32.add (local.get $addr) (i32.const 25)) (local.get $carry))
                                (i32.store8 (i32.add (local.get $addr) (i32.const 3)) (i32.const 5)) ;; returning
                                ;; Target = town hall position
                                (if (i32.eqz (local.get $team))
                                  (then
                                    (i32.store16 (i32.add (local.get $addr) (i32.const 8)) (i32.const 96))
                                    (i32.store16 (i32.add (local.get $addr) (i32.const 10)) (i32.const 816))
                                  )
                                )
                              )
                              (else
                                (i32.store8 (i32.add (local.get $addr) (i32.const 25)) (local.get $carry))
                              )
                            )
                          )
                        )
                        (i32.store8 (i32.add (local.get $addr) (i32.const 22)) (local.get $atk_timer))
                      )
                      (else
                        (call $move_toward (local.get $addr) (local.get $tx) (local.get $ty) (local.get $spd))
                      )
                    )
                  )
                )

                ;; ATTACKING state
                (if (i32.eq (local.get $state) (i32.const 2))
                  (then
                    (if (i32.ge_s (local.get $target_unit) (i32.const 0))
                      (then
                        (local.set $taddr (i32.add (i32.const 0x14400)
                          (i32.mul (local.get $target_unit) (i32.const 32))))
                        ;; Check if target still alive
                        (if (i32.and
                              (i32.load8_u (local.get $taddr))
                              (i32.ne (i32.load8_u (i32.add (local.get $taddr) (i32.const 3))) (i32.const 4))
                            )
                          (then
                            ;; Get distance to target
                            (local.set $dx (i32.sub
                              (i32.load16_s (i32.add (local.get $taddr) (i32.const 4))) (local.get $ux)))
                            (local.set $dy (i32.sub
                              (i32.load16_s (i32.add (local.get $taddr) (i32.const 6))) (local.get $uy)))
                            (local.set $dist (i32.add (call $abs (local.get $dx)) (call $abs (local.get $dy))))
                            (local.set $rng_val (i32.load8_u (i32.add (local.get $addr) (i32.const 17))))

                            (if (i32.le_s (local.get $dist) (local.get $rng_val))
                              (then
                                ;; In range - attack
                                (local.set $atk_timer (i32.load8_u (i32.add (local.get $addr) (i32.const 22))))
                                (local.set $atk_timer (i32.add (local.get $atk_timer) (i32.const 1)))
                                (if (i32.ge_u (local.get $atk_timer) (i32.load8_u (i32.add (local.get $addr) (i32.const 26))))
                                  (then
                                    (local.set $atk_timer (i32.const 0))
                                    ;; Deal damage
                                    (local.set $atk (i32.load8_u (i32.add (local.get $addr) (i32.const 16))))
                                    (local.set $thp (i32.load16_s (i32.add (local.get $taddr) (i32.const 12))))
                                    (local.set $thp (i32.sub (local.get $thp) (local.get $atk)))
                                    (i32.store16 (i32.add (local.get $taddr) (i32.const 12)) (local.get $thp))
                                    ;; Play attack sound
                                    (call $note (i32.const 1) (i32.const 200) (i32.const 30) (i32.const 60))
                                    ;; Kill check
                                    (if (i32.le_s (local.get $thp) (i32.const 0))
                                      (then
                                        (i32.store8 (i32.add (local.get $taddr) (i32.const 3)) (i32.const 4)) ;; dead
                                        (i32.store8 (i32.add (local.get $addr) (i32.const 3)) (i32.const 0)) ;; idle
                                        (i32.store8 (i32.add (local.get $addr) (i32.const 24)) (i32.const 255)) ;; no target
                                        (call $note (i32.const 0) (i32.const 100) (i32.const 100) (i32.const 80))
                                      )
                                    )
                                  )
                                )
                                (i32.store8 (i32.add (local.get $addr) (i32.const 22)) (local.get $atk_timer))
                              )
                              (else
                                ;; Move toward attack target
                                (call $move_toward (local.get $addr)
                                  (i32.load16_s (i32.add (local.get $taddr) (i32.const 4)))
                                  (i32.load16_s (i32.add (local.get $taddr) (i32.const 6)))
                                  (local.get $spd))
                              )
                            )
                          )
                          (else
                            ;; Target dead - go idle
                            (i32.store8 (i32.add (local.get $addr) (i32.const 3)) (i32.const 0))
                            (i32.store8 (i32.add (local.get $addr) (i32.const 24)) (i32.const 255))
                          )
                        )
                      )
                    )
                  )
                )

                ;; IDLE - auto-attack nearby enemies
                (if (i32.eq (local.get $state) (i32.const 0))
                  (then
                    (call $find_nearby_enemy (local.get $i))
                  )
                )
              )
            )
          )
        )

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)
      )
    )
  )

  ;; ============ FIND NEARBY ENEMY ============
  (func $find_nearby_enemy (param $unit_idx i32)
    (local $addr i32)
    (local $team i32)
    (local $ux i32)
    (local $uy i32)
    (local $j i32)
    (local $jaddr i32)
    (local $jteam i32)
    (local $dx i32)
    (local $dy i32)
    (local $dist i32)
    (local $best_dist i32)
    (local $best_j i32)

    (local.set $addr (i32.add (i32.const 0x14400) (i32.mul (local.get $unit_idx) (i32.const 32))))
    (local.set $team (i32.load8_u (i32.add (local.get $addr) (i32.const 2))))
    (local.set $ux (i32.load16_s (i32.add (local.get $addr) (i32.const 4))))
    (local.set $uy (i32.load16_s (i32.add (local.get $addr) (i32.const 6))))
    (local.set $best_dist (i32.const 50)) ;; auto-aggro range
    (local.set $best_j (i32.const -1))

    (local.set $j (i32.const 0))
    (block $brk
      (loop $lp
        (br_if $brk (i32.ge_s (local.get $j) (i32.const 64)))
        (if (i32.ne (local.get $j) (local.get $unit_idx))
          (then
            (local.set $jaddr (i32.add (i32.const 0x14400) (i32.mul (local.get $j) (i32.const 32))))
            (if (i32.and
                  (i32.load8_u (local.get $jaddr))
                  (i32.ne (i32.load8_u (i32.add (local.get $jaddr) (i32.const 3))) (i32.const 4))
                )
              (then
                (local.set $jteam (i32.load8_u (i32.add (local.get $jaddr) (i32.const 2))))
                (if (i32.ne (local.get $jteam) (local.get $team))
                  (then
                    (local.set $dx (call $abs (i32.sub
                      (i32.load16_s (i32.add (local.get $jaddr) (i32.const 4))) (local.get $ux))))
                    (local.set $dy (call $abs (i32.sub
                      (i32.load16_s (i32.add (local.get $jaddr) (i32.const 6))) (local.get $uy))))
                    (local.set $dist (i32.add (local.get $dx) (local.get $dy)))
                    (if (i32.lt_s (local.get $dist) (local.get $best_dist))
                      (then
                        (local.set $best_dist (local.get $dist))
                        (local.set $best_j (local.get $j))
                      )
                    )
                  )
                )
              )
            )
          )
        )
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $lp)
      )
    )

    ;; If found an enemy, attack it
    (if (i32.ge_s (local.get $best_j) (i32.const 0))
      (then
        (i32.store8 (i32.add (local.get $addr) (i32.const 3)) (i32.const 2)) ;; attacking
        (i32.store8 (i32.add (local.get $addr) (i32.const 24)) (local.get $best_j))
      )
    )
  )

  ;; ============ ENEMY AI ============
  (func $update_ai
    (local $timer i32)
    (local $gold i32)
    (local $r i32)
    (local $x i32)
    (local $y i32)
    (local $uid i32)
    (local $num_enemy i32)
    (local $i i32)
    (local $addr i32)

    ;; Count enemy units
    (local.set $num_enemy (i32.const 0))
    (local.set $i (i32.const 0))
    (block $cnt_brk
      (loop $cnt_lp
        (br_if $cnt_brk (i32.ge_s (local.get $i) (i32.const 64)))
        (local.set $addr (i32.add (i32.const 0x14400) (i32.mul (local.get $i) (i32.const 32))))
        (if (i32.and
              (i32.load8_u (local.get $addr))
              (i32.and
                (i32.eq (i32.load8_u (i32.add (local.get $addr) (i32.const 2))) (i32.const 1))
                (i32.ne (i32.load8_u (i32.add (local.get $addr) (i32.const 3))) (i32.const 4))
              )
            )
          (then
            (local.set $num_enemy (i32.add (local.get $num_enemy) (i32.const 1)))
          )
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $cnt_lp)
      )
    )

    ;; Spawn timer
    (local.set $timer (i32.load (i32.const 0x1A970)))
    (local.set $timer (i32.add (local.get $timer) (i32.const 1)))

    ;; Spawn rate depends on game progress
    (if (i32.and
          (i32.gt_s (local.get $timer) (i32.const 180)) ;; every ~3 seconds
          (i32.lt_s (local.get $num_enemy) (i32.const 15)) ;; cap at 15 enemy units
        )
      (then
        (local.set $timer (i32.const 0))
        (local.set $r (i32.and (call $rng) (i32.const 3)))

        ;; Spawn position near enemy base
        (local.set $x (i32.add (i32.const 880)
          (i32.sub (i32.rem_u (call $rng) (i32.const 30)) (i32.const 15))))
        (local.set $y (i32.add (i32.const 120)
          (i32.sub (i32.rem_u (call $rng) (i32.const 30)) (i32.const 15))))

        (if (i32.lt_u (local.get $r) (i32.const 2))
          (then
            ;; Spawn enemy soldier
            (local.set $uid (call $create_unit (i32.const 3) (i32.const 1) (local.get $x) (local.get $y)))
          )
          (else
            ;; Spawn enemy archer
            (local.set $uid (call $create_unit (i32.const 4) (i32.const 1) (local.get $x) (local.get $y)))
          )
        )

        ;; Pre-warm flow field toward player base for enemy pathfinding
        (call $build_flow_field (i32.const 96) (i32.const 816)
          (call $find_or_alloc_flow_slot
            (i32.add (i32.mul (i32.shr_u (i32.const 816) (i32.const 3)) (i32.const 128))
                     (i32.shr_u (i32.const 96) (i32.const 3)))))

        ;; Send to attack player town hall (exact position for flow field match)
        (if (i32.ge_s (local.get $uid) (i32.const 0))
          (then
            (local.set $addr (i32.add (i32.const 0x14400) (i32.mul (local.get $uid) (i32.const 32))))
            (i32.store8 (i32.add (local.get $addr) (i32.const 3)) (i32.const 1)) ;; moving
            (i32.store16 (i32.add (local.get $addr) (i32.const 8)) (i32.const 96))
            (i32.store16 (i32.add (local.get $addr) (i32.const 10)) (i32.const 816))
          )
        )
      )
    )

    (i32.store (i32.const 0x1A970) (local.get $timer))
  )

  ;; ============ HANDLE INPUT ============
  (func $handle_input
    (local $mx i32)
    (local $my i32)
    (local $mbtn i32)
    (local $keys i32)
    (local $last_btn i32)
    (local $cam_x i32)
    (local $cam_y i32)
    (local $world_x i32)
    (local $world_y i32)
    (local $i i32)
    (local $addr i32)
    (local $ux i32)
    (local $uy i32)
    (local $dx i32)
    (local $dy i32)
    (local $dist i32)
    (local $best_i i32)
    (local $best_dist i32)
    (local $gold i32)
    (local $nsel i32)
    (local $team i32)
    (local $clicked_enemy i32)
    (local $uid i32)

    ;; Read mouse
    (local.set $mx (i32.or
      (i32.load8_u (i32.const 4))
      (i32.shl (i32.load8_u (i32.const 5)) (i32.const 8))))
    (local.set $my (i32.or
      (i32.load8_u (i32.const 6))
      (i32.shl (i32.load8_u (i32.const 7)) (i32.const 8))))
    (local.set $mbtn (i32.load8_u (i32.const 8)))
    (local.set $last_btn (i32.load8_u (i32.const 0x1A940)))
    (local.set $keys (i32.load8_u (i32.const 16)))

    ;; Camera
    (local.set $cam_x (i32.load16_s (i32.const 0x1A820)))
    (local.set $cam_y (i32.load16_s (i32.const 0x1A822)))

    ;; Scroll with keys
    (if (i32.and (local.get $keys) (i32.const 1)) ;; up
      (then (local.set $cam_y (i32.sub (local.get $cam_y) (i32.const 3))))
    )
    (if (i32.and (local.get $keys) (i32.const 2)) ;; down
      (then (local.set $cam_y (i32.add (local.get $cam_y) (i32.const 3))))
    )
    (if (i32.and (local.get $keys) (i32.const 4)) ;; left
      (then (local.set $cam_x (i32.sub (local.get $cam_x) (i32.const 3))))
    )
    (if (i32.and (local.get $keys) (i32.const 8)) ;; right
      (then (local.set $cam_x (i32.add (local.get $cam_x) (i32.const 3))))
    )

    ;; Edge scroll with mouse
    (if (i32.lt_s (local.get $mx) (i32.const 4))
      (then (local.set $cam_x (i32.sub (local.get $cam_x) (i32.const 2))))
    )
    (if (i32.gt_s (local.get $mx) (i32.const 316))
      (then (local.set $cam_x (i32.add (local.get $cam_x) (i32.const 2))))
    )
    (if (i32.lt_s (local.get $my) (i32.const 4))
      (then (local.set $cam_y (i32.sub (local.get $cam_y) (i32.const 2))))
    )
    (if (i32.gt_s (local.get $my) (i32.const 180))
      (then (local.set $cam_y (i32.add (local.get $cam_y) (i32.const 2))))
    )

    ;; Clamp camera
    (if (i32.lt_s (local.get $cam_x) (i32.const 0))
      (then (local.set $cam_x (i32.const 0)))
    )
    (if (i32.gt_s (local.get $cam_x) (i32.const 704)) ;; 1024-320
      (then (local.set $cam_x (i32.const 704)))
    )
    (if (i32.lt_s (local.get $cam_y) (i32.const 0))
      (then (local.set $cam_y (i32.const 0)))
    )
    (if (i32.gt_s (local.get $cam_y) (i32.const 824)) ;; 1024-200
      (then (local.set $cam_y (i32.const 824)))
    )

    (i32.store16 (i32.const 0x1A820) (local.get $cam_x))
    (i32.store16 (i32.const 0x1A822) (local.get $cam_y))

    ;; World coordinates of mouse
    (local.set $world_x (i32.add (local.get $mx) (local.get $cam_x)))
    (local.set $world_y (i32.add (local.get $my) (local.get $cam_y)))

    ;; LEFT CLICK DOWN - Start drag (skip if clicking bottom bar)
    (if (i32.and
          (i32.and
            (i32.and (local.get $mbtn) (i32.const 1))
            (i32.eqz (i32.and (local.get $last_btn) (i32.const 1))))
          (i32.lt_u (local.get $my) (i32.const 184)))
      (then
        ;; Store drag start in world coords
        (i32.store16 (i32.const 0x1A950) (local.get $world_x))
        (i32.store16 (i32.const 0x1A952) (local.get $world_y))
        (i32.store8 (i32.const 0x1A958) (i32.const 1)) ;; dragging = true
      )
    )

    ;; LEFT CLICK UP - Finish selection (skip if clicking bottom bar)
    (if (i32.and
          (i32.and
            (i32.eqz (i32.and (local.get $mbtn) (i32.const 1)))
            (i32.and (local.get $last_btn) (i32.const 1)))
          (i32.lt_u (local.get $my) (i32.const 184)))
      (then
        ;; Clear selection
        (local.set $i (i32.const 0))
        (block $cl_brk
          (loop $cl_lp
            (br_if $cl_brk (i32.ge_s (local.get $i) (i32.const 64)))
            (local.set $addr (i32.add (i32.const 0x14400) (i32.mul (local.get $i) (i32.const 32))))
            (i32.store8 (i32.add (local.get $addr) (i32.const 19)) (i32.const 0))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $cl_lp)
          )
        )
        (i32.store (i32.const 0x1A930) (i32.const 0)) ;; clear num selected

        ;; Check drag distance to decide box vs single select
        ;; drag_dx = abs(world_x - drag_start_x), drag_dy = abs(world_y - drag_start_y)
        (local.set $dx (call $abs (i32.sub (local.get $world_x) (i32.load16_s (i32.const 0x1A950)))))
        (local.set $dy (call $abs (i32.sub (local.get $world_y) (i32.load16_s (i32.const 0x1A952)))))

        (if (i32.gt_s (i32.add (local.get $dx) (local.get $dy)) (i32.const 10))
          (then
            ;; BOX SELECT - select all player units inside rectangle
            ;; Compute min/max of drag start and current world pos
            ;; Reuse $ux/$uy/$dx/$dy as min_x/min_y/max_x/max_y
            (local.set $ux (call $min (local.get $world_x) (i32.load16_s (i32.const 0x1A950))))
            (local.set $uy (call $min (local.get $world_y) (i32.load16_s (i32.const 0x1A952))))
            (local.set $dx (call $max (local.get $world_x) (i32.load16_s (i32.const 0x1A950))))
            (local.set $dy (call $max (local.get $world_y) (i32.load16_s (i32.const 0x1A952))))

            (local.set $nsel (i32.const 0))
            (local.set $i (i32.const 0))
            (block $bs_brk
              (loop $bs_lp
                (br_if $bs_brk (i32.ge_s (local.get $i) (i32.const 64)))
                (local.set $addr (i32.add (i32.const 0x14400) (i32.mul (local.get $i) (i32.const 32))))
                (if (i32.and
                      (i32.load8_u (local.get $addr))
                      (i32.and
                        (i32.eqz (i32.load8_u (i32.add (local.get $addr) (i32.const 2)))) ;; player team
                        (i32.ne (i32.load8_u (i32.add (local.get $addr) (i32.const 3))) (i32.const 4)) ;; not dead
                      )
                    )
                  (then
                    (local.set $best_i (i32.load16_s (i32.add (local.get $addr) (i32.const 4)))) ;; unit x
                    (local.set $best_dist (i32.load16_s (i32.add (local.get $addr) (i32.const 6)))) ;; unit y
                    (if (i32.and
                          (i32.and
                            (i32.ge_s (local.get $best_i) (local.get $ux))
                            (i32.le_s (local.get $best_i) (local.get $dx)))
                          (i32.and
                            (i32.ge_s (local.get $best_dist) (local.get $uy))
                            (i32.le_s (local.get $best_dist) (local.get $dy)))
                        )
                      (then
                        (i32.store8 (i32.add (local.get $addr) (i32.const 19)) (i32.const 1))
                        (if (i32.lt_s (local.get $nsel) (i32.const 16))
                          (then
                            (i32.store8 (i32.add (i32.const 0x1A920) (local.get $nsel)) (local.get $i))
                          )
                        )
                        (local.set $nsel (i32.add (local.get $nsel) (i32.const 1)))
                      )
                    )
                  )
                )
                (local.set $i (i32.add (local.get $i) (i32.const 1)))
                (br $bs_lp)
              )
            )
            (i32.store (i32.const 0x1A930) (local.get $nsel))
            (if (local.get $nsel)
              (then (call $note (i32.const 0) (i32.const 600) (i32.const 30) (i32.const 50)))
            )
          )
          (else
            ;; SINGLE SELECT - Find unit nearest to click (player only)
            (local.set $best_i (i32.const -1))
            (local.set $best_dist (i32.const 100))
            (local.set $i (i32.const 0))
            (block $sel_brk
              (loop $sel_lp
                (br_if $sel_brk (i32.ge_s (local.get $i) (i32.const 64)))
                (local.set $addr (i32.add (i32.const 0x14400) (i32.mul (local.get $i) (i32.const 32))))
                (if (i32.and
                      (i32.load8_u (local.get $addr))
                      (i32.and
                        (i32.eqz (i32.load8_u (i32.add (local.get $addr) (i32.const 2)))) ;; player team
                        (i32.ne (i32.load8_u (i32.add (local.get $addr) (i32.const 3))) (i32.const 4))
                      )
                    )
                  (then
                    (local.set $ux (i32.load16_s (i32.add (local.get $addr) (i32.const 4))))
                    (local.set $uy (i32.load16_s (i32.add (local.get $addr) (i32.const 6))))
                    (local.set $dist (i32.add
                      (call $abs (i32.sub (local.get $world_x) (local.get $ux)))
                      (call $abs (i32.sub (local.get $world_y) (local.get $uy)))))
                    (if (i32.lt_s (local.get $dist) (local.get $best_dist))
                      (then
                        (local.set $best_dist (local.get $dist))
                        (local.set $best_i (local.get $i))
                      )
                    )
                  )
                )
                (local.set $i (i32.add (local.get $i) (i32.const 1)))
                (br $sel_lp)
              )
            )

            (if (i32.ge_s (local.get $best_i) (i32.const 0))
              (then
                (local.set $addr (i32.add (i32.const 0x14400) (i32.mul (local.get $best_i) (i32.const 32))))
                (i32.store8 (i32.add (local.get $addr) (i32.const 19)) (i32.const 1))
                (i32.store8 (i32.const 0x1A920) (local.get $best_i))
                (i32.store (i32.const 0x1A930) (i32.const 1))
                (call $note (i32.const 0) (i32.const 600) (i32.const 30) (i32.const 50))
              )
            )
          )
        )

        (i32.store8 (i32.const 0x1A958) (i32.const 0)) ;; dragging = false
      )
    )

    ;; RIGHT CLICK - Command (move/attack)
    (if (i32.and (local.get $mbtn) (i32.const 4))
      (then
        (local.set $nsel (i32.load (i32.const 0x1A930)))
        (if (local.get $nsel)
          (then
            ;; Check if clicking on an enemy unit
            (local.set $clicked_enemy (i32.const -1))
            (local.set $best_dist (i32.const 15))
            (local.set $i (i32.const 0))
            (block $en_brk
              (loop $en_lp
                (br_if $en_brk (i32.ge_s (local.get $i) (i32.const 64)))
                (local.set $addr (i32.add (i32.const 0x14400) (i32.mul (local.get $i) (i32.const 32))))
                (if (i32.and
                      (i32.load8_u (local.get $addr))
                      (i32.and
                        (i32.eq (i32.load8_u (i32.add (local.get $addr) (i32.const 2))) (i32.const 1))
                        (i32.ne (i32.load8_u (i32.add (local.get $addr) (i32.const 3))) (i32.const 4))
                      )
                    )
                  (then
                    (local.set $ux (i32.load16_s (i32.add (local.get $addr) (i32.const 4))))
                    (local.set $uy (i32.load16_s (i32.add (local.get $addr) (i32.const 6))))
                    (local.set $dist (i32.add
                      (call $abs (i32.sub (local.get $world_x) (local.get $ux)))
                      (call $abs (i32.sub (local.get $world_y) (local.get $uy)))))
                    (if (i32.lt_s (local.get $dist) (local.get $best_dist))
                      (then
                        (local.set $best_dist (local.get $dist))
                        (local.set $clicked_enemy (local.get $i))
                      )
                    )
                  )
                )
                (local.set $i (i32.add (local.get $i) (i32.const 1)))
                (br $en_lp)
              )
            )

            ;; Pre-warm flow field for move target
            (if (i32.lt_s (local.get $clicked_enemy) (i32.const 0))
              (then (call $build_flow_field (local.get $world_x) (local.get $world_y)
                (call $find_or_alloc_flow_slot
                  (i32.add (i32.mul (i32.shr_u (local.get $world_y) (i32.const 3)) (i32.const 128))
                           (i32.shr_u (local.get $world_x) (i32.const 3))))))
            )

            ;; Command selected units
            (local.set $i (i32.const 0))
            (block $cmd_brk
              (loop $cmd_lp
                (br_if $cmd_brk (i32.ge_s (local.get $i) (i32.const 64)))
                (local.set $addr (i32.add (i32.const 0x14400) (i32.mul (local.get $i) (i32.const 32))))
                (if (i32.and
                      (i32.load8_u (local.get $addr))
                      (i32.load8_u (i32.add (local.get $addr) (i32.const 19)))
                    )
                  (then
                    (if (i32.ge_s (local.get $clicked_enemy) (i32.const 0))
                      (then
                        ;; Attack command
                        (i32.store8 (i32.add (local.get $addr) (i32.const 3)) (i32.const 2))
                        (i32.store8 (i32.add (local.get $addr) (i32.const 24)) (local.get $clicked_enemy))
                      )
                      (else
                        ;; Move command
                        (i32.store8 (i32.add (local.get $addr) (i32.const 3)) (i32.const 1))
                        (i32.store16 (i32.add (local.get $addr) (i32.const 8)) (local.get $world_x))
                        (i32.store16 (i32.add (local.get $addr) (i32.const 10)) (local.get $world_y))
                        (i32.store8 (i32.add (local.get $addr) (i32.const 24)) (i32.const 255))
                      )
                    )
                  )
                )
                (local.set $i (i32.add (local.get $i) (i32.const 1)))
                (br $cmd_lp)
              )
            )
            (call $note (i32.const 0) (i32.const 400) (i32.const 20) (i32.const 40))
          )
        )
      )
    )

    ;; BOTTOM BAR BUTTON CLICKS (left-click-up in bar area y>=184)
    (if (i32.and
          (i32.and
            (i32.eqz (i32.and (local.get $mbtn) (i32.const 1)))   ;; left released
            (i32.and (local.get $last_btn) (i32.const 1)))         ;; was pressed
          (i32.ge_u (local.get $my) (i32.const 184)))              ;; in bottom bar
      (then
        ;; Worker button: x=70..122
        (if (i32.and (i32.ge_u (local.get $mx) (i32.const 70))
                     (i32.lt_u (local.get $mx) (i32.const 122)))
          (then
            (local.set $gold (i32.load (i32.const 0x15690)))
            (if (i32.ge_s (local.get $gold) (i32.const 50))
              (then
                (i32.store (i32.const 0x15690) (i32.sub (local.get $gold) (i32.const 50)))
                (local.set $uid (call $create_unit (i32.const 0) (i32.const 0)
                  (i32.add (i32.const 96) (i32.rem_u (call $rng) (i32.const 20)))
                  (i32.add (i32.const 830) (i32.rem_u (call $rng) (i32.const 20)))))
                (call $note (i32.const 0) (i32.const 500) (i32.const 50) (i32.const 60)))
              (else (call $note (i32.const 1) (i32.const 100) (i32.const 100) (i32.const 60))))))
        ;; Soldier button: x=128..186
        (if (i32.and (i32.ge_u (local.get $mx) (i32.const 128))
                     (i32.lt_u (local.get $mx) (i32.const 186)))
          (then
            (local.set $gold (i32.load (i32.const 0x15690)))
            (if (i32.ge_s (local.get $gold) (i32.const 100))
              (then
                (i32.store (i32.const 0x15690) (i32.sub (local.get $gold) (i32.const 100)))
                (local.set $uid (call $create_unit (i32.const 1) (i32.const 0)
                  (i32.add (i32.const 96) (i32.rem_u (call $rng) (i32.const 20)))
                  (i32.add (i32.const 830) (i32.rem_u (call $rng) (i32.const 20)))))
                (call $note (i32.const 1) (i32.const 400) (i32.const 50) (i32.const 70)))
              (else (call $note (i32.const 1) (i32.const 100) (i32.const 100) (i32.const 60))))))
        ;; Archer button: x=192..244
        (if (i32.and (i32.ge_u (local.get $mx) (i32.const 192))
                     (i32.lt_u (local.get $mx) (i32.const 244)))
          (then
            (local.set $gold (i32.load (i32.const 0x15690)))
            (if (i32.ge_s (local.get $gold) (i32.const 80))
              (then
                (i32.store (i32.const 0x15690) (i32.sub (local.get $gold) (i32.const 80)))
                (local.set $uid (call $create_unit (i32.const 2) (i32.const 0)
                  (i32.add (i32.const 96) (i32.rem_u (call $rng) (i32.const 20)))
                  (i32.add (i32.const 830) (i32.rem_u (call $rng) (i32.const 20)))))
                (call $note (i32.const 3) (i32.const 500) (i32.const 50) (i32.const 60)))
              (else (call $note (i32.const 1) (i32.const 100) (i32.const 100) (i32.const 60))))))
      )
    )

    ;; SPACE - spawn worker (cost 50 gold)
    (if (i32.and
          (i32.and (local.get $keys) (i32.const 16)) ;; space
          (i32.eqz (i32.and (i32.load (i32.const 0x1A944)) (i32.const 16))) ;; wasn't pressed
        )
      (then
        (local.set $gold (i32.load (i32.const 0x15690)))
        (if (i32.ge_s (local.get $gold) (i32.const 50))
          (then
            (i32.store (i32.const 0x15690) (i32.sub (local.get $gold) (i32.const 50)))
            (local.set $uid (call $create_unit (i32.const 0) (i32.const 0)
              (i32.add (i32.const 96) (i32.rem_u (call $rng) (i32.const 20)))
              (i32.add (i32.const 830) (i32.rem_u (call $rng) (i32.const 20)))))
            (call $note (i32.const 0) (i32.const 500) (i32.const 50) (i32.const 60))
          )
          (else
            (call $note (i32.const 1) (i32.const 100) (i32.const 100) (i32.const 60))
          )
        )
      )
    )

    ;; ENTER - spawn soldier (cost 100 gold)
    (if (i32.and
          (i32.and (local.get $keys) (i32.const 32)) ;; enter
          (i32.eqz (i32.and (i32.load (i32.const 0x1A944)) (i32.const 32)))
        )
      (then
        (local.set $gold (i32.load (i32.const 0x15690)))
        (if (i32.ge_s (local.get $gold) (i32.const 100))
          (then
            (i32.store (i32.const 0x15690) (i32.sub (local.get $gold) (i32.const 100)))
            (local.set $uid (call $create_unit (i32.const 1) (i32.const 0)
              (i32.add (i32.const 96) (i32.rem_u (call $rng) (i32.const 20)))
              (i32.add (i32.const 830) (i32.rem_u (call $rng) (i32.const 20)))))
            (call $note (i32.const 1) (i32.const 400) (i32.const 50) (i32.const 70))
          )
          (else
            (call $note (i32.const 1) (i32.const 100) (i32.const 100) (i32.const 60))
          )
        )
      )
    )

    ;; SHIFT - spawn archer (cost 80 gold)
    (if (i32.and
          (i32.and (local.get $keys) (i32.const 128)) ;; shift
          (i32.eqz (i32.and (i32.load (i32.const 0x1A944)) (i32.const 128)))
        )
      (then
        (local.set $gold (i32.load (i32.const 0x15690)))
        (if (i32.ge_s (local.get $gold) (i32.const 80))
          (then
            (i32.store (i32.const 0x15690) (i32.sub (local.get $gold) (i32.const 80)))
            (local.set $uid (call $create_unit (i32.const 2) (i32.const 0)
              (i32.add (i32.const 96) (i32.rem_u (call $rng) (i32.const 20)))
              (i32.add (i32.const 830) (i32.rem_u (call $rng) (i32.const 20)))))
            (call $note (i32.const 3) (i32.const 500) (i32.const 50) (i32.const 60))
          )
          (else
            (call $note (i32.const 1) (i32.const 100) (i32.const 100) (i32.const 60))
          )
        )
      )
    )

    ;; Save last button state
    (i32.store8 (i32.const 0x1A940) (local.get $mbtn))
    (i32.store (i32.const 0x1A944) (local.get $keys))
  )

  ;; ============ DRAW UI ============
  (func $draw_ui
    (local $gold i32)
    (local $d i32)
    (local $x i32)
    (local $digit i32)
    (local $nsel i32)
    (local $sel_type i32)
    (local $addr i32)

    ;; Bottom UI bar
    (call $fill_rect (i32.const 0) (i32.const 184) (i32.const 320) (i32.const 16) (i32.const 30))
    (call $hline (i32.const 0) (i32.const 184) (i32.const 320) (i32.const 31))

    ;; Gold display
    ;; "G:" label
    (call $fill_rect (i32.const 4) (i32.const 188) (i32.const 3) (i32.const 5) (i32.const 15)) ;; gold icon
    (call $put_pixel (i32.const 3) (i32.const 189) (i32.const 15))
    (call $put_pixel (i32.const 3) (i32.const 190) (i32.const 15))
    (call $put_pixel (i32.const 7) (i32.const 189) (i32.const 16))
    (call $put_pixel (i32.const 7) (i32.const 190) (i32.const 16))

    ;; Gold number
    (local.set $gold (i32.load (i32.const 0x15690)))
    (local.set $x (i32.const 12))

    ;; Hundreds
    (local.set $digit (i32.div_u (local.get $gold) (i32.const 1000)))
    (if (local.get $digit)
      (then
        (call $draw_digit (local.get $x) (i32.const 188) (local.get $digit) (i32.const 12))
        (local.set $x (i32.add (local.get $x) (i32.const 5)))
      )
    )
    (local.set $digit (i32.rem_u (i32.div_u (local.get $gold) (i32.const 100)) (i32.const 10)))
    (if (i32.or (local.get $digit) (i32.ge_u (local.get $gold) (i32.const 100)))
      (then
        (call $draw_digit (local.get $x) (i32.const 188) (local.get $digit) (i32.const 12))
        (local.set $x (i32.add (local.get $x) (i32.const 5)))
      )
    )
    (local.set $digit (i32.rem_u (i32.div_u (local.get $gold) (i32.const 10)) (i32.const 10)))
    (if (i32.or (local.get $digit) (i32.ge_u (local.get $gold) (i32.const 10)))
      (then
        (call $draw_digit (local.get $x) (i32.const 188) (local.get $digit) (i32.const 12))
        (local.set $x (i32.add (local.get $x) (i32.const 5)))
      )
    )
    (local.set $digit (i32.rem_u (local.get $gold) (i32.const 10)))
    (call $draw_digit (local.get $x) (i32.const 188) (local.get $digit) (i32.const 12))

    ;; Unit spawn hotkey hints
    ;; SPC:Worker ENTER:Knight SHIFT:Archer
    ;; Simplified: colored boxes with costs
    ;; Worker box (blue)
    (call $fill_rect (i32.const 70) (i32.const 186) (i32.const 52) (i32.const 12) (i32.const 31))
    (call $fill_rect (i32.const 71) (i32.const 187) (i32.const 8) (i32.const 10) (i32.const 19))
    ;; "W" for worker pixel art mini
    (call $fill_rect (i32.const 72) (i32.const 188) (i32.const 3) (i32.const 2) (i32.const 17))
    (call $fill_rect (i32.const 72) (i32.const 190) (i32.const 3) (i32.const 3) (i32.const 19))
    ;; Cost "50"
    (call $draw_digit (i32.const 82) (i32.const 189) (i32.const 5) (i32.const 15))
    (call $draw_digit (i32.const 87) (i32.const 189) (i32.const 0) (i32.const 15))
    ;; "SPC" label
    (call $put_pixel (i32.const 95) (i32.const 188) (i32.const 10))
    (call $put_pixel (i32.const 97) (i32.const 188) (i32.const 10))
    (call $put_pixel (i32.const 99) (i32.const 188) (i32.const 10))

    ;; Soldier box
    (call $fill_rect (i32.const 128) (i32.const 186) (i32.const 58) (i32.const 12) (i32.const 31))
    (call $fill_rect (i32.const 129) (i32.const 187) (i32.const 8) (i32.const 10) (i32.const 19))
    ;; Soldier mini
    (call $fill_rect (i32.const 130) (i32.const 187) (i32.const 3) (i32.const 2) (i32.const 10))
    (call $fill_rect (i32.const 130) (i32.const 189) (i32.const 3) (i32.const 3) (i32.const 19))
    (call $put_pixel (i32.const 134) (i32.const 189) (i32.const 11))
    ;; Cost "100"
    (call $draw_digit (i32.const 140) (i32.const 189) (i32.const 1) (i32.const 15))
    (call $draw_digit (i32.const 145) (i32.const 189) (i32.const 0) (i32.const 15))
    (call $draw_digit (i32.const 150) (i32.const 189) (i32.const 0) (i32.const 15))

    ;; Archer box
    (call $fill_rect (i32.const 192) (i32.const 186) (i32.const 52) (i32.const 12) (i32.const 31))
    (call $fill_rect (i32.const 193) (i32.const 187) (i32.const 8) (i32.const 10) (i32.const 19))
    ;; Archer mini
    (call $fill_rect (i32.const 194) (i32.const 187) (i32.const 3) (i32.const 2) (i32.const 25))
    (call $fill_rect (i32.const 194) (i32.const 189) (i32.const 3) (i32.const 3) (i32.const 19))
    (call $put_pixel (i32.const 198) (i32.const 189) (i32.const 5))
    ;; Cost "80"
    (call $draw_digit (i32.const 204) (i32.const 189) (i32.const 8) (i32.const 15))
    (call $draw_digit (i32.const 209) (i32.const 189) (i32.const 0) (i32.const 15))

    ;; Minimap (top-right corner, 48x48)
    (call $draw_minimap)
  )

  ;; ============ TINY DIGIT RENDERER (3x5 pixel digits) ============
  (func $draw_digit (param $x i32) (param $y i32) (param $d i32) (param $col i32)
    ;; Ultra simple 3x5 pixel font for digits 0-9
    ;; Using hardcoded patterns

    (if (i32.eq (local.get $d) (i32.const 0))
      (then
        (call $hline (local.get $x) (local.get $y) (i32.const 3) (local.get $col))
        (call $put_pixel (local.get $x) (i32.add (local.get $y) (i32.const 1)) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 1)) (local.get $col))
        (call $put_pixel (local.get $x) (i32.add (local.get $y) (i32.const 2)) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 2)) (local.get $col))
        (call $put_pixel (local.get $x) (i32.add (local.get $y) (i32.const 3)) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 3)) (local.get $col))
        (call $hline (local.get $x) (i32.add (local.get $y) (i32.const 4)) (i32.const 3) (local.get $col))
      )
    )
    (if (i32.eq (local.get $d) (i32.const 1))
      (then
        (call $put_pixel (i32.add (local.get $x) (i32.const 1)) (local.get $y) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 1)) (i32.add (local.get $y) (i32.const 1)) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 1)) (i32.add (local.get $y) (i32.const 2)) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 1)) (i32.add (local.get $y) (i32.const 3)) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 1)) (i32.add (local.get $y) (i32.const 4)) (local.get $col))
      )
    )
    (if (i32.eq (local.get $d) (i32.const 2))
      (then
        (call $hline (local.get $x) (local.get $y) (i32.const 3) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 1)) (local.get $col))
        (call $hline (local.get $x) (i32.add (local.get $y) (i32.const 2)) (i32.const 3) (local.get $col))
        (call $put_pixel (local.get $x) (i32.add (local.get $y) (i32.const 3)) (local.get $col))
        (call $hline (local.get $x) (i32.add (local.get $y) (i32.const 4)) (i32.const 3) (local.get $col))
      )
    )
    (if (i32.eq (local.get $d) (i32.const 3))
      (then
        (call $hline (local.get $x) (local.get $y) (i32.const 3) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 1)) (local.get $col))
        (call $hline (local.get $x) (i32.add (local.get $y) (i32.const 2)) (i32.const 3) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 3)) (local.get $col))
        (call $hline (local.get $x) (i32.add (local.get $y) (i32.const 4)) (i32.const 3) (local.get $col))
      )
    )
    (if (i32.eq (local.get $d) (i32.const 4))
      (then
        (call $put_pixel (local.get $x) (local.get $y) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (local.get $y) (local.get $col))
        (call $put_pixel (local.get $x) (i32.add (local.get $y) (i32.const 1)) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 1)) (local.get $col))
        (call $hline (local.get $x) (i32.add (local.get $y) (i32.const 2)) (i32.const 3) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 3)) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 4)) (local.get $col))
      )
    )
    (if (i32.eq (local.get $d) (i32.const 5))
      (then
        (call $hline (local.get $x) (local.get $y) (i32.const 3) (local.get $col))
        (call $put_pixel (local.get $x) (i32.add (local.get $y) (i32.const 1)) (local.get $col))
        (call $hline (local.get $x) (i32.add (local.get $y) (i32.const 2)) (i32.const 3) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 3)) (local.get $col))
        (call $hline (local.get $x) (i32.add (local.get $y) (i32.const 4)) (i32.const 3) (local.get $col))
      )
    )
    (if (i32.eq (local.get $d) (i32.const 6))
      (then
        (call $hline (local.get $x) (local.get $y) (i32.const 3) (local.get $col))
        (call $put_pixel (local.get $x) (i32.add (local.get $y) (i32.const 1)) (local.get $col))
        (call $hline (local.get $x) (i32.add (local.get $y) (i32.const 2)) (i32.const 3) (local.get $col))
        (call $put_pixel (local.get $x) (i32.add (local.get $y) (i32.const 3)) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 3)) (local.get $col))
        (call $hline (local.get $x) (i32.add (local.get $y) (i32.const 4)) (i32.const 3) (local.get $col))
      )
    )
    (if (i32.eq (local.get $d) (i32.const 7))
      (then
        (call $hline (local.get $x) (local.get $y) (i32.const 3) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 1)) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 2)) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 3)) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 4)) (local.get $col))
      )
    )
    (if (i32.eq (local.get $d) (i32.const 8))
      (then
        (call $hline (local.get $x) (local.get $y) (i32.const 3) (local.get $col))
        (call $put_pixel (local.get $x) (i32.add (local.get $y) (i32.const 1)) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 1)) (local.get $col))
        (call $hline (local.get $x) (i32.add (local.get $y) (i32.const 2)) (i32.const 3) (local.get $col))
        (call $put_pixel (local.get $x) (i32.add (local.get $y) (i32.const 3)) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 3)) (local.get $col))
        (call $hline (local.get $x) (i32.add (local.get $y) (i32.const 4)) (i32.const 3) (local.get $col))
      )
    )
    (if (i32.eq (local.get $d) (i32.const 9))
      (then
        (call $hline (local.get $x) (local.get $y) (i32.const 3) (local.get $col))
        (call $put_pixel (local.get $x) (i32.add (local.get $y) (i32.const 1)) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 1)) (local.get $col))
        (call $hline (local.get $x) (i32.add (local.get $y) (i32.const 2)) (i32.const 3) (local.get $col))
        (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 3)) (local.get $col))
        (call $hline (local.get $x) (i32.add (local.get $y) (i32.const 4)) (i32.const 3) (local.get $col))
      )
    )
  )

  ;; ============ MINIMAP ============
  (func $draw_minimap
    (local $mx i32)
    (local $my i32)
    (local $tx i32)
    (local $ty i32)
    (local $tile i32)
    (local $col i32)
    (local $sx i32)
    (local $sy i32)
    (local $i i32)
    (local $addr i32)
    (local $cam_x i32)
    (local $cam_y i32)

    (local.set $sx (i32.const 268)) ;; top-right
    (local.set $sy (i32.const 2))

    ;; Border
    (call $fill_rect (i32.sub (local.get $sx) (i32.const 1)) (i32.sub (local.get $sy) (i32.const 1))
      (i32.const 50) (i32.const 50) (i32.const 31))

    ;; Draw map at 1:2.67 scale (128 tiles -> 48px)
    (local.set $my (i32.const 0))
    (block $brk_y
      (loop $lp_y
        (br_if $brk_y (i32.ge_s (local.get $my) (i32.const 48)))
        (local.set $mx (i32.const 0))
        (block $brk_x
          (loop $lp_x
            (br_if $brk_x (i32.ge_s (local.get $mx) (i32.const 48)))
            ;; Map tile position
            (local.set $tx (i32.div_u (i32.mul (local.get $mx) (i32.const 128)) (i32.const 48)))
            (local.set $ty (i32.div_u (i32.mul (local.get $my) (i32.const 128)) (i32.const 48)))
            (local.set $addr (i32.add (i32.const 0x10400)
              (i32.add (i32.mul (local.get $ty) (i32.const 128)) (local.get $tx))))
            (local.set $tile (i32.load8_u (local.get $addr)))

            (local.set $col (i32.const 2)) ;; default green
            (if (i32.eq (local.get $tile) (i32.const 4)) (then (local.set $col (i32.const 7)))) ;; water
            (if (i32.eq (local.get $tile) (i32.const 5)) (then (local.set $col (i32.const 33)))) ;; tree
            (if (i32.eq (local.get $tile) (i32.const 6)) (then (local.set $col (i32.const 9)))) ;; stone/mountain
            (if (i32.eq (local.get $tile) (i32.const 7)) (then (local.set $col (i32.const 40)))) ;; gold

            (call $put_pixel
              (i32.add (local.get $sx) (local.get $mx))
              (i32.add (local.get $sy) (local.get $my))
              (local.get $col))

            (local.set $mx (i32.add (local.get $mx) (i32.const 1)))
            (br $lp_x)
          )
        )
        (local.set $my (i32.add (local.get $my) (i32.const 1)))
        (br $lp_y)
      )
    )

    ;; Draw units on minimap
    (local.set $i (i32.const 0))
    (block $ubrk
      (loop $ulp
        (br_if $ubrk (i32.ge_s (local.get $i) (i32.const 64)))
        (local.set $addr (i32.add (i32.const 0x14400) (i32.mul (local.get $i) (i32.const 32))))
        (if (i32.and
              (i32.load8_u (local.get $addr))
              (i32.ne (i32.load8_u (i32.add (local.get $addr) (i32.const 3))) (i32.const 4))
            )
          (then
            (local.set $mx (i32.div_u
              (i32.mul (i32.load16_s (i32.add (local.get $addr) (i32.const 4))) (i32.const 48))
              (i32.const 1024)))
            (local.set $my (i32.div_u
              (i32.mul (i32.load16_s (i32.add (local.get $addr) (i32.const 6))) (i32.const 48))
              (i32.const 1024)))
            (local.set $col
              (if (result i32) (i32.eqz (i32.load8_u (i32.add (local.get $addr) (i32.const 2))))
                (then (i32.const 38)) ;; blue for player
                (else (i32.const 39)) ;; red for enemy
              )
            )
            (call $put_pixel
              (i32.add (local.get $sx) (local.get $mx))
              (i32.add (local.get $sy) (local.get $my))
              (local.get $col))
          )
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $ulp)
      )
    )

    ;; Camera viewport box
    (local.set $cam_x (i32.load16_s (i32.const 0x1A820)))
    (local.set $cam_y (i32.load16_s (i32.const 0x1A822)))
    (local.set $mx (i32.div_u (i32.mul (local.get $cam_x) (i32.const 48)) (i32.const 1024)))
    (local.set $my (i32.div_u (i32.mul (local.get $cam_y) (i32.const 48)) (i32.const 1024)))
    ;; Draw viewport rectangle outline
    (call $hline (i32.add (local.get $sx) (local.get $mx))
      (i32.add (local.get $sy) (local.get $my)) (i32.const 15) (i32.const 12))
    (call $hline (i32.add (local.get $sx) (local.get $mx))
      (i32.add (i32.add (local.get $sy) (local.get $my)) (i32.const 9)) (i32.const 15) (i32.const 12))
    (call $vline (i32.add (local.get $sx) (local.get $mx))
      (i32.add (local.get $sy) (local.get $my)) (i32.const 10) (i32.const 12))
    (call $vline (i32.add (i32.add (local.get $sx) (local.get $mx)) (i32.const 14))
      (i32.add (local.get $sy) (local.get $my)) (i32.const 10) (i32.const 12))
  )

  ;; ============ UNIT SEPARATION ============
  ;; Push overlapping units apart so they don't stack
  (func $separate_units
    (local $i i32)
    (local $j i32)
    (local $addr_i i32)
    (local $addr_j i32)
    (local $ix i32)
    (local $iy i32)
    (local $jx i32)
    (local $jy i32)
    (local $dx i32)
    (local $dy i32)

    ;; Only run every 4th frame to prevent flicker
    (if (i32.and (i32.load (i32.const 0)) (i32.const 3)) (then (return)))

    (local.set $i (i32.const 0))
    (block $brk_i
      (loop $lp_i
        (br_if $brk_i (i32.ge_s (local.get $i) (i32.const 64)))
        (local.set $addr_i (i32.add (i32.const 0x14400) (i32.mul (local.get $i) (i32.const 32))))
        (if (i32.and
              (i32.load8_u (local.get $addr_i))
              (i32.ne (i32.load8_u (i32.add (local.get $addr_i) (i32.const 3))) (i32.const 4))) ;; active & not dead
          (then
            (local.set $ix (i32.load16_s (i32.add (local.get $addr_i) (i32.const 4))))
            (local.set $iy (i32.load16_s (i32.add (local.get $addr_i) (i32.const 6))))

            (local.set $j (i32.add (local.get $i) (i32.const 1)))
            (block $brk_j
              (loop $lp_j
                (br_if $brk_j (i32.ge_s (local.get $j) (i32.const 64)))
                (local.set $addr_j (i32.add (i32.const 0x14400) (i32.mul (local.get $j) (i32.const 32))))
                (if (i32.and
                      (i32.load8_u (local.get $addr_j))
                      (i32.ne (i32.load8_u (i32.add (local.get $addr_j) (i32.const 3))) (i32.const 4)))
                  (then
                    (local.set $jx (i32.load16_s (i32.add (local.get $addr_j) (i32.const 4))))
                    (local.set $jy (i32.load16_s (i32.add (local.get $addr_j) (i32.const 6))))
                    (local.set $dx (i32.sub (local.get $ix) (local.get $jx)))
                    (local.set $dy (i32.sub (local.get $iy) (local.get $jy)))

                    ;; If within 12px manhattan distance, push apart
                    (if (i32.lt_s (i32.add (call $abs (local.get $dx)) (call $abs (local.get $dy))) (i32.const 12))
                      (then
                        ;; Push each unit 1px away from the other
                        ;; If exactly overlapping, push in arbitrary direction
                        (if (i32.and (i32.eqz (local.get $dx)) (i32.eqz (local.get $dy)))
                          (then
                            (local.set $dx (i32.const 1))
                            (local.set $dy (i32.const 1))
                          )
                        )
                        ;; Only push unit j away from i (asymmetric to prevent oscillation)
                        (if (i32.ge_s (call $abs (local.get $dx)) (call $abs (local.get $dy)))
                          (then
                            ;; Push j horizontally away from i
                            (if (i32.gt_s (local.get $dx) (i32.const 0))
                              (then
                                (i32.store16 (i32.add (local.get $addr_j) (i32.const 4)) (i32.sub (local.get $jx) (i32.const 1)))
                              )
                              (else
                                (i32.store16 (i32.add (local.get $addr_j) (i32.const 4)) (i32.add (local.get $jx) (i32.const 1)))
                              )
                            )
                          )
                          (else
                            ;; Push j vertically away from i
                            (if (i32.gt_s (local.get $dy) (i32.const 0))
                              (then
                                (i32.store16 (i32.add (local.get $addr_j) (i32.const 6)) (i32.sub (local.get $jy) (i32.const 1)))
                              )
                              (else
                                (i32.store16 (i32.add (local.get $addr_j) (i32.const 6)) (i32.add (local.get $jy) (i32.const 1)))
                              )
                            )
                          )
                        )
                        ;; Re-read i position since it may have changed
                        (local.set $ix (i32.load16_s (i32.add (local.get $addr_i) (i32.const 4))))
                        (local.set $iy (i32.load16_s (i32.add (local.get $addr_i) (i32.const 6))))
                      )
                    )
                  )
                )
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $lp_j)
              )
            )
          )
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_i)
      )
    )
  )

  ;; ============ REMOVE DEAD UNITS (cleanup) ============
  (func $cleanup_dead
    (local $i i32)
    (local $addr i32)
    (local $timer i32)
    ;; Remove units that have been dead for a while
    (local.set $i (i32.const 0))
    (block $brk
      (loop $lp
        (br_if $brk (i32.ge_s (local.get $i) (i32.const 64)))
        (local.set $addr (i32.add (i32.const 0x14400) (i32.mul (local.get $i) (i32.const 32))))
        (if (i32.and
              (i32.load8_u (local.get $addr))
              (i32.eq (i32.load8_u (i32.add (local.get $addr) (i32.const 3))) (i32.const 4))
            )
          (then
            ;; Use attack_timer as death counter
            (local.set $timer (i32.load8_u (i32.add (local.get $addr) (i32.const 22))))
            (local.set $timer (i32.add (local.get $timer) (i32.const 1)))
            (if (i32.gt_u (local.get $timer) (i32.const 120))
              (then
                ;; Remove unit
                (i32.store8 (local.get $addr) (i32.const 0))
              )
              (else
                (i32.store8 (i32.add (local.get $addr) (i32.const 22)) (local.get $timer))
              )
            )
          )
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)
      )
    )
  )

  ;; ============ SETUP MUSIC ============
  (func $setup_music
    (local $addr i32)
    (local.set $addr (i32.const 0x1A710))
    ;; BPM
    (i32.store16 (local.get $addr) (i32.const 100))
    ;; Steps
    (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (i32.const 16))
    ;; Num tracks
    (i32.store8 (i32.add (local.get $addr) (i32.const 3)) (i32.const 2))
    ;; Track 0: bass (square wave)
    (i32.store8 (i32.add (local.get $addr) (i32.const 4)) (i32.const 1)) ;; square
    (i32.store8 (i32.add (local.get $addr) (i32.const 5)) (i32.const 40)) ;; vol
    (i32.store8 (i32.add (local.get $addr) (i32.const 6)) (i32.const 15)) ;; dur
    ;; Track 1: melody (triangle)
    (i32.store8 (i32.add (local.get $addr) (i32.const 8)) (i32.const 3)) ;; triangle
    (i32.store8 (i32.add (local.get $addr) (i32.const 9)) (i32.const 30)) ;; vol
    (i32.store8 (i32.add (local.get $addr) (i32.const 10)) (i32.const 10)) ;; dur

    ;; Notes - bass: E2-A2-B2-A2 pattern (MIDI notes)
    ;; Track 0 notes (offset +16)
    (i32.store8 (i32.add (local.get $addr) (i32.const 16)) (i32.const 40)) ;; E2
    (i32.store8 (i32.add (local.get $addr) (i32.const 17)) (i32.const 0))
    (i32.store8 (i32.add (local.get $addr) (i32.const 18)) (i32.const 40))
    (i32.store8 (i32.add (local.get $addr) (i32.const 19)) (i32.const 0))
    (i32.store8 (i32.add (local.get $addr) (i32.const 20)) (i32.const 45)) ;; A2
    (i32.store8 (i32.add (local.get $addr) (i32.const 21)) (i32.const 0))
    (i32.store8 (i32.add (local.get $addr) (i32.const 22)) (i32.const 45))
    (i32.store8 (i32.add (local.get $addr) (i32.const 23)) (i32.const 0))
    (i32.store8 (i32.add (local.get $addr) (i32.const 24)) (i32.const 47)) ;; B2
    (i32.store8 (i32.add (local.get $addr) (i32.const 25)) (i32.const 0))
    (i32.store8 (i32.add (local.get $addr) (i32.const 26)) (i32.const 47))
    (i32.store8 (i32.add (local.get $addr) (i32.const 27)) (i32.const 0))
    (i32.store8 (i32.add (local.get $addr) (i32.const 28)) (i32.const 45)) ;; A2
    (i32.store8 (i32.add (local.get $addr) (i32.const 29)) (i32.const 0))
    (i32.store8 (i32.add (local.get $addr) (i32.const 30)) (i32.const 45))
    (i32.store8 (i32.add (local.get $addr) (i32.const 31)) (i32.const 0))

    ;; Track 1 notes (offset +16+16=+32): melody
    (i32.store8 (i32.add (local.get $addr) (i32.const 32)) (i32.const 64)) ;; E4
    (i32.store8 (i32.add (local.get $addr) (i32.const 33)) (i32.const 67)) ;; G4
    (i32.store8 (i32.add (local.get $addr) (i32.const 34)) (i32.const 69)) ;; A4
    (i32.store8 (i32.add (local.get $addr) (i32.const 35)) (i32.const 67))
    (i32.store8 (i32.add (local.get $addr) (i32.const 36)) (i32.const 64))
    (i32.store8 (i32.add (local.get $addr) (i32.const 37)) (i32.const 0))
    (i32.store8 (i32.add (local.get $addr) (i32.const 38)) (i32.const 62)) ;; D4
    (i32.store8 (i32.add (local.get $addr) (i32.const 39)) (i32.const 0))
    (i32.store8 (i32.add (local.get $addr) (i32.const 40)) (i32.const 64))
    (i32.store8 (i32.add (local.get $addr) (i32.const 41)) (i32.const 67))
    (i32.store8 (i32.add (local.get $addr) (i32.const 42)) (i32.const 71)) ;; B4
    (i32.store8 (i32.add (local.get $addr) (i32.const 43)) (i32.const 69))
    (i32.store8 (i32.add (local.get $addr) (i32.const 44)) (i32.const 67))
    (i32.store8 (i32.add (local.get $addr) (i32.const 45)) (i32.const 0))
    (i32.store8 (i32.add (local.get $addr) (i32.const 46)) (i32.const 64))
    (i32.store8 (i32.add (local.get $addr) (i32.const 47)) (i32.const 0))

    (call $music (local.get $addr))
  )

  ;; ============ INIT ============
  (func (export "init")
    ;; Clear flow field slot headers (4 slots × 16 bytes)
    (i32.store (i32.const 0x1AFC0) (i32.const 0))
    (i32.store (i32.const 0x1AFC4) (i32.const 0))
    (i32.store (i32.const 0x1AFC8) (i32.const 0))
    (i32.store (i32.const 0x1AFCC) (i32.const 0))
    (i32.store (i32.const 0x1AFD0) (i32.const 0))
    (i32.store (i32.const 0x1AFD4) (i32.const 0))
    (i32.store (i32.const 0x1AFD8) (i32.const 0))
    (i32.store (i32.const 0x1AFDC) (i32.const 0))
    (i32.store (i32.const 0x1AFE0) (i32.const 0))
    (i32.store (i32.const 0x1AFE4) (i32.const 0))
    (i32.store (i32.const 0x1AFE8) (i32.const 0))
    (i32.store (i32.const 0x1AFEC) (i32.const 0))
    (i32.store (i32.const 0x1AFF0) (i32.const 0))
    (i32.store (i32.const 0x1AFF4) (i32.const 0))
    (i32.store (i32.const 0x1AFF8) (i32.const 0))
    (i32.store (i32.const 0x1AFFC) (i32.const 0))

    ;; Seed RNG
    (i32.store (i32.const 0x1A810) (i32.const 12345678))

    ;; Setup palette
    (call $setup_palette)

    ;; Generate map
    (call $generate_map)

    ;; Starting gold
    (i32.store (i32.const 0x15690) (i32.const 200))

    ;; Camera starts near player base
    (i32.store16 (i32.const 0x1A820) (i32.const 0)) ;; cam_x
    (i32.store16 (i32.const 0x1A822) (i32.const 640)) ;; cam_y

    ;; Create player buildings
    ;; Town Hall at tile (10, 100) -> pixel (80, 800)
    (drop (call $create_building (i32.const 0) (i32.const 0) (i32.const 10) (i32.const 100)))
    ;; Barracks at tile (16, 102) -> pixel (128, 816)
    (drop (call $create_building (i32.const 1) (i32.const 0) (i32.const 16) (i32.const 102)))
    ;; Gold mine at (25, 105)
    (drop (call $create_building (i32.const 3) (i32.const 0) (i32.const 25) (i32.const 105)))

    ;; Create enemy buildings
    ;; Enemy Town Hall at tile (110, 10)
    (drop (call $create_building (i32.const 4) (i32.const 1) (i32.const 110) (i32.const 10)))
    ;; Enemy Barracks at tile (106, 12)
    (drop (call $create_building (i32.const 5) (i32.const 1) (i32.const 106) (i32.const 12)))
    ;; Enemy Gold Mine at (100, 15)
    (drop (call $create_building (i32.const 3) (i32.const 1) (i32.const 100) (i32.const 15)))

    ;; Create starting player units
    ;; 2 workers
    (drop (call $create_unit (i32.const 0) (i32.const 0) (i32.const 100) (i32.const 830)))
    (drop (call $create_unit (i32.const 0) (i32.const 0) (i32.const 115) (i32.const 835)))
    ;; 1 soldier
    (drop (call $create_unit (i32.const 1) (i32.const 0) (i32.const 140) (i32.const 830)))

    ;; Create starting enemy units
    (drop (call $create_unit (i32.const 3) (i32.const 1) (i32.const 890) (i32.const 100)))
    (drop (call $create_unit (i32.const 3) (i32.const 1) (i32.const 870) (i32.const 110)))

    ;; Set workers to auto-gather gold
    ;; Worker 0 - send to gather
    (i32.store8 (i32.add (i32.const 0x14400) (i32.const 3)) (i32.const 3)) ;; gathering state
    (i32.store16 (i32.add (i32.const 0x14400) (i32.const 8)) (i32.const 208)) ;; target gold mine x
    (i32.store16 (i32.add (i32.const 0x14400) (i32.const 10)) (i32.const 840)) ;; target gold mine y
    ;; Worker 1
    (i32.store8 (i32.add (i32.add (i32.const 0x14400) (i32.const 32)) (i32.const 3)) (i32.const 3))
    (i32.store16 (i32.add (i32.add (i32.const 0x14400) (i32.const 32)) (i32.const 8)) (i32.const 208))
    (i32.store16 (i32.add (i32.add (i32.const 0x14400) (i32.const 32)) (i32.const 10)) (i32.const 840))

    ;; Setup music
    (call $setup_music)
  )

  ;; ============ FRAME ============
  (func (export "frame")
    (local $cam_x i32)
    (local $cam_y i32)
    (local $start_tx i32)
    (local $start_ty i32)
    (local $end_tx i32)
    (local $end_ty i32)
    (local $tx i32)
    (local $ty i32)
    (local $sx i32)
    (local $sy i32)
    (local $i i32)

    ;; Reset flow field user counts each frame
    (i32.store (i32.const 0x1AFC8) (i32.const 0))
    (i32.store (i32.const 0x1AFD8) (i32.const 0))
    (i32.store (i32.const 0x1AFE8) (i32.const 0))
    (i32.store (i32.const 0x1AFF8) (i32.const 0))

    ;; Handle input first
    (call $handle_input)

    ;; Update game logic
    (call $update_units)
    (call $update_ai)
    (call $separate_units)
    (call $cleanup_dead)

    ;; Get camera
    (local.set $cam_x (i32.load16_s (i32.const 0x1A820)))
    (local.set $cam_y (i32.load16_s (i32.const 0x1A822)))

    ;; Calculate visible tile range
    (local.set $start_tx (i32.div_s (local.get $cam_x) (i32.const 8)))
    (local.set $start_ty (i32.div_s (local.get $cam_y) (i32.const 8)))
    (local.set $end_tx (i32.add (local.get $start_tx) (i32.const 41)))
    (local.set $end_ty (i32.add (local.get $start_ty) (i32.const 26)))

    ;; Clamp
    (if (i32.lt_s (local.get $start_tx) (i32.const 0))
      (then (local.set $start_tx (i32.const 0))))
    (if (i32.lt_s (local.get $start_ty) (i32.const 0))
      (then (local.set $start_ty (i32.const 0))))
    (if (i32.gt_s (local.get $end_tx) (i32.const 128))
      (then (local.set $end_tx (i32.const 128))))
    (if (i32.gt_s (local.get $end_ty) (i32.const 128))
      (then (local.set $end_ty (i32.const 128))))

    ;; Draw visible tiles
    (local.set $ty (local.get $start_ty))
    (block $brk_y
      (loop $lp_y
        (br_if $brk_y (i32.ge_s (local.get $ty) (local.get $end_ty)))
        (local.set $tx (local.get $start_tx))
        (block $brk_x
          (loop $lp_x
            (br_if $brk_x (i32.ge_s (local.get $tx) (local.get $end_tx)))
            (local.set $sx (i32.sub (i32.mul (local.get $tx) (i32.const 8)) (local.get $cam_x)))
            (local.set $sy (i32.sub (i32.mul (local.get $ty) (i32.const 8)) (local.get $cam_y)))
            (call $draw_tile (local.get $tx) (local.get $ty) (local.get $sx) (local.get $sy))
            (local.set $tx (i32.add (local.get $tx) (i32.const 1)))
            (br $lp_x)
          )
        )
        (local.set $ty (i32.add (local.get $ty) (i32.const 1)))
        (br $lp_y)
      )
    )

    ;; Draw buildings
    (local.set $i (i32.const 0))
    (block $bbrk
      (loop $blp
        (br_if $bbrk (i32.ge_s (local.get $i) (i32.const 32)))
        (call $draw_building (local.get $i) (local.get $cam_x) (local.get $cam_y))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $blp)
      )
    )

    ;; Draw units
    (local.set $i (i32.const 0))
    (block $ubrk
      (loop $ulp
        (br_if $ubrk (i32.ge_s (local.get $i) (i32.const 64)))
        (call $draw_unit (local.get $i) (local.get $cam_x) (local.get $cam_y))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $ulp)
      )
    )

    ;; Draw UI on top
    (call $draw_ui)

    ;; Draw drag selection box if dragging
    (if (i32.load8_u (i32.const 0x1A958))
      (then
        (local.set $sx (i32.sub (i32.load16_s (i32.const 0x1A950)) (local.get $cam_x)))
        (local.set $sy (i32.sub (i32.load16_s (i32.const 0x1A952)) (local.get $cam_y)))
        ;; Current mouse screen pos
        (local.set $tx (i32.or
          (i32.load8_u (i32.const 4))
          (i32.shl (i32.load8_u (i32.const 5)) (i32.const 8))))
        (local.set $ty (i32.or
          (i32.load8_u (i32.const 6))
          (i32.shl (i32.load8_u (i32.const 7)) (i32.const 8))))
        ;; Draw box: top, bottom hlines and left, right vlines
        (local.set $start_tx (call $min (local.get $sx) (local.get $tx)))
        (local.set $start_ty (call $min (local.get $sy) (local.get $ty)))
        (local.set $end_tx (i32.add (call $abs (i32.sub (local.get $tx) (local.get $sx))) (i32.const 1)))
        (local.set $end_ty (i32.add (call $abs (i32.sub (local.get $ty) (local.get $sy))) (i32.const 1)))
        (call $hline (local.get $start_tx) (local.get $start_ty) (local.get $end_tx) (i32.const 27))
        (call $hline (local.get $start_tx) (i32.add (local.get $start_ty) (i32.sub (local.get $end_ty) (i32.const 1))) (local.get $end_tx) (i32.const 27))
        (call $vline (local.get $start_tx) (local.get $start_ty) (local.get $end_ty) (i32.const 27))
        (call $vline (i32.add (local.get $start_tx) (i32.sub (local.get $end_tx) (i32.const 1))) (local.get $start_ty) (local.get $end_ty) (i32.const 27))
      )
    )

  )
)