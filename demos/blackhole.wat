(module
  (import "env" "memory" (memory 4))
  (import "env" "note" (func $note (param i32 i32 i32 i32)))

  ;; Interstellar-style black hole with gravitational lensing
  ;; Schwarzschild geodesic ray marching with accretion disk
  ;; Interactive: arrow keys orbit, mouse controls view, W/S zoom
  ;;
  ;; Memory layout (guest area):
  ;;   0x10340  PRNG state (4 bytes)
  ;;   0x10344  orbit_angle (f64) — horizontal orbit
  ;;   0x1034C  orbit_tilt (f64) — vertical elevation angle
  ;;   0x10354  orbit_dist (f64) — camera distance from BH
  ;;   0x1035C  prev_mouse_x (i32)
  ;;   0x10360  prev_mouse_y (i32)
  ;;   0x10364  idle_counter (i32)
  ;;   0x10368  autopilot (i32) — 1=auto
  ;;   0x1036C  sound_timer (i32) — frames until next ambient sound
  ;;   0x10370  drone_timer (i32) — frames until next drone

  ;; ---- sin_approx (3-step range reduction, from raycaster) ----
  (func $sin_a (param $x f64) (result f64)
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

  (func $cos_a (param $x f64) (result f64)
    (call $sin_a (f64.add (local.get $x) (f64.const 1.5707963)))
  )

  (func $rand (result i32)
    (local $s i32)
    (local.set $s (i32.load (i32.const 0x10340)))
    (if (i32.eqz (local.get $s)) (then (local.set $s (i32.const 987654321))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 13))))
    (local.set $s (i32.xor (local.get $s) (i32.shr_u (local.get $s) (i32.const 17))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 5))))
    (i32.store (i32.const 0x10340) (local.get $s))
    (local.get $s)
  )

  ;; ---- Init ----
  (func (export "init")
    (local $i i32) (local $addr i32)
    (local $t f64) (local $r i32) (local $g i32) (local $b i32)

    ;; Palette 0: black (event horizon + deep space)
    ;; Already zero from memory init

    ;; Palette 1-3: dark space tints
    (i32.store8 (i32.const 0x43) (i32.const 1))
    (i32.store8 (i32.const 0x44) (i32.const 1))
    (i32.store8 (i32.const 0x45) (i32.const 4))
    (i32.store8 (i32.const 0x46) (i32.const 2))
    (i32.store8 (i32.const 0x47) (i32.const 2))
    (i32.store8 (i32.const 0x48) (i32.const 7))
    (i32.store8 (i32.const 0x49) (i32.const 3))
    (i32.store8 (i32.const 0x4A) (i32.const 3))
    (i32.store8 (i32.const 0x4B) (i32.const 10))

    ;; Palette 4-7: star brightness levels (white)
    (i32.store8 (i32.const 0x4C) (i32.const 50))
    (i32.store8 (i32.const 0x4D) (i32.const 50))
    (i32.store8 (i32.const 0x4E) (i32.const 60))
    (i32.store8 (i32.const 0x4F) (i32.const 120))
    (i32.store8 (i32.const 0x50) (i32.const 115))
    (i32.store8 (i32.const 0x51) (i32.const 140))
    (i32.store8 (i32.const 0x52) (i32.const 200))
    (i32.store8 (i32.const 0x53) (i32.const 195))
    (i32.store8 (i32.const 0x54) (i32.const 220))
    (i32.store8 (i32.const 0x55) (i32.const 255))
    (i32.store8 (i32.const 0x56) (i32.const 250))
    (i32.store8 (i32.const 0x57) (i32.const 255))

    ;; Palette 8-11: colored stars (warm, blue, cyan)
    (i32.store8 (i32.const 0x58) (i32.const 80))
    (i32.store8 (i32.const 0x59) (i32.const 50))
    (i32.store8 (i32.const 0x5A) (i32.const 30))
    (i32.store8 (i32.const 0x5B) (i32.const 160))
    (i32.store8 (i32.const 0x5C) (i32.const 120))
    (i32.store8 (i32.const 0x5D) (i32.const 60))
    (i32.store8 (i32.const 0x5E) (i32.const 140))
    (i32.store8 (i32.const 0x5F) (i32.const 160))
    (i32.store8 (i32.const 0x60) (i32.const 255))
    (i32.store8 (i32.const 0x61) (i32.const 100))
    (i32.store8 (i32.const 0x62) (i32.const 180))
    (i32.store8 (i32.const 0x63) (i32.const 255))

    ;; Palette 16-143: accretion disk gradient (128 colors: outer cool → inner hot)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 128)))
      (local.set $addr (i32.add (i32.const 0x0070) (i32.mul (local.get $i) (i32.const 3))))
      ;; R = min(255, i*5 + 30) — saturates at i≈45
      (local.set $r (i32.add (i32.mul (local.get $i) (i32.const 5)) (i32.const 30)))
      (if (i32.gt_s (local.get $r) (i32.const 255)) (then (local.set $r (i32.const 255))))
      ;; G = min(255, max(0, (i-12)*4)) — warm orange from i=12
      (local.set $g (i32.mul (i32.sub (local.get $i) (i32.const 12)) (i32.const 4)))
      (if (i32.lt_s (local.get $g) (i32.const 0)) (then (local.set $g (i32.const 0))))
      (if (i32.gt_s (local.get $g) (i32.const 255)) (then (local.set $g (i32.const 255))))
      ;; B = min(255, max(0, (i-40)*4)) — late blue for white inner
      (local.set $b (i32.mul (i32.sub (local.get $i) (i32.const 40)) (i32.const 4)))
      (if (i32.lt_s (local.get $b) (i32.const 0)) (then (local.set $b (i32.const 0))))
      (if (i32.gt_s (local.get $b) (i32.const 255)) (then (local.set $b (i32.const 255))))
      (i32.store8 (local.get $addr) (local.get $r))
      (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (local.get $g))
      (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (local.get $b))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)
    ))

    ;; Palette 80-95: photon ring glow (warm white → blue-white)
    (local.set $i (i32.const 0))
    (block $done2 (loop $lp2
      (br_if $done2 (i32.ge_u (local.get $i) (i32.const 16)))
      (local.set $addr (i32.add (i32.const 0x01F4) (i32.mul (local.get $i) (i32.const 3))))
      (local.set $t (f64.div (f64.convert_i32_u (local.get $i)) (f64.const 15.0)))
      (local.set $r (i32.trunc_f64_s (f64.sub (f64.const 255.0) (f64.mul (local.get $t) (f64.const 60.0)))))
      (local.set $g (i32.trunc_f64_s (f64.sub (f64.const 240.0) (f64.mul (local.get $t) (f64.const 30.0)))))
      (local.set $b (i32.const 255))
      (i32.store8 (local.get $addr) (local.get $r))
      (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (local.get $g))
      (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (local.get $b))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp2)
    ))

    ;; Init camera state
    (f64.store (i32.const 0x10344) (f64.const 0.0))    ;; orbit_angle
    (f64.store (i32.const 0x1034C) (f64.const 0.25))   ;; orbit_tilt (slightly above disk)
    (f64.store (i32.const 0x10354) (f64.const 28.0))   ;; orbit_dist
    (i32.store (i32.const 0x1035C) (i32.const 0))      ;; prev_mouse_x
    (i32.store (i32.const 0x10360) (i32.const 0))      ;; prev_mouse_y
    (i32.store (i32.const 0x10364) (i32.const 60))      ;; idle_counter (start high)
    (i32.store (i32.const 0x10368) (i32.const 1))       ;; autopilot on
    (i32.store (i32.const 0x1036C) (i32.const 30))      ;; sound_timer
    (i32.store (i32.const 0x10370) (i32.const 0))       ;; drone_timer

    ;; 4x4 Bayer dither matrix at 0x10380 (16 bytes)
    ;; Values 0-15, looked up by (py&3)*4 + (px&3)
    (i32.store (i32.const 0x10380) (i32.const 0x0a020800))  ;;  0, 8, 2,10
    (i32.store (i32.const 0x10384) (i32.const 0x060e040c))  ;; 12, 4,14, 6
    (i32.store (i32.const 0x10388) (i32.const 0x09010b03))  ;;  3,11, 1, 9
    (i32.store (i32.const 0x1038C) (i32.const 0x050d070f))  ;; 15, 7,13, 5

    ;; Init PRNG
    (i32.store (i32.const 0x10340) (i32.const 987654321))
  )

  ;; ---- Frame ----
  (func (export "frame")
    (local $px i32) (local $py i32) (local $fb_addr i32)
    (local $frame_count i32)
    (local $orbit_angle f64) (local $orbit_tilt f64) (local $orbit_dist f64)
    (local $cam_x f64) (local $cam_y f64) (local $cam_z f64) (local $cam_dist f64)
    (local $fwd_x f64) (local $fwd_y f64) (local $fwd_z f64)
    (local $right_x f64) (local $right_z f64) (local $right_len f64)
    (local $up_x f64) (local $up_y f64) (local $up_z f64)
    (local $u f64) (local $v f64)
    (local $ray_dx f64) (local $ray_dy f64) (local $ray_dz f64) (local $ray_len f64)
    (local $pos_x f64) (local $pos_y f64) (local $pos_z f64)
    (local $vel_x f64) (local $vel_y f64) (local $vel_z f64)
    (local $r f64) (local $r2 f64) (local $r3 f64) (local $r5 f64)
    (local $dt f64) (local $factor f64)
    (local $cx f64) (local $cy f64) (local $cz f64) (local $L2 f64)
    (local $old_y f64) (local $disk_r f64) (local $disk_r2 f64)
    (local $t f64) (local $doppler f64) (local $brightness f64)
    (local $color i32) (local $step i32) (local $idx i32)
    (local $hash i32) (local $ix i32) (local $iy i32) (local $iz i32)
    (local $spiral f64) (local $pattern f64)
    (local $keys i32) (local $mouse_x i32) (local $mouse_y i32)
    (local $prev_mx i32) (local $prev_my i32)
    (local $has_input i32) (local $sound_timer i32) (local $rnd i32)
    (local $cos_tilt f64) (local $sin_tilt f64)

    ;; Read frame counter
    (local.set $frame_count (i32.load (i32.const 0x00)))

    ;; Read input state
    (local.set $keys (i32.load8_u (i32.const 0x10)))
    (local.set $mouse_x (i32.load16_u (i32.const 0x04)))
    (local.set $mouse_y (i32.load16_u (i32.const 0x06)))
    (local.set $prev_mx (i32.load (i32.const 0x1035C)))
    (local.set $prev_my (i32.load (i32.const 0x10360)))

    ;; Load camera state from memory
    (local.set $orbit_angle (f64.load (i32.const 0x10344)))
    (local.set $orbit_tilt (f64.load (i32.const 0x1034C)))
    (local.set $orbit_dist (f64.load (i32.const 0x10354)))

    ;; --- Autopilot / manual mode detection ---
    (local.set $has_input (i32.const 0))
    ;; Check keyboard
    (if (local.get $keys)
      (then (local.set $has_input (i32.const 1))))
    ;; Check mouse movement (skip if prev was 0,0 = first frame)
    (if (i32.and
          (i32.ne (local.get $prev_mx) (i32.const 0))
          (i32.or
            (i32.ne (local.get $mouse_x) (local.get $prev_mx))
            (i32.ne (local.get $mouse_y) (local.get $prev_my))))
      (then (local.set $has_input (i32.const 1))))

    (if (local.get $has_input)
      (then
        ;; Input: reset idle, go manual
        (i32.store (i32.const 0x10364) (i32.const 0))
        (i32.store (i32.const 0x10368) (i32.const 0)))
      (else
        ;; No input: increment idle
        (i32.store (i32.const 0x10364)
          (i32.add (i32.load (i32.const 0x10364)) (i32.const 1)))
        ;; After 90 idle frames → autopilot
        (if (i32.ge_u (i32.load (i32.const 0x10364)) (i32.const 90))
          (then (i32.store (i32.const 0x10368) (i32.const 1))))))

    ;; Save mouse for next frame
    (i32.store (i32.const 0x1035C) (local.get $mouse_x))
    (i32.store (i32.const 0x10360) (local.get $mouse_y))

    ;; --- Camera control ---
    (if (i32.load (i32.const 0x10368))
      (then
        ;; === AUTOPILOT: slow orbit ===
        (local.set $orbit_angle (f64.add (local.get $orbit_angle) (f64.const 0.003)))
        ;; Gentle tilt oscillation
        (local.set $orbit_tilt (f64.add (f64.const 0.25)
          (f64.mul (f64.const 0.15) (call $sin_a
            (f64.mul (f64.convert_i32_u (local.get $frame_count)) (f64.const 0.004))))))
        ;; Gentle distance oscillation
        (local.set $orbit_dist (f64.add (f64.const 28.0)
          (f64.mul (f64.const 6.0) (call $sin_a
            (f64.mul (f64.convert_i32_u (local.get $frame_count)) (f64.const 0.002)))))))
      (else
        ;; === MANUAL CONTROL ===
        ;; Left/Right (bits 2,3): orbit horizontally
        (if (i32.and (local.get $keys) (i32.const 4))  ;; Left/A
          (then (local.set $orbit_angle (f64.sub (local.get $orbit_angle) (f64.const 0.03)))))
        (if (i32.and (local.get $keys) (i32.const 8))  ;; Right/D
          (then (local.set $orbit_angle (f64.add (local.get $orbit_angle) (f64.const 0.03)))))
        ;; Up/Down (bits 0,1): orbit vertically
        (if (i32.and (local.get $keys) (i32.const 1))  ;; Up/W
          (then (local.set $orbit_tilt (f64.add (local.get $orbit_tilt) (f64.const 0.02)))))
        (if (i32.and (local.get $keys) (i32.const 2))  ;; Down/S
          (then (local.set $orbit_tilt (f64.sub (local.get $orbit_tilt) (f64.const 0.02)))))
        ;; Space (bit 4): zoom in
        (if (i32.and (local.get $keys) (i32.const 16))
          (then (local.set $orbit_dist (f64.sub (local.get $orbit_dist) (f64.const 0.15)))))
        ;; Shift (bit 7): zoom out
        (if (i32.and (local.get $keys) (i32.const 128))
          (then (local.set $orbit_dist (f64.add (local.get $orbit_dist) (f64.const 0.15)))))

        ;; Mouse: relative movement adjusts orbit
        (if (i32.ne (local.get $prev_mx) (i32.const 0))
          (then
            (local.set $orbit_angle (f64.add (local.get $orbit_angle)
              (f64.mul (f64.convert_i32_s (i32.sub (local.get $mouse_x) (local.get $prev_mx)))
                       (f64.const 0.008))))
            (local.set $orbit_tilt (f64.sub (local.get $orbit_tilt)
              (f64.mul (f64.convert_i32_s (i32.sub (local.get $mouse_y) (local.get $prev_my)))
                       (f64.const 0.008))))))))

    ;; Clamp tilt to [-1.2, 1.2] (avoid gimbal lock)
    (if (f64.gt (local.get $orbit_tilt) (f64.const 1.2))
      (then (local.set $orbit_tilt (f64.const 1.2))))
    (if (f64.lt (local.get $orbit_tilt) (f64.const -1.2))
      (then (local.set $orbit_tilt (f64.const -1.2))))
    ;; Clamp distance to [3.0, 30.0]
    (if (f64.lt (local.get $orbit_dist) (f64.const 3.0))
      (then (local.set $orbit_dist (f64.const 3.0))))
    (if (f64.gt (local.get $orbit_dist) (f64.const 120.0))
      (then (local.set $orbit_dist (f64.const 120.0))))

    ;; Save camera state
    (f64.store (i32.const 0x10344) (local.get $orbit_angle))
    (f64.store (i32.const 0x1034C) (local.get $orbit_tilt))
    (f64.store (i32.const 0x10354) (local.get $orbit_dist))

    ;; --- Creepy ambient sounds ---
    ;; Deep rumbling drone (every ~120 frames)
    (i32.store (i32.const 0x10370) (i32.sub (i32.load (i32.const 0x10370)) (i32.const 1)))
    (if (i32.le_s (i32.load (i32.const 0x10370)) (i32.const 0))
      (then
        ;; Low ominous drone — sine wave, deep frequency
        (call $note (i32.const 0) (i32.const 38) (i32.const 3000) (i32.const 80))
        ;; Dissonant undertone
        (call $note (i32.const 0) (i32.const 41) (i32.const 2800) (i32.const 60))
        ;; Sub-bass pulse
        (call $note (i32.const 0) (i32.const 25) (i32.const 2000) (i32.const 70))
        (i32.store (i32.const 0x10370) (i32.const 100))))

    ;; Eerie ambient sounds (random, every ~60-200 frames)
    (local.set $sound_timer (i32.sub (i32.load (i32.const 0x1036C)) (i32.const 1)))
    (i32.store (i32.const 0x1036C) (local.get $sound_timer))
    (if (i32.le_s (local.get $sound_timer) (i32.const 0))
      (then
        (local.set $rnd (call $rand))
        ;; Pick from several creepy sounds based on rnd
        (if (i32.lt_u (i32.and (local.get $rnd) (i32.const 7)) (i32.const 2))
          (then
            ;; High eerie whistle — triangle wave, ghostly
            (call $note (i32.const 3) (i32.const 1200) (i32.const 1000) (i32.const 30))
            (call $note (i32.const 3) (i32.const 1207) (i32.const 1100) (i32.const 25))))
        (if (i32.and
              (i32.ge_u (i32.and (local.get $rnd) (i32.const 7)) (i32.const 2))
              (i32.lt_u (i32.and (local.get $rnd) (i32.const 7)) (i32.const 4)))
          (then
            ;; Deep metallic groan — sawtooth, very low
            (call $note (i32.const 2) (i32.const 55) (i32.const 2000) (i32.const 70))
            (call $note (i32.const 0) (i32.const 57) (i32.const 1800) (i32.const 50))))
        (if (i32.and
              (i32.ge_u (i32.and (local.get $rnd) (i32.const 7)) (i32.const 4))
              (i32.lt_u (i32.and (local.get $rnd) (i32.const 7)) (i32.const 6)))
          (then
            ;; Descending tone — like something falling in
            (call $note (i32.const 0) (i32.const 300) (i32.const 800) (i32.const 40))
            (call $note (i32.const 0) (i32.const 180) (i32.const 1000) (i32.const 50))
            (call $note (i32.const 0) (i32.const 80) (i32.const 1500) (i32.const 60))))
        (if (i32.ge_u (i32.and (local.get $rnd) (i32.const 7)) (i32.const 6))
          (then
            ;; Dissonant chord — tritone, unsettling
            (call $note (i32.const 3) (i32.const 220) (i32.const 2500) (i32.const 35))
            (call $note (i32.const 3) (i32.const 311) (i32.const 2500) (i32.const 35))))
        ;; Next sound in 40-130 frames
        (i32.store (i32.const 0x1036C) (i32.add (i32.const 40)
          (i32.rem_u (i32.and (call $rand) (i32.const 0x7FFFFFFF)) (i32.const 90))))))

    ;; --- Compute camera position from orbit params ---
    (local.set $cos_tilt (call $cos_a (local.get $orbit_tilt)))
    (local.set $sin_tilt (call $sin_a (local.get $orbit_tilt)))

    (local.set $cam_x (f64.mul (local.get $orbit_dist)
      (f64.mul (local.get $cos_tilt) (call $cos_a (local.get $orbit_angle)))))
    (local.set $cam_y (f64.mul (local.get $orbit_dist) (local.get $sin_tilt)))
    (local.set $cam_z (f64.mul (local.get $orbit_dist)
      (f64.mul (local.get $cos_tilt) (call $sin_a (local.get $orbit_angle)))))

    ;; Camera distance from origin
    (local.set $cam_dist (f64.sqrt (f64.add (f64.add
      (f64.mul (local.get $cam_x) (local.get $cam_x))
      (f64.mul (local.get $cam_y) (local.get $cam_y)))
      (f64.mul (local.get $cam_z) (local.get $cam_z)))))

    ;; Forward = normalize(-cam_pos)
    (local.set $fwd_x (f64.div (f64.neg (local.get $cam_x)) (local.get $cam_dist)))
    (local.set $fwd_y (f64.div (f64.neg (local.get $cam_y)) (local.get $cam_dist)))
    (local.set $fwd_z (f64.div (f64.neg (local.get $cam_z)) (local.get $cam_dist)))

    ;; Right = normalize(fwd × (0,1,0)) = normalize(-fwd_z, 0, fwd_x)
    (local.set $right_len (f64.sqrt (f64.add
      (f64.mul (local.get $fwd_z) (local.get $fwd_z))
      (f64.mul (local.get $fwd_x) (local.get $fwd_x)))))
    ;; Guard against zero (looking straight up/down)
    (if (f64.lt (local.get $right_len) (f64.const 0.001))
      (then (local.set $right_len (f64.const 0.001))))
    (local.set $right_x (f64.div (f64.neg (local.get $fwd_z)) (local.get $right_len)))
    (local.set $right_z (f64.div (local.get $fwd_x) (local.get $right_len)))

    ;; Up = right × fwd = (-rz*fy, rz*fx - rx*fz, rx*fy)
    (local.set $up_x (f64.neg (f64.mul (local.get $right_z) (local.get $fwd_y))))
    (local.set $up_y (f64.sub
      (f64.mul (local.get $right_z) (local.get $fwd_x))
      (f64.mul (local.get $right_x) (local.get $fwd_z))))
    (local.set $up_z (f64.mul (local.get $right_x) (local.get $fwd_y)))

    ;; === Pixel loop ===
    (local.set $py (i32.const 0))
    (block $ydone (loop $ylp
      (br_if $ydone (i32.ge_u (local.get $py) (i32.const 200)))
      (local.set $px (i32.const 0))
      (block $xdone (loop $xlp
        (br_if $xdone (i32.ge_u (local.get $px) (i32.const 320)))

        ;; Compute ray direction
        (local.set $u (f64.div (f64.convert_i32_s (i32.sub (local.get $px) (i32.const 160))) (f64.const 200.0)))
        (local.set $v (f64.div (f64.convert_i32_s (i32.sub (i32.const 100) (local.get $py))) (f64.const 200.0)))

        (local.set $ray_dx (f64.add (local.get $fwd_x)
          (f64.add (f64.mul (local.get $u) (local.get $right_x))
                   (f64.mul (local.get $v) (local.get $up_x)))))
        (local.set $ray_dy (f64.add (local.get $fwd_y)
          (f64.mul (local.get $v) (local.get $up_y))))
        (local.set $ray_dz (f64.add (local.get $fwd_z)
          (f64.add (f64.mul (local.get $u) (local.get $right_z))
                   (f64.mul (local.get $v) (local.get $up_z)))))

        ;; Normalize ray direction
        (local.set $ray_len (f64.sqrt (f64.add (f64.add
          (f64.mul (local.get $ray_dx) (local.get $ray_dx))
          (f64.mul (local.get $ray_dy) (local.get $ray_dy)))
          (f64.mul (local.get $ray_dz) (local.get $ray_dz)))))
        (local.set $ray_dx (f64.div (local.get $ray_dx) (local.get $ray_len)))
        (local.set $ray_dy (f64.div (local.get $ray_dy) (local.get $ray_len)))
        (local.set $ray_dz (f64.div (local.get $ray_dz) (local.get $ray_len)))

        ;; Init ray state
        (local.set $pos_x (local.get $cam_x))
        (local.set $pos_y (local.get $cam_y))
        (local.set $pos_z (local.get $cam_z))
        (local.set $vel_x (local.get $ray_dx))
        (local.set $vel_y (local.get $ray_dy))
        (local.set $vel_z (local.get $ray_dz))
        (local.set $color (i32.const 0))

        ;; Ray march loop
        (local.set $step (i32.const 0))
        (block $ray_done (loop $ray_lp
          (br_if $ray_done (i32.ge_u (local.get $step) (i32.const 200)))

          ;; Distance from black hole
          (local.set $r2 (f64.add (f64.add
            (f64.mul (local.get $pos_x) (local.get $pos_x))
            (f64.mul (local.get $pos_y) (local.get $pos_y)))
            (f64.mul (local.get $pos_z) (local.get $pos_z))))
          (local.set $r (f64.sqrt (local.get $r2)))

          ;; Event horizon (rs = 2*GM = 1.0)
          (if (f64.lt (local.get $r) (f64.const 1.0))
            (then
              (local.set $color (i32.const 0))
              (br $ray_done)))

          ;; Adaptive step size (conservative near BH, fast when far)
          (local.set $dt (f64.mul (local.get $r) (f64.const 0.08)))
          (if (f64.lt (local.get $dt) (f64.const 0.01))
            (then (local.set $dt (f64.const 0.01))))
          (if (f64.gt (local.get $dt) (f64.const 2.0))
            (then (local.set $dt (f64.const 2.0))))

          ;; Schwarzschild geodesic: a = -(GM/r³ + 3*GM*L²/r⁵) * pos
          (local.set $r3 (f64.mul (local.get $r2) (local.get $r)))
          (local.set $r5 (f64.mul (local.get $r3) (local.get $r2)))

          ;; Angular momentum L² = |pos × vel|²
          (local.set $cx (f64.sub (f64.mul (local.get $pos_y) (local.get $vel_z))
                                  (f64.mul (local.get $pos_z) (local.get $vel_y))))
          (local.set $cy (f64.sub (f64.mul (local.get $pos_z) (local.get $vel_x))
                                  (f64.mul (local.get $pos_x) (local.get $vel_z))))
          (local.set $cz (f64.sub (f64.mul (local.get $pos_x) (local.get $vel_y))
                                  (f64.mul (local.get $pos_y) (local.get $vel_x))))
          (local.set $L2 (f64.add (f64.add
            (f64.mul (local.get $cx) (local.get $cx))
            (f64.mul (local.get $cy) (local.get $cy)))
            (f64.mul (local.get $cz) (local.get $cz))))

          ;; Acceleration factor
          (local.set $factor (f64.neg (f64.add
            (f64.div (f64.const 0.5) (local.get $r3))
            (f64.div (f64.mul (f64.const 1.5) (local.get $L2)) (local.get $r5)))))

          ;; Update velocity
          (local.set $vel_x (f64.add (local.get $vel_x)
            (f64.mul (f64.mul (local.get $factor) (local.get $pos_x)) (local.get $dt))))
          (local.set $vel_y (f64.add (local.get $vel_y)
            (f64.mul (f64.mul (local.get $factor) (local.get $pos_y)) (local.get $dt))))
          (local.set $vel_z (f64.add (local.get $vel_z)
            (f64.mul (f64.mul (local.get $factor) (local.get $pos_z)) (local.get $dt))))

          ;; Re-normalize velocity to |v|=c=1 (light speed is constant)
          (local.set $ray_len (f64.sqrt (f64.add (f64.add
            (f64.mul (local.get $vel_x) (local.get $vel_x))
            (f64.mul (local.get $vel_y) (local.get $vel_y)))
            (f64.mul (local.get $vel_z) (local.get $vel_z)))))
          (local.set $vel_x (f64.div (local.get $vel_x) (local.get $ray_len)))
          (local.set $vel_y (f64.div (local.get $vel_y) (local.get $ray_len)))
          (local.set $vel_z (f64.div (local.get $vel_z) (local.get $ray_len)))

          ;; Save old y for disk crossing detection
          (local.set $old_y (local.get $pos_y))

          ;; Update position
          (local.set $pos_x (f64.add (local.get $pos_x) (f64.mul (local.get $vel_x) (local.get $dt))))
          (local.set $pos_y (f64.add (local.get $pos_y) (f64.mul (local.get $vel_y) (local.get $dt))))
          (local.set $pos_z (f64.add (local.get $pos_z) (f64.mul (local.get $vel_z) (local.get $dt))))

          ;; --- Accretion disk crossing ---
          (if (f64.lt (f64.mul (local.get $old_y) (local.get $pos_y)) (f64.const 0.0))
            (then
              (local.set $disk_r2 (f64.add
                (f64.mul (local.get $pos_x) (local.get $pos_x))
                (f64.mul (local.get $pos_z) (local.get $pos_z))))
              (local.set $disk_r (f64.sqrt (local.get $disk_r2)))

              (if (i32.and
                    (f64.gt (local.get $disk_r) (f64.const 3.0))
                    (f64.lt (local.get $disk_r) (f64.const 12.0)))
                (then
                  ;; Temperature: inner=hot(1), outer=cool(0)
                  (local.set $t (f64.sub (f64.const 1.0)
                    (f64.div (f64.sub (local.get $disk_r) (f64.const 3.0)) (f64.const 9.0))))

                  ;; Doppler shift
                  (local.set $doppler (f64.div
                    (f64.sub
                      (f64.mul (local.get $pos_z) (local.get $cam_x))
                      (f64.mul (local.get $pos_x) (local.get $cam_z)))
                    (f64.mul (local.get $disk_r) (local.get $cam_dist))))
                  (local.set $brightness (f64.add (f64.const 0.35)
                    (f64.mul (f64.const 0.65) (f64.add
                      (f64.mul (local.get $doppler) (f64.const 0.5))
                      (f64.const 0.5)))))

                  ;; Disk turbulence: gentle concentric rings drifting inward
                  ;; sin(r*2.0 - frame*0.015) — wide bands, no spiral
                  (local.set $spiral (call $sin_a
                    (f64.sub
                      (f64.mul (local.get $disk_r) (f64.const 2.0))
                      (f64.mul (f64.convert_i32_u (local.get $frame_count)) (f64.const 0.015)))))
                  ;; Very subtle: 0.88 to 1.0
                  (local.set $pattern (f64.add (f64.const 0.88)
                    (f64.mul (local.get $spiral) (f64.const 0.12))))

                  ;; Palette index with 4x4 Bayer ordered dither
                  (local.set $spiral (f64.mul
                    (f64.mul (f64.mul (local.get $t) (local.get $brightness)) (local.get $pattern))
                    (f64.const 127.0)))
                  ;; Look up Bayer value (0-15) from 4x4 matrix
                  ;; dither = (bayer / 16.0 - 0.5) * 4.0 → range [-2, +2]
                  (local.set $spiral (f64.add (local.get $spiral)
                    (f64.mul
                      (f64.sub
                        (f64.div
                          (f64.convert_i32_u (i32.load8_u
                            (i32.add (i32.const 0x10380)
                              (i32.add
                                (i32.shl (i32.and (local.get $py) (i32.const 3)) (i32.const 2))
                                (i32.and (local.get $px) (i32.const 3))))))
                          (f64.const 16.0))
                        (f64.const 0.5))
                      (f64.const 4.0))))
                  (local.set $idx (i32.add (i32.const 16)
                    (i32.trunc_f64_s (local.get $spiral))))
                  (if (i32.lt_s (local.get $idx) (i32.const 16))
                    (then (local.set $idx (i32.const 16))))
                  (if (i32.gt_s (local.get $idx) (i32.const 143))
                    (then (local.set $idx (i32.const 143))))

                  (local.set $color (local.get $idx))
                  (br $ray_done)))))

          ;; --- Escape check ---
          (if (f64.gt (local.get $r) (f64.const 120.0))
            (then
              ;; Procedural starfield
              (local.set $ix (i32.trunc_f64_s (f64.mul (local.get $vel_x) (f64.const 400.0))))
              (local.set $iy (i32.trunc_f64_s (f64.mul (local.get $vel_y) (f64.const 400.0))))
              (local.set $iz (i32.trunc_f64_s (f64.mul (local.get $vel_z) (f64.const 400.0))))
              (local.set $hash (i32.add
                (i32.mul (local.get $ix) (i32.const 374761393))
                (i32.add
                  (i32.mul (local.get $iy) (i32.const 668265263))
                  (i32.mul (local.get $iz) (i32.const 1299709)))))
              (local.set $hash (i32.xor (local.get $hash)
                (i32.shr_u (local.get $hash) (i32.const 13))))
              (local.set $hash (i32.mul (local.get $hash) (i32.const 1274126177)))
              (local.set $hash (i32.xor (local.get $hash)
                (i32.shr_u (local.get $hash) (i32.const 16))))
              (if (i32.lt_u (i32.and (local.get $hash) (i32.const 0xFFF)) (i32.const 5))
                (then
                  (local.set $color (i32.add (i32.const 4)
                    (i32.and (i32.shr_u (local.get $hash) (i32.const 8)) (i32.const 7)))))
                (else
                  (local.set $color (i32.and (i32.shr_u (local.get $hash) (i32.const 12)) (i32.const 1)))))
              (br $ray_done)))

          (local.set $step (i32.add (local.get $step) (i32.const 1)))
          (br $ray_lp)
        ))

        ;; Write pixel
        (local.set $fb_addr (i32.add (i32.const 0x0340)
          (i32.add (i32.mul (local.get $py) (i32.const 320)) (local.get $px))))
        (i32.store8 (local.get $fb_addr) (local.get $color))

        (local.set $px (i32.add (local.get $px) (i32.const 1)))
        (br $xlp)
      ))
      (local.set $py (i32.add (local.get $py) (i32.const 1)))
      (br $ylp)
    ))
  )
)
