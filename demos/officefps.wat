(module
  (import "env" "memory" (memory 4))
  (import "env" "sfx" (func $sfx (param i32)))
  (import "env" "note" (func $note (param i32 i32 i32 i32)))

  ;; Doom-style FPS — Retrofuture Office Complex
  ;; 256-color palette: 16 ramps × 16 shades for smooth dithered lighting
  ;;
  ;; Palette layout: index = ramp*16 + shade (shade 0=black, 15=brightest)
  ;;   Ramp 0: Gray       Ramp 4: Blood Red    Ramp 8: Yellow     Ramp 12: Orange
  ;;   Ramp 1: Beige      Ramp 5: Brown        Ramp 9: Purple     Ramp 13: Cyan
  ;;   Ramp 2: Blue-Gray  Ramp 6: Fluorescent  Ramp 10: Steel     Ramp 14: Tan
  ;;   Ramp 3: Teal       Ramp 7: Crimson      Ramp 11: Green     Ramp 15: Warm White
  ;;
  ;; Lighting: light = 1/(1 + dist*K), then shade = base_shade * light
  ;; Dithering: Bayer 4×4 interpolates between floor(shade) and ceil(shade)
  ;;
  ;; CONST: 0x10340 map, 0x10440 bayer, 0x10450 ramp RGB targets, 0x10480 textures
  ;; DYNAMIC: 0x3F000 zbuf, 0x3F500 player, 0x3F520 enemies, 0x3F5A0+ state

  ;; ---- sin_approx (3-step reduction + Taylor) ----
  (func $sin_approx (param $x f64) (result f64)
    (local $x2 f64) (local $x3 f64) (local $x5 f64) (local $x7 f64)
    (local $sign f64)
    (local.set $sign (f64.const 1.0))
    (local.set $x (f64.sub (local.get $x)
      (f64.mul (f64.floor (f64.div (local.get $x) (f64.const 6.283185307179586))) (f64.const 6.283185307179586))))
    (if (f64.ge (local.get $x) (f64.const 3.141592653589793))
      (then
        (local.set $x (f64.sub (local.get $x) (f64.const 3.141592653589793)))
        (local.set $sign (f64.const -1.0))))
    (if (f64.gt (local.get $x) (f64.const 1.5707963267948966))
      (then (local.set $x (f64.sub (f64.const 3.141592653589793) (local.get $x)))))
    (local.set $x2 (f64.mul (local.get $x) (local.get $x)))
    (local.set $x3 (f64.mul (local.get $x2) (local.get $x)))
    (local.set $x5 (f64.mul (local.get $x3) (local.get $x2)))
    (local.set $x7 (f64.mul (local.get $x5) (local.get $x2)))
    (f64.mul (local.get $sign)
      (f64.sub (f64.add (local.get $x) (f64.div (local.get $x5) (f64.const 120.0)))
        (f64.add (f64.div (local.get $x3) (f64.const 6.0)) (f64.div (local.get $x7) (f64.const 5040.0)))))
  )

  (func $cos_approx (param $x f64) (result f64)
    (call $sin_approx (f64.add (local.get $x) (f64.const 1.5707963)))
  )

  (func $rand (result i32)
    (local $s i32)
    (local.set $s (i32.load (i32.const 0x3F5A0)))
    (if (i32.eqz (local.get $s)) (then (local.set $s (i32.const 987654321))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 13))))
    (local.set $s (i32.xor (local.get $s) (i32.shr_u (local.get $s) (i32.const 17))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 5))))
    (i32.store (i32.const 0x3F5A0) (local.get $s))
    (local.get $s)
  )

  ;; ---- Helpers ----
  (func $set_pal (param $idx i32) (param $r i32) (param $g i32) (param $b i32)
    (local $a i32)
    (local.set $a (i32.add (i32.const 0x0040) (i32.mul (local.get $idx) (i32.const 3))))
    (i32.store8 (local.get $a) (local.get $r))
    (i32.store8 (i32.add (local.get $a) (i32.const 1)) (local.get $g))
    (i32.store8 (i32.add (local.get $a) (i32.const 2)) (local.get $b))
  )

  (func $map_get (param $x i32) (param $y i32) (result i32)
    (if (result i32) (i32.or (i32.or (i32.lt_s (local.get $x) (i32.const 0)) (i32.ge_s (local.get $x) (i32.const 16)))
                             (i32.or (i32.lt_s (local.get $y) (i32.const 0)) (i32.ge_s (local.get $y) (i32.const 16))))
      (then (i32.const 1))
      (else (i32.load8_u (i32.add (i32.const 0x10340)
        (i32.add (i32.mul (local.get $y) (i32.const 16)) (local.get $x))))))
  )

  (func $tex_addr (param $id i32) (param $u i32) (param $v i32) (result i32)
    (i32.add (i32.const 0x10480)
      (i32.add (i32.mul (local.get $id) (i32.const 4096))
        (i32.add (i32.mul (i32.and (local.get $v) (i32.const 63)) (i32.const 64))
                 (i32.and (local.get $u) (i32.const 63)))))
  )

  (func $wall_ahead (param $px f64) (param $py f64) (param $a f64) (param $d f64) (result i32)
    (call $map_get
      (i32.trunc_f64_s (f64.add (local.get $px) (f64.mul (call $cos_approx (local.get $a)) (local.get $d))))
      (i32.trunc_f64_s (f64.add (local.get $py) (f64.mul (call $sin_approx (local.get $a)) (local.get $d)))))
  )

  (func $draw_rect (param $x i32) (param $y i32) (param $w i32) (param $h i32) (param $c i32)
    (local $r i32) (local $cc i32) (local $px i32) (local $py i32)
    (local.set $r (i32.const 0))
    (block $d (loop $l (br_if $d (i32.ge_u (local.get $r) (local.get $h)))
      (local.set $py (i32.add (local.get $y) (local.get $r)))
      (if (i32.and (i32.ge_s (local.get $py) (i32.const 0)) (i32.lt_s (local.get $py) (i32.const 200)))
        (then
          (local.set $cc (i32.const 0))
          (block $d2 (loop $l2 (br_if $d2 (i32.ge_u (local.get $cc) (local.get $w)))
            (local.set $px (i32.add (local.get $x) (local.get $cc)))
            (if (i32.and (i32.ge_s (local.get $px) (i32.const 0)) (i32.lt_s (local.get $px) (i32.const 320)))
              (then (i32.store8 (i32.add (i32.const 0x0340)
                (i32.add (i32.mul (local.get $py) (i32.const 320)) (local.get $px))) (local.get $c))))
            (local.set $cc (i32.add (local.get $cc) (i32.const 1)))
            (br $l2)))))
      (local.set $r (i32.add (local.get $r) (i32.const 1)))
      (br $l)))
  )

  ;; ---- Texture generators ----
  ;; Tex 0: Office drywall — ramp 1 (beige) with ramp 5 (brown) stains
  (func $gen_tex_drywall
    (local $u i32) (local $v i32) (local $c i32)
    (local.set $v (i32.const 0))
    (block $vd (loop $vl (br_if $vd (i32.ge_u (local.get $v) (i32.const 64)))
      (local.set $u (i32.const 0))
      (block $ud (loop $ul (br_if $ud (i32.ge_u (local.get $u) (i32.const 64)))
        ;; Base beige: ramp 1 shade 10-13
        (local.set $c (i32.add (i32.const 26) (i32.and (call $rand) (i32.const 3))))
        ;; Horizontal panel seams every 16 rows → darker
        (if (i32.eqz (i32.and (local.get $v) (i32.const 15)))
          (then (local.set $c (i32.add (i32.const 20) (i32.and (call $rand) (i32.const 1))))))
        ;; Vertical seam at col 32
        (if (i32.eq (local.get $u) (i32.const 32))
          (then (local.set $c (i32.const 21))))
        ;; Brown water stains (ramp 5)
        (if (i32.eqz (i32.and (call $rand) (i32.const 127)))
          (then (local.set $c (i32.add (i32.const 83) (i32.and (call $rand) (i32.const 3))))))
        ;; Outlet cover (ramp 10 steel, rare)
        (if (i32.and
              (i32.eqz (i32.and (call $rand) (i32.const 511)))
              (i32.and (i32.gt_u (local.get $v) (i32.const 30)) (i32.lt_u (local.get $v) (i32.const 40))))
          (then (local.set $c (i32.const 167))))
        (i32.store8 (call $tex_addr (i32.const 0) (local.get $u) (local.get $v)) (local.get $c))
        (local.set $u (i32.add (local.get $u) (i32.const 1)))
        (br $ul)))
      (local.set $v (i32.add (local.get $v) (i32.const 1)))
      (br $vl)))
  )

  ;; Tex 1: Cubicle partition — ramp 2 (blue-gray) fabric with ramp 10 (steel) frame
  (func $gen_tex_cubicle
    (local $u i32) (local $v i32) (local $c i32)
    (local.set $v (i32.const 0))
    (block $vd (loop $vl (br_if $vd (i32.ge_u (local.get $v) (i32.const 64)))
      (local.set $u (i32.const 0))
      (block $ud (loop $ul (br_if $ud (i32.ge_u (local.get $u) (i32.const 64)))
        ;; Woven fabric: alternating shades at 2px scale
        (local.set $c (i32.add (i32.const 40)
          (i32.mul (i32.xor (i32.and (i32.shr_u (local.get $u) (i32.const 1)) (i32.const 1))
                            (i32.and (i32.shr_u (local.get $v) (i32.const 1)) (i32.const 1)))
                   (i32.const 2))))
        ;; Subtle noise
        (local.set $c (i32.add (local.get $c) (i32.and (call $rand) (i32.const 1))))
        ;; Metal frame: top/bottom 3px
        (if (i32.or (i32.lt_u (local.get $v) (i32.const 3)) (i32.gt_u (local.get $v) (i32.const 60)))
          (then (local.set $c (i32.add (i32.const 166) (i32.and (call $rand) (i32.const 1))))))
        ;; Metal frame: sides 2px
        (if (i32.or (i32.lt_u (local.get $u) (i32.const 2)) (i32.gt_u (local.get $u) (i32.const 61)))
          (then (local.set $c (i32.add (i32.const 167) (i32.and (call $rand) (i32.const 1))))))
        (i32.store8 (call $tex_addr (i32.const 1) (local.get $u) (local.get $v)) (local.get $c))
        (local.set $u (i32.add (local.get $u) (i32.const 1)))
        (br $ul)))
      (local.set $v (i32.add (local.get $v) (i32.const 1)))
      (br $vl)))
  )

  ;; Tex 2: Server rack — ramp 3 (teal) with colored LEDs and ramp 13 (cyan) screens
  (func $gen_tex_server
    (local $u i32) (local $v i32) (local $c i32)
    (local.set $v (i32.const 0))
    (block $vd (loop $vl (br_if $vd (i32.ge_u (local.get $v) (i32.const 64)))
      (local.set $u (i32.const 0))
      (block $ud (loop $ul (br_if $ud (i32.ge_u (local.get $u) (i32.const 64)))
        ;; Dark panel: ramp 3 shade 4-7
        (local.set $c (i32.add (i32.const 52) (i32.and (call $rand) (i32.const 3))))
        ;; Rack unit lines every 8 rows
        (if (i32.eqz (i32.and (local.get $v) (i32.const 7)))
          (then (local.set $c (i32.const 57))))
        ;; Steel edges
        (if (i32.or (i32.eqz (local.get $u)) (i32.eq (local.get $u) (i32.const 63)))
          (then (local.set $c (i32.const 168))))
        ;; Blue screen patches (ramp 13 cyan)
        (if (i32.and
              (i32.and (i32.gt_u (local.get $u) (i32.const 20)) (i32.lt_u (local.get $u) (i32.const 44)))
              (i32.and (i32.gt_u (i32.and (local.get $v) (i32.const 31)) (i32.const 8))
                       (i32.lt_u (i32.and (local.get $v) (i32.const 31)) (i32.const 24))))
          (then (local.set $c (i32.add (i32.const 218) (i32.and (call $rand) (i32.const 3))))))
        ;; Green LEDs (ramp 11)
        (if (i32.and (i32.lt_u (local.get $u) (i32.const 8))
                     (i32.eqz (i32.and (call $rand) (i32.const 47))))
          (then (local.set $c (i32.add (i32.const 189) (i32.and (call $rand) (i32.const 1))))))
        ;; Red LEDs (ramp 7 crimson)
        (if (i32.and (i32.lt_u (local.get $u) (i32.const 8))
                     (i32.eqz (i32.and (call $rand) (i32.const 95))))
          (then (local.set $c (i32.const 126))))
        ;; Amber LEDs (ramp 8 yellow)
        (if (i32.and (i32.lt_u (local.get $u) (i32.const 8))
                     (i32.eqz (i32.and (call $rand) (i32.const 127))))
          (then (local.set $c (i32.const 141))))
        (i32.store8 (call $tex_addr (i32.const 2) (local.get $u) (local.get $v)) (local.get $c))
        (local.set $u (i32.add (local.get $u) (i32.const 1)))
        (br $ul)))
      (local.set $v (i32.add (local.get $v) (i32.const 1)))
      (br $vl)))
  )

  ;; Tex 3: Demon flesh — ramp 4 (red) with ramp 9 (purple) veins, ramp 12 (orange) pustules
  (func $gen_tex_demon
    (local $u i32) (local $v i32) (local $c i32)
    (local.set $v (i32.const 0))
    (block $vd (loop $vl (br_if $vd (i32.ge_u (local.get $v) (i32.const 64)))
      (local.set $u (i32.const 0))
      (block $ud (loop $ul (br_if $ud (i32.ge_u (local.get $u) (i32.const 64)))
        ;; Flesh: ramp 4 shade 6-11
        (local.set $c (i32.add (i32.const 70) (i32.rem_u (i32.and (call $rand) (i32.const 0x7FFFFFFF)) (i32.const 6))))
        ;; Purple veins (ramp 9) along diagonals
        (if (i32.lt_u (i32.rem_u (i32.add (local.get $u) (local.get $v)) (i32.const 11)) (i32.const 2))
          (then (local.set $c (i32.add (i32.const 149) (i32.and (call $rand) (i32.const 3))))))
        ;; Orange pustules (ramp 12)
        (if (i32.eqz (i32.and (call $rand) (i32.const 79)))
          (then (local.set $c (i32.add (i32.const 203) (i32.and (call $rand) (i32.const 1))))))
        ;; Yellow eye (ramp 8) at center
        (if (i32.and
              (i32.and (i32.gt_u (local.get $u) (i32.const 26)) (i32.lt_u (local.get $u) (i32.const 38)))
              (i32.and (i32.gt_u (local.get $v) (i32.const 26)) (i32.lt_u (local.get $v) (i32.const 38))))
          (then (local.set $c (i32.const 142))))
        (i32.store8 (call $tex_addr (i32.const 3) (local.get $u) (local.get $v)) (local.get $c))
        (local.set $u (i32.add (local.get $u) (i32.const 1)))
        (br $ul)))
      (local.set $v (i32.add (local.get $v) (i32.const 1)))
      (br $vl)))
  )

  ;; ---- Init ----
  (func (export "init")
    (local $ramp i32) (local $shade i32) (local $idx i32)
    (local $tr i32) (local $tg i32) (local $tb i32) (local $base i32)

    ;; Generate 256-color palette from 16 ramp targets (at 0x10450, 48 bytes)
    ;; Each ramp: 16 shades from black (shade 0) to target color (shade 15)
    (local.set $ramp (i32.const 0))
    (block $rd (loop $rl (br_if $rd (i32.ge_u (local.get $ramp) (i32.const 16)))
      (local.set $base (i32.add (i32.const 0x10450) (i32.mul (local.get $ramp) (i32.const 3))))
      (local.set $tr (i32.load8_u (local.get $base)))
      (local.set $tg (i32.load8_u (i32.add (local.get $base) (i32.const 1))))
      (local.set $tb (i32.load8_u (i32.add (local.get $base) (i32.const 2))))
      (local.set $shade (i32.const 0))
      (block $sd (loop $sl (br_if $sd (i32.ge_u (local.get $shade) (i32.const 16)))
        (call $set_pal
          (i32.add (i32.shl (local.get $ramp) (i32.const 4)) (local.get $shade))
          (i32.div_u (i32.mul (local.get $tr) (local.get $shade)) (i32.const 15))
          (i32.div_u (i32.mul (local.get $tg) (local.get $shade)) (i32.const 15))
          (i32.div_u (i32.mul (local.get $tb) (local.get $shade)) (i32.const 15)))
        (local.set $shade (i32.add (local.get $shade) (i32.const 1)))
        (br $sl)))
      (local.set $ramp (i32.add (local.get $ramp) (i32.const 1)))
      (br $rl)))

    ;; Generate textures
    (call $gen_tex_drywall)
    (call $gen_tex_cubicle)
    (call $gen_tex_server)
    (call $gen_tex_demon)

    ;; Player: (2.5, 8.5) facing east
    (f32.store (i32.const 0x3F500) (f32.const 2.5))
    (f32.store (i32.const 0x3F504) (f32.const 8.5))
    (f32.store (i32.const 0x3F508) (f32.const 0.0))
    (i32.store (i32.const 0x3F50C) (i32.const 100))

    ;; 8 enemies: x(f32) y(f32) hp(i32) active(i32) — 16 bytes each at 0x3F520
    (f32.store (i32.const 0x3F520) (f32.const 3.5))  (f32.store (i32.const 0x3F524) (f32.const 1.5))
    (i32.store (i32.const 0x3F528) (i32.const 3))     (i32.store (i32.const 0x3F52C) (i32.const 1))
    (f32.store (i32.const 0x3F530) (f32.const 6.5))  (f32.store (i32.const 0x3F534) (f32.const 3.5))
    (i32.store (i32.const 0x3F538) (i32.const 3))     (i32.store (i32.const 0x3F53C) (i32.const 1))
    (f32.store (i32.const 0x3F540) (f32.const 10.5)) (f32.store (i32.const 0x3F544) (f32.const 5.5))
    (i32.store (i32.const 0x3F548) (i32.const 3))     (i32.store (i32.const 0x3F54C) (i32.const 1))
    (f32.store (i32.const 0x3F550) (f32.const 1.5))  (f32.store (i32.const 0x3F554) (f32.const 7.5))
    (i32.store (i32.const 0x3F558) (i32.const 3))     (i32.store (i32.const 0x3F55C) (i32.const 1))
    (f32.store (i32.const 0x3F560) (f32.const 13.5)) (f32.store (i32.const 0x3F564) (f32.const 7.5))
    (i32.store (i32.const 0x3F568) (i32.const 3))     (i32.store (i32.const 0x3F56C) (i32.const 1))
    (f32.store (i32.const 0x3F570) (f32.const 10.5)) (f32.store (i32.const 0x3F574) (f32.const 10.5))
    (i32.store (i32.const 0x3F578) (i32.const 3))     (i32.store (i32.const 0x3F57C) (i32.const 1))
    (f32.store (i32.const 0x3F580) (f32.const 12.5)) (f32.store (i32.const 0x3F584) (f32.const 11.5))
    (i32.store (i32.const 0x3F588) (i32.const 3))     (i32.store (i32.const 0x3F58C) (i32.const 1))
    (f32.store (i32.const 0x3F590) (f32.const 3.5))  (f32.store (i32.const 0x3F594) (f32.const 13.5))
    (i32.store (i32.const 0x3F598) (i32.const 3))     (i32.store (i32.const 0x3F59C) (i32.const 1))

    ;; Autopilot on, turn_dir = 1
    (i32.store (i32.const 0x3F5A8) (i32.const 1))
    (i32.store (i32.const 0x3F5B0) (i32.const 1))
  )

  ;; ---- Shooting hitscan ----
  (func $try_shoot (param $px f64) (param $py f64) (param $pa f64)
    (local $ei i32) (local $addr i32)
    (local $ex f64) (local $ey f64) (local $edx f64) (local $edy f64)
    (local $etx f64) (local $etz f64)
    (local $best_ei i32) (local $best_dist f64)
    (local $cos_a f64) (local $sin_a f64)
    (local.set $cos_a (call $cos_approx (local.get $pa)))
    (local.set $sin_a (call $sin_approx (local.get $pa)))
    (local.set $best_ei (i32.const -1))
    (local.set $best_dist (f64.const 100.0))
    (local.set $ei (i32.const 0))
    (block $sd (loop $sl (br_if $sd (i32.ge_u (local.get $ei) (i32.const 8)))
      (local.set $addr (i32.add (i32.const 0x3F520) (i32.mul (local.get $ei) (i32.const 16))))
      (if (i32.load (i32.add (local.get $addr) (i32.const 12)))
        (then
          (local.set $ex (f64.promote_f32 (f32.load (local.get $addr))))
          (local.set $ey (f64.promote_f32 (f32.load (i32.add (local.get $addr) (i32.const 4)))))
          (local.set $edx (f64.sub (local.get $ex) (local.get $px)))
          (local.set $edy (f64.sub (local.get $ey) (local.get $py)))
          (local.set $etx (f64.add (f64.mul (local.get $edx) (local.get $cos_a))
                                    (f64.mul (local.get $edy) (local.get $sin_a))))
          (local.set $etz (f64.sub (f64.mul (local.get $edy) (local.get $cos_a))
                                    (f64.mul (local.get $edx) (local.get $sin_a))))
          (if (f64.gt (local.get $etx) (f64.const 0.2))
            (then
              (if (f64.lt (f64.abs (f64.div (local.get $etz) (local.get $etx))) (f64.const 0.15))
                (then
                  (if (f64.lt (local.get $etx)
                        (f64.promote_f32 (f32.load (i32.add (i32.const 0x3F000) (i32.mul (i32.const 160) (i32.const 4))))))
                    (then
                      (if (f64.lt (local.get $etx) (local.get $best_dist))
                        (then
                          (local.set $best_dist (local.get $etx))
                          (local.set $best_ei (local.get $ei))))))))))))
      (local.set $ei (i32.add (local.get $ei) (i32.const 1)))
      (br $sl)))
    (if (i32.ge_s (local.get $best_ei) (i32.const 0))
      (then
        (local.set $addr (i32.add (i32.const 0x3F520) (i32.mul (local.get $best_ei) (i32.const 16))))
        (i32.store (i32.add (local.get $addr) (i32.const 8))
          (i32.sub (i32.load (i32.add (local.get $addr) (i32.const 8))) (i32.const 1)))
        (if (i32.le_s (i32.load (i32.add (local.get $addr) (i32.const 8))) (i32.const 0))
          (then
            (i32.store (i32.add (local.get $addr) (i32.const 12)) (i32.const 0))
            (i32.store (i32.const 0x3F5BC) (i32.add (i32.load (i32.const 0x3F5BC)) (i32.const 1)))
            (call $note (i32.const 0) (i32.const 100) (i32.const 200) (i32.const 200)))
          (else
            (call $note (i32.const 3) (i32.const 200) (i32.const 50) (i32.const 150))))))
  )

  ;; ---- Frame ----
  (func (export "frame")
    (local $px f64) (local $py f64) (local $pa f64)
    (local $keys i32) (local $mouse_x i32) (local $prev_mouse_x i32)
    (local $cos_a f64) (local $sin_a f64)
    (local $move_dx f64) (local $move_dy f64)
    (local $new_px f64) (local $new_py f64)
    (local $col i32) (local $row i32)
    (local $ray_angle f64) (local $ray_dx f64) (local $ray_dy f64)
    (local $map_x i32) (local $map_y i32)
    (local $delta_dist_x f64) (local $delta_dist_y f64)
    (local $side_dist_x f64) (local $side_dist_y f64)
    (local $step_x i32) (local $step_y i32)
    (local $hit i32) (local $side i32) (local $dda_steps i32)
    (local $wall_type i32)
    (local $perp_dist f64)
    (local $wall_h i32) (local $draw_start i32) (local $draw_end i32)
    (local $wall_x f64) (local $tex_u i32) (local $tex_v i32) (local $tex_id i32)
    (local $tex_color i32)
    (local $light f64) (local $lit f64)
    (local $ramp i32) (local $base_shade i32)
    (local $shade_lo i32) (local $frac i32) (local $bayer i32) (local $final_shade i32)
    (local $pixel i32) (local $fdist f64) (local $fhalf f64)
    (local $ei i32) (local $ex f64) (local $ey f64)
    (local $edx f64) (local $edy f64) (local $etx f64) (local $etz f64)
    (local $escr_x i32) (local $eheight i32) (local $ewidth i32)
    (local $ecol i32) (local $erow i32)
    (local $ecol_start i32) (local $ecol_end i32)
    (local $erow_start i32) (local $erow_end i32)
    (local $ecolor i32) (local $edist f64)
    (local $bob i32) (local $wep_y i32)
    (local $input i32) (local $prev_input i32) (local $new_press i32)
    (local $addr i32)

    ;; Load player
    (local.set $px (f64.promote_f32 (f32.load (i32.const 0x3F500))))
    (local.set $py (f64.promote_f32 (f32.load (i32.const 0x3F504))))
    (local.set $pa (f64.promote_f32 (f32.load (i32.const 0x3F508))))

    ;; Input
    (local.set $keys (i32.load8_u (i32.const 0x10)))
    (local.set $mouse_x (i32.load16_u (i32.const 0x04)))
    (local.set $prev_mouse_x (i32.load (i32.const 0x3F5AC)))

    ;; Rising edge
    (local.set $input (i32.or
      (i32.and (local.get $keys) (i32.const 0x3F))
      (i32.shl (i32.and (i32.load8_u (i32.const 0x08)) (i32.const 1)) (i32.const 6))))
    (local.set $prev_input (i32.load (i32.const 0x3F5C0)))
    (local.set $new_press (i32.and (local.get $input) (i32.xor (local.get $prev_input) (i32.const 0xFFFFFFFF))))
    (i32.store (i32.const 0x3F5C0) (local.get $input))

    ;; Autopilot detection
    (if (i32.or (local.get $keys)
          (i32.and (i32.ne (local.get $prev_mouse_x) (i32.const 0))
                   (i32.ne (local.get $mouse_x) (local.get $prev_mouse_x))))
      (then
        (i32.store (i32.const 0x3F5A4) (i32.const 0))
        (i32.store (i32.const 0x3F5A8) (i32.const 0)))
      (else
        (i32.store (i32.const 0x3F5A4) (i32.add (i32.load (i32.const 0x3F5A4)) (i32.const 1)))
        (if (i32.ge_u (i32.load (i32.const 0x3F5A4)) (i32.const 60))
          (then (i32.store (i32.const 0x3F5A8) (i32.const 1))))))
    (i32.store (i32.const 0x3F5AC) (local.get $mouse_x))

    (local.set $cos_a (call $cos_approx (local.get $pa)))
    (local.set $sin_a (call $sin_approx (local.get $pa)))
    (local.set $move_dx (f64.const 0.0))
    (local.set $move_dy (f64.const 0.0))

    (if (i32.load (i32.const 0x3F5A8))
      (then
        ;; AUTOPILOT
        (local.set $move_dx (f64.mul (local.get $cos_a) (f64.const 0.04)))
        (local.set $move_dy (f64.mul (local.get $sin_a) (f64.const 0.04)))
        (if (call $wall_ahead (local.get $px) (local.get $py) (local.get $pa) (f64.const 1.0))
          (then
            (local.set $move_dx (f64.const 0.0))
            (local.set $move_dy (f64.const 0.0))
            (if (call $wall_ahead (local.get $px) (local.get $py)
                  (f64.add (local.get $pa) (f64.mul (f64.convert_i32_s (i32.load (i32.const 0x3F5B0))) (f64.const 1.57)))
                  (f64.const 1.0))
              (then (i32.store (i32.const 0x3F5B0) (i32.sub (i32.const 0) (i32.load (i32.const 0x3F5B0))))))
            (local.set $pa (f64.add (local.get $pa)
              (f64.mul (f64.convert_i32_s (i32.load (i32.const 0x3F5B0))) (f64.const 0.05)))))
          (else
            (if (i32.eqz (i32.rem_u (i32.and (call $rand) (i32.const 0x7FFFFFFF)) (i32.const 90)))
              (then (i32.store (i32.const 0x3F5B0) (i32.sub (i32.const 0) (i32.load (i32.const 0x3F5B0))))))
            (local.set $pa (f64.add (local.get $pa)
              (f64.mul (f64.convert_i32_s (i32.load (i32.const 0x3F5B0))) (f64.const 0.003))))))
        (local.set $cos_a (call $cos_approx (local.get $pa)))
        (local.set $sin_a (call $sin_approx (local.get $pa)))
        ;; Auto-shoot
        (if (i32.eqz (i32.and (i32.load (i32.const 0x00)) (i32.const 31)))
          (then (if (i32.eqz (i32.load (i32.const 0x3F5B4)))
            (then
              (i32.store (i32.const 0x3F5B4) (i32.const 12))
              (i32.store (i32.const 0x3F5B8) (i32.const 6))
              (call $note (i32.const 1) (i32.const 440) (i32.const 50) (i32.const 150))
              (call $try_shoot (local.get $px) (local.get $py) (local.get $pa)))))))
      (else
        ;; MANUAL
        (if (i32.and (local.get $keys) (i32.const 4))
          (then (local.set $pa (f64.sub (local.get $pa) (f64.const 0.04)))))
        (if (i32.and (local.get $keys) (i32.const 8))
          (then (local.set $pa (f64.add (local.get $pa) (f64.const 0.04)))))
        (if (local.get $prev_mouse_x)
          (then (local.set $pa (f64.add (local.get $pa)
            (f64.mul (f64.convert_i32_s (i32.sub (local.get $mouse_x) (local.get $prev_mouse_x)))
                     (f64.const 0.01))))))
        (local.set $cos_a (call $cos_approx (local.get $pa)))
        (local.set $sin_a (call $sin_approx (local.get $pa)))
        (if (i32.and (local.get $keys) (i32.const 1))
          (then
            (local.set $move_dx (f64.add (local.get $move_dx) (f64.mul (local.get $cos_a) (f64.const 0.06))))
            (local.set $move_dy (f64.add (local.get $move_dy) (f64.mul (local.get $sin_a) (f64.const 0.06))))))
        (if (i32.and (local.get $keys) (i32.const 2))
          (then
            (local.set $move_dx (f64.sub (local.get $move_dx) (f64.mul (local.get $cos_a) (f64.const 0.06))))
            (local.set $move_dy (f64.sub (local.get $move_dy) (f64.mul (local.get $sin_a) (f64.const 0.06))))))
        (if (i32.and (local.get $new_press) (i32.const 0x50))
          (then (if (i32.eqz (i32.load (i32.const 0x3F5B4)))
            (then
              (i32.store (i32.const 0x3F5B4) (i32.const 12))
              (i32.store (i32.const 0x3F5B8) (i32.const 6))
              (call $note (i32.const 1) (i32.const 440) (i32.const 50) (i32.const 180))
              (call $try_shoot (local.get $px) (local.get $py) (local.get $pa))))))))

    ;; Collision
    (local.set $new_px (f64.add (local.get $px) (local.get $move_dx)))
    (if (i32.eqz (call $map_get
          (i32.trunc_f64_s (f64.add (local.get $new_px) (select (f64.const 0.2) (f64.const -0.2) (f64.gt (local.get $move_dx) (f64.const 0.0)))))
          (i32.trunc_f64_s (local.get $py))))
      (then (local.set $px (local.get $new_px))))
    (local.set $new_py (f64.add (local.get $py) (local.get $move_dy)))
    (if (i32.eqz (call $map_get
          (i32.trunc_f64_s (local.get $px))
          (i32.trunc_f64_s (f64.add (local.get $new_py) (select (f64.const 0.2) (f64.const -0.2) (f64.gt (local.get $move_dy) (f64.const 0.0)))))))
      (then (local.set $py (local.get $new_py))))

    (f32.store (i32.const 0x3F500) (f32.demote_f64 (local.get $px)))
    (f32.store (i32.const 0x3F504) (f32.demote_f64 (local.get $py)))
    (f32.store (i32.const 0x3F508) (f32.demote_f64 (local.get $pa)))

    ;; Cooldowns
    (if (i32.gt_s (i32.load (i32.const 0x3F5B4)) (i32.const 0))
      (then (i32.store (i32.const 0x3F5B4) (i32.sub (i32.load (i32.const 0x3F5B4)) (i32.const 1)))))
    (if (i32.gt_s (i32.load (i32.const 0x3F5B8)) (i32.const 0))
      (then (i32.store (i32.const 0x3F5B8) (i32.sub (i32.load (i32.const 0x3F5B8)) (i32.const 1)))))
    (if (i32.gt_s (i32.load (i32.const 0x3F5C4)) (i32.const 0))
      (then (i32.store (i32.const 0x3F5C4) (i32.sub (i32.load (i32.const 0x3F5C4)) (i32.const 1)))))

    ;; === Update enemies ===
    (local.set $ei (i32.const 0))
    (block $edone (loop $elp (br_if $edone (i32.ge_u (local.get $ei) (i32.const 8)))
      (local.set $addr (i32.add (i32.const 0x3F520) (i32.mul (local.get $ei) (i32.const 16))))
      (if (i32.load (i32.add (local.get $addr) (i32.const 12)))
        (then
          (local.set $ex (f64.promote_f32 (f32.load (local.get $addr))))
          (local.set $ey (f64.promote_f32 (f32.load (i32.add (local.get $addr) (i32.const 4)))))
          (local.set $edx (f64.sub (local.get $px) (local.get $ex)))
          (local.set $edy (f64.sub (local.get $py) (local.get $ey)))
          (local.set $edist (f64.sqrt (f64.add (f64.mul (local.get $edx) (local.get $edx))
                                                (f64.mul (local.get $edy) (local.get $edy)))))
          (if (f64.gt (local.get $edist) (f64.const 0.5))
            (then
              (local.set $edx (f64.div (local.get $edx) (local.get $edist)))
              (local.set $edy (f64.div (local.get $edy) (local.get $edist)))
              (local.set $new_px (f64.add (local.get $ex) (f64.mul (local.get $edx) (f64.const 0.012))))
              (local.set $new_py (f64.add (local.get $ey) (f64.mul (local.get $edy) (f64.const 0.012))))
              (if (i32.eqz (call $map_get (i32.trunc_f64_s (local.get $new_px)) (i32.trunc_f64_s (local.get $ey))))
                (then (f32.store (local.get $addr) (f32.demote_f64 (local.get $new_px)))))
              (if (i32.eqz (call $map_get (i32.trunc_f64_s (local.get $ex)) (i32.trunc_f64_s (local.get $new_py))))
                (then (f32.store (i32.add (local.get $addr) (i32.const 4)) (f32.demote_f64 (local.get $new_py)))))))
          (if (i32.and (f64.lt (local.get $edist) (f64.const 0.8))
                       (i32.gt_s (i32.load (i32.const 0x3F50C)) (i32.const 0)))
            (then (if (i32.eqz (i32.load (i32.const 0x3F5C4)))
              (then
                (i32.store (i32.const 0x3F50C) (i32.sub (i32.load (i32.const 0x3F50C)) (i32.const 10)))
                (i32.store (i32.const 0x3F5C4) (i32.const 15))
                (call $note (i32.const 0) (i32.const 80) (i32.const 200) (i32.const 200))
                (f32.store (local.get $addr) (f32.demote_f64
                  (f64.sub (local.get $ex) (f64.mul (local.get $edx) (f64.const 1.0)))))
                (f32.store (i32.add (local.get $addr) (i32.const 4)) (f32.demote_f64
                  (f64.sub (local.get $ey) (f64.mul (local.get $edy) (f64.const 1.0)))))))))))
      (local.set $ei (i32.add (local.get $ei) (i32.const 1)))
      (br $elp)))

    ;; ===== RAYCASTING with dithered ramp lighting =====
    (local.set $col (i32.const 0))
    (block $rdone (loop $rlp (br_if $rdone (i32.ge_u (local.get $col) (i32.const 320)))

      ;; --- Ray setup ---
      (local.set $ray_angle (f64.add (local.get $pa)
        (f64.mul (f64.sub (f64.convert_i32_s (local.get $col)) (f64.const 160.0))
                 (f64.div (f64.const 1.047) (f64.const 320.0)))))
      (local.set $ray_dx (call $cos_approx (local.get $ray_angle)))
      (local.set $ray_dy (call $sin_approx (local.get $ray_angle)))
      (local.set $map_x (i32.trunc_f64_s (local.get $px)))
      (local.set $map_y (i32.trunc_f64_s (local.get $py)))

      (local.set $delta_dist_x
        (if (result f64) (f64.eq (local.get $ray_dx) (f64.const 0.0))
          (then (f64.const 1000000.0))
          (else (f64.abs (f64.div (f64.const 1.0) (local.get $ray_dx))))))
      (local.set $delta_dist_y
        (if (result f64) (f64.eq (local.get $ray_dy) (f64.const 0.0))
          (then (f64.const 1000000.0))
          (else (f64.abs (f64.div (f64.const 1.0) (local.get $ray_dy))))))

      (if (f64.lt (local.get $ray_dx) (f64.const 0.0))
        (then
          (local.set $step_x (i32.const -1))
          (local.set $side_dist_x (f64.mul
            (f64.sub (local.get $px) (f64.convert_i32_s (local.get $map_x)))
            (local.get $delta_dist_x))))
        (else
          (local.set $step_x (i32.const 1))
          (local.set $side_dist_x (f64.mul
            (f64.sub (f64.add (f64.convert_i32_s (local.get $map_x)) (f64.const 1.0)) (local.get $px))
            (local.get $delta_dist_x)))))
      (if (f64.lt (local.get $ray_dy) (f64.const 0.0))
        (then
          (local.set $step_y (i32.const -1))
          (local.set $side_dist_y (f64.mul
            (f64.sub (local.get $py) (f64.convert_i32_s (local.get $map_y)))
            (local.get $delta_dist_y))))
        (else
          (local.set $step_y (i32.const 1))
          (local.set $side_dist_y (f64.mul
            (f64.sub (f64.add (f64.convert_i32_s (local.get $map_y)) (f64.const 1.0)) (local.get $py))
            (local.get $delta_dist_y)))))

      ;; --- DDA ---
      (local.set $hit (i32.const 0))
      (local.set $side (i32.const 0))
      (local.set $dda_steps (i32.const 0))
      (block $hd (loop $hl
        (br_if $hd (i32.or (local.get $hit) (i32.ge_u (local.get $dda_steps) (i32.const 64))))
        (if (f64.lt (local.get $side_dist_x) (local.get $side_dist_y))
          (then
            (local.set $side_dist_x (f64.add (local.get $side_dist_x) (local.get $delta_dist_x)))
            (local.set $map_x (i32.add (local.get $map_x) (local.get $step_x)))
            (local.set $side (i32.const 0)))
          (else
            (local.set $side_dist_y (f64.add (local.get $side_dist_y) (local.get $delta_dist_y)))
            (local.set $map_y (i32.add (local.get $map_y) (local.get $step_y)))
            (local.set $side (i32.const 1))))
        (local.set $wall_type (call $map_get (local.get $map_x) (local.get $map_y)))
        (if (i32.gt_u (local.get $wall_type) (i32.const 0))
          (then (local.set $hit (i32.const 1))))
        (local.set $dda_steps (i32.add (local.get $dda_steps) (i32.const 1)))
        (br $hl)))

      ;; Perpendicular distance
      (if (i32.eqz (local.get $side))
        (then (local.set $perp_dist (f64.sub (local.get $side_dist_x) (local.get $delta_dist_x))))
        (else (local.set $perp_dist (f64.sub (local.get $side_dist_y) (local.get $delta_dist_y)))))
      (if (f64.lt (local.get $perp_dist) (f64.const 0.001))
        (then (local.set $perp_dist (f64.const 0.001))))

      ;; Z-buffer
      (f32.store (i32.add (i32.const 0x3F000) (i32.mul (local.get $col) (i32.const 4)))
        (f32.demote_f64 (local.get $perp_dist)))

      ;; Wall geometry
      (local.set $wall_h (i32.trunc_f64_s (f64.div (f64.const 200.0) (local.get $perp_dist))))
      (if (i32.gt_s (local.get $wall_h) (i32.const 400))
        (then (local.set $wall_h (i32.const 400))))
      (local.set $draw_start (i32.sub (i32.const 100) (i32.shr_u (local.get $wall_h) (i32.const 1))))
      (local.set $draw_end (i32.add (i32.const 100) (i32.shr_u (local.get $wall_h) (i32.const 1))))

      ;; Texture U
      (if (i32.eqz (local.get $side))
        (then (local.set $wall_x (f64.add (local.get $py) (f64.mul (local.get $perp_dist) (local.get $ray_dy)))))
        (else (local.set $wall_x (f64.add (local.get $px) (f64.mul (local.get $perp_dist) (local.get $ray_dx))))))
      (local.set $wall_x (f64.sub (local.get $wall_x) (f64.floor (local.get $wall_x))))
      (local.set $tex_u (i32.and (i32.trunc_f64_s (f64.mul (local.get $wall_x) (f64.const 64.0))) (i32.const 63)))
      (local.set $tex_id (i32.sub (local.get $wall_type) (i32.const 1)))
      (if (i32.lt_s (local.get $tex_id) (i32.const 0)) (then (local.set $tex_id (i32.const 0))))
      (if (i32.gt_s (local.get $tex_id) (i32.const 3)) (then (local.set $tex_id (i32.const 3))))

      ;; === Wall light factor: 1/(1+dist*0.25), side darkening ===
      (local.set $light (f64.div (f64.const 1.0)
        (f64.add (f64.const 1.0) (f64.mul (local.get $perp_dist) (f64.const 0.25)))))
      (if (local.get $side)
        (then (local.set $light (f64.mul (local.get $light) (f64.const 0.7)))))
      (if (f64.lt (local.get $light) (f64.const 0.05))
        (then (local.set $light (f64.const 0.05))))

      ;; --- Draw ceiling: ramp 6 (fluorescent), base shade 14 ---
      (local.set $row (i32.const 0))
      (block $cd (loop $cl
        (br_if $cd (i32.or (i32.ge_s (local.get $row) (local.get $draw_start))
                           (i32.ge_s (local.get $row) (i32.const 200))))
        ;; Ceiling distance from vertical perspective
        (local.set $fhalf (f64.convert_i32_s (i32.sub (i32.const 100) (local.get $row))))
        (if (f64.lt (local.get $fhalf) (f64.const 1.0)) (then (local.set $fhalf (f64.const 1.0))))
        (local.set $fdist (f64.div (f64.const 50.0) (local.get $fhalf)))
        (local.set $lit (f64.mul (f64.const 14.0)
          (f64.div (f64.const 1.0) (f64.add (f64.const 1.0) (f64.mul (local.get $fdist) (f64.const 0.15))))))
        ;; Dither: shade_lo, frac, bayer
        (local.set $shade_lo (i32.trunc_f64_s (local.get $lit)))
        (if (i32.lt_s (local.get $shade_lo) (i32.const 0)) (then (local.set $shade_lo (i32.const 0))))
        (if (i32.gt_s (local.get $shade_lo) (i32.const 14)) (then (local.set $shade_lo (i32.const 14))))
        (local.set $frac (i32.trunc_f64_s (f64.mul
          (f64.sub (local.get $lit) (f64.convert_i32_s (local.get $shade_lo))) (f64.const 16.0))))
        (local.set $bayer (i32.load8_u (i32.add (i32.const 0x10440)
          (i32.add (i32.mul (i32.and (local.get $row) (i32.const 3)) (i32.const 4))
                   (i32.and (local.get $col) (i32.const 3))))))
        (local.set $final_shade (select
          (i32.add (local.get $shade_lo) (i32.const 1)) (local.get $shade_lo)
          (i32.gt_s (local.get $frac) (local.get $bayer))))
        (if (i32.gt_s (local.get $final_shade) (i32.const 15))
          (then (local.set $final_shade (i32.const 15))))
        ;; Pixel = ramp 6 * 16 + shade = 96 + shade
        (i32.store8 (i32.add (i32.const 0x0340)
          (i32.add (i32.mul (local.get $row) (i32.const 320)) (local.get $col)))
          (i32.add (i32.const 96) (local.get $final_shade)))
        (local.set $row (i32.add (local.get $row) (i32.const 1)))
        (br $cl)))

      ;; --- Draw wall with dithered ramp lighting ---
      (local.set $row (select (local.get $draw_start) (i32.const 0) (i32.ge_s (local.get $draw_start) (i32.const 0))))
      (block $wd (loop $wl
        (br_if $wd (i32.or (i32.ge_s (local.get $row) (local.get $draw_end))
                           (i32.ge_s (local.get $row) (i32.const 200))))
        ;; Texture sample
        (local.set $tex_v (i32.and
          (i32.div_s (i32.mul (i32.sub (local.get $row) (local.get $draw_start)) (i32.const 64))
                     (local.get $wall_h))
          (i32.const 63)))
        (local.set $tex_color (i32.load8_u (call $tex_addr (local.get $tex_id) (local.get $tex_u) (local.get $tex_v))))
        ;; Extract ramp and base shade
        (local.set $ramp (i32.shr_u (local.get $tex_color) (i32.const 4)))
        (local.set $base_shade (i32.and (local.get $tex_color) (i32.const 15)))
        ;; Apply lighting: lit = base_shade * light
        (local.set $lit (f64.mul (f64.convert_i32_u (local.get $base_shade)) (local.get $light)))
        ;; Dither between shade levels
        (local.set $shade_lo (i32.trunc_f64_s (local.get $lit)))
        (if (i32.lt_s (local.get $shade_lo) (i32.const 0)) (then (local.set $shade_lo (i32.const 0))))
        (if (i32.gt_s (local.get $shade_lo) (i32.const 14)) (then (local.set $shade_lo (i32.const 14))))
        (local.set $frac (i32.trunc_f64_s (f64.mul
          (f64.sub (local.get $lit) (f64.convert_i32_s (local.get $shade_lo))) (f64.const 16.0))))
        (local.set $bayer (i32.load8_u (i32.add (i32.const 0x10440)
          (i32.add (i32.mul (i32.and (local.get $row) (i32.const 3)) (i32.const 4))
                   (i32.and (local.get $col) (i32.const 3))))))
        (local.set $final_shade (select
          (i32.add (local.get $shade_lo) (i32.const 1)) (local.get $shade_lo)
          (i32.gt_s (local.get $frac) (local.get $bayer))))
        (if (i32.gt_s (local.get $final_shade) (i32.const 15))
          (then (local.set $final_shade (i32.const 15))))
        ;; Final pixel: ramp * 16 + shade
        (i32.store8 (i32.add (i32.const 0x0340)
          (i32.add (i32.mul (local.get $row) (i32.const 320)) (local.get $col)))
          (i32.add (i32.shl (local.get $ramp) (i32.const 4)) (local.get $final_shade)))
        (local.set $row (i32.add (local.get $row) (i32.const 1)))
        (br $wl)))

      ;; --- Draw floor: ramp 5 (brown), base shade 10 ---
      (local.set $row (select (local.get $draw_end) (i32.const 0) (i32.ge_s (local.get $draw_end) (i32.const 0))))
      (block $fd (loop $fl (br_if $fd (i32.ge_s (local.get $row) (i32.const 200)))
        (local.set $fhalf (f64.convert_i32_s (i32.sub (local.get $row) (i32.const 99))))
        (if (f64.lt (local.get $fhalf) (f64.const 1.0)) (then (local.set $fhalf (f64.const 1.0))))
        (local.set $fdist (f64.div (f64.const 50.0) (local.get $fhalf)))
        (local.set $lit (f64.mul (f64.const 10.0)
          (f64.div (f64.const 1.0) (f64.add (f64.const 1.0) (f64.mul (local.get $fdist) (f64.const 0.25))))))
        ;; Dither
        (local.set $shade_lo (i32.trunc_f64_s (local.get $lit)))
        (if (i32.lt_s (local.get $shade_lo) (i32.const 0)) (then (local.set $shade_lo (i32.const 0))))
        (if (i32.gt_s (local.get $shade_lo) (i32.const 14)) (then (local.set $shade_lo (i32.const 14))))
        (local.set $frac (i32.trunc_f64_s (f64.mul
          (f64.sub (local.get $lit) (f64.convert_i32_s (local.get $shade_lo))) (f64.const 16.0))))
        (local.set $bayer (i32.load8_u (i32.add (i32.const 0x10440)
          (i32.add (i32.mul (i32.and (local.get $row) (i32.const 3)) (i32.const 4))
                   (i32.and (local.get $col) (i32.const 3))))))
        (local.set $final_shade (select
          (i32.add (local.get $shade_lo) (i32.const 1)) (local.get $shade_lo)
          (i32.gt_s (local.get $frac) (local.get $bayer))))
        (if (i32.gt_s (local.get $final_shade) (i32.const 15))
          (then (local.set $final_shade (i32.const 15))))
        ;; Pixel = ramp 5 * 16 + shade = 80 + shade
        (i32.store8 (i32.add (i32.const 0x0340)
          (i32.add (i32.mul (local.get $row) (i32.const 320)) (local.get $col)))
          (i32.add (i32.const 80) (local.get $final_shade)))
        (local.set $row (i32.add (local.get $row) (i32.const 1)))
        (br $fl)))

      (local.set $col (i32.add (local.get $col) (i32.const 1)))
      (br $rlp)))

    ;; === ENEMY RENDERING with dithered lighting ===
    (local.set $ei (i32.const 0))
    (block $erdone (loop $erlp (br_if $erdone (i32.ge_u (local.get $ei) (i32.const 8)))
      (local.set $addr (i32.add (i32.const 0x3F520) (i32.mul (local.get $ei) (i32.const 16))))
      (if (i32.load (i32.add (local.get $addr) (i32.const 12)))
        (then
          (local.set $ex (f64.promote_f32 (f32.load (local.get $addr))))
          (local.set $ey (f64.promote_f32 (f32.load (i32.add (local.get $addr) (i32.const 4)))))
          (local.set $edx (f64.sub (local.get $ex) (local.get $px)))
          (local.set $edy (f64.sub (local.get $ey) (local.get $py)))
          ;; View-space transform
          (local.set $etx (f64.add (f64.mul (local.get $edx) (local.get $cos_a))
                                    (f64.mul (local.get $edy) (local.get $sin_a))))
          (local.set $etz (f64.sub (f64.mul (local.get $edy) (local.get $cos_a))
                                    (f64.mul (local.get $edx) (local.get $sin_a))))
          (if (f64.gt (local.get $etx) (f64.const 0.3))
            (then
              (local.set $escr_x (i32.add (i32.const 160)
                (i32.trunc_f64_s (f64.div (f64.mul (local.get $etz) (f64.const 200.0)) (local.get $etx)))))
              (local.set $eheight (i32.trunc_f64_s (f64.div (f64.const 160.0) (local.get $etx))))
              (if (i32.gt_s (local.get $eheight) (i32.const 200)) (then (local.set $eheight (i32.const 200))))
              (local.set $ewidth (i32.div_s (i32.mul (local.get $eheight) (i32.const 8)) (i32.const 10)))
              (local.set $ecol_start (i32.sub (local.get $escr_x) (i32.shr_u (local.get $ewidth) (i32.const 1))))
              (local.set $ecol_end (i32.add (local.get $escr_x) (i32.shr_u (local.get $ewidth) (i32.const 1))))
              (local.set $erow_start (i32.sub (i32.const 100) (i32.shr_u (local.get $eheight) (i32.const 1))))
              (local.set $erow_end (i32.add (i32.const 100) (i32.shr_u (local.get $eheight) (i32.const 1))))
              ;; Enemy light factor
              (local.set $light (f64.div (f64.const 1.0)
                (f64.add (f64.const 1.0) (f64.mul (local.get $etx) (f64.const 0.25)))))
              (if (f64.lt (local.get $light) (f64.const 0.05))
                (then (local.set $light (f64.const 0.05))))
              ;; Draw columns
              (local.set $ecol (local.get $ecol_start))
              (block $ecd (loop $ecl (br_if $ecd (i32.ge_s (local.get $ecol) (local.get $ecol_end)))
                (if (i32.and (i32.ge_s (local.get $ecol) (i32.const 0)) (i32.lt_s (local.get $ecol) (i32.const 320)))
                  (then
                    (if (f64.lt (local.get $etx) (f64.promote_f32
                          (f32.load (i32.add (i32.const 0x3F000) (i32.mul (local.get $ecol) (i32.const 4))))))
                      (then
                        (local.set $erow (local.get $erow_start))
                        (block $erd (loop $erl (br_if $erd (i32.ge_s (local.get $erow) (local.get $erow_end)))
                          (if (i32.and (i32.ge_s (local.get $erow) (i32.const 0)) (i32.lt_s (local.get $erow) (i32.const 190)))
                            (then
                              ;; 16x16 sprite lookup
                              (local.set $tex_v (i32.div_u
                                (i32.mul (i32.sub (local.get $erow) (local.get $erow_start)) (i32.const 16))
                                (select (local.get $eheight) (i32.const 1) (i32.gt_s (local.get $eheight) (i32.const 0)))))
                              (local.set $tex_u (i32.div_u
                                (i32.mul (i32.sub (local.get $ecol) (local.get $ecol_start)) (i32.const 16))
                                (select (local.get $ewidth) (i32.const 1) (i32.gt_s (local.get $ewidth) (i32.const 0)))))
                              (if (i32.gt_u (local.get $tex_v) (i32.const 15)) (then (local.set $tex_v (i32.const 15))))
                              (if (i32.gt_u (local.get $tex_u) (i32.const 15)) (then (local.set $tex_u (i32.const 15))))
                              ;; Look up sprite (0 = transparent)
                              (local.set $ecolor (i32.load8_u (i32.add (i32.const 0x14480)
                                (i32.add (i32.mul (local.get $tex_v) (i32.const 16)) (local.get $tex_u)))))
                              (if (local.get $ecolor)
                                (then
                                  ;; Apply dithered lighting
                                  (local.set $ramp (i32.shr_u (local.get $ecolor) (i32.const 4)))
                                  (local.set $base_shade (i32.and (local.get $ecolor) (i32.const 15)))
                                  (local.set $lit (f64.mul (f64.convert_i32_u (local.get $base_shade)) (local.get $light)))
                                  (local.set $shade_lo (i32.trunc_f64_s (local.get $lit)))
                                  (if (i32.lt_s (local.get $shade_lo) (i32.const 0)) (then (local.set $shade_lo (i32.const 0))))
                                  (if (i32.gt_s (local.get $shade_lo) (i32.const 14)) (then (local.set $shade_lo (i32.const 14))))
                                  (local.set $frac (i32.trunc_f64_s (f64.mul
                                    (f64.sub (local.get $lit) (f64.convert_i32_s (local.get $shade_lo))) (f64.const 16.0))))
                                  (local.set $bayer (i32.load8_u (i32.add (i32.const 0x10440)
                                    (i32.add (i32.mul (i32.and (local.get $erow) (i32.const 3)) (i32.const 4))
                                             (i32.and (local.get $ecol) (i32.const 3))))))
                                  (local.set $final_shade (select
                                    (i32.add (local.get $shade_lo) (i32.const 1)) (local.get $shade_lo)
                                    (i32.gt_s (local.get $frac) (local.get $bayer))))
                                  (if (i32.gt_s (local.get $final_shade) (i32.const 15))
                                    (then (local.set $final_shade (i32.const 15))))
                                  (i32.store8 (i32.add (i32.const 0x0340)
                                    (i32.add (i32.mul (local.get $erow) (i32.const 320)) (local.get $ecol)))
                                    (i32.add (i32.shl (local.get $ramp) (i32.const 4)) (local.get $final_shade)))))))
                          (local.set $erow (i32.add (local.get $erow) (i32.const 1)))
                          (br $erl)))))))
                (local.set $ecol (i32.add (local.get $ecol) (i32.const 1)))
                (br $ecl)))))))
      (local.set $ei (i32.add (local.get $ei) (i32.const 1)))
      (br $erlp)))

    ;; === WEAPON (detailed shotgun with hand) ===
    (local.set $bob (i32.const 0))
    (if (i32.or (i32.and (local.get $keys) (i32.const 3)) (i32.load (i32.const 0x3F5A8)))
      (then (local.set $bob (i32.and (i32.shr_u (i32.load (i32.const 0x00)) (i32.const 2)) (i32.const 3)))))
    (local.set $wep_y (i32.sub (i32.const 0) (i32.add (local.get $bob) (i32.load (i32.const 0x3F5B8)))))
    ;; Hand — skin (ramp 14 tan)
    (call $draw_rect (i32.const 140) (i32.add (i32.const 182) (local.get $wep_y)) (i32.const 36) (i32.const 18) (i32.const 233))
    (call $draw_rect (i32.const 142) (i32.add (i32.const 180) (local.get $wep_y)) (i32.const 32) (i32.const 4) (i32.const 234))
    ;; Thumb (left side)
    (call $draw_rect (i32.const 137) (i32.add (i32.const 176) (local.get $wep_y)) (i32.const 5) (i32.const 10) (i32.const 232))
    ;; Fingers wrapping around grip
    (call $draw_rect (i32.const 145) (i32.add (i32.const 174) (local.get $wep_y)) (i32.const 28) (i32.const 3) (i32.const 235))
    (call $draw_rect (i32.const 147) (i32.add (i32.const 171) (local.get $wep_y)) (i32.const 24) (i32.const 3) (i32.const 234))
    ;; Knuckle highlights
    (call $draw_rect (i32.const 148) (i32.add (i32.const 178) (local.get $wep_y)) (i32.const 6) (i32.const 2) (i32.const 236))
    (call $draw_rect (i32.const 158) (i32.add (i32.const 178) (local.get $wep_y)) (i32.const 6) (i32.const 2) (i32.const 236))
    ;; Grip (ramp 10 steel, dark — cross-hatched)
    (call $draw_rect (i32.const 150) (i32.add (i32.const 168) (local.get $wep_y)) (i32.const 18) (i32.const 6) (i32.const 163))
    (call $draw_rect (i32.const 152) (i32.add (i32.const 170) (local.get $wep_y)) (i32.const 14) (i32.const 2) (i32.const 165))
    ;; Trigger guard (thin arc)
    (call $draw_rect (i32.const 148) (i32.add (i32.const 174) (local.get $wep_y)) (i32.const 2) (i32.const 8) (i32.const 166))
    (call $draw_rect (i32.const 170) (i32.add (i32.const 174) (local.get $wep_y)) (i32.const 2) (i32.const 8) (i32.const 166))
    (call $draw_rect (i32.const 150) (i32.add (i32.const 182) (local.get $wep_y)) (i32.const 20) (i32.const 1) (i32.const 166))
    ;; Trigger (ramp 10 shade 3)
    (call $draw_rect (i32.const 160) (i32.add (i32.const 176) (local.get $wep_y)) (i32.const 3) (i32.const 5) (i32.const 163))
    ;; Receiver body (main gun body)
    (call $draw_rect (i32.const 142) (i32.add (i32.const 152) (local.get $wep_y)) (i32.const 36) (i32.const 16) (i32.const 168))
    ;; Receiver top (lighter)
    (call $draw_rect (i32.const 142) (i32.add (i32.const 150) (local.get $wep_y)) (i32.const 36) (i32.const 3) (i32.const 170))
    ;; Right side highlight
    (call $draw_rect (i32.const 176) (i32.add (i32.const 152) (local.get $wep_y)) (i32.const 3) (i32.const 14) (i32.const 171))
    ;; Left side shadow
    (call $draw_rect (i32.const 142) (i32.add (i32.const 154) (local.get $wep_y)) (i32.const 2) (i32.const 12) (i32.const 164))
    ;; Ejection port (dark slot)
    (call $draw_rect (i32.const 163) (i32.add (i32.const 156) (local.get $wep_y)) (i32.const 10) (i32.const 4) (i32.const 161))
    (call $draw_rect (i32.const 164) (i32.add (i32.const 157) (local.get $wep_y)) (i32.const 8) (i32.const 2) (i32.const 160))
    ;; Hammer (rear)
    (call $draw_rect (i32.const 143) (i32.add (i32.const 148) (local.get $wep_y)) (i32.const 6) (i32.const 4) (i32.const 166))
    ;; Barrel
    (call $draw_rect (i32.const 152) (i32.add (i32.const 130) (local.get $wep_y)) (i32.const 16) (i32.const 20) (i32.const 170))
    ;; Barrel bore (dark center)
    (call $draw_rect (i32.const 157) (i32.add (i32.const 128) (local.get $wep_y)) (i32.const 6) (i32.const 4) (i32.const 161))
    (call $draw_rect (i32.const 158) (i32.add (i32.const 129) (local.get $wep_y)) (i32.const 4) (i32.const 2) (i32.const 160))
    ;; Barrel highlight (left edge)
    (call $draw_rect (i32.const 152) (i32.add (i32.const 132) (local.get $wep_y)) (i32.const 2) (i32.const 16) (i32.const 172))
    ;; Front sight post
    (call $draw_rect (i32.const 158) (i32.add (i32.const 124) (local.get $wep_y)) (i32.const 4) (i32.const 4) (i32.const 167))
    (call $draw_rect (i32.const 159) (i32.add (i32.const 122) (local.get $wep_y)) (i32.const 2) (i32.const 3) (i32.const 169))
    ;; Muzzle flash — star/cross pattern (ramp 8 yellow + ramp 12 orange + ramp 15 warm white)
    (if (i32.gt_s (i32.load (i32.const 0x3F5B8)) (i32.const 3))
      (then
        ;; Outer orange cross
        (call $draw_rect (i32.const 148) (i32.add (i32.const 118) (local.get $wep_y)) (i32.const 24) (i32.const 10) (i32.const 204))
        (call $draw_rect (i32.const 154) (i32.add (i32.const 108) (local.get $wep_y)) (i32.const 12) (i32.const 24) (i32.const 205))
        ;; Inner yellow
        (call $draw_rect (i32.const 152) (i32.add (i32.const 116) (local.get $wep_y)) (i32.const 16) (i32.const 6) (i32.const 142))
        (call $draw_rect (i32.const 156) (i32.add (i32.const 112) (local.get $wep_y)) (i32.const 8) (i32.const 14) (i32.const 143))
        ;; White-hot center
        (call $draw_rect (i32.const 157) (i32.add (i32.const 116) (local.get $wep_y)) (i32.const 6) (i32.const 4) (i32.const 255))
        ;; Diagonal flare lines
        (call $draw_rect (i32.const 146) (i32.add (i32.const 114) (local.get $wep_y)) (i32.const 4) (i32.const 3) (i32.const 206))
        (call $draw_rect (i32.const 170) (i32.add (i32.const 114) (local.get $wep_y)) (i32.const 4) (i32.const 3) (i32.const 206))
        (call $draw_rect (i32.const 146) (i32.add (i32.const 122) (local.get $wep_y)) (i32.const 4) (i32.const 3) (i32.const 206))
        (call $draw_rect (i32.const 170) (i32.add (i32.const 122) (local.get $wep_y)) (i32.const 4) (i32.const 3) (i32.const 206))))

    ;; Crosshair (ramp 0 shade 15 = white)
    (i32.store8 (i32.add (i32.const 0x0340) (i32.add (i32.mul (i32.const 100) (i32.const 320)) (i32.const 159))) (i32.const 15))
    (i32.store8 (i32.add (i32.const 0x0340) (i32.add (i32.mul (i32.const 100) (i32.const 320)) (i32.const 161))) (i32.const 15))
    (i32.store8 (i32.add (i32.const 0x0340) (i32.add (i32.mul (i32.const 99) (i32.const 320)) (i32.const 160))) (i32.const 15))
    (i32.store8 (i32.add (i32.const 0x0340) (i32.add (i32.mul (i32.const 101) (i32.const 320)) (i32.const 160))) (i32.const 15))

    ;; === HUD ===
    ;; Background (ramp 0 shade 1 = 1)
    (call $draw_rect (i32.const 0) (i32.const 190) (i32.const 320) (i32.const 10) (i32.const 1))
    ;; Health bar (ramp 11 shade 12 = 188)
    (call $draw_rect (i32.const 4) (i32.const 193)
      (select (i32.load (i32.const 0x3F50C)) (i32.const 0) (i32.gt_s (i32.load (i32.const 0x3F50C)) (i32.const 0)))
      (i32.const 4) (i32.const 188))
    ;; Health border (ramp 0 shade 8 = 8)
    (call $draw_rect (i32.const 3) (i32.const 192) (i32.const 102) (i32.const 1) (i32.const 8))
    (call $draw_rect (i32.const 3) (i32.const 197) (i32.const 102) (i32.const 1) (i32.const 8))
    ;; Kill marks (ramp 4 shade 12 = 76)
    (local.set $ei (i32.const 0))
    (block $kd (loop $kl (br_if $kd (i32.ge_u (local.get $ei) (i32.load (i32.const 0x3F5BC))))
      (call $draw_rect (i32.add (i32.const 220) (i32.mul (local.get $ei) (i32.const 10)))
        (i32.const 192) (i32.const 8) (i32.const 5) (i32.const 76))
      (local.set $ei (i32.add (local.get $ei) (i32.const 1)))
      (br $kl)))

    ;; Hit flash (ramp 7 shade 12 = 124, red edges)
    (if (i32.gt_s (i32.load (i32.const 0x3F5C4)) (i32.const 0))
      (then
        (local.set $row (i32.const 0))
        (block $hfd (loop $hfl (br_if $hfd (i32.ge_u (local.get $row) (i32.const 190)))
          (call $draw_rect (i32.const 0) (local.get $row) (i32.const 8) (i32.const 1) (i32.const 124))
          (call $draw_rect (i32.const 312) (local.get $row) (i32.const 8) (i32.const 1) (i32.const 124))
          (local.set $row (i32.add (local.get $row) (i32.const 4)))
          (br $hfl)))))
  )

  ;; ---- Data segments ----
  ;; Map 16x16 at 0x10340: 1=drywall 2=cubicle 3=server 4=demon
  (data (i32.const 0x10340)
    "\01\01\01\01\01\01\01\01\01\01\01\01\01\01\01\01"
    "\01\00\00\00\00\00\00\00\00\00\00\00\00\00\00\01"
    "\01\00\02\02\00\02\02\00\00\00\00\00\00\00\00\01"
    "\01\00\00\00\00\00\00\00\00\00\00\00\00\00\00\01"
    "\01\00\02\02\00\02\02\00\00\03\03\03\00\00\00\01"
    "\01\00\00\00\00\00\00\00\00\03\00\03\00\00\00\01"
    "\01\01\01\01\00\01\01\01\00\03\03\03\00\01\01\01"
    "\01\00\00\00\00\00\00\00\00\00\00\00\00\00\00\01"
    "\01\00\00\00\00\00\00\00\00\00\00\00\00\00\00\01"
    "\01\01\01\01\00\01\01\01\00\01\01\01\00\01\01\01"
    "\01\00\00\00\00\00\00\00\00\04\00\04\04\00\00\01"
    "\01\00\02\02\00\02\02\00\00\04\00\00\00\00\00\01"
    "\01\00\00\00\00\00\00\00\00\04\00\04\04\00\00\01"
    "\01\00\02\02\00\02\02\00\00\00\00\00\00\00\00\01"
    "\01\00\00\00\00\00\00\00\00\00\00\00\00\00\00\01"
    "\01\01\01\01\01\01\01\01\01\01\01\01\01\01\01\01")

  ;; Bayer 4x4 ordered dither matrix (values 0-15)
  (data (i32.const 0x10440)
    "\00\08\02\0A\0C\04\0E\06\03\0B\01\09\0F\07\0D\05")

  ;; 16 ramp target RGB colors (48 bytes) — each ramp goes shade 0 (black) to shade 15 (target)
  ;; 0:Gray      1:Beige     2:BlueGray  3:Teal      4:BloodRed  5:Brown
  ;; 6:Fluoresc  7:Crimson   8:Yellow    9:Purple    10:Steel    11:Green
  ;; 12:Orange   13:Cyan     14:Tan      15:WarmWht
  ;;
  ;; Enemy demon sprite 16x16 at 0x14480 (256 bytes, 0=transparent)
  ;; H=0xEB(bone) C=0x7A(crimson) E=0x8E(eye) T=0x0D(teeth)
  ;; B=0x4A(blood) A=0x9A(purple) P=0x98(belt)
  (data (i32.const 0x14480)
    "\00\00\00\EB\00\00\00\00\00\00\00\00\EB\00\00\00"  ;; horns
    "\00\00\EB\EB\EB\00\00\00\00\00\EB\EB\EB\00\00\00"  ;; horn stems
    "\00\00\00\00\7A\7A\7A\7A\7A\7A\00\00\00\00\00\00"  ;; head top
    "\00\00\00\7A\7A\7A\7A\7A\7A\7A\7A\00\00\00\00\00"  ;; head
    "\00\00\00\7A\8E\7A\7A\7A\7A\8E\7A\00\00\00\00\00"  ;; eyes
    "\00\00\00\00\7A\7A\0D\0D\7A\7A\00\00\00\00\00\00"  ;; mouth/teeth
    "\00\00\7A\7A\7A\7A\7A\7A\7A\7A\7A\7A\00\00\00\00"  ;; shoulders
    "\00\9A\7A\7A\7A\7A\7A\7A\7A\7A\7A\7A\9A\00\00\00"  ;; arms extended
    "\00\9A\00\00\4A\4A\4A\4A\4A\4A\00\00\9A\00\00\00"  ;; torso + arms
    "\00\00\00\00\4A\4A\4A\4A\4A\4A\00\00\00\00\00\00"  ;; waist
    "\00\00\00\00\98\98\98\98\98\98\00\00\00\00\00\00"  ;; belt
    "\00\00\00\4A\4A\4A\00\00\4A\4A\4A\00\00\00\00\00"  ;; upper legs
    "\00\00\00\4A\4A\00\00\00\00\4A\4A\00\00\00\00\00"  ;; legs apart
    "\00\00\00\4A\4A\00\00\00\00\4A\4A\00\00\00\00\00"  ;; lower legs
    "\00\00\9A\4A\4A\00\00\00\00\4A\4A\9A\00\00\00\00"  ;; feet + claws
    "\00\9A\9A\00\00\00\00\00\00\00\00\9A\9A\00\00\00") ;; claw tips

  (data (i32.const 0x10450)
    "\FF\FF\FF"  ;; 0  gray/white
    "\D2\B4\8C"  ;; 1  beige
    "\82\96\BE"  ;; 2  blue-gray
    "\50\AA\82"  ;; 3  teal
    "\C8\37\2D"  ;; 4  blood red
    "\9B\73\4B"  ;; 5  brown
    "\AF\C3\A5"  ;; 6  fluorescent
    "\D7\2D\23"  ;; 7  crimson
    "\FF\D7\37"  ;; 8  yellow
    "\9B\4B\AF"  ;; 9  purple
    "\91\96\A5"  ;; 10 steel
    "\37\D7\37"  ;; 11 green
    "\FF\9B\23"  ;; 12 orange
    "\4B\C3\EB"  ;; 13 cyan
    "\D7\AF\91"  ;; 14 tan
    "\FF\FF\D7"  ;; 15 warm white
  )
)
