(module
  (import "env" "memory" (memory 4))

  ;; Doom-style fire effect
  ;; Uses scratch area at 0x10040 for fire intensity buffer (320*200 = 64000 bytes)
  ;; Fire buffer stores intensity 0-255, mapped via fire palette

  (func (export "init")
    (local $i i32)
    ;; Set up fire palette at 0x0040 (256 entries * 3 bytes)
    ;; Black -> red -> yellow -> white
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $i) (i32.const 256)))
        (call $set_fire_color (local.get $i))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)
      )
    )
    ;; Set bottom row of fire buffer to max intensity (white)
    (local.set $i (i32.const 0))
    (block $done2
      (loop $lp2
        (br_if $done2 (i32.ge_u (local.get $i) (i32.const 320)))
        ;; bottom row = row 199
        (i32.store8
          (i32.add (i32.const 0x10040) (i32.add (i32.mul (i32.const 199) (i32.const 320)) (local.get $i)))
          (i32.const 255))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp2)
      )
    )
  )

  (func $set_fire_color (param $i i32)
    (local $addr i32) (local $r i32) (local $g i32) (local $b i32)
    (local.set $addr (i32.add (i32.const 0x0040) (i32.mul (local.get $i) (i32.const 3))))
    ;; 0-85: black to red
    (if (i32.lt_u (local.get $i) (i32.const 85))
      (then
        (local.set $r (i32.mul (local.get $i) (i32.const 3)))
        (local.set $g (i32.const 0))
        (local.set $b (i32.const 0))
      )
      (else (if (i32.lt_u (local.get $i) (i32.const 170))
        (then
          ;; 85-170: red to yellow
          (local.set $r (i32.const 255))
          (local.set $g (i32.mul (i32.sub (local.get $i) (i32.const 85)) (i32.const 3)))
          (local.set $b (i32.const 0))
        )
        (else
          ;; 170-255: yellow to white
          (local.set $r (i32.const 255))
          (local.set $g (i32.const 255))
          (local.set $b (i32.mul (i32.sub (local.get $i) (i32.const 170)) (i32.const 3)))
        )
      ))
    )
    (if (i32.gt_u (local.get $r) (i32.const 255)) (then (local.set $r (i32.const 255))))
    (if (i32.gt_u (local.get $g) (i32.const 255)) (then (local.set $g (i32.const 255))))
    (if (i32.gt_u (local.get $b) (i32.const 255)) (then (local.set $b (i32.const 255))))
    (i32.store8 (local.get $addr) (local.get $r))
    (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (local.get $g))
    (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (local.get $b))
  )

  ;; Simple PRNG state at 0x10000 (before fire buffer)
  (func $rand (result i32)
    (local $s i32)
    (local.set $s (i32.load (i32.const 0x10000)))
    ;; xorshift32
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 13))))
    (local.set $s (i32.xor (local.get $s) (i32.shr_u (local.get $s) (i32.const 17))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 5))))
    ;; avoid 0 state
    (if (i32.eqz (local.get $s)) (then (local.set $s (i32.const 1))))
    (i32.store (i32.const 0x10000) (local.get $s))
    (local.get $s)
  )

  (func (export "frame")
    (local $x i32) (local $y i32) (local $src i32) (local $val i32)
    (local $dst i32) (local $rnd i32)
    ;; seed PRNG if zero
    (if (i32.eqz (i32.load (i32.const 0x10000)))
      (then (i32.store (i32.const 0x10000) (i32.const 12345))))
    ;; Classic DOOM fire: for each pixel (x,y) where y > 0,
    ;; sample fire[y][x], apply random decay, write to fire[y-1][x + wind]
    (local.set $y (i32.const 1))
    (block $ydone
      (loop $yloop
        (br_if $ydone (i32.ge_u (local.get $y) (i32.const 200)))
        (local.set $x (i32.const 0))
        (block $xdone
          (loop $xloop
            (br_if $xdone (i32.ge_u (local.get $x) (i32.const 320)))
            ;; read source pixel fire[y][x]
            (local.set $src (i32.add (i32.const 0x10040)
              (i32.add (i32.mul (local.get $y) (i32.const 320)) (local.get $x))))
            (local.set $val (i32.load8_u (local.get $src)))
            ;; decay = rand & 3
            (local.set $rnd (i32.and (call $rand) (i32.const 3)))
            (local.set $val (i32.sub (local.get $val) (local.get $rnd)))
            (if (i32.lt_s (local.get $val) (i32.const 0))
              (then (local.set $val (i32.const 0))))
            ;; wind offset: rand & 3 gives 0,1,2,3; subtract 1 for range -1..2
            (local.set $dst (i32.add (local.get $x)
              (i32.sub (i32.and (call $rand) (i32.const 3)) (i32.const 1))))
            ;; clamp x to [0, 319]
            (if (i32.lt_s (local.get $dst) (i32.const 0))
              (then (local.set $dst (i32.const 0))))
            (if (i32.gt_s (local.get $dst) (i32.const 319))
              (then (local.set $dst (i32.const 319))))
            ;; write to fire[y-1][dst_x]
            (i32.store8
              (i32.add (i32.const 0x10040)
                (i32.add (i32.mul (i32.sub (local.get $y) (i32.const 1)) (i32.const 320))
                  (local.get $dst)))
              (local.get $val))
            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (br $xloop)
          )
        )
        (local.set $y (i32.add (local.get $y) (i32.const 1)))
        (br $yloop)
      )
    )
    ;; Copy fire buffer to framebuffer
    (local.set $y (i32.const 0))
    (block $cdone
      (loop $cloop
        (br_if $cdone (i32.ge_u (local.get $y) (i32.const 64000)))
        (i32.store8
          (i32.add (i32.const 0x0340) (local.get $y))
          (i32.load8_u (i32.add (i32.const 0x10040) (local.get $y))))
        (local.set $y (i32.add (local.get $y) (i32.const 1)))
        (br $cloop)
      )
    )
  )
)
