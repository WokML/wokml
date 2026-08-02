(module Main)
(import Base)
(effect State (params s) (op get s) (op set (-> s (unit))))
(sig (names state) (-> s (app Handler (app State s) a (tuple a s))))
(def
  state
  (params init)
  (handler
    State
    (var cur init)
    (clause get (args) cur)
    (clause set (args x) (:= cur x))
    (return v (tuple v cur))))
(sig
  (names bumpAmbient)
  (with (-> (unit) (unit)) (row (slot (app State U64)))))
(def
  bumpAmbient
  (params (unit))
  (app (dot State set) (infix (dot State get) (+ 1))))
(sig (names main) (tuple U64 U64))
(def
  main
  (params)
  (block
    (let
      (bind
        (tuple (tuple u2 bFinal) aFinal)
        (block
          (handle (role a) (app state 10))
          (handle (role b) (app state 20))
          (use-in (binds (as a (slot State))) (app bumpAmbient (unit)))
          (use-in (binds (as b (slot State))) (app bumpAmbient (unit)))
          (unit))))
    (tuple aFinal bFinal)))
